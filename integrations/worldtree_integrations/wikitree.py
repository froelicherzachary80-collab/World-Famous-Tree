"""WikiTree connector — public profiles via the official WikiTree API (no login).
Private WikiTree profiles return limited data and are respected as such."""
from __future__ import annotations

from typing import Optional

from .base import HttpClient, PersonRecord
from worldtree.dates import parse_date

API = "https://api.wikitree.com/api.php"
FIELDS = "Id,Name,FirstName,LastNameAtBirth,LastNameCurrent,Gender,BirthDate,DeathDate,BirthLocation,DeathLocation,Father,Mother,IsLiving,Privacy"


def _year(s: Optional[str]) -> Optional[int]:
    if not s or s.startswith("0000"):
        return None
    d = parse_date(s.split("-")[0])
    return d.year if d else None


class WikiTreeConnector:
    id = "wikitree"

    def __init__(self, client: Optional[HttpClient] = None, app_id: str = "WorldTreeAI"):
        self.http = client or HttpClient("wikitree", per_second=1.0)
        self.app_id = app_id

    def _to_record(self, p: dict, id_map: dict[int, str]) -> PersonRecord:
        name = f"{p.get('FirstName', '')} {p.get('LastNameAtBirth', '')}".strip() or p.get("Name", "")
        rec = PersonRecord(source="wikitree", external_id=p["Name"], name=name,
                           given=p.get("FirstName", ""), surname=p.get("LastNameAtBirth", ""),
                           sex={"Male": "M", "Female": "F"}.get(p.get("Gender", ""), "U"),
                           birth_year=_year(p.get("BirthDate")), death_year=_year(p.get("DeathDate")),
                           birth_date=p.get("BirthDate"), death_date=p.get("DeathDate"),
                           birth_place=p.get("BirthLocation"), death_place=p.get("DeathLocation"),
                           url=f"https://www.wikitree.com/wiki/{p['Name']}")
        for key, rel in (("Father", "father"), ("Mother", "mother")):
            pid = p.get(key)
            if pid and pid in id_map:
                rec.relatives[rel] = [(id_map[pid], True)]
        return rec

    def ancestors(self, wikitree_id: str, depth: int = 4) -> list[PersonRecord]:
        data = self.http.get_json(API, {"action": "getAncestors", "key": wikitree_id, "depth": depth,
                                        "fields": FIELDS, "appId": self.app_id, "format": "json"})
        people = data[0].get("ancestors", []) if isinstance(data, list) and data else []
        id_map = {p["Id"]: p["Name"] for p in people if "Id" in p and "Name" in p}
        return [self._to_record(p, id_map) for p in people if "Name" in p and str(p.get("IsLiving", "0")) != "1"]
