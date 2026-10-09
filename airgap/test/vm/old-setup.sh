#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# old-setup.sh — E10 (migration rehearsal, docs/airgap/DESIGN.md test plan 3):
# install the OLD teknoir-local layout on the fresh test VM with DUMMY secrets,
# using the old tooling itself (infra e9a3b7f, gitops 158b3da = app-of-apps
# 0.0.3), so that e2e.sh E10 can run the new migrate, up and migrate --argo
# on it. e2e.sh runs it as E2E_OLD_SETUP, on vpro, with VM_IP exported, right
# after it re-created the VM and brought up the LAN namespace tklan.
#
# Steps, in the order of the old runbooks at e9a3b7f (docs/AIRGAP-HOST-SETUP.md,
# AIRGAP-BOOTSTRAP.md, AIRGAP-UPDATE.md):
#   connected workstation (vpro, work dir OLD_SETUP_DIR):
#    1. throwaway detached worktrees: infra at e9a3b7f, gitops at 158b3da
#    2. dummy secrets from the old scripts/gen-*.sh (their output, which
#       echoes the values, is discarded)
#    3. the old airgap/make-bundle.sh, seeded with the existing old bundle's
#       images, bootstrap tarballs, k3s and tools (hard links). Rebuilt because
#       the bundle embeds the CA (argocd-tls-certs-cm, oidc rootCA), the secret
#       manifests and the node IP (coredns-custom). The old bundle's
#       bootstrap/secrets hold the LIVE secrets: never copied, never read.
#   LAN host (netns tklan via lan-netns.sh exec, HOME=OLD_SETUP_DIR/lanhome,
#   ssh as teknoir@VM_IP with the VM key; nothing is written to ~/.ssh):
#    4. host setup: upload-bundle.sh (the node keeps ~/teknoir-airgap-bundle-0.1.0,
#       as the live node does), the inotify sysctl (HOST-SETUP 6), then the
#       bundle's airgap/install-k3s.sh on the node
#    5. bootstrap-airgap.sh --host --node-ip, push-to-harbor.sh (robot$argocd),
#       deploy-secrets.sh (ArgoCD switches to the robot credential)
#    6. the Keycloak-dependent secrets (gen-argocd-keycloak-secrets.sh,
#       gen-oauth2-proxy-secrets.sh with dummy client secrets), deploy-secrets.sh
#    7. the history of the older tooling (simulated, see below)
#    8. the update round of AIRGAP-UPDATE.md 2.3/2.4: deploy-secrets.sh --only
#       manifest-argocd-harbor-repo-secret.yaml, update-airgap.sh 0.0.3,
#       bootstrap-airgap.sh --update
#    9. a k3s restart (as the live node has had), then it waits until K3s has
#       re-applied every file and the Applications have settled, and checks
#       the layout: 23 Teknoir K3s files and 26 Addons (3 of them orphans)
#
# History (7): besides what e9a3b7f writes, the live node carries files of
# older tooling (DESIGN M3): 8 legacy manifest-*-secret files next to the 9
# teknoir-*-secret files, and the orphan Addons 10-teknoir-argo, app-of-apps
# and manifest-argocd-harbor-repo-secret, whose files are gone. e9a3b7f writes
# canonical names only, so this script drops byte-identical copies under the
# legacy names and waits until K3s applied them; step 8 then retires three of
# them with the old tooling's own k3s_retire_legacy, which leaves exactly
# those orphan Addons. OLD_SETUP_HISTORY=0 skips 7 (a plain e9a3b7f layout).
#
# TEST-ENVIRONMENT WORKAROUNDS, not part of the legacy layout:
#   - the VM has no default route and no upstream DNS (the live node has
#     both), which the old tooling does not handle (flannel cannot pick an
#     interface, k3s may not pick a node IP; CoreDNS forwards to 8.8.8.8 and
#     hangs; DESIGN "VM e2e findings"). Only when that is so, before k3s's
#     first start: node-ip, flannel-iface and resolv-conf are appended, as a
#     marked block, to the config.yaml that install-k3s.sh wrote, and
#     systemd-resolved is exposed on VM_IP as CoreDNS's upstream. Same paths
#     as the new host phase, so its `up` replaces them;
#   - while bootstrap-airgap.sh runs, istio-system pods that were created
#     before istiod's injection webhook answered (container image still
#     "auto": they never start) are deleted once istiod is up, so their
#     ReplicaSet re-creates them injected (the race the new converge handles).
#
# Usage: VM_IP=10.77.0.10 airgap/test/vm/old-setup.sh [--build-only] [--clean]
#   --build-only  only the workstation steps 1-3 (no VM, no LAN namespace)
#   --clean       remove OLD_SETUP_DIR (worktrees, dummy secrets, bundle) first
# Environment:
#   VM_IP              the test VM (required; must be NODE_IP of the vmtest site)
#   OLD_SETUP_DIR      work dir (default ~/vmtest/old-setup); holds the dummy
#                      secrets (0600) and the rebuilt bundle (~8 GB, hard links)
#   OLD_BUNDLE_SRC     the old bundle to seed from (default
#                      ~/git/ai/infra-teknoir-local/bundle/teknoir-airgap-bundle-0.1.0);
#                      without it make-bundle.sh downloads everything
#   OLD_INFRA_DEPS     infra checkout with charts/argo's vendored dependencies
#                      (default ~/git/ai/infra-teknoir-local)
#   OLD_GITOPS_REPO    gitops repository for the 158b3da worktree
#                      (default ~/git/ai/platform-applications-gitops)
#   OLD_GITOPS_DEPS    gitops checkout at 158b3da with vendored chart
#                      dependencies to seed from (default
#                      ~/git/ai/platform-applications-gitops-teknoir-local)
#   OLD_SETUP_HISTORY  1 (default): add the legacy duplicates and orphans (7)
#   OLD_SETUP_RESTART  1 (default): restart k3s at the end (9)
#   OLD_SETUP_SETTLE_TIMEOUT  seconds to wait for the Applications (default 1800)
#
# Idempotent: the workstation steps reuse what OLD_SETUP_DIR holds; the node
# steps leave markers in /var/lib/teknoir-e10-old-setup on the VM, so a re-run
# against the same VM resumes after the last finished step. It refuses a VM
# that has k3s or the new tooling but no marker (not fresh). Never prints a
# secret value; the log is OLD_SETUP_DIR/old-setup.log. Exit 0 when the old
# layout is in place, non-zero on any failure.
set -euo pipefail
# iptables, ip and sysctl live in the sbin dirs, which not every shell has on PATH
PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
SELF="${HERE}/$(basename "${BASH_SOURCE[0]}")"
VM="${HERE}/vm.sh"
NETNS="${HERE}/lan-netns.sh"

