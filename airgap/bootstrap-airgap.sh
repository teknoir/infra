#!/usr/bin/env bash
# bootstrap-airgap.sh — first-time bootstrap of the air-gapped K3s node
# (LAN-laptop side, everything over ssh to $TEKNOIR_HOST).
#
# Flow (plan §4.4):
#   CA + registries.yaml + /etc/hosts + bootstrap image tarballs -> restart k3s
#   secrets + coredns-custom.yaml -> ordered bootstrap manifests (istio -> argo -> harbor)
#   with health waits between the tiers.
#
# Usage: airgap/bootstrap-airgap.sh [--bundle DIR] [--host user@host]
#                                   [--node-ip IP] [--update] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR     bundle directory (default: $(bundle_dir))
  --host H         ssh target (default: ${TEKNOIR_HOST})
  --node-ip IP     node IP for /etc/hosts + coredns-custom
                   (default: NODE_IP from versions.env [${NODE_IP:-unset}], else auto-detect over ssh)
  --update         update mode: only re-copy image tarballs + re-apply manifests
                   (skips CA / registries.yaml / /etc/hosts mutations)
  --dry-run        print every action without mutating the node
  -h, --help       show this help

Paths on the node (K3S_DATA_DIR=${K3S_DATA_DIR}, matching scripts/deploy-argo.sh):
  image tarballs:   ${K3S_DATA_DIR}/agent/images/
  manifests:        ${K3S_DATA_DIR}/server/manifests/
EOF
}

UPDATE_MODE=0
NODE_IP="${NODE_IP:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --node-ip) NODE_IP="$2"; shift ;;
    --update) UPDATE_MODE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh

BUNDLE="$(bundle_dir)"
K3S_MANIFESTS_DIR="${K3S_DATA_DIR}/server/manifests"
K3S_IMAGES_DIR="${K3S_DATA_DIR}/agent/images"

[[ -d "${BUNDLE}/bootstrap" ]] || die "bundle not found or incomplete: ${BUNDLE} (run make-bundle.sh)"
CA_FILE="${BUNDLE}/bootstrap/k3s/teknoir-root-ca.crt"
REGISTRIES_FILE="${BUNDLE}/bootstrap/k3s/registries.yaml"
COREDNS_FILE="${BUNDLE}/bootstrap/k3s/coredns-custom.yaml"
[[ -f "${CA_FILE}" ]] || die "missing ${CA_FILE}"
[[ -f "${REGISTRIES_FILE}" ]] || die "missing ${REGISTRIES_FILE}"
[[ -f "${COREDNS_FILE}" ]] || die "missing ${COREDNS_FILE}"

# ---------------------------------------------------------------------------
# Node IP (auto-detected unless --node-ip / NODE_IP given)
# ---------------------------------------------------------------------------
if [[ -z "${NODE_IP}" ]]; then
  log "auto-detecting node IP on ${TEKNOIR_HOST}"
  NODE_IP="$(ssh_query "hostname -I 2>/dev/null | awk '{print \$1}' || ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true)"
  NODE_IP="$(echo "${NODE_IP}" | head -1 | tr -d '[:space:]')"
fi
if [[ -z "${NODE_IP}" ]]; then
  if [[ "${DRY_RUN}" == "1" ]]; then
    warn "node IP not detectable in dry-run — using placeholder __NODE_IP__"
    NODE_IP="__NODE_IP__"
  else
    die "could not determine node IP (use --node-ip)"
  fi
fi
log "node IP: ${NODE_IP}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# ---------------------------------------------------------------------------
# Health-wait helpers
# ---------------------------------------------------------------------------
wait_ready() {
  # wait_ready <description> <kubectl args...>
  local desc="$1"; shift
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] wait: ${desc} (kubectl $*)"
    return 0
  fi
  log "waiting for ${desc} ..."
  local deadline=$(( $(date +%s) + 900 ))
  until remote_kubectl "$@" >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
      die "timed out waiting for ${desc}"
    fi
    sleep 10
  done
  log "${desc}: ready"
}

# ---------------------------------------------------------------------------
# 1. Node preparation (skipped in --update mode)
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE}" != "1" ]]; then
  log "installing Teknoir Root CA on the node"
  ssh_sudo_write "${CA_FILE}" "/etc/rancher/k3s/teknoir-root-ca.crt" 0644
  ssh_sudo_write "${CA_FILE}" "/usr/local/share/ca-certificates/teknoir-root-ca.crt" 0644
  ssh_run "command -v update-ca-certificates >/dev/null 2>&1 && sudo update-ca-certificates || echo 'update-ca-certificates not available, skipped'"

  log "installing K3s registry mirrors (registries.yaml)"
  ssh_sudo_write "${REGISTRIES_FILE}" "/etc/rancher/k3s/registries.yaml" 0644

  log "updating /etc/hosts (idempotent marker block)"
  hosts_block="${tmpdir}/hosts-block"
  {
    echo "# BEGIN teknoir-airgap (managed by bootstrap-airgap.sh)"
    echo "${NODE_IP} ${TEKNOIR_HOSTNAMES[*]}"
    echo "# END teknoir-airgap"
  } > "${hosts_block}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] replace marker block in /etc/hosts with: ${NODE_IP} ${TEKNOIR_HOSTNAMES[*]}"
  else
    ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
      "sudo sed -i '/# BEGIN teknoir-airgap/,/# END teknoir-airgap/d' /etc/hosts && sudo tee -a /etc/hosts >/dev/null" \
      < "${hosts_block}"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Bootstrap image tarballs -> <data-dir>/agent/images/ (imported on k3s start)
