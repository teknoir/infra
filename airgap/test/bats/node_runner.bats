#!/usr/bin/env bats
# node_runner.bats — airgap/node/bin/teknoir-node (I-05, I-10): CLI, lock,
# log file, payload verify, dry-run without mutations, the downgrade guard.
#
# The runner runs as a normal user in its test sandbox (TEKNOIR_HOST_ROOT
# prefixes every host path), with the recording stubs for kubectl, k3s,
# systemctl, ip, crane, helm and curl. The payload is staged where the LAN
# side puts it: <root>/var/lib/teknoir-airgap/bundles/<bundleId>/node, with
# SHA256SUMS.
#
# Two stub worlds: a fresh node (no k3s; every API call is refused, as kubectl
# does without a server) and an existing cluster (stub_existing_cluster:
# k3s runs, every object exists, every server-side diff reports a change,
# Harbor answers but holds nothing), so a dry-run walks every mutation gate.

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
  # the node owns NODE_IP; a fresh node: no k3s, so kubectl reaches no API
  # server (only `version --client` works) and no unit is active
  stub_handler <<'EOF'
stub_ip() { echo "2: ens3    inet 10.77.0.10/24 brd 10.77.0.255 scope global ens3"; echo "1: lo    inet 127.0.0.1/8 scope host lo"; }
stub_kubectl() {
  case " $* " in
    *" version "*"--client"*) echo "Client Version: v1.33.5+k3s1"; return 0 ;;
  esac
  echo "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?" >&2
  return 1
}
stub_systemctl() {
  case "$1" in
    is-active|is-enabled) return 3 ;;
  esac
  return 0
}
EOF
}

