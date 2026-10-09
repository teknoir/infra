#!/usr/bin/env bash
# rotate-argocd-admin-test.sh — unit test (no cluster) of lib/secrets.sh's
# `rotate argocd-admin` (DESIGN D10, SEC-C9) and `credentials argocd-admin`,
# with kc(), in_cluster() and the login check replaced by recorders:
#
#   1. the happy path: `argocd account bcrypt` in the argocd-server container
#      with the password on stdin only (no --password: in no argv), then Secret argocd-admin-break-glass, then one merge
#      patch of argocd-secret with exactly admin.password (the hash) and
#      admin.passwordMtime from a 0600 file, then the login check, and only
#      after its 200 the delete of argocd-initial-admin-secret; the password
#      is in no argv and no output;
#   2. a bcrypt failure, or output that is no bcrypt hash: nothing is written;
#   3. a login that keeps failing: argocd-initial-admin-secret stays, and the
#      check stops after ARGOCD_LOGIN_ATTEMPTS; 401 then 200 deletes it;
#   4. an existing break-glass Secret is patched, not re-created; an absent
#      initial Secret is not deleted; a failed argocd-secret patch stops it;
#   5. --dry-run changes nothing;
#   6. the login check sends the password only in curl's config on a pipe, to
#      https://argocd.<domain>/api/v1/session through NODE_IP;
#   7. credentials argocd-admin reads argocd-admin-break-glass, and before the
#      first rotation ArgoCD's initial password with a warning.
#
# Usage: airgap/test/unit/rotate-argocd-admin-test.sh
# shellcheck disable=SC2016  # the scenario scripts expand in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn-rot-argocd.XXXXXX")"
trap '[[ -n "${KEEP:-}" ]] || rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/node/bin" "${WORK}/tmp" "${WORK}/bin"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"
ln -s "${REPO}/airgap/node/lib" "${WORK}/node/lib"   # secrets.sh sources NODE_ROOT/lib/common.sh
FAKE_HASH='$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234'

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }

# scenario VAR=VALUE... — run cmd_rotate argocd-admin in a fresh bash with the
# recorders. Knobs: BG (break-glass exists 0|1), INIT (initial secret exists
# 0|1), DEPLOY (0|1), BCRYPT (ok: "Password: <hash>" as ArgoCD 3.5 prints it |
# bare: the hash alone | fail | garbage), PATCH_FAIL (0|1), LOGIN_CODES
# (space-separated answers of the login check), DRY (0|1).
# Records in ${WORK}/rec: calls (one per kc call, argv only), stdin.bcrypt (the
# value given to bcrypt), create.json, patch-*.json (+ .mode), logins.
scenario() {
  local rc=0
  rm -rf "${WORK}/rec"; mkdir -p "${WORK}/rec"
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" REC="${WORK}/rec" \
    TEKNOIR_DOMAIN=teknoir.airgapped NODE_IP=192.0.2.10 FAKE_HASH="${FAKE_HASH}" \
    COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/secrets.sh" \
    BG=0 INIT=1 DEPLOY=1 BCRYPT=ok PATCH_FAIL=0 LOGIN_CODES=200 DRY=0 ARGOCD_LOGIN_DELAY=0 "$@" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      source "${LIB}"
      DRY_RUN="${DRY}"
      cluster_up() { return 0; }
      in_cluster() {
        case "$1 $2" in
          "deployment argo-argocd-server") [[ "${DEPLOY}" == 1 ]] ;;
          "secret argocd-secret") return 0 ;;
          "secret argocd-admin-break-glass") [[ "${BG}" == 1 ]] ;;
          "secret argocd-initial-admin-secret") [[ "${INIT}" == 1 ]] ;;
          *) return 1 ;;
        esac
      }
      kc() {
        printf "%s\n" "$*" >> "${REC}/calls"
        local a f="" prev=""
        for a in "$@"; do [[ "${prev}" == --patch-file ]] && f="${a}"; prev="${a}"; done
        case " $* " in
          *" exec -i deploy/argo-argocd-server -c server -- argocd account bcrypt ")
            cat > "${REC}/stdin.bcrypt"
            case "${BCRYPT}" in
              ok) printf "Password: %s" "${FAKE_HASH}" ;;
              bare) printf "%s\n" "${FAKE_HASH}" ;;
              real) HOME="${REC}" argocd account bcrypt < "${REC}/stdin.bcrypt" ;;   # the CLI needs a HOME
              garbage) echo "Error: something" ;;
              *) return 1 ;;
            esac ;;
          *" patch secret argocd-admin-break-glass "*)
            cp "${f}" "${REC}/patch-bg.json"; stat -c %a "${f}" > "${REC}/patch-bg.mode" ;;
          *" patch secret argocd-secret "*)
            cp "${f}" "${REC}/patch-argocd.json"; stat -c %a "${f}" > "${REC}/patch-argocd.mode"
            [[ "${PATCH_FAIL}" == 0 ]] ;;
          *" create -f - "*) cat > "${REC}/create.json" ;;
          *" delete secret argocd-initial-admin-secret"*) ;;
          *) return 1 ;;
        esac
      }
      read -r -a _codes <<<"${LOGIN_CODES}"
      _n=0
      _secrets_argocd_login() {
        # the real one runs in $(...): count through a file
        local i; i=$(wc -l < "${REC}/logins" 2>/dev/null || echo 0)
        [[ "${!1}" == "$(cat "${REC}/stdin.bcrypt")" ]] && echo same >> "${REC}/logins" || echo other >> "${REC}/logins"
        printf "%s" "${_codes[i]:-${_codes[-1]}}"
      }
      cmd_rotate argocd-admin
    ' > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}

