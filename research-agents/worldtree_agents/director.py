"""Genealogy Director AI — dispatches durable jobs to the specialist agents.

Job kinds:
  plan_goal           Research Planner output -> discovery / lookup jobs
  discover_category   Celebrity Research AI: find public figures for a universe
  lookup_name         Web Researcher AI: resolve a named person on Wikidata
  research_person     fetch record, privacy check, store, expand parents, cross-source
  wikitree_ancestors  Historical Records AI: corroborate via WikiTree
  match_person        Family Matcher AI: compare against the user's tree
  find_connections    Relationship Pathfinder AI after confirmed identity matches
"""
from __future__ import annotations

import json
import sqlite3
from typing import Optional

from worldtree import duplicates, jobqueue, privacy, relationships, store
from worldtree.db import get_setting, log_activity
from worldtree_integrations.base import BlockedError, BudgetExceeded, ConnectorError, PersonRecord
from worldtree_integrations.wikidata import WikidataConnector
from worldtree_integrations.wikitree import WikiTreeConnector

from . import planner, verifier

MATCH_THRESHOLD = 0.7


class Director:
    def __init__(self, conn: sqlite3.Connection, wikidata: Optional[WikidataConnector] = None,
                 wikitree: Optional[WikiTreeConnector] = None):
        self.conn = conn
        self.wd = wikidata or WikidataConnector()
        self.wt = wikitree or WikiTreeConnector()
        self._goal: Optional[int] = None
        for c in (self.wd.http, self.wt.http):
            c.on_request = self._spend

    # ------------------------------------------------------------ budget
    def _spend(self) -> None:
        if self._goal is None:
            return
        g = self.conn.execute("SELECT spent, budget FROM goals WHERE id=?", (self._goal,)).fetchone()
        if g and g["spent"] >= g["budget"]:
            raise BudgetExceeded("goal request budget reached")
        self.conn.execute("UPDATE goals SET spent=spent+1 WHERE id=?", (self._goal,))

    def log(self, agent: str, msg: str, level: str = "info") -> None:
        log_activity(self.conn, agent, msg, level, self._goal)

    def discovery(self, kind: str, title: str, detail: dict, status: str = "pending") -> int:
        return self.conn.execute("INSERT INTO discoveries(goal_id, kind, title, detail, status) VALUES (?,?,?,?,?)",
                                 (self._goal, kind, title, json.dumps(detail), status)).lastrowid

    def enqueue(self, kind: str, payload: dict, priority: int = 5, key: Optional[str] = None):
        dk = f"{self._goal}:{key}" if key else None
        return jobqueue.enqueue(self.conn, kind, payload, self._goal, priority, dk)

    # ------------------------------------------------------------ run
    def run_one(self) -> bool:
        job = jobqueue.claim(self.conn)
        if job is None:
            return False
        self._goal = job["goal_id"]
        payload = json.loads(job["payload"])
        try:
            getattr(self, "job_" + job["kind"])(payload)
            jobqueue.complete(self.conn, job["id"])
        except BudgetExceeded as e:
            jobqueue.fail(self.conn, job["id"], str(e), retryable=True)
            self.conn.execute("UPDATE jobs SET attempts=attempts-1 WHERE id=?", (job["id"],))
            self.conn.execute("UPDATE goals SET status='paused' WHERE id=?", (self._goal,))
            self.log("Genealogy Director AI", "Request budget reached — goal paused. Raise the budget to continue.", "warn")
        except BlockedError as e:
            jobqueue.fail(self.conn, job["id"], str(e), retryable=False)
            self.log("Web Researcher AI", str(e), "blocked")
        except ConnectorError as e:
            jobqueue.fail(self.conn, job["id"], str(e), retryable=True)
            self.log("Web Researcher AI", f"source error (will retry): {e}", "error")
        except Exception as e:  # noqa: BLE001
            jobqueue.fail(self.conn, job["id"], f"{type(e).__name__}: {e}", retryable=False)
            self.log("Genealogy Director AI", f"job {job['kind']} failed: {e}", "error")
        self._maybe_complete_goal()
        return True

    def _maybe_complete_goal(self) -> None:
        if self._goal is None:
            return
        open_jobs = self.conn.execute("SELECT COUNT(*) FROM jobs WHERE goal_id=? AND status IN ('queued','running')",
                                      (self._goal,)).fetchone()[0]
        g = self.conn.execute("SELECT status, schedule FROM goals WHERE id=?", (self._goal,)).fetchone()
        if open_jobs == 0 and g and g["status"] == "active":
            if g["schedule"] == "daily":
                jobqueue.enqueue(self.conn, "plan_goal", {}, self._goal, 1, None, delay_seconds=86400)
            else:
                self.conn.execute("UPDATE goals SET status='completed' WHERE id=?", (self._goal,))
                self.log("Genealogy Director AI", "Goal completed.")

    # ------------------------------------------------------------ jobs
    def job_plan_goal(self, _p: dict) -> None:
        plan = json.loads(self.conn.execute("SELECT plan FROM goals WHERE id=?", (self._goal,)).fetchone()[0])
        for step in plan["steps"]:
            if step["action"] == "discover":
                self.enqueue("discover_category", {"category": step["category"], "universe": step["universe"],
                                                   "limit": step["limit"]}, 3, f"disc:{step['category']}")
            elif step["action"] == "lookup":
                self.enqueue("lookup_name", {"name": step["name"]}, 3, f"name:{step['name']}")
        self.log("Research Planner AI", f"Plan queued: {len(plan['steps'])} steps.")

    def job_discover_category(self, p: dict) -> None:
        ids = self.wd.discover(p["category"], p.get("limit", 12))
        self.log("Celebrity Research AI", f"Found {len(ids)} public figures for '{p['category']}'.")
        for q in ids:
            self.enqueue("research_person", {"qid": q, "universe": p["universe"], "depth": 0, "root": True}, 4, f"wd:{q}")

    def job_lookup_name(self, p: dict) -> None:
        from worldtree_integrations.wikidata import choose_creator
        ids = self.wd.search(p["name"], 7)
        recs = self.wd.fetch(ids) if ids else []
        by_id = {r.external_id: r for r in recs}
        ordered = [by_id[i] for i in ids if i in by_id]
        pick = choose_creator(p["name"], ordered)
        if pick is None:   # not a creator handle: accept an exact name match of any public figure
            pick = next((r for r in ordered if r.is_public_figure and r.name.lower() == p["name"].lower()), None)
        if pick is None:
            self.log("Web Researcher AI", f"No public record found for '{p['name']}' — nothing was guessed.", "warn")
            self.discovery("new_person", f"No public record found for {p['name']}", {"name": p["name"]}, "auto_accepted")
            return
        real = f" (real name: {pick.birth_name})" if pick.birth_name else ""
        self.log("Celebrity Research AI", f"Found {p['name']}{real}.")
        universe = "minecraft" if pick.is_creator else "famous_lookups"
        self.enqueue("research_person", {"qid": pick.external_id, "universe": universe,
                                         "depth": 0, "root": True, "handle": p["name"]}, 4, f"wd:{pick.external_id}")

    def _find_existing(self, source: str, ext: str) -> Optional[str]:
        r = self.conn.execute("SELECT id FROM persons WHERE json_extract(external_ids, ?) = ? AND merged_into IS NULL",
                              (f"$.{source}", ext)).fetchone()
        return r[0] if r else None

    def _store_record(self, rec: PersonRecord, universe: Optional[str]) -> Optional[str]:
        ok, why = privacy.may_import({"birth_year": rec.birth_year, "death_year": rec.death_year,
                                      "is_public_figure": rec.is_public_figure})
        if not ok:
            self.log("Evidence Verification AI", f"Skipped a record from {rec.source}: {why}.", "warn")
            return None
        pid = self._find_existing(rec.source, rec.external_id)
        for src, ext in rec.cross_ids.items():
            pid = pid or self._find_existing(src, ext)
        is_new = pid is None
        pid = pid or f"{'wd' if rec.source == 'wikidata' else 'wt'}:{rec.external_id}"
        ext_ids = {rec.source: rec.external_id, **rec.cross_ids}
        if not is_new:
            old = json.loads(self.conn.execute("SELECT external_ids FROM persons WHERE id=?", (pid,)).fetchone()[0])
            ext_ids = {**old, **ext_ids}
            store.upsert_person(self.conn, pid, external_ids=ext_ids)
        else:
            clean = privacy.scrub(rec.__dict__)
            store.upsert_person(self.conn, pid, given_name=clean["given"], surname=clean["surname"], sex=rec.sex,
                                birth_date=rec.birth_date, birth_year=rec.birth_year, birth_place=clean.get("birth_place"),
                                death_date=rec.death_date, death_year=rec.death_year, death_place=clean.get("death_place"),
                                is_living=int(store.presumed_living(rec.birth_year, rec.death_year is not None)),
                                is_public_figure=int(rec.is_public_figure), origin="research",
                                evidence_status="candidate", external_ids=ext_ids, notes=clean.get("description", ""))
            sid = store.add_source(self.conn, f"{rec.source}:{rec.external_id}", f"{rec.source}: {rec.name}", rec.url,
                                   rec.source, 1)
            store.cite(self.conn, sid, "person", pid, f"retrieved {rec.retrieved_at}", verifier.assessment_text(True, rec.source))
        if universe:
            self.conn.execute("INSERT OR IGNORE INTO universes(id,name,color) VALUES (?,?,?)",
                              (universe, universe.replace('_', ' ').title(), "#9AA5C4"))
            self.conn.execute("INSERT OR IGNORE INTO universe_members VALUES (?,?)", (universe, pid))
        if is_new:
            self.discovery("new_person", f"New candidate person: {rec.name}",
                           {"person_id": pid, "source": rec.url, "description": rec.description}, "auto_accepted")
        return pid

    def _link_parent(self, parent: str, child: str, referenced: bool, rec_source: str, url: str) -> None:
        rid = store.add_parent_edge(self.conn, parent, child, "birth", verifier.initial_status(referenced))
        sid = store.add_source(self.conn, f"{rec_source}:rel:{parent}>{child}", f"{rec_source} parent claim", url, rec_source, 1)
        if rec_source not in verifier.sources_for(self.conn, rid):
            store.cite(self.conn, sid, "relationship", rid, f"{parent} parent of {child}",
                       verifier.assessment_text(referenced, rec_source))
        res = verifier.evaluate(self.conn, rid)
        if res.get("issues"):
            self.discovery("relationship", "Timeline contradiction found",
                           {"relationship_id": rid, "issues": res["issues"]})
            self.log("Timeline Researcher AI", "; ".join(res["issues"]), "warn")
        elif res.get("status") == "verified" and res.get("changed"):
            self.discovery("relationship", "Relationship verified by independent sources",
                           {"relationship_id": rid, "connectors": res["connectors"]}, "auto_accepted")
        elif not referenced:
            self.discovery("relationship", "Unreferenced parent claim needs review", {"relationship_id": rid})

    def job_research_person(self, p: dict) -> None:
        recs = self.wd.fetch([p["qid"]])
        if not recs:
            return
        rec = recs[0]
        pid = self._store_record(rec, p.get("universe"))
        if pid is None:
            return
        max_depth = 4
        parent_ids = rec.relatives.get("father", []) + rec.relatives.get("mother", [])
        if parent_ids:
            parents = {r.external_id: r for r in self.wd.fetch([q for q, _ in parent_ids])}
            for q, referenced in parent_ids:
                if q in parents:
                    ppid = self._store_record(parents[q], p.get("universe"))
                    if ppid:
                        self._link_parent(ppid, pid, referenced, "wikidata", rec.url)
                        if p.get("depth", 0) + 1 < max_depth:
                            self.enqueue("research_person", {"qid": q, "universe": p.get("universe"),
                                                             "depth": p.get("depth", 0) + 1}, 6, f"wd:{q}")
        if "wikitree" in rec.cross_ids:
            self.enqueue("wikitree_ancestors", {"wikitree_id": rec.cross_ids["wikitree"], "person_id": pid}, 6,
                         f"wt:{rec.cross_ids['wikitree']}")
        self.enqueue("match_person", {"person_id": pid}, 7, f"match:{pid}")

    def job_wikitree_ancestors(self, p: dict) -> None:
        recs = self.wt.ancestors(p["wikitree_id"], 4)
        by_ext = {}
        for r in recs:
            pid = self._store_record(r, None)
            if pid:
                by_ext[r.external_id] = pid
        for r in recs:
            child = by_ext.get(r.external_id)
            for rel in ("father", "mother"):
                for ext, ref in r.relatives.get(rel, []):
                    if child and ext in by_ext:
                        self._link_parent(by_ext[ext], child, ref, "wikitree", r.url)
        self.log("Historical Records AI", f"WikiTree: cross-checked {len(recs)} ancestor profiles.")
        for pid in by_ext.values():
            self.enqueue("match_person", {"person_id": pid}, 7, f"match:{pid}")

    def job_match_person(self, p: dict) -> None:
        g = store.load_graph(self.conn)
        pid = p["person_id"]
        if pid not in g.persons:
            return
        mine = [r[0] for r in self.conn.execute(
            "SELECT person_id FROM universe_members WHERE universe_id='my_family'") if r[0] in g.persons]
        best = None
        for m in mine:
            ds = duplicates.score_pair(self.conn, g, pid, m)
            if ds.score >= MATCH_THRESHOLD and ds.corroborations >= 2 and not ds.conflicts:
                if best is None or ds.score > best.score:
                    best = ds
        if best:
            self.discovery("identity_match", f"Possible match: {g.name(pid)} ↔ {g.name(best.b)} in your tree",
                           {"research_person": pid, "my_person": best.b, "score": best.score,
                            "matches": best.matches, "conflicts": best.conflicts})
            self.log("Family Matcher AI", f"Candidate identity match for {g.name(pid)} (score {best.score}). Needs your review.")

    def job_find_connections(self, p: dict) -> None:
        g = store.load_graph(self.conn)
        home = get_setting(self.conn, "home_person")
        target = p["person_id"]
        if not home or home not in g.persons or target not in g.persons:
            return
        res = relationships.find_connection(g, home, target)
        if res["kind"] in ("blood", "adoptive", "marriage"):
            prim = res["primary"]
            title = f"{'Candidate' if prim['uncertain'] else 'VERIFIED'} connection: {g.name(target)} is your {res['relationship']}"
            self.discovery("connection", title, {"person_id": target, "result": res})
            self.log("Relationship Pathfinder AI", title)
        else:
            self.log("Relationship Pathfinder AI", f"{g.name(target)}: NO VERIFIED CONNECTION FOUND — RESEARCH CONTINUES")


