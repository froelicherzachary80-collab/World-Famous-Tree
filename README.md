# WORLD TREE AI — The Famous Family Multiverse

An iPhone family-tree app (SwiftUI, iOS 17+) plus a self-hosted research server whose AI agents
look for **documented** connections between your ancestors and public figures — Minecraft creators,
Young Hollywood, Marvel actors, pop stars, royal and ancient dynasties.

It never assumes you're related to anyone. Every research relationship keeps its source URL, retrieval
date and evidence assessment, and anything uncertain goes to you for review.
When nothing is documented you see **NO VERIFIED CONNECTION FOUND — RESEARCH CONTINUES**.

## What's in v1.0.0

| Area | Where | Status |
|---|---|---|
| GEDCOM 5.5 / 5.5.1 / 7 import (alt names, notes, sources, adoptions, divorce, BCE dates) | `ios/WorldTreeCore`, `backend/worldtree/gedcom.py` | ✅ working, tested |
| Relationship Pathfinder (cousin degree, removal, half, step, in-law, adoptive, multiple paths, uncertainty) | `RelationshipCalculator.swift`, `relationships.py` | ✅ working, tested |
| Duplicate detection + side-by-side review + undoable merges + strict auto-merge rules | `DuplicateDetector.swift`, `duplicates.py` | ✅ working, tested |
| Family Multiverse graph (pinch/pan, search, filters, timeline, collapse, glowing paths, evidence rings) | `WorldTreeGraphView.swift` | ✅ implemented (compiles in CI) |
| Research server: durable job queue, budgets, pause/resume/stop/schedule, audit log | `backend/` | ✅ working, tested |
| Research agents (planner, celebrity, matcher, evidence, timeline, pathfinder) | `research-agents/` | ✅ working against a simulated web in tests |
| Wikidata + WikiTree connectors | `integrations/` | ✅ implemented; **not live-tested from the build sandbox** |
| FamilySearch, NARA, YouTube, Chronicling America, Internet Archive… | `integrations/registry.py` | ⏳ listed honestly as planned / needs credentials |
| DNA raw-file import (encrypted, local only) | `RawDNAParser`, Profile tab | ✅ parse + store; ❌ no relative matching (needs a consented dataset) |
| On-device creator research + background continuation | `CreatorResearch.swift`, `BackgroundResearch.swift` | ✅ engine tested; 🟢 background modes compile in CI, need on-device check |
| Unsigned IPA via GitHub Actions | `.github/workflows` | ✅ workflow written; runs on first push |

Full detail: [`docs/STATUS.md`](docs/STATUS.md).

## Creator research on your iPhone (v1.1)

AI Research → *Creator research on this iPhone* → type handles like `LDShadowLady, JumperWho, MinuteTech`.
For each creator the app looks up their publicly documented real name, public relatives and deceased
ancestors (up to 4 generations), then checks them against your tree. No server needed.

- **Leave the app freely** — research keeps going in the background (iOS 26+: system progress indicator).
- **Swipe the app away** from the app switcher and research stops; the saved queue resumes next launch.
- Only an **exact** handle/alias match on a creator record is accepted — no "closest YouTuber" guesses.
  If a creator has no public record, you'll see *No public record found* and nothing is invented.
- Living relatives who aren't public figures, and anyone under 18, are never researched.

## Quick start

1. **Every push to `main`** makes GitHub Actions build the app on a macOS 26 runner.
2. **Get the IPA** from the CI run's artifacts (or a release), and install it with Signulous — see [`docs/BUILD.md`](docs/BUILD.md).
3. **Import your tree**: Profile → Import GEDCOM.
4. **(Optional) Run the research server** on an always-on computer — see [`docs/SERVER.md`](docs/SERVER.md):
   ```bash
   python3 -m backend.run --db worldtree.db --with-worker
   ```
   Enter the printed address and token in Profile → Research server.

## Repository layout

```
ios/               SwiftUI app (WorldTreeApp), core library (WorldTreeCore, SwiftPM), UI tests, XcodeGen spec
backend/           Research API + job orchestration (Python standard library only)
research-agents/   Planner, Director, Evidence/Timeline verification, gap analysis
integrations/      Connector framework, Wikidata, WikiTree, discovery queries
database/          SQLite migrations
tests/             Backend tests + shared synthetic GEDCOM with known cousin relationships
.github/workflows  CI, release, security
docs/              Build, server, architecture, status
```

## Tests

```bash
pip install pytest && python -m pytest        # backend: 53 tests
cd ios/WorldTreeCore && swift test            # Swift core (macOS)
```
