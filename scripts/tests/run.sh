#!/usr/bin/env bash
# Runs every test in scripts/tests (no cluster: fakes, temp dirs, a throwaway local apiserver when envtest is
# installed); *-test.sh is picked up by name, so kargo-root-test.sh needs no entry here.
#   scripts/tests/run.sh
# Output: verbose for humans and CI. Under a coding agent (CLAUDECODE, AI_AGENT, Codex) it prints one totals line per
# script and, for a failing script, its output without the ok lines. The full log is always in .test-logs/ (git-ignored).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/../.." || exit 1

is_agent() { case "${AI_AGENT:-}" in 0|false|no|off) return 1;; "") ;; *) return 0;; esac
  [ -n "${CLAUDECODE:-}${CODEX_THREAD_ID:-}${CODEX_SANDBOX:-}${GEMINI_CLI:-}${CURSOR_AGENT:-}${OPENCODE:-}" ]; }
export NO_COLOR=1
mkdir -p .test-logs; log=".test-logs/run-$(date +%Y%m%d-%H%M%S)-$$.log"; : >"$log"
rc=0
for t in "$HERE"/*-test.sh; do
  name=$(basename "$t"); out=$(mktemp)
  echo "== $name" >>"$log"
  if is_agent; then bash "$t" >"$out" 2>&1; r=$?; else bash "$t" 2>&1 | tee "$out"; r=${PIPESTATUS[0]}; fi
  cat "$out" >>"$log"; echo "exit=$r" >>"$log"
  [ "$r" -eq 0 ] || rc=1
  if is_agent; then
    echo "$name: $(grep -c "^ok " "$out") ok, $(grep -c "^FAIL " "$out") failed, exit $r$(grep -m1 "^SKIP" "$out" | sed "s/^/, /")"
    [ "$r" -eq 0 ] || grep -v "^ok " "$out" | tail -n 150
  fi
  rm -f "$out"
done
echo "exit=$rc full log: $log"
exit "$rc"
