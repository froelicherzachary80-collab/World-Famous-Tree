import json

from worldtree import duplicates, store
from worldtree.relationships import find_connection


def test_detects_spelling_variant_with_corroboration(family):
    found = duplicates.detect(family)
    pairs = {(d.a, d.b) for d in found}
    assert ("g1:I24", "g1:I25") in pairs           # Jon Smyth ~ John Smith, same dates/place
    assert ("g1:I25", "g1:I26") not in pairs       # same name, 120 years apart
    assert ("g1:I24", "g1:I26") not in pairs
    row = family.execute("SELECT * FROM duplicate_candidates WHERE person_a='g1:I24'").fetchone()
    assert "birthplace matches" in json.loads(row["matches"])


def test_name_alone_never_reaches_threshold(conn):
    store.upsert_person(conn, "a", given_name="Mary", surname="Jones")
    store.upsert_person(conn, "b", given_name="Mary", surname="Jones")
    g = store.load_graph(conn)
    ds = duplicates.score_pair(conn, g, "a", "b")
    assert ds.corroborations == 0 and ds.score < 0.55
    assert duplicates.detect(conn) == []


def test_merge_and_undo_round_trip(family):
    before_edges = family.execute("SELECT COUNT(*) FROM relationships").fetchone()[0]
    store.add_parent_edge(family, "g1:I25", "g1:I26")   # give the dropped record an edge to move
    log_id = duplicates.merge(family, "g1:I24", "g1:I25")
    g = store.load_graph(family)
    assert "g1:I25" not in g.persons
    assert any(e.other == "g1:I26" for e in g.children["g1:I24"])
    alias = family.execute("SELECT * FROM person_names WHERE person_id='g1:I24' AND name_type='merged'").fetchone()
    assert alias["given_name"] == "John"
    duplicates.undo_merge(family, log_id)
    g = store.load_graph(family)
    assert "g1:I25" in g.persons
    assert any(e.other == "g1:I26" for e in g.children["g1:I25"])
    assert "g1:I24" not in g.children
    assert family.execute("SELECT COUNT(*) FROM relationships").fetchone()[0] == before_edges + 1
    assert family.execute("SELECT undone FROM merge_log WHERE id=?", (log_id,)).fetchone()[0] == 1


def test_merge_connects_trees_for_pathfinder(family):
    # A second copy of Carol (no parents) married to someone; merging links her branch to Adam.
    store.upsert_person(family, "x:carol", given_name="Carol", surname="Stone", sex="F", birth_year=1878, death_year=1960)
    store.upsert_person(family, "x:kid", given_name="Zed", surname="Moss", sex="M", birth_year=1905)
    store.add_parent_edge(family, "x:carol", "x:kid")
    duplicates.merge(family, "g1:I4", "x:carol")
    r = find_connection(store.load_graph(family), "g1:I8", "x:kid")
    assert r["relationship"] == "1st cousin"


def test_auto_merge_rules_are_strict():
    ds = duplicates.DupScore("a", "b", 0.97, ["name: exact/near-exact", "birth year identical (1820)",
                                              "death year identical (1888)", "parents match (2)"], [])
    assert not duplicates.auto_merge_allowed(ds, {"enabled": False})
    assert duplicates.auto_merge_allowed(ds, {"enabled": True})
    ds.conflicts.append("birthplace differs")
    assert not duplicates.auto_merge_allowed(ds, {"enabled": True})


def test_phonetics():
    assert duplicates.soundex("Smith") == duplicates.soundex("Smyth") == "S530"
    assert duplicates.jaro_winkler("Martha", "Marhta") > 0.95