has()   { grep -qE -- "$1" "$2"; }
calls() { cat "${WORK}/rec/calls" 2>/dev/null || true; }
nth()   { calls | grep -nE -- "$1" | head -1 | cut -d: -f1; }
pw()    { tr -d '\n' < "${WORK}/rec/stdin.bcrypt"; }

echo "# 1. happy path: bcrypt, break-glass, argocd-secret, login 200, then delete"
scenario
check "rc 0" has '^rc=0$' "${WORK}/out"
check "the value for bcrypt is 32 alphanumerics on stdin" bash -c "[[ \"\$(tr -d '\n' < '${WORK}/rec/stdin.bcrypt')\" =~ ^[A-Za-z0-9]{32}\$ ]]"
check "bcrypt runs as 'argocd account bcrypt' (stdin, no --password) in container server" \
  bash -c "grep -qx -- '-n teknoir-system exec -i deploy/argo-argocd-server -c server -- argocd account bcrypt' '${WORK}/rec/calls'"
check "order: bcrypt < break-glass create < argocd-secret patch < initial delete" \
  bash -c "[ $(nth 'exec -i') -lt $(nth 'create -f -') ] && [ $(nth 'create -f -') -lt $(nth 'patch secret argocd-secret') ] && [ $(nth 'patch secret argocd-secret') -lt $(nth 'delete secret argocd-initial-admin-secret') ]"
check "the break-glass Secret: name, namespace, label, annotation, password = the bcrypt input" \
  bash -c "jq -e --arg p \"\$(tr -d '\n' < '${WORK}/rec/stdin.bcrypt')\" '.kind == \"Secret\" and .metadata.name == \"argocd-admin-break-glass\" and .metadata.namespace == \"teknoir-system\" and .metadata.labels[\"app.kubernetes.io/managed-by\"] == \"teknoir-node\" and (.metadata.annotations[\"teknoir.org/rotated-at\"] | test(\"^[0-9-]+T[0-9:]+Z\$\")) and (.data.password | @base64d) == \$p' '${WORK}/rec/create.json' >/dev/null"
check "argocd-secret patch: exactly admin.password (the hash) and admin.passwordMtime (now)" \
  bash -c "jq -e --arg h '${FAKE_HASH}' '(.data | keys) == [\"admin.password\", \"admin.passwordMtime\"] and (.data[\"admin.password\"] | @base64d) == \$h and (.data[\"admin.passwordMtime\"] | @base64d | test(\"^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\$\")) and (keys == [\"data\"])' '${WORK}/rec/patch-argocd.json' >/dev/null"
check "the argocd-secret patch file was 0600" [ "$(cat "${WORK}/rec/patch-argocd.mode")" == 600 ]
check "one login check, with the new password" [ "$(cat "${WORK}/rec/logins")" == same ]
check "the password is in no kubectl argv" bash -c "! grep -qF \"\$(tr -d '\n' < '${WORK}/rec/stdin.bcrypt')\" '${WORK}/rec/calls'"
check "neither the password nor the hash is printed" \
  bash -c "! grep -qF \"\$(tr -d '\n' < '${WORK}/rec/stdin.bcrypt')\" '${WORK}/out' && ! grep -qF '${FAKE_HASH}' '${WORK}/out'"
check "the summary names the three changes" \
  bash -c "grep -q 'stored the new ArgoCD admin password' '${WORK}/out' && grep -q 'set the new ArgoCD admin password' '${WORK}/out' && grep -q 'deleted teknoir-system/argocd-initial-admin-secret' '${WORK}/out'"

scenario BCRYPT=bare
check "a bare hash on stdout (no prompt) is accepted too" \
  bash -c "grep -q '^rc=0\$' '${WORK}/out' && jq -e --arg h '${FAKE_HASH}' '(.data[\"admin.password\"] | @base64d) == \$h' '${WORK}/rec/patch-argocd.json' >/dev/null"

