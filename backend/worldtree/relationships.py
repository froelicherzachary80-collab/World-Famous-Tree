"""Relationship Pathfinder.

Blood relationships are computed from common ancestors (cousin degree =
min(gA, gB) - 1, removal = |gA - gB|). Marriage links are never treated as
shared ancestry; they are only used when no blood/adoptive path exists.
"""
from __future__ import annotations

from collections import deque
from typing import Optional

from .store import Graph

BIOLOGICAL = {"birth", "unknown"}
LEGAL = BIOLOGICAL | {"adopted"}
STATUS_RANK = {"verified": 5, "user_provided": 5, "supported": 4, "candidate": 2, "disputed": 1, "legendary": 0}


def ordinal(n: int) -> str:
    suffix = "th" if 10 <= n % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")
    return f"{n}{suffix}"


def times(n: int) -> str:
    return {1: "once", 2: "twice"}.get(n, f"{n} times")


def _gendered(sex: str, m: str, f: str, n: str) -> str:
    return m if sex == "M" else f if sex == "F" else n


def _greats(n: int, base: str) -> str:
    if n <= 0:
        return base
    if n == 1:
        return f"great-{base}"
    return f"{ordinal(n)} great-{base}"


def label(g_a: int, g_b: int, sex_b: str = "U", half: bool = False) -> str:
    """Name what B is to A, given generations from A and from B up to the common ancestor."""
    h = "half-" if half else ""
    if g_a == 0 and g_b == 0:
        return "same person"
    if g_b == 0:
        base = _gendered(sex_b, "father", "mother", "parent")
        if g_a == 1:
            return base
        return _greats(g_a - 2, "grand" + base)
    if g_a == 0:
        base = _gendered(sex_b, "son", "daughter", "child")
        if g_b == 1:
            return base
        return _greats(g_b - 2, "grand" + base)
    if g_a == 1 and g_b == 1:
        return h + _gendered(sex_b, "brother", "sister", "sibling")
    if g_b == 1:
        return h + _greats(g_a - 2, _gendered(sex_b, "uncle", "aunt", "aunt/uncle"))
    if g_a == 1:
        return h + _greats(g_b - 2, _gendered(sex_b, "nephew", "niece", "niece/nephew"))
    degree, removed = min(g_a, g_b) - 1, abs(g_a - g_b)
    s = f"{h}{ordinal(degree)} cousin"
    return s + (f" {times(removed)} removed" if removed else "")


def _ancestor_paths(g: Graph, start: str, allowed: set[str]) -> dict[str, list[str]]:
    """BFS upward. Returns ancestor -> shortest path [start, ..., ancestor] (includes self at 0)."""
    paths = {start: [start]}
    q = deque([start])
    while q:
        cur = q.popleft()
        for e in g.parents.get(cur, []):
            if e.pedigree in allowed and e.other not in paths:
                paths[e.other] = paths[cur] + [e.other]
                q.append(e.other)
    return paths


def _edge_status(g: Graph, a: str, b: str) -> str:
    for e in g.parents.get(a, []) + g.children.get(a, []) + g.spouses.get(a, []):
        if e.other == b:
            return e.status
    return "candidate"


def _evidence(g: Graph, path: list[str]) -> tuple[str, bool]:
    worst = "verified"
    for x, y in zip(path, path[1:]):
        s = _edge_status(g, x, y)
        if STATUS_RANK.get(s, 2) < STATUS_RANK.get(worst, 5):
            worst = s
    # Only user-provided or independently verified links count as certain.
    return worst, STATUS_RANK.get(worst, 2) < 5


def _step_text(g: Graph, x: str, y: str) -> str:
    sex = g.persons[y]["sex"] if y in g.persons else "U"
    if any(e.other == y for e in g.parents.get(x, [])):
        ped = next(e.pedigree for e in g.parents[x] if e.other == y)
        rel = _gendered(sex, "father", "mother", "parent")
        rel = f"{'adoptive ' if ped == 'adopted' else 'step-' if ped == 'step' else ''}{rel}"
    elif any(e.other == y for e in g.children.get(x, [])):
        rel = _gendered(sex, "son", "daughter", "child")
    else:
        rel = _gendered(sex, "husband", "wife", "spouse")
    return f"{g.name(x)}'s {rel} is {g.name(y)}"


def explain(g: Graph, path: list[str]) -> str:
    return "; ".join(_step_text(g, x, y) for x, y in zip(path, path[1:])) + "." if len(path) > 1 else ""


