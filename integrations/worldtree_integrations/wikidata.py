"""Wikidata connector (CC0 data, public API). Pulls genealogical properties only."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from .base import HttpClient, PersonRecord

API = "https://www.wikidata.org/w/api.php"
SPARQL = "https://query.wikidata.org/sparql"

REL_PROPS = {"P22": "father", "P25": "mother", "P40": "child", "P26": "spouse", "P3373": "sibling"}
GENDER = {"Q6581097": "M", "Q6581072": "F", "Q2449503": "M", "Q1052281": "F"}
P_WIKITREE = "P2949"
CREATOR_OCCUPATIONS = {"Q17125263", "Q57414145", "Q15077007", "Q94791573", "Q2626540"}  # YouTuber, streamer, ...


def _norm(s: str) -> str:
    return "".join(ch for ch in s.lower() if ch.isalnum())


def choose_creator(handle: str, records: list) -> "PersonRecord | None":
    """Exact handle/label/alias match among content creators only — never a 'closest' guess."""
    h = _norm(handle)
    for r in records:
        if r.is_creator and h in {_norm(x) for x in [r.name, *r.aliases]}:
            return r
    return None
CATEGORIES_FILE = Path(__file__).with_name("discovery_categories.json")


def wd_time_to_astronomical(t: str) -> Optional[int]:
    """Wikidata '+1850-03-12T00:00:00Z' / '-0044-03-15T00:00:00Z'. Wikidata BCE years have no
    year zero (-0044 == 44 BC), so astronomical = year + 1 for negatives."""
    if not t:
        return None
    sign = -1 if t.startswith("-") else 1
    try:
        y = int(t.lstrip("+-").split("-")[0])
    except ValueError:
        return None
    if y == 0:
        return None
    return y if sign > 0 else 1 - y


def _claims(entity: dict, prop: str) -> list[dict]:
    return [c for c in entity.get("claims", {}).get(prop, []) if c.get("mainsnak", {}).get("snaktype") == "value"]


def _item_ids(entity: dict, prop: str) -> list[tuple[str, bool]]:
    out = []
    for c in _claims(entity, prop):
        if c.get("rank") == "deprecated":
            continue
        v = c["mainsnak"]["datavalue"]["value"]
        if isinstance(v, dict) and "id" in v:
            out.append((v["id"], bool(c.get("references"))))
    return out


def _time(entity: dict, prop: str) -> tuple[Optional[int], Optional[str]]:
    for c in _claims(entity, prop):
        v = c["mainsnak"]["datavalue"]["value"]
        return wd_time_to_astronomical(v.get("time", "")), v.get("time")
    return None, None


class WikidataConnector:
    id = "wikidata"

    def __init__(self, client: Optional[HttpClient] = None):
        self.http = client or HttpClient("wikidata", per_second=2.0)
        self._labels: dict[str, str] = {}

    def search(self, query: str, limit: int = 10) -> list[str]:
        data = self.http.get_json(API, {"action": "wbsearchentities", "search": query, "language": "en",
                                        "type": "item", "limit": limit, "format": "json"})
        return [r["id"] for r in data.get("search", [])]

    def fulltext(self, query: str, limit: int = 25) -> list[str]:
        data = self.http.get_json(API, {"action": "query", "list": "search", "srsearch": query,
                                        "srlimit": limit, "format": "json"})
        return [r["title"] for r in data.get("query", {}).get("search", []) if r["title"].startswith("Q")]

    def sparql_ids(self, query: str) -> list[str]:
        data = self.http.get_json(SPARQL, {"query": query, "format": "json"})
        ids = []
        for b in data.get("results", {}).get("bindings", []):
            uri = b.get("item", {}).get("value", "")
            if uri.rsplit("/", 1)[-1].startswith("Q"):
                ids.append(uri.rsplit("/", 1)[-1])
        return list(dict.fromkeys(ids))

    def discover(self, category: str, limit: int = 25) -> list[str]:
        cats = json.loads(CATEGORIES_FILE.read_text())
        spec = cats.get(category)
        if not spec:
            raise KeyError(f"unknown category {category}")
        if spec["method"] == "fulltext":
            return self.fulltext(spec["query"], limit)
        return self.sparql_ids(spec["query"].replace("{LIMIT}", str(limit)))[:limit]

    def entities(self, ids: list[str]) -> dict[str, dict]:
        out = {}
        for i in range(0, len(ids), 50):
            data = self.http.get_json(API, {"action": "wbgetentities", "ids": "|".join(ids[i:i + 50]),
                                            "props": "labels|aliases|descriptions|claims|sitelinks", "languages": "en",
                                            "format": "json"})
            out.update(data.get("entities", {}))
        return out

    def labels(self, ids: list[str]) -> dict[str, str]:
        missing = [i for i in ids if i not in self._labels]
        for i in range(0, len(missing), 50):
            data = self.http.get_json(API, {"action": "wbgetentities", "ids": "|".join(missing[i:i + 50]),
                                            "props": "labels", "languages": "en", "format": "json"})
            for k, v in data.get("entities", {}).items():
                self._labels[k] = v.get("labels", {}).get("en", {}).get("value", k)
        return {i: self._labels.get(i, i) for i in ids}

    def to_record(self, qid: str, e: dict) -> PersonRecord:
        name = e.get("labels", {}).get("en", {}).get("value", qid)
        by, bt = _time(e, "P569")
        dy, dt = _time(e, "P570")
        sex = next((GENDER.get(g) for g, _ in _item_ids(e, "P21") if g in GENDER), "U")
        places = [p for p, _ in _item_ids(e, "P19")[:1] + _item_ids(e, "P20")[:1]]
        lab = self.labels(places) if places else {}
        bp = _item_ids(e, "P19")
        dp = _item_ids(e, "P20")
        rec = PersonRecord(
            source="wikidata", external_id=qid, name=name,
            given=name.rsplit(" ", 1)[0] if " " in name else name,
            surname=name.rsplit(" ", 1)[1] if " " in name else "",
            sex=sex, birth_year=by, death_year=dy, birth_date=bt, death_date=dt,
            birth_place=lab.get(bp[0][0]) if bp else None, death_place=lab.get(dp[0][0]) if dp else None,
            description=e.get("descriptions", {}).get("en", {}).get("value", ""),
            # Having an enwiki article is our signal of notability / public-figure status.
            is_public_figure="enwiki" in e.get("sitelinks", {}) or bool(_claims(e, "P2397")),
            url=f"https://www.wikidata.org/wiki/{qid}")
        for prop, rel in REL_PROPS.items():
            ids = _item_ids(e, prop)
            if ids:
                rec.relatives[rel] = ids
        rec.aliases = [a["value"] for a in e.get("aliases", {}).get("en", [])]
        rec.is_creator = bool(_claims(e, "P2397")) or any(o in CREATOR_OCCUPATIONS for o, _ in _item_ids(e, "P106"))
        bn = [c["mainsnak"]["datavalue"]["value"].get("text") for c in _claims(e, "P1477")
              if isinstance(c["mainsnak"]["datavalue"]["value"], dict)]
        if bn and bn[0]:
            rec.birth_name = bn[0]
            parts = bn[0].rsplit(" ", 1)
            rec.given, rec.surname = (parts[0], parts[1]) if len(parts) == 2 else (bn[0], "")
        wt = _claims(e, P_WIKITREE)
        if wt:
            rec.cross_ids["wikitree"] = wt[0]["mainsnak"]["datavalue"]["value"]
        return rec

    def fetch(self, qids: list[str]) -> list[PersonRecord]:
        ents = self.entities(qids)
        return [self.to_record(q, e) for q, e in ents.items() if "missing" not in e
                and any(c["mainsnak"].get("datavalue", {}).get("value", {}).get("id") == "Q5"
                        for c in _claims(e, "P31"))]