OLD_INFRA_REV="${OLD_INFRA_REV:-e9a3b7f918941a0da85e6eabc7e8a0487fe1a753}"
OLD_GITOPS_REV="${OLD_GITOPS_REV:-158b3daa0d732a893a3c726c20c91d2129f63b76}"
OLD_APP_OF_APPS="0.0.3"
OLD_SETUP_DIR="${OLD_SETUP_DIR:-${HOME}/vmtest/old-setup}"
OLD_BUNDLE_SRC="${OLD_BUNDLE_SRC:-${HOME}/git/ai/infra-teknoir-local/bundle/teknoir-airgap-bundle-0.1.0}"
OLD_INFRA_DEPS="${OLD_INFRA_DEPS:-${HOME}/git/ai/infra-teknoir-local}"
OLD_GITOPS_REPO="${OLD_GITOPS_REPO:-${HOME}/git/ai/platform-applications-gitops}"
OLD_GITOPS_DEPS="${OLD_GITOPS_DEPS:-${HOME}/git/ai/platform-applications-gitops-teknoir-local}"
OLD_SETUP_HISTORY="${OLD_SETUP_HISTORY:-1}"
OLD_SETUP_RESTART="${OLD_SETUP_RESTART:-1}"
OLD_SETUP_SETTLE_TIMEOUT="${OLD_SETUP_SETTLE_TIMEOUT:-1800}"

INFRA="${OLD_SETUP_DIR}/infra"
GITOPS="${OLD_SETUP_DIR}/gitops"
LANHOME="${OLD_SETUP_DIR}/lanhome"
BIN="${OLD_SETUP_DIR}/bin"
LOG="${OLD_SETUP_DIR}/old-setup.log"
DIR_TAG="${OLD_SETUP_DIR}/.old-setup-dir"
VM_ID_FILE="${OLD_SETUP_DIR}/vm-machine-id"
BUNDLE_NAME="teknoir-airgap-bundle-0.1.0"
BUNDLE="${INFRA}/bundle/${BUNDLE_NAME}"
NODE_USER="teknoir"
MANIFESTS="/opt/k3s/server/manifests"
MARKS="/var/lib/teknoir-e10-old-setup"
LIVE_NODE_IP="192.168.5.181"
TEKNOIR_RE='^(teknoir-.+|00-teknoir-.+|05-teknoir-.+|10-teknoir-.+|manifest-.+-secret|app-of-apps)$'

# Secret manifests: canonical K3s name <- legacy name (the .secrets basename;
# lib.sh:k3s_canonical_name at e9a3b7f). Mirrors airgap/test/k3d/fixtures/legacy-k3s/secrets.tsv.
SECRET_PAIRS=(
  "teknoir-argocd-harbor-repo-secret manifest-argocd-harbor-repo-secret"
  "teknoir-argocd-keycloak-secret manifest-argocd-keycloak-secret"
  "teknoir-auth-ca-bundle-secret manifest-teknoir-auth-ca-bundle-secret"
  "teknoir-ca-secret manifest-teknoir-ca-secret"
  "teknoir-harbor-secret manifest-harbor-secret"
  "teknoir-keycloak-db-secret manifest-keycloak-db-secret"
  "teknoir-oauth2-proxy-redis-secret manifest-oauth2-proxy-redis-secret"
  "teknoir-oauth2-proxy-secret manifest-oauth2-proxy-secret"
  "teknoir-system-ca-bundle-secret manifest-teknoir-system-ca-bundle-secret"
)
OTHER_FILES=(00-teknoir-namespaces 00-teknoir-istio-crds 05-teknoir-certmanager-crds teknoir-coredns-custom teknoir-app-of-apps teknoir-argo)
# legacy name <- canonical name of the non-secret files (k3s_legacy_names)
OTHER_LEGACY=("teknoir-argo 10-teknoir-argo" "teknoir-app-of-apps app-of-apps")
# what the update round (8) retires; their Addons stay behind as orphans
RETIRED_BY_UPDATE=(manifest-argocd-harbor-repo-secret app-of-apps 10-teknoir-argo)

