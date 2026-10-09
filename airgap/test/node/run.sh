#!/usr/bin/env bash
# run.sh: unit tests for the node runner (airgap/node), with stub kubectl,
# k3s, systemctl, ip, install.sh, apt-get, dpkg-query, chronyc, hwclock,
# timedatectl and date-set (DATE_BIN), in a sandbox (TEKNOIR_HOST_ROOT): no
# root, no cluster, nothing outside a temp dir is touched, and the test
# host's clock and packages are never changed (the stubs shadow the real
# tools; CHRONYC, HWCLOCK and DATE_BIN point at stubs or at absent paths).
#
# Covers: template rendering (coredns-custom golden: the live hosts block
# plus the wildcard template for teamspace names), payload
# verify (tamper, unlisted file), error-vs-absent in in_cluster, lock
# contention (exit 75), dry-run on a fresh node makes no mutating call, the
# host phase (fresh install, idempotent re-run, restart only on a desired
# config change, restart after an interrupted run, secrets-encryption only on
# new installs, managed /etc/hosts block), node CA trust, the release guard
# (downgrade, --rollback, broken list), credentials refusing a terminal, the
# runner interface (teknoir-airgap up's exact converge argv, --operator, the
# break-glass flags reaching the oneshot and harbor phases as ONESHOT_REAPPLY
# and HARBOR_FORCE_IMAGES, --reapply checked against oneshot/TIERS), the
# preflight refusal of an unmigrated cluster (live Teknoir K3s files), r5 time
# (offline install of node/debs behind apt's simulate guard; chrony drop-in
# goldens and restart only on change; one LAN-time sample per up while chrony
# has only its local/manual reference, none with a selected source; RTC writes
# above 2 s; the preflight matrix 0/20/400 s x --sync-clock x chrony; status's
# time line), the site keys TIME_SOURCE, NODE_IP_DHCP_RESERVED and
# BACKUP_AGE_RECIPIENTS (load_site and the build's site_check), and the leak
# check. With lib/oneshot.sh and lib/harbor.sh present the real phases
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
  # The clock tools: chrony and hwclock are absent unless a test points
  # T_CHRONYC / T_HWCLOCK at the stubs; setting the clock always hits the stub.
  env PATH="${HERE}/stubs:${PATH}" \
    CHRONYC="${T_CHRONYC:-${T}/absent/chronyc}" HWCLOCK="${T_HWCLOCK:-${T}/absent/hwclock}" \
    DATE_BIN="${HERE}/stubs/date-set" \
    TEKNOIR_HOST_ROOT="${ROOT}" STUB_STATE="${STUB_STATE}" STUB_CALLS="${STUB_CALLS}" \
    KUBECTL="kubectl" TEKNOIR_MIN_FREE_GB=0 WAIT_INTERVAL=1 K3S_IMPORT_WAIT=0 K3S_READY_TIMEOUT=5 \
    K3S_SETTLE_DELAY=0 K3S_SETTLE_INTERVAL=0 K3S_SETTLE_TIMEOUT=5 \
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
# r5 (TS-C5): the hosts block of the live teknoir-local ConfigMap, after a
# template that answers NODE_IP for the apex and every <name>.<domain>
# (teamspace hostnames such as mqtt-teknoir-default) and NODATA for AAAA.
# Checked against CoreDNS 1.12.3 by airgap/test/node/coredns-test.sh.
want='teknoir.airgapped:53 {
    errors
    # CoreDNS runs template before hosts: the apex and every <name>.<domain>
    # (the platform and every teamspace hostname) answer NODE_IP for A and
    # NODATA for AAAA; deeper names and other types get the hosts answers.
    template IN A teknoir.airgapped {
        match ^([a-z0-9-]+[.])?teknoir[.]airgapped[.]$
        answer "{{ .Name }} 60 IN A 192.168.5.181"
        fallthrough
    }
    template IN AAAA teknoir.airgapped {
        match ^([a-z0-9-]+[.])?teknoir[.]airgapped[.]$
        rcode NOERROR
        fallthrough
    }
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
check "coredns-custom renders the wildcard template and the live hosts block (golden)" [ "${rendered}" == "${want}" ]
check "the A template answers NODE_IP" grep -qF 'answer "{{ .Name }} 60 IN A 192.168.5.181"' "${T}/coredns.yaml"
check "the hosts block keeps the live entries" \
  bash -c "awk '/hosts \\{/{f=1; next} f && /\\}/{f=0} f' '${T}/coredns.yaml' | grep -c '192.168.5.181 ' | grep -qx 6"
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
# k3s on sqlite still creates server/db/etcd/name (VM and live node): only
# server/db/etcd/member means embedded etcd
mkdir -p "${ROOT}/opt/k3s/server/db/etcd" "${ROOT}/opt/k3s/server/tls" "${ROOT}/opt/k3s/server/cred"
echo "sqlite" > "${ROOT}/opt/k3s/server/db/state.db"
echo "name" > "${ROOT}/opt/k3s/server/db/etcd/name"
echo "token" > "${ROOT}/opt/k3s/server/token"
before="$(ncalls)"
tn backup --site test
B="$(find "${ROOT}/var/lib/teknoir-airgap/backups" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | tail -1)"
check "backup takes the datastore, token and k3s config" \
  bash -c "[ ${RC} = 0 ] && [ -f '${B}/k3s/db/state.db' ] && [ -f '${B}/k3s/server/token' ] && [ -f '${B}/k3s/etc/config.yaml' ]"
