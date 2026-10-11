"""TEST STUB: the browser sign-in flow kc-login.sh drives (never shipped).

  python3 -I fake-sso.py <port> <cert> <key> <users.json> <event-log> <domain>

One HTTPS listener answers three hosts (the client maps them to 127.0.0.1,
e.g. with curl --resolve or a .curlrc):
  <domain>         oauth2-proxy and the protected apps: /oauth2/start,
                   /oauth2/callback, /oauth2/sign_out; any other path needs
                   the session cookie _teknoir_oauth2_proxy. Without it a
                   navigation gets 302 /oauth2/start plus two expiring
                   Set-Cookie headers, fetch/XHR (Sec-Fetch-Mode other than
                   navigate, or X-Requested-With) gets 401 (the r5 gateway
                   Lua). Signed in: /teknoir-system/* is 403 unless the user
                   is in group admin, /api/catalog/* is 401 without a bearer
                   token (Backstage), /home carries window.__APP_CONFIG__ with
                   teknoir.auth.issuer, anything else 200.
  auth.<domain>    Keycloak realm teknoir under /auth: the login form
                   (kc-form-login), the required actions UPDATE_PASSWORD
                   (kc-passwd-update-form) and UPDATE_PROFILE
                   (kc-update-profile-form, needs a lastName), the SSO cookie
                   KEYCLOAK_IDENTITY, and the end-session endpoint with its
                   logout confirmation form (logout-confirm).
  argocd.<domain>  an OIDC client like ArgoCD: /auth/login, /auth/callback
                   (cookie argocd.token), /api/v1/applications (items only for
                   group admin).
users.json: {"<username>": {"password_file": F, "email": E, "groups": [...],
"required": ["UPDATE_PASSWORD", "UPDATE_PROFILE"], "enabled": true}}.
The event log gets "<event> <username>" lines only (never a password).
"""
import json
import secrets
import ssl
import sys
import threading
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlencode, urlparse

PORT = int(sys.argv[1])
CERT, KEY = sys.argv[2], sys.argv[3]
with open(sys.argv[4], encoding="utf-8") as f:
    USERS = json.load(f)
for _u in USERS.values():
    with open(_u["password_file"], encoding="utf-8") as f:
        _u["password"] = f.read().rstrip("\n")
    _u.setdefault("required", [])
    _u.setdefault("groups", [])
    _u.setdefault("enabled", True)
LOG = sys.argv[5]
DOMAIN = sys.argv[6]
APP, AUTH, ARGO = DOMAIN, "auth." + DOMAIN, "argocd." + DOMAIN
APP_URL, AUTH_URL, ARGO_URL = (f"https://{h}:{PORT}" for h in (APP, AUTH, ARGO))
REALM = "/auth/realms/teknoir"
COOKIE = "_teknoir_oauth2_proxy"
LOCK = threading.Lock()
S = {"kc": {}, "auth": {}, "codes": {}, "o2p": {}, "argo": {}, "logout": {}, "argo_state": {}}
CLIENTS = {"teknoir": APP_URL + "/oauth2/callback", "argocd": ARGO_URL + "/auth/callback"}


def event(name, user=""):
    with LOCK, open(LOG, "a", encoding="utf-8") as f:
        f.write(f"{name} {user}\n")