usage() { sed -n '3,/^set -euo/p' "${SELF}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

log()  { printf '\033[1;35m[old-setup %s]\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[1;33m[old-setup %s] WARN:\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[old-setup %s] ERROR:\033[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

need() { local t; for t in "$@"; do command -v "${t}" >/dev/null 2>&1 || die "missing tool: ${t}"; done; }

# ---------------------------------------------------------------------------
# the VM (harness access, as e2e.sh does it)
# ---------------------------------------------------------------------------
vmx() { "${VM}" ssh "$(printf '%q ' "$@")"; }     # one command on the VM, as teknoir
node_root() { "${VM}" ssh 'sudo bash -s'; }        # a root script on stdin

node_vars() {
  # node_vars NAME... — shell assignments for a node script (values %q-quoted)
  local v
  for v in "$@"; do printf '%s=%q\n' "${v}" "${!v}"; done
}

has_mark() { vmx sudo test -e "${MARKS}/$1"; }
set_mark() { vmx sudo install -d -m 0700 "${MARKS}" >/dev/null && vmx sudo touch "${MARKS}/$1"; }

stage() {
  # stage NAME FUNCTION — run FUNCTION once per VM (marker on the node)
  local name="$1" fn="$2" t0
  if has_mark "${name}"; then
    log "== ${name}: done already on this VM (marker ${MARKS}/${name}), skipped"
    return 0
  fi
  t0=$(date +%s)
  log "== ${name}"
  "${fn}"
  set_mark "${name}"
  log "== ${name}: done ($(( $(date +%s) - t0 )) s)"
}

# ---------------------------------------------------------------------------
# the LAN host: the old LAN-side scripts in the netns
# ---------------------------------------------------------------------------
lan_run() {
  # lan_run CMD... — one old-tooling command in the netns tklan as the invoking
  # user, cwd = the e9a3b7f worktree, HOME = LANHOME (helm and crane logins
  # land there), ssh through the wrapper in BIN. sudo resets the environment,
  # so everything the old scripts read is passed here (no secret among it).
  log "LAN \$ $*"
  # shellcheck disable=SC2016  # expanded by the inner bash
  "${NETNS}" exec -- env HOME="${LANHOME}" PATH="${BIN}:${BUNDLE}/tools/linux-amd64:${PATH}" \
    DOCKER_CONFIG="${LANHOME}/.docker" SSH_KEY="${SSH_KEY}" TEKNOIR_HOST="${NODE_USER}@${VM_IP}" \
    NODE_IP="${VM_IP}" K3S_DATA_DIR=/opt/k3s \
    bash -c 'cd "$1" && shift && exec "$@"' old-setup "${INFRA}" "$@"
}

write_ssh_wrapper() {
  # The old scripts ssh with StrictHostKeyChecking=accept-new into ~/.ssh
  # (OpenSSH uses the passwd home, not $HOME). The VM is re-created all the
  # time, so: no host-key pinning and no known_hosts writes, like vm.sh. ssh
  # takes the first value of an option, so these win over the scripts' -o.
  local real
  real="$(command -v ssh)" || die "ssh not found"   # BIN is only on lan_run's PATH
  [[ "${real}" != *"'"* ]] || die "unexpected quote in the ssh path ${real}"
  install -d -m 0700 "${BIN}"
  cat > "${BIN}/ssh.tmp" <<EOF
#!/bin/sh
# written by airgap/test/vm/old-setup.sh: ssh for the old tooling against the test VM
exec '${real}' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \\
  -o IdentitiesOnly=yes -o BatchMode=yes -o LogLevel=ERROR "\$@"
EOF
  chmod 0700 "${BIN}/ssh.tmp"
  mv -f "${BIN}/ssh.tmp" "${BIN}/ssh"
}

# ---------------------------------------------------------------------------
# 1. throwaway worktrees
# ---------------------------------------------------------------------------
ensure_worktree() {
  # ensure_worktree <repo> <dir> <rev>
  local repo="$1" dir="$2" rev="$3"
  if [[ -e "${dir}/.git" ]]; then
    [[ "$(git -C "${dir}" rev-parse HEAD)" == "${rev}" ]] \
      || die "${dir} is not at ${rev} (re-run with --clean)"
    [[ -z "$(git -C "${dir}" status --porcelain --untracked-files=no)" ]] \
      || die "${dir} has local changes to tracked files (re-run with --clean)"
    return 0
  fi
  git -C "${repo}" cat-file -e "${rev}^{commit}" 2>/dev/null || die "${repo} does not have commit ${rev}"
  log "worktree ${dir} (detached at ${rev:0:7})"
  git -C "${repo}" worktree add --detach "${dir}" "${rev}" >/dev/null 2>&1 || die "git worktree add ${dir} ${rev} failed"
}

seed_chart_deps() {
  # seed_chart_deps <src-chart-dir> <dst-chart-dir> — copy the vendored
  # dependencies (Chart.lock, charts/*.tgz; gitignored, never secrets) so that
  # helm_dep_build needs no download
  local src="$1" dst="$2" f
  [[ -d "${src}/charts" && ! -e "${dst}/charts" ]] || return 0
  install -d "${dst}/charts"
  for f in "${src}/charts/"*.tgz; do
    if [[ -f "${f}" ]]; then cp "${f}" "${dst}/charts/"; fi
  done
  if [[ -f "${src}/Chart.lock" && ! -e "${dst}/Chart.lock" ]]; then cp "${src}/Chart.lock" "${dst}/Chart.lock"; fi
}

prepare_worktrees() {
  local c
  ensure_worktree "${REPO}" "${INFRA}" "${OLD_INFRA_REV}"
  [[ -d "${OLD_GITOPS_REPO}/.git" || -f "${OLD_GITOPS_REPO}/.git" ]] || die "no gitops repository at ${OLD_GITOPS_REPO} (set OLD_GITOPS_REPO)"
  ensure_worktree "${OLD_GITOPS_REPO}" "${GITOPS}" "${OLD_GITOPS_REV}"
  seed_chart_deps "${OLD_INFRA_DEPS}/charts/argo" "${INFRA}/charts/argo"
  if [[ -d "${OLD_GITOPS_DEPS}" ]] && [[ "$(git -C "${OLD_GITOPS_DEPS}" rev-parse HEAD 2>/dev/null)" == "${OLD_GITOPS_REV}" ]]; then
    for c in "${GITOPS}/charts/"*/; do
      c="$(basename "${c}")"
      seed_chart_deps "${OLD_GITOPS_DEPS}/charts/${c}" "${GITOPS}/charts/${c}"
    done
  else
    warn "${OLD_GITOPS_DEPS} is not a checkout at ${OLD_GITOPS_REV:0:7}: chart dependencies are downloaded"
  fi
}

# ---------------------------------------------------------------------------
# 2. dummy secrets (the old generators; they echo values, so stdout is discarded)
# ---------------------------------------------------------------------------
gen() {
  # gen <script> [stdin-file] — one old generator in the worktree root
  log "  scripts/$1 (dummy values; its output is discarded)"
  if [[ -n "${2:-}" ]]; then
    (cd "${INFRA}" && "./scripts/$1" < "$2" >/dev/null) || die "scripts/$1 failed"
  else
    (cd "${INFRA}" && "./scripts/$1" </dev/null >/dev/null) || die "scripts/$1 failed"
  fi
}

secrets_phase1() {
  # AIRGAP-BOOTSTRAP.md 3: the five generators run before the bundle build
  local s="${INFRA}/.secrets"
  log "dummy secrets (bootstrap runbook 3) in ${s}"
  if [[ ! -f "${s}/manifest-teknoir-ca-secret.yaml" || ! -f "${INFRA}/teknoir-root-ca.crt" ]]; then gen gen-local-ca-secret.sh; fi
  [[ -f "${s}/manifest-harbor-secret.yaml" ]] || gen gen-harbor-secrets.sh
  [[ -f "${s}/manifest-keycloak-db-secret.yaml" ]] || gen gen-keycloak-db-secret.sh
  [[ -f "${s}/manifest-oauth2-proxy-redis-secret.yaml" ]] || gen gen-oauth2-proxy-redis-secret.sh
  [[ -f "${s}/manifest-argocd-harbor-repo-secret.yaml" ]] || gen gen-argocd-harbor-repo-secret.sh
  local m
  for m in teknoir-ca wildcard-tls teknoir-auth-ca-bundle teknoir-system-ca-bundle harbor keycloak-db oauth2-proxy-redis argocd-harbor-repo; do
    [[ -s "${s}/manifest-${m}-secret.yaml" ]] || die "the generators did not write ${s}/manifest-${m}-secret.yaml"
  done
}

secrets_phase2() {
  # AIRGAP-BOOTSTRAP.md 8.1 and 8.3: the client secrets come from Keycloak
  # clients created by hand; here random dummies are fed to the prompts
  local s="${INFRA}/.secrets" tmp
  tmp="$(mktemp "${OLD_SETUP_DIR}/.client.XXXXXX")"
  if [[ ! -f "${s}/manifest-argocd-keycloak-secret.yaml" ]]; then
    openssl rand -hex 16 > "${tmp}"
    gen gen-argocd-keycloak-secrets.sh "${tmp}"
  fi
  if [[ ! -f "${s}/manifest-oauth2-proxy-secret.yaml" ]]; then
    openssl rand -hex 16 > "${tmp}"
    gen gen-oauth2-proxy-secrets.sh "${tmp}"
  fi
  rm -f "${tmp}"
  [[ -s "${s}/manifest-argocd-keycloak-secret.yaml" && -s "${s}/manifest-oauth2-proxy-secret.yaml" ]] \
    || die "the Keycloak client secret manifests were not written"
}

# ---------------------------------------------------------------------------
# 3. the bundle (old make-bundle.sh)
# ---------------------------------------------------------------------------
bundle_stamp() {
  { printf 'infra %s\ngitops %s\nnode-ip %s\n' "${OLD_INFRA_REV}" "${OLD_GITOPS_REV}" "${VM_IP}"
    sha256sum "${INFRA}/teknoir-root-ca.crt" | cut -d' ' -f1
  } | sha256sum | cut -d' ' -f1
}

seed_bundle() {
  # Hard links of the parts make-bundle.sh only reads (it skips an image whose
  # OCI layout or tarball exists, and tools/k3s that exist). Everything it
  # (re)writes in place is NOT linked: charts/, bootstrap/{manifests,apply,k3s,
  # secrets}, airgap/, scripts/, images/images.txt. bootstrap/secrets of the
  # source holds the live secrets: it is never copied or read.
  local d
  install -d -m 0700 "${BUNDLE}" "${BUNDLE}/bootstrap"
  if [[ ! -d "${OLD_BUNDLE_SRC}" ]]; then
    warn "no old bundle at ${OLD_BUNDLE_SRC}: make-bundle.sh downloads every image, k3s and the tools (internet, ~8 GB)"
    return 0
  fi
  for d in images bootstrap/images k3s tools; do
    [[ -d "${OLD_BUNDLE_SRC}/${d}" && ! -e "${BUNDLE}/${d}" ]] || continue
    log "  seeding ${d}/ from ${OLD_BUNDLE_SRC} (hard links)"
    if ! cp -al "${OLD_BUNDLE_SRC}/${d}" "${BUNDLE}/${d}" 2>/dev/null; then
      rm -rf "${BUNDLE:?}/${d}"
      cp -a "${OLD_BUNDLE_SRC}/${d}" "${BUNDLE}/${d}"
    fi
  done
  # collect-images.sh truncates images.txt: give it its own inode
  if [[ -f "${OLD_BUNDLE_SRC}/images/images.txt" ]]; then
    cp --remove-destination "${OLD_BUNDLE_SRC}/images/images.txt" "${BUNDLE}/images/images.txt"
  fi
}

check_bundle() {
  # the rebuilt bundle carries the dummy secrets, the dummy CA and VM_IP
  local m f n=0
  for f in "${BUNDLE}/bootstrap/secrets/"*.yaml; do
    [[ -f "${f}" ]] || continue
    n=$((n + 1))
    m="$(basename "${f}")"
    cmp -s "${f}" "${INFRA}/.secrets/${m}" || die "bundle bootstrap/secrets/${m} differs from the dummy ${INFRA}/.secrets/${m}"
  done
  for m in teknoir-ca wildcard-tls teknoir-auth-ca-bundle teknoir-system-ca-bundle harbor keycloak-db oauth2-proxy-redis argocd-harbor-repo; do
    [[ -f "${BUNDLE}/bootstrap/secrets/manifest-${m}-secret.yaml" ]] || die "bundle bootstrap/secrets lacks manifest-${m}-secret.yaml (bootstrap runbook 3)"
  done
  (( n >= 8 )) || die "bundle bootstrap/secrets has ${n} manifests, expected at least the 8 of the bootstrap runbook 3"
  cmp -s "${BUNDLE}/bootstrap/k3s/teknoir-root-ca.crt" "${INFRA}/teknoir-root-ca.crt" \
    || die "bundle bootstrap/k3s/teknoir-root-ca.crt is not the dummy CA"
  if [[ -f "${OLD_BUNDLE_SRC}/bootstrap/k3s/teknoir-root-ca.crt" ]] \
     && cmp -s "${BUNDLE}/bootstrap/k3s/teknoir-root-ca.crt" "${OLD_BUNDLE_SRC}/bootstrap/k3s/teknoir-root-ca.crt"; then
    die "the rebuilt bundle carries the LIVE CA certificate"
  fi
  grep -qF "${VM_IP} harbor." "${BUNDLE}/bootstrap/k3s/coredns-custom.yaml" \
    || die "bundle coredns-custom.yaml does not map the platform names to ${VM_IP}"
  grep -qF "harbor.teknoir.airgapped: |" "${BUNDLE}/bootstrap/manifests/teknoir-argo.yaml" \
    || die "bundle teknoir-argo.yaml has no CA for harbor.teknoir.airgapped (argocd-tls-certs-cm)"
  [[ "$(head -1 "${BUNDLE}/charts/pins.txt")" == "app-of-apps ${OLD_APP_OF_APPS}" ]] \
    || die "bundle charts/pins.txt does not pin app-of-apps ${OLD_APP_OF_APPS}"
  [[ -f "${BUNDLE}/bootstrap/apply/harbor.yaml" && -f "${BUNDLE}/bootstrap/apply/istio.yaml" ]] \
    || die "bundle bootstrap/apply is incomplete (no first bootstrap possible)"
}

build_bundle() {
  local want
  want="$(bundle_stamp)"
  if [[ -f "${BUNDLE}/bundle-manifest.yaml" && -f "${OLD_SETUP_DIR}/bundle.stamp" ]] \
     && [[ "$(cat "${OLD_SETUP_DIR}/bundle.stamp")" == "${want}" ]]; then
    log "bundle ${BUNDLE} is up to date (same revisions, CA and node IP)"
    check_bundle
    return 0
  fi
  rm -f "${OLD_SETUP_DIR}/bundle.stamp"
  seed_bundle
  log "old make-bundle.sh (GITOPS_REPO_DIR=${GITOPS}, NODE_IP=${VM_IP})"
  (cd "${INFRA}" && env -u DRY_RUN -u BUNDLE_DIR -u HARBOR_ADMIN_PASSWORD -u ROBOT_ENV_FILE \
     NODE_IP="${VM_IP}" GITOPS_REPO_DIR="${GITOPS}" GITOPS_ALLOW_ANY_BRANCH=1 \
     ./airgap/make-bundle.sh) || die "the old make-bundle.sh failed"
  check_bundle
  printf '%s\n' "${want}" > "${OLD_SETUP_DIR}/bundle.stamp"
  log "bundle ready: $(du -sh "${BUNDLE}" | cut -f1) in ${BUNDLE}"
}

# ---------------------------------------------------------------------------
# 4. host setup on the node
# ---------------------------------------------------------------------------
check_fresh() {
  # a VM with k3s or the new tooling but without our first marker is not fresh
  has_mark started && return 0
  if vmx test -e /usr/local/bin/k3s || vmx test -e /var/lib/teknoir-airgap || vmx test -e /opt/k3s; then
    die "the VM is not fresh (k3s or the new tooling is installed, and no ${MARKS}/started): re-create it (e2e.sh E10 does: vm.sh destroy && vm.sh start)"
  fi
  set_mark started
}

do_upload() {
  # HOST-SETUP 8.1 (LAN rsync; tar over ssh when the node has no rsync)
  lan_run ./airgap/upload-bundle.sh --host "${NODE_USER}@${VM_IP}"
}

do_k3s() {
  # HOST-SETUP 6 (inotify) and 8.2 (install-k3s.sh), with the
  # test-environment workaround between writing config.yaml and the first start
  { node_vars VM_IP NODE_USER BUNDLE_NAME; cat <<'EOF'
set -euo pipefail
printf 'fs.inotify.max_user_instances=1024\n' > /etc/sysctl.d/teknoir.inotify.conf
sysctl -q --system >/dev/null 2>&1 || true
home="$(getent passwd "${NODE_USER}" | cut -d: -f6)"
cd "${home}/${BUNDLE_NAME}"
# the old installer as the runbook runs it, but without starting k3s yet
INSTALL_K3S_SKIP_START=true ./airgap/install-k3s.sh --no-verify </dev/null
EOF
  } | node_root || die "airgap/install-k3s.sh failed on the node"
  log "test-environment workaround check (default route, upstream DNS)"
  { node_vars VM_IP; cat <<'EOF'
set -euo pipefail
cfg=/etc/rancher/k3s/config.yaml
[ -f "${cfg}" ] || { echo "install-k3s.sh wrote no ${cfg}" >&2; exit 1; }
iface="$(ip -o -4 addr show | awk -v ip="${VM_IP}" '{ split($4, a, "/"); if (a[1] == ip && !f) { print $2; f = 1 } }')"
[ -n "${iface}" ] || { echo "no interface holds ${VM_IP}" >&2; exit 1; }
upstream="$(awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ { print $2 }' /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null || true)"
upstream="${upstream%%$'\n'*}"
block=""
if [ -z "$(ip -4 route show default)" ]; then
  block="${block}node-ip: ${VM_IP}
flannel-iface: ${iface}
"
fi
if [ -z "${upstream}" ]; then
  if systemctl is-active --quiet systemd-resolved; then
    install -d -m 0755 /etc/systemd/resolved.conf.d
    printf '# E10 test-environment workaround (airgap/test/vm/old-setup.sh), not part of the legacy layout:\n# the test VM has no upstream DNS; systemd-resolved answers CoreDNS on the node IP\n[Resolve]\nDNSStubListenerExtra=%s\n' \
      "${VM_IP}" > /etc/systemd/resolved.conf.d/teknoir-airgap.conf
    systemctl restart systemd-resolved
  else
    echo "WARN: no upstream DNS and no systemd-resolved: CoreDNS lookups of other names will time out" >&2
  fi
  install -d -m 0755 /etc/rancher/k3s
  printf '# E10 test-environment workaround (airgap/test/vm/old-setup.sh), not part of the legacy layout\nnameserver %s\n' \
    "${VM_IP}" > /etc/rancher/k3s/resolv.conf
  block="${block}resolv-conf: /etc/rancher/k3s/resolv.conf
"
fi
if [ -n "${block}" ] && ! grep -q '^# BEGIN E10 test-environment workaround' "${cfg}"; then
  {
    echo "# BEGIN E10 test-environment workaround (airgap/test/vm/old-setup.sh), NOT part of"
    echo "# the legacy layout: the test VM has no default route and/or no upstream DNS;"
    echo "# the live node has both. The new host phase writes these keys itself."
    printf '%s' "${block}"
    echo "# END E10 test-environment workaround"
  } >> "${cfg}"
  echo "appended to ${cfg}: $(printf '%s' "${block}" | tr '\n' ' ')"
elif [ -z "${block}" ]; then
  echo "no workaround needed (the node has a default route and an upstream resolver)"
fi
systemctl start k3s </dev/null
deadline=$(( $(date +%s) + 300 ))
until k3s kubectl get nodes --no-headers 2>/dev/null | grep -w Ready >/dev/null; do
  [ "$(date +%s)" -lt "${deadline}" ] || { echo "k3s node not Ready within 300 s (journalctl -u k3s)" >&2; exit 1; }
  sleep 5
done
k3s kubectl get nodes -o wide --no-headers
EOF
  } | node_root || die "starting k3s failed on the node"
}

# ---------------------------------------------------------------------------
# 5./6. bootstrap, Harbor, secrets
# ---------------------------------------------------------------------------
fix_stuck_gateways() {
  # delete istio-system pods whose container image is still the injection
  # placeholder "auto" (created before istiod's webhook answered), once istiod
  # is available and the pod is older than a minute; quiet, best effort
  node_root <<'EOF' 2>/dev/null || true
set -u
k3s kubectl -n istio-system get deploy istiod -o jsonpath='{.status.availableReplicas}' 2>/dev/null | grep -q '^[1-9]' || exit 0
now=$(date +%s)
k3s kubectl -n istio-system get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.creationTimestamp}{" "}{.spec.containers[*].image}{"\n"}{end}' |
while read -r pod created images; do
  case " ${images} " in *" auto "*) ;; *) continue ;; esac
  age=$(( now - $(date -d "${created}" +%s) ))
  [ "${age}" -gt 60 ] || continue
  echo "E10 race workaround: deleting istio-system/${pod} (not injected: image auto, ${age}s old)"
  k3s kubectl -n istio-system delete pod "${pod}" --wait=false >/dev/null