if command -v argocd >/dev/null 2>&1 && argocd account bcrypt --help 2>/dev/null | grep -q 'Read password from stdin'; then
  scenario BCRYPT=real
  real_hash="$(jq -r '.data["admin.password"] | @base64d' "${WORK}/rec/patch-argocd.json" 2>/dev/null || true)"
  check "the real argocd CLI ($(argocd version --client --short 2>/dev/null | head -1)) reads stdin; rc 0" grep -q '^rc=0$' "${WORK}/out"
  check "its output (\"Password: <hash>\") parses to the bcrypt hash that is patched in" \
    grep -qE '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$' <<<"${real_hash}"
else
  echo "  skip the real argocd CLI (not installed, or without bcrypt from stdin)"
fi

echo "# 2. bcrypt fails or returns no hash: nothing is written"
for mode in fail garbage; do
  scenario BCRYPT="${mode}"
  check "bcrypt ${mode}: rc != 0, 'nothing was changed'" bash -c "! grep -q '^rc=0\$' '${WORK}/out' && grep -q 'nothing was changed' '${WORK}/out'"
  check "bcrypt ${mode}: no create, patch or delete" bash -c "! grep -qE 'create|patch|delete' '${WORK}/rec/calls'"
done

echo "# 3. the login check gates the delete"
scenario LOGIN_CODES="401 401 401 401 401 401" ARGOCD_LOGIN_ATTEMPTS=4
check "a login that keeps failing fails the rotation" bash -c "! grep -q '^rc=0\$' '${WORK}/out' && grep -q 'argocd-initial-admin-secret was kept' '${WORK}/out'"
check "argocd-initial-admin-secret is not deleted" bash -c "! grep -q 'delete' '${WORK}/rec/calls'"
check "exactly ARGOCD_LOGIN_ATTEMPTS (4) login attempts" [ "$(wc -l < "${WORK}/rec/logins")" == 4 ]
scenario LOGIN_CODES="401 200"
check "401 then 200: rc 0 and the delete follows the second attempt" \
  bash -c "grep -q '^rc=0\$' '${WORK}/out' && [ \$(wc -l < '${WORK}/rec/logins') = 2 ] && grep -q 'delete secret argocd-initial-admin-secret' '${WORK}/rec/calls'"

echo "# 4. existing break-glass, absent initial secret, failed argocd-secret patch"
scenario BG=1 INIT=0
check "an existing break-glass Secret is patched (0600 file: password + rotated-at), not created" \
  bash -c "grep -q '^rc=0\$' '${WORK}/out' && ! grep -q 'create -f -' '${WORK}/rec/calls' && [ \"\$(cat '${WORK}/rec/patch-bg.mode')\" = 600 ] && jq -e --arg p \"\$(tr -d '\n' < '${WORK}/rec/stdin.bcrypt')\" '(.data.password | @base64d) == \$p and (.metadata.annotations | has(\"teknoir.org/rotated-at\"))' '${WORK}/rec/patch-bg.json' >/dev/null"
check "no initial Secret: no delete" bash -c "! grep -q 'delete' '${WORK}/rec/calls'"
scenario PATCH_FAIL=1
check "a failed argocd-secret patch stops before the login check and the delete" \
  bash -c "! grep -q '^rc=0\$' '${WORK}/out' && grep -q 'run rotate argocd-admin again' '${WORK}/out' && [ ! -s '${WORK}/rec/logins' ] && ! grep -q delete '${WORK}/rec/calls'"
scenario DEPLOY=0
check "no argocd-server Deployment: refused before anything runs" bash -c "! grep -q '^rc=0\$' '${WORK}/out' && [ ! -s '${WORK}/rec/calls' ]"

echo "# 5. dry-run"
scenario DRY=1
check "--dry-run: rc 0, a would-change line, no kubectl write or exec" \
  bash -c "grep -q '^rc=0\$' '${WORK}/out' && grep -q 'would change: set a new ArgoCD admin password' '${WORK}/out' && [ ! -s '${WORK}/rec/calls' ]"

