from worldtree import db, jobqueue, privacy, store


def test_queue_persists_across_restart(tmp_path):
    path = tmp_path / "wt.db"
    c = db.connect(path)
    c.execute("INSERT INTO goals(instruction, plan, status) VALUES ('x','{}','active')")
    jobqueue.enqueue(c, "plan_goal", {"a": 1}, 1)
    jobqueue.enqueue(c, "plan_goal", {"a": 1}, 1, dedupe_key="k")
    assert jobqueue.enqueue(c, "plan_goal", {"a": 1}, 1, dedupe_key="k") is None   # deduped
    c.close()
    c2 = db.connect(path)
    assert jobqueue.counts(c2)["queued"] == 2
    job = jobqueue.claim(c2)
    assert job["status"] == "running" and job["attempts"] == 1


def test_paused_goal_jobs_not_claimed(conn):
    conn.execute("INSERT INTO goals(instruction, plan, status) VALUES ('x','{}','paused')")
    jobqueue.enqueue(conn, "plan_goal", {}, 1)
    assert jobqueue.claim(conn) is None
    conn.execute("UPDATE goals SET status='active'")
    assert jobqueue.claim(conn) is not None


def test_expired_lease_is_recovered_and_retry_backoff(conn):
    jid = jobqueue.enqueue(conn, "x", {})
    jobqueue.claim(conn)
    conn.execute("UPDATE jobs SET lease_until=datetime('now','-1 minute') WHERE id=?", (jid,))
    again = jobqueue.claim(conn)
    assert again["id"] == jid and again["attempts"] == 2
    jobqueue.fail(conn, jid, "boom")
    row = conn.execute("SELECT status, run_after > datetime('now') AS later FROM jobs WHERE id=?", (jid,)).fetchone()
    assert row["status"] == "queued" and row["later"] == 1
    conn.execute("UPDATE jobs SET attempts=max_attempts WHERE id=?", (jid,))
    jobqueue.fail(conn, jid, "boom")
    assert conn.execute("SELECT status FROM jobs WHERE id=?", (jid,)).fetchone()[0] == "failed"


def test_privacy_rules():
    y = store.current_year()
    assert privacy.may_import({"birth_year": y - 10, "is_public_figure": True})[0] is False      # minor
    assert privacy.may_import({"birth_year": y - 40, "is_public_figure": False})[0] is False     # private living
    assert privacy.may_import({"birth_year": y - 40, "is_public_figure": True})[0] is True
    assert privacy.may_import({"birth_year": 1800, "death_year": 1870})[0] is True
    out = privacy.scrub({"name": "A", "home_address": "1 Main St", "description": "mail me a@b.com or +1 555 123 4567"})
    assert "home_address" not in out and "a@b.com" not in out["description"] and "555" not in out["description"]


def test_living_people_private_in_api_view(family):
    r = family.execute("SELECT * FROM persons WHERE id='g1:I16'").fetchone()
    d = store.person_dict(family, r, include_private=False)
    assert d["private"] and d["birth_year"] is None
