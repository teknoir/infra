#!/usr/bin/env bash
# migrate-kc-admin-test.sh — unit test (no cluster) of lib/migrate.sh's
# migrate_keycloak_admin: the Keycloak master admin carried over before the
# first up (DESIGN M3, gitops charts/auth README "Keycloak admin").
#
#   1. with the Secret absent and the StatefulSet's literal password accepted,
#      it creates teknoir-auth/keycloak-admin with username + previous-password
#      from a temp file in the run's private scratch dir (not in /), removes
#      that file, and never prints the password;
#   2. a password Keycloak refuses (401) stops it with the
#      --keycloak-admin-password-file hint and creates nothing;
#   3. an existing Secret is left as it is.
#
# Usage: airgap/test/unit/migrate-kc-admin-test.sh
# shellcheck disable=SC2016  # the scenario script expands in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-mkc.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/node/bin" "${WORK}/tmp"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"
PW='not-a-real-pass-4711'

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

# scenario <secret-exists 0|1> <login-code>
scenario() {
  local rc=0
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped NODE_IP=192.0.2.10 \
    COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/migrate.sh" \
    EXISTS="$1" CODE="$2" PW="${PW}" REC="${WORK}/rec" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      source "${LIB}"
      MIGRATE_JQ=jq DRY_RUN=0
      : > "${REC}"
      in_cluster() {
        case "$1" in
          secrets) [[ "${EXISTS}" == 1 ]] ;;
          statefulsets) return 0 ;;
          *) return 1 ;;
        esac
      }
      kc() {
        case " $* " in
          *" get statefulset "*)
            printf "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"keycloak\",\"env\":[{\"name\":\"KC_BOOTSTRAP_ADMIN_USERNAME\",\"value\":\"admin\"},{\"name\":\"KC_BOOTSTRAP_ADMIN_PASSWORD\",\"value\":\"%s\"}]}]}}}}" "${PW}" ;;
          *" create secret generic "*)
            local a f=""
            for a in "$@"; do case "${a}" in --from-file=previous-password=*) f="${a#--from-file=previous-password=}" ;; esac; done
            { echo "file=${f}"; echo "content-ok=$([[ "$(cat "${f}")" == "${PW}" ]] && echo yes || echo no)"; echo "args=$*"; } >> "${REC}"
            echo "${f}" > "${REC}.path" ;;
          *) return 1 ;;
        esac
      }
      migrate_kc_login() { printf "%s" "${CODE}"; }
      migrate_keycloak_admin
      echo "workdir=${WORK_DIR}"
      [[ ! -e "$(cat "${REC}.path" 2>/dev/null || echo /nonexistent)" ]] && echo "tempfile-removed=yes"
    ' > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}

has()  { grep -qE -- "$1" "$2"; }

echo "# 1. Secret absent, password accepted"
scenario 0 200
if has '^rc=0$' "${WORK}/out" && has '^file='"${WORK}"'/tmp/|^file=/dev/shm/' "${WORK}/rec" && has '^content-ok=yes$' "${WORK}/rec"; then
  ok "the Secret is created from a temp file in the private scratch dir with the password"
else bad "temp file location or content"; sed 's/^/      /' "${WORK}/out" "${WORK}/rec" | sed "s/${PW}/<redacted>/g"; fi
if has 'username=admin' "${WORK}/rec" && has '^tempfile-removed=yes$' "${WORK}/out"; then ok "username carried over; the temp file is removed"
else bad "username or temp file removal"; fi
if grep -qF -- "${PW}" "${WORK}/out"; then bad "the password was printed"; else ok "the password is never printed"; fi
if grep -q '^file=/kc-' "${WORK}/rec"; then bad "the temp file was created in / (WORK_DIR empty)"; else ok "nothing in /"; fi

echo "# 2. Keycloak refuses the password"
scenario 0 401
if has '^rc=1$' "${WORK}/out" && has 'keycloak-admin-password-file' "${WORK}/out" && [[ ! -s "${WORK}/rec" ]]; then
  ok "stops with the --keycloak-admin-password-file hint and creates nothing"
else bad "401 handling"; sed "s/${PW}/<redacted>/g" "${WORK}/out" | sed 's/^/      /'; fi

echo "# 3. Secret exists"
scenario 1 200
if has '^rc=0$' "${WORK}/out" && has 'exists \(left as it is\)' "${WORK}/out" && [[ ! -s "${WORK}/rec" ]]; then
  ok "an existing Secret is left as it is"
else bad "existing Secret handling"; sed 's/^/      /' "${WORK}/out"; fi

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