echo "# 6. the login check's request"
cat > "${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
# stub curl: records argv and the -K config; answers with ${CURL_CODE}
printf '%s\n' "$*" > "${REC}/curl.argv"
prev=""
for a in "$@"; do [[ "${prev}" == -K ]] && cat "${a}" > "${REC}/curl.cfg"; prev="${a}"; done
printf '%s' "${CURL_CODE:-200}"
EOF
chmod +x "${WORK}/bin/curl"
rm -rf "${WORK}/rec"; mkdir -p "${WORK}/rec"
PW='Abc123xyz"quote\back'
code="$(env -i PATH="${WORK}/bin:${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" REC="${WORK}/rec" CURL_CODE=401 \
  TEKNOIR_DOMAIN=teknoir.airgapped NODE_IP=192.0.2.10 PW="${PW}" \
  COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/secrets.sh" \
  bash -c '
    set -euo pipefail
    source "${COMMON}"; source "${LIB}"
    in_cluster() { return 0; }
    secret_value() { printf -- "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"; }
    ensure_work_dir
    pass="${PW}"
    _secrets_argocd_login pass' 2>"${WORK}/out")" || true
check "it returns curl's HTTP status" [ "${code}" == 401 ]
check "the password is not in curl's argv" bash -c "! grep -qF 'Abc123xyz' '${WORK}/rec/curl.argv'"
check "POST to https://argocd.<domain>/api/v1/session through NODE_IP with the platform CA" \
  bash -c "grep -q -- '--resolve argocd.teknoir.airgapped:443:192.0.2.10' '${WORK}/rec/curl.argv' && grep -q -- '--cacert ' '${WORK}/rec/curl.argv' && grep -q 'https://argocd.teknoir.airgapped/api/v1/session\$' '${WORK}/rec/curl.argv'"
# curl unescapes the config value; jq then must read back the exact password
check "the config carries the JSON body {username: admin, password} (quotes and backslashes escaped)" \
  bash -c "grep -qx 'header = \"Content-Type: application/json\"' '${WORK}/rec/curl.cfg' && sed -n 's/^data = \"\\(.*\\)\"\$/\\1/p' '${WORK}/rec/curl.cfg' | sed -e 's/\\\\\\(.\\)/\\1/g' | jq -e --arg p '${PW}' '.username == \"admin\" and .password == \$p' >/dev/null"

echo "# 6b. the same request with the real curl, against a local HTTP server"
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  cat > "${WORK}/server.py" <<'EOF'
import http.server, json, sys
out, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(out, "w") as f:
            json.dump({"path": self.path, "ctype": self.headers.get("Content-Type"), "body": body.decode()}, f)
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"token":"x"}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.handle_request()
EOF
  python3 -I "${WORK}/server.py" "${WORK}/req.json" "${WORK}/port" &
  srv=$!
  for _ in $(seq 50); do [[ -s "${WORK}/port" ]] && break; sleep 0.1; done
  code="$(env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" PW="${PW}" \
    TEKNOIR_DOMAIN=teknoir.airgapped NODE_IP=192.0.2.10 ARGOCD_URL="http://127.0.0.1:$(cat "${WORK}/port")" \
    COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/secrets.sh" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"; source "${LIB}"
      in_cluster() { return 0; }
      secret_value() { printf -- "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"; }
      ensure_work_dir
      pass="${PW}"
      _secrets_argocd_login pass' 2>"${WORK}/out")" || true
  wait "${srv}" 2>/dev/null || true
  check "real curl: HTTP 200 from the server" [ "${code}" == 200 ]
  check "real curl: POST /api/v1/session, JSON, and the exact password arrives" \
    bash -c "jq -e --arg p '${PW}' '.path == \"/api/v1/session\" and .ctype == \"application/json\" and (.body | fromjson | .username == \"admin\" and .password == \$p)' '${WORK}/req.json' >/dev/null"
else
  echo "  skip (python3 or curl missing)"
fi

echo "# 7. credentials argocd-admin"
cred() {
  # cred <BG 0|1> <INIT 0|1>: run cmd_credentials argocd-admin --out FILE
  rm -f "${WORK}/cred.txt"
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" BG="$1" INIT="$2" OUT="${WORK}/cred.txt" \
    COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/secrets.sh" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"; source "${LIB}"
      cluster_up() { return 0; }
      in_cluster() {
        case "$2" in
          argocd-admin-break-glass) [[ "${BG}" == 1 ]] ;;
          argocd-initial-admin-secret) [[ "${INIT}" == 1 ]] ;;
          *) return 1 ;;
        esac
      }
      secret_value() { printf "value-of-%s-%s" "$2" "$3"; }
      cmd_credentials argocd-admin --out "${OUT}"' > "${WORK}/out" 2>&1 && echo ok || echo failed
}
r="$(cred 1 1)"
check "with argocd-admin-break-glass: its password, mode 0600, no warning" \
  bash -c "[ '${r}' = ok ] && [ \"\$(cat '${WORK}/cred.txt')\" = value-of-argocd-admin-break-glass-password ] && [ \$(stat -c %a '${WORK}/cred.txt') = 600 ] && ! grep -q WARN '${WORK}/out'"
r="$(cred 0 1)"
check "before the first rotation: ArgoCD's initial password, with a warning to rotate" \
  bash -c "[ '${r}' = ok ] && [ \"\$(cat '${WORK}/cred.txt')\" = value-of-argocd-initial-admin-secret-password ] && grep -q 'not rotated yet' '${WORK}/out'"
r="$(cred 0 0)"
check "neither Secret: fails" bash -c "[ '${r}' = failed ] && [ ! -e '${WORK}/cred.txt' ]"

echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
