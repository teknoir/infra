#!/usr/bin/env bash
# admin-out-file-test.sh — unit test (no cluster) of lib/admin.sh's --out
# handling. The LAN tool (teknoir-airgap admin-user) always passes the node a
# fresh EMPTY 0600 file from node_mktemp in a 0700 directory
# (/var/lib/teknoir-airgap/tmp/admin-user.XXXXXX). admin-user must fill that
# file and refuse only a NON-EMPTY one: "never overwrites" is `-s`, not `-e`.
# The k3d test covers the same through the whole command; this one runs on
# every run-static.
#
#   1. admin_handover_password into an empty 0600 file: written (0600, exactly
#      the recorded value), then the Secret is deleted; no .teknoir-admin-user.*
#      temp file is left;
#   2. ... into a non-empty file with another value: refused, the file
#      untouched, the Secret kept;
#   3. ... into a file that already holds the recorded value (resume): accepted
#      and not rewritten, the Secret deleted;
#   4. admin_reset_password into an empty 0600 file: one temporary=true reset,
#      the file (0600) holds the value Keycloak got, no temp file left;
#   5. cmd_admin_user --reset-password: the up-front check lets an empty --out
#      through and refuses a non-empty one before anything else runs;
#   6. admin_write_file: a file that is non-empty by the time of the rename is
#      not replaced, and the temp file is removed.
# No password reaches the output.
#
# Usage: airgap/test/unit/admin-out-file-test.sh
# shellcheck disable=SC2016  # the scenario script expands in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-aof.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"
mkdir -p "${WORK}/node/bin" "${WORK}/tmp" "${WORK}/rec"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"
# the node's private temp dir, as NODE_MKTEMP_SCRIPT creates it
NT="${WORK}/node-tmp"
( umask 077; mkdir "${NT}" )
( umask 077; printf 'tmp-%s\n' "$(openssl rand -hex 12)" > "${WORK}/rec/recorded" )

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; sed 's/^/      /' "${WORK}/out" "${WORK}/rec/calls" 2>/dev/null || true; fi; }
has() { grep -qE -- "$1" "$2"; }
hasnt() { ! grep -qE -- "$1" "$2"; }
mode600() { [[ "$(stat -c %a "$1")" == 600 ]]; }
empty600() { [[ -f "$1" && ! -s "$1" ]] && mode600 "$1"; }
no_tmp_left() { [[ -z "$(find "${NT}" -name '.teknoir-admin-user.*' -print)" ]]; }
no_secret_out() {
  # none of the passwords (recorded, reset) is in the output; grep reads them from a pipe
  local f
  f="$(mktemp "${WORK}/needles.XXXXXX")"
  cat "${WORK}/rec/recorded" > "${f}"
  [[ ! -f "${WORK}/rec/kc-got" ]] || cat "${WORK}/rec/kc-got" >> "${f}"
  if grep -v '^$' "${f}" | grep -qF -f - "${WORK}/out"; then rm -f "${f}"; return 1; fi
  rm -f "${f}"
}
node_out() {
  # node_out — a new empty 0600 file in the node temp dir, like node_mktemp admin-user
  ( umask 077; mktemp "${NT}/admin-user.XXXXXX" )
}
fstate() { printf '%s %s' "$(sha256sum < "$1" | cut -c1-64)" "$(stat -c '%Y %s' "$1")"; }

