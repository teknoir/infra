#!/usr/bin/env bash
# bootstrap-airgap.sh — bootstrap the air-gapped K3s node, or update its
# bootstrap tier (LAN-laptop side, everything over ssh to $TEKNOIR_HOST).
#
# First bootstrap (default):
#   1. node: Teknoir Root CA, registries.yaml, /etc/hosts marker block
#   2. bootstrap image tarballs -> agent/images; K3s is restarted only when
#      something in 1-2 changed (or --restart-k3s), then the images are awaited
#   3. K3s-owned manifests (lib.sh:k3s_deploy, canonical single-owner names):
#      namespaces, istio + cert-manager CRDs, coredns-custom
#   4. bundle secrets (scripts/deploy-secrets.sh --secrets-dir --create-only:
#      only Secrets that do not exist yet, incl. the wildcard TLS placeholder)
#   5. istio resources, one-shot `kubectl apply` -> wait istiod + gateway
#   6. teknoir-argo.yaml -> wait Application CRD Established + argocd-server
#   7. harbor resources, one-shot `kubectl apply` -> wait pods + sidecars
#   8. teknoir-app-of-apps.yaml (ArgoCD syncs once push-to-harbor.sh ran)
#   The one-shot istio/harbor resources are adopted by their ArgoCD
#   Applications; once an Application exists the one-shot apply is skipped,
#   so a re-run never reverts what ArgoCD owns (--reapply-adopted overrides,
#   for disaster recovery only).
#
# --update (live cluster, bootstrap tier changed): steps 2, 3 and 6 only.
#   Node files, secrets (scripts/deploy-secrets.sh deploys them from the
#   operator's .secrets/; the bundle copy may be stale), the one-shot
#   resources and app-of-apps (update-airgap.sh) are left alone.
#
# Every step is idempotent: unchanged node files and tarballs are not
# rewritten, unchanged manifests are not re-applied by K3s.
#
# Usage: airgap/bootstrap-airgap.sh [--bundle DIR] [--host user@host]
#                                   [--ssh-key FILE] [--node-ip IP] [--update]
#                                   [--restart-k3s] [--reapply-adopted] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR       bundle directory (default: $(bundle_dir))
  --host H           ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE     ssh identity file, e.g. .secrets/teknoir.airgapped.id_rsa
                     (default: \$SSH_KEY, else auto-detected [${SSH_KEY:-none}])
  --node-ip IP       node IP for /etc/hosts + coredns-custom
                     (default: NODE_IP from versions.env [${NODE_IP:-unset}], else auto-detect over ssh)
  --update           live cluster: only image tarballs, K3s-owned bootstrap
                     manifests (namespaces, istio/cert-manager CRDs,
                     coredns-custom) and ArgoCD
  --restart-k3s      restart K3s even if no tarball/node file changed
  --reapply-adopted  first bootstrap: re-apply the one-shot istio/harbor
                     resources even though ArgoCD already owns them
                     (disaster recovery only)
  --dry-run          print every action without mutating the node
                     (read-only ssh queries still run)
  -h, --help         show this help

Paths on the node (K3S_DATA_DIR=${K3S_DATA_DIR}):
  image tarballs:   ${K3S_DATA_DIR}/agent/images/
  manifests:        ${K3S_DATA_DIR}/server/manifests/
EOF
}

UPDATE_MODE=0
RESTART_K3S=0
REAPPLY_ADOPTED=0
NODE_IP="${NODE_IP:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --node-ip) NODE_IP="$2"; shift ;;
    --update) UPDATE_MODE=1 ;;
    --restart-k3s) RESTART_K3S=1 ;;
    --reapply-adopted) REAPPLY_ADOPTED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh tar
apply_ssh_key

# Preflight: fail early with a clear hint instead of a mid-run
# "Permission denied (publickey)" (the node only accepts publickey auth).
if [[ "${DRY_RUN}" != "1" ]] && ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${TEKNOIR_HOST}" true 2>/dev/null; then
  die "cannot ssh to ${TEKNOIR_HOST}${SSH_KEY:+ with key ${SSH_KEY}} — provide the node's private key via --ssh-key FILE or SSH_KEY=FILE (e.g. .secrets/teknoir.airgapped.id_rsa, auto-detected when present)"
