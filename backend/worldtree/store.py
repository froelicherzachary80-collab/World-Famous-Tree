"""Tree persistence: GEDCOM import, person CRUD, and in-memory graph loading."""
from __future__ import annotations

import datetime as _dt
import json
import sqlite3
from dataclasses import dataclass, field
from typing import Optional

from . import gedcom
from .dates import year_of
from .db import audit

LIVING_CUTOFF_YEARS = 110  # no death record and born within this window => treated as living


def current_year() -> int:
    return _dt.date.today().year


def presumed_living(birth_year: Optional[int], has_death: bool) -> bool:
    if has_death:
        return False
    if birth_year is None:
        return True  # private by default when unknown
    return birth_year > current_year() - LIVING_CUTOFF_YEARS


def upsert_person(conn: sqlite3.Connection, pid: str, **f) -> None:
    cols = ["given_name", "surname", "sex", "birth_date", "birth_year", "birth_place", "death_date",
            "death_year", "death_place", "is_living", "is_public_figure", "origin", "evidence_status",
            "external_ids", "notes"]
    vals = {c: f[c] for c in cols if c in f}
    if "external_ids" in vals and isinstance(vals["external_ids"], dict):
        vals["external_ids"] = json.dumps(vals["external_ids"])
    exists = conn.execute("SELECT 1 FROM persons WHERE id=?", (pid,)).fetchone()
    if exists:
        if vals:
            conn.execute(f"UPDATE persons SET {', '.join(c + '=?' for c in vals)} WHERE id=?", (*vals.values(), pid))
    else:
        keys = ["id", *vals]
        conn.execute(f"INSERT INTO persons({', '.join(keys)}) VALUES ({', '.join('?' * len(keys))})",
                     (pid, *vals.values()))


def add_parent_edge(conn, parent: str, child: str, pedigree="birth", status="user_provided", family_id=None) -> int:
    cur = conn.execute("""INSERT OR IGNORE INTO relationships(kind, person_a, person_b, pedigree, evidence_status, family_id)
                          VALUES ('parent',?,?,?,?,?)""", (parent, child, pedigree, status, family_id))
    if cur.rowcount == 0:
        r = conn.execute("SELECT id FROM relationships WHERE kind='parent' AND person_a=? AND person_b=? AND pedigree=?",
                         (parent, child, pedigree)).fetchone()
        return r[0]
    return cur.lastrowid


def add_spouse_edge(conn, a: str, b: str, status="user_provided", family_id=None, ended=None) -> int:
    a, b = sorted((a, b))
    cur = conn.execute("""INSERT OR IGNORE INTO relationships(kind, person_a, person_b, pedigree, evidence_status, family_id, ended)
                          VALUES ('spouse',?,?,'birth',?,?,?)""", (a, b, status, family_id, ended))
    if cur.rowcount == 0:
        return conn.execute("SELECT id FROM relationships WHERE kind='spouse' AND person_a=? AND person_b=?",
                            (a, b)).fetchone()[0]
    return cur.lastrowid


def add_source(conn, sid: str, title: str, url=None, connector="manual", reliability=1) -> str:
    conn.execute("""INSERT OR IGNORE INTO sources(id, title, url, connector, retrieved_at, reliability)
                    VALUES (?,?,?,?,datetime('now'),?)""", (sid, title, url, connector, reliability))
    return sid


def cite(conn, source_id: str, subject_type: str, subject_id: str | int, detail="", assessment="") -> None:
    conn.execute("INSERT INTO citations(source_id, subject_type, subject_id, detail, assessment) VALUES (?,?,?,?,?)",
                 (source_id, subject_type, str(subject_id), detail, assessment))


