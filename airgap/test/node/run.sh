#!/usr/bin/env bash
# run.sh: unit tests for the node runner (airgap/node), with stub kubectl,
# k3s, systemctl, ip and install.sh, in a sandbox (TEKNOIR_HOST_ROOT): no
# root, no cluster, nothing outside a temp dir is touched.
#
# Covers: template rendering (byte-equal to the live coredns-custom), payload
# verify (tamper, unlisted file), error-vs-absent in in_cluster, lock
# contention (exit 75), dry-run on a fresh node makes no mutating call, the
# host phase (fresh install, idempotent re-run, restart only on a desired
# config change, restart after an interrupted run, secrets-encryption only on
# new installs, managed /etc/hosts block), node CA trust, the release guard
# (downgrade, --rollback, broken list), credentials refusing a terminal, the
# runner interface (teknoir-airgap up's exact converge argv, --operator, the
# break-glass flags reaching the oneshot and harbor phases as ONESHOT_REAPPLY
# and HARBOR_FORCE_IMAGES, --reapply checked against oneshot/TIERS), the
# preflight refusal of an unmigrated cluster (live Teknoir K3s files), and the
# leak check. With lib/oneshot.sh and lib/harbor.sh present the real phases
# parse the flags (only their cluster/Harbor work is replaced); without them
# a stand-in with their interface is used.
#
# Usage: airgap/test/node/run.sh [-v]
#   TEKNOIR_NODE_SRC=DIR   test another airgap/node tree
# shellcheck disable=SC2016 # literal $1 / $ patterns in single quotes are intended
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TEKNOIR_NODE_SRC: another airgap/node tree (e.g. with the oneshot/harbor
# libraries of I-08/I-09 merged in) to test instead of this checkout's.
SRC="$(cd "${TEKNOIR_NODE_SRC:-${HERE}/../../node}" && pwd)"
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
nok()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else nok "${d}"; fi; }

# ---------------------------------------------------------------------------
# Sandbox: <T>/root is the host root; the payload sits where the LAN side
# puts it (/var/lib/teknoir-airgap/bundles/<id>/node).
# ---------------------------------------------------------------------------
new_sandbox() {
  ROOT="${T}/root$1"
  BID="teknoir-local-aoa0.0.4-20261009-i1111111-g2222222"
  PAYLOAD="${ROOT}/var/lib/teknoir-airgap/bundles/${BID}/node"
  STUB_STATE="${T}/state$1"
  STUB_CALLS="${T}/calls$1.log"
  mkdir -p "${PAYLOAD}" "${STUB_STATE}" "${ROOT}/etc" "${ROOT}/run"
  : > "${STUB_CALLS}"
  printf '127.0.0.1 localhost\n# BEGIN teknoir-airgap (managed by bootstrap-airgap.sh)\n1.2.3.4 old.example\n# END teknoir-airgap\n::1 ip6-localhost\n' > "${ROOT}/etc/hosts"
  cp -r "${SRC}/bin" "${SRC}/lib" "${SRC}/templates" "${PAYLOAD}/"
  mkdir -p "${PAYLOAD}/site" "${PAYLOAD}/k3s" "${PAYLOAD}/bootstrap-images" "${PAYLOAD}/charts"
  cat > "${PAYLOAD}/site/test.env" <<'EOF'
TEKNOIR_ENV=teknoir-local
TEKNOIR_DOMAIN=teknoir.airgapped
NODE_IP=10.77.0.10
NODE=teknoir@10.77.0.10
TEKNOIR_HOSTNAMES="harbor argocd auth keycloak grafana"
K3S_DATA_DIR=/opt/k3s
EOF
  cp "${HERE}/stubs/k3s" "${PAYLOAD}/k3s/k3s"
  cp "${HERE}/stubs/install.sh" "${PAYLOAD}/k3s/install.sh"
  head -c 4096 /dev/urandom > "${PAYLOAD}/k3s/k3s-airgap-images-amd64.tar.zst"
  ( cd "${PAYLOAD}/k3s" && sha256sum k3s k3s-airgap-images-amd64.tar.zst > sha256sum-amd64.txt )
  mkdir -p "${T}/img"
  echo '[{"Config":"c.json","RepoTags":["docker.io/rancher/mirrored-pause:3.6"],"Layers":[]}]' > "${T}/img/manifest.json"
  echo '{}' > "${T}/img/c.json"
  tar -C "${T}/img" -cf "${PAYLOAD}/bootstrap-images/docker.io_rancher_mirrored-pause_3.6.tar" manifest.json c.json
  echo "app-of-apps 0.0.4" > "${PAYLOAD}/charts/pins.txt"
  reseal
}

