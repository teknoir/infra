#!/usr/bin/env bats
# node_runner.bats — airgap/node/bin/teknoir-node (I-05, I-10): CLI, lock,
# log file, payload verify, dry-run without mutations, the downgrade guard.
#
# The runner runs as a normal user in its test sandbox (TEKNOIR_HOST_ROOT
# prefixes every host path), with the recording stubs for kubectl, k3s,
# systemctl, ip, crane and helm. The payload is staged where the LAN side puts
# it: <root>/var/lib/teknoir-airgap/bundles/<bundleId>/node, with SHA256SUMS.

# shellcheck disable=SC2016,SC2030,SC2031  # code strings for the inner shells; bats runs each test in a subshell

load test_helper

BID=teknoir-local-aoa0.0.4-20261009-iaaaaaaa-gbbbbbbb

setup() {
  # shellcheck disable=SC2153  # NODE_DIR comes from test_helper.bash (load)
  require_file "${NODE_DIR}/bin/teknoir-node"
  setup_stubs
  common_env
  BUNDLE="${TEKNOIR_HOST_ROOT}/var/lib/teknoir-airgap/bundles/${BID}"
  stage_payload "${BUNDLE}"
  NODE_BIN="${BUNDLE}/node/bin/teknoir-node"
  # the node owns NODE_IP; the API is not reachable (a fresh node)
  stub_handler <<'EOF'
stub_ip() { echo "2: ens3    inet 10.77.0.10/24 brd 10.77.0.255 scope global ens3"; echo "1: lo    inet 127.0.0.1/8 scope host lo"; }
stub_kubectl() {
  case " $* " in
    *" --raw"*readyz*) echo "The connection to the server 127.0.0.1:6443 was refused" >&2; return 1 ;;
  esac
  return 0
}
EOF
}

@test "help lists the converge, status, credentials, rotate, backup and migrate commands" {
  run "${NODE_BIN}" help
  [ "${status}" -eq 0 ]
  for c in converge status credentials rotate backup migrate; do
    [[ "${output}" == *"${c}"* ]] || { echo "missing: ${c}"; return 1; }
  done
}

@test "an unknown command is a usage error (exit 2)" {
  run "${NODE_BIN}" no-such-command
  [ "${status}" -eq 2 ]
}

@test "refuses to run as non-root outside the test sandbox" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  unset TEKNOIR_HOST_ROOT
  run "${NODE_BIN}" status --site "${VMTEST_SITE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *root* ]]
}

@test "a second mutating run while the lock is held exits 75" {
  flock -n "${TEKNOIR_LOCK_FILE}" -c "sleep 30" 3>&- &
  holder=$!
  for _ in $(seq 1 50); do flock -n "${TEKNOIR_LOCK_FILE}" -c true 2>/dev/null || break; sleep 0.1; done
  run "${NODE_BIN}" converge --site "${VMTEST_SITE}" --lan-time "$(date +%s)"
  kill "${holder}" 2>/dev/null || true
  [ "${status}" -eq 75 ]
  [ -z "$(mutating_calls)" ]
}

@test "every run writes a 0600 log named <UTC>-<command>.log" {
  run "${NODE_BIN}" verify --site "${VMTEST_SITE}"
  log="$(find "${TEKNOIR_LOG_DIR}" -type f -name '*-verify*.log' | head -1)"
  [ -n "${log}" ]
  [ "$(stat -c %a "${log}")" = 600 ]
  [[ "$(basename "${log}")" =~ ^[0-9]{8}T[0-9]{6}Z-verify ]]
}

@test "verify passes on an intact payload" {
  run "${NODE_BIN}" verify --site "${VMTEST_SITE}"
  [ "${status}" -eq 0 ]
}

@test "verify fails on a tampered payload file and names it" {
  printf '\n# tampered\n' >> "${BUNDLE}/node/lib/common.sh"
  run "${NODE_BIN}" verify --site "${VMTEST_SITE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *lib/common.sh* ]]
}

@test "verify fails on a file SHA256SUMS does not list" {
  printf 'x\n' > "${BUNDLE}/node/lib/planted.sh"
  run "${NODE_BIN}" verify --site "${VMTEST_SITE}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *planted.sh* ]]
}

