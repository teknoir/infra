# shellcheck shell=bash
# lib.sh - assertions for the teknoir-airgap LAN tests (bash 3.2 compatible).
PASS_N=0
FAIL_N=0
LAST_OUT=
LAST_RC=0
TRANSCRIPT=${TRANSCRIPT:-/tmp/teknoir-airgap-test-transcript.log}

ok()  { PASS_N=$((PASS_N + 1)); printf 'PASS %s\n' "$*"; }
bad() { FAIL_N=$((FAIL_N + 1)); printf 'FAIL %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

show_last() { printf '%s\n' "${LAST_OUT}" | tail -n 25 | sed 's/^/    | /'; }

# expect_rc RC DESCRIPTION CMD...: run CMD, capture stdout+stderr, check the exit code.
expect_rc() {
  local want=$1 desc=$2
  shift 2
  LAST_OUT=$("$@" 2>&1 </dev/null)
  LAST_RC=$?
  { printf '\n$ %s\n' "$*"; printf '%s\n' "${LAST_OUT}"; } >>"${TRANSCRIPT}"
  if [ "${LAST_RC}" -eq "${want}" ]; then ok "${desc} (exit ${LAST_RC})"; else bad "${desc}: exit ${LAST_RC}, expected ${want}"; show_last; fi
}

# expect_out REGEX DESCRIPTION: the last command's output matches REGEX.
expect_out() {
  if printf '%s\n' "${LAST_OUT}" | grep -q -- "$1"; then ok "$2"; else bad "$2: output lacks /$1/"; show_last; fi
}

# expect_no_out REGEX DESCRIPTION: the last command's output does not match REGEX.
expect_no_out() {
  if printf '%s\n' "${LAST_OUT}" | grep -q -- "$1"; then bad "$2: output has /$1/"; show_last; else ok "$2"; fi
}

# check DESCRIPTION CMD...: pass when CMD succeeds.
check() {
  local desc=$1
  shift
  if "$@"; then ok "${desc}"; else bad "${desc}"; fi
}

summary() {
  printf '\nRESULT: %d passed, %d failed\n' "${PASS_N}" "${FAIL_N}"
  [ "${FAIL_N}" -eq 0 ]
}