stub_existing_cluster() {
  # The world of a node that runs this platform already: k3s installed and
  # active, every object a phase looks up exists (a converged cluster),
  # `kubectl diff --server-side` reports a difference for every apply (so
  # each apply gate is reached), Harbor is healthy but has no projects,
  # charts or images (so each push gate is reached). Reads return plausible
  # data; nothing a dry-run may not call fails here.
  local ca="${BATS_TEST_TMPDIR}/stub-ca.crt" k3s="${TEKNOIR_HOST_ROOT}/usr/local/bin/k3s"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj "/CN=stub CA" -days 3650 \
    -addext "basicConstraints=critical,CA:TRUE" -out "${ca}" 2>/dev/null
  STUB_CA_B64="$(base64 -w0 < "${ca}")"
  export STUB_CA_B64
  # the installed k3s is this bundle's (its stand-in hands calls to the k3s
  # stub, and `k3s kubectl` reaches the kubectl stub)
  mkdir -p "$(dirname "${k3s}")" "${TEKNOIR_HOST_ROOT}/opt/k3s/server/db" "${TEKNOIR_HOST_ROOT}/etc/systemd/system"
  install -m 0755 "${BUNDLE}/node/k3s/k3s" "${k3s}"
  printf '[Unit]\nDescription=Lightweight Kubernetes (test stand-in)\n' > "${TEKNOIR_HOST_ROOT}/etc/systemd/system/k3s.service"
  : > "${TEKNOIR_HOST_ROOT}/opt/k3s/server/db/state.db"
  stub_handler <<'EOF'
_words() {
  # the positional words of a kubectl call (flags and their values dropped)
  local skip=0 w
  for w in "$@"; do
    if (( skip )); then skip=0; continue; fi
    case "${w}" in
      -n|--namespace|--context|-o|--output|-l|--selector|-f|--filename|--field-manager|--request-timeout|--sort-by|-c|--container|--for|--timeout|-p|--type) skip=1 ;;
      -*) ;;
      *) printf '%s\n' "${w}" ;;
    esac
  done
}
stub_kubectl() {
  local a=" $* " verb res name
  verb="$(_words "$@" | sed -n 1p)" res="$(_words "$@" | sed -n 2p)" name="$(_words "$@" | sed -n 3p)"
  case "${a}" in
    *" version "*) echo "Client Version: v1.33.5+k3s1"; echo "Server Version: v1.33.5+k3s1"; return 0 ;;
    *" --raw"*) echo ok; return 0 ;;
  esac
  case "${verb}" in
    diff) echo "diff -q LIVE MERGED: differ"; return 1 ;;
    api-resources)
      printf '%s\n' customresourcedefinitions.apiextensions.k8s.io namespaces secrets configmaps \
        deployments.apps jobs.batch applications.argoproj.io appprojects.argoproj.io; return 0 ;;
    wait|rollout|logs|top|auth|explain|describe) return 0 ;;
    get) ;;
    *) return 0 ;;
  esac
  case "${a}" in
    *" -o name "*|*" -o=name "*|*" --output=name "*)
      [ -n "${name}" ] && printf '%s/%s\n' "${res%%.*}" "${name}"; return 0 ;;
    *go-template*)
      case "${res}/${name}" in
        secret/teknoir-root-ca|secrets/teknoir-root-ca) printf '%s' "${STUB_CA_B64}" ;;
        *) printf '%s' "c3R1Yi12YWx1ZS1ub3QtYS1zZWNyZXQtMTIzNDU2" ;;
      esac
      return 0 ;;
    *Established*) echo True; return 0 ;;
    *"teknoir.org/storage"*) echo true; return 0 ;;
  esac
  case "${res}" in
    configmap|configmaps|cm)
      if [ "${name}" = teknoir-airgap-release ]; then
        printf '{"metadata":{"name":"teknoir-airgap-release"},"data":{"appOfAppsVersion":"0.0.4","bundleId":"teknoir-local-aoa0.0.4-20261001-iccccccc-gddddddd","manifestSha256":"%064d","mode":"install","history":""}}\n' 0
        return 0
      fi ;;
    nodes|node)
      echo '{"items":[{"metadata":{"name":"teknoir","labels":{"teknoir.org/storage":"true"}},"status":{"addresses":[{"type":"InternalIP","address":"10.77.0.10"}]}}]}'
      return 0 ;;
    applications|applications.argoproj.io|application|app|apps)
      if [ -n "${name}" ]; then
        case "${a}" in
          *jsonpath*targetRevision*) echo 0.0.4 ;;
          *) printf '{"metadata":{"name":"%s"},"spec":{"source":{"targetRevision":"0.0.4"}},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"},"reconciledAt":"2099-01-01T00:00:00Z"}}\n' "${name}" ;;
        esac
      else
        echo '{"items":[{"metadata":{"name":"app-of-apps","namespace":"teknoir-system"},"spec":{"source":{"targetRevision":"0.0.4"}},"status":{"sync":{"status":"Synced","revision":"0.0.4"},"health":{"status":"Healthy"},"reconciledAt":"2099-01-01T00:00:00Z"}}]}'
      fi
      return 0 ;;
  esac
  case "${a}" in
    *" -o json "*|*" -o=json "*) if [ -n "${name}" ]; then printf '{"metadata":{"name":"%s"},"data":{}}\n' "${name}"; else echo '{"items":[]}'; fi ;;
  esac
  return 0
}
stub_systemctl() {
  case "$1" in
    is-active) [ "${*: -1}" = k3s ] && return 0; return 3 ;;
    show) case " $* " in *ActiveEnterTimestamp*) echo "Thu 2026-10-08 10:00:00 UTC" ;; *ActiveState*) echo active ;; esac; return 0 ;;
  esac
  return 0
}
stub_k3s() {
  case "$1" in
    --version|-v) echo "k3s version v1.33.5+k3s1 (test stand-in)"; return 0 ;;
    kubectl) stub_default "$@"; return $? ;;
    ctr) case " $* " in *" images ls"*|*" images list"*) echo "docker.io/rancher/mirrored-pause:3.6" ;; esac; return 0 ;;
  esac
  return 0
}
stub_curl() {
  # Harbor's API: healthy, no projects, no robots; -o FILE gets the body,
  # -w prints the status code
  local out="" url="" prev="" w body='[]'
  for w in "$@"; do
    [ "${prev}" = -o ] && out="${w}"
    case "${w}" in https://*|http://*) url="${w}" ;; esac
    prev="${w}"
  done
  case "${url}" in
    */health) body='{"status":"healthy","components":[{"name":"core","status":"healthy"},{"name":"registry","status":"healthy"},{"name":"database","status":"healthy"}]}' ;;
  esac
  if [ -n "${out}" ]; then printf '%s' "${body}" > "${out}"; else printf '%s' "${body}"; fi
  case " $* " in *" -w "*) printf '200' ;; esac
  return 0
}
stub_crane() {
  case "$1" in
    auth) return 0 ;;
    manifest|config|digest|blob)
      echo "GET https://harbor.teknoir.airgapped/v2/x/manifests/y: MANIFEST_UNKNOWN: manifest unknown" >&2; return 1 ;;
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