fi

BUNDLE="$(bundle_dir)"
K3S_IMAGES_DIR="${K3S_DATA_DIR}/agent/images"

[[ -d "${BUNDLE}/bootstrap" ]] || die "bundle not found or incomplete: ${BUNDLE} (run make-bundle.sh)"
CA_FILE="${BUNDLE}/bootstrap/k3s/teknoir-root-ca.crt"
REGISTRIES_FILE="${BUNDLE}/bootstrap/k3s/registries.yaml"
COREDNS_FILE="${BUNDLE}/bootstrap/k3s/coredns-custom.yaml"
[[ -f "${CA_FILE}" ]] || die "missing ${CA_FILE}"
[[ -f "${REGISTRIES_FILE}" ]] || die "missing ${REGISTRIES_FILE}"
[[ -f "${COREDNS_FILE}" ]] || die "missing ${COREDNS_FILE}"

# Rendered bootstrap outputs (relative to the bundle):
#   manifests/ — K3s-owned static resources, named as in the manifests dir
#   apply/     — one-shot adopted resources (kubectl apply, never in manifests dir)
#   secrets/   — secret manifests from scripts/gen-*.sh (first bootstrap only)
MANIFESTS_SRC="${BUNDLE}/bootstrap/manifests"
APPLY_SRC="${BUNDLE}/bootstrap/apply"
SECRETS_SRC="${BUNDLE}/bootstrap/secrets"

NAMESPACES_FILE="${MANIFESTS_SRC}/00-teknoir-namespaces.yaml"
ISTIO_CRDS_FILE="${MANIFESTS_SRC}/00-teknoir-istio-crds.yaml"
CERTMANAGER_CRDS_FILE="${MANIFESTS_SRC}/05-teknoir-certmanager-crds.yaml"
ARGO_FILE="${MANIFESTS_SRC}/teknoir-argo.yaml"
ISTIO_APPLY_FILE="${APPLY_SRC}/istio.yaml"
HARBOR_APPLY_FILE="${APPLY_SRC}/harbor.yaml"
for f in "${NAMESPACES_FILE}" "${ISTIO_CRDS_FILE}" "${CERTMANAGER_CRDS_FILE}" "${ARGO_FILE}"; do
  [[ -f "${f}" ]] || die "missing ${f} (re-run render-bootstrap.sh / make-bundle.sh)"
done

# Delegated scripts get the same target, key and dry-run mode.
DELEGATE_ARGS=(--host "${TEKNOIR_HOST}")
[[ "${DRY_RUN}" == "1" ]] && DELEGATE_ARGS+=(--dry-run)

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
# Helpers
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

