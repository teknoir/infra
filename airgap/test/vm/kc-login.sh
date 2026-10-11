#!/usr/bin/env bash
# kc-login.sh — scripted browser login and logout through oauth2-proxy and
# Keycloak (VM e2e E1, E8, E10, E11, E13, E14, E15).
#
# Runs inside the LAN network namespace (lan-netns.sh exec), where the
# *.<domain> names resolve to the VM. It follows the real browser flow with a
# cookie jar: protected URL -> oauth2-proxy (or an OIDC client such as ArgoCD
# or Harbor) -> Keycloak login form -> required actions (Update Password,
# Update Profile) -> callback -> the app.
#
# Passwords never appear in argv, output or logs: they are read from files and
# handed to curl with --data-urlencode name@file.
#
# Usage: kc-login.sh --cacert CA --url URL --user NAME --password-file FILE
#                    [--new-password-file FILE] [--cookie-jar FILE]
#                    [--forbid-profile-form] [--session-cookie NAME]
#                    [--accept-status CODES]
#        kc-login.sh --logout --cacert CA --url ORIGIN --cookie-jar FILE
#                    [--issuer URL] [--client-id ID]
#   --user               the Keycloak username; for a user that
#                        `teknoir-airgap admin-user` created this is its
#                        e-mail address (user-controller's username)
#   --password-file      the current password; for a new admin-user admin the
#                        temporary one from its --out file
#   --new-password-file  used when Keycloak forces a password change (always at
#                        the first login of a new user: its password is
#                        temporary); created (mode 0600, random) when it does
#                        not exist, so the caller learns the new password.
#                        After a forced change the caller must use this file
#                        as the password.
#   --cookie-jar FILE    the cookie jar to use and keep (mode 0600). Cookies in
#                        it are sent: with the Keycloak SSO session of an
#                        earlier login, another client (ArgoCD, Harbor) signs
#                        in without the form, and --user/--password-file may
#                        be left out. Remove the file first for a fresh login.
#                        Without it a private jar is used and deleted.
#   --forbid-profile-form  fail when Keycloak shows the Update Profile form
#                        (a user without a last name under VERIFY_PROFILE)
#   --session-cookie NAME  the cookie that proves the app session: NAME or its
#                        split parts NAME_0, NAME_1, ... (default: the
#                        oauth2-proxy session cookie, any name ending in
#                        oauth2_proxy, never its _csrf cookie). ArgoCD:
#                        argocd.token; Harbor: sid
#   --accept-status CODES  final HTTP status codes that count as signed in,
#                        comma-separated (default: any 2xx or 3xx); e.g. 403
#                        for a non-admin realm user at an admin-only app
# Update Profile (Keycloak 26 asks for a missing last name when VERIFY_PROFILE
# is on and user-controller did not set one) is answered with the form's own
# values, a default name, and the e-mail address (--user when it is one),
# unless --forbid-profile-form.
# Exit 0 when the final page is served by the protected host, with an accepted
# status and the session cookie; 1 otherwise; 2 on usage errors.
#
# --logout checks the whole sign-out chain with the jar of a login (E14):
#   1. GET ORIGIN/oauth2/sign_out?rd=<ISSUER/protocol/openid-connect/logout
#      ?client_id=ID&post_logout_redirect_uri=ORIGIN/> -> 302 to the issuer's
#      host, and the oauth2-proxy session cookie is gone from the jar;
#   2. GET that -> Keycloak's logout confirmation form;
#   3. POST the form -> 302 to ORIGIN/;
#   4. GET ORIGIN/ -> 302 to /oauth2/start (signed out of oauth2-proxy);
#   5. following /oauth2/start ends at the Keycloak login form (signed out of
#      Keycloak too: no silent re-login).
# ISSUER defaults to https://auth.<ORIGIN host[:port]>/auth/realms/teknoir, ID
# to teknoir. Exit 0 when every step holds, 1 otherwise.
set -euo pipefail

