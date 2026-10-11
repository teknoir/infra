#!/usr/bin/env bats
# kc_login.bats — kc-login.sh and the E14 checks of e2e.sh against
# stubs/fake-sso.py, a local HTTPS stand-in for oauth2-proxy, Keycloak (realm
# teknoir) and an OIDC client like ArgoCD. No VM and no network: everything
# listens on 127.0.0.1, and curl maps the three names to it through a .curlrc
# in CURL_HOME. The CA, the server key and every password are throwaway files
# in the test's temp dir.

# shellcheck disable=SC2016,SC2030,SC2031  # code strings for the inner shells; bats runs each test in a subshell

load test_helper

KCLOGIN="${REPO_ROOT}/airgap/test/vm/kc-login.sh"
E2E="${REPO_ROOT}/airgap/test/vm/e2e.sh"
FAKE="${REPO_ROOT}/airgap/test/stubs/fake-sso.py"

setup_file() {
  local d="${BATS_FILE_TMPDIR}" port u t
  for t in openssl python3 curl jq; do command -v "${t}" >/dev/null || skip "${t} not installed"; done
  ( umask 077
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=fake-sso test CA' \
      -keyout "${d}/ca.key" -out "${d}/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj '/CN=teknoir.test' -keyout "${d}/srv.key" -out "${d}/srv.csr" 2>/dev/null
    printf 'subjectAltName=DNS:teknoir.test,DNS:auth.teknoir.test,DNS:argocd.teknoir.test\n' > "${d}/san.ext"
    openssl x509 -req -in "${d}/srv.csr" -CA "${d}/ca.crt" -CAkey "${d}/ca.key" -CAcreateserial -days 1 \
      -extfile "${d}/san.ext" -out "${d}/srv.crt" 2>/dev/null
    for u in admin viewer noname disabled; do head -c 18 /dev/urandom | base64 | tr -d '/+=\n' > "${d}/${u}.pw"; done )
  cat > "${d}/users.json" <<EOF
{"admin@example.com": {"password_file": "${d}/admin.pw", "email": "admin@example.com", "groups": ["admin"], "required": ["UPDATE_PASSWORD"]},
 "viewer@example.com": {"password_file": "${d}/viewer.pw", "email": "viewer@example.com", "required": ["UPDATE_PASSWORD"]},
 "noname@example.com": {"password_file": "${d}/noname.pw", "email": "noname@example.com", "required": ["UPDATE_PROFILE"]},
 "platform-admin": {"password_file": "${d}/disabled.pw", "enabled": false}}
EOF
  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  python3 -I "${FAKE}" "${port}" "${d}/srv.crt" "${d}/srv.key" "${d}/users.json" "${d}/events.log" teknoir.test \
    >"${d}/server.log" 2>&1 3>&- &
  echo $! > "${d}/pid"
  printf 'resolve = "%s:%s:127.0.0.1"\n' teknoir.test "${port}" auth.teknoir.test "${port}" argocd.teknoir.test "${port}" > "${d}/.curlrc"
  export CURL_HOME="${d}" SSO_DIR="${d}" SSO_PORT="${port}" APP="https://teknoir.test:${port}"
  for _ in $(seq 1 50); do
    curl -s --cacert "${d}/ca.crt" -o /dev/null "${APP}/oauth2/start" && return 0
    sleep 0.1
  done
  echo "fake-sso did not start: $(cat "${d}/server.log")" >&2
  return 1
}

teardown_file() {
  [[ -f "${SSO_DIR:-}/pid" ]] && kill "$(cat "${SSO_DIR}/pid")" 2>/dev/null
  return 0
}

kcl() { "${KCLOGIN}" --cacert "${SSO_DIR}/ca.crt" "$@"; }

