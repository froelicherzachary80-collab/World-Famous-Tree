from worldtree import dates, gedcom, store
from worldtree.dates import parse_date


def test_parse_synthetic(gedcom_text):
    r = gedcom.parse(gedcom_text)
    assert r.valid and r.version == "5.5.1"
    assert len(r.persons) == 27 and len(r.families) == 9 and "@S1@" in r.sources
    john = r.persons["@I25@"]
    assert (john.given, john.surname) == ("John", "Smith")
    assert ("Johann", "Schmidt", "birth") in john.alt_names
    assert r.persons["@I27@"].notes[0] == "Test record for BCE date handling.\nSecond line of the note."
    assert r.persons["@I22@"].famc == [("@F9@", "adopted")]
    assert r.families["@F9@"].divorced == "1960"
    assert r.persons["@I1@"].citations[0].page == "p. 3"
    assert r.warnings == []


def test_import_preserves_and_flags_living(family):
    c = family
    jack = c.execute("SELECT * FROM persons WHERE id='g1:I16'").fetchone()
    assert jack["is_living"] == 1           # born 1950, no death
    adam = c.execute("SELECT * FROM persons WHERE id='g1:I1'").fetchone()
    assert adam["is_living"] == 0 and adam["birth_year"] == 1850
    ped = c.execute("SELECT pedigree FROM relationships WHERE person_b='g1:I22' AND kind='parent'").fetchall()
    assert {p[0] for p in ped} == {"adopted"}
    assert c.execute("SELECT COUNT(*) FROM citations").fetchone()[0] >= 2
    assert c.execute("SELECT ended FROM relationships WHERE kind='spouse' AND family_id='g1:F9'").fetchone()[0] == "1960"


def test_second_import_does_not_collide(family, gedcom_text):
    rep = store.import_gedcom(family, gedcom_text)
    assert rep.batch == "g2" and rep.people == 27
    assert family.execute("SELECT COUNT(*) FROM persons").fetchone()[0] == 54


def test_malformed_and_broken_refs():
    r = gedcom.parse("0 HEAD\nthis is junk\n0 @I1@ INDI\n1 NAME A /B/\n1 FAMC @F99@\n")
    assert r.valid
    assert any("unparseable" in w for w in r.warnings)
    assert any("TRLR" in w for w in r.warnings)
    assert any("@F99@" in w for w in r.warnings)


def test_empty_file_is_error():
    assert not gedcom.parse("").valid
    assert not gedcom.parse("0 HEAD\n0 TRLR\n").valid


def test_gedcom7_and_bom():
    text = "\ufeff0 HEAD\n1 GEDC\n2 VERS 7.0\n0 @I1@ INDI\n1 NAME Ana /Ruiz/\n1 BIRT\n2 DATE 500 BCE\n0 TRLR\n"
    r = gedcom.parse(text.encode("utf-8-sig"))
    assert r.version == "7.0"
    assert dates.year_of(r.persons["@I1@"].birth.date) == -499


def test_dates_astronomical():
    assert parse_date("1 BC").year == 0
    assert parse_date("44 B.C.").year == -43
    assert parse_date("4000 BCE").year == -3999
    assert dates.format_year(-3999) == "4000 BCE"
    assert dates.format_year(0) == "1 BCE"
    d = parse_date("BET 1800 AND 1810")
    assert (d.qualifier, d.year, d.end_year) == ("between", 1800, 1810)
    d = parse_date("ABT 12 MAR 1850")
    assert (d.qualifier, d.day, d.month, d.year) == ("about", 12, 3, 1850)
    assert parse_date("1700/01").year == 1700
    assert parse_date("") is None
    # Ages across the era boundary: born 10 BCE, died 10 CE => 19 years (no year zero historically)
    assert parse_date("10") .year - parse_date("10 BC").year == 19
