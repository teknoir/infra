# shellcheck shell=bash
# test_helper.bash — shared setup for the airgap bats tests (load 'test_helper').
#
# Tests that exercise code written by other work items skip, with the path
# they wait for, while that code is not in the tree yet ("skipped-if-missing").
#
# Inputs (environment):
#   COMMON_SH          the common.sh under test (default airgap/node/lib/common.sh;
#                      run.sh also runs the contract tests against the test stub
#                      airgap/test/stubs/common.sh, so the stub cannot drift)
#   TEKNOIR_NODE_DIR   node payload dir (default airgap/node)
#   TEKNOIR_LAN_BIN    LAN entrypoint (default airgap/teknoir-airgap)

bats_require_minimum_version 1.5.0   # run --separate-stderr

# shellcheck disable=SC2034  # used by the .bats files that load this helper
REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
NODE_DIR="${TEKNOIR_NODE_DIR:-${REPO_ROOT}/airgap/node}"
COMMON_SH="${COMMON_SH:-${NODE_DIR}/lib/common.sh}"
# shellcheck disable=SC2034
LAN_BIN="${TEKNOIR_LAN_BIN:-${REPO_ROOT}/airgap/teknoir-airgap}"
STUB_BIN="${REPO_ROOT}/airgap/test/stubs/bin"
# shellcheck disable=SC2034
VMTEST_SITE="${REPO_ROOT}/airgap/site/vmtest.env"

# Calls that change something. A kubectl call with --dry-run is not one.
MUTATING_RE='^(kubectl|k3s kubectl) (.* )?(apply|create|delete|patch|replace|label|annotate|scale|edit|set|cordon|drain|taint|uncordon)( |$)|^(kubectl|k3s kubectl) (.* )?rollout restart|^k3s ctr .*( import| rm| delete)( |$)|^k3s (secrets-encrypt|etcd-snapshot save|server|agent)( |$)|^systemctl (start|stop|restart|reload|enable|disable|daemon-reload|mask|unmask)( |$)|^crane (push|copy|cp|tag|delete|mutate|append|rebase)( |$)|^helm (push|install|upgrade|uninstall|registry login)( |$)'

require_file() {
  # require_file <path> — skip the test while <path> does not exist
  [[ -e "$1" ]] || skip "not implemented yet: ${1#"${REPO_ROOT}/"}"
}

require_fn() {
  # require_fn <file> <function> — skip unless <file> defines <function>
  require_file "$1"
  grep -qE "^$2[[:space:]]*\(\)" "$1" || skip "not implemented yet: $2() in ${1#"${REPO_ROOT}/"}"
}

setup_stubs() {
  # Put the recording stubs first on PATH, with a per-test log and handler.
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub.log"
  export STUB_HANDLER="${BATS_TEST_TMPDIR}/stub-handler.bash"
  : > "${STUB_LOG}"
  : > "${STUB_HANDLER}"
  unset STUB_FAIL_ON STUB_DEFAULT_RC
  export PATH="${STUB_BIN}:${PATH}"
}

stub_handler() {
  # stub_handler <<'EOF' ... EOF — append handler functions (stub_kubectl ...)
  cat >> "${STUB_HANDLER}"
}

stub_calls() {
  # stub_calls [name] — the recorded calls (of one stub)
  if (( $# )); then grep -E "^$1( |$)" "${STUB_LOG}" || true; else cat "${STUB_LOG}"; fi
}

mutating_calls() {
  # the recorded calls that would change a cluster, host or registry
  grep -E "${MUTATING_RE}" "${STUB_LOG}" | grep -v -- '--dry-run' || true
}

common_env() {
  # An environment in which common.sh can be sourced by a non-root test:
  # stub kubectl, sandboxed paths, short poll intervals.
  export KUBECTL=kubectl
  export TEKNOIR_HOST_ROOT="${BATS_TEST_TMPDIR}/root"
  export STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export TEKNOIR_LOG_DIR="${BATS_TEST_TMPDIR}/log"
  export TEKNOIR_LOCK_FILE="${BATS_TEST_TMPDIR}/teknoir-airgap.lock"
  export WAIT_INTERVAL=1 STUB_WAIT_INTERVAL=1
  export NODE_ROOT="${NODE_DIR}"
  mkdir -p "${TEKNOIR_HOST_ROOT}" "${STATE_DIR}"
}

with_common() {
  # with_common <bash code> — run the code in a fresh bash that sourced
  # COMMON_SH under `set -euo pipefail` (as teknoir-node does), killed after
  # WITH_COMMON_TIMEOUT (60) seconds (exit 124); use with `run`.
  # shellcheck disable=SC2016  # $1 and $2 are expanded by the inner bash
  timeout "${WITH_COMMON_TIMEOUT:-60}" bash -c 'set -euo pipefail; source "$1"; eval "$2"' with_common "${COMMON_SH}" "$1"
}

stage_payload() {
  # stage_payload <dest> — copy the node payload, add small stand-ins for the
  # build artifacts a source tree lacks (contract #1: k3s/, bootstrap-images/,
  # charts/pins.txt), and write node/SHA256SUMS the way the bundle build does
  # (sha256 of every file, paths relative to node/)
  local dest="$1" n img
  mkdir -p "${dest}"
  cp -a "${NODE_DIR}" "${dest}/node"
  n="${dest}/node"
  mkdir -p "${n}/k3s" "${n}/bootstrap-images" "${n}/charts"
  if [[ ! -e "${n}/k3s/k3s" ]]; then
    printf '#!/bin/sh\necho "k3s version v1.33.5+k3s1 (test stand-in)"\n' > "${n}/k3s/k3s"
    printf '#!/bin/sh\nexit 0\n' > "${n}/k3s/install.sh"
    chmod +x "${n}/k3s/k3s" "${n}/k3s/install.sh"
    head -c 4096 /dev/urandom > "${n}/k3s/k3s-airgap-images-amd64.tar.zst"
    (cd "${n}/k3s" && sha256sum k3s k3s-airgap-images-amd64.tar.zst > sha256sum-amd64.txt)
  fi
  if [[ -z "$(ls -A "${n}/bootstrap-images")" ]]; then
    img="$(mktemp -d)"
    echo '[{"Config":"c.json","RepoTags":["docker.io/rancher/mirrored-pause:3.6"],"Layers":[]}]' > "${img}/manifest.json"
    echo '{}' > "${img}/c.json"
    tar -C "${img}" -cf "${n}/bootstrap-images/docker.io_rancher_mirrored-pause_3.6.tar" manifest.json c.json
    rm -rf "${img}"
  fi
  [[ -f "${n}/charts/pins.txt" ]] || echo "app-of-apps 0.0.4" > "${n}/charts/pins.txt"
  (cd "${n}" && rm -f SHA256SUMS &&
    find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS)
}
