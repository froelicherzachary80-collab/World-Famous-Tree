import json
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import pytest

from worldtree import db, store

FIX = Path(__file__).parent / "fixtures"


@pytest.fixture
def gedcom_text():
    return (FIX / "synthetic_family.ged").read_text()


@pytest.fixture
def conn():
    c = db.connect(":memory:")
    yield c
    c.close()


@pytest.fixture
def family(conn, gedcom_text):
    rep = store.import_gedcom(conn, gedcom_text)
    assert rep.errors == []
    return conn


def pid(x):
    return f"g1:{x}"


# ---------------------------------------------------------------- fake Wikidata / WikiTree

def wd_entity(qid, name, *, born=None, died=None, sex="M", father=None, mother=None, ref=True,
              enwiki=True, wikitree=None, human=True):
    def item(v, referenced=ref):
        return {"mainsnak": {"snaktype": "value", "datavalue": {"value": {"id": v}}}, "rank": "normal",
                "references": [{"snaks": {}}] if referenced else []}

    def t(v):
        return {"mainsnak": {"snaktype": "value", "datavalue": {"value": {"time": v}}}, "rank": "normal"}

    claims = {"P31": [item("Q5")] if human else [item("Q515")],
              "P21": [item({"M": "Q6581097", "F": "Q6581072"}[sex])]}
    if born:
        claims["P569"] = [t(born)]
    if died:
        claims["P570"] = [t(died)]
    if father:
        claims["P22"] = [item(father)]
    if mother:
        claims["P25"] = [item(mother)]
    if wikitree:
        claims["P2949"] = [{"mainsnak": {"snaktype": "value", "datavalue": {"value": wikitree}}, "rank": "normal"}]
    return {"id": qid, "labels": {"en": {"value": name}}, "descriptions": {"en": {"value": "test person"}},
            "claims": claims, "sitelinks": {"enwiki": {}} if enwiki else {}}


class FakeWeb:
    """Transport that serves canned Wikidata/WikiTree responses and records calls."""

    def __init__(self, entities=None, search=None, wikitree=None, status_override=None):
        self.entities = entities or {}
        self.search = search or {}
        self.wikitree = wikitree or {}
        self.status_override = status_override or {}
        self.calls = []

    def __call__(self, url, headers):
        self.calls.append(url)
        u = urlparse(url)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        for frag, status in self.status_override.items():
            if frag in url:
                return status, b"denied"
        if "wikidata.org/w/api.php" in url:
            if q.get("action") == "wbgetentities":
                ids = q["ids"].split("|")
                return 200, json.dumps({"entities": {i: self.entities.get(i, {"id": i, "missing": ""}) for i in ids}}).encode()
            if q.get("action") == "wbsearchentities":
                return 200, json.dumps({"search": [{"id": i} for i in self.search.get(q["search"], [])]}).encode()
            if q.get("action") == "query":
                return 200, json.dumps({"query": {"search": [{"title": i} for i in self.search.get("__fulltext__", [])]}}).encode()
        if "query.wikidata.org" in url:
            ids = self.search.get("__sparql__", [])
            return 200, json.dumps({"results": {"bindings": [{"item": {"value": f"http://www.wikidata.org/entity/{i}"}} for i in ids]}}).encode()
        if "api.wikitree.com" in url:
            return 200, json.dumps([{"ancestors": self.wikitree.get(q["key"], [])}]).encode()
        return 404, b""
