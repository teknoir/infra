#!/usr/bin/env bash
# bootstrap-airgap.sh — first-time bootstrap of the air-gapped K3s node
# (LAN-laptop side, everything over ssh to $TEKNOIR_HOST).
#
# Flow:
#   CA + registries.yaml + /etc/hosts + bootstrap image tarballs -> restart k3s
#   static single-owner manifests (namespaces, CRDs, argo, read-only secrets,
#   app-of-apps, coredns-custom) -> K3s server manifests dir (K3s owns them)
#   adopted resources (wildcard TLS secret, istio, harbor) -> one-shot
#   `kubectl apply` over ssh, with health waits, so K3s never re-applies them.
#
# Usage: airgap/bootstrap-airgap.sh [--bundle DIR] [--host user@host]
#                                   [--ssh-key FILE] [--node-ip IP]
#                                   [--update] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR     bundle directory (default: $(bundle_dir))
  --host H         ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE   ssh identity file, e.g. .secrets/teknoir.airgapped.id_rsa
                   (default: \$SSH_KEY, else auto-detected [${SSH_KEY:-none}])
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
    --ssh-key) SSH_KEY="$2"; shift ;;
    --node-ip) NODE_IP="$2"; shift ;;
    --update) UPDATE_MODE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh
apply_ssh_key

# Preflight: fail early with a clear hint instead of a mid-run
# "Permission denied (publickey)" (the node only accepts publickey auth).
if [[ "${DRY_RUN}" != "1" ]] && ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${TEKNOIR_HOST}" true 2>/dev/null; then
  die "cannot ssh to ${TEKNOIR_HOST}${SSH_KEY:+ with key ${SSH_KEY}} — provide the node's private key via --ssh-key FILE or SSH_KEY=FILE (e.g. .secrets/teknoir.airgapped.id_rsa, auto-detected when present)"
fi

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

# Rendered bootstrap outputs (relative to the bundle):
#   manifests/ — K3s-owned static resources (copied into the manifests dir)
#   apply/     — one-shot adopted resources (kubectl apply, never in manifests dir)
#   secrets/   — secret manifests (read-only -> manifests dir, wildcard -> one-shot)
MANIFESTS_SRC="${BUNDLE}/bootstrap/manifests"
APPLY_SRC="${BUNDLE}/bootstrap/apply"
SECRETS_SRC="${BUNDLE}/bootstrap/secrets"

NAMESPACES_FILE="${MANIFESTS_SRC}/00-teknoir-namespaces.yaml"
ISTIO_CRDS_FILE="${MANIFESTS_SRC}/00-teknoir-istio-crds.yaml"
CERTMANAGER_CRDS_FILE="${MANIFESTS_SRC}/05-teknoir-certmanager-crds.yaml"
ARGO_FILE="${MANIFESTS_SRC}/10-teknoir-argo.yaml"
APP_OF_APPS_FILE="${MANIFESTS_SRC}/app-of-apps.yaml"
ISTIO_APPLY_FILE="${APPLY_SRC}/istio.yaml"
HARBOR_APPLY_FILE="${APPLY_SRC}/harbor.yaml"
WILDCARD_SECRET_FILE="${SECRETS_SRC}/manifest-wildcard-tls-secret.yaml"

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