def create_goal(conn: sqlite3.Connection, instruction: str, budget: int = 200, schedule: Optional[str] = None,
                llm=None) -> int:
    plan = planner.make_plan(instruction, llm)
    gid = conn.execute("INSERT INTO goals(instruction, plan, budget, schedule) VALUES (?,?,?,?)",
                       (instruction, json.dumps(plan), budget, schedule)).lastrowid
    return gid


def set_goal_status(conn: sqlite3.Connection, gid: int, action: str) -> str:
    g = conn.execute("SELECT status FROM goals WHERE id=?", (gid,)).fetchone()
    if g is None:
        raise KeyError("goal not found")
    if action == "start":
        if g["status"] in ("draft", "stopped", "completed"):
            jobqueue.enqueue(conn, "plan_goal", {}, gid, 1, None)
        new = "active"
    elif action == "resume":
        new = "active"
    elif action == "pause":
        new = "paused"
    elif action == "stop":
        jobqueue.cancel_goal(conn, gid)
        new = "stopped"
    elif action == "prioritize":
        conn.execute("UPDATE goals SET priority=MAX(0, priority-2) WHERE id=?", (gid,))
        return g["status"]
    else:
        raise ValueError(action)
    conn.execute("UPDATE goals SET status=? WHERE id=?", (new, gid))
    return new


def accept_identity_match(conn: sqlite3.Connection, discovery_id: int) -> Optional[int]:
    """User confirmed a research person is the same as someone in their tree -> merge (undoable),
    then queue the pathfinder from the home person to every root public figure in that goal."""
    d = conn.execute("SELECT * FROM discoveries WHERE id=?", (discovery_id,)).fetchone()
    det = json.loads(d["detail"])
    log_id = duplicates.merge(conn, det["my_person"], det["research_person"])
    conn.execute("UPDATE discoveries SET status='accepted' WHERE id=?", (discovery_id,))
    figures = [r[0] for r in conn.execute("""SELECT p.id FROM persons p WHERE p.is_public_figure=1 AND p.merged_into IS NULL
                                             AND p.origin='research'""")]
    for f in figures:
        # Goal-less job: runs even if the originating goal has already completed.
        jobqueue.enqueue(conn, "find_connections", {"person_id": f}, None, 2, f"conn:{discovery_id}:{f}")
    return log_id