done
EOF
}

do_bootstrap() {
  # BOOTSTRAP 6.1, with the gateway race watchdog in the background
  local watchdog rc=0 attempt
  for attempt in 1 2; do
    ( while :; do sleep 30; fix_stuck_gateways; done ) &
    watchdog=$!
    rc=0
    lan_run ./airgap/bootstrap-airgap.sh --host "${NODE_USER}@${VM_IP}" --node-ip "${VM_IP}" || rc=$?
    kill "${watchdog}" 2>/dev/null || true
    wait "${watchdog}" 2>/dev/null || true
    (( rc == 0 )) && return 0
    warn "bootstrap-airgap.sh failed (rc ${rc}, attempt ${attempt}); it is idempotent"
  done
  die "bootstrap-airgap.sh failed twice"
}

push_with_dummy_admin() {
  # internal (__push, runs inside the netns): push-to-harbor.sh with the dummy
  # Harbor admin password from .secrets (the parse of gen-argocd-harbor-repo-secret.sh);
  # it goes to the script through the environment, never through argv or output
  local pw
  pw="$(sed -n 's/^ *HARBOR_ADMIN_PASSWORD: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' .secrets/manifest-harbor-secret.yaml)" \
    || die "cannot read .secrets/manifest-harbor-secret.yaml"
  pw="${pw%%$'\n'*}"
  [[ -n "${pw}" ]] || die "cannot read the dummy Harbor admin password from .secrets/manifest-harbor-secret.yaml"
  HARBOR_ADMIN_PASSWORD="${pw}" exec ./airgap/push-to-harbor.sh "$@"
}

