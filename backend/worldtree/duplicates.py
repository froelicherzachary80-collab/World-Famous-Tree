"""Duplicate detection, reversible merging, and strict auto-merge rules.

A shared name is never sufficient: a candidate needs at least one independent
corroborating field (date, place, or relative) and is penalised for conflicts.
"""
from __future__ import annotations

import json
import re
import sqlite3
import unicodedata
from dataclasses import dataclass, field

from .db import audit
from .store import Graph, load_graph


def normalize(s: str | None) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z ]", "", s.lower()).strip()


def soundex(s: str) -> str:
    s = normalize(s).replace(" ", "")
    if not s:
        return ""
    codes = {**dict.fromkeys("bfpv", "1"), **dict.fromkeys("cgjkqsxz", "2"), **dict.fromkeys("dt", "3"),
             "l": "4", **dict.fromkeys("mn", "5"), "r": "6"}
    out, last = s[0].upper(), codes.get(s[0], "")
    for ch in s[1:]:
        c = codes.get(ch, "")
        if c and c != last:
            out += c
        if ch not in "hw":
            last = c
    return (out + "000")[:4]


def jaro_winkler(a: str, b: str) -> float:
    a, b = normalize(a), normalize(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    md = max(len(a), len(b)) // 2 - 1
    am, bm = [False] * len(a), [False] * len(b)
    m = 0
    for i, ca in enumerate(a):
        for j in range(max(0, i - md), min(len(b), i + md + 1)):
            if not bm[j] and b[j] == ca:
                am[i] = bm[j] = True
                m += 1
                break
    if not m:
        return 0.0
    t, k = 0, 0
    for i in range(len(a)):
        if am[i]:
            while not bm[k]:
                k += 1
            t += a[i] != b[k]
            k += 1
    jaro = (m / len(a) + m / len(b) + (m - t / 2) / m) / 3
    p = 0
    for x, y in zip(a[:4], b[:4]):
        if x != y:
            break
        p += 1
    return jaro + p * 0.1 * (1 - jaro)


@dataclass
class DupScore:
    a: str
    b: str
    score: float
    matches: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)

    @property
    def corroborations(self) -> int:
        return len([m for m in self.matches if not m.startswith("name")])


def _names(conn, pid, row) -> list[tuple[str, str]]:
    out = [(row["given_name"], row["surname"])]
    out += [(r[0], r[1]) for r in conn.execute("SELECT given_name, surname FROM person_names WHERE person_id=?", (pid,))]
    return out


def _rel_names(g: Graph, pid: str, kind: str) -> set[str]:
    edges = {"parents": g.parents, "spouses": g.spouses, "children": g.children}[kind].get(pid, [])
    return {normalize(g.name(e.other)) for e in edges}


def score_pair(conn: sqlite3.Connection, g: Graph, a: str, b: str) -> DupScore:
    ra, rb = g.persons[a], g.persons[b]
    ds = DupScore(a, b, 0.0)
    best = max(jaro_winkler(f"{ga} {sa}", f"{gb} {sb}") for ga, sa in _names(conn, a, ra) for gb, sb in _names(conn, b, rb))
    if best >= 0.97:
        ds.matches.append("name: exact/near-exact")
    elif best >= 0.88:
        ds.matches.append(f"name: similar ({best:.2f})")
    else:
        return ds  # names too different to consider
    s = 0.35 * best
    if ra["sex"] in "MF" and rb["sex"] in "MF" and ra["sex"] != rb["sex"]:
        ds.conflicts.append("sex differs")
        s -= 0.4
    for f, label, tol in (("birth_year", "birth year", 2), ("death_year", "death year", 2)):
        ya, yb = ra[f], rb[f]
        if ya is not None and yb is not None:
            if ya == yb:
                ds.matches.append(f"{label} identical ({ya})")
                s += 0.2
            elif abs(ya - yb) <= tol:
                ds.matches.append(f"{label} within {tol} years")
                s += 0.1
            elif abs(ya - yb) > 5:
                ds.conflicts.append(f"{label} differs ({ya} vs {yb})")
                s -= 0.3
    for f, label in (("birth_place", "birthplace"), ("death_place", "death place")):
        pa, pb = normalize(ra[f]), normalize(rb[f])
        if pa and pb:
            ta, tb = set(pa.split()), set(pb.split())
            overlap = len(ta & tb) / max(1, min(len(ta), len(tb)))
            if overlap >= 0.6:
                ds.matches.append(f"{label} matches")
                s += 0.1
            elif overlap == 0:
                ds.conflicts.append(f"{label} differs")
                s -= 0.05
    for kind, w in (("parents", 0.2), ("spouses", 0.15), ("children", 0.1)):
        na, nb = _rel_names(g, a, kind), _rel_names(g, b, kind)
        if na and nb:
            shared = {x for x in na if any(jaro_winkler(x, y) >= 0.93 for y in nb)}
            if shared:
                ds.matches.append(f"{kind} match ({len(shared)})")
                s += w
    if ds.corroborations == 0:
        s = min(s, 0.45)  # name alone can never reach review threshold
    ds.score = round(max(0.0, min(1.0, s)), 3)
    return ds