def page(body):
    return f"<html><body>{body}</body></html>"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    # -- plumbing ------------------------------------------------------------
    def cookies(self):
        c = SimpleCookie()
        c.load(self.headers.get("Cookie") or "")
        return {k: v.value for k, v in c.items()}

    def form(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        return {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    def send(self, code, body="", location=None, cookies=(), ctype="text/html"):
        data = body.encode()
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        for c in cookies:
            self.send_header("Set-Cookie", c)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def host(self):
        return (self.headers.get("Host") or "").split(":")[0]

    def route(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
        h = self.host()
        fn = {APP: self.app, AUTH: self.auth, ARGO: self.argo}.get(h)
        if fn is None:
            return self.send(404, "unknown host")
        return fn(method, u.path, q)

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    # -- oauth2-proxy and the apps ------------------------------------------
    def app(self, method, path, q):
        ck = self.cookies()
        if path == "/oauth2/start":
            csrf = secrets.token_hex(8)
            state = csrf + ":" + q.get("rd", "/")
            loc = AUTH_URL + REALM + "/protocol/openid-connect/auth?" + urlencode(
                {"client_id": "teknoir", "response_type": "code", "redirect_uri": CLIENTS["teknoir"], "state": state})
            return self.send(302, location=loc, cookies=[f"{COOKIE}_csrf={csrf}; Path=/; Secure; HttpOnly"])
        if path == "/oauth2/callback":
            csrf, _, rd = q.get("state", "").partition(":")
            got = S["codes"].pop(q.get("code", ""), None)
            if not got or got[1] != "teknoir" or ck.get(COOKIE + "_csrf") != csrf:
                return self.send(403, page("oauth2-proxy: invalid callback"))
            sid = secrets.token_hex(16)
            S["o2p"][sid] = got[0]
            event("o2p-session", got[0])
            return self.send(302, location=rd or "/", cookies=[
                f"{COOKIE}={sid}; Domain={DOMAIN}; Path=/; Secure; HttpOnly; SameSite=None",
                f"{COOKIE}_csrf=; Path=/; Max-Age=0; Secure; HttpOnly"])
        if path == "/oauth2/sign_out":
            S["o2p"].pop(ck.get(COOKIE, ""), None)
            rd = q.get("rd", "/")
            host = urlparse(rd).hostname or ""
            event("sign-out")
            return self.send(302, location=rd if host == DOMAIN or host.endswith("." + DOMAIN) else "/", cookies=[
                f"{COOKIE}=; Domain={DOMAIN}; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly"])
        user = S["o2p"].get(ck.get(COOKIE, ""))
        if user is None:
            mode = (self.headers.get("Sec-Fetch-Mode") or "").lower()
            xrw = (self.headers.get("X-Requested-With") or "").lower()
            if (mode and mode not in ("navigate", "nested-navigate")) or xrw == "xmlhttprequest":
                return self.send(401)
            rd = APP_URL + self.path
            return self.send(302, location=APP_URL + "/oauth2/start?rd=" + quote(rd, safe=""), cookies=[
                f"{COOKIE}=; Domain={DOMAIN}; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly",
                f"{COOKIE}=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly"])
        if path.startswith("/teknoir-system/") and "admin" not in USERS[user]["groups"]:
            return self.send(403, "RBAC: access denied", ctype="text/plain")
        if path.startswith("/api/catalog/") and not (self.headers.get("Authorization") or "").startswith("Bearer "):
            return self.send(401, '{"error":{"name":"AuthenticationError"}}', ctype="application/json")
        if path == "/home":
            # Backstage's index.html with the runtime config the chart adds (E14)
            cfg = json.dumps({"teknoir": {"auth": {"issuer": AUTH_URL + REALM, "clientId": "teknoir"}}}, separators=(",", ":"))
            return self.send(200, "<html><head><script data-teknoir-runtime-config>window.__APP_CONFIG__=" + cfg
                             + ";</script></head><body>app /home</body></html>")
        return self.send(200, page(f"app {path}"))

    # -- Keycloak --------------------------------------------------------------
    def login_form(self, sc, feedback=""):
        a = S["auth"][sc]
        fb = f'<span id="input-error" class="kc-feedback-text" aria-live="polite">{feedback}</span>' if feedback else ""
        act = (f"{AUTH_URL}{REALM}/login-actions/authenticate?session_code={sc}&amp;execution=e1"
               f"&amp;client_id={a['client']}&amp;tab_id=t1")
        return self.send(200, page(
            f'{fb}<form id="kc-form-login" onsubmit="login.disabled = true; return true;"\n      action="{act}" method="post">'
            '<input tabindex="1" id="username" name="username" value="" type="text">'
            '<input id="password" name="password" type="password"></form>'))

    def next_step(self, sc):
        a = S["auth"][sc]
        user = a["user"]
        req = USERS[user]["required"]
        base = f"{AUTH_URL}{REALM}/login-actions/required-action?session_code={sc}&amp;execution="
        if "UPDATE_PASSWORD" in req:
            return self.send(200, page(
                f'<form id="kc-passwd-update-form" class="x" action="{base}UPDATE_PASSWORD" method="post">'
                '<input type="password" id="password-new" name="password-new">'
                '<input type="password" id="password-confirm" name="password-confirm"></form>'))
        if "UPDATE_PROFILE" in req:
            u = USERS[user]
            return self.send(200, page(
                f'<form id="kc-update-profile-form" class="x" action="{base}UPDATE_PROFILE" method="post">'
                f'<input type="text" id="email" name="email" value="{u.get("email", "")}">'
                '<input type="text" id="firstName" name="firstName" value="First">'
                '<input type="text" id="lastName" name="lastName" value=""></form>'))
        kid = secrets.token_hex(16)
        S["kc"][kid] = user
        S["auth"].pop(sc, None)
        event("kc-login", user)
        return self.redirect_code(user, a, [f"KEYCLOAK_IDENTITY={kid}; Path={REALM}/; Secure; HttpOnly"])

    def redirect_code(self, user, a, cookies=()):
        code = secrets.token_hex(12)
        S["codes"][code] = (user, a["client"])
        sep = "&" if "?" in a["redirect_uri"] else "?"
        return self.send(302, location=a["redirect_uri"] + sep + urlencode({"state": a["state"], "code": code}),
                         cookies=cookies)

    def auth(self, method, path, q):
        ck = self.cookies()
        if path == REALM + "/protocol/openid-connect/auth" and method == "GET":
            client, ru = q.get("client_id", ""), q.get("redirect_uri", "")
            if CLIENTS.get(client) != ru:
                return self.send(400, page("Invalid parameter: redirect_uri"))
            a = {"client": client, "redirect_uri": ru, "state": q.get("state", "")}
            user = S["kc"].get(ck.get("KEYCLOAK_IDENTITY", ""))
            if user is not None:
                event("kc-sso", user)
                return self.redirect_code(user, a)
            sc = secrets.token_hex(8)
            S["auth"][sc] = a
            return self.login_form(sc)
        if path == REALM + "/login-actions/authenticate" and method == "POST":
            sc = q.get("session_code", "")
            if sc not in S["auth"]:
                return self.send(400, page("session expired"))
            f = self.form()
            u = USERS.get(f.get("username", ""))
            if u is not None and not u["enabled"]:
                event("kc-disabled", f.get("username", ""))
                return self.login_form(sc, "Account is disabled, contact your administrator.")
            if u is None or f.get("password") != u["password"]:
                event("kc-bad-password", f.get("username", ""))
                return self.login_form(sc, "Invalid username or password.")
            S["auth"][sc]["user"] = f["username"]
            return self.next_step(sc)
        if path == REALM + "/login-actions/required-action" and method == "POST":
            sc = q.get("session_code", "")
            a = S["auth"].get(sc)
            if a is None or "user" not in a:
                return self.send(400, page("session expired"))
            f, user = self.form(), a["user"]
            ex = q.get("execution", "")
            if ex == "UPDATE_PASSWORD":
                new = f.get("password-new", "")
                if not new or new != f.get("password-confirm") or new == USERS[user]["password"]:
                    return self.send(200, page('<span class="kc-feedback-text">Invalid password.</span>'))
                USERS[user]["password"] = new
                event("password-changed", user)
            elif ex == "UPDATE_PROFILE":
                if not f.get("lastName"):
                    return self.send(200, page('<span class="kc-feedback-text">Please specify last name.</span>'))
                event("profile-updated", user)
            if ex in USERS[user]["required"]:
                USERS[user]["required"].remove(ex)
            return self.next_step(sc)
        if path == REALM + "/protocol/openid-connect/logout" and method == "GET":
            client, ru = q.get("client_id", ""), q.get("post_logout_redirect_uri", "")
            if client not in CLIENTS or not ru.startswith(APP_URL + "/"):
                return self.send(400, page("Invalid redirect uri"))
            kid = ck.get("KEYCLOAK_IDENTITY", "")
            if kid not in S["kc"]:
                return self.send(302, location=ru)
            lc = secrets.token_hex(8)
            S["logout"][lc] = (kid, ru)
            return self.send(200, page(
                '<div id="kc-logout-confirm" class="content-area"><p class="instruction">Do you want to log out?</p>'
                f'<form class="form-actions" action="{AUTH_URL}{REALM}/protocol/openid-connect/logout/logout-confirm" method="POST">'
                f'<input type="hidden" name="session_code" value="{lc}">'
                '<input tabindex="4" class="pf-c-button" name="confirmLogout" id="kc-logout" type="submit" value="Logout"/>'
                '</form></div>'))
        if path == REALM + "/protocol/openid-connect/logout/logout-confirm" and method == "POST":
            f = self.form()
            got = S["logout"].pop(f.get("session_code", ""), None)
            if got is None or "confirmLogout" not in f:
                return self.send(400, page("logout not confirmed"))
            user = S["kc"].pop(got[0], "")
            event("kc-logout", user)
            return self.send(302, location=got[1], cookies=[f"KEYCLOAK_IDENTITY=; Path={REALM}/; Max-Age=0; Secure; HttpOnly"])
        return self.send(404, page("not found"))

    # -- ArgoCD-like OIDC client ------------------------------------------------
    def argo(self, method, path, q):
        ck = self.cookies()
        if path == "/auth/login":
            st = secrets.token_hex(8)
            S["argo_state"][st] = q.get("return_url", ARGO_URL + "/applications")
            loc = AUTH_URL + REALM + "/protocol/openid-connect/auth?" + urlencode(
                {"client_id": "argocd", "response_type": "code", "redirect_uri": CLIENTS["argocd"], "state": st})
            return self.send(303, location=loc)
        if path == "/auth/callback":
            rd = S["argo_state"].pop(q.get("state", ""), None)
            got = S["codes"].pop(q.get("code", ""), None)
            if rd is None or not got or got[1] != "argocd":
                return self.send(401, page("invalid callback"))
            tok = secrets.token_hex(16)
            S["argo"][tok] = got[0]
            event("argocd-session", got[0])
            return self.send(303, location=rd, cookies=[f"argocd.token={tok}; Path=/; Secure; HttpOnly"])
        user = S["argo"].get(ck.get("argocd.token", ""))
        if path == "/api/v1/applications":
            if user is None:
                return self.send(401, '{"error":"no session"}', ctype="application/json")
            items = [{"metadata": {"name": "app-of-apps"}}] if "admin" in USERS[user]["groups"] else None
            return self.send(200, json.dumps({"items": items, "metadata": {}}), ctype="application/json")
        return self.send(200, page("argocd"))


ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