# ---------------------------------------------------------------------------
log "copying bootstrap image tarballs to ${K3S_IMAGES_DIR}/"
shopt -s nullglob
tarballs=("${BUNDLE}/bootstrap/images/"*.tar)
shopt -u nullglob
if [[ ${#tarballs[@]} -eq 0 ]]; then
  warn "no image tarballs found in ${BUNDLE}/bootstrap/images/ (run collect-images.sh)"
fi
for t in "${tarballs[@]}"; do
  ssh_sudo_write "${t}" "${K3S_IMAGES_DIR}/$(basename "${t}")" 0644
done

log "restarting k3s to re-import images and pick up registries.yaml"
ssh_run "sudo systemctl restart k3s"
wait_ready "k3s node Ready" "wait --for=condition=Ready node --all --timeout=60s"

# ---------------------------------------------------------------------------
# 3. Secrets + coredns-custom -> server manifests dir
# ---------------------------------------------------------------------------
log "copying bootstrap secrets + coredns-custom.yaml to ${K3S_MANIFESTS_DIR}/"
shopt -s nullglob
secret_files=("${BUNDLE}/bootstrap/secrets/"*.yaml)
shopt -u nullglob
if [[ ${#secret_files[@]} -eq 0 ]]; then
  warn "no secret manifests in ${BUNDLE}/bootstrap/secrets/ — first bootstrap will fail without them"
fi
for s in "${secret_files[@]}"; do
  ssh_sudo_write "${s}" "${K3S_MANIFESTS_DIR}/$(basename "${s}")" 0600
done

coredns_rendered="${tmpdir}/coredns-custom.yaml"
sed "s/__NODE_IP__/${NODE_IP}/g" "${COREDNS_FILE}" > "${coredns_rendered}"
ssh_sudo_write "${coredns_rendered}" "${K3S_MANIFESTS_DIR}/teknoir-coredns-custom.yaml" 0644

# ---------------------------------------------------------------------------
# 4. Ordered bootstrap manifests with health waits between tiers
# ---------------------------------------------------------------------------
MANIFESTS_SRC="${BUNDLE}/bootstrap/manifests"

log "tier 1/3: istio (00-teknoir-istio.yaml)"
[[ -f "${MANIFESTS_SRC}/00-teknoir-istio.yaml" ]] || die "missing ${MANIFESTS_SRC}/00-teknoir-istio.yaml"
ssh_sudo_write "${MANIFESTS_SRC}/00-teknoir-istio.yaml" "${K3S_MANIFESTS_DIR}/00-teknoir-istio.yaml" 0644
wait_ready "istiod" "-n istio-system rollout status deployment/istiod --timeout=30s"
wait_ready "istio-ingressgateway" "-n istio-system rollout status deployment/istio-ingressgateway --timeout=30s"

log "tier 2/3: argocd (10-teknoir-argo.yaml)"
[[ -f "${MANIFESTS_SRC}/10-teknoir-argo.yaml" ]] || die "missing ${MANIFESTS_SRC}/10-teknoir-argo.yaml"
ssh_sudo_write "${MANIFESTS_SRC}/10-teknoir-argo.yaml" "${K3S_MANIFESTS_DIR}/10-teknoir-argo.yaml" 0644
wait_ready "argocd server" "-n teknoir-system wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-server --timeout=30s"

log "tier 3/3: harbor (20-teknoir-harbor.yaml)"
[[ -f "${MANIFESTS_SRC}/20-teknoir-harbor.yaml" ]] || die "missing ${MANIFESTS_SRC}/20-teknoir-harbor.yaml"
ssh_sudo_write "${MANIFESTS_SRC}/20-teknoir-harbor.yaml" "${K3S_MANIFESTS_DIR}/20-teknoir-harbor.yaml" 0644
wait_ready "harbor pods" "-n teknoir-system wait --for=condition=Ready pod -l app=harbor --timeout=30s"

# STRICT mTLS sanity: every harbor pod must carry an istio-proxy sidecar
if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] verify harbor pods have istio-proxy containers"
else
  log "verifying harbor pods carry istio-proxy sidecars"
  pods_without_sidecar="$(remote_kubectl_query \
    "-n teknoir-system get pods -l app=harbor -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.containers[*].name}{\"\\n\"}{end}'" \
    | awk '!/istio-proxy/{print $1}')"
  if [[ -n "${pods_without_sidecar}" ]]; then
    die "harbor pods missing istio-proxy sidecar (STRICT mTLS will fail): ${pods_without_sidecar}"
  fi
  log "all harbor pods have istio-proxy sidecars"
fi

log "bootstrap complete — next: push-to-harbor.sh, then deploy-app-of-apps.sh"
