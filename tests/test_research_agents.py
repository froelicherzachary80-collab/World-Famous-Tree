"""End-to-end research pipeline against a fake web (no network)."""
import json

from worldtree import db, store
from worldtree_agents import director as D
from worldtree_agents.planner import make_plan
from worldtree_integrations.base import HttpClient
from worldtree_integrations.wikidata import WikidataConnector, wd_time_to_astronomical
from worldtree_integrations.wikitree import WikiTreeConnector

from conftest import FakeWeb, wd_entity

Y = store.current_year()


def make_director(conn, web):
    wd = WikidataConnector(HttpClient("wikidata", 1000, transport=web))
    wt = WikiTreeConnector(HttpClient("wikitree", 1000, transport=web))
    return D.Director(conn, wd, wt)


def drain(d, limit=200):
    n = 0
    while d.run_one() and n < limit:
        n += 1
    return n


def scenario_web(**kw):
    ents = {
        "Q100": wd_entity("Q100", "Rae Star", born="+1990-05-01T00:00:00Z", sex="F", father="Q101", wikitree="Star-1"),
        "Q101": wd_entity("Q101", "Tom Star", born="+1930-01-01T00:00:00Z", died="+2000-01-01T00:00:00Z",
                          father="Q103", enwiki=False, wikitree="Star-2"),
        "Q103": wd_entity("Q103", "Bob Stone", born="+1875-01-01T00:00:00Z", died="+1950-01-01T00:00:00Z",
                          enwiki=False, wikitree="Stone-3"),
        "Q200": wd_entity("Q200", "Kid Star", born=f"+{Y - 9}-01-01T00:00:00Z"),            # minor
        "Q201": wd_entity("Q201", "Private Parent", born="+1970-01-01T00:00:00Z", enwiki=False),
    }
    wt = {"Star-1": [
        {"Id": 1, "Name": "Star-1", "FirstName": "Rae", "LastNameAtBirth": "Star", "IsLiving": 1, "Father": 2},
        {"Id": 2, "Name": "Star-2", "FirstName": "Tom", "LastNameAtBirth": "Star", "Gender": "Male",
         "BirthDate": "1930-01-01", "DeathDate": "2000-01-01", "Father": 3, "IsLiving": 0},
        {"Id": 3, "Name": "Stone-3", "FirstName": "Bob", "LastNameAtBirth": "Stone", "Gender": "Male",
         "BirthDate": "1875-00-00", "DeathDate": "1950-00-00", "IsLiving": 0}]}
    return FakeWeb(ents, {"Rae Star": ["Q100"], "Kid Star": ["Q200"], "Private Parent": ["Q201"],
                          "__fulltext__": ["Q100", "Q200"]}, wt, **kw)


def test_planner_structures_goals():
    p = make_plan("Research Young Hollywood actors, investigate their publicly documented ancestors, and find "
                  "possible connections to my GEDCOM family tree.")
    assert p["categories"] == ["young_hollywood"] and p["connect_to_my_tree"]
    agents = [s["agent"] for s in p["steps"]]
    assert "Family Matcher AI" in agents and "Relationship Pathfinder AI" in agents
    assert make_plan('Look up "Rae Star"')["named_people"] == ["Rae Star"]
    assert "minecraft" in make_plan("Find my possible family connections to Minecraft YouTubers.")["categories"]
    assert make_plan("hello")["understood"] is False


def test_wikidata_bce_conversion():
    assert wd_time_to_astronomical("-0044-03-15T00:00:00Z") == -43
    assert wd_time_to_astronomical("+1850-01-01T00:00:00Z") == 1850


def test_full_pipeline_to_connection(family):
    db.set_setting(family, "home_person", "g1:I16")       # Jack Stone, great-grandson of Bob Stone
    web = scenario_web()
    d = make_director(family, web)
    gid = D.create_goal(family, 'Research "Rae Star" and find connections to my family tree', budget=100)
    D.set_goal_status(family, gid, "start")
    drain(d)

    rae = family.execute("SELECT * FROM persons WHERE id='wd:Q100'").fetchone()
    assert rae["is_public_figure"] == 1 and rae["origin"] == "research"
    # Every research relationship keeps a source URL + retrieval date + assessment
    cits = family.execute("""SELECT s.url, s.retrieved_at, c.assessment FROM citations c JOIN sources s ON s.id=c.source_id
                             WHERE c.subject_type='relationship' AND s.connector != 'gedcom'""").fetchall()
    assert cits and all(c["url"] and c["retrieved_at"] and c["assessment"] for c in cits)
    # Tom->Bob asserted by Wikidata AND WikiTree => verified; Rae's parent link only one source => supported
    st = {(r["person_a"], r["person_b"]): r["evidence_status"] for r in
          family.execute("SELECT * FROM relationships WHERE kind='parent' AND person_b IN ('wd:Q100','wd:Q101')")}
    assert st[("wd:Q103", "wd:Q101")] == "verified"
    assert st[("wd:Q101", "wd:Q100")] == "supported"
    # WikiTree living profile (Rae) was not imported as a separate person
    assert family.execute("SELECT COUNT(*) FROM persons WHERE id LIKE 'wt:%'").fetchone()[0] == 0

    match = family.execute("SELECT * FROM discoveries WHERE kind='identity_match'").fetchone()
    assert match is not None
    det = json.loads(match["detail"])
    assert det["research_person"] == "wd:Q103" and det["my_person"] == "g1:I3"
    # Nothing connects until the human confirms the identity match
    assert family.execute("SELECT COUNT(*) FROM discoveries WHERE kind='connection'").fetchone()[0] == 0

    D.accept_identity_match(family, match["id"])
    drain(d)
    conn_d = family.execute("SELECT * FROM discoveries WHERE kind='connection'").fetchone()
    assert conn_d is not None
    res = json.loads(conn_d["detail"])["result"]
    assert res["relationship"] == "1st cousin once removed"   # Jack(3 up) vs Rae(2 up) via Bob Stone
    assert conn_d["title"].startswith("Candidate")              # Rae's own parent link is single-source
    assert family.execute("SELECT status FROM goals WHERE id=?", (gid,)).fetchone()[0] == "completed"