reseal() {
  # (Re)write node/SHA256SUMS and the MANIFEST.yaml next to node/.
  ( cd "${PAYLOAD}" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum ) > "${T}/sums"
  mv "${T}/sums" "${PAYLOAD}/SHA256SUMS"
  cat > "${PAYLOAD}/../MANIFEST.yaml" <<EOF
bundleId: ${BID}
env: teknoir-local
domain: teknoir.airgapped
appOfAppsVersion: "${AOA:-0.0.4}"
infraCommit: 1111111
gitopsCommit: 2222222
files:
  node/SHA256SUMS: $(sha256sum "${PAYLOAD}/SHA256SUMS" | cut -d' ' -f1)
EOF
}

node_env() {
  env PATH="${HERE}/stubs:${PATH}" \
    TEKNOIR_HOST_ROOT="${ROOT}" STUB_STATE="${STUB_STATE}" STUB_CALLS="${STUB_CALLS}" \
    KUBECTL="kubectl" TEKNOIR_MIN_FREE_GB=0 WAIT_INTERVAL=1 K3S_IMPORT_WAIT=0 K3S_READY_TIMEOUT=5 \
    STUB_CTR_IMAGES="${STUB_STATE}/ctr-images" STUB_KUBECTL_MODE="${KMODE:-up}" "$@"
}

tn() {
  # tn <args...> - run the payload's teknoir-node; output in ${T}/out, rc in RC.
  RC=0
  node_env "${PAYLOAD}/bin/teknoir-node" "$@" > "${T}/out" 2>&1 || RC=$?
  (( VERBOSE )) && sed 's/^/    | /' "${T}/out"
  return 0
}

calls_since() { tail -n +"$(( $1 + 1 ))" "${STUB_CALLS}"; }
ncalls() { wc -l < "${STUB_CALLS}"; }

