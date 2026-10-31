"""WORLD TREE AI research server — zero-dependency JSON API (Python stdlib).

Run:  python -m worldtree.api --db worldtree.db --port 8787 --with-worker
Auth: every request needs `Authorization: Bearer <token>`; the token is created
on first run and printed once (also stored hashed-free in settings for the owner).
"""
from __future__ import annotations

import argparse
import hmac
import json
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[2]
for extra in ("integrations", "research-agents"):
    if str(ROOT / extra) not in sys.path:
        sys.path.insert(0, str(ROOT / extra))

from worldtree import db, duplicates, jobqueue, relationships, store  # noqa: E402
from worldtree_agents import director as D  # noqa: E402
from worldtree_agents import gaps, planner  # noqa: E402
from worldtree_integrations import registry  # noqa: E402

MAX_BODY = 50 * 1024 * 1024
RATE_LIMIT_PER_MIN = 240


class App:
    def __init__(self, conn):
        self.conn = conn
        self.lock = threading.RLock()
        self.hits: dict[str, list[float]] = {}
        token = db.get_setting(conn, "api_token")
        if not token:
            token = secrets.token_urlsafe(32)
            db.set_setting(conn, "api_token", token)
            print(f"\n  WORLD TREE AI API token (enter this in the iOS app):\n  {token}\n", flush=True)
        self.token = token
        self.routes = []
        r = self.route
        r("GET", r"/health", lambda m, q, b: {"ok": True, "service": "world-tree-ai", "version": "1.0.0"}, auth=False)
        r("GET", r"/stats", self.stats)
        r("POST", r"/gedcom/import", self.import_gedcom)
        r("GET", r"/people", self.people)
        r("GET", r"/people/(?P<pid>[^/]+)", self.person)
        r("POST", r"/home-person", self.home_person)
        r("POST", r"/connection", self.connection)
        r("GET", r"/goals", self.goals)
        r("POST", r"/goals", self.create_goal)
        r("POST", r"/goals/plan-preview", lambda m, q, b: planner.make_plan(b.get("instruction", "")))
        r("POST", r"/goals/(?P<gid>\d+)/(?P<action>start|pause|resume|stop|prioritize)", self.goal_action)
        r("GET", r"/discoveries", self.discoveries)
        r("POST", r"/discoveries/(?P<did>\d+)/(?P<action>accept|reject)", self.discovery_action)
        r("GET", r"/duplicates", self.duplicates)
        r("POST", r"/duplicates/scan", lambda m, q, b: {"found": len(duplicates.detect(self.conn))})
        r("POST", r"/duplicates/(?P<did>\d+)/(?P<action>merge|separate|investigate|different)", self.dup_action)
        r("POST", r"/merges/(?P<lid>\d+)/undo", self.undo)
        r("GET", r"/gaps", lambda m, q, b: gaps.analyze(self.conn))
        r("GET", r"/activity", self.activity)
        r("GET", r"/universes", self.universes)
        r("GET", r"/graph", self.graph)
        r("GET", r"/connectors", lambda m, q, b: registry.info())
        r("GET", r"/export", self.export)
        r("DELETE", r"/data", self.delete_all)

    def route(self, method, pattern, fn, auth=True):
        self.routes.append((method, re.compile("^" + pattern + "$"), fn, auth))

    # ---------------------------------------------------------- handlers
    def stats(self, m, q, b):
        c = self.conn
        one = lambda sql, *a: c.execute(sql, a).fetchone()[0]  # noqa: E731
        return {
            "imported_people": one("SELECT COUNT(*) FROM persons WHERE origin='gedcom' AND merged_into IS NULL"),
            "candidate_people": one("SELECT COUNT(*) FROM persons WHERE origin='research' AND merged_into IS NULL"),
            "verified_connections": one("SELECT COUNT(*) FROM discoveries WHERE kind='connection' AND title LIKE 'VERIFIED%'"),
            "pending_discoveries": one("SELECT COUNT(*) FROM discoveries WHERE status='pending'"),
            "possible_duplicates": one("SELECT COUNT(*) FROM duplicate_candidates WHERE status='open'"),
            "unresolved_branches": gaps.analyze(c, 0)["counts"]["missing_parents"],
            "sources_reviewed": one("SELECT COUNT(*) FROM sources"),
            "active_goals": one("SELECT COUNT(*) FROM goals WHERE status='active'"),
            "completed_goals": one("SELECT COUNT(*) FROM goals WHERE status='completed'"),
            "queue": jobqueue.counts(c),
            "errors": one("SELECT COUNT(*) FROM activity WHERE level IN ('error','blocked')"),
            "home_person": db.get_setting(c, "home_person"),
        }

    def import_gedcom(self, m, q, b):
        rep = store.import_gedcom(self.conn, b.get("gedcom", ""), b.get("universe", "my_family"))
        found = duplicates.detect(self.conn) if not rep.errors else []
        if rep.people and not db.get_setting(self.conn, "home_person"):
            first = self.conn.execute("SELECT id FROM persons WHERE id LIKE ? ORDER BY rowid LIMIT 1",
                                      (rep.batch + ":%",)).fetchone()
            if first:
                db.set_setting(self.conn, "home_person", first[0])
        return {**rep.__dict__, "possible_duplicates": len(found), "gaps": gaps.analyze(self.conn, 10)}

    def people(self, m, q, b):
        term = f"%{q.get('q', [''])[0]}%"
        uni = q.get("universe", [None])[0]
        sql = "SELECT p.* FROM persons p WHERE p.merged_into IS NULL AND (p.given_name || ' ' || p.surname) LIKE ?"
        args = [term]
        if uni:
            sql += " AND p.id IN (SELECT person_id FROM universe_members WHERE universe_id=?)"
            args.append(uni)
        sql += " ORDER BY p.surname, p.given_name LIMIT ?"
        args.append(int(q.get("limit", ["200"])[0]))
        return [store.person_dict(self.conn, r) for r in self.conn.execute(sql, args)]

    def person(self, m, q, b):
        r = self.conn.execute("SELECT * FROM persons WHERE id=?", (m["pid"],)).fetchone()
        if not r:
            raise KeyError("person not found")
        d = store.person_dict(self.conn, r)
        g = store.load_graph(self.conn)
        rel = lambda edges: [{"id": e.other, "name": g.name(e.other), "pedigree": e.pedigree, "evidence": e.status}  # noqa: E731
                             for e in edges]
        d["parents"], d["children"], d["spouses"] = (rel(g.parents.get(r["id"], [])), rel(g.children.get(r["id"], [])),
                                                     rel(g.spouses.get(r["id"], [])))
        d["alt_names"] = [dict(x) for x in self.conn.execute("SELECT * FROM person_names WHERE person_id=?", (r["id"],))]
        d["citations"] = [dict(x) for x in self.conn.execute(
            """SELECT c.detail, c.assessment, s.title, s.url, s.connector, s.retrieved_at FROM citations c
               JOIN sources s ON s.id=c.source_id WHERE c.subject_type='person' AND c.subject_id=?""", (r["id"],))]
        return d

    def home_person(self, m, q, b):
        db.set_setting(self.conn, "home_person", b["person_id"])
        return {"home_person": b["person_id"]}

    def connection(self, m, q, b):
        return relationships.find_connection(store.load_graph(self.conn), b["a"], b["b"])

    def goals(self, m, q, b):
        out = []
        for r in self.conn.execute("SELECT * FROM goals ORDER BY priority, id DESC"):
            d = dict(r)
            d["plan"] = json.loads(d["plan"])
            d["jobs"] = jobqueue.counts(self.conn, r["id"])
            out.append(d)
        return out

    def create_goal(self, m, q, b):
        gid = D.create_goal(self.conn, b["instruction"], int(b.get("budget", 200)), b.get("schedule"))
        if b.get("start"):
            D.set_goal_status(self.conn, gid, "start")
        db.audit(self.conn, "user", "create_goal", {"id": gid})
        return {"id": gid, "plan": json.loads(self.conn.execute("SELECT plan FROM goals WHERE id=?", (gid,)).fetchone()[0])}

    def goal_action(self, m, q, b):
        return {"status": D.set_goal_status(self.conn, int(m["gid"]), m["action"])}

    def discoveries(self, m, q, b):
        st = q.get("status", [None])[0]
        sql = "SELECT * FROM discoveries" + (" WHERE status=?" if st else "") + " ORDER BY id DESC LIMIT 300"
        return [{**dict(r), "detail": json.loads(r["detail"])} for r in self.conn.execute(sql, (st,) if st else ())]

    def discovery_action(self, m, q, b):
        did = int(m["did"])
        d = self.conn.execute("SELECT * FROM discoveries WHERE id=?", (did,)).fetchone()
        if not d:
            raise KeyError("discovery not found")
        det = json.loads(d["detail"])
        if m["action"] == "reject":
            self.conn.execute("UPDATE discoveries SET status='rejected' WHERE id=?", (did,))
            if "relationship_id" in det:
                self.conn.execute("UPDATE relationships SET evidence_status='rejected' WHERE id=?", (det["relationship_id"],))
            return {"status": "rejected"}
        if d["kind"] == "identity_match":
            return {"status": "accepted", "merge_log_id": D.accept_identity_match(self.conn, did)}
        if "relationship_id" in det:
            self.conn.execute("UPDATE relationships SET evidence_status='verified' WHERE id=? AND evidence_status!='disputed'",
                              (det["relationship_id"],))
        self.conn.execute("UPDATE discoveries SET status='accepted' WHERE id=?", (did,))
        return {"status": "accepted"}

    def duplicates(self, m, q, b):
        out = []
        for r in self.conn.execute("SELECT * FROM duplicate_candidates WHERE status IN ('open','investigating') ORDER BY score DESC"):
            pa = self.conn.execute("SELECT * FROM persons WHERE id=?", (r["person_a"],)).fetchone()
            pb = self.conn.execute("SELECT * FROM persons WHERE id=?", (r["person_b"],)).fetchone()
            out.append({**dict(r), "matches": json.loads(r["matches"]), "conflicts": json.loads(r["conflicts"]),
                        "a": store.person_dict(self.conn, pa), "b": store.person_dict(self.conn, pb)})
        return out

    def dup_action(self, m, q, b):
        r = self.conn.execute("SELECT * FROM duplicate_candidates WHERE id=?", (int(m["did"]),)).fetchone()
        if not r:
            raise KeyError("candidate not found")
        if m["action"] == "merge":
            keep = b.get("keep", r["person_a"])
            drop = r["person_b"] if keep == r["person_a"] else r["person_a"]
            return {"merge_log_id": duplicates.merge(self.conn, keep, drop)}
        st = {"separate": "separate", "investigate": "investigating", "different": "different"}[m["action"]]
        self.conn.execute("UPDATE duplicate_candidates SET status=? WHERE id=?", (st, r["id"]))
        return {"status": st}

    def undo(self, m, q, b):
        duplicates.undo_merge(self.conn, int(m["lid"]))
        return {"undone": True}

    def activity(self, m, q, b):
        return [dict(r) for r in self.conn.execute("SELECT * FROM activity ORDER BY id DESC LIMIT 200")]

    def universes(self, m, q, b):
        return [{**dict(r), "members": self.conn.execute("SELECT COUNT(*) FROM universe_members WHERE universe_id=?",
                                                         (r["id"],)).fetchone()[0]}
                for r in self.conn.execute("SELECT * FROM universes")]

    def graph(self, m, q, b):
        g = store.load_graph(self.conn)
        nodes = [{"id": pid, "name": g.name(pid), "sex": r["sex"], "birth_year": r["birth_year"],
                  "death_year": r["death_year"], "evidence": r["evidence_status"], "origin": r["origin"],
                  "living": bool(r["is_living"]), "public": bool(r["is_public_figure"])} for pid, r in g.persons.items()]
        uni = {}
        for pid, u in self.conn.execute("SELECT person_id, universe_id FROM universe_members"):
            uni.setdefault(pid, []).append(u)
        for n in nodes:
            n["universes"] = uni.get(n["id"], [])
        edges = [{"from": e.other, "to": child, "kind": "parent", "pedigree": e.pedigree, "evidence": e.status}
                 for child, es in g.parents.items() for e in es]
        edges += [{"from": a, "to": e.other, "kind": "spouse", "evidence": e.status}
                  for a, es in g.spouses.items() for e in es if a < e.other]
        return {"nodes": nodes, "edges": edges}

    def export(self, m, q, b):
        tables = ["persons", "person_names", "relationships", "sources", "citations", "universe_members",
                  "duplicate_candidates", "merge_log", "goals", "discoveries"]
        return {t: [dict(r) for r in self.conn.execute(f"SELECT * FROM {t}")] for t in tables}

    def delete_all(self, m, q, b):
        if b.get("confirm") != "DELETE EVERYTHING":
            raise ValueError("send {\"confirm\": \"DELETE EVERYTHING\"}")
        for t in ["citations", "universe_members", "person_names", "duplicate_candidates", "merge_log", "discoveries",
                  "jobs", "activity", "relationships", "goals", "sources"]:
            self.conn.execute(f"DELETE FROM {t}")
        self.conn.execute("UPDATE persons SET merged_into=NULL")
        self.conn.execute("DELETE FROM persons")
        self.conn.execute("DELETE FROM settings WHERE key='home_person'")
        db.audit(self.conn, "user", "delete_all")
        return {"deleted": True}

    # ---------------------------------------------------------- dispatch
    def handle(self, method: str, path: str, headers, body: bytes, client: str):
        u = urlparse(path)
        for meth, rx, fn, auth in self.routes:
            mt = rx.match(u.path)
            if mt and meth == method:
                if auth:
                    got = (headers.get("Authorization") or "").removeprefix("Bearer ").strip()
                    if not hmac.compare_digest(got, self.token):
                        return 401, {"error": "unauthorized"}
                    now = time.time()
                    hits = [t for t in self.hits.get(client, []) if now - t < 60]
                    if len(hits) >= RATE_LIMIT_PER_MIN:
                        return 429, {"error": "rate limited"}
                    self.hits[client] = hits + [now]
                try:
                    data = json.loads(body) if body else {}
                    with self.lock:
                        return 200, fn(mt.groupdict(), parse_qs(u.query), data)
                except KeyError as e:
                    return 404, {"error": str(e).strip("'")}
                except (ValueError, TypeError) as e:
                    return 400, {"error": str(e)}
        return 404, {"error": "no such route"}


def make_handler(app: App):
    class Handler(BaseHTTPRequestHandler):
        server_version = "WorldTreeAI/1.0"

        def _go(self, method):
            n = int(self.headers.get("Content-Length") or 0)
            if n > MAX_BODY:
                return self._send(413, {"error": "body too large"})
            body = self.rfile.read(n) if n else b""
            status, payload = app.handle(method, self.path, self.headers, body, self.client_address[0])
            self._send(status, payload)

        def _send(self, status, payload):
            data = json.dumps(payload, default=str).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._go("GET")

        def do_POST(self):
            self._go("POST")

        def do_DELETE(self):
            self._go("DELETE")

        def log_message(self, fmt, *args):
            pass

    return Handler


def main(argv=None):
    ap = argparse.ArgumentParser(description="WORLD TREE AI research server")
    ap.add_argument("--db", default="worldtree.db")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--with-worker", action="store_true", help="run the research worker in this process")
    a = ap.parse_args(argv)
    conn = db.connect(a.db)
    app = App(conn)
    if a.with_worker:
        from worldtree.worker import run_forever
        threading.Thread(target=run_forever, args=(a.db,), daemon=True).start()
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(app))
    print(f"WORLD TREE AI server on http://{a.host}:{a.port}  (db: {a.db})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