wait_images_imported() {
  # wait_images_imported <image-ref...>
  #
  # k3s imports agent/images/*.tar ASYNCHRONOUSLY, after the node already
  # reports Ready. Deploying the istio tier before proxyv2 finished importing
  # makes the injected gateway pods (image: auto) fall through to a registry
  # pull; during bootstrap Harbor is not up yet, so that pull is refused and the
  # gateways get stuck in ImagePullBackOff. Block until every expected bootstrap
  # image is present in containerd's k8s.io namespace.
  local expected=("$@")
  (( ${#expected[@]} > 0 )) || return 0
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] wait for ${#expected[@]} bootstrap images to import into containerd"
    return 0
  fi
  log "waiting for ${#expected[@]} bootstrap images to import into containerd ..."
  local deadline=$(( $(date +%s) + 900 ))
  local present ref missing
  while :; do
    present="$(ssh_query "sudo k3s ctr -n k8s.io images ls -q" 2>/dev/null || true)"
    missing=()
    for ref in "${expected[@]}"; do
      grep -qxF -- "${ref}" <<<"${present}" || missing+=("${ref}")
    done
    (( ${#missing[@]} == 0 )) && break
    if (( $(date +%s) > deadline )); then
      die "timed out waiting for bootstrap images to import: ${missing[*]}"
    fi
    sleep 10
  done
  log "all bootstrap images imported"
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

# Expected image refs (RepoTags read from each docker-archive tarball) so we can
# wait for k3s to finish importing them before deploying manifests that consume
# them (see wait_images_imported). Tarballs without a parseable RepoTag are
# simply not waited on.
expected_images=()
while IFS= read -r _ref; do
  [[ -n "${_ref}" ]] && expected_images+=("${_ref}")
done < <(
  for t in "${tarballs[@]}"; do
    tar -xOf "${t}" manifest.json 2>/dev/null || true
  done | tr ',' '\n' | sed -n 's/.*"RepoTags":\["\([^"]*\)".*/\1/p'
)
unset _ref

log "restarting k3s to re-import images and pick up registries.yaml"
ssh_run "sudo systemctl restart k3s"
wait_ready "k3s node Ready" "wait --for=condition=Ready node --all --timeout=60s"
wait_images_imported "${expected_images[@]}"

# ---------------------------------------------------------------------------
# 3. Static single-owner manifests -> K3s server manifests dir
#    (K3s owns these: namespaces, CRDs, ArgoCD, read-only secrets, app-of-apps,
#    coredns-custom). Adopted resources (istio, harbor, wildcard secret) are
#    deliberately NOT placed here — they are one-shot applied in §4.
# ---------------------------------------------------------------------------
log "copying static bootstrap manifests to ${K3S_MANIFESTS_DIR}/"

# Untracked, K3s-owned bootstrap tier: namespaces first, then CRDs, ArgoCD,
# then app-of-apps (its Application references ArgoCD's CRDs from 10-teknoir-argo.yaml).
for f in "${NAMESPACES_FILE}" "${ISTIO_CRDS_FILE}" "${CERTMANAGER_CRDS_FILE}" \
         "${ARGO_FILE}" "${APP_OF_APPS_FILE}"; do
  [[ -f "${f}" ]] || die "missing ${f}"
  ssh_sudo_write "${f}" "${K3S_MANIFESTS_DIR}/$(basename "${f}")" 0644
done

# Read-only secrets (all except the cert-manager-owned wildcard TLS secret,
# which is one-shot applied in §4) stay K3s-owned in the manifests dir. Their
# namespaces are created first by 00-teknoir-namespaces.yaml above.
shopt -s nullglob
secret_files=("${SECRETS_SRC}/"*.yaml)
shopt -u nullglob
if [[ ${#secret_files[@]} -eq 0 ]]; then
  warn "no secret manifests in ${SECRETS_SRC} — first bootstrap will fail without them"
fi
for s in "${secret_files[@]}"; do
  [[ "$(basename "${s}")" == "manifest-wildcard-tls-secret.yaml" ]] && continue
  ssh_sudo_write "${s}" "${K3S_MANIFESTS_DIR}/$(basename "${s}")" 0600
done

coredns_rendered="${tmpdir}/coredns-custom.yaml"
sed "s/__NODE_IP__/${NODE_IP}/g" "${COREDNS_FILE}" > "${coredns_rendered}"
ssh_sudo_write "${coredns_rendered}" "${K3S_MANIFESTS_DIR}/teknoir-coredns-custom.yaml" 0644

# ---------------------------------------------------------------------------
# 4. One-shot handover: adopted resources applied once over ssh, never by K3s
# ---------------------------------------------------------------------------
# These resources are applied with `kubectl apply -f -` (streamed via stdin, no
# temp files on the node) so they never land in the manifests dir and K3s never
# re-applies them. The istio/harbor resources carry ArgoCD v3 tracking-ids and
# are adopted by their ArgoCD Applications; the wildcard secret is adopted by
# cert-manager.

apply_once() {
  # apply_once <local-manifest> — stream a manifest to the node and
  # `kubectl apply -f -` it (one-shot; leaves no temp file on the node).
  local src="$1"
  [[ -f "${src}" ]] || die "missing ${src}"
  log "one-shot apply: $(basename "${src}")"
  remote_kubectl apply -f - < "${src}"
}

# a. Namespaces must exist before any secret/CR apply. K3s applies the manifests
#    dir asynchronously (sorted by filename), so 00-teknoir-namespaces.yaml is
#    first — wait for each one before proceeding.
for ns in istio-system teknoir-system cert-manager teknoir-auth; do
  wait_ready "namespace ${ns}" "get namespace ${ns}"
done

# b. Wildcard TLS secret (bootstrap placeholder; cert-manager replaces it on
#    first issuance).
apply_once "${WILDCARD_SECRET_FILE}"

# c. Istio CRDs must be Established before istio CRs can be applied.
wait_ready "istio CRDs Established" "wait --for=condition=Established crd/virtualservices.networking.istio.io --timeout=60s"

# d. Istio resources (adopted by the `istio` ArgoCD Application).
apply_once "${ISTIO_APPLY_FILE}"

# e. Istio control plane + ingress gateway ready.
wait_ready "istiod" "-n istio-system rollout status deployment/istiod --timeout=30s"
wait_ready "istio-ingressgateway" "-n istio-system rollout status deployment/istio-ingressgateway --timeout=30s"

# f. ArgoCD server ready (10-teknoir-argo.yaml is K3s-applied from §3).
wait_ready "argocd server" "-n teknoir-system wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-server --timeout=30s"

# g. Harbor resources (adopted by the `harbor` ArgoCD Application).
apply_once "${HARBOR_APPLY_FILE}"

# h. Harbor pods ready.
wait_ready "harbor pods" "-n teknoir-system wait --for=condition=Ready pod -l app=harbor --timeout=30s"

# STRICT mTLS sanity: every harbor pod must carry an istio-proxy sidecar
if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] verify harbor pods have istio-proxy containers"
else
  log "verifying harbor pods carry istio-proxy sidecars"
  # Istio 1.29+ injects the sidecar as a native (Kubernetes) sidecar, i.e. an
  # initContainer with restartPolicy: Always — so istio-proxy shows up under
  # .spec.initContainers, not .spec.containers. Check both to stay compatible
  # with legacy (container) and native (initContainer) sidecar injection.
  pods_without_sidecar="$(remote_kubectl_query \
    "-n teknoir-system get pods -l app=harbor -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.spec.containers[*].name}{\" \"}{.spec.initContainers[*].name}{\"\\n\"}{end}'" \
    | awk '!/istio-proxy/{print $1}')"
  if [[ -n "${pods_without_sidecar}" ]]; then
    die "harbor pods missing istio-proxy sidecar (STRICT mTLS will fail): ${pods_without_sidecar}"
  fi
  log "all harbor pods have istio-proxy sidecars"
fi

log "bootstrap complete — app-of-apps.yaml is K3s-managed; next: push-to-harbor.sh"
