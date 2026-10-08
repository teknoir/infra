#!/usr/bin/env bash
# deploy-argo.sh — render this checkout's charts/argo and install it on the
# air-gapped node as the K3s auto-deploy manifest teknoir-argo.yaml.
#
# teknoir-argo.yaml is the only owner of the ArgoCD objects: the legacy
# duplicate 10-teknoir-argo.yaml (older bootstrap) is retired once
# teknoir-argo owns every object (airgap/lib.sh:k3s_deploy). The render is the
# bundle's (airgap/lib.sh:helm_template_chart): teknoir.airgapped values plus
# the Teknoir Root CA in the two trust paths ArgoCD needs —
# argocd-tls-certs-cm (repo-server -> Harbor OCI login) and the oidc.config
# rootCA (argocd-server -> Keycloak discovery). See charts/argo/README.md.
#
# The rendered manifest lives in a temp dir only (or --out FILE). Re-running
# with an unchanged chart is a no-op. From an unpacked bundle (no charts/argo),
# use airgap/bootstrap-airgap.sh --update, which deploys the bundle's render.
#
# ArgoCD manages CRDs, so the deploy is refused until it cannot adopt the
# bootstrap-owned istio / cert-manager CRDs (lib.sh:argocd_crd_gate). If the
# deploy ends the CRD exclusion of an older ArgoCD, the automated syncs that
# failed because of it are re-run (lib.sh:argocd_crd_handover_resync).
#
# Usage: scripts/deploy-argo.sh [--out FILE] [--host user@host]
#                               [--ssh-key FILE] [--skip-crd-gate] [--dry-run]
set -euo pipefail

# shellcheck source=../airgap/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/airgap/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --out FILE      also write the rendered manifest to FILE (for inspection)
  --host H        ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE  ssh identity file (default: \$SSH_KEY, else auto-detected)
  --skip-crd-gate deploy even if lib.sh:argocd_crd_gate refuses
  --dry-run       render, but do not touch the node
  -h, --help      show this help
EOF
}

OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --skip-crd-gate) SKIP_CRD_GATE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

CHART_DIR="${REPO_ROOT}/charts/argo"
[[ -f "${CHART_DIR}/Chart.yaml" ]] \
  || die "${CHART_DIR} not found — from a bundle, deploy ArgoCD with airgap/bootstrap-airgap.sh --update"

require_cmd helm ssh python3
apply_ssh_key

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
# The basename is the K3s manifest name (k3s_canonical_name).
rendered="${tmpdir}/teknoir-argo.yaml"

helm_dep_build "${CHART_DIR}"
helm_template_chart argo "${CHART_DIR}" > "${rendered}"
log "rendered charts/argo: $(grep -c '^kind:' "${rendered}") objects"
if [[ -n "${OUT}" ]]; then
  cp "${rendered}" "${OUT}"
  log "wrote ${OUT}"
fi

argocd_crd_gate crds-live
k3s_deploy "${rendered}"
argocd_crd_handover_resync
log "deploy-argo complete"
