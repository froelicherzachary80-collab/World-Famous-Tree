"""Privacy rules enforced on everything research agents bring in.

* Living people who are not public figures are never imported from research.
* Minors (under 18) are never imported from research, public figure or not.
* Contact details / addresses are never requested or stored (connectors only
  ask for genealogical properties), and are scrubbed if they slip through.
"""
from __future__ import annotations

import re
from typing import Optional

from .store import current_year, presumed_living

FORBIDDEN_KEYS = {"address", "residence", "email", "phone", "telephone", "contact", "street",
                  "postal_code", "coordinates", "home"}
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
_PHONE = re.compile(r"\+?\d[\d\s().-]{7,}\d")


def is_minor(birth_year: Optional[int]) -> bool:
    return birth_year is not None and current_year() - birth_year < 18


def may_import(candidate: dict) -> tuple[bool, str]:
    """candidate: {birth_year, death_year, is_public_figure}"""
    by, dy = candidate.get("birth_year"), candidate.get("death_year")
    living = presumed_living(by, dy is not None)
    if living and is_minor(by):
        return False, "living minor — never imported"
    if living and by is None and not candidate.get("is_public_figure"):
        return False, "living status unknown and not a public figure"
    if living and not candidate.get("is_public_figure"):
        return False, "living private individual — not imported"
    return True, "ok"


def scrub(record: dict) -> dict:
    out = {}
    for k, v in record.items():
        if any(f in k.lower() for f in FORBIDDEN_KEYS):
            continue
        if isinstance(v, str):
            v = _PHONE.sub("[removed]", _EMAIL.sub("[removed]", v))
        out[k] = v
    return out