host_files() {
  # every file under the sandbox root but the staged payload, the run logs
  # and the stub state
  (cd "${TEKNOIR_HOST_ROOT}" && find . -type f ! -path "./var/lib/teknoir-airgap/bundles/*" | sort)
}

@test "converge --dry-run on a fresh node makes no mutating call and writes no host file" {
  local l
  for l in host secrets oneshot harbor release backup; do require_file "${NODE_DIR}/lib/${l}.sh"; done
  local before
  before="$(host_files)"
  run "${NODE_BIN}" converge --dry-run --site "${VMTEST_SITE}" --lan-time "$(date +%s)"
  echo "${output}" | tail -20
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"summary (dry-run)"* ]]
  local m
  m="$(mutating_calls)"
  [ -z "${m}" ] || { echo "mutating calls: ${m}"; return 1; }
  [ ! -e "${TEKNOIR_HOST_ROOT}/etc/rancher/k3s/config.yaml" ]
  [ ! -e "${TEKNOIR_HOST_ROOT}/etc/rancher/k3s/registries.yaml" ]
  [ ! -e "${TEKNOIR_HOST_ROOT}/usr/local/bin/k3s" ]
  [ "$(host_files)" = "${before}" ]
}

@test "converge --dry-run on an existing cluster makes no mutating call and writes no host file" {
  local l
  for l in host secrets oneshot harbor release backup; do require_file "${NODE_DIR}/lib/${l}.sh"; done
  stub_existing_cluster
  local before
  before="$(host_files)"
  run "${NODE_BIN}" converge --dry-run --site "${VMTEST_SITE}" --lan-time "$(date +%s)"
  echo "${output}" | tail -25
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"summary (dry-run)"* ]]
  local m
  m="$(mutating_calls)"
  [ -z "${m}" ] || { echo "mutating calls: ${m}"; return 1; }
  [ "$(host_files)" = "${before}" ]
  # the gates were reached: server-side diffs ran and Harbor was asked
  [ -n "$(stub_calls kubectl | grep -E ' diff ' || true)" ]
  [ -n "$(stub_calls curl)" ]
}

@test "MUTATING_RE: kubectl exec/cp and curl writes are mutating; reads are not" {
  local l
  for l in "kubectl -n teknoir-auth exec keycloak-0 -- pg_dump" "k3s kubectl cp a:b c" \
           "curl -sS -X POST https://h/api" "curl -sS --request=DELETE https://h/api" \
           "curl -sS --data-binary \\{\\} https://h/api" "curl -XPUT https://h" \
           "kubectl apply --server-side -f -" "crane push a b" "helm registry login h"; do
    grep -qE "${MUTATING_RE}" <<<"${l}" || { echo "not mutating: ${l}"; return 1; }
  done
  for l in "kubectl get pods -o json" "kubectl diff --server-side -f x" "curl -sS -X GET https://h/api" \
           "curl -sS -o /tmp/b -w %\\{http_code\\} https://h/health" "crane manifest a" "kubectl get secret x -o name"; do
    if grep -qE "${MUTATING_RE}" <<<"${l}"; then echo "wrongly mutating: ${l}"; return 1; fi
  done
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
