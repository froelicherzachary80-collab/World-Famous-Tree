# Running the research server (free, self-hosted)

Autonomous research has to keep going when your iPhone is locked, so it runs on a computer you leave on —
your gaming PC, an old laptop, a Raspberry Pi, or any cheap VPS. It uses only the Python standard library
(Python 3.10+) and a single SQLite file.

```bash
git clone https://github.com/<you>/WORLD-TREE-AI && cd WORLD-TREE-AI
python3 -m backend.run --db worldtree.db --port 8787 --with-worker
```

On first start it prints an **API token**. In the app: Profile → Research server → enter
`http://<computer-ip>:8787` and the token.

- **Same Wi-Fi:** use the computer's LAN IP (e.g. `192.168.1.20`).
- **Away from home:** install Tailscale (free) on both devices and use the computer's Tailscale IP (`100.x.x.x`).
  Don't expose port 8787 directly to the internet.

Worker and API can also run separately (`python3 -m backend.run_worker --db worldtree.db`). Jobs are leased in
SQLite, so you can stop and restart either at any time and research resumes where it left off.

## What the server does

1. You create a goal in plain English ("Research Marvel actors and find connections to my tree").
2. The **Research Planner** turns it into a structured plan (categories, named people, agent steps).
3. **Celebrity Research** finds public figures (Wikidata), **Web Researcher** resolves quoted names.
4. Each person's documented parents are fetched up to 4 generations; WikiTree is used to corroborate.
5. **Evidence Verification**: a parent link is *verified* only when two independent sources agree and the
   **Timeline Researcher** finds no contradiction; otherwise it stays *supported*/*candidate* and goes to review.
6. **Family Matcher** compares researched ancestors with your tree. Matches are only *suggestions* —
   you confirm "same person" in Discoveries, then the **Relationship Pathfinder** computes the connection.

Budgets cap external requests per goal; a goal pauses itself when its budget is spent.

## Privacy rules enforced by the server

- Living private individuals and anyone under 18 are never imported from research.
- Connectors request genealogical fields only; addresses, contact details and phone numbers are never stored.
- 401/403/paywall/CAPTCHA responses are recorded as **blocked** and never retried around.
- Every API call needs the bearer token; requests are rate-limited; all changes go to an audit log.
- `DELETE /data` (Profile → delete) wipes the server database contents.

## Optional AI model

The planner works offline with deterministic rules. You can plug in any OpenAI-compatible endpoint
(`OpenAICompatibleLLM` in `research-agents/worldtree_agents/planner.py`), including a free local
**Ollama** server at `http://localhost:11434/v1`. The model may only choose research categories — it can never
create people or relationships; facts come exclusively from cited sources.

Local-model trade-offs:

| Hardware | Model size | Experience |
|---|---|---|
| 8 GB RAM, no GPU | 1–3B | works for category planning, slow (several seconds) |
| 16 GB RAM / Apple Silicon | 7–8B | comfortable |
| GPU with 8–12 GB VRAM | 7–14B | fast |

Paid cloud APIs are never required.