no_password_in() {
  # no_password_in <text> — none of the test passwords appears in <text>
  local f
  for f in "${SSO_DIR}"/*.pw "${SSO_DIR}"/*.new; do
    [[ -s "${f}" ]] || continue
    if grep -qF -- "$(cat "${f}")" <<<"$1"; then echo "the value of ${f} was printed"; return 1; fi
  done
}

@test "kc-login: a first login changes the temporary password into a new 0600 file and keeps the session in the jar" {
  run kcl --url "${APP}/teknoir-system/grafana/" --user admin@example.com --password-file "${SSO_DIR}/admin.pw" \
    --new-password-file "${SSO_DIR}/admin.new" --cookie-jar "${SSO_DIR}/admin.jar"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"required action Update Password"* && "${output}" == *"login ok: HTTP 200"* ]]
  [ -s "${SSO_DIR}/admin.new" ]
  [ "$(stat -c %a "${SSO_DIR}/admin.new")" = 600 ]
  [ "$(stat -c %a "${SSO_DIR}/admin.jar")" = 600 ]
  grep -qx 'password-changed admin@example.com' "${SSO_DIR}/events.log"
  grep -q '_teknoir_oauth2_proxy' "${SSO_DIR}/admin.jar"
  no_password_in "${output}"
}

@test "kc-login: the new password signs in; the temporary one is refused with Keycloak's message" {
  run kcl --url "${APP}/" --user admin@example.com --password-file "${SSO_DIR}/admin.pw" --cookie-jar "${SSO_DIR}/old.jar"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Keycloak rejected the login: Invalid username or password."* ]]
  rm -f "${SSO_DIR}/admin.jar"
  run kcl --url "${APP}/teknoir-system/grafana/" --user admin@example.com --password-file "${SSO_DIR}/admin.new" \
    --cookie-jar "${SSO_DIR}/admin.jar" --forbid-profile-form
  [ "${status}" -eq 0 ]
  no_password_in "${output}"
}

@test "kc-login: --forbid-profile-form fails on Update Profile; without it the form is answered" {
  run kcl --url "${APP}/" --user noname@example.com --password-file "${SSO_DIR}/noname.pw" --forbid-profile-form
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Update Profile form"*"forbidden by --forbid-profile-form"* ]]
  refute_grep -q 'profile-updated noname' "${SSO_DIR}/events.log"
  run kcl --url "${APP}/" --user noname@example.com --password-file "${SSO_DIR}/noname.pw"
  [ "${status}" -eq 0 ]
  grep -qx 'profile-updated noname@example.com' "${SSO_DIR}/events.log"
}

@test "kc-login: a non-admin realm user's 403 is a failure by default and accepted with --accept-status 403" {
  run kcl --url "${APP}/teknoir-system/grafana/" --user viewer@example.com --password-file "${SSO_DIR}/viewer.pw" \
    --new-password-file "${SSO_DIR}/viewer.new" --cookie-jar "${SSO_DIR}/viewer.jar"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"login failed: HTTP 403"* ]]
  rm -f "${SSO_DIR}/viewer.jar"
  run kcl --url "${APP}/teknoir-system/grafana/" --user viewer@example.com --password-file "${SSO_DIR}/viewer.new" \
    --cookie-jar "${SSO_DIR}/viewer.jar" --accept-status 403
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"login ok: HTTP 403"* ]]
}

@test "kc-login: the Keycloak SSO session in the jar signs in to an OIDC client without the form (--session-cookie)" {
  local argo="https://argocd.teknoir.test:${SSO_PORT}" n
  run kcl --cookie-jar "${SSO_DIR}/admin.jar" --session-cookie argocd.token \
    --url "${argo}/auth/login?return_url=https%3A%2F%2Fargocd.teknoir.test%3A${SSO_PORT}%2Fapplications"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"signed in through the session in the jar"* ]]
  grep -qx 'kc-sso admin@example.com' "${SSO_DIR}/events.log"
  n="$(curl -sS --cacert "${SSO_DIR}/ca.crt" -b "${SSO_DIR}/admin.jar" "${argo}/api/v1/applications" | jq '(.items // []) | length')"
  [ "${n}" = 1 ]
  run kcl --cookie-jar "${SSO_DIR}/viewer.jar" --session-cookie argocd.token --url "${argo}/auth/login"
  [ "${status}" -eq 0 ]
  n="$(curl -sS --cacert "${SSO_DIR}/ca.crt" -b "${SSO_DIR}/viewer.jar" "${argo}/api/v1/applications" | jq '(.items // []) | length')"
  [ "${n}" = 0 ]
  # no SSO session and no credentials: a clear failure
  run kcl --cookie-jar "${SSO_DIR}/empty.jar" --session-cookie argocd.token --url "${argo}/auth/login"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pass --user and --password-file"* ]]
}

@test "kc-login: a disabled user is refused with Keycloak's 'Account is disabled'" {
  run kcl --url "${APP}/" --user platform-admin --password-file "${SSO_DIR}/disabled.pw"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Account is disabled, contact your administrator."* ]]
  no_password_in "${output}"
}

@test "kc-login --logout: sign_out, the Keycloak confirmation, the app, /oauth2/start, the login form" {
  run kcl --logout --url "${APP}/" --cookie-jar "${SSO_DIR}/admin.jar"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"logout 1/5"*"logout 2/5"*"logout 3/5"*"logout 4/5"*"logout 5/5: /oauth2/start shows the Keycloak login form"* ]]
  grep -qx 'kc-logout admin@example.com' "${SSO_DIR}/events.log"
  # signed out of both: no session left to log out
  run kcl --logout --url "${APP}/" --cookie-jar "${SSO_DIR}/admin.jar"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"no oauth2-proxy session"* ]]
}

@test "e2e.sh E14 checks pass against the stand-in (garbage cookie, XHR 401, upstream 401 passthrough, logout)" {
  run bash -c "
    LAN_HOME='${SSO_DIR}/lanhome' E2E_WORK='${SSO_DIR}/e2e'; source '${E2E}'
    mkdir -p \"\${LAN_HOME}/e2e\" \"\${HTTP_DIR}\"; TRANSCRIPT=\"\${E2E_WORK}/transcript.log\"; : > \"\${TRANSCRIPT}\"
    cp '${SSO_DIR}/admin.new' \"\${LAN_HOME}/e2e/admin.new\"
    DOMAIN='teknoir.test:${SSO_PORT}' LOGIN_URL='${APP}/teknoir-system/grafana/'
    set_admin admin@example.com
    lan() { local d=\"\$1\"; shift; ( cd \"\${d}\" && \"\$@\" ) 2>&1 | tee -a \"\${TRANSCRIPT}\"; return \"\${PIPESTATUS[0]}\"; }
    ca_file() { echo '${SSO_DIR}/ca.crt'; }
    oauth2_cookie() { echo _teknoir_oauth2_proxy; }
    http_to_https_check() { :; }   # no plain-HTTP listener here
    tl_case T 'e14 against fake-sso'
    e14_checks
    echo \"FAILED=\${TL_NFAIL} PASSED=\${TL_NPASS}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"FAILED=0 PASSED=8"* ]] || { echo "${output}"; return 1; }
  no_password_in "${output}"
}
