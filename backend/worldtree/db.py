"""SQLite access + migrations. SQLite in WAL mode is the durable store for the
tree, the research job queue and the audit trail — free and self-hostable."""
from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = Path(os.environ.get("WORLDTREE_MIGRATIONS", REPO_ROOT / "database" / "migrations"))


def connect(path: str | os.PathLike = ":memory:") -> sqlite3.Connection:
    conn = sqlite3.connect(str(path), timeout=30, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    if str(path) != ":memory:":
        conn.execute("PRAGMA journal_mode = WAL")
    migrate(conn)
    return conn


def migrate(conn: sqlite3.Connection) -> list[int]:
    conn.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
    done = {r[0] for r in conn.execute("SELECT version FROM schema_version")}
    applied = []
    for f in sorted(MIGRATIONS.glob("*.sql")):
        v = int(f.name.split("_", 1)[0])
        if v in done:
            continue
        conn.executescript(f.read_text())
        conn.execute("INSERT INTO schema_version VALUES (?, datetime('now'))", (v,))
        applied.append(v)
    return applied


def audit(conn: sqlite3.Connection, actor: str, action: str, detail: str | dict = "") -> None:
    if isinstance(detail, dict):
        detail = json.dumps(detail)
    conn.execute("INSERT INTO audit_log(actor, action, detail) VALUES (?,?,?)", (actor, action, detail))


def log_activity(conn: sqlite3.Connection, agent: str, message: str, level: str = "info", goal_id=None) -> None:
    conn.execute("INSERT INTO activity(agent, level, message, goal_id) VALUES (?,?,?,?)",
                 (agent, level, message, goal_id))


def get_setting(conn, key: str, default=None):
    r = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return json.loads(r[0]) if r else default


def set_setting(conn, key: str, value) -> None:
    conn.execute("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                 (key, json.dumps(value)))