@dataclass
class ImportReport:
    batch: str
    people: int = 0
    families: int = 0
    parent_links: int = 0
    spouse_links: int = 0
    sources: int = 0
    version: str = ""
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def import_gedcom(conn: sqlite3.Connection, data: str | bytes, universe: str = "my_family") -> ImportReport:
    res = gedcom.parse(data)
    batch = f"g{conn.execute('SELECT COUNT(*) FROM audit_log WHERE action=?', ('gedcom_import',)).fetchone()[0] + 1}"
    rep = ImportReport(batch, version=res.version, warnings=res.warnings[:200], errors=res.errors)
    if not res.valid:
        return rep
    pid = lambda x: f"{batch}:{x.strip('@')}"  # noqa: E731
    conn.execute("BEGIN")
    try:
        for s in res.sources.values():
            add_source(conn, pid(s.xref), s.title or s.author or s.xref, s.url, "gedcom", 1)
            rep.sources += 1
        for p in res.persons.values():
            by, dy = year_of(p.birth.date), year_of(p.death.date)
            upsert_person(conn, pid(p.xref), given_name=p.given, surname=p.surname, sex=p.sex,
                          birth_date=p.birth.date, birth_year=by, birth_place=p.birth.place,
                          death_date=p.death.date, death_year=dy, death_place=p.death.place,
                          is_living=int(presumed_living(by, p.is_dead_flag or dy is not None)),
                          origin="gedcom", evidence_status="user_provided",
                          external_ids={"gedcom": p.xref, "media": p.media} if p.media else {"gedcom": p.xref},
                          notes="\n".join(p.notes))
            for g, s, t in p.alt_names:
                conn.execute("INSERT INTO person_names(person_id, given_name, surname, name_type) VALUES (?,?,?,?)",
                             (pid(p.xref), g, s, t))
            for c in p.citations:
                if c.source_xref and c.source_xref in res.sources:
                    cite(conn, pid(c.source_xref), "person", pid(p.xref), c.page or c.text, "gedcom citation")
            conn.execute("INSERT OR IGNORE INTO universe_members VALUES (?,?)", (universe, pid(p.xref)))
            rep.people += 1
        for f in res.families.values():
            rep.families += 1
            parents = [x for x in f.parents if x in res.persons]
            if len(parents) == 2:
                add_spouse_edge(conn, pid(parents[0]), pid(parents[1]), family_id=pid(f.xref), ended=f.divorced)
                rep.spouse_links += 1
            for cx, _, _ in f.children:
                if cx not in res.persons:
                    continue
                child = res.persons[cx]
                for px in parents:
                    ped = gedcom.pedigree_for(child, f, px)
                    rid = add_parent_edge(conn, pid(px), pid(cx), ped, family_id=pid(f.xref))
                    for c in f.citations:
                        if c.source_xref in res.sources:
                            cite(conn, pid(c.source_xref), "relationship", rid, c.page, "gedcom family citation")
                    rep.parent_links += 1
        audit(conn, "user", "gedcom_import", {"batch": batch, "people": rep.people, "version": rep.version})
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return rep


# ---------------------------------------------------------------- graph view

@dataclass
class Edge:
    other: str
    pedigree: str
    status: str
    rel_id: int


@dataclass
class Graph:
    persons: dict[str, sqlite3.Row] = field(default_factory=dict)
    parents: dict[str, list[Edge]] = field(default_factory=dict)
    children: dict[str, list[Edge]] = field(default_factory=dict)
    spouses: dict[str, list[Edge]] = field(default_factory=dict)

    def name(self, pid: str) -> str:
        r = self.persons.get(pid)
        if not r:
            return pid
        return f"{r['given_name']} {r['surname']}".strip() or "(unknown)"


def load_graph(conn: sqlite3.Connection) -> Graph:
    g = Graph()
    for r in conn.execute("SELECT * FROM persons WHERE merged_into IS NULL"):
        g.persons[r["id"]] = r
    for r in conn.execute("SELECT * FROM relationships WHERE evidence_status != 'rejected'"):
        a, b = r["person_a"], r["person_b"]
        if a not in g.persons or b not in g.persons:
            continue
        if r["kind"] == "parent":
            g.parents.setdefault(b, []).append(Edge(a, r["pedigree"], r["evidence_status"], r["id"]))
            g.children.setdefault(a, []).append(Edge(b, r["pedigree"], r["evidence_status"], r["id"]))
        else:
            g.spouses.setdefault(a, []).append(Edge(b, "spouse", r["evidence_status"], r["id"]))
            g.spouses.setdefault(b, []).append(Edge(a, "spouse", r["evidence_status"], r["id"]))
    return g


def person_dict(conn: sqlite3.Connection, r: sqlite3.Row, include_private: bool = True) -> dict:
    d = dict(r)
    d["external_ids"] = json.loads(d.get("external_ids") or "{}")
    d["name"] = f"{d['given_name']} {d['surname']}".strip()
    d["universes"] = [x[0] for x in conn.execute("SELECT universe_id FROM universe_members WHERE person_id=?", (d["id"],))]
    if d["is_living"] and not d["is_public_figure"] and not include_private:
        for k in ("birth_date", "birth_place", "notes"):
            d[k] = None
        d["birth_year"] = None
        d["private"] = True
    return d
