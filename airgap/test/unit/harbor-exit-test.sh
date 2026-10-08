#!/usr/bin/env bash
# harbor-exit-test.sh — unit test (no cluster) of lib/harbor.sh's clean-up
# against the runner's EXIT handler (bin/teknoir-node on_exit: `local rc=$?`,
# run the at_exit list, `exit "${rc}"`).
#
# A die (or exit N) while a Harbor session is open must leave the process with
# that status, the runner's handler must see it and still run, and the 0700
# temp dir with the registry logins must be gone. Checked both with at_exit
# (common.sh registers the clean-up) and without it (the library chains onto
# the EXIT trap), and after a session ended (the trap is back to the runner's).
#
# Usage: airgap/test/unit/harbor-exit-test.sh
#   TEKNOIR_COMMON=<common.sh>   test against that common.sh (default: the
#                                tree's airgap/node/lib/common.sh, else the stub)
#   HARBOR_LIB=<harbor.sh>       test another harbor.sh (e.g. an older revision)
# shellcheck disable=SC2016  # the scenario scripts expand in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
COMMON="${TEKNOIR_COMMON:-${REPO}/airgap/node/lib/common.sh}"
[[ -f "${COMMON}" ]] || COMMON="${REPO}/airgap/test/stubs/common.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-hexit.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/node/bin" "${WORK}/tmp"
for t in crane helm; do ln -s "$(command -v true)" "${WORK}/node/bin/${t}"; done
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"

PASS=0
FAIL=0
FAILED=()
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }

# scenario <mode at_exit|chained> <script> — runs the script after a
# runner-like set-up; prints "rc=<exit status>" and the handler's lines
scenario() {
  local mode="$1" body="$2" rc=0
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped \
    COMMON="${COMMON}" LIB="${HARBOR_LIB:-${REPO}/airgap/node/lib/harbor.sh}" MODE="${mode}" BODY="${body}" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      [[ "${MODE}" == "at_exit" ]] || unset -f at_exit
      source "${LIB}"
      secret_value() { printf "%s" "not-a-real-password-123"; }
      on_exit() {
        local rc=$?
        trap - EXIT
        if declare -F run_at_exit >/dev/null; then run_at_exit; fi
        echo "handler rc=${rc} tmp-left=$(find "${TMPDIR}" -mindepth 1 -maxdepth 1 | wc -l)"
        exit "${rc}"
      }
      trap on_exit EXIT
      eval "${BODY}"
    ' > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}

expect() {
  # expect <description> <grep -E pattern>... — every pattern is in the output
  local d="$1" p
  shift
  for p in "$@"; do
    if ! grep -qE -- "${p}" "${WORK}/out"; then
      bad "${d} (no '${p}' in:"$'\n'"$(sed 's/^/      /' "${WORK}/out"))"
      return 0
    fi
  done
  ok "${d}"
}

echo "common.sh: ${COMMON}, harbor.sh: ${HARBOR_LIB:-${REPO}/airgap/node/lib/harbor.sh}"
for mode in at_exit chained; do
  echo "--- ${mode}"
  scenario "${mode}" 'harbor_session_begin; [[ -d "${HARBOR_TMP}" ]]; die "refused: a different chart"'
  expect "${mode}: die in an open session exits 1, the runner handler sees 1, temp dir removed" \
    '^rc=1$' 'handler rc=1 tmp-left=0'
  scenario "${mode}" 'harbor_session_begin; exit 3'
  expect "${mode}: exit 3 in an open session keeps 3" '^rc=3$' 'handler rc=3 tmp-left=0'
  scenario "${mode}" 'harbor_session_begin; harbor_session_end; [[ -z "${HARBOR_TMP}${HARBOR_PW}" ]]; die "later failure"'
  expect "${mode}: die after the session ended exits 1" '^rc=1$' 'handler rc=1 tmp-left=0'
  scenario "${mode}" 'harbor_session_begin; harbor_session_end; trap -p EXIT; true'
  expect "${mode}: a clean run exits 0 and the EXIT trap is the runner's again" '^rc=0$' 'handler rc=0 tmp-left=0' "^trap -- 'on_exit' EXIT$"
  scenario "${mode}" 'harbor_session_begin; harbor_session_end; harbor_session_begin; harbor_session_end; harbor_session_begin; false'
  expect "${mode}: sessions opened again, then a failing command: exits 1" '^rc=1$' 'handler rc=1 tmp-left=0'
done

echo "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