def test_privacy_blocks_minors_and_private_living(conn):
    web = scenario_web()
    d = make_director(conn, web)
    gid = D.create_goal(conn, 'Research "Kid Star" and "Private Parent"')
    D.set_goal_status(conn, gid, "start")
    drain(d)
    assert conn.execute("SELECT COUNT(*) FROM persons").fetchone()[0] == 0
    msgs = [r[0] for r in conn.execute("SELECT message FROM activity WHERE level='warn'")]
    assert any("minor" in m for m in msgs)
    assert any("No public record found for 'Private Parent'" in m for m in msgs)   # private people aren't even matched


def test_blocked_source_not_bypassed(conn):
    web = scenario_web(status_override={"wbsearchentities": 403})
    d = make_director(conn, web)
    gid = D.create_goal(conn, 'Research "Rae Star"')
    D.set_goal_status(conn, gid, "start")
    drain(d)
    assert conn.execute("SELECT COUNT(*) FROM activity WHERE level='blocked'").fetchone()[0] == 1
    assert conn.execute("SELECT status FROM jobs WHERE kind='lookup_name'").fetchone()[0] == "failed"
    assert sum("wbsearchentities" in u for u in web.calls) == 1   # no retry hammering


def test_budget_pauses_goal_and_resumes(family):
    web = scenario_web()
    d = make_director(family, web)
    gid = D.create_goal(family, 'Research "Rae Star"', budget=2)
    D.set_goal_status(family, gid, "start")
    drain(d)
    g = family.execute("SELECT status, spent FROM goals WHERE id=?", (gid,)).fetchone()
    assert g["status"] == "paused" and g["spent"] == 2
    family.execute("UPDATE goals SET budget=100, status='active' WHERE id=?", (gid,))
    family.execute("UPDATE jobs SET run_after=datetime('now') WHERE status='queued'")
    drain(d)
    assert family.execute("SELECT COUNT(*) FROM persons WHERE id='wd:Q100'").fetchone()[0] == 1


def test_category_discovery_and_stop(conn):
    web = scenario_web()
    d = make_director(conn, web)
    gid = D.create_goal(conn, "Find my possible family connections to Minecraft YouTubers")
    D.set_goal_status(conn, gid, "start")
    d.run_one()   # plan
    d.run_one()   # discover -> research jobs queued
    assert conn.execute("SELECT COUNT(*) FROM jobs WHERE kind='research_person' AND status='queued'").fetchone()[0] == 2
    D.set_goal_status(conn, gid, "stop")
    assert d.run_one() is False
    assert conn.execute("SELECT COUNT(*) FROM jobs WHERE status='cancelled'").fetchone()[0] == 2


def test_creator_handles_from_plain_list_and_exact_match(conn):
    plan = make_plan("I want to research YouTubers like Ldshadowlady, JumperWho, MinuteTech, and more")
    assert plan["named_people"] == ["Ldshadowlady", "JumperWho", "MinuteTech"]

    def creator(qid, label, aliases, birth_name=None):
        e = wd_entity(qid, label, born="+1993-01-01T00:00:00Z", sex="F")
        e["aliases"] = {"en": [{"value": a} for a in aliases]}
        e["claims"]["P2397"] = [{"mainsnak": {"snaktype": "value", "datavalue": {"value": "UC" + qid}}, "rank": "normal"}]
        if birth_name:
            e["claims"]["P1477"] = [{"mainsnak": {"snaktype": "value", "datavalue": {"value": {"text": birth_name}}}, "rank": "normal"}]
        return e

    web = FakeWeb({"Q1": creator("Q1", "Decoy Gamer", ["SomeoneElse"]),
                   "Q2": creator("Q2", "TestHandle", ["Test Handle"], birth_name="Liz Example")},
                  {"TestHandle": ["Q1", "Q2"], "UnknownCreator": ["Q1"]})
    d = make_director(conn, web)
    gid = D.create_goal(conn, 'Research "TestHandle" and "UnknownCreator"')
    D.set_goal_status(conn, gid, "start")
    drain(d)
    p = conn.execute("SELECT * FROM persons WHERE id='wd:Q2'").fetchone()
    assert (p["given_name"], p["surname"]) == ("Liz", "Example")
    assert conn.execute("SELECT COUNT(*) FROM persons WHERE id='wd:Q1'").fetchone()[0] == 0   # decoy never chosen
    assert conn.execute("SELECT COUNT(*) FROM universe_members WHERE universe_id='minecraft' AND person_id='wd:Q2'").fetchone()[0] == 1
    assert conn.execute("SELECT COUNT(*) FROM discoveries WHERE title LIKE 'No public record found for UnknownCreator'").fetchone()[0] == 1
