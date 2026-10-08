#!/usr/bin/env bash
# run.sh — run the airgap bats unit tests with the pinned bats-core.
#
#   airgap/test/bats/run.sh [bats options] [file.bats ...]
#
# Default: every airgap/test/bats/*.bats. The contract tests
# (common_contract.bats) run twice: against airgap/node/lib/common.sh and
# against the stub airgap/test/stubs/common.sh (when present), so the stub the
# phase libraries were developed against stays equivalent to the real thing.
# Tests whose code is not in the tree yet are reported as skipped.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
BATS="${BATS:-$("${HERE}/bootstrap-bats.sh")}"

opts=() files=()
for a in "$@"; do
  case "${a}" in
    *.bats) files+=("${a}") ;;
    *) opts+=("${a}") ;;
  esac
done
if (( ${#files[@]} == 0 )); then
  for f in "${HERE}"/*.bats; do files+=("${f}"); done
fi

rc=0
"${BATS}" ${opts[@]+"${opts[@]}"} "${files[@]}" || rc=$?

stub_common="${REPO}/airgap/test/stubs/common.sh"
if [[ -f "${stub_common}" ]] && printf '%s\n' "${files[@]}" | grep -q 'common_contract.bats$'; then
  printf '\n# contract tests against the stub %s\n' "${stub_common#"${REPO}/"}"
  COMMON_SH="${stub_common}" "${BATS}" ${opts[@]+"${opts[@]}"} "${HERE}/common_contract.bats" || rc=$?
fi
exit "${rc}"