CACERT="" URL="" LOGIN_USER="" PWFILE="" NEWPWFILE="" JAR_OPT="" FORBID_PROFILE=0
SESSION_COOKIE="" ACCEPT="" MODE=login ISSUER="" CLIENT_ID=teknoir
work="" jar="" page="" CODE="" EFF="" LOC=""

say() { printf '[kc-login] %s\n' "$*" >&2; }

parse_args() {
while (( $# )); do
  case "$1" in
    --cacert|--url|--user|--password-file|--new-password-file|--cookie-jar|--session-cookie|--accept-status|--issuer|--client-id)
      (( $# >= 2 )) || { printf 'kc-login: %s needs a value\n' "$1" >&2; exit 2; } ;;
  esac
  case "$1" in
    --cacert) CACERT="$2"; shift ;;
    --url) URL="$2"; shift ;;
    --user) LOGIN_USER="$2"; shift ;;
    --password-file) PWFILE="$2"; shift ;;
    --new-password-file) NEWPWFILE="$2"; shift ;;
    --cookie-jar) JAR_OPT="$2"; shift ;;
    --forbid-profile-form) FORBID_PROFILE=1 ;;
    --session-cookie) SESSION_COOKIE="$2"; shift ;;
    --accept-status) ACCEPT="$2"; shift ;;
    --logout) MODE=logout ;;
    --issuer) ISSUER="$2"; shift ;;
    --client-id) CLIENT_ID="$2"; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'kc-login: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[[ -f "${CACERT}" && -n "${URL}" ]] || { echo "kc-login: --cacert (an existing file) and --url are required" >&2; exit 2; }
[[ -z "${ACCEPT}" || "${ACCEPT}" =~ ^[0-9]{3}(,[0-9]{3})*$ ]] || { echo "kc-login: --accept-status takes codes like 200,403" >&2; exit 2; }
if [[ "${MODE}" == logout ]]; then
  [[ -n "${JAR_OPT}" ]] || { echo "kc-login: --logout needs the --cookie-jar of a login" >&2; exit 2; }
  return 0
fi
# a login needs credentials, unless a jar may hold a Keycloak SSO session
if [[ -z "${JAR_OPT}" ]] || [[ -n "${LOGIN_USER}${PWFILE}" ]]; then
  [[ -n "${LOGIN_USER}" && -f "${PWFILE}" ]] || { echo "kc-login: --cacert, --url, --user and --password-file are required" >&2; exit 2; }
fi
}

nonl() {
  # nonl <src> <dst> — copy a secret file without its trailing newline(s)
  local v
  v="$(cat "$1")"
  ( umask 077; printf '%s' "${v}" > "$2" )
}

urlenc() {
  # urlenc <string> — percent-encode everything but unreserved characters
  # (byte-wise: LC_ALL=C makes ${s:i:1} one byte)
  local LC_ALL=C s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "${c}" in
      [A-Za-z0-9._~-]) out+="${c}" ;;
      *) out+="$(printf '%%%02X' "'${c}")" ;;
    esac
  done
  printf '%s' "${out}"
}

url_host() { sed -E 's|^https?://([^/:?#]+).*|\1|' <<<"$1"; }
url_origin() { sed -E 's|^(https?://[^/?#]+).*|\1|' <<<"$1"; }
no_query() { sed -E 's|\?.*||' <<<"$1"; }

# A browser asks for HTML. ArgoCD 3.x answers its single-page-app routes
# (/applications) with "404 page not found" unless Accept names text/html.
ACCEPT_HTML='Accept: text/html,application/xhtml+xml,*/*;q=0.8'

