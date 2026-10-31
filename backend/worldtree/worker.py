"""Research worker: runs queued jobs forever. Safe to stop/restart at any time —
jobs are leased in SQLite and resume after a crash or reboot.

Run:  python -m worldtree.worker --db worldtree.db
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for extra in ("integrations", "research-agents"):
    if str(ROOT / extra) not in sys.path:
        sys.path.insert(0, str(ROOT / extra))

from worldtree import db  # noqa: E402
from worldtree_agents.director import Director  # noqa: E402


def run_forever(db_path: str, idle_sleep: float = 5.0, max_jobs: int | None = None) -> int:
    conn = db.connect(db_path)
    d = Director(conn)
    done = 0
    while max_jobs is None or done < max_jobs:
        if d.run_one():
            done += 1
        else:
            time.sleep(idle_sleep)
    return done


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="worldtree.db")
    a = ap.parse_args(argv)
    print(f"WORLD TREE AI research worker started (db: {a.db})", flush=True)
    run_forever(a.db)


if __name__ == "__main__":
    main()
