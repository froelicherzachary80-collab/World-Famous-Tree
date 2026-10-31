"""Durable research job queue on SQLite.

Jobs are leased (not deleted) while running; a crashed worker's lease expires
and the job is retried with exponential backoff. Survives restarts.
"""
from __future__ import annotations

import json
import sqlite3
from typing import Optional

LEASE_SECONDS = 300


def enqueue(conn: sqlite3.Connection, kind: str, payload: dict, goal_id: Optional[int] = None,
            priority: int = 5, dedupe_key: Optional[str] = None, delay_seconds: int = 0) -> Optional[int]:
    cur = conn.execute(
        """INSERT OR IGNORE INTO jobs(goal_id, kind, payload, priority, dedupe_key, run_after)
           VALUES (?,?,?,?,?, datetime('now', ?))""",
        (goal_id, kind, json.dumps(payload), priority, dedupe_key, f"+{delay_seconds} seconds"))
    return cur.lastrowid if cur.rowcount else None


def claim(conn: sqlite3.Connection) -> Optional[sqlite3.Row]:
    """Atomically lease the next runnable job whose goal is active (or goal-less)."""
    conn.execute("BEGIN IMMEDIATE")
    try:
        # Recover expired leases.
        conn.execute("""UPDATE jobs SET status='queued', lease_until=NULL
                        WHERE status='running' AND lease_until < datetime('now')""")
        row = conn.execute(
            """SELECT j.* FROM jobs j LEFT JOIN goals g ON g.id = j.goal_id
               WHERE j.status='queued' AND j.run_after <= datetime('now')
                 AND (j.goal_id IS NULL OR g.status='active')
               ORDER BY COALESCE(g.priority, 5) ASC, j.priority ASC, j.id ASC LIMIT 1""").fetchone()
        if row:
            conn.execute("""UPDATE jobs SET status='running', attempts=attempts+1,
                            lease_until=datetime('now', ?) WHERE id=?""", (f"+{LEASE_SECONDS} seconds", row["id"]))
            row = conn.execute("SELECT * FROM jobs WHERE id=?", (row["id"],)).fetchone()
        conn.execute("COMMIT")
        return row
    except Exception:
        conn.execute("ROLLBACK")
        raise


def complete(conn, job_id: int) -> None:
    conn.execute("UPDATE jobs SET status='done', lease_until=NULL WHERE id=?", (job_id,))


def fail(conn, job_id: int, error: str, retryable: bool = True) -> None:
    row = conn.execute("SELECT attempts, max_attempts FROM jobs WHERE id=?", (job_id,)).fetchone()
    if retryable and row["attempts"] < row["max_attempts"]:
        backoff = 30 * (2 ** (row["attempts"] - 1))
        conn.execute("""UPDATE jobs SET status='queued', lease_until=NULL, last_error=?,
                        run_after=datetime('now', ?) WHERE id=?""", (error[:500], f"+{backoff} seconds", job_id))
    else:
        conn.execute("UPDATE jobs SET status='failed', lease_until=NULL, last_error=? WHERE id=?", (error[:500], job_id))


def cancel_goal(conn, goal_id: int) -> None:
    conn.execute("UPDATE jobs SET status='cancelled' WHERE goal_id=? AND status IN ('queued','running')", (goal_id,))


def counts(conn, goal_id: Optional[int] = None) -> dict:
    q = "SELECT status, COUNT(*) FROM jobs" + (" WHERE goal_id=?" if goal_id else "") + " GROUP BY status"
    return {r[0]: r[1] for r in conn.execute(q, (goal_id,) if goal_id else ())}