abs_url() {
  # abs_url <page-url> <url> — <url> itself, or, when it is a path ("/auth/..."
  # as Keycloak's logout-confirm form has), resolved against the page's origin
  case "$2" in
    /*) printf '%s%s' "$(url_origin "$1")" "$2" ;;
    *) printf '%s' "$2" ;;
  esac
}

fetch() {
  # fetch <curl args...> — follow redirects; sets CODE and EFF (final URL)
  local out
  # HTTP/1.1: over HTTP/2 the gateway resets the stream after ext_authz's 302
  # (PROTOCOL_ERROR, curl exit 92; the same on staging and production), which
  # browsers tolerate and curl does not
  out="$(curl -sS --http1.1 -H "${ACCEPT_HTML}" --cacert "${CACERT}" -c "${jar}" -b "${jar}" -L --max-redirs 20 \
           -o "${page}" -w '%{http_code} %{url_effective}' "$@")" || return 1
  CODE="${out%% *}" EFF="${out#* }"
}

fetch1() {
  # fetch1 <curl args...> — one request, no redirect following; sets CODE and
  # LOC (the Location header, resolved: curl's redirect_url)
  local out
  out="$(curl -sS --http1.1 -H "${ACCEPT_HTML}" --cacert "${CACERT}" -c "${jar}" -b "${jar}" \
           -o "${page}" -w '%{http_code} %{redirect_url}' "$@")" || return 1
  CODE="${out%% *}" LOC="${out#* }"
  [[ "${LOC}" != "${CODE}" ]] || LOC=""
}

form_action() {
  # form_action <form-id> — the unescaped action URL of that form, or nothing
  tr '\n' ' ' < "${page}" | grep -oE "<form[^>]*id=\"$1\"[^>]*>" | head -1 |
    grep -oE 'action="[^"]*"' | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g' || true
}

form_action_matching() {
  # form_action_matching <ERE> — the unescaped action URL of the first form
  # whose action matches <ERE> (forms without an id), or nothing
  tr '\n' ' ' < "${page}" | grep -oE '<form[^>]*action="[^"]*"[^>]*>' |
    grep -oE 'action="[^"]*"' | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g' | grep -E -- "$1" | head -1 || true
}

input_value() {
  # input_value <name> — the value attribute of an input field
  tr '\n' ' ' < "${page}" | grep -oE "<input[^>]*name=\"$1\"[^>]*>" | head -1 |
    grep -oE 'value="[^"]*"' | sed -e 's/^value="//' -e 's/"$//' || true
}

feedback_text() {
  # the message Keycloak shows on a rejected form (no secret: Keycloak's own
  # text, e.g. "Invalid username or password." or "Account is disabled ...")
  tr '\n' ' ' < "${page}" |
    grep -oE '(kc-feedback-text|id="input-error[^"]*")[^>]*>[[:space:]]*[^<]+' | head -1 |
    sed -E 's/^[^>]*>[[:space:]]*//; s/[[:space:]]+$//' || true
}

profile_email() {
  # the e-mail address for Update Profile: the form's own value, else --user
  # when it is an address (an admin-user admin), else a placeholder
  local e
  e="$(input_value email)"
  if [[ -n "${e}" ]]; then printf '%s' "${e}"
  elif [[ "${LOGIN_USER}" == *@* ]]; then printf '%s' "${LOGIN_USER}"
  else printf '%s@example.invalid' "${LOGIN_USER:-user}"; fi
}

