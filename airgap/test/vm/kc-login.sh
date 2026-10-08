#!/usr/bin/env bash
# kc-login.sh — scripted browser login through oauth2-proxy and Keycloak (VM e2e E1, E8).
#
# Runs inside the LAN network namespace (lan-netns.sh exec), where the
# *.<domain> names resolve to the VM. It follows the real browser flow with a
# cookie jar: protected URL -> oauth2-proxy -> Keycloak login form -> required
# actions (Update Password, Update Profile) -> /oauth2/callback -> the app.
#
# Passwords never appear in argv, output or logs: they are read from files and
# handed to curl with --data-urlencode name@file.
#
# Usage: kc-login.sh --cacert CA --url URL --user NAME --password-file FILE
#                    [--new-password-file FILE]
#   --new-password-file  used when Keycloak forces a password change; created
#                        (mode 0600, random) when it does not exist, so the
#                        caller learns the new password. After a forced change
#                        the caller must use this file as the password.
# Exit 0 when the final page is served by the protected host with an
# oauth2-proxy session cookie; 1 otherwise; 2 on usage errors.
set -euo pipefail

CACERT="" URL="" LOGIN_USER="" PWFILE="" NEWPWFILE=""
work="" jar="" page="" CODE="" EFF=""

say() { printf '[kc-login] %s\n' "$*" >&2; }

parse_args() {
while (( $# )); do
  case "$1" in
    --cacert) CACERT="$2"; shift ;;
    --url) URL="$2"; shift ;;
    --user) LOGIN_USER="$2"; shift ;;
    --password-file) PWFILE="$2"; shift ;;
    --new-password-file) NEWPWFILE="$2"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'kc-login: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[[ -f "${CACERT}" && -n "${URL}" && -n "${LOGIN_USER}" && -f "${PWFILE}" ]] || { echo "kc-login: --cacert, --url, --user and --password-file are required" >&2; exit 2; }
}

nonl() {
  # nonl <src> <dst> — copy a secret file without its trailing newline(s)
  local v
  v="$(cat "$1")"
  ( umask 077; printf '%s' "${v}" > "$2" )
}

fetch() {
  # fetch <curl args...> — follow redirects; sets CODE and EFF (final URL)
  local out
  out="$(curl -sS --cacert "${CACERT}" -c "${jar}" -b "${jar}" -L --max-redirs 20 \
           -o "${page}" -w '%{http_code} %{url_effective}' "$@")" || return 1
  CODE="${out%% *}" EFF="${out#* }"
}

form_action() {
  # form_action <form-id> — the unescaped action URL of that form, or nothing
  tr '\n' ' ' < "${page}" | grep -oE "<form[^>]*id=\"$1\"[^>]*>" | head -1 |
    grep -oE 'action="[^"]*"' | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g' || true
}

input_value() {
  # input_value <name> — the value attribute of an input field
  tr '\n' ' ' < "${page}" | grep -oE "<input[^>]*name=\"$1\"[^>]*>" | head -1 |
    grep -oE 'value="[^"]*"' | sed -e 's/^value="//' -e 's/"$//' || true
}

main() {
parse_args "$@"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
chmod 700 "${work}"
jar="${work}/jar" page="${work}/page.html"
origin="$(sed -E 's|^(https?://[^/]+).*|\1|' <<<"${URL}")"
nonl "${PWFILE}" "${work}/pw"

fetch "${URL}" || { say "cannot reach ${URL}"; exit 1; }
act="$(form_action kc-form-login)"
if [[ -z "${act}" ]] && grep -q 'oauth2/start' "${page}"; then
  # oauth2-proxy's own sign-in page (provider button not skipped)
  fetch "${origin}/oauth2/start?rd=%2F" || { say "oauth2/start failed"; exit 1; }
  act="$(form_action kc-form-login)"
fi
[[ -n "${act}" ]] || { say "no Keycloak login form (HTTP ${CODE} at ${EFF})"; exit 1; }
say "login form at $(sed -E 's|\?.*||' <<<"${act}")"
fetch --data-urlencode "username=${LOGIN_USER}" --data-urlencode "password@${work}/pw" --data-urlencode "credentialId=" "${act}" \
  || { say "posting the login form failed"; exit 1; }

for _ in 1 2 3 4; do
  if act="$(form_action kc-passwd-update-form)" && [[ -n "${act}" ]]; then
    [[ -n "${NEWPWFILE}" ]] || { say "Keycloak requires a password change; pass --new-password-file"; exit 1; }
    if [[ ! -s "${NEWPWFILE}" ]]; then
      ( umask 077; head -c 24 /dev/urandom | base64 | tr -d '/+=\n' > "${NEWPWFILE}" )
      say "required action Update Password: new password written to ${NEWPWFILE} (0600)"
    fi
    nonl "${NEWPWFILE}" "${work}/newpw"
    fetch --data-urlencode "password-new@${work}/newpw" --data-urlencode "password-confirm@${work}/newpw" "${act}" \
      || { say "posting the password update failed"; exit 1; }
  elif act="$(form_action kc-update-profile-form)" && [[ -n "${act}" ]]; then
    local_email="$(input_value email)"
    say "required action Update Profile"
    fetch --data-urlencode "email=${local_email:-${LOGIN_USER}@example.invalid}" \
          --data-urlencode "firstName=$(input_value firstName | grep . || echo Platform)" \
          --data-urlencode "lastName=$(input_value lastName | grep . || echo Admin)" "${act}" \
      || { say "posting the profile update failed"; exit 1; }
  else
    break
  fi
done

if grep -qiE 'Invalid username or password|kc-feedback-text|alert-error' "${page}" && [[ "${EFF}" == *"/realms/"* ]]; then
  say "Keycloak rejected the login (HTTP ${CODE} at $(sed -E 's|\?.*||' <<<"${EFF}"))"
  exit 1
fi
final_host="$(sed -E 's|^https?://([^/:]+).*|\1|' <<<"${EFF}")"
if [[ "${final_host}" != auth.* ]] && (( CODE >= 200 && CODE < 400 )) && grep -q '_oauth2_proxy' "${jar}"; then
  say "login ok: HTTP ${CODE} at $(sed -E 's|\?.*||' <<<"${EFF}") with an oauth2-proxy session"
  exit 0
fi
say "login failed: HTTP ${CODE} at $(sed -E 's|\?.*||' <<<"${EFF}")"
exit 1
}

# Sourcing (unit tests) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