do_push() {
  # BOOTSTRAP 6.2; Harbor may still answer 5xx right after its pods are Ready
  local attempt
  for attempt in 1 2 3; do
    if lan_run "${SELF}" __push; then return 0; fi
    warn "push-to-harbor.sh failed (attempt ${attempt}); it is idempotent, retrying in 60 s"
    sleep 60
  done
  die "push-to-harbor.sh failed three times"
}

do_secrets() {
  # BOOTSTRAP 6.3 (robot credential), then 8.1/8.3 (the Keycloak client secrets)
  lan_run ./scripts/deploy-secrets.sh
  secrets_phase2
  lan_run ./scripts/deploy-secrets.sh
}

# ---------------------------------------------------------------------------
# 7. the history of older tooling
# ---------------------------------------------------------------------------
do_history() {
  # byte-identical copies of canonical files under their legacy names (what
  # bootstrap-airgap.sh and the deploy scripts wrote before e9a3b7f), applied
  # by K3s, so that the legacy Addons own the objects for now
  local pairs="" p
  for p in "${OTHER_LEGACY[@]}" "${SECRET_PAIRS[@]}"; do pairs+="${p}"$'\n'; done
  { node_vars MANIFESTS pairs; cat <<'EOF'
set -euo pipefail
written=""
while read -r canon legacy; do
  [ -n "${canon}" ] || continue
  src="${MANIFESTS}/${canon}.yaml" dst="${MANIFESTS}/${legacy}.yaml"
  [ -f "${src}" ] || { echo "missing ${src}: the old flow did not deploy it" >&2; exit 1; }
  if [ -e "${dst}" ]; then echo "  ${legacy}.yaml exists"; continue; fi
  mode="$(stat -c %a "${src}")"
  # K3s ignores dot files; the rename makes the file appear complete
  install -m "${mode}" "${src}" "${MANIFESTS}/.${legacy}.yaml.tmp"
  mv -f "${MANIFESTS}/.${legacy}.yaml.tmp" "${dst}"
  echo "  ${legacy}.yaml <- copy of ${canon}.yaml (mode ${mode})"
  written="${written} ${legacy}"
done <<< "${pairs}"
deadline=$(( $(date +%s) + 300 ))
for legacy in ${written}; do
  sum="$(sha256sum "${MANIFESTS}/${legacy}.yaml" | cut -d' ' -f1)"
  until [ "$(k3s kubectl -n kube-system get addons.k3s.cattle.io "${legacy}" --ignore-not-found -o jsonpath='{.spec.checksum}')" = "${sum}" ]; do
    [ "$(date +%s)" -lt "${deadline}" ] || { echo "K3s did not apply ${legacy}.yaml within 300 s" >&2; exit 1; }
    sleep 3
  done
done
echo "K3s applied every legacy copy"
EOF
  } | node_root || die "writing the legacy duplicates failed"
}