jar_cookies() {
  # jar_cookies <jar> — "<domain> <name>" of every cookie with a value in a
  # Netscape cookie jar (curl -c); curl marks HttpOnly cookies "#HttpOnly_"
  [[ -f "$1" ]] || return 0
  awk -F'\t' '
    { line = $0; sub(/^#HttpOnly_/, "", line) }
    line ~ /^#/ || line ~ /^[[:space:]]*$/ { next }
    { n = split(line, f, "\t"); if (n >= 7 && f[7] != "") print f[1], f[6] }
  ' "$1"
}

has_session_cookie() {
  # has_session_cookie <jar> [name] — a session cookie with a value: <name>
  # or its split parts <name>_<n>; without <name>, oauth2-proxy's (a name
  # ending in oauth2_proxy, optionally _<n>; never the _csrf one)
  local want="${2:-}" n
  while read -r _ n; do
    if [[ -n "${want}" ]]; then
      [[ "${n}" == "${want}" || "${n}" =~ ^${want//./\\.}_[0-9]+$ ]] && return 0
    else
      [[ "${n}" =~ oauth2_proxy(_[0-9]+)?$ ]] && return 0
    fi
  done < <(jar_cookies "$1")
  return 1
}

status_accepted() {
  # status_accepted <code> — in --accept-status, or any 2xx/3xx by default
  local c="$1"
  if [[ -n "${ACCEPT}" ]]; then [[ ",${ACCEPT}," == *",${c},"* ]]
  else [[ "${c}" =~ ^[23][0-9][0-9]$ ]]; fi
}

open_jar() {
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  chmod 700 "${work}"
  page="${work}/page.html"
  if [[ -n "${JAR_OPT}" ]]; then
    [[ ! -L "${JAR_OPT}" && ! -d "${JAR_OPT}" ]] || { say "--cookie-jar ${JAR_OPT} is a symlink or a directory"; exit 2; }
    if ! { ( umask 077; touch "${JAR_OPT}" ) && chmod 600 "${JAR_OPT}"; }; then say "cannot use the cookie jar ${JAR_OPT}"; exit 2; fi
    jar="${JAR_OPT}"
  else
    jar="${work}/jar"
  fi
}

login() {
local act origin app_host
origin="$(url_origin "${URL}")"
app_host="$(url_host "${URL}")"
[[ -z "${PWFILE}" ]] || nonl "${PWFILE}" "${work}/pw"

fetch "${URL}" || { say "cannot reach ${URL}"; exit 1; }
act="$(form_action kc-form-login)"
if [[ -z "${act}" && "$(url_host "${EFF}")" == "${app_host}" ]] && grep -q 'oauth2/start' "${page}"; then
  # oauth2-proxy's own sign-in page (provider button not skipped)
  fetch "${origin}/oauth2/start?rd=%2F" || { say "oauth2/start failed"; exit 1; }
  act="$(form_action kc-form-login)"
fi
if [[ -n "${act}" ]]; then
  [[ -n "${LOGIN_USER}" && -s "${work}/pw" ]] || { say "Keycloak asks for a password (no SSO session in the jar): pass --user and --password-file"; exit 1; }
  say "login form at $(no_query "${act}")"
  fetch --data-urlencode "username=${LOGIN_USER}" --data-urlencode "password@${work}/pw" --data-urlencode "credentialId=" "${act}" \
    || { say "posting the login form failed"; exit 1; }
elif [[ "$(url_host "${EFF}")" != auth.* ]]; then
  say "no Keycloak login form: signed in through the session in the jar"
else
  say "no Keycloak login form (HTTP ${CODE} at $(no_query "${EFF}"))"
  exit 1
fi

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
    if (( FORBID_PROFILE )); then
      say "Keycloak shows the Update Profile form (VERIFY_PROFILE, or the user has no last name): forbidden by --forbid-profile-form"
      exit 1
    fi
    say "required action Update Profile"
    fetch --data-urlencode "email=$(profile_email)" \
          --data-urlencode "firstName=$(input_value firstName | grep . || echo Platform)" \
          --data-urlencode "lastName=$(input_value lastName | grep . || echo Admin)" "${act}" \
      || { say "posting the profile update failed"; exit 1; }
  else
    break
  fi
done

if [[ "$(url_host "${EFF}")" == auth.* ]] && grep -qiE 'Invalid username or password|kc-feedback-text|input-error|alert-error' "${page}"; then
  say "Keycloak rejected the login: $(feedback_text | grep . || echo "HTTP ${CODE}") (at $(no_query "${EFF}"))"
  exit 1
fi
if [[ "$(url_host "${EFF}")" != auth.* ]] && status_accepted "${CODE}" && has_session_cookie "${jar}" "${SESSION_COOKIE}"; then
  say "login ok: HTTP ${CODE} at $(no_query "${EFF}") with a ${SESSION_COOKIE:-oauth2-proxy} session"
  exit 0
fi
say "login failed: HTTP ${CODE} at $(no_query "${EFF}")$(has_session_cookie "${jar}" "${SESSION_COOKIE}" || printf ' (no %s session cookie)' "${SESSION_COOKIE:-oauth2-proxy}")"
exit 1
}

logout() {
local origin issuer end_session act code_v auth_host page_url
origin="$(url_origin "${URL}")"
issuer="${ISSUER:-https://auth.${origin#*://}/auth/realms/teknoir}"
auth_host="$(url_host "${issuer}")"
end_session="${issuer}/protocol/openid-connect/logout?client_id=$(urlenc "${CLIENT_ID}")&post_logout_redirect_uri=$(urlenc "${origin}/")"
has_session_cookie "${jar}" || { say "logout: no oauth2-proxy session in ${jar} (sign in first)"; exit 1; }

fetch1 "${origin}/oauth2/sign_out?rd=$(urlenc "${end_session}")" || { say "logout: cannot reach ${origin}/oauth2/sign_out"; exit 1; }
[[ "${CODE}" == 302 && "$(url_host "${LOC}")" == "${auth_host}" ]] \
  || { say "logout 1/5: /oauth2/sign_out answered HTTP ${CODE} to $(no_query "${LOC:-nowhere}"), want 302 to ${auth_host}"; exit 1; }
if has_session_cookie "${jar}"; then say "logout 1/5: /oauth2/sign_out left the oauth2-proxy session cookie in place"; exit 1; fi
say "logout 1/5: /oauth2/sign_out -> 302 $(no_query "${LOC}"), session cookie cleared"

page_url="${LOC}"
fetch1 "${LOC}" || { say "logout: cannot reach $(no_query "${LOC}")"; exit 1; }
act="$(abs_url "${page_url}" "$(form_action_matching 'logout-confirm')")"
code_v="$(input_value session_code)"
[[ "${CODE}" == 200 && -n "${act}" ]] \
  || { say "logout 2/5: the end-session endpoint answered HTTP ${CODE} without the logout confirmation form"; exit 1; }
say "logout 2/5: Keycloak asks to confirm the logout ($(no_query "${act}"))"

fetch1 --data-urlencode "session_code=${code_v}" --data-urlencode "confirmLogout=$(input_value confirmLogout | grep . || echo Logout)" "${act}" \
  || { say "logout: posting the confirmation failed"; exit 1; }
[[ "${CODE}" =~ ^30[1237]$ && "${LOC}" == "${origin}/" ]] \
  || { say "logout 3/5: the confirmation answered HTTP ${CODE} to ${LOC:-nowhere}, want a redirect to ${origin}/"; exit 1; }
say "logout 3/5: confirmed -> ${CODE} ${LOC}"

fetch1 "${origin}/" || { say "logout: cannot reach ${origin}/"; exit 1; }
[[ "${CODE}" == 302 && "${LOC}" == *"/oauth2/start"* ]] \
  || { say "logout 4/5: ${origin}/ answered HTTP ${CODE} to $(no_query "${LOC:-nowhere}"), want 302 to /oauth2/start"; exit 1; }
say "logout 4/5: ${origin}/ -> 302 /oauth2/start"

fetch "${LOC}" || { say "logout: following /oauth2/start failed"; exit 1; }
[[ -n "$(form_action kc-form-login)" ]] \
  || { say "logout 5/5: /oauth2/start ended at HTTP ${CODE} $(no_query "${EFF}") without the Keycloak login form (silent re-login)"; exit 1; }
say "logout 5/5: /oauth2/start shows the Keycloak login form; signed out"
exit 0
}

main() {
parse_args "$@"
open_jar
if [[ "${MODE}" == logout ]]; then logout; else login; fi
}

# Sourcing (unit tests) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