@test "a tampered payload stops converge before any cluster or host change" {
  printf '\n# tampered\n' >> "${BUNDLE}/node/lib/host.sh"
  run "${NODE_BIN}" converge --site "${VMTEST_SITE}" --lan-time "$(date +%s)"
  [ "${status}" -ne 0 ]
  [ -z "$(mutating_calls)" ]
  [ ! -e "${TEKNOIR_HOST_ROOT}/etc/rancher/k3s/config.yaml" ]
}

@test "converge --dry-run on a fresh node makes no mutating call and writes no host file" {
  local l
  for l in host secrets oneshot harbor release backup; do require_file "${NODE_DIR}/lib/${l}.sh"; done
  run "${NODE_BIN}" converge --dry-run --site "${VMTEST_SITE}" --lan-time "$(date +%s)"
  echo "${output}" | tail -20
  [ "${status}" -eq 0 ]
  [ -z "$(mutating_calls)" ]
  [ ! -e "${TEKNOIR_HOST_ROOT}/etc/rancher/k3s/config.yaml" ]
  [ ! -e "${TEKNOIR_HOST_ROOT}/etc/rancher/k3s/registries.yaml" ]
  [ ! -e "${TEKNOIR_HOST_ROOT}/usr/local/bin/k3s" ]
}

# ---------------------------------------------------------------------------
# downgrade guard (I-10): release_guard in lib/release.sh
# ---------------------------------------------------------------------------
release_cm() {
  # the cluster holds the release record of app-of-apps $1
  stub_handler <<EOF
stub_kubectl() {
  case " \$* " in
    *" get configmap teknoir-airgap-release "*" -o name"*|*" get configmap teknoir-airgap-release "*"-o=name"*) echo configmap/teknoir-airgap-release ;;
    *" get configmap teknoir-airgap-release "*json*) printf '{"data":{"appOfAppsVersion":"%s","bundleId":"teknoir-local-aoa%s-x"}}' "$1" "$1" ;;
  esac
  return 0
}
EOF
}

guard() {
  # guard <bundle app-of-apps version> [ROLLBACK] — run release_guard
  run with_common "source '${NODE_DIR}/lib/release.sh'; APP_OF_APPS_VERSION='$1' ROLLBACK='${2:-0}'; release_guard; echo GUARD-OK"
}

@test "downgrade guard: an older app-of-apps than the recorded one is refused" {
  require_fn "${NODE_DIR}/lib/release.sh" release_guard
  release_cm 0.0.4
  guard 0.0.3
  [ "${status}" -ne 0 ]
  [[ "${output}" != *GUARD-OK* ]]
  [[ "${output}" == *rollback* ]]
}

@test "downgrade guard: --rollback accepts the older version" {
  require_fn "${NODE_DIR}/lib/release.sh" release_guard
  release_cm 0.0.4
  guard 0.0.3 1
  [ "${status}" -eq 0 ]
  [[ "${output}" == *GUARD-OK* ]]
}

@test "downgrade guard: the same or a newer version passes" {
  require_fn "${NODE_DIR}/lib/release.sh" release_guard
  release_cm 0.0.4
  guard 0.0.4
  [ "${status}" -eq 0 ]
  guard 0.0.5
  [ "${status}" -eq 0 ]
}

@test "downgrade guard: a broken app-of-apps (0.0.1, 0.0.2) is refused even with --rollback" {
  require_fn "${NODE_DIR}/lib/release.sh" release_guard
  release_cm 0.0.4
  guard 0.0.2 1
  [ "${status}" -ne 0 ]
  [[ "${output}" != *GUARD-OK* ]]
}

@test "downgrade guard: an API error is fatal, not 'no release recorded'" {
  require_fn "${NODE_DIR}/lib/release.sh" release_guard
  stub_handler <<'EOF'
stub_kubectl() { echo "Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused" >&2; return 1; }
EOF
  guard 0.0.3
  [ "${status}" -ne 0 ]
  [[ "${output}" != *GUARD-OK* ]]
}
