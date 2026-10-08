"""TEST STUB: the subset of the Harbor v2.0 REST API that lib/harbor.sh uses.

Never shipped in a bundle (the node scripts contain no python). Paired with a
plain registry:2 for the OCI side in airgap/test/k3d/harbor-test.sh.

  python3 -I fake-harbor-api.py <port> <admin-password-file> <request-log>

Endpoints (admin basic auth required, like Harbor):
  GET    /api/v2.0/health
  GET    /api/v2.0/projects?name=N        POST /api/v2.0/projects
  PUT    /api/v2.0/projects/<id>
  GET    /api/v2.0/projects/<id>/immutabletagrules   POST (same path)
  GET    /api/v2.0/robots?q=name%3D<n>    DELETE /api/v2.0/robots/<id>
Test controls (no auth): POST /test/project-public?name=N&public=false,
POST /test/robot?name=argocd, GET /test/state.
The request log gets one "METHOD PATH" line per request, never a header.
"""
import base64
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as f:
    PASSWORD = f.read()
LOG = sys.argv[3]
LOCK = threading.Lock()
STATE = {"projects": {}, "rules": {}, "robots": {}, "next": 1}


def next_id():
    STATE["next"] += 1
    return STATE["next"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence the default stderr access log
        pass

    def record(self):
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{self.command} {self.path}\n")

    def reply(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        expected = "Basic " + base64.b64encode(f"admin:{PASSWORD}".encode()).decode()
        if self.headers.get("Authorization") == expected:
            return True
        self.reply(401, {"errors": [{"code": "UNAUTHORIZED", "message": "unauthorized"}]})
        return False

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def route(self):
        u = urlparse(self.path)
        return u.path.rstrip("/").split("/")[1:], parse_qs(u.query)

    def do_GET(self):
        self.record()
        parts, q = self.route()
        with LOCK:
            if parts == ["test", "state"]:
                return self.reply(200, STATE)
            if not self.authed():
                return None
            if parts == ["api", "v2.0", "health"]:
                return self.reply(200, {"status": "healthy", "components": [{"name": "core", "status": "healthy"}]})
            if parts == ["api", "v2.0", "projects"]:
                name = (q.get("name") or [""])[0]
                return self.reply(200, [p for p in STATE["projects"].values() if not name or name in p["name"]])
            if len(parts) == 5 and parts[:3] == ["api", "v2.0", "projects"] and parts[4] == "immutabletagrules":
                return self.reply(200, STATE["rules"].get(parts[3], []))
            if parts == ["api", "v2.0", "robots"]:
                return self.reply(200, list(STATE["robots"].values()))
        return self.reply(404, {"errors": [{"code": "NOT_FOUND"}]})

    def do_POST(self):
        self.record()
        parts, q = self.route()
        with LOCK:
            if parts == ["test", "project-public"]:
                for p in STATE["projects"].values():
                    if p["name"] == q["name"][0]:
                        p["metadata"]["public"] = q["public"][0]
                return self.reply(200, {})
            if parts == ["test", "robot"]:
                rid = next_id()
                STATE["robots"][str(rid)] = {"id": rid, "name": "robot$" + q["name"][0], "level": "system"}
                return self.reply(201, {})
            if not self.authed():
                return None
            if parts == ["api", "v2.0", "projects"]:
                b = self.body()
                if any(p["name"] == b["project_name"] for p in STATE["projects"].values()):
                    return self.reply(409, {"errors": [{"code": "CONFLICT"}]})
                pid = next_id()
                STATE["projects"][str(pid)] = {"project_id": pid, "name": b["project_name"],
                                               "metadata": dict(b.get("metadata") or {"public": "false"})}
                return self.reply(201)
            if len(parts) == 5 and parts[4] == "immutabletagrules":
                STATE["rules"].setdefault(parts[3], []).append(dict(self.body(), id=next_id()))
                return self.reply(201)
        return self.reply(404, {"errors": [{"code": "NOT_FOUND"}]})

    def do_PUT(self):
        self.record()
        parts, _ = self.route()
        with LOCK:
            if not self.authed():
                return None
            if len(parts) == 4 and parts[:3] == ["api", "v2.0", "projects"] and parts[3] in STATE["projects"]:
                STATE["projects"][parts[3]]["metadata"].update(self.body().get("metadata") or {})
                return self.reply(200)
        return self.reply(404, {"errors": [{"code": "NOT_FOUND"}]})

    def do_DELETE(self):
        self.record()
        parts, _ = self.route()
        with LOCK:
            if not self.authed():
                return None
            if len(parts) == 4 and parts[:3] == ["api", "v2.0", "robots"] and parts[3] in STATE["robots"]:
                del STATE["robots"][parts[3]]
                return self.reply(200)
        return self.reply(404, {"errors": [{"code": "NOT_FOUND"}]})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
