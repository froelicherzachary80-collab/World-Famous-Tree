"""Genealogical date handling with astronomical year numbering.

Astronomical years: 1 BC == 0, 2 BC == -1, 44 BC == -43, 4000 BC == -3999.
This keeps arithmetic (ages, generation gaps) correct across the BCE/CE boundary.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

MONTHS = {m: i + 1 for i, m in enumerate(
    ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"])}
QUALIFIERS = {"ABT": "about", "ABOUT": "about", "CIRCA": "about", "CA": "about", "C": "about",
              "EST": "estimated", "CAL": "calculated", "BEF": "before", "AFT": "after"}
_BCE_RE = re.compile(r"\s*(B\.?\s?C\.?\s?E?\.?|BCE)\s*$", re.I)


@dataclass(frozen=True)
class GenDate:
    qualifier: str = "exact"          # exact|about|estimated|calculated|before|after|between|from_to
    year: Optional[int] = None        # astronomical
    month: Optional[int] = None
    day: Optional[int] = None
    end_year: Optional[int] = None    # for between / from-to ranges
    original: str = ""

    @property
    def sort_year(self) -> Optional[int]:
        return self.year

    def display(self) -> str:
        if self.year is None:
            return self.original
        prefix = {"about": "c. ", "estimated": "est. ", "calculated": "calc. ",
                  "before": "before ", "after": "after "}.get(self.qualifier, "")
        if self.qualifier in ("between", "from_to") and self.end_year is not None:
            return f"{format_year(self.year)}–{format_year(self.end_year)}"
        parts = []
        if self.day:
            parts.append(str(self.day))
        if self.month:
            parts.append(list(MONTHS)[self.month - 1].title())
        parts.append(format_year(self.year))
        return prefix + " ".join(parts)


def historical_to_astronomical(year: int, bce: bool) -> int:
    if year <= 0:
        raise ValueError("historical years start at 1")
    return 1 - year if bce else year


def astronomical_to_historical(year: int) -> tuple[int, bool]:
    return (1 - year, True) if year <= 0 else (year, False)


def format_year(year: int) -> str:
    y, bce = astronomical_to_historical(year)
    return f"{y} BCE" if bce else str(y)


def _parse_simple(text: str) -> tuple[Optional[int], Optional[int], Optional[int]]:
    text = text.strip().upper()
    bce = False
    if _BCE_RE.search(text):
        bce = True
        text = _BCE_RE.sub("", text)
    # Dual dating "1700/01": keep the first year.
    text = re.sub(r"(\d+)/\d+", r"\1", text).strip()
    if re.fullmatch(r"-\d+", text):          # already astronomical
        return int(text), None, None
    day = month = year = None
    seen_month = False
    for tok in text.replace(",", " ").split():
        tok = tok.rstrip(".")
        if tok[:3] in MONTHS and tok.isalpha():
            month = MONTHS[tok[:3]]
            seen_month = True
        elif tok.isdigit():
            n = int(tok)
            if not seen_month and day is None and year is None and n <= 31 and len(tok) <= 2 \
                    and any(t.rstrip(".")[:3] in MONTHS for t in text.split()):
                day = n
            else:
                year = n
    if year is not None:
        year = historical_to_astronomical(year, bce) if year > 0 else None
    return year, month, day


def parse_date(text: Optional[str]) -> Optional[GenDate]:
    """Parse GEDCOM 5.5.1 / 7 date values and common free text."""
    if not text or not text.strip():
        return None
    raw = text.strip()
    up = raw.upper().replace("@#DGREGORIAN@", "").replace("@#DJULIAN@", "").strip()
    up = re.sub(r"^(GREGORIAN|JULIAN)\s+", "", up)
    m = re.match(r"^(BET|FROM)\s+(.+?)\s+(AND|TO)\s+(.+)$", up)
    if m:
        y1, _, _ = _parse_simple(m.group(2))
        y2, _, _ = _parse_simple(m.group(4))
        return GenDate("between" if m.group(1) == "BET" else "from_to", y1, None, None, y2, raw)
    m = re.match(r"^(FROM|TO)\s+(.+)$", up)
    if m:
        y, mo, d = _parse_simple(m.group(2))
        return GenDate("after" if m.group(1) == "FROM" else "before", y, mo, d, None, raw)
    first, _, rest = up.partition(" ")
    qualifier = QUALIFIERS.get(first.rstrip("."))
    body = rest if qualifier else up
    if up.startswith("(") or up.startswith("INT "):
        inner = re.sub(r"^INT\s+", "", up)
        inner = re.sub(r"\(.*\)", "", inner).strip()
        y, mo, d = _parse_simple(inner) if inner else (None, None, None)
        return GenDate("exact" if y is not None else "phrase", y, mo, d, None, raw)
    y, mo, d = _parse_simple(body)
    return GenDate(qualifier or "exact", y, mo, d, None, raw)


def year_of(text: Optional[str]) -> Optional[int]:
    d = parse_date(text)
    return d.year if d else None
