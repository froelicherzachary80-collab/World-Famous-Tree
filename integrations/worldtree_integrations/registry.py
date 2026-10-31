"""Connector registry — honest status of every source named in the spec."""
from __future__ import annotations

from .base import ConnectorInfo

CONNECTORS = [
    ConnectorInfo("wikidata", "Wikidata", "implemented", "CC0 structured data: parents, spouses, children, siblings, dates, places, WikiTree cross-IDs."),
    ConnectorInfo("wikitree", "WikiTree", "implemented", "Official public API (getAncestors). Living/private profiles excluded."),
    ConnectorInfo("familysearch", "FamilySearch", "requires_credentials", "Requires an approved FamilySearch developer app key + user OAuth. Not bypassed."),
    ConnectorInfo("wikipedia", "Wikipedia", "planned", "Biography text as research leads only (never auto-establishes relationships)."),
    ConnectorInfo("chronicling_america", "Chronicling America (LoC)", "planned", "Public newspaper search API; leads only."),
    ConnectorInfo("internet_archive", "Internet Archive", "planned", "Public advancedsearch API for historical books; leads only."),
    ConnectorInfo("nara", "National Archives (NARA)", "planned", "Catalog API requires an API key."),
    ConnectorInfo("findagrave", "Find a Grave", "planned", "No public API; will only be added if an authorized access path exists."),
    ConnectorInfo("youtube", "YouTube metadata/transcripts", "requires_credentials", "Needs your YouTube Data API key; interviews are leads only."),
]


def info() -> list[dict]:
    return [c.__dict__ for c in CONNECTORS]
