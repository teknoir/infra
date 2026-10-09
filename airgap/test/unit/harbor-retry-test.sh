#!/usr/bin/env bash
# harbor-retry-test.sh — unit test (no cluster) of lib/harbor.sh's push retry
# (harbor_push_retry): Harbor answers 503 for a while after a k3s restart (VM
# e2e E4: the pre-change backup restarts k3s right before the harbor phase).
#
#   1. a push that fails once is retried after Harbor reports healthy, and passes;
#   2. a failed push that landed after all is not pushed again (immutable tags);
#   3. a push that keeps failing gives up after HARBOR_PUSH_ATTEMPTS attempts and
#      leaves the last error in ${HARBOR_TMP}/err;
#   4. reads (harbor_remote_manifest): a 503 "no healthy upstream" is retried, a
#      404 means absent at once, a 401 dies at once.
#
# Usage: airgap/test/unit/harbor-retry-test.sh
#   TEKNOIR_COMMON=<common.sh>   test against that common.sh (default: the tree's)
# shellcheck disable=SC2016  # the scenario scripts expand in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
COMMON="${TEKNOIR_COMMON:-${REPO}/airgap/node/lib/common.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-hretry.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/node/bin" "${WORK}/tmp"
for t in crane helm; do ln -s "$(command -v true)" "${WORK}/node/bin/${t}"; done
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

# scenario <failures-before-success> <landed 0|1> — prints the push count,
# the result and the log
scenario() {
  local fails="$1" landed="$2" rc=0
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped \
    COMMON="${COMMON}" LIB="${REPO}/airgap/node/lib/harbor.sh" FAILS="${fails}" LANDED="${landed}" \
    HARBOR_RETRY_DELAY=0 HARBOR_PUSH_ATTEMPTS=3 WAIT_INTERVAL=0 \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      source "${LIB}"
      HARBOR_TMP="$(mktemp -d)"
      HARBOR_API=https://harbor.teknoir.airgapped/api/v2.0
      health=0
      harbor_healthy() { health=$((health + 1)); return 0; }
      fake_landed() { [[ "${LANDED}" == 1 ]]; }
      count="${HARBOR_TMP}/count"; echo 0 > "${count}"
      fake_push() {
        local n; n=$(( $(cat "${count}") + 1 )); echo "${n}" > "${count}"
        if (( n <= FAILS )); then echo "PUT https://harbor/v2/x/manifests/sha256:1: response status code 503: Service Unavailable" >&2; return 1; fi
        return 0
      }
      res=0
      harbor_push_retry "fake push" fake_landed -- fake_push || res=$?
      echo "pushes=$(cat "${count}") health=${health} result=${res} err=$(tail -1 "${HARBOR_TMP}/err" 2>/dev/null | grep -c 503 || true)"
      rm -rf "${HARBOR_TMP}"
    ' > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}

# read_scenario <crane stderr of the failing attempts> <failures> — prints the
# crane call count and harbor_remote_manifest's status
read_scenario() {
  local err="$1" fails="$2" rc=0
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped \
    COMMON="${COMMON}" LIB="${REPO}/airgap/node/lib/harbor.sh" ERRTEXT="${err}" FAILS="${fails}" \
    HARBOR_RETRY_DELAY=0 HARBOR_PUSH_ATTEMPTS=3 WAIT_INTERVAL=0 \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      source "${LIB}"
      HARBOR_TMP="$(mktemp -d)"
      HARBOR_API=https://harbor.teknoir.airgapped/api/v2.0
      harbor_healthy() { return 0; }
      count="${HARBOR_TMP}/count"; echo 0 > "${count}"
      harbor_crane() {
        local n; n=$(( $(cat "${count}") + 1 )); echo "${n}" > "${count}"
        if (( n <= FAILS )); then echo "${ERRTEXT}" >&2; return 1; fi
        echo "{\"schemaVersion\": 2}"
      }
      res=0
      harbor_remote_manifest harbor.teknoir.airgapped/teknoir/argo:0.0.3 || res=$?
      echo "calls=$(cat "${count}") result=${res}"
      rm -rf "${HARBOR_TMP}"
    ' > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}

expect() {
  # expect <description> <grep -E pattern>... — every pattern is in the output
  local desc="$1" p
  shift
  for p in "$@"; do
    if ! grep -qE -- "${p}" "${WORK}/out"; then bad "${desc}: no /${p}/"; sed 's/^/      /' "${WORK}/out"; return 0; fi
  done
  ok "${desc}"
}

echo "# 1. one 503, then success"
scenario 1 0
expect "retried once, after a health wait, and passed" 'pushes=2 health=1 result=0' 'attempt 1 of 3 failed .*503.*retrying once Harbor is healthy' '^rc=0$'

echo "# 2. a failed attempt that landed"
scenario 1 1
expect "not pushed again" 'pushes=1 health=1 result=0' 'the failed attempt landed after all' '^rc=0$'

echo "# 3. Harbor keeps answering 503"
scenario 9 0
expect "gives up after 3 attempts with the last error in err" 'pushes=3 health=2 result=1 err=1' '^rc=0$'

echo "# 4. reads"
read_scenario 'Error: GET https://harbor.teknoir.airgapped/v2/teknoir/argo/manifests/0.0.3: unexpected status code 503 Service Unavailable: no healthy upstream' 1
expect "a 503 read is retried and then succeeds" 'calls=2 result=0' 'reading .* attempt 1 of 3 failed' '^rc=0$'
read_scenario 'Error: GET https://harbor/v2/teknoir/argo/manifests/0.0.3: MANIFEST_UNKNOWN: manifest unknown' 1
expect "a 404 read means absent, no retry" 'calls=1 result=1' '^rc=0$'
read_scenario 'Error: GET https://harbor/v2/teknoir/argo/manifests/0.0.3: unexpected status code 401 Unauthorized' 1
expect "a 401 read dies at once" 'cannot read harbor.teknoir.airgapped/teknoir/argo:0.0.3 from Harbor' '^rc=1$'

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