def detect(conn: sqlite3.Connection, threshold: float = 0.55, only: set[str] | None = None) -> list[DupScore]:
    g = load_graph(conn)
    blocks: dict[str, list[str]] = {}
    for pid, r in g.persons.items():
        keys = {soundex(s) + normalize(gv)[:1] for gv, s in _names(conn, pid, r) if s or gv}
        for k in keys:
            blocks.setdefault(k, []).append(pid)
    seen, found = set(), []
    known = {(r[0], r[1]) for r in conn.execute("SELECT person_a, person_b FROM duplicate_candidates")}
    for ids in blocks.values():
        if len(ids) > 400:  # pathological block (e.g. empty names); skip rather than O(n^2)
            continue
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                a, b = sorted((ids[i], ids[j]))
                if (a, b) in seen or (only and a not in only and b not in only):
                    continue
                seen.add((a, b))
                if any(e.other == b for e in g.parents.get(a, []) + g.children.get(a, []) + g.spouses.get(a, [])):
                    continue  # directly related people are not duplicates
                ds = score_pair(conn, g, a, b)
                if ds.score >= threshold:
                    found.append(ds)
                    if (a, b) not in known:
                        conn.execute("""INSERT OR IGNORE INTO duplicate_candidates(person_a, person_b, score, matches, conflicts)
                                        VALUES (?,?,?,?,?)""", (a, b, ds.score, json.dumps(ds.matches), json.dumps(ds.conflicts)))
    return found


def auto_merge_allowed(ds: DupScore, rules: dict) -> bool:
    if not rules.get("enabled"):
        return False
    return (ds.score >= rules.get("min_score", 0.95) and not ds.conflicts
            and ds.corroborations >= rules.get("min_corroborations", 3))


def merge(conn: sqlite3.Connection, keep: str, drop: str, actor: str = "user") -> int:
    """Move drop's edges to keep, mark drop as merged. Fully reversible via undo_merge."""
    rels = [dict(r) for r in conn.execute("SELECT * FROM relationships WHERE person_a=? OR person_b=?", (drop, drop))]
    cits = [dict(r) for r in conn.execute("SELECT * FROM citations WHERE subject_type='person' AND subject_id=?", (drop,))]
    unis = [r[0] for r in conn.execute("SELECT universe_id FROM universe_members WHERE person_id=?", (drop,))]
    conn.execute("BEGIN")
    try:
        moved = []
        for r in rels:
            a = keep if r["person_a"] == drop else r["person_a"]
            b = keep if r["person_b"] == drop else r["person_b"]
            if a == b:
                continue
            if r["kind"] == "spouse":
                a, b = sorted((a, b))
            cur = conn.execute("""INSERT OR IGNORE INTO relationships(kind, person_a, person_b, pedigree, evidence_status, family_id, ended)
                                  VALUES (?,?,?,?,?,?,?)""", (r["kind"], a, b, r["pedigree"], r["evidence_status"], r["family_id"], r["ended"]))
            moved.append({"old": r, "new_id": cur.lastrowid if cur.rowcount else None})
            conn.execute("DELETE FROM relationships WHERE id=?", (r["id"],))
        conn.execute("UPDATE citations SET subject_id=? WHERE subject_type='person' AND subject_id=?", (keep, drop))
        for u in unis:
            conn.execute("INSERT OR IGNORE INTO universe_members VALUES (?,?)", (u, keep))
        # Alternate names preserved: record dropped primary name as an alias of keep.
        r = conn.execute("SELECT given_name, surname FROM persons WHERE id=?", (drop,)).fetchone()
        conn.execute("INSERT INTO person_names(person_id, given_name, surname, name_type) VALUES (?,?,?,'merged')",
                     (keep, r[0], r[1]))
        conn.execute("UPDATE persons SET merged_into=? WHERE id=?", (keep, drop))
        a, b = sorted((keep, drop))
        conn.execute("UPDATE duplicate_candidates SET status='merged' WHERE person_a=? AND person_b=?", (a, b))
        snap = json.dumps({"moved": moved, "citations": [c["id"] for c in cits], "universes": unis})
        cur = conn.execute("INSERT INTO merge_log(kept_id, merged_id, snapshot) VALUES (?,?,?)", (keep, drop, snap))
        audit(conn, actor, "merge", {"keep": keep, "drop": drop})
        conn.execute("COMMIT")
        return cur.lastrowid
    except Exception:
        conn.execute("ROLLBACK")
        raise


def undo_merge(conn: sqlite3.Connection, log_id: int, actor: str = "user") -> None:
    row = conn.execute("SELECT * FROM merge_log WHERE id=? AND undone=0", (log_id,)).fetchone()
    if not row:
        raise KeyError("merge not found or already undone")
    snap = json.loads(row["snapshot"])
    keep, drop = row["kept_id"], row["merged_id"]
    conn.execute("BEGIN")
    try:
        for m in snap["moved"]:
            if m["new_id"]:
                conn.execute("DELETE FROM relationships WHERE id=?", (m["new_id"],))
            o = m["old"]
            conn.execute("""INSERT INTO relationships(id, kind, person_a, person_b, pedigree, evidence_status, family_id, ended, created_at)
                            VALUES (?,?,?,?,?,?,?,?,?)""", (o["id"], o["kind"], o["person_a"], o["person_b"], o["pedigree"],
                                                         o["evidence_status"], o["family_id"], o["ended"], o["created_at"]))
        for cid in snap["citations"]:
            conn.execute("UPDATE citations SET subject_id=? WHERE id=?", (drop, cid))
        r = conn.execute("SELECT given_name, surname FROM persons WHERE id=?", (drop,)).fetchone()
        conn.execute("""DELETE FROM person_names WHERE rowid = (SELECT rowid FROM person_names WHERE person_id=? AND
                        given_name=? AND surname=? AND name_type='merged' LIMIT 1)""", (keep, r[0], r[1]))
        conn.execute("UPDATE persons SET merged_into=NULL WHERE id=?", (drop,))
        a, b = sorted((keep, drop))
        conn.execute("UPDATE duplicate_candidates SET status='open' WHERE person_a=? AND person_b=?", (a, b))
        conn.execute("UPDATE merge_log SET undone=1 WHERE id=?", (log_id,))
        audit(conn, actor, "undo_merge", {"log_id": log_id})
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