# ---------------------------------------------------------------------------
echo "# template rendering"
new_sandbox 1
(
  export NODE_ROOT="${PAYLOAD}"
  # shellcheck source=/dev/null
  source "${PAYLOAD}/lib/common.sh"
  # shellcheck source=/dev/null
  source "${PAYLOAD}/site/test.env"
  export NODE_IP=192.168.5.181 HARBOR_HOST=harbor.teknoir.airgapped
  render_template "${PAYLOAD}/templates/coredns-custom.yaml.tmpl" > "${T}/coredns.yaml"
  render_template "${PAYLOAD}/templates/registries.yaml.tmpl" > "${T}/registries.yaml"
  APP_OF_APPS_VERSION=0.0.4 render_template "${PAYLOAD}/templates/app-of-apps.yaml.tmpl" > "${T}/aoa.yaml"
  render_template "${PAYLOAD}/templates/config.yaml.tmpl" SECRETS_ENCRYPTION= FLANNEL_IFACE= RESOLV_CONF= > "${T}/config-noenc.yaml"
)
live='teknoir.airgapped:53 {
    errors
    hosts {
        192.168.5.181 harbor.teknoir.airgapped
        192.168.5.181 argocd.teknoir.airgapped
        192.168.5.181 auth.teknoir.airgapped
        192.168.5.181 keycloak.teknoir.airgapped
        192.168.5.181 grafana.teknoir.airgapped
        192.168.5.181 teknoir.airgapped
    }
}'
rendered="$(awk '/teknoir.server: \|/{f=1; next} f {sub(/^    /, ""); print}' "${T}/coredns.yaml")"
check "coredns-custom renders byte-equal to the live teknoir-local ConfigMap data" [ "${rendered}" == "${live}" ]
check "registries.yaml mirrors 5 registries to harbor with the CA" \
  [ "$(grep -c '"https://harbor.teknoir.airgapped"' "${T}/registries.yaml")" == 5 -a "$(grep -c 'ca_file: /etc/rancher/k3s/teknoir-root-ca.crt' "${T}/registries.yaml")" == 1 ]
check "app-of-apps root pins 0.0.4 from harbor.<domain>/teknoir" grep -q 'targetRevision: 0.0.4' "${T}/aoa.yaml"
check "config.yaml without encryption has no secrets-encryption line" bash -c "! grep -q secrets-encryption '${T}/config-noenc.yaml'"
if bash -c "export NODE_ROOT='${PAYLOAD}'; source '${PAYLOAD}/lib/common.sh'; printf 'x: __NOPE__\n' > '${T}/bad.tmpl'; render_template '${T}/bad.tmpl'" >/dev/null 2>&1; then
  nok "an unknown placeholder fails the render"
else
  ok "an unknown placeholder fails the render"
fi

# ---------------------------------------------------------------------------
echo "# payload verify"
tn verify
check "verify passes on a sealed payload" [ "${RC}" == 0 ]
echo extra > "${PAYLOAD}/lib/extra.sh"
tn verify
check "an unlisted file fails verify" [ "${RC}" != 0 ]
rm -f "${PAYLOAD}/lib/extra.sh"
cp "${PAYLOAD}/templates/config.yaml.tmpl" "${T}/cfg.bak"
echo "# tampered" >> "${PAYLOAD}/templates/config.yaml.tmpl"
tn verify
check "a modified file fails verify" [ "${RC}" != 0 ]
cp "${T}/cfg.bak" "${PAYLOAD}/templates/config.yaml.tmpl"
sed -i 's/^\(  node\/SHA256SUMS: \).*/\10000000000000000000000000000000000000000000000000000000000000000/' "${PAYLOAD}/../MANIFEST.yaml"
tn verify
check "SHA256SUMS not matching MANIFEST.yaml fails verify" [ "${RC}" != 0 ]
reseal

# ---------------------------------------------------------------------------
echo "# usage"
tn converge --site test --only nonsense
check "an unknown phase is a usage error (exit 2)" [ "${RC}" == 2 ]
tn frobnicate
check "an unknown command is a usage error (exit 2)" [ "${RC}" == 2 ]

# ---------------------------------------------------------------------------
echo "# in_cluster: error vs absent"
probe() {
  KMODE="$1" node_env bash -c "
    export NODE_ROOT='${PAYLOAD}'; source '${PAYLOAD}/lib/common.sh'
    if in_cluster secret x teknoir-system; then echo present; else echo absent; fi" 2>&1 || true
}
out="$(probe refused)"
check "connection refused dies, never reads as absent" bash -c "[[ '${out//\'/}' == *'cannot check'* && '${out//\'/}' != *absent* ]]"
out="$(probe up)"
check "an empty --ignore-not-found answer reads as absent" [ "${out}" == "absent" ]
out="$(probe resourcetype)"
check "an unknown resource type (no CRD) reads as absent" [ "${out}" == "absent" ]

# ---------------------------------------------------------------------------
echo "# lock"
mkdir -p "${ROOT}/run"
( flock "${ROOT}/run/teknoir-airgap.lock" sleep 3 ) &
sleep 0.5
tn converge --site test --only verify
check "a second lock holder exits 75" [ "${RC}" == 75 ]
wait

# ---------------------------------------------------------------------------
echo "# dry-run on a fresh node (no k3s, API down)"
before="$(ncalls)"
find "${ROOT}" -path "${ROOT}/var/log" -prune -o -print | sort > "${T}/tree.before"
KMODE=refused tn converge --site test --dry-run --skip oneshot,harbor
check "dry-run converge on a fresh node succeeds" [ "${RC}" == 0 ]
check "dry-run reports the k3s install" grep -q 'would change: install k3s' "${T}/out"
check "dry-run reports the config.yaml write" grep -q "would change: write ${ROOT}/etc/rancher/k3s/config.yaml" "${T}/out"
check "dry-run defers the cluster phases" grep -q 'secrets: the cluster is not reachable' "${T}/out"
mut="$(calls_since "${before}" | grep -E '^kubectl .*( create | apply | patch | delete | annotate | label | replace | rollout )|^systemctl (start|stop|restart)|^install\.sh|^k3s ctr .* import|^update-ca' || true)"
check "dry-run makes no mutating stub call" [ -z "${mut}" ]
find "${ROOT}" -path "${ROOT}/var/log" -prune -o -print | sort > "${T}/tree.after"
check "dry-run writes no file outside the log dir" cmp -s "${T}/tree.before" "${T}/tree.after"

# ---------------------------------------------------------------------------
echo "# host phase: fresh install"
tn converge --site test --only verify,preflight,host
check "fresh host converge succeeds" [ "${RC}" == 0 ]
check "k3s installed with INSTALL_K3S_SKIP_DOWNLOAD" grep -q 'install.sh SKIP_DOWNLOAD=true EXEC=server' "${STUB_CALLS}"
check "new install enables secrets-encryption" grep -qx 'secrets-encryption: true' "${ROOT}/etc/rancher/k3s/config.yaml"
check "config.yaml carries data-dir and node-ip" bash -c "grep -qx 'data-dir: /opt/k3s' '${ROOT}/etc/rancher/k3s/config.yaml' && grep -qx 'node-ip: 10.77.0.10' '${ROOT}/etc/rancher/k3s/config.yaml'"
check "config.yaml is 0600" [ "$(stat -c %a "${ROOT}/etc/rancher/k3s/config.yaml")" == 600 ]
check "registries.yaml written" grep -q 'dockerhub/\$1' "${ROOT}/etc/rancher/k3s/registries.yaml"
check "tarballs synced to <data-dir>/agent/images" \
  [ -f "${ROOT}/opt/k3s/agent/images/docker.io_rancher_mirrored-pause_3.6.tar" -a -f "${ROOT}/opt/k3s/agent/images/k3s-airgap-images-amd64.tar.zst" ]
check "missing bootstrap image imported with k3s ctr" grep -q 'k3s ctr -n k8s.io images import' "${STUB_CALLS}"
check "restart stamp written" [ -s "${ROOT}/var/lib/teknoir-airgap/restart.stamp" ]
check "old /etc/hosts block replaced by the managed one" \
  bash -c "grep -qx '10.77.0.10 harbor.teknoir.airgapped argocd.teknoir.airgapped auth.teknoir.airgapped keycloak.teknoir.airgapped grafana.teknoir.airgapped teknoir.airgapped' '${ROOT}/etc/hosts' && ! grep -q old.example '${ROOT}/etc/hosts' && [ \$(grep -c 'BEGIN teknoir-airgap' '${ROOT}/etc/hosts') = 1 ] && [ \"\$(tail -1 '${ROOT}/etc/hosts')\" = '::1 ip6-localhost' ]"

echo "# host phase: idempotent re-run"
before="$(ncalls)"
tn converge --site test --only verify,preflight,host
check "second host converge succeeds" [ "${RC}" == 0 ]
check "second run reports 0 changes" grep -q 'summary: 0 changes' "${T}/out"
check "second run neither installs, restarts nor imports" \
  bash -c "! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -Eq '^install\.sh|^systemctl (start|restart)|images import'"

echo "# host phase: a hand edit is reverted without a restart"
echo "# local edit" >> "${ROOT}/etc/rancher/k3s/registries.yaml"
before="$(ncalls)"
tn converge --site test --only host
check "hand-edited registries.yaml is rewritten" grep -q "changed: wrote ${ROOT}/etc/rancher/k3s/registries.yaml" "${T}/out"
check "no restart: the running k3s already has the desired content" \
  bash -c "! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q '^systemctl restart k3s'"

echo "# host phase: a desired registries change restarts exactly once"
sed -i 's|"\^(\.\*)\$": "quay/\$1"|"^(.*)$": "quay-mirror/$1"|' "${PAYLOAD}/templates/registries.yaml.tmpl"
reseal
before="$(ncalls)"
tn converge --site test --only verify,host
check "converge after a registries template change succeeds" [ "${RC}" == 0 ]
check "exactly one k3s restart" [ "$(tail -n +$(( before + 1 )) "${STUB_CALLS}" | grep -c '^systemctl restart k3s')" == 1 ]
before="$(ncalls)"
tn converge --site test --only verify,host
check "the following run does not restart again" \
  bash -c "! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q '^systemctl restart k3s'"

echo "# host phase: a run that died before its restart restarts on the re-run"
echo "config=stale registries=stale ca=absent" > "${ROOT}/var/lib/teknoir-airgap/restart.stamp"
before="$(ncalls)"
tn converge --site test --only host
check "stale stamp -> one restart" [ "$(tail -n +$(( before + 1 )) "${STUB_CALLS}" | grep -c '^systemctl restart k3s')" == 1 ]

echo "# host phase: stale tarballs are pruned, a deleted image is re-imported"
touch "${ROOT}/opt/k3s/agent/images/goharbor_harbor-core_v2.15.2.tar" "${ROOT}/opt/k3s/agent/images/.cache.json"
: > "${STUB_STATE}/ctr-images"
before="$(ncalls)"
tn converge --site test --only host
check "stale tarball pruned" [ ! -e "${ROOT}/opt/k3s/agent/images/goharbor_harbor-core_v2.15.2.tar" ]
check "k3s dotfiles are left alone" [ -e "${ROOT}/opt/k3s/agent/images/.cache.json" ]
check "missing image re-imported without a restart" \
  bash -c "tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q 'images import' && ! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q '^systemctl restart k3s'"

echo "# host phase: an existing install keeps encryption off"
new_sandbox 2
mkdir -p "${ROOT}/opt/k3s/server/db" "${ROOT}/etc/rancher/k3s" "${ROOT}/usr/local/bin" "${ROOT}/etc/systemd/system"
touch "${ROOT}/opt/k3s/server/db/state.db"
printf 'data-dir: /opt/k3s\n' > "${ROOT}/etc/rancher/k3s/config.yaml"
tn converge --site test --only host
check "host converge on an existing (pre-redesign) install succeeds" [ "${RC}" == 0 ]
check "existing install without encryption keeps it off (D6)" bash -c "! grep -q secrets-encryption '${ROOT}/etc/rancher/k3s/config.yaml'"

# ---------------------------------------------------------------------------
echo "# node CA trust"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${T}/ca.key" -out "${T}/ca.crt" -days 1 -subj /CN=test >/dev/null 2>&1
before="$(ncalls)"
node_env bash -c "
  set -euo pipefail
  export NODE_ROOT='${PAYLOAD}'
  source '${PAYLOAD}/lib/common.sh'; source '${PAYLOAD}/lib/host.sh'
  load_site '${PAYLOAD}/site/test.env'
  host_trust_ca '${T}/ca.crt'" > "${T}/out" 2>&1 || true
check "CA written to the k3s registry path" cmp -s "${T}/ca.crt" "${ROOT}/etc/rancher/k3s/teknoir-root-ca.crt"
check "CA written to the OS trust store" cmp -s "${T}/ca.crt" "${ROOT}/usr/local/share/ca-certificates/teknoir-root-ca.crt"
check "update-ca-certificates ran" bash -c "tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q '^update-ca-certificates'"
check "k3s restarted once because it started without the CA" \
  [ "$(tail -n +$(( before + 1 )) "${STUB_CALLS}" | grep -c '^systemctl restart k3s')" == 1 ]

# ---------------------------------------------------------------------------
echo "# release guard"
guard() {
  # guard <deployed aoa> <bundle aoa> [rollback] - prints ok or refused
  node_env STUB_RELEASE_AOA="$1" APP_OF_APPS_VERSION="$2" ROLLBACK="${3:-0}" bash -c "
    export NODE_ROOT='${PAYLOAD}'
    source '${PAYLOAD}/lib/common.sh'; source '${PAYLOAD}/lib/release.sh'
    load_site '${PAYLOAD}/site/test.env'
    ( release_guard ) >/dev/null 2>&1 && echo ok || echo refused"
}
check "same version: ok" [ "$(guard 0.0.4 0.0.4)" == ok ]
check "upgrade 0.0.4 -> 0.0.5: ok" [ "$(guard 0.0.4 0.0.5)" == ok ]
check "downgrade 0.0.4 -> 0.0.3 without --rollback: refused" [ "$(guard 0.0.4 0.0.3)" == refused ]
check "downgrade 0.0.4 -> 0.0.3 with --rollback: ok" [ "$(guard 0.0.4 0.0.3 1)" == ok ]
check "0.0.10 is newer than 0.0.9 (version sort)" [ "$(guard 0.0.10 0.0.9)" == refused ]
check "broken 0.0.2 refused even with --rollback" [ "$(guard 0.0.4 0.0.2 1)" == refused ]
check "broken 0.0.1 refused on a first install" [ "$(guard "" 0.0.1)" == refused ]
check "an unpinned version is refused" [ "$(guard "" latest)" == refused ]

# ---------------------------------------------------------------------------
echo "# post: live image check"
cat > "${STUB_STATE}/pods.json" <<'EOF'
{"items": [
  {"status": {"phase": "Running"}, "spec": {"containers": [{"image": "istio/proxyv2:1.29.2"}], "initContainers": [{"image": "redis:7"}]}},
  {"status": {"phase": "Running"}, "spec": {"containers": [{"image": "ghcr.io/teknoir/gone:1"}]}},
  {"status": {"phase": "Succeeded"}, "spec": {"containers": [{"image": "quay.io/ignored:1"}]}}
]}
EOF
printf 'docker.io/library/redis:7\n' > "${STUB_STATE}/ctr-images"
cat > "${T}/crane" <<'EOF'
#!/usr/bin/env bash
printf 'crane %s\n' "$*" >> "${STUB_CALLS}"
[[ "$*" == "digest --platform linux/amd64 harbor.teknoir.airgapped/dockerhub/istio/proxyv2:1.29.2" ]]
EOF
chmod +x "${T}/crane"
imgcheck() {
  node_env CRANE="${T}/crane" bash -c "
    set -euo pipefail
    export NODE_ROOT='${PAYLOAD}'
    source '${PAYLOAD}/lib/common.sh'; source '${PAYLOAD}/lib/host.sh'; source '${PAYLOAD}/lib/release.sh'
    load_site '${PAYLOAD}/site/test.env'
    post_image_check" > "${T}/out" 2>&1 && echo pass || echo fail
}
check "an image neither in Harbor nor in containerd fails the check" [ "$(imgcheck)" == fail ]
check "the failure names the missing image" grep -q 'ghcr.io/teknoir/gone:1' "${T}/out"
check "the Harbor lookup uses the mirror project path" grep -q 'harbor.teknoir.airgapped/dockerhub/istio/proxyv2:1.29.2' "${STUB_CALLS}"
printf 'docker.io/library/redis:7\nghcr.io/teknoir/gone:1\n' > "${STUB_STATE}/ctr-images"
r="$(imgcheck)"
check "containerd-only images pass" [ "${r}" == pass ]
check "they are listed in a single warning" [ "$(grep -c 'not pullable from harbor' "${T}/out")" == 1 ]

# ---------------------------------------------------------------------------
echo "# backup: sqlite datastore with a brief k3s stop"
mkdir -p "${ROOT}/opt/k3s/server/db" "${ROOT}/opt/k3s/server/tls" "${ROOT}/opt/k3s/server/cred"
echo "sqlite" > "${ROOT}/opt/k3s/server/db/state.db"
echo "token" > "${ROOT}/opt/k3s/server/token"
before="$(ncalls)"
tn backup --site test
B="$(find "${ROOT}/var/lib/teknoir-airgap/backups" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | tail -1)"
check "backup takes the datastore, token and k3s config" \
  bash -c "[ ${RC} = 0 ] && [ -f '${B}/k3s/db/state.db' ] && [ -f '${B}/k3s/server/token' ] && [ -f '${B}/k3s/etc/config.yaml' ]"
check "k3s is stopped for the copy and started again" \
  bash -c "tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -E '^systemctl (stop|start) k3s' | tr '\n' ' ' | grep -q 'systemctl stop k3s systemctl start k3s'"
check "backup prints its path on stdout" grep -qx "${B}" "${T}/out"
chmod 000 "${ROOT}/opt/k3s/server/db/state.db"
tn backup --site test
chmod 644 "${ROOT}/opt/k3s/server/db/state.db"
check "a failed datastore copy fails the backup" [ "${RC}" != 0 ]
check "k3s is running again after the failed backup" [ -f "${STUB_STATE}/k3s.active" ]
check "no partial backup is left behind" [ -z "$(find "${ROOT}/var/lib/teknoir-airgap/backups" -name '*.partial')" ]

# ---------------------------------------------------------------------------
echo "# credentials"
if command -v script >/dev/null 2>&1; then
  node_env script -qec "'${PAYLOAD}/bin/teknoir-node' credentials harbor-admin --site test" /dev/null > "${T}/out" 2>&1 || true
  check "credentials refuses a terminal stdout" grep -q 'refusing to print a credential to a terminal' "${T}/out"
else
  echo "skip credentials tty test (no script(1))"
fi
tn credentials nonsense --site test
check "an unknown credential name fails" [ "${RC}" != 0 ]
tn credentials platform-admin --site test --out "${T}/pa.txt"
check "platform-admin is a credential name (teknoir-auth/keycloak-platform-admin, from the realm import)" \
  bash -c "! grep -q 'unknown NAME' '${T}/out' && { [ ${RC} = 0 ] || grep -q 'keycloak-platform-admin' '${T}/out'; }"

# ---------------------------------------------------------------------------
echo "# runner interface: the converge argv of teknoir-airgap up; break-glass flags reach the phases"
new_sandbox 3
mkdir -p "${PAYLOAD}/oneshot"
printf '# order\nplatform-secrets\nistio istio-system\nharbor\nargo\n' > "${PAYLOAD}/oneshot/TIERS"
for t in platform-secrets istio harbor argo; do echo '---' > "${PAYLOAD}/oneshot/${t}.yaml"; done
if [[ -f "${SRC}/lib/oneshot.sh" ]]; then
  # The real phase (I-08) parses the flags; only its per-tier apply is replaced.
  printf '\noneshot_tier() { log "oneshot_tier $1 ns=$2 force=$3"; }\n' >> "${PAYLOAD}/lib/oneshot.sh"
else
  cat > "${PAYLOAD}/lib/oneshot.sh" <<'EOF'
# shellcheck shell=bash
# Test stand-in with the interface of lib/oneshot.sh (I-08): ONESHOT_REAPPLY.
phase_oneshot() {
  local tier ns f
  while read -r tier ns; do
    f=0
    [[ " ${ONESHOT_REAPPLY:-} " == *" ${tier} "* ]] && f=1
    oneshot_tier "${tier}" "${ns:-teknoir-system}" "${f}"
  done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${NODE_ROOT}/oneshot/TIERS")
}
oneshot_tier() { log "oneshot_tier $1 ns=$2 force=$3"; }
EOF
fi
if [[ -f "${SRC}/lib/harbor.sh" ]]; then
  # The real phase (I-09) parses the flag; Harbor itself is replaced.
  cat >> "${PAYLOAD}/lib/harbor.sh" <<'EOF'
harbor_session_begin() { HARBOR_API="https://harbor.invalid/api/v2.0"; }
harbor_healthy() { return 0; }
harbor_login() { :; }
harbor_ensure_project() { :; }
harbor_mirror_projects() { :; }
harbor_ensure_immutability() { :; }
harbor_retire_robot() { :; }
harbor_push_charts() { :; }
harbor_session_end() { :; }
harbor_push_images() { log "harbor_push_images force=$1"; }
EOF
else
  cat > "${PAYLOAD}/lib/harbor.sh" <<'EOF'
# shellcheck shell=bash
# Test stand-in with the interface of lib/harbor.sh (I-09): HARBOR_FORCE_IMAGES.
phase_harbor() { harbor_push_images "${HARBOR_FORCE_IMAGES:-0}"; }
harbor_push_images() { log "harbor_push_images force=$1"; }
EOF
fi
reseal
# teknoir-airgap pushes the site file to /var/lib/teknoir-airgap/site/<name>.env
# and runs (cmd_up): converge --site <that> --lan-time <now> --lan-user <id -un>
# followed by up's options in the order given and --dry-run last.
REMOTE_SITE="${ROOT}/var/lib/teknoir-airgap/site/test.env"
mkdir -p "$(dirname "${REMOTE_SITE}")"
cp "${PAYLOAD}/site/test.env" "${REMOTE_SITE}"
KMODE=refused tn converge --site "${REMOTE_SITE}" --lan-time "$(date +%s)" --lan-user anders \
  --rollback --sync-clock --reapply istio --force-images --dry-run
check "teknoir-airgap up's exact converge argv is accepted" [ "${RC}" == 0 ]
check "the operator is recorded" grep -q 'operator anders' "${T}/out"
# The dry-run above has no reachable cluster, so the real oneshot and harbor
# phases stop at their offline plan; check the flag plumbing on a reachable one.
tn converge --site "${REMOTE_SITE}" --lan-time "$(date +%s)" --lan-user anders \
  --only oneshot,harbor --reapply istio --force-images
check "--reapply istio reaches oneshot_tier istio with force=1, and only istio" \
  bash -c "grep -q 'oneshot_tier istio ns=istio-system force=1' '${T}/out' && [ \$(grep -c 'oneshot_tier .* force=1' '${T}/out') = 1 ] && [ \$(grep -c 'oneshot_tier ' '${T}/out') = 4 ]"
check "--force-images reaches the harbor phase" grep -q 'harbor_push_images force=1' "${T}/out"
tn converge --site test --lan-time "$(date +%s)" --operator anders --only oneshot,harbor --reapply istio --reapply argo
check "--operator is an alias of --lan-user" bash -c "[ ${RC} = 0 ] && grep -q 'operator anders' '${T}/out'"
check "a repeated --reapply marks both tiers" \
  bash -c "grep -q 'oneshot_tier istio ns=istio-system force=1' '${T}/out' && grep -q 'oneshot_tier argo ns=teknoir-system force=1' '${T}/out' && [ \$(grep -c 'oneshot_tier .* force=1' '${T}/out') = 2 ]"
check "without --force-images the harbor phase gets force=0" grep -q 'harbor_push_images force=0' "${T}/out"
tn converge --site test --only oneshot --reapply nosuchtier
check "--reapply of a tier not in oneshot/TIERS is a usage error before any phase" \
  bash -c "[ ${RC} = 2 ] && grep -q 'not a one-shot tier of this bundle' '${T}/out' && ! grep -q '== oneshot' '${T}/out'"
tn converge --site test --skip oneshot --reapply istio
check "--reapply with the oneshot phase skipped is a usage error" [ "${RC}" == 2 ]
tn converge --site test --only release --force-images
check "--force-images with the harbor phase skipped is a usage error" [ "${RC}" == 2 ]
rm -rf "${PAYLOAD}/oneshot"
reseal
tn converge --site test --only oneshot --reapply istio
check "--reapply on a payload without oneshot/TIERS is a usage error" [ "${RC}" == 2 ]

# ---------------------------------------------------------------------------
echo "# preflight: an unmigrated cluster (live Teknoir K3s auto-deploy files) is refused"
M="${ROOT}/opt/k3s/server/manifests"
mkdir -p "${M}"
for f in coredns.yaml local-storage.yaml teknoir-argo.yaml teknoir-app-of-apps.yaml \
         manifest-harbor-secret.yaml teknoir-keycloak-db-secret.yaml 00-teknoir-namespaces.yaml; do
  echo '---' > "${M}/${f}"
done
touch "${M}/00-teknoir-namespaces.yaml.skip"
before="$(ncalls)"
tn converge --site test --only preflight,backup,host
check "converge stops in preflight and asks for migrate" \
  bash -c "[ ${RC} = 1 ] && grep -q 'Run teknoir-airgap migrate first' '${T}/out' && ! grep -q '== backup' '${T}/out'"
check "it names the live Teknoir files" \
  bash -c "for n in teknoir-app-of-apps manifest-harbor-secret teknoir-keycloak-db-secret; do grep 'migrate first' '${T}/out' | grep -q \"\${n}.yaml\" || exit 1; done"
check "K3s's own files, teknoir-argo.yaml (M7) and files with a .skip are not counted" \
  bash -c "grep 'migrate first' '${T}/out' | grep -q '3 Teknoir file' && ! grep 'migrate first' '${T}/out' | grep -qE 'coredns|local-storage|teknoir-argo|00-teknoir-namespaces'"
check "nothing was changed" bash -c "! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -Eq '^systemctl (stop|start|restart)|^install\.sh|images import|^kubectl .*( apply | create | patch )'"
tn converge --site test --only preflight --dry-run
check "dry-run reports the files and goes on" \
  bash -c "[ ${RC} = 0 ] && grep -q 'converge refuses this until they are detached' '${T}/out'"
for f in teknoir-app-of-apps manifest-harbor-secret teknoir-keycloak-db-secret; do touch "${M}/${f}.yaml.skip"; done
tn converge --site test --only preflight
check "once every Teknoir file has its .skip, preflight passes" [ "${RC}" == 0 ]

# ---------------------------------------------------------------------------
echo "# leak check"
lc() {
  bash -c "
    export NODE_ROOT='${PAYLOAD}'; source '${PAYLOAD}/lib/common.sh'
    mark_sensitive 'S3cr3t-Value-0123'
    printf '%s\n' \"\$1\" > '${T}/leak.log'
    leak_check '${T}/leak.log' 2>/dev/null && echo clean || echo leak" _ "$1"
}
check "a log with a remembered secret value fails the leak check" [ "$(lc 'oops S3cr3t-Value-0123 here')" == leak ]
check "a log with a private key fails the leak check" [ "$(lc '-----BEGIN PRIVATE KEY-----')" == leak ]
check "a clean log passes" [ "$(lc 'nothing to see')" == clean ]
logs_mode="$(find "${ROOT}/var/log/teknoir-airgap" -type f -printf '%m\n' | sort -u | tr '\n' ' ')"
check "every run log is 0600" [ "${logs_mode}" == "600 " ]

echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
