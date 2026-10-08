# shellcheck shell=bash
# testlib.sh — assertions and a pass/fail summary for the k3d and VM suites.
#
# Sourced by airgap/test/k3d/run.sh and airgap/test/vm/e2e.sh. These run on
# vpro or a CI runner (bash >= 4.4), never on the LAN host or the node.
#
#   tl_case <ID> <description>     start a test case (prints a header)
#   pass <msg> / fail <msg>        record one assertion result in the case
#   skip_case <reason>             mark the current case skipped
#   assert_eq <msg> <want> <got>   pass when equal, else fail with both values
#   assert_cmd <msg> <cmd...>      pass when the command succeeds
#   assert_not_cmd <msg> <cmd...>  pass when the command fails
#   wait_until <secs> <cmd...>     poll every TL_POLL seconds until success
#   tl_summary                     print the table; returns 1 if anything failed
#
# Never pass secret values to these helpers: messages are printed verbatim.

TL_NAME="${TL_NAME:-test}"
TL_POLL="${TL_POLL:-2}"
TL_CASE=""
TL_CASE_DESC=""
TL_CASE_FAILED=0
TL_CASE_SKIPPED=""
declare -a TL_ROWS=()
declare -i TL_NPASS=0 TL_NFAIL=0

if [[ -t 2 ]]; then
  TL_C_INFO=$'\033[1;34m' TL_C_OK=$'\033[1;32m' TL_C_BAD=$'\033[1;31m' TL_C_SKIP=$'\033[1;33m' TL_C_OFF=$'\033[0m'
else
  TL_C_INFO="" TL_C_OK="" TL_C_BAD="" TL_C_SKIP="" TL_C_OFF=""
fi

tl_log()  { printf '%s[%s]%s %s\n' "${TL_C_INFO}" "${TL_NAME}${TL_CASE:+ ${TL_CASE}}" "${TL_C_OFF}" "$*" >&2; }
tl_warn() { printf '%s[%s] WARN:%s %s\n' "${TL_C_SKIP}" "${TL_NAME}${TL_CASE:+ ${TL_CASE}}" "${TL_C_OFF}" "$*" >&2; }
tl_die()  { printf '%s[%s] ERROR:%s %s\n' "${TL_C_BAD}" "${TL_NAME}" "${TL_C_OFF}" "$*" >&2; exit 2; }

tl_close_case() {
  [[ -n "${TL_CASE}" ]] || return 0
  local result
  if [[ -n "${TL_CASE_SKIPPED}" ]]; then
    result="SKIP  ${TL_CASE}  ${TL_CASE_DESC} (${TL_CASE_SKIPPED})"
  elif (( TL_CASE_FAILED )); then
    result="FAIL  ${TL_CASE}  ${TL_CASE_DESC}"
  else
    result="PASS  ${TL_CASE}  ${TL_CASE_DESC}"
  fi
  TL_ROWS+=("${result}")
  TL_CASE="" TL_CASE_DESC="" TL_CASE_FAILED=0 TL_CASE_SKIPPED=""
}

tl_case() {
  tl_close_case
  TL_CASE="$1" TL_CASE_DESC="$2"
  printf '\n%s=== %s: %s%s\n' "${TL_C_INFO}" "$1" "$2" "${TL_C_OFF}" >&2
}

pass() { TL_NPASS+=1; printf '  %sok%s   %s\n' "${TL_C_OK}" "${TL_C_OFF}" "$*" >&2; }
fail() { TL_NFAIL+=1; TL_CASE_FAILED=1; printf '  %sFAIL%s %s\n' "${TL_C_BAD}" "${TL_C_OFF}" "$*" >&2; }
skip_case() { TL_CASE_SKIPPED="$*"; printf '  %sskip%s %s\n' "${TL_C_SKIP}" "${TL_C_OFF}" "$*" >&2; }

assert_eq() {
  local msg="$1" want="$2" got="$3"
  if [[ "${want}" == "${got}" ]]; then pass "${msg}"; else fail "${msg}: want [${want}] got [${got}]"; fi
}

assert_cmd() {
  local msg="$1"; shift
  if "$@"; then pass "${msg}"; else fail "${msg} (command failed: $*)"; fi
}

assert_not_cmd() {
  local msg="$1"; shift
  if "$@"; then fail "${msg} (command unexpectedly succeeded: $*)"; else pass "${msg}"; fi
}

wait_until() {
  # wait_until <timeout-seconds> <cmd...> — 0 once cmd succeeds, 1 on timeout
  local timeout="$1"; shift
  local deadline=$(( SECONDS + timeout ))
  while :; do
    "$@" && return 0
    (( SECONDS >= deadline )) && return 1
    sleep "${TL_POLL}"
  done
}

tl_summary() {
  tl_close_case
  local row npass=0 nfail=0 nskip=0
  printf '\n===== %s summary =====\n' "${TL_NAME}"
  for row in "${TL_ROWS[@]}"; do
    case "${row}" in
      PASS*) npass=$((npass + 1)); printf '%s%s%s\n' "${TL_C_OK}" "${row}" "${TL_C_OFF}" ;;
      FAIL*) nfail=$((nfail + 1)); printf '%s%s%s\n' "${TL_C_BAD}" "${row}" "${TL_C_OFF}" ;;
      *)     nskip=$((nskip + 1)); printf '%s%s%s\n' "${TL_C_SKIP}" "${row}" "${TL_C_OFF}" ;;
    esac
  done
  printf 'cases: %d passed, %d failed, %d skipped (assertions: %d ok, %d failed)\n' \
    "${npass}" "${nfail}" "${nskip}" "${TL_NPASS}" "${TL_NFAIL}"
  (( nfail == 0 ))
}