# ---------------------------------------------------------------------------
# 8. the update round (AIRGAP-UPDATE.md 2.3, 2.4: app-of-apps before --update)
# ---------------------------------------------------------------------------
do_update() {
  lan_run ./scripts/deploy-secrets.sh --only manifest-argocd-harbor-repo-secret.yaml
  lan_run ./airgap/update-airgap.sh "${OLD_APP_OF_APPS}"
  lan_run ./airgap/bootstrap-airgap.sh --update --host "${NODE_USER}@${VM_IP}" --node-ip "${VM_IP}"
}

# ---------------------------------------------------------------------------
# 9. restart, settle, layout check
# ---------------------------------------------------------------------------
wait_files_applied() {
  # every Teknoir file in the manifests dir is applied by K3s with its current content
  { node_vars MANIFESTS TEKNOIR_RE; cat <<'EOF'
set -euo pipefail
deadline=$(( $(date +%s) + 600 ))
until k3s kubectl get --raw /readyz >/dev/null 2>&1; do
  [ "$(date +%s)" -lt "${deadline}" ] || { echo "API server not ready within 600 s" >&2; exit 1; }
  sleep 5
done
k3s kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
for f in "${MANIFESTS}"/*.yaml; do
  name="$(basename "${f}" .yaml)"
  [[ "${name}" =~ ${TEKNOIR_RE} ]] || continue
  sum="$(sha256sum "${f}" | cut -d' ' -f1)"
  until [ "$(k3s kubectl -n kube-system get addons.k3s.cattle.io "${name}" --ignore-not-found -o jsonpath='{.spec.checksum}')" = "${sum}" ]; do
    [ "$(date +%s)" -lt "${deadline}" ] || { echo "K3s did not re-apply ${name}.yaml within 600 s" >&2; exit 1; }
    sleep 5
  done
done
EOF
  } | node_root || die "K3s did not settle"
}

do_restart() {
  log "restarting k3s (re-applies every K3s file in name order: the canonical teknoir-* files own their objects again)"
  vmx sudo systemctl restart k3s
  wait_files_applied
  # K3s re-applies every file once after a start; its deploy loop scans every 15 s
  sleep 45
}

apps_table() {
  vmx sudo k3s kubectl -n teknoir-system get applications.argoproj.io --no-headers \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,TARGET:.spec.source.targetRevision
}

wait_settled() {
  # The Applications have settled when none is Progressing, Missing or Unknown
  # (Degraded and OutOfSync count: the old harbor render is not deterministic,
  # and the live env runs with a Degraded app or two) in two polls 30 s apart,
  # so e2e.sh's pre-migration inventory holds no half-created objects.
  local deadline t ok=0
  deadline=$(( $(date +%s) + OLD_SETUP_SETTLE_TIMEOUT ))
  log "waiting up to ${OLD_SETUP_SETTLE_TIMEOUT}s for the Applications to settle"
  while (( $(date +%s) < deadline )); do
    t="$(apps_table 2>/dev/null || true)"
    if [[ -n "${t}" ]] && grep -q '^app-of-apps ' <<<"${t}" \
       && [[ -z "$(awk '$3 == "Progressing" || $3 == "Missing" || $3 == "Unknown" || $3 == "<none>" || $2 == "Unknown" || $2 == "<none>"' <<<"${t}")" ]]; then
      ok=$((ok + 1))
      if (( ok >= 2 )); then
        log "Applications settled:"
        printf '%s\n' "${t}" | sed 's/^/    /' >&2
        return 0
      fi
    else
      ok=0
    fi
    sleep 30
  done
  warn "the Applications did not settle within ${OLD_SETUP_SETTLE_TIMEOUT}s:"
  apps_table 2>/dev/null | sed 's/^/    /' >&2 || true
  return 0
}

expected_layout() {
  # expected_layout files|addons — the Teknoir K3s files / Addons, sorted
  local p
  {
    printf '%s\n' "${OTHER_FILES[@]}"
    for p in "${SECRET_PAIRS[@]}"; do
      printf '%s\n' "${p%% *}"
      if [[ "${OLD_SETUP_HISTORY}" == "1" ]]; then printf '%s\n' "${p##* }"; fi
    done
    if [[ "${OLD_SETUP_HISTORY}" == "1" && "$1" == addons ]]; then
      printf '%s\n' "10-teknoir-argo" "app-of-apps"
    fi
  } | if [[ "${OLD_SETUP_HISTORY}" == "1" && "$1" == files ]]; then
        grep -vxF -f <(printf '%s\n' "${RETIRED_BY_UPDATE[@]}")
      else
        cat
      fi | LC_ALL=C sort
}

check_layout() {
  local files addons want_files want_addons orphans
  files="$(vmx sudo ls -1 "${MANIFESTS}" | sed -n 's/\.yaml$//p' | grep -E "${TEKNOIR_RE}" | LC_ALL=C sort || true)"
  addons="$(vmx sudo k3s kubectl -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -E "${TEKNOIR_RE}" | LC_ALL=C sort || true)"
  want_files="$(expected_layout files)" want_addons="$(expected_layout addons)"
  if [[ "${files}" != "${want_files}" ]]; then
    diff <(printf '%s\n' "${want_files}") <(printf '%s\n' "${files}") | sed 's/^/    /' >&2 || true
    die "the Teknoir K3s files are not the legacy layout (< expected, > found)"
  fi
  if [[ "${addons}" != "${want_addons}" ]]; then
    diff <(printf '%s\n' "${want_addons}") <(printf '%s\n' "${addons}") | sed 's/^/    /' >&2 || true
    die "the Teknoir Addons are not the legacy layout (< expected, > found)"
  fi
  orphans="$(LC_ALL=C comm -13 <(printf '%s\n' "${files}") <(printf '%s\n' "${addons}") | tr '\n' ' ')"
  log "layout OK: $(grep -c . <<<"${files}") Teknoir K3s files, $(grep -c . <<<"${addons}") Addons (orphans, file gone: ${orphans:-none})"
}

report() {
  local rev
  rev="$(vmx sudo k3s kubectl -n teknoir-system get applications.argoproj.io app-of-apps -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || true)"
  [[ "${rev}" == "${OLD_APP_OF_APPS}" ]] || die "the root Application app-of-apps targets '${rev}', not ${OLD_APP_OF_APPS}"
  log "old layout on ${VM_IP}: app-of-apps ${rev}, k3s $(vmx k3s --version 2>/dev/null | head -1 | awk '{print $3}'), files in ${MANIFESTS}:"
  vmx sudo ls -l "${MANIFESTS}" | sed 's/^/    /' >&2
  log "node home: $(vmx ls -d "/home/${NODE_USER}/${BUNDLE_NAME}" 2>/dev/null || echo "no ${BUNDLE_NAME}")"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
clean() {
  [[ -e "${OLD_SETUP_DIR}" ]] || return 0
  [[ -f "${DIR_TAG}" ]] || die "${OLD_SETUP_DIR} was not created by old-setup.sh (no ${DIR_TAG}); not removing it"
  log "removing ${OLD_SETUP_DIR}"
  if [[ -e "${INFRA}/.git" ]]; then git -C "${REPO}" worktree remove --force "${INFRA}" >/dev/null 2>&1 || true; fi
  if [[ -e "${GITOPS}/.git" ]]; then git -C "${OLD_GITOPS_REPO}" worktree remove --force "${GITOPS}" >/dev/null 2>&1 || true; fi
  rm -rf "${OLD_SETUP_DIR:?}"
  git -C "${REPO}" worktree prune >/dev/null 2>&1 || true
  if [[ -d "${OLD_GITOPS_REPO}" ]]; then git -C "${OLD_GITOPS_REPO}" worktree prune >/dev/null 2>&1 || true; fi
}

main() {
  local build_only=0 do_clean=0 t0 hosts vm_id
  if [[ "${1:-}" == __push ]]; then shift; push_with_dummy_admin "$@"; fi
  while (( $# )); do
    case "$1" in
      --build-only) build_only=1 ;;
      --clean) do_clean=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown argument $1 (see --help)" ;;
    esac
    shift
  done
  [[ -n "${VM_IP:-}" ]] || die "VM_IP is not set (e2e.sh exports it; the test VM is 10.77.0.10)"
  [[ "${VM_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "VM_IP '${VM_IP}' is not an IPv4 address"
  [[ "${VM_IP}" != "${LIVE_NODE_IP}" ]] || die "VM_IP is the live teknoir-local node; this script only targets the test VM"
  need git helm crane python3 openssl sha256sum cmp tar curl
  python3 -c 'import yaml' 2>/dev/null || die "python3 without PyYAML (the old render needs it)"
  umask 077
  if (( ! build_only )) && [[ -f "${VM_ID_FILE}" ]]; then
    # the dummy secrets of phase 2 (the robot$argocd token) belong to the VM
    # they were made for: a re-created VM starts from a clean work dir
    vm_id="$("${VM}" ssh cat /etc/machine-id 2>/dev/null)" || die "the VM ${VM_IP} does not answer on ssh (vm.sh start)"
    if [[ "${vm_id}" != "$(cat "${VM_ID_FILE}")" ]]; then
      log "the VM was re-created since the last run (machine-id changed): starting from a clean ${OLD_SETUP_DIR}"
      do_clean=1
    fi
  fi
  if (( do_clean )); then clean; fi
  install -d -m 0700 "${OLD_SETUP_DIR}" "${LANHOME}"
  : > "${DIR_TAG}"
  exec > >(tee -a "${LOG}") 2>&1
  t0=$(date +%s)
  log "E10 old setup: infra ${OLD_INFRA_REV:0:7}, gitops ${OLD_GITOPS_REV:0:7} (app-of-apps ${OLD_APP_OF_APPS}), VM ${VM_IP}, work dir ${OLD_SETUP_DIR}"

  prepare_worktrees
  secrets_phase1
  build_bundle
  if (( build_only )); then
    log "--build-only: done ($(( $(date +%s) - t0 )) s); the bundle is ${BUNDLE}"
    return 0
  fi

  need sudo ssh ip
  [[ -x "${VM}" && -x "${NETNS}" ]] || die "vm.sh or lan-netns.sh missing next to ${SELF}"
  SSH_KEY="$("${VM}" key)"
  [[ -f "${SSH_KEY}" ]] || die "no VM ssh key at ${SSH_KEY} (vm.sh create)"
  "${VM}" ssh true || die "the VM ${VM_IP} does not answer on ssh (vm.sh start)"
  "${NETNS}" up
  hosts="$("${NETNS}" hosts)" || die "lan-netns.sh hosts failed"
  grep -qE "^${VM_IP//./\\.}[[:space:]].*harbor\." <<<"${hosts}" \
    || die "the LAN namespace does not map the platform names to ${VM_IP} (LAN_SITE NODE_IP must equal VM_IP)"
  write_ssh_wrapper

  check_fresh
  "${VM}" ssh cat /etc/machine-id > "${VM_ID_FILE}" || die "cannot read the VM's machine-id"
  stage upload do_upload
  stage k3s do_k3s
  stage bootstrap do_bootstrap
  stage push do_push
  stage secrets do_secrets
  if [[ "${OLD_SETUP_HISTORY}" == "1" ]]; then stage history do_history; fi
  stage update do_update
  if [[ "${OLD_SETUP_RESTART}" == "1" ]]; then stage restart do_restart; fi
  wait_files_applied
  check_layout
  wait_settled
  check_layout
  report
  log "E10 old setup complete ($(( ($(date +%s) - t0) / 60 )) min)"
}

main "$@"