check "k3s is stopped for the copy and started again" \
  bash -c "tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -E '^systemctl (stop|start) k3s' | tr '\n' ' ' | grep -q 'systemctl stop k3s systemctl start k3s'"
check "backup prints its path on stdout" grep -qx "${B}" "${T}/out"
check "no etcd snapshot on a sqlite node (server/db/etcd holds only its name file)" \
  bash -c "! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q 'etcd-snapshot'"
cp "${STUB_STATE}/pods.json" "${T}/pods.json.keep"
cat > "${STUB_STATE}/pods.json" <<'EOF'
{"items": [
  {"metadata": {"namespace": "teknoir-system", "name": "harbor-core-1"}, "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "False"}]}},
  {"metadata": {"namespace": "teknoir-demo", "name": "user-app"}, "status": {"phase": "Pending"}}
]}
EOF
sleep 1   # backups are named by the second
tn backup --site test
check "after the k3s restart the backup waits for the platform pods and only warns about one that stays unready" \
  bash -c "[ ${RC} = 0 ] && grep -q 'still not Ready.*teknoir-system/harbor-core-1' '${T}/out' && ! grep -q 'teknoir-demo/user-app' '${T}/out'"
cp "${T}/pods.json.keep" "${STUB_STATE}/pods.json"
chmod 000 "${ROOT}/opt/k3s/server/db/state.db"
tn backup --site test
chmod 644 "${ROOT}/opt/k3s/server/db/state.db"
check "a failed datastore copy fails the backup" [ "${RC}" != 0 ]
check "k3s is running again after the failed backup" [ -f "${STUB_STATE}/k3s.active" ]
check "no partial backup is left behind" [ -z "$(find "${ROOT}/var/lib/teknoir-airgap/backups" -name '*.partial')" ]

# ---------------------------------------------------------------------------
echo "# backup: age-encrypted exports to the site's BACKUP_AGE_RECIPIENTS (SEC-C8)"
# Stub age (stubs/age) records its arguments and prefixes one header line. The
# recipients only need the age1 + 58 [0-9a-z] shape; they are no real keys.
R1="age1$(printf 'q%.0s' {1..58})"
R2="age1$(printf 'p%.0s' {1..58})"
BK="${ROOT}/var/lib/teknoir-airgap/backups"
EX="${ROOT}/var/lib/teknoir-airgap/exports"
site_with() {
  # site_with <file> <BACKUP_AGE_RECIPIENTS value>: the test site plus that key
  { cat "${PAYLOAD}/site/test.env"; printf 'BACKUP_AGE_RECIPIENTS="%s"\n' "$2"; } > "$1"
}
site_with "${T}/age.env" "${R1} ${R2}"
nplain() { find "${BK}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | wc -l; }
nexp() { find "${EX}" -mindepth 1 -maxdepth 1 -type f -name '2*Z.tar.age' 2>/dev/null | wc -l; }
newest() { find "${BK}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | tail -1; }
tne() {
  # tne VAR=VALUE... <teknoir-node args>: tn with extra environment
  local -a vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  RC=0
  node_env "${vars[@]}" "${PAYLOAD}/bin/teknoir-node" "$@" > "${T}/out" 2>&1 || RC=$?
  (( VERBOSE )) && sed 's/^/    | /' "${T}/out"
  return 0
}
plain_before="$(nplain)"
sleep 1
before="$(ncalls)"
tn backup --site "${T}/age.env"
B="$(newest)"; TS="$(basename "${B}")"
check "a backup with recipients succeeds and still prints its directory on stdout" bash -c "[ ${RC} = 0 ] && grep -qx '${B}' '${T}/out'"
check "it writes exports/<ts>.tar.age with mode 0600 (age itself created it 0644)" [ "$(stat -c %a "${EX}/${TS}.tar.age" 2>/dev/null)" == 600 ]
check "the exports directory is 0700" [ "$(stat -c %a "${EX}")" == 700 ]
check "age gets every recipient and writes a .partial file first" \
  bash -c "tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -qx 'age -r ${R1} -r ${R2} -o ${EX}/${TS}.tar.age.partial'"
check "the export holds the backup directory with BACKUP.info and SHA256SUMS" \
  bash -c "tail -n +2 '${EX}/${TS}.tar.age' | tar -tf - > '${T}/list' && grep -qx '${TS}/SHA256SUMS' '${T}/list' && grep -qx '${TS}/BACKUP.info' '${T}/list'"
check "only the newest unencrypted set stays (BACKUP_KEEP_PLAIN=1)" [ "$(nplain)" == 1 ]
check "the older unencrypted sets were encrypted before they were pruned" [ "$(nexp)" == "$(( plain_before + 1 ))" ]
check "no .partial file is left" [ -z "$(find "${BK}" "${EX}" -name '*.partial')" ]
check "no warning about missing recipients" bash -c "! grep -q 'BACKUP_AGE_RECIPIENTS is not set' '${T}/out'"
for _ in 1 2; do sleep 1; tn backup --site "${T}/age.env"; done
check "encrypted exports rotate at BACKUP_KEEP (3), unencrypted at 1" bash -c "[ ${RC} = 0 ] && [ $(nexp) = 3 ] && [ $(nplain) = 1 ]"
sleep 1
tne BACKUP_KEEP=2 BACKUP_KEEP_PLAIN=2 backup --site "${T}/age.env"
check "BACKUP_KEEP and BACKUP_KEEP_PLAIN override the counts" bash -c "[ ${RC} = 0 ] && [ $(nexp) = 2 ] && [ $(nplain) = 2 ]"
tne BACKUP_KEEP_PLAIN=0 backup --site "${T}/age.env"
check "BACKUP_KEEP_PLAIN=0 is refused (the newest set always stays)" bash -c "[ ${RC} != 0 ] && grep -q 'BACKUP_KEEP_PLAIN must be a whole number' '${T}/out'"

echo "# backup: an age failure leaves no partial file and prunes nothing"
exp_before="$(find "${EX}" -type f | sort)"
plain_before="$(nplain)"
sleep 1
tne STUB_AGE_FAIL=1 backup --site "${T}/age.env"
check "the backup fails when age fails" bash -c "[ ${RC} != 0 ] && grep -q 'encrypting .* with age failed' '${T}/out'"
check "no .partial export is left" [ -z "$(find "${EX}" -name '*.partial')" ]
check "the exports are unchanged" [ "$(find "${EX}" -type f | sort)" == "${exp_before}" ]
check "the complete unencrypted set stays and nothing was pruned" [ "$(nplain)" == "$(( plain_before + 1 ))" ]
check "k3s is running after the failed encryption" [ -f "${STUB_STATE}/k3s.active" ]
FAILED_TS="$(basename "$(newest)")"
sleep 1
tn backup --site "${T}/age.env"
check "the next backup encrypts the set left unencrypted, then prunes it" \
  bash -c "[ ${RC} = 0 ] && [ -f '${EX}/${FAILED_TS}.tar.age' ] && [ ! -d '${BK}/${FAILED_TS}' ] && [ $(nplain) = 1 ]"

echo "# backup: invalid recipients are refused before k3s is stopped"
site_with "${T}/bad.env" "${R1} age1tooshort"
before="$(ncalls)"; plain_before="$(nplain)"
tn backup --site "${T}/bad.env"
check "an entry that is not an age public key is refused" bash -c "[ ${RC} != 0 ] && grep -q \"'age1tooshort...' is not an age X25519 public key\" '${T}/out'"
check "nothing was stopped and no backup was taken" \
  bash -c "! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q '^systemctl stop k3s' && [ $(nplain) = ${plain_before} ]"
# assembled at run time: no private-key-shaped literal in the repository
FAKE_PRIV="AGE-SECRET-KEY-""1$(printf 'Q%.0s' {1..58})"
site_with "${T}/priv.env" "${FAKE_PRIV}"
tn backup --site "${T}/priv.env"
check "a private key in BACKUP_AGE_RECIPIENTS is refused and called out" bash -c "[ ${RC} != 0 ] && grep -q 'age PRIVATE key' '${T}/out'"
check "the private key is never echoed" bash -c "! grep -qF '${FAKE_PRIV}' '${T}/out' && ! grep -rqF '${FAKE_PRIV}' '${ROOT}/var/log/teknoir-airgap'"

echo "# backup --recipient-site / --name / --recipient / --list"
TS="$(basename "$(newest)")"
before="$(ncalls)"
tn backup --site "${T}/age.env" --recipient-site --name "${TS}"
check "--recipient-site --name re-encrypts that set to the site's recipients and prints the export path" \
  bash -c "[ ${RC} = 0 ] && [ \"\$(grep -v ' \[teknoir-node\] ' '${T}/out')\" = '${EX}/${TS}.tar.age' ] && tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -qx 'age -r ${R1} -r ${R2} -o ${EX}/${TS}.tar.age.partial'"
before="$(ncalls)"
sleep 1
tn backup --site "${T}/age.env" --recipient-site --take
NEW="$(basename "$(newest)")"
check "--recipient-site --take takes a backup and prints its export, encrypted once" \
  bash -c "[ ${RC} = 0 ] && [ '${NEW}' != '${TS}' ] && [ \"\$(grep -v ' \[teknoir-node\] ' '${T}/out')\" = '${EX}/${NEW}.tar.age' ] && [ \$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -c '^age .*${NEW}.tar.age.partial') = 1 ]"
OLD="$(find "${EX}" -name '2*Z.tar.age' | sort | head -1)"; OLD="$(basename "${OLD}" .tar.age)"
before="$(ncalls)"
tn backup --site "${T}/age.env" --recipient-site --name "${OLD}"
check "--recipient-site --name of a set kept only encrypted hands out that export as it is" \
  bash -c "[ ! -d '${BK}/${OLD}' ] && [ ${RC} = 0 ] && [ \"\$(grep -v ' \[teknoir-node\] ' '${T}/out')\" = '${EX}/${OLD}.tar.age' ] && ! tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -q '^age '"
tn backup --site test --recipient-site
check "--recipient-site without BACKUP_AGE_RECIPIENTS fails" bash -c "[ ${RC} != 0 ] && grep -q 'BACKUP_AGE_RECIPIENTS is not set' '${T}/out'"
before="$(ncalls)"
node_env "${PAYLOAD}/bin/teknoir-node" backup --site test --recipient "${R1}" --recipient "${R2}" --name "${NEW}" > "${T}/stream" 2> "${T}/out" || true
check "--recipient (repeatable) streams the named set encrypted to stdout" \
  bash -c "head -1 '${T}/stream' | grep -q '^age-encryption.org/v1' && tail -n +2 '${T}/stream' | tar -tf - | grep -qx '${NEW}/SHA256SUMS' && tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -qx 'age -r ${R1} -r ${R2}'"
tn backup --site "${T}/age.env" --recipient-site --name 2026-10-09
check "--name must be a backup timestamp" bash -c "[ ${RC} != 0 ] && grep -q 'a backup name is a UTC timestamp' '${T}/out'"
tn backup --site "${T}/age.env" --recipient-site --name 20000101T000000Z
check "--name of a missing backup fails" bash -c "[ ${RC} != 0 ] && grep -q 'no backup 20000101T000000Z' '${T}/out'"
tn backup --site "${T}/age.env" --recipient-site --take --name "${NEW}"
check "--take and --name exclude each other" [ "${RC}" != 0 ]
tn backup --site "${T}/age.env" --list
check "--list shows the unencrypted set and the encrypted exports" \
  bash -c "[ ${RC} = 0 ] && grep -q '^${NEW} ' '${T}/out' && grep -q '^${NEW}.tar.age .*encrypted export' '${T}/out'"
check "every export is 0600" [ "$(find "${EX}" -type f ! -perm 600 | wc -l)" == 0 ]

echo "# backup: the real age (when installed) encrypts to every recipient"
REAL_AGE="$(command -v age || true)"
if [[ -n "${REAL_AGE}" && "${REAL_AGE}" != "${HERE}/stubs/age" && -x "$(dirname "${REAL_AGE}")/age-keygen" ]]; then
  for k in a b; do "$(dirname "${REAL_AGE}")/age-keygen" -o "${T}/id-${k}.key" 2>/dev/null; done
  site_with "${T}/real.env" "$("$(dirname "${REAL_AGE}")/age-keygen" -y "${T}/id-a.key") $("$(dirname "${REAL_AGE}")/age-keygen" -y "${T}/id-b.key")"
  sleep 1
  tne AGE="${REAL_AGE}" backup --site "${T}/real.env"
  TS="$(basename "$(newest)")"
  check "real age: the backup succeeds" [ "${RC}" == 0 ]
  check "real age: the export carries no plaintext" bash -c "! grep -qa 'createdAt=' '${EX}/${TS}.tar.age'"
  for k in a b; do
    rm -rf "${T}/dec"; mkdir -p "${T}/dec"
    check "real age: identity ${k} decrypts it and SHA256SUMS verifies" \
      bash -c "'${REAL_AGE}' -d -i '${T}/id-${k}.key' '${EX}/${TS}.tar.age' | tar -C '${T}/dec' -xf - && cd '${T}/dec/${TS}' && sha256sum --quiet -c SHA256SUMS"
  done
else
  echo "skip real age (no age and age-keygen on PATH)"
fi

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
# r5 time and host packages (TIME-T2, TIME-T3) and the site keys (R9)
# ---------------------------------------------------------------------------
DEB_CHRONY=chrony_4.6.1-3+deb13u2_amd64.deb
DEB_ULE=util-linux-extra_2.41.5-0+deb13u1_amd64.deb
add_debs() {
  # node/debs as the bundle build stages it: two .debs (stand-ins) and
  # debs.lock lines "<pkg> <version> <arch> <sha256> <file>"
  local f b
  mkdir -p "${PAYLOAD}/debs"
  : > "${PAYLOAD}/debs/debs.lock"
  for f in "${DEB_CHRONY}" "${DEB_ULE}"; do
    head -c 2048 /dev/urandom > "${PAYLOAD}/debs/${f}"
    b="${f%.deb}"
    printf '%s %s amd64 %s %s\n' "${b%%_*}" "$(cut -d_ -f2 <<<"${b}")" \
      "$(sha256sum "${PAYLOAD}/debs/${f}" | cut -d' ' -f1)" "${f}" >> "${PAYLOAD}/debs/debs.lock"
  done
  reseal
}
since() { calls_since "$1" | grep -E "${2}" || true; }
clock_calls() { since "$1" '^(date -|chronyc (settime|makestep)|hwclock )'; }

echo "# host packages (TIME-T2): offline install of node/debs"
new_sandbox 4
add_debs
before="$(ncalls)"
tn converge --site test --only host
installs="$(since "${before}" '^apt-get install' | grep -v ' -s ' || true)"
check "(a) fresh node: converge succeeds" [ "${RC}" == 0 ]
check "(a) exactly one apt-get install, after the simulate" \
  bash -c "[ \$(grep -c . <<<'${installs}') = 1 ] && tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^apt-get install' | head -1 | grep -q ' -s '"
check "(a) the install is offline, with both absolute .deb paths" \
  bash -c "grep -q -- '--no-download' <<<'${installs}' && grep -qF '${PAYLOAD}/debs/${DEB_CHRONY}' <<<'${installs}' && grep -qF '${PAYLOAD}/debs/${DEB_ULE}' <<<'${installs}' && grep -q 'DPkg::Lock::Timeout=300' <<<'${installs}'"
check "(a) the change is recorded, with the timesyncd removal" \
  grep -qF 'changed: installed chrony 4.6.1-3+deb13u2, util-linux-extra 2.41.5-0+deb13u1 from the bundle (removed systemd-timesyncd)' "${T}/out"
before="$(ncalls)"
tn converge --site test --only host
check "(b) re-run with both versions installed: no apt-get call" \
  bash -c "[ ${RC} = 0 ] && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^apt-get' || true)\" ]"
check "(b) and it says so" grep -q 'host packages: the bundle.s node packages are installed (chrony 4.6.1-3+deb13u2, util-linux-extra 2.41.5-0+deb13u1)' "${T}/out"
echo 4.6.1-3+deb13u3 > "${STUB_STATE}/dpkg/chrony"
rm -f "${STUB_STATE}/dpkg/util-linux-extra"
before="$(ncalls)"
tn converge --site test --only host
installs="$(since "${before}" '^apt-get install' | grep -v ' -s ' || true)"
check "a newer installed chrony is kept (no downgrade); only util-linux-extra is installed" \
  bash -c "[ ${RC} = 0 ] && grep -q 'chrony 4.6.1-3+deb13u3 is newer than the bundle.s 4.6.1-3+deb13u2: kept' '${T}/out' && grep -qF '${DEB_ULE}' <<<'${installs}' && ! grep -qF '${DEB_CHRONY}' <<<'${installs}' && [ \"\$(cat '${STUB_STATE}/dpkg/chrony')\" = 4.6.1-3+deb13u3 ]"
rm -rf "${STUB_STATE}/dpkg"
printf 'Remv systemd-timesyncd [257.13-1~deb13u1]\nInst libsmartcols1 [2.41.4-1] (2.41.5-0+deb13u1 Debian:13.1/stable [amd64])\nInst chrony (4.6.1-3+deb13u2 local-deb [amd64])\nInst util-linux-extra (2.41.5-0+deb13u1 local-deb [amd64])\n' > "${STUB_STATE}/apt-sim.txt"
before="$(ncalls)"
tn converge --site test --only host
check "(c) a plan that also upgrades libsmartcols1: WARN, no install, converge rc 0" \
  bash -c "[ ${RC} = 0 ] && grep -q 'WARN: host packages: .*also changes other packages (Inst libsmartcols1)' '${T}/out' && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^apt-get install' | grep -v ' -s ' || true)\" ]"
rm -f "${STUB_STATE}/apt-sim.txt"
export STUB_APT_SIM_RC=100
before="$(ncalls)"
tn converge --site test --only host
unset STUB_APT_SIM_RC
check "(d) a failing simulate (exit 100): WARN, no install, converge rc 0" \
  bash -c "[ ${RC} = 0 ] && grep -q 'WARN: host packages: apt cannot install .* offline (simulate exit 100' '${T}/out' && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^apt-get install' | grep -v ' -s ' || true)\" ]"
before="$(ncalls)"
tn converge --site test --only host --dry-run
check "(e) dry-run: the simulate is the only apt-get call" \
  bash -c "[ ${RC} = 0 ] && [ \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -c '^apt-get')\" = 1 ] && tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^apt-get' | grep -q '^apt-get install -s --no-download'"
check "(e) dry-run reports the install it would do" grep -q 'would change: install chrony 4.6.1-3+deb13u2, util-linux-extra 2.41.5-0+deb13u1 from the bundle (removes systemd-timesyncd)' "${T}/out"
check "(e) dry-run installs nothing" [ ! -d "${STUB_STATE}/dpkg" ]
printf 'chrony %s amd64 %064d %s\n' 4.6.1-3+deb13u2 0 "${DEB_CHRONY}" > "${PAYLOAD}/debs/debs.lock"
reseal
before="$(ncalls)"
tn converge --site test --only host
check "a .deb that does not match its debs.lock pin is not installed (WARN, rc 0)" \
  bash -c "[ ${RC} = 0 ] && grep -q 'does not match its pin in debs.lock' '${T}/out' && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^apt-get' || true)\" ]"

echo "# chrony drop-in and the clock sample (TIME-T3)"
new_sandbox 5
T_CHRONYC="${HERE}/stubs/chronyc" T_HWCLOCK="${HERE}/stubs/hwclock"
mkdir -p "${ROOT}/etc/chrony" "${ROOT}/sys/class/rtc/rtc0"
printf 'pool 2.debian.pool.ntp.org iburst\nconfdir /etc/chrony/conf.d\nrtcsync\nmakestep 1 3\n' > "${ROOT}/etc/chrony/chrony.conf"
date +%s > "${ROOT}/sys/class/rtc/rtc0/since_epoch"
touch "${STUB_STATE}/chrony.active"
DROPIN="${ROOT}/etc/chrony/conf.d/teknoir-airgap.conf"
golden_head='# Managed by teknoir-node (host phase); every up rewrites it.
# Serves NTP to the LAN (Robots, cameras: server NODE_IP). Without an
# answering server below, the reference is the local clock (stratum 10),
# which up corrects with the LAN host time (chronyc settime, needs manual).'
golden_tail='allow 10.77.0.0/24
local stratum 10
manual'
before="$(ncalls)"
lt="$(date +%s)"
tn converge --site test --only host --lan-time "${lt}"
check "converge with chrony active succeeds" [ "${RC}" == 0 ]
check "drop-in golden, TIME_SOURCE empty" [ "$(cat "${DROPIN}")" == "${golden_head}"$'\n'"${golden_tail}" ]
check "a new drop-in restarts chrony once" [ "$(since "${before}" '^systemctl restart chrony' | grep -c .)" == 1 ]
st="$(since "${before}" '^chronyc settime')"
want_any=""
for d in 0 1 2; do want_any+="chronyc settime $(LC_ALL=C date -u -d "@$(( lt + d ))" '+%b %d, %Y %H:%M:%S') (TZ=UTC)"$'\n'; done
check "reference LOCAL: exactly one settime, with the LAN time in UTC" \
  bash -c "[ \"\$(grep -c . <<<'${st}')\" = 1 ] && grep -qxF '${st}' <<<'${want_any}'"
check "a skew within 2 s needs no makestep" [ -z "$(since "${before}" '^chronyc makestep')" ]
check "no RTC write when the RTC is right" [ -z "$(since "${before}" '^hwclock')" ]
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "an unchanged drop-in does not restart chrony" [ -z "$(since "${before}" '^systemctl restart chrony')" ]
check "every up gives chrony one sample" [ "$(since "${before}" '^chronyc settime' | grep -c .)" == 1 ]
check "a routine sample is not a change (0 changes)" grep -q 'summary: 0 changes' "${T}/out"
printf 'TEKNOIR_ENV=teknoir-local\nTEKNOIR_DOMAIN=teknoir.airgapped\nNODE_IP=10.77.0.10\nNODE=teknoir@10.77.0.10\nTEKNOIR_HOSTNAMES="harbor"\nTIME_SOURCE="a.example 10.0.0.5"\nK3S_DATA_DIR=/opt/k3s\n' > "${T}/ts.env"
before="$(ncalls)"
tn converge --site "${T}/ts.env" --only host --lan-time "$(date +%s)"
check "drop-in golden, TIME_SOURCE 'a.example 10.0.0.5': one server line each" \
  [ "$(cat "${DROPIN}")" == "${golden_head}"$'\n''server a.example iburst prefer'$'\n''server 10.0.0.5 iburst prefer'$'\n'"${golden_tail}" ]
check "the changed drop-in restarts chrony once" [ "$(since "${before}" '^systemctl restart chrony' | grep -c .)" == 1 ]
echo C0A80201 > "${STUB_STATE}/chrony.ref"
echo 10.0.0.5 > "${STUB_STATE}/chrony.refname"
echo '^* 10.0.0.5                    2   6   377    35   +123us[ +456us] +/-   20ms' > "${STUB_STATE}/chrony.sources"
before="$(ncalls)"
tn converge --site "${T}/ts.env" --only host --lan-time "$(( $(date +%s) - 20 ))"
check "a selected NTP source: no settime (not even with a 20 s skew)" \
  bash -c "[ ${RC} = 0 ] && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^chronyc settime' || true)\" ] && grep -q 'chrony follows the NTP source 10.0.0.5' '${T}/out'"
rm -f "${STUB_STATE}/chrony.ref" "${STUB_STATE}/chrony.refname" "${STUB_STATE}/chrony.sources"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(( $(date +%s) - 20 ))"
check "reference LOCAL and a 20 s skew: settime, then makestep applies it at once" \
  bash -c "[ ${RC} = 0 ] && tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -E '^chronyc (settime|makestep)' | cut -d' ' -f2 | tr '\n' ' ' | grep -qx 'settime makestep ' && grep -q 'changed: node clock corrected through chrony (was 2[01]s off the LAN host)' '${T}/out'"
echo 4D414E55 > "${STUB_STATE}/chrony.ref"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "reference MANU (an earlier sample): another sample" [ "$(since "${before}" '^chronyc settime' | grep -c .)" == 1 ]
echo 00000000 > "${STUB_STATE}/chrony.ref"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "no reference yet (00000000): a sample" [ "$(since "${before}" '^chronyc settime' | grep -c .)" == 1 ]
rm -f "${STUB_STATE}/chrony.ref"
before="$(ncalls)"
tn converge --site test --only host
check "without --lan-time: no sample" [ -z "$(since "${before}" '^chronyc settime')" ]

echo "# RTC (TIME-T3)"
echo "$(( $(date +%s) - 93 ))" > "${ROOT}/sys/class/rtc/rtc0/since_epoch"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "RTC 93 s behind: hwclock --systohc --utc" [ "$(since "${before}" '^hwclock' | tr -d '\n')" == "hwclock --systohc --utc" ]
check "the RTC write is recorded" grep -q 'changed: RTC set from the system clock (was -9[234]s off)' "${T}/out"
check "the RTC is right afterwards" [ $(( $(date +%s) - $(cat "${ROOT}/sys/class/rtc/rtc0/since_epoch") )) -le 2 ]
echo "$(( $(date +%s) - 1 ))" > "${ROOT}/sys/class/rtc/rtc0/since_epoch"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "RTC 1 s off: not written" [ -z "$(since "${before}" '^hwclock')" ]
echo "$(( $(date +%s) - 93 ))" > "${ROOT}/sys/class/rtc/rtc0/since_epoch"
before="$(ncalls)"
T_HWCLOCK="" tn converge --site test --only host --lan-time "$(date +%s)"
check "RTC 93 s behind without hwclock: a WARN, no write, rc 0" \
  bash -c "[ ${RC} = 0 ] && grep -q 'WARN: hwclock is not installed' '${T}/out' && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^hwclock' || true)\" ]"
printf '0.0 0 0.0\n0\nLOCAL\n' > "${ROOT}/etc/adjtime"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "an RTC in local time (/etc/adjtime LOCAL) is not written" \
  bash -c "grep -q 'the RTC keeps local time' '${T}/out' && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep '^hwclock' || true)\" ]"
rm -f "${ROOT}/etc/adjtime"
date +%s > "${ROOT}/sys/class/rtc/rtc0/since_epoch"
rm -f "${STUB_STATE}/chrony.active"
before="$(ncalls)"
tn converge --site test --only host --lan-time "$(date +%s)"
check "chrony installed but not active: enabled and started" \
  bash -c "tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -qx 'systemctl enable --now chrony' && grep -q 'changed: enabled and started chrony' '${T}/out'"
rm -f "${STUB_STATE}/chrony.active"
touch "${STUB_STATE}/chrony.broken"
tn converge --site test --only host --lan-time "$(date +%s)"
check "a chrony that does not start is a WARN; the converge goes on" \
  bash -c "[ ${RC} = 0 ] && grep -q 'WARN: chrony is installed but does not start' '${T}/out'"
rm -f "${STUB_STATE}/chrony.broken"
touch "${STUB_STATE}/chrony.active"
before="$(ncalls)"
tn status --site test
check "status prints the time line" \
  bash -c "grep -Eq '^time: +[0-9T:-]+Z source=LOCAL stratum 10 freq 45.123 ppm slow NTPSynchronized=no; RTC [+-][0-9]+ s; chrony active$' '${T}/out'"

echo "# preflight clock policy (TIME-T3): skew 0/20/400 s x --sync-clock x chrony"
# rc and clock calls per case; the LAN host is behind for 20 s (node ahead),
# ahead for 400 s (node behind, like the live drift)
pf() {
  # pf <skew> <flag:0|1> <chrony:active|absent> - run preflight; prints "rc calls"
  local skew="$1" flag="$2" ch="$3" b lan
  local -a extra=()
  (( flag )) && extra=(--sync-clock)
  rm -f "${STUB_STATE}/chrony.active"
  [[ "${ch}" == active ]] && touch "${STUB_STATE}/chrony.active"
  lan=$(( $(date +%s) - skew ))
  b="$(ncalls)"
  if [[ "${ch}" == active ]]; then
    T_CHRONYC="${HERE}/stubs/chronyc" tn converge --site test --only preflight --lan-time "${lan}" ${extra[@]+"${extra[@]}"}
  else
    T_CHRONYC="" tn converge --site test --only preflight --lan-time "${lan}" ${extra[@]+"${extra[@]}"}
  fi
  printf '%s %s' "${RC}" "$(clock_calls "${b}" | sed -E 's/(settime|-s) .*/\1/' | tr '\n' ',')"
}
for flag in 0 1; do
  for ch in absent active; do
    check "skew 0, sync-clock=${flag}, chrony ${ch}: nothing" [ "$(pf 0 "${flag}" "${ch}")" == "0 " ]
  done
  check "skew 20, sync-clock=${flag}, no chrony: stepped now with date" [ "$(pf 20 "${flag}" absent)" == "0 date -u -s," ]
  check "skew 20, sync-clock=${flag}, chrony active: left to the host-phase sample" [ "$(pf 20 "${flag}" active)" == "0 " ]
done
for ch in absent active; do
  r="$(pf -400 0 "${ch}")"
  check "skew -400 without --sync-clock, chrony ${ch}: refused (rc 1) with the hint, no clock call" \
    bash -c "[ '${r}' = '1 ' ] && grep -q 'off the LAN host (limit 30s).*--sync-clock' '${T}/out'"
done
check "skew -400 --sync-clock, no chrony: date -u -s, then hwclock --systohc --utc" [ "$(pf -400 1 absent)" == "0 date -u -s,hwclock --systohc --utc," ]
check "skew -400 --sync-clock, chrony active: settime + makestep, then hwclock" \
  [ "$(pf -400 1 active)" == "0 chronyc settime,chronyc makestep,hwclock --systohc --utc," ]
check "the --sync-clock settime runs in UTC" bash -c "tail -n 20 '${STUB_CALLS}' | grep '^chronyc settime' | tail -1 | grep -q '(TZ=UTC)$'"
T_HWCLOCK=""
r="$(pf -400 1 absent)"
check "skew -400 --sync-clock without hwclock: stepped, the RTC is left to the host phase" \
  bash -c "[ '${r}' = '0 date -u -s,' ] && grep -q 'host phase writes the RTC once' '${T}/out'"
unset T_CHRONYC T_HWCLOCK
before="$(ncalls)"
tn converge --site test --only preflight --lan-time "$(( $(date +%s) - 20 ))" --dry-run
check "dry-run: a 20 s skew is reported, the clock is not set" \
  bash -c "[ ${RC} = 0 ] && grep -q 'would change: node clock set from the LAN host with date' '${T}/out' && [ -z \"\$(tail -n +$(( before + 1 )) '${STUB_CALLS}' | grep -E '^(date|chronyc|hwclock)' || true)\" ]"

echo "# site keys (R9): TIME_SOURCE, NODE_IP_DHCP_RESERVED, BACKUP_AGE_RECIPIENTS"
# a dummy in the age public-key format (age1 + 58 bech32 characters), no real key
AGE_OK="age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce"
check "the dummy age recipient has the format's length (62)" [ "${#AGE_OK}" == 62 ]
site_variant() {
  # site_variant <file> <extra line>... - the test site plus extra KEY=value lines
  local f="$1"
  shift
  { cat "${PAYLOAD}/site/test.env"; printf '%s\n' "$@"; } > "${f}"
}
site_check_rc() {
  bash -c "source '${HERE}/../../build/lib-build.sh'; site_check '$1'" > "${T}/sc.out" 2>&1 && echo 0 || echo 1
}
site_variant "${T}/good.env" 'TIME_SOURCE="a.example 10.0.0.5"' 'NODE_IP_DHCP_RESERVED=yes' "BACKUP_AGE_RECIPIENTS=\"${AGE_OK} ${AGE_OK}\""
tn converge --site "${T}/good.env" --only verify
check "valid TIME_SOURCE, NODE_IP_DHCP_RESERVED and two age recipients: load_site accepts them" [ "${RC}" == 0 ]
check "site_check (build) accepts them" [ "$(site_check_rc "${T}/good.env")" == 0 ]
for bad in 'TIME_SOURCE="a;b"' 'TIME_SOURCE="10.0.0.300"' 'TIME_SOURCE="-x.example"' 'NODE_IP_DHCP_RESERVED=maybe' \
           'BACKUP_AGE_RECIPIENTS="age1short"' "BACKUP_AGE_RECIPIENTS=\"${AGE_OK^^}\"" "BACKUP_AGE_RECIPIENTS=\"${AGE_OK} x\""; do
  site_variant "${T}/bad.env" "${bad}"
  tn converge --site "${T}/bad.env" --only verify
  check "load_site rejects ${bad}" bash -c "[ ${RC} = 1 ] && grep -q 'ERROR: .*invalid ${bad%%=*}' '${T}/out'"
  check "site_check rejects ${bad}" bash -c "[ \"\$(bash -c \"source '${HERE}/../../build/lib-build.sh'; site_check '${T}/bad.env'\" 2>&1 >/dev/null | grep -c 'invalid ${bad%%=*}')\" -ge 1 ]"
done
check "the committed site files pass site_check" \
  bash -c "[ \"\$(bash -c \"source '${HERE}/../../build/lib-build.sh'; site_check '${HERE}/../../site/teknoir-local.env' && site_check '${HERE}/../../site/vmtest.env' && echo ok\" 2>/dev/null)\" = ok ]"

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
