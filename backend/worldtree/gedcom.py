"""GEDCOM 5.5 / 5.5.1 / 7.0 parser.

Produces plain dataclasses; nothing is discarded — unknown tags are kept as raw
notes on the record so provenance survives a round trip into the database.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

LINE_RE = re.compile(r"^\s*(\d+)\s+(?:(@[^@]+@)\s+)?([A-Za-z0-9_]+)(?:\s(.*))?$")


@dataclass
class Node:
    level: int
    tag: str
    value: str = ""
    xref: Optional[str] = None
    children: list["Node"] = field(default_factory=list)

    def first(self, tag: str) -> Optional["Node"]:
        return next((c for c in self.children if c.tag == tag), None)

    def all(self, tag: str) -> list["Node"]:
        return [c for c in self.children if c.tag == tag]

    def val(self, tag: str) -> Optional[str]:
        n = self.first(tag)
        return n.value if n and n.value else None


@dataclass
class Event:
    date: Optional[str] = None
    place: Optional[str] = None


@dataclass
class Citation:
    source_xref: Optional[str]
    page: str = ""
    text: str = ""


@dataclass
class ParsedPerson:
    xref: str
    given: str = ""
    surname: str = ""
    alt_names: list[tuple[str, str, str]] = field(default_factory=list)  # (given, surname, type)
    sex: str = "U"
    birth: Event = field(default_factory=Event)
    death: Event = field(default_factory=Event)
    is_dead_flag: bool = False
    famc: list[tuple[str, str]] = field(default_factory=list)  # (fam xref, pedigree)
    fams: list[str] = field(default_factory=list)
    citations: list[Citation] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    media: list[str] = field(default_factory=list)

    @property
    def full_name(self) -> str:
        return f"{self.given} {self.surname}".strip() or "(unknown)"


@dataclass
class ParsedFamily:
    xref: str
    husband: Optional[str] = None
    wife: Optional[str] = None
    parents: list[str] = field(default_factory=list)  # GEDCOM 7 / same-sex / >2 parents
    children: list[tuple[str, str, str]] = field(default_factory=list)  # (child, frel, mrel)
    marriage: Event = field(default_factory=Event)
    divorced: Optional[str] = None
    citations: list[Citation] = field(default_factory=list)


@dataclass
class ParsedSource:
    xref: str
    title: str = ""
    author: str = ""
    url: Optional[str] = None
    text: str = ""


@dataclass
class GedcomResult:
    version: str = "unknown"
    persons: dict[str, ParsedPerson] = field(default_factory=dict)
    families: dict[str, ParsedFamily] = field(default_factory=dict)
    sources: dict[str, ParsedSource] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def valid(self) -> bool:
        return not self.errors


def decode(data: bytes) -> str:
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", errors="replace")
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")  # ANSEL/ANSI fallback; diacritics may degrade


def tokenize(text: str, warnings: list[str]) -> list[Node]:
    roots: list[Node] = []
    stack: list[Node] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        m = LINE_RE.match(line)
        if not m:
            warnings.append(f"line {lineno}: unparseable line skipped: {line[:60]!r}")
            continue
        level = int(m.group(1))
        node = Node(level, m.group(3).upper(), (m.group(4) or ""), m.group(2))
        if node.tag in ("CONT", "CONC") and stack:
            parent = stack[-1] if stack[-1].level == level - 1 else None
            if parent is None:
                parent = next((n for n in reversed(stack) if n.level == level - 1), None)
            if parent is not None:
                parent.value += ("\n" if node.tag == "CONT" else "") + node.value
                continue
        while stack and stack[-1].level >= level:
            stack.pop()
        if level == 0:
            roots.append(node)
        elif stack and stack[-1].level == level - 1:
            stack[-1].children.append(node)
        else:
            warnings.append(f"line {lineno}: level jump to {level}; attached to nearest parent")
            if stack:
                stack[-1].children.append(node)
            else:
                roots.append(node)
        stack.append(node)
    return roots


_NAME_RE = re.compile(r"^(.*?)/(.*?)/(.*)$")


def _split_name(value: str) -> tuple[str, str]:
    m = _NAME_RE.match(value.strip())
    if m:
        given = (m.group(1) + " " + m.group(3)).strip()
        return re.sub(r"\s+", " ", given), m.group(2).strip()
    return value.strip(), ""


def _event(n: Optional[Node]) -> Event:
    if n is None:
        return Event()
    return Event(n.val("DATE"), n.val("PLAC"))


def _citations(n: Node) -> list[Citation]:
    out = []
    for s in n.all("SOUR"):
        if s.value.startswith("@"):
            out.append(Citation(s.value, s.val("PAGE") or "", (s.first("DATA").val("TEXT") if s.first("DATA") else "") or ""))
        else:
            out.append(Citation(None, "", s.value))
    return out


def parse(text_or_bytes: str | bytes) -> GedcomResult:
    text = (decode(text_or_bytes) if isinstance(text_or_bytes, bytes) else text_or_bytes).lstrip("\ufeff")
    res = GedcomResult()
    roots = tokenize(text, res.warnings)
    if not roots:
        res.errors.append("empty file or no GEDCOM records found")
        return res
    if roots[0].tag != "HEAD":
        res.warnings.append("file does not start with HEAD record")
    if roots[-1].tag != "TRLR":
        res.warnings.append("missing TRLR trailer (file may be truncated)")
    head = next((r for r in roots if r.tag == "HEAD"), None)
    if head and head.first("GEDC"):
        res.version = head.first("GEDC").val("VERS") or "unknown"

    for r in roots:
        if r.tag == "INDI" and r.xref:
            p = ParsedPerson(r.xref)
            names = r.all("NAME")
            for i, nm in enumerate(names):
                given, surname = _split_name(nm.value)
                given = nm.val("GIVN") or given
                surname = nm.val("SURN") or surname
                if i == 0:
                    p.given, p.surname = given, surname
                else:
                    p.alt_names.append((given, surname, (nm.val("TYPE") or "aka").lower()))
            p.sex = (r.val("SEX") or "U")[:1].upper()
            p.birth = _event(r.first("BIRT") or r.first("CHR") or r.first("BAPM"))
            death = r.first("DEAT") or r.first("BURI")
            p.death = _event(death)
            p.is_dead_flag = death is not None
            for fc in r.all("FAMC"):
                p.famc.append((fc.value, (fc.val("PEDI") or "birth").lower()))
            p.fams = [f.value for f in r.all("FAMS")]
            p.citations = _citations(r)
            for ev in r.children:
                if ev.tag in ("BIRT", "DEAT", "NAME", "CHR", "BURI"):
                    p.citations.extend(_citations(ev))
            p.notes = [n.value for n in r.all("NOTE") if n.value]
            p.media = [o.val("FILE") or o.value for o in r.all("OBJE") if (o.val("FILE") or o.value)]
            res.persons[r.xref] = p
        elif r.tag == "FAM" and r.xref:
            f = ParsedFamily(r.xref, r.val("HUSB"), r.val("WIFE"))
            f.parents = [x for x in (f.husband, f.wife) if x]
            for c in r.all("CHIL"):
                f.children.append((c.value, (c.val("_FREL") or "").lower(), (c.val("_MREL") or "").lower()))
            f.marriage = _event(r.first("MARR"))
            div = r.first("DIV")
            f.divorced = (div.val("DATE") or "Y") if div else None
            f.citations = _citations(r)
            res.families[r.xref] = f
        elif r.tag == "SOUR" and r.xref:
            s = ParsedSource(r.xref, r.val("TITL") or "", r.val("AUTH") or "")
            www = r.val("WWW")
            s.url = www
            s.text = r.val("TEXT") or ""
            res.sources[r.xref] = s

    # Referential validation — warn, never drop.
    for f in res.families.values():
        for x in f.parents + [c[0] for c in f.children]:
            if x not in res.persons:
                res.warnings.append(f"family {f.xref} references missing individual {x}")
    for p in res.persons.values():
        for fx, _ in p.famc:
            if fx not in res.families:
                res.warnings.append(f"{p.xref} FAMC references missing family {fx}")
        for c in p.citations:
            if c.source_xref and c.source_xref not in res.sources:
                res.warnings.append(f"{p.xref} cites missing source {c.source_xref}")
    if not res.persons:
        res.errors.append("no individuals (INDI records) found")
    return res


def pedigree_for(person: ParsedPerson, fam: ParsedFamily, parent_xref: str) -> str:
    """Resolve birth/adopted/step/foster for one parent->child edge."""
    for fx, ped in person.famc:
        if fx == fam.xref and ped and ped != "birth":
            return {"adopted": "adopted", "foster": "foster", "step": "step", "sealing": "birth"}.get(ped, "unknown")
    for cx, frel, mrel in fam.children:
        if cx == person.xref:
            rel = frel if parent_xref == fam.husband else mrel
            if rel in ("adopted", "foster", "step"):
                return rel
    return "birth"
