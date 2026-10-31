import pytest

from worldtree import store
from worldtree.relationships import find_connection, label

from conftest import pid

# (A, B, expected kind, expected label of B relative to A)
EXPECTED = [
    ("I3", "I4", "blood", "sister"),
    ("I3", "I6", "blood", "half-brother"),
    ("I8", "I11", "blood", "1st cousin"),
    ("I13", "I15", "blood", "2nd cousin"),
    ("I15", "I16", "blood", "2nd cousin once removed"),
    ("I11", "I13", "blood", "1st cousin once removed"),
    ("I8", "I4", "blood", "aunt"),
    ("I4", "I8", "blood", "nephew"),
    ("I16", "I1", "blood", "2nd great-grandfather"),
    ("I1", "I16", "blood", "2nd great-grandson"),
    ("I13", "I1", "blood", "great-grandfather"),
    ("I8", "I19", "blood", "half-1st cousin"),
    ("I16", "I4", "blood", "2nd great-aunt"),
    ("I3", "I5", "marriage", "stepmother"),
    ("I22", "I23", "adoptive", "adoptive sister"),
    ("I12", "I3", "marriage", "father-in-law"),
    ("I3", "I12", "marriage", "daughter-in-law"),
    ("I3", "I7", "marriage", "wife"),
    ("I16", "I22", "none", "NO VERIFIED CONNECTION FOUND — RESEARCH CONTINUES"),
]


@pytest.mark.parametrize("a,b,kind,rel", EXPECTED)
def test_expected_relationships(family, a, b, kind, rel):
    r = find_connection(store.load_graph(family), pid(a), pid(b))
    assert r["kind"] == kind
    assert r["relationship"] == rel


def test_cousin_degree_and_removal_numbers(family):
    r = find_connection(store.load_graph(family), pid("I15"), pid("I16"))
    p = r["primary"]
    assert (p["cousin_degree"], p["removed"], p["generations_a"], p["generations_b"]) == (2, 1, 3, 4)
    assert {c["name"] for c in p["common_ancestors"]} == {"Adam Stone", "Eve Hill"}
    assert p["half"] is False
    assert p["explanation"].startswith("Ivy Webb's mother is Gina Moss")


def test_marriage_never_counted_as_blood(family):
    r = find_connection(store.load_graph(family), pid("I3"), pid("I5"))
    assert r["kind"] == "marriage" and r["primary"]["common_ancestors"] == []


def test_uncertain_path_flagged(family):
    family.execute("UPDATE relationships SET evidence_status='candidate' WHERE person_a='g1:I4' AND person_b='g1:I11'")
    r = find_connection(store.load_graph(family), pid("I8"), pid("I11"))
    assert r["primary"]["uncertain"] is True and r["primary"]["weakest_evidence"] == "candidate"


def test_rejected_edges_ignored(family):
    family.execute("UPDATE relationships SET evidence_status='rejected' WHERE person_b='g1:I11'")
    r = find_connection(store.load_graph(family), pid("I8"), pid("I11"))
    assert r["kind"] == "none"


def test_double_cousins_report_multiple_paths(conn):
    # Two brothers marry two sisters -> children are double first cousins.
    for p, sex in [("A", "M"), ("B", "F"), ("C", "M"), ("D", "F"), ("b1", "M"), ("b2", "M"), ("s1", "F"), ("s2", "F"),
                   ("x", "M"), ("y", "F")]:
        store.upsert_person(conn, p, given_name=p, sex=sex)
    store.add_spouse_edge(conn, "A", "B")
    store.add_spouse_edge(conn, "C", "D")
    for parent in ("A", "B"):
        store.add_parent_edge(conn, parent, "b1"); store.add_parent_edge(conn, parent, "b2")  # noqa: E702
    for parent in ("C", "D"):
        store.add_parent_edge(conn, parent, "s1"); store.add_parent_edge(conn, parent, "s2")  # noqa: E702
    for parent, child in (("b1", "x"), ("s1", "x"), ("b2", "y"), ("s2", "y")):
        store.add_parent_edge(conn, parent, child)
    r = find_connection(store.load_graph(conn), "x", "y")
    assert r["relationship"] == "1st cousin"
    assert len(r["primary"]["common_ancestors"]) == 4  # both grandparent couples


def test_labels_far():
    assert label(6, 9) == "5th cousin 3 times removed"
    assert label(11, 12) == "10th cousin once removed"
    assert label(5, 0, "F") == "3rd great-grandmother"
    assert label(1, 4, "M") == "2nd great-nephew"
