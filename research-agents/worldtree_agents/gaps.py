"""Research gap analysis for the user's imported tree."""
from __future__ import annotations

import sqlite3

from worldtree.store import load_graph


def analyze(conn: sqlite3.Connection, limit: int = 50) -> dict:
    g = load_graph(conn)
    mine = {r[0] for r in conn.execute("SELECT person_id FROM universe_members WHERE universe_id='my_family'")}
    missing_parents, missing_birth, unsourced = [], [], []
    cited = {r[0] for r in conn.execute("SELECT subject_id FROM citations WHERE subject_type='person'")}
    for pid in mine:
        if pid not in g.persons:
            continue
        r = g.persons[pid]
        np = len(g.parents.get(pid, []))
        if np < 2 and not r["is_living"]:
            missing_parents.append({"id": pid, "name": g.name(pid), "known_parents": np, "birth_year": r["birth_year"]})
        if r["birth_year"] is None and not r["is_living"]:
            missing_birth.append({"id": pid, "name": g.name(pid)})
        if pid not in cited:
            unsourced.append({"id": pid, "name": g.name(pid)})
    # Deepest end-of-line ancestors first: they are where new branches come from.
    missing_parents.sort(key=lambda x: (x["birth_year"] is None, x["birth_year"] or 0))
    recs = []
    if missing_parents:
        recs.append("Reconstruct missing branches for your end-of-line ancestors")
    recs += ["Find my possible family connections to Minecraft YouTubers",
             "Research Young Hollywood actors and find connections to my GEDCOM family tree",
             "Explore royal family connections"]
    return {"missing_parents": missing_parents[:limit], "missing_birth": missing_birth[:limit],
            "unsourced": unsourced[:limit], "counts": {"missing_parents": len(missing_parents),
            "missing_birth": len(missing_birth), "unsourced": len(unsourced)}, "recommended_goals": recs}
