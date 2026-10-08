"""TEST STUB: the Keycloak endpoints lib/admin.sh uses (never shipped).

  python3 -I fake-keycloak.py <port> <admin-username-file> <admin-password-file> <request-log>

  POST /realms/master/protocol/openid-connect/token   (grant_type=password, client_id=admin-cli)
  GET  /admin/realms/<realm>/users?username=U&exact=true
  GET  /admin/realms/<realm>/groups?search=admin&exact=true
  GET  /admin/realms/<realm>/users/<id>/groups
  PUT  /admin/realms/<realm>/users/<id>/groups/<group-id>
Test controls: POST /test/user?username=U (what user-controller does),
GET /test/state. The request log gets "METHOD PATH" lines only.
"""
import json
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as f:
    ADMIN_USER = f.read()
with open(sys.argv[3], encoding="utf-8") as f:
    ADMIN_PASSWORD = f.read()
LOG = sys.argv[4]
LOCK = threading.Lock()
STATE = {"tokens": [], "users": {}, "groups": {"g-admin": {"id": "g-admin", "name": "admin", "path": "/admin"}},
         "members": {}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self):
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(f"{self.command} {urlparse(self.path).path}\n")

    def reply(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def bearer_ok(self):
        h = self.headers.get("Authorization") or ""
        if h.startswith("Bearer ") and h[7:] in STATE["tokens"]:
            return True
        self.reply(401, {"error": "HTTP 401 Unauthorized"})
        return False

    def parts(self):
        u = urlparse(self.path)
        return u.path.rstrip("/").split("/")[1:], parse_qs(u.query)

    def do_POST(self):
        self.record()
        parts, q = self.parts()
        with LOCK:
            if parts == ["test", "user"]:
                uid = "u-" + secrets.token_hex(4)
                STATE["users"][uid] = {"id": uid, "username": q["username"][0].lower()}
                return self.reply(201, {})
            if parts == ["realms", "master", "protocol", "openid-connect", "token"]:
                n = int(self.headers.get("Content-Length") or 0)
                form = parse_qs(self.rfile.read(n).decode())
                if (form.get("grant_type") == ["password"] and form.get("client_id") == ["admin-cli"]
                        and form.get("username") == [ADMIN_USER] and form.get("password") == [ADMIN_PASSWORD]):
                    tok = "tok-" + secrets.token_hex(16)
                    STATE["tokens"].append(tok)
                    return self.reply(200, {"access_token": tok, "token_type": "Bearer"})
                return self.reply(401, {"error": "invalid_grant"})
        return self.reply(404, {"error": "not found"})

    def do_GET(self):
        self.record()
        parts, q = self.parts()
        with LOCK:
            if parts == ["test", "state"]:
                return self.reply(200, {k: v for k, v in STATE.items() if k != "tokens"})
            if not self.bearer_ok():
                return None
            if len(parts) == 4 and parts[:2] == ["admin", "realms"] and parts[3] == "users":
                u = (q.get("username") or [""])[0].lower()
                return self.reply(200, [x for x in STATE["users"].values() if x["username"] == u])
            if len(parts) == 4 and parts[:2] == ["admin", "realms"] and parts[3] == "groups":
                return self.reply(200, list(STATE["groups"].values()))
            if len(parts) == 6 and parts[3] == "users" and parts[5] == "groups":
                return self.reply(200, [STATE["groups"][g] for g in STATE["members"].get(parts[4], [])])
        return self.reply(404, {"error": "not found"})

    def do_PUT(self):
        self.record()
        parts, _ = self.parts()
        with LOCK:
            if not self.bearer_ok():
                return None
            if len(parts) == 7 and parts[3] == "users" and parts[5] == "groups" and parts[4] in STATE["users"]:
                members = STATE["members"].setdefault(parts[4], [])
                if parts[6] not in members:
                    members.append(parts[6])
                return self.reply(204)
        return self.reply(404, {"error": "not found"})


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
