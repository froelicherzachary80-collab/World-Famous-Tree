"""Research Planner AI — turns a natural-language instruction into a structured plan.

Deterministic keyword planner by default (free, offline). If an LLM provider is
configured, it may *refine category selection only*; its output is validated
against the fixed category list and can never inject facts.
"""
from __future__ import annotations

import json
import re
from typing import Optional

CATEGORY_KEYWORDS = {
    "minecraft": ["minecraft"],
    "gaming_creators": ["gaming", "gamer", "streamer", "twitch"],
    "young_hollywood": ["young hollywood", "young actor", "young actress", "disney", "nickelodeon", "teen star", "streaming-series", "tv star", "television star"],
    "marvel": ["marvel", "mcu", "avengers"],
    "pop_music": ["pop star", "pop singer", "singer", "musician", "music", "songwriter"],
    "royal": ["royal", "royalty", "king", "queen", "monarch", "nobility", "dynasty", "dynasties"],
    "ancient": ["ancient", "egypt", "rome", "roman", "greece", "greek", "mesopotamia", "pharaoh", "civilization"],
}
UNIVERSE_OF = {"minecraft": "minecraft", "gaming_creators": "minecraft", "young_hollywood": "young_hollywood",
               "marvel": "marvel", "pop_music": "music", "royal": "royal", "ancient": "ancient"}


def keyword_categories(text: str) -> list[str]:
    t = text.lower()
    found = [c for c, kws in CATEGORY_KEYWORDS.items() if any(k in t for k in kws)]
    if "youtuber" in t and not found:
        found.append("gaming_creators")
    return found


def named_people(text: str) -> list[str]:
    # Quoted names: Research "Tom Holland" and "Zendaya"
    names = [m.strip() for m in re.findall(r"[\"“]([^\"”]{2,60})[\"”]", text)]
    # Lists after "like"/"such as": "YouTubers like Ldshadowlady, JumperWho, MinuteTech, and more"
    m = re.search(r"\b(?:like|such as|including)\s+(.+?)(?:\s+with\b|\s+to\b|[.!?]|$)", text, re.I)
    if m:
        for part in re.split(r",|\band\b|&", m.group(1)):
            part = part.strip(" @\"“”")
            if part and part.lower() not in ("more", "others", "etc", "many more") and len(part) <= 40:
                names.append(part)
    return list(dict.fromkeys(names))


def make_plan(instruction: str, llm=None, person_limit: int = 12) -> dict:
    cats = keyword_categories(instruction)
    if llm is not None:
        try:
            refined = llm.choose_categories(instruction, list(CATEGORY_KEYWORDS))
            cats = [c for c in refined if c in CATEGORY_KEYWORDS] or cats
        except Exception:  # noqa: BLE001 — LLM is optional; fall back silently to keywords
            pass
    names = named_people(instruction)
    t = instruction.lower()
    connect = any(k in t for k in ("connection", "connect", "related", "my tree", "my ancestors", "my family", "gedcom"))
    gaps = any(k in t for k in ("missing", "gap", "reconstruct", "unknown parents"))
    steps = []
    for c in cats:
        steps.append({"agent": "Celebrity Research AI", "action": "discover", "category": c,
                      "universe": UNIVERSE_OF[c], "limit": person_limit})
    for n in names:
        steps.append({"agent": "Web Researcher AI", "action": "lookup", "name": n})
    if cats or names:
        steps.append({"agent": "Celebrity Research AI", "action": "expand_ancestry", "generations": 4})
        steps.append({"agent": "Evidence Verification AI", "action": "verify"})
        steps.append({"agent": "Timeline Researcher AI", "action": "check_contradictions"})
    if connect or cats or names:
        steps.append({"agent": "Family Matcher AI", "action": "match_against_my_tree"})
        steps.append({"agent": "Relationship Pathfinder AI", "action": "find_connections"})
    if gaps:
        steps.append({"agent": "Research Planner AI", "action": "analyze_gaps"})
    return {"instruction": instruction, "categories": cats, "named_people": names,
            "connect_to_my_tree": connect or bool(cats or names), "analyze_gaps": gaps,
            "expand_generations": 4, "steps": steps,
            "understood": bool(steps)}


class OpenAICompatibleLLM:
    """Works with any OpenAI-compatible chat endpoint, including a local Ollama
    server (http://localhost:11434/v1) for zero subscription cost."""

    def __init__(self, base_url: str, model: str, api_key: Optional[str] = None, transport=None):
        self.base_url, self.model, self.api_key = base_url.rstrip("/"), model, api_key
        self.transport = transport

    def choose_categories(self, instruction: str, allowed: list[str]) -> list[str]:
        import urllib.request
        body = json.dumps({"model": self.model, "temperature": 0, "messages": [
            {"role": "system", "content": "Return ONLY a JSON array of category ids chosen from: " + ", ".join(allowed)},
            {"role": "user", "content": instruction}]}).encode()
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = urllib.request.Request(self.base_url + "/chat/completions", body, headers)
        with urllib.request.urlopen(req, timeout=60) as r:
            content = json.loads(r.read())["choices"][0]["message"]["content"]
        arr = json.loads(re.search(r"\[.*\]", content, re.S).group(0))
        return [a for a in arr if isinstance(a, str) and a in allowed]