# scenario <on-record 0|1> <command...> — run one lib/admin.sh function with the
# cluster and Keycloak stubbed; output in WORK/out (plus rc=N), calls in WORK/rec/calls
scenario() {
  local rc=0
  : > "${WORK}/rec/calls"
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped \
    COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/admin.sh" \
    REC="${WORK}/rec" ON_RECORD="$1" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      source "${LIB}"
      trap run_at_exit EXIT
      DRY_RUN=0 ADMIN_JQ=jq
      admin_recorded() {
        ADMIN_PW="" ADMIN_PW_FROM="" ADMIN_SECRET_UID="" ADMIN_SECRET_RV="" ADMIN_LEGACY=0
        ADMIN_SECRET_NS=tk-user-creds ADMIN_SECRET_NAME="user-initial-password-$1"
        if [[ "${ON_RECORD}" == 1 ]]; then
          ADMIN_PW="$(cat "${REC}/recorded")" ADMIN_PW_FROM=secret ADMIN_SECRET_UID=u-1 ADMIN_SECRET_RV=7
        fi
      }
      admin_delete_secret() { echo "delete-secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME} uid=${ADMIN_SECRET_UID} rv=${ADMIN_SECRET_RV}" >> "${REC}/calls"; }
      admin_clear_legacy() { echo "clear-legacy $*" >> "${REC}/calls"; }
      admin_kc_call() {
        echo "kc $1 $2" >> "${REC}/calls"
        jq -c "{type, temporary, length: (.value | length)}" "$3" >> "${REC}/calls"
        ( umask 077; jq -r .value "$3" > "${REC}/kc-got" )
        ADMIN_KC_CODE=204 ADMIN_KC_BODY=""
      }
      in_cluster() { echo "in_cluster $*" >> "${REC}/calls"; return 1; }
      ADMIN_KC_UID=kc-uid-1 ADMIN_KC_REALM=teknoir
      "$@"
    ' admin-out-file-test "${@:2}" > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}

echo "# 1. handover into an existing empty 0600 file (the LAN tool's node_mktemp file)"
out1="$(node_out)"
check "the pre-created file is empty, mode 0600" empty600 "${out1}"
scenario 1 admin_handover_password x-at-teknoir.ai x@teknoir.ai "${out1}"
check "exits 0" has '^rc=0$' "${WORK}/out"
check "the file (0600) holds exactly the recorded value" bash -c "cmp -s '${out1}' '${WORK}/rec/recorded' && [[ \$(stat -c %a '${out1}') == 600 ]]"
check "it wrote the file (not 'already holds')" bash -c "grep -q 'written to ${out1} (mode 0600, not shown); deleted Secret tk-user-creds/user-initial-password-x-at-teknoir.ai' '${WORK}/out' && ! grep -q 'already holds' '${WORK}/out'"
check "the Secret is deleted under its uid/resourceVersion" has '^delete-secret tk-user-creds/user-initial-password-x-at-teknoir.ai uid=u-1 rv=7$' "${WORK}/rec/calls"
check "no .teknoir-admin-user.* temp file is left" no_tmp_left
check "no password in the output" no_secret_out

echo "# 2. handover into a non-empty file with another value"
out2="$(node_out)"
printf 'keep me\n' > "${out2}"
st2="$(fstate "${out2}")"
sleep 1
scenario 1 admin_handover_password x-at-teknoir.ai x@teknoir.ai "${out2}"
check "exits 1 with 'never overwrites'" bash -c "grep -q '^rc=1$' '${WORK}/out' && grep -q 'exists and is not empty; admin-user never overwrites a file' '${WORK}/out'"
check "the file is untouched" test "$(fstate "${out2}")" == "${st2}"
check "the Secret is kept" hasnt 'delete-secret' "${WORK}/rec/calls"
check "no .teknoir-admin-user.* temp file is left" no_tmp_left

echo "# 3. resume: the file already holds the recorded value"
out3="$(node_out)"
cat "${WORK}/rec/recorded" > "${out3}"
st3="$(fstate "${out3}")"
sleep 1
scenario 1 admin_handover_password x-at-teknoir.ai x@teknoir.ai "${out3}"
check "exits 0 and says the file already holds the password" bash -c "grep -q '^rc=0$' '${WORK}/out' && grep -q 'already holds the temporary password of x@teknoir.ai' '${WORK}/out'"
check "the file is not rewritten" test "$(fstate "${out3}")" == "${st3}"
check "the Secret is deleted" has '^delete-secret ' "${WORK}/rec/calls"

echo "# 4. --reset-password into an existing empty 0600 file, nothing on record"
out4="$(node_out)"
check "the pre-created file is empty, mode 0600" empty600 "${out4}"
scenario 0 admin_reset_password x-at-teknoir.ai x@teknoir.ai "${out4}"
check "exits 0" has '^rc=0$' "${WORK}/out"
check "exactly one reset-password call, temporary=true, length 20" bash -c "[[ \$(grep -c '^kc PUT /admin/realms/teknoir/users/kc-uid-1/reset-password$' '${WORK}/rec/calls') == 1 ]] && grep -qx '{\"type\":\"password\",\"temporary\":true,\"length\":20}' '${WORK}/rec/calls'"
check "the file (0600) holds exactly the value Keycloak got" bash -c "cmp -s '${out4}' '${WORK}/rec/kc-got' && [[ \$(stat -c %a '${out4}') == 600 ]]"
check "nothing superseded to delete" bash -c "! grep -qE '^(delete-secret|clear-legacy)' '${WORK}/rec/calls'"
check "no .teknoir-admin-user.* temp file is left" no_tmp_left
check "no password in the output" no_secret_out

echo "# 5. cmd_admin_user --reset-password: the up-front --out check"
out5="$(node_out)"
scenario 0 cmd_admin_user --email x@teknoir.ai --reset-password --out "${out5}"
check "an empty --out passes the check (it stops later, at the stubbed CRD lookup)" bash -c "grep -q '^rc=1$' '${WORK}/out' && grep -q 'the users.teknoir.org CRD is missing' '${WORK}/out' && ! grep -q 'exists and is not empty' '${WORK}/out' && grep -q '^in_cluster ' '${WORK}/rec/calls'"
check "  ... the file is still empty, mode 0600" empty600 "${out5}"
printf 'keep me\n' > "${out5}"
st5="$(fstate "${out5}")"
scenario 0 cmd_admin_user --email x@teknoir.ai --reset-password --out "${out5}"
check "a non-empty --out is refused before anything else" bash -c "grep -q '^rc=1$' '${WORK}/out' && grep -q 'exists and is not empty; admin-user never overwrites a file' '${WORK}/out' && [[ ! -s '${WORK}/rec/calls' ]]"
check "  ... the file is untouched" test "$(fstate "${out5}")" == "${st5}"

echo "# 6. admin_write_file: a file non-empty at the rename is not replaced"
out6="$(node_out)"
printf 'appeared\n' > "${out6}"
st6="$(fstate "${out6}")"
scenario 1 admin_write_file "${out6}" some-value-4711
check "exits 1 with 'appeared meanwhile'" bash -c "grep -q '^rc=1$' '${WORK}/out' && grep -q 'appeared meanwhile and is not empty' '${WORK}/out'"
check "the file is untouched" test "$(fstate "${out6}")" == "${st6}"
check "the temp file is removed" no_tmp_left

check "the node temp dir holds only the --out files" \
  test "$(find "${NT}" -mindepth 1 -maxdepth 1 | wc -l)" == 6

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