def _blood(g: Graph, a: str, b: str, allowed: set[str]) -> list[dict]:
    pa, pb = _ancestor_paths(g, a, allowed), _ancestor_paths(g, b, allowed)
    common = set(pa) & set(pb)
    if not common:
        return []
    # Keep only "lowest" common ancestors: not an ancestor of another common ancestor.
    # (If c were above another common ancestor, the child of c on that line is also common.)
    lowest = {c for c in common
              if not any(e.other in common and e.pedigree in allowed for e in g.children.get(c, []))}
    groups: dict[tuple[int, int], list[str]] = {}
    for c in lowest:
        groups.setdefault((len(pa[c]) - 1, len(pb[c]) - 1), []).append(c)
    results = []
    for (ga, gb), cas in sorted(groups.items(), key=lambda kv: kv[0][0] + kv[0][1]):
        couple = len(cas) >= 2 and any(e.other in cas for c in cas for e in g.spouses.get(c, []))
        ca = cas[0]
        half = False
        if ga > 0 and gb > 0 and not couple:
            # "Half" only when both lines document a *different* second parent; if the other
            # parent is simply unknown we do not claim half-relationship.
            ka, kb = pa[ca][-2], pb[ca][-2]
            oa = {e.other for e in g.parents.get(ka, []) if e.pedigree in allowed} - {ca}
            ob = {e.other for e in g.parents.get(kb, []) if e.pedigree in allowed} - {ca}
            half = bool(oa) and bool(ob) and not (oa & ob)
        sex_b = g.persons[b]["sex"]
        path = pa[ca] + list(reversed(pb[ca]))[1:]
        worst, uncertain = _evidence(g, path)
        results.append({
            "relationship": label(ga, gb, sex_b, half),
            "generations_a": ga, "generations_b": gb,
            "cousin_degree": min(ga, gb) - 1 if ga >= 2 and gb >= 2 else None,
            "removed": abs(ga - gb) if ga >= 2 and gb >= 2 else None,
            "half": half,
            "common_ancestors": [{"id": c, "name": g.name(c)} for c in cas],
            "path": path, "path_names": [g.name(p) for p in path],
            "explanation": explain(g, path),
            "weakest_evidence": worst, "uncertain": uncertain,
        })
    return results


def _shortest_any(g: Graph, a: str, b: str) -> Optional[list[str]]:
    prev = {a: None}
    q = deque([a])
    while q:
        cur = q.popleft()
        if cur == b:
            break
        for e in g.parents.get(cur, []) + g.children.get(cur, []) + g.spouses.get(cur, []):
            if e.other not in prev:
                prev[e.other] = cur
                q.append(e.other)
    if b not in prev:
        return None
    path, cur = [], b
    while cur is not None:
        path.append(cur)
        cur = prev[cur]
    return path[::-1]


def _is_spouse(g: Graph, x: str, y: str) -> bool:
    return any(e.other == y for e in g.spouses.get(x, []))


def _marriage(g: Graph, a: str, b: str) -> Optional[dict]:
    path = _shortest_any(g, a, b)
    if not path:
        return None
    sex_b = g.persons[b]["sex"]
    spouse_idx = [i for i, (x, y) in enumerate(zip(path, path[1:])) if _is_spouse(g, x, y)]
    rel = "relative by marriage"
    if len(spouse_idx) == 1:
        i = spouse_idx[0]
        c, d = path[i], path[i + 1]
        if c == a and d == b:
            rel = _gendered(sex_b, "husband", "wife", "spouse")
        elif c == a:  # B is a blood relative of A's spouse
            inner = (_blood(g, d, b, BIOLOGICAL) or [{}])[0].get("relationship", "")
            rel = {"father": "father-in-law", "mother": "mother-in-law", "parent": "parent-in-law",
                   "brother": "brother-in-law", "sister": "sister-in-law", "sibling": "sibling-in-law",
                   "son": "stepson", "daughter": "stepdaughter", "child": "stepchild"}.get(inner, f"spouse's {inner}" if inner else rel)
        elif d == b:  # B is the spouse of A's blood relative
            inner = (_blood(g, a, c, BIOLOGICAL) or [{}])[0].get("relationship", "")
            if inner in ("father", "mother", "parent"):
                rel = _gendered(sex_b, "stepfather", "stepmother", "step-parent")
            elif inner.endswith(("brother", "sister", "sibling")):
                rel = _gendered(sex_b, "brother-in-law", "sister-in-law", "sibling-in-law")
            elif inner in ("son", "daughter", "child"):
                rel = _gendered(sex_b, "son-in-law", "daughter-in-law", "child-in-law")
            elif inner:
                rel = f"spouse of {inner}"
    worst, uncertain = _evidence(g, path)
    return {"relationship": rel, "path": path, "path_names": [g.name(p) for p in path],
            "explanation": explain(g, path), "weakest_evidence": worst, "uncertain": uncertain,
            "common_ancestors": [], "half": False, "cousin_degree": None, "removed": None}


def find_connection(g: Graph, a: str, b: str) -> dict:
    if a not in g.persons or b not in g.persons:
        raise KeyError("unknown person")
    if a == b:
        return {"kind": "self", "relationship": "same person", "paths": []}
    blood = _blood(g, a, b, BIOLOGICAL)
    if blood:
        return {"kind": "blood", "relationship": blood[0]["relationship"], "primary": blood[0],
                "alternatives": blood[1:], "paths": blood}
    adoptive = _blood(g, a, b, LEGAL)
    if adoptive:
        for r in adoptive:
            r["relationship"] = "adoptive " + r["relationship"]
        return {"kind": "adoptive", "relationship": adoptive[0]["relationship"], "primary": adoptive[0],
                "alternatives": adoptive[1:], "paths": adoptive}
    m = _marriage(g, a, b)
    if m:
        return {"kind": "marriage", "relationship": m["relationship"], "primary": m, "alternatives": [], "paths": [m],
                "note": "Connected by marriage only — no shared ancestry."}
    return {"kind": "none", "relationship": "NO VERIFIED CONNECTION FOUND — RESEARCH CONTINUES", "paths": []}
