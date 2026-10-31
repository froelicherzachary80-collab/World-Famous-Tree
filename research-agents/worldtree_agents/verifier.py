"""Evidence Verification AI + Timeline Researcher AI.

Strict auto-accept rule (configurable off): a researched parent/child link is
promoted to 'verified' only when two independent connectors assert it and the
timeline check finds no contradiction. Everything else stays 'candidate' or
'supported' and is routed to human review as a discovery.
"""
from __future__ import annotations

import json
import sqlite3

from worldtree.db import get_setting

RELIABILITY = {"gedcom": 1, "wikidata": 1, "wikitree": 1, "familysearch": 2, "manual": 1}


def initial_status(referenced: bool) -> str:
    return "supported" if referenced else "candidate"


def timeline_issues(parent: sqlite3.Row, child: sqlite3.Row) -> list[str]:
    issues = []
    pb, pd, cb = parent["birth_year"], parent["death_year"], child["birth_year"]
    if pb is not None and pd is not None and pd < pb:
        issues.append(f"{parent['given_name']} died before being born")
    if pb is not None and cb is not None:
        gap = cb - pb
        if gap < 12:
            issues.append(f"parent only {gap} years older than child")
        if gap > 75:
            issues.append(f"parent {gap} years older than child (implausible)")
    if pd is not None and cb is not None:
        limit = 1 if parent["sex"] == "M" else 0
        if cb > pd + limit:
            issues.append(f"child born {cb - pd} years after parent's death")
    if pb is not None and pd is not None and pd - pb > 122:
        issues.append("lifespan over 122 years")
    return issues


def sources_for(conn, rel_id: int) -> set[str]:
    return {r[0] for r in conn.execute("""SELECT DISTINCT s.connector FROM citations c JOIN sources s ON s.id=c.source_id
                                          WHERE c.subject_type='relationship' AND c.subject_id=?""", (str(rel_id),))}


def evaluate(conn: sqlite3.Connection, rel_id: int) -> dict:
    rel = conn.execute("SELECT * FROM relationships WHERE id=?", (rel_id,)).fetchone()
    if rel is None or rel["evidence_status"] in ("user_provided", "rejected"):
        return {"changed": False}
    connectors = sources_for(conn, rel_id)
    issues = []
    if rel["kind"] == "parent":
        p = conn.execute("SELECT * FROM persons WHERE id=?", (rel["person_a"],)).fetchone()
        c = conn.execute("SELECT * FROM persons WHERE id=?", (rel["person_b"],)).fetchone()
        issues = timeline_issues(p, c)
    rules = get_setting(conn, "auto_accept", {"enabled": True, "min_independent_sources": 2})
    new = rel["evidence_status"]
    if issues:
        new = "disputed"
    elif rules.get("enabled") and len(connectors) >= rules.get("min_independent_sources", 2):
        new = "verified"
    if new != rel["evidence_status"]:
        conn.execute("UPDATE relationships SET evidence_status=? WHERE id=?", (new, rel_id))
    return {"changed": new != rel["evidence_status"], "status": new, "issues": issues,
            "connectors": sorted(connectors)}


def assessment_text(referenced: bool, connector: str) -> str:
    return json.dumps({"connector": connector, "claim_has_reference": referenced,
                       "note": "secondary structured source" if referenced else "unreferenced claim — needs review"})
