#!/usr/bin/env bash
# run-static.sh — the static and unit checks of the airgap tooling (DESIGN test
# plan 1); what CI runs on every PR, and what to run locally before a commit.
#
#   1. shellcheck -x on every shell script under airgap/ and scripts/
#      (the pre-redesign scripts at airgap/*.sh and scripts/*.sh, which I-14
#      deletes, are held to severity warning; everything else to the default),
#      and on the bats files (shellcheck -s bash knows bats: SC2314/SC2315
#      flag a `! cmd` that cannot fail the test)
#   2. the LAN entrypoint under docker bash:3.2 (macOS /bin/bash): syntax and help
#   3. bats unit tests (airgap/test/bats/run.sh, pinned bats-core)
#   4. the node runner's own unit tests (airgap/test/node/run.sh), when present,
#      and the library unit tests (airgap/test/unit/*-test.sh)
#   5. gitleaks over the history of HEAD and the working tree
#      (config: airgap/test/gitleaks.toml)
#
# Usage: airgap/test/run-static.sh [--no-docker] [--no-gitleaks]
# Steps whose tool is missing are reported as SKIP locally and fail in CI
# (CI=true), where every tool is installed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BASH32_IMAGE="${BASH32_IMAGE:-docker.io/library/bash:3.2@sha256:0fd7cb8499c63a3c9345e7088a9cd83bb69f6e895e83833859aff838a0312091}"
DOCKER=1 GITLEAKS=1
for a in "$@"; do
  case "${a}" in
    --no-docker) DOCKER=0 ;;
    --no-gitleaks) GITLEAKS=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument ${a}" >&2; exit 2 ;;
  esac
done

declare -a RESULTS=()
FAILED=0
step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
result() {
  # result <PASS|FAIL|SKIP> <name>
  RESULTS+=("$1  $2")
  [[ "$1" == FAIL ]] && FAILED=1
  return 0
}
missing() {
  # missing <tool> <step> — SKIP locally, FAIL in CI
  if [[ "${CI:-}" == true ]]; then result FAIL "$2 ($1 not installed)"; else result SKIP "$2 ($1 not installed)"; fi
}

cd "${REPO}"

# ---------------------------------------------------------------------------
step "shellcheck"
scripts=() legacy=() batsfiles=()
while IFS= read -r f; do
  case "${f}" in *.bats) batsfiles+=("${f}"); continue ;; esac
  if [[ "${f}" == *.sh || "${f}" == *.bash ]] || head -c 64 "${f}" 2>/dev/null | grep -qE '^#!.*(ba)?sh'; then
    if [[ "${f}" =~ ^(airgap|scripts)/[^/]+\.sh$ ]]; then legacy+=("${f}"); else scripts+=("${f}"); fi
  fi
done < <(git ls-files --cached --others --exclude-standard -- airgap scripts | sort -u)
if command -v shellcheck >/dev/null; then
  printf '%s %s; %d scripts, %d legacy\n' "$(shellcheck --version | sed -n 's/^version: //p')" "-x -P SCRIPTDIR" "${#scripts[@]}" "${#legacy[@]}"
  if shellcheck -x -P SCRIPTDIR "${scripts[@]}"; then result PASS "shellcheck (${#scripts[@]} scripts)"; else result FAIL shellcheck; fi
  if (( ${#legacy[@]} )); then
    if shellcheck -x -P SCRIPTDIR -S warning "${legacy[@]}"; then result PASS "shellcheck -S warning (${#legacy[@]} legacy scripts)"
    else result FAIL "shellcheck (legacy scripts)"; fi
  fi
  if (( ${#batsfiles[@]} )); then
    if shellcheck -s bash -x -P SCRIPTDIR "${batsfiles[@]}"; then result PASS "shellcheck -s bash (${#batsfiles[@]} bats files)"
    else result FAIL "shellcheck (bats files)"; fi
  fi
else
  missing shellcheck shellcheck
fi

# ---------------------------------------------------------------------------
step "LAN entrypoint under bash 3.2"
if [[ ! -f airgap/teknoir-airgap ]]; then
  result SKIP "bash 3.2 (airgap/teknoir-airgap not in the tree yet)"
elif (( ! DOCKER )); then
  result SKIP "bash 3.2 (--no-docker)"
elif ! command -v docker >/dev/null; then
  missing docker "bash 3.2"
elif docker run --rm -v "${REPO}/airgap/teknoir-airgap:/b/teknoir-airgap:ro" "${BASH32_IMAGE}" \
       bash -c 'bash -n /b/teknoir-airgap && bash /b/teknoir-airgap help >/dev/null'; then
  result PASS "teknoir-airgap parses and runs help under bash 3.2"
else
  result FAIL "teknoir-airgap under bash 3.2"
fi

# ---------------------------------------------------------------------------
step "bats"
if "${HERE}/bats/run.sh"; then result PASS bats; else result FAIL bats; fi

# ---------------------------------------------------------------------------
step "node runner unit tests"
if [[ -x "${HERE}/node/run.sh" ]]; then
  if "${HERE}/node/run.sh"; then result PASS "airgap/test/node/run.sh"; else result FAIL "airgap/test/node/run.sh"; fi
else
  result SKIP "airgap/test/node/run.sh (not in the tree yet)"
fi
# ---------------------------------------------------------------------------
step "library unit tests (airgap/test/unit)"
for t in "${HERE}"/unit/*-test.sh; do
  [[ -f "${t}" ]] || continue
  if bash "${t}"; then result PASS "${t#"${REPO}"/}"; else result FAIL "${t#"${REPO}"/}"; fi
done

# ---------------------------------------------------------------------------
step "gitleaks"
if (( ! GITLEAKS )); then
  result SKIP "gitleaks (--no-gitleaks)"
elif ! command -v gitleaks >/dev/null; then
  missing gitleaks gitleaks
else
  # history reachable from HEAD (all worktrees share one object store, so
  # the default --all would scan other branches too) and the working tree;
  # airgap/test/gitleaks.toml = default rules + narrow allowlists
  gl=(--config "${HERE}/gitleaks.toml" --redact --no-banner --log-level warn)
  if gitleaks git "${gl[@]}" --log-opts=HEAD . && gitleaks dir "${gl[@]}" .; then
    result PASS "gitleaks (history and working tree)"
  else
    result FAIL gitleaks
  fi
fi

printf '\n===== static summary =====\n'
printf '%s\n' "${RESULTS[@]}"
exit "${FAILED}"
