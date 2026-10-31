import json
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from worldtree import api, db, duplicates, store
from worldtree.relationships import find_connection


@pytest.fixture
def server(tmp_path):
    conn = db.connect(tmp_path / "api.db")
    app = api.App(conn)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), api.make_handler(app))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{srv.server_address[1]}", app.token
    srv.shutdown()


def call(base, token, method, path, body=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"Authorization": f"Bearer {token}",
                                                         "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_api_end_to_end(server, gedcom_text):
    base, tok = server
    assert call(base, "", "GET", "/health")[0] == 200
    assert call(base, "wrong", "GET", "/stats")[0] == 401

    s, rep = call(base, tok, "POST", "/gedcom/import", {"gedcom": gedcom_text})
    assert s == 200 and rep["people"] == 27 and rep["possible_duplicates"] >= 1
    assert rep["gaps"]["recommended_goals"]

    s, stats = call(base, tok, "GET", "/stats")
    assert stats["imported_people"] == 27 and stats["possible_duplicates"] >= 1

    s, res = call(base, tok, "POST", "/connection", {"a": "g1:I13", "b": "g1:I15"})
    assert res["relationship"] == "2nd cousin"

    s, people = call(base, tok, "GET", "/people?q=Stone")
    assert s == 200 and any(p["name"] == "Adam Stone" for p in people)
    s, adam = call(base, tok, "GET", "/people/g1:I1")
    assert {c["name"] for c in adam["children"]} == {"Bob Stone", "Carol Stone", "Dan Stone"}
    assert adam["citations"][0]["title"] == "Stone Family Bible"

    s, dups = call(base, tok, "GET", "/duplicates")
    d = dups[0]
    assert d["a"]["name"] and d["b"]["name"] and d["matches"]
    s, m = call(base, tok, "POST", f"/duplicates/{d['id']}/merge", {"keep": d["person_a"]})
    s, _ = call(base, tok, "POST", f"/merges/{m['merge_log_id']}/undo", {})
    assert s == 200

    s, goal = call(base, tok, "POST", "/goals", {"instruction": "Research Marvel actors and connect to my tree", "start": True})
    assert goal["plan"]["categories"] == ["marvel"]
    s, goals = call(base, tok, "GET", "/goals")
    assert goals[0]["status"] == "active" and goals[0]["jobs"]["queued"] == 1
    assert call(base, tok, "POST", f"/goals/{goal['id']}/pause", {})[1]["status"] == "paused"
    assert call(base, tok, "POST", f"/goals/{goal['id']}/stop", {})[1]["status"] == "stopped"

    s, g = call(base, tok, "GET", "/graph")
    assert len(g["nodes"]) == 27 and any(e["kind"] == "spouse" for e in g["edges"])
    assert len(call(base, tok, "GET", "/connectors")[1]) >= 5

    assert call(base, tok, "DELETE", "/data", {})[0] == 400
    assert call(base, tok, "DELETE", "/data", {"confirm": "DELETE EVERYTHING"})[1]["deleted"]
    assert call(base, tok, "GET", "/stats")[1]["imported_people"] == 0


def test_large_tree_performance(conn):
    """>10,000 people over several generations: graph load, pathfinding and duplicate scan stay fast."""
    import random
    rnd = random.Random(7)
    conn.execute("BEGIN")
    prev = []
    for i in range(256):
        pid = f"p0_{i}"
        store.upsert_person(conn, pid, given_name=f"G{i}", surname=f"Root{i}", sex="MF"[i % 2], birth_year=1500, death_year=1560)
        prev.append(pid)
    count, level = 256, 0
    while count < 10_000:
        level += 1
        rnd.shuffle(prev)
        nxt = []
        for i in range(0, len(prev) - 1, 2):
            store.add_spouse_edge(conn, prev[i], prev[i + 1])
            for k in range(rnd.choice([3, 4, 5])):
                cid = f"p{level}_{len(nxt)}"
                store.upsert_person(conn, cid, given_name=f"N{rnd.randint(0, 99999)}", surname=f"S{rnd.randint(0, 5000)}",
                                    sex="MF"[k % 2], birth_year=1500 + level * 30, death_year=1560 + level * 30)
                store.add_parent_edge(conn, prev[i], cid)
                store.add_parent_edge(conn, prev[i + 1], cid)
                nxt.append(cid)
                count += 1
        prev = nxt
    conn.execute("COMMIT")
    assert conn.execute("SELECT COUNT(*) FROM persons").fetchone()[0] >= 10_000
    t = time.perf_counter()
    g = store.load_graph(conn)
    results = [find_connection(g, prev[i], prev[-1 - i]) for i in range(20)]
    elapsed = time.perf_counter() - t
    assert all(r["kind"] in ("blood", "marriage", "none") for r in results)
    assert any("cousin" in r["relationship"] for r in results)
    assert elapsed < 10.0, elapsed
    t = time.perf_counter()
    duplicates.detect(conn)
    assert time.perf_counter() - t < 60