missing_images() {
  # missing_images <image-ref...> — print the refs not yet in containerd's k8s.io namespace
  local present ref
  present="$(ssh_query "sudo k3s ctr -n k8s.io images ls -q" 2>/dev/null || true)"
  for ref in "$@"; do
    grep -qxF -- "${ref}" <<<"${present}" || echo "${ref}"
  done
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
  (( $# > 0 )) || return 0
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] wait for $# bootstrap images to import into containerd"
    return 0
  fi
  log "waiting for $# bootstrap images to import into containerd ..."
  local deadline=$(( $(date +%s) + 900 )) missing
  while :; do
    missing="$(missing_images "$@")"
    [[ -z "${missing}" ]] && break
    if (( $(date +%s) > deadline )); then
      die "timed out waiting for bootstrap images to import: $(tr '\n' ' ' <<<"${missing}")"
    fi
    sleep 10
  done
  log "all bootstrap images imported"
}

argocd_owns() {
  # argocd_owns <application> — true when the ArgoCD Application exists, i.e.
  # ArgoCD has adopted that tier and owns its objects from now on.
  [[ "${REAPPLY_ADOPTED}" == "1" ]] && return 1
  remote_kubectl_query "-n teknoir-system get application $1 -o name" >/dev/null 2>&1
}

apply_once() {
  # apply_once <local-manifest> — stream a manifest to the node and
  # `kubectl apply -f -` it (one-shot; leaves no file on the node).
  local src="$1"
  [[ -f "${src}" ]] || die "missing ${src}"
  log "one-shot apply: $(basename "${src}")"
  remote_kubectl apply -f - < "${src}"
}

restart_needed="${RESTART_K3S}"

# ---------------------------------------------------------------------------
# 1. Node preparation (first bootstrap only)
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE}" != "1" ]]; then
  log "Teknoir Root CA on the node"
  if ssh_sync_file "${CA_FILE}" "/etc/rancher/k3s/teknoir-root-ca.crt" 0644; then
    restart_needed=1
  fi
  if ssh_sync_file "${CA_FILE}" "/usr/local/share/ca-certificates/teknoir-root-ca.crt" 0644; then
    ssh_run "command -v update-ca-certificates >/dev/null 2>&1 && sudo update-ca-certificates || echo 'update-ca-certificates not available, skipped'"
  fi

  log "K3s registry mirrors (registries.yaml)"
  if ssh_sync_file "${REGISTRIES_FILE}" "/etc/rancher/k3s/registries.yaml" 0644; then
    restart_needed=1
  fi

  log "/etc/hosts marker block"
  hosts_block="${tmpdir}/hosts-block"
  {
    echo "# BEGIN teknoir-airgap (managed by bootstrap-airgap.sh)"
    echo "${NODE_IP} ${TEKNOIR_HOSTNAMES[*]}"
    echo "# END teknoir-airgap"
  } > "${hosts_block}"
  current_block="$(ssh_query "sed -n '/# BEGIN teknoir-airgap/,/# END teknoir-airgap/p' /etc/hosts" 2>/dev/null || true)"
  if [[ "${current_block}" == "$(cat "${hosts_block}")" ]]; then
    log "/etc/hosts block unchanged"
  elif [[ "${DRY_RUN}" == "1" ]]; then
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
shopt -s nullglob
tarballs=("${BUNDLE}/bootstrap/images/"*.tar)
shopt -u nullglob
if [[ ${#tarballs[@]} -eq 0 ]]; then
  warn "no image tarballs found in ${BUNDLE}/bootstrap/images/ (run collect-images.sh)"
fi
log "syncing ${#tarballs[@]} bootstrap image tarball(s) to ${K3S_IMAGES_DIR}/ (changed ones only)"
for t in ${tarballs[@]+"${tarballs[@]}"}; do
  if ssh_sync_file "${t}" "${K3S_IMAGES_DIR}/$(basename "${t}")" 0644; then
    log "  updated $(basename "${t}")"
    restart_needed=1
  fi
done

# Expected image refs (RepoTags read from each docker-archive tarball), to wait
# for k3s to finish importing them before deploying manifests that consume
# them (see wait_images_imported). Tarballs without a parseable RepoTag are
# simply not waited on.
expected_images=()
while IFS= read -r _ref; do
  [[ -n "${_ref}" ]] && expected_images+=("${_ref}")
done < <(
  for t in ${tarballs[@]+"${tarballs[@]}"}; do
    tar -xOf "${t}" manifest.json 2>/dev/null || true
  done | tr ',' '\n' | sed -n 's/.*"RepoTags":\["\([^"]*\)".*/\1/p'
)
unset _ref

if [[ "${restart_needed}" == "1" ]]; then
  log "restarting k3s (re-imports image tarballs, reloads registries.yaml + CA)"
  ssh_run "sudo systemctl restart k3s"
  wait_ready "k3s node Ready" "wait --for=condition=Ready node --all --timeout=60s"
  wait_images_imported ${expected_images[@]+"${expected_images[@]}"}
else
  log "no tarball or node file changed — k3s not restarted"
  not_imported="$(missing_images ${expected_images[@]+"${expected_images[@]}"})"
  [[ -z "${not_imported}" ]] \
    || warn "bootstrap images not in containerd (re-run with --restart-k3s to re-import): $(tr '\n' ' ' <<<"${not_imported}")"
fi

# ---------------------------------------------------------------------------
# 3. K3s-owned bootstrap manifests (namespaces, istio + cert-manager CRDs,
#    coredns-custom). k3s_deploy waits until K3s applied each one, so the
#    namespaces exist before any secret and the CRDs before any istio object.
# ---------------------------------------------------------------------------
log "K3s-owned bootstrap manifests -> ${K3S_MANIFESTS_DIR}/"
k3s_deploy "${NAMESPACES_FILE}"
k3s_deploy "${ISTIO_CRDS_FILE}"
k3s_deploy "${CERTMANAGER_CRDS_FILE}"

coredns_rendered="${tmpdir}/teknoir-coredns-custom.yaml"
sed "s/__NODE_IP__/${NODE_IP}/g" "${COREDNS_FILE}" > "${coredns_rendered}"
k3s_deploy "${coredns_rendered}"

# ---------------------------------------------------------------------------
# 4-5. First bootstrap: secrets, then the one-shot istio tier
# ---------------------------------------------------------------------------
if [[ "${UPDATE_MODE}" != "1" ]]; then
  log "bundle secrets -> K3s manifests (only Secrets that do not exist yet)"
  "${REPO_ROOT}/scripts/deploy-secrets.sh" --secrets-dir "${SECRETS_SRC}" --create-only --bootstrap-wildcard \
    "${DELEGATE_ARGS[@]}"

  if argocd_owns istio; then
    log "ArgoCD Application istio exists — it owns the istio resources; skipping the one-shot apply"
  else
    wait_ready "istio CRDs Established" "wait --for=condition=Established crd/virtualservices.networking.istio.io --timeout=60s"
    apply_once "${ISTIO_APPLY_FILE}"
  fi
  wait_ready "istiod" "-n istio-system rollout status deployment/istiod --timeout=30s"
  wait_ready "istio-ingressgateway" "-n istio-system rollout status deployment/istio-ingressgateway --timeout=30s"
fi

# ---------------------------------------------------------------------------
# 6. ArgoCD (K3s-owned teknoir-argo.yaml; after istio so its pods get sidecars)
# ---------------------------------------------------------------------------
log "ArgoCD -> ${K3S_MANIFESTS_DIR}/teknoir-argo.yaml"
k3s_deploy "${ARGO_FILE}"
wait_ready "Application CRD Established" "wait --for=condition=Established crd/applications.argoproj.io --timeout=60s"
wait_ready "argocd server" "-n teknoir-system wait --for=condition=Available deployment -l app.kubernetes.io/name=argocd-server --timeout=30s"

if [[ "${UPDATE_MODE}" == "1" ]]; then
  log "bootstrap tier updated (secrets: scripts/deploy-secrets.sh; app-of-apps: airgap/update-airgap.sh)"
  exit 0
fi

# ---------------------------------------------------------------------------
# 7. Harbor (one-shot, adopted by the ArgoCD `harbor` Application)
# ---------------------------------------------------------------------------
if argocd_owns harbor; then
  log "ArgoCD Application harbor exists — it owns the harbor resources; skipping the one-shot apply"
else
  [[ -f "${HARBOR_APPLY_FILE}" ]] \
    || die "missing ${HARBOR_APPLY_FILE}: this bundle cannot bootstrap Harbor (render-bootstrap.sh had no source for the pinned harbor chart)"
  apply_once "${HARBOR_APPLY_FILE}"
fi
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

# ---------------------------------------------------------------------------
# 8. Root app-of-apps (Application CRD is Established since step 6). ArgoCD
#    retries until push-to-harbor.sh has uploaded the charts.
# ---------------------------------------------------------------------------
"${AIRGAP_DIR}/deploy-app-of-apps.sh" --bundle "${BUNDLE}" "${DELEGATE_ARGS[@]}"

log "bootstrap complete — next: push-to-harbor.sh, then scripts/deploy-secrets.sh (switches ArgoCD to the robot credential)"
