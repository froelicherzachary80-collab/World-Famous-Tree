"""Entry point: python3 -m backend.run [--db worldtree.db ...] (run from the repo root)."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for p in ("backend", "integrations", "research-agents"):
    sys.path.insert(0, str(ROOT / p))

from worldtree.api import main  # noqa: E402

if __name__ == "__main__":
    main()
