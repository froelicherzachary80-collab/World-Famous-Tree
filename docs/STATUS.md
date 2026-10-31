# Feature status — v1.0.0

Legend: ✅ implemented and covered by automated tests · 🟢 implemented, verified only by compiling in CI ·
🟡 partial · ⏳ not implemented (planned) · ❌ out of scope / not possible as specified

**How this was verified.** The Python backend (52 tests) was run and passes. The Swift code was written
without a local Swift compiler; it is compiled and tested by GitHub Actions on first push. Until that
first CI run is green, treat every Swift item as *written, not yet compiled*.

## Spec section by section

| # | Feature | Status | Notes |
|---|---|---|---|
| 3 | Repo structure, CI, tests, security checks, semantic versioning, release | 🟢 | Workflows validated as YAML; they run on first push |
| 3 | Signed IPA | 🟡 | Only with your Apple signing secrets; otherwise unsigned IPA for Signulous |
| 4 | GEDCOM 5.5/5.5.1/7, alt names, notes (CONT/CONC), sources, PEDI adopted/foster, _FREL/_MREL, divorce, BOM/UTF-16/Latin-1 | ✅ | Both Swift and Python parsers, same fixture |
| 4 | Validation without discarding records | ✅ | Warnings for broken refs, bad lines, missing TRLR |
| 4 | Gap analysis + recommended goals | ✅ | |
| 5 | Durable, resumable job queue independent of the phone | ✅ | SQLite leases, retries with backoff, crash recovery |
| 5 | Strict auto-accept + human review routing | ✅ | 2 independent sources + clean timeline ⇒ verified |
| 6 | Wikidata connector | 🟡 | Implemented + tested against a simulated web; not run against live Wikidata from the build sandbox |
| 6 | WikiTree connector | 🟡 | Same as above |
| 6 | FamilySearch, YouTube | ⏳ | Need your developer keys; listed as `requires_credentials` |
| 6 | Wikipedia, LoC/Chronicling America, Internet Archive, NARA, Find a Grave | ⏳ | Listed as `planned` in `/connectors` |
| 6 | robots.txt, rate limits, never bypass login/paywall/CAPTCHA | ✅ | |
| 7 | Famous Family Research Studio categories | 🟡 | Discovery queries in `discovery_categories.json`; **the SPARQL/search queries should be checked against live Wikidata** and are editable |
| 7 | "NO VERIFIED CONNECTION FOUND — RESEARCH CONTINUES" | ✅ | |
| 8 | Graph: pinch/pan, search, collapse, universes, century filter, evidence indicators, glowing paths, culling + LOD, Metal rasterization | 🟢 | Rotation not implemented; full custom Metal shader renderer not implemented (Canvas + drawingGroup) |
| 9 | Duplicate scoring, never name-only, side-by-side review, 4 actions, undoable merge log, auto-merge rules | ✅ | |
| 10 | Pathfinder: ancestors, descendants, siblings, half, cousins/removed, adoptive, step, in-law, multiple paths, uncertainty | ✅ | |
| 11 | BCE dates (astronomical years), 4000 BCE+ | ✅ | |
| 11 | Five ancestry categories | 🟡 | Evidence statuses: documented = `verified`/`user_provided`; probable = `supported`/`candidate`; `disputed`; `legendary`. Population-level ancestry is explained, never stored as a lineage |
| 12 | DNA import, encrypted, consent-gated | 🟢 | Parsing ✅ tested |
| 12 | DNA matching | ❌ | Requires a consented matching dataset; architecture leaves room, nothing is faked |
| 13 | Research Command Center + NL goals + start/pause/resume/stop/prioritize/schedule | ✅ / 🟢 | API tested; iOS screens compile in CI |
| 13 | Notifications | 🟡 | Local notifications when the app polls; no APNs push while the app is closed |
| 14 | Multi-agent architecture | ✅ | Agents are deterministic modules over real retrieval; LLM optional and cannot create facts |
| 15 | Encryption, token auth, local-first, export/delete, private living people, audit log, rate limits | ✅ / 🟢 | |
| 17 | Tests incl. synthetic dataset with known cousins, 10k-person tree | ✅ | |

## v1.1 additions

| Feature | Status | Notes |
|---|---|---|
| On-device creator research by handle (real name, public relatives, deceased ancestors, tree matching) | ✅ | Swift engine tested against simulated Wikidata; live Wikidata not yet exercised |
| Exact handle matching only; "No public record found" otherwise | ✅ | Both Swift and Python |
| Background continuation, iOS 26+ (BGContinuedProcessingTask) | 🟢 | Requires the iOS 26 SDK → CI uses the `macos-26` runner |
| Background on iOS 17–25 (~30 s + BGProcessing/BGAppRefresh slots) | 🟢 | iOS decides when slots run |
| Stops when swiped away, resumes from saved queue | ✅ | Queue is persisted with the encrypted tree |

## Known limitations

- Graph layout is a layered generational layout; very wide generations get long rows.
- Research merges are reversible on the server via `/merges/{id}/undo`; the iOS merge log covers local merges.
- iOS may still pause background research under heavy load or Low Power Mode; it always resumes from the saved queue.
- Many creators (especially smaller channels) have no Wikidata record, so their real names/families can't be documented.
