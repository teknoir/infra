#!/usr/bin/env bash
# deploy-app-of-apps.sh — install the root app-of-apps (AppProject `default` +
# Application `app-of-apps`, chart app-of-apps from
# oci://harbor.teknoir.airgapped/teknoir) on the node as the K3s auto-deploy
# manifest teknoir-app-of-apps.yaml (LAN-laptop side, over ssh).
#
# That file is the only owner of the two objects: the legacy duplicate
# app-of-apps.yaml (older bootstrap) is retired once teknoir-app-of-apps owns
# both (airgap/lib.sh:k3s_deploy), so a stale copy can never flip
# targetRevision or the sync policy back. The whole file is always redeployed,
# never patched in place on the node. Re-running with unchanged content is a
# no-op.
#
# Source: the bundle's bootstrap/manifests/teknoir-app-of-apps.yaml, else this
# checkout's teknoir-local-app-of-apps.yaml. --revision deploys it with another
# app-of-apps chart version (update or rollback; see update-airgap.sh).
#
# Usage: airgap/deploy-app-of-apps.sh [--bundle DIR] [--revision V] [--refresh]
#                                     [--host user@host] [--ssh-key FILE] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR    bundle directory (default: $(bundle_dir))
  --revision V    app-of-apps chart version to deploy (default: the manifest's)
  --refresh       also ask ArgoCD to refresh the Application right away
  --host H        ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE  ssh identity file, e.g. .secrets/teknoir.airgapped.id_rsa
                  (default: \$SSH_KEY, else auto-detected [${SSH_KEY:-none}])
  --dry-run       print actions without mutating the node
  -h, --help      show this help
EOF
}

REVISION=""
REFRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --revision) REVISION="$2"; shift ;;
    --refresh) REFRESH=1 ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh
apply_ssh_key

SRC=""
for candidate in "$(bundle_dir)/bootstrap/manifests/teknoir-app-of-apps.yaml" \
                 "${REPO_ROOT}/teknoir-local-app-of-apps.yaml"; do
  if [[ -f "${candidate}" ]]; then SRC="${candidate}"; break; fi
done
[[ -n "${SRC}" ]] || die "no app-of-apps manifest in $(bundle_dir)/bootstrap/manifests/ or ${REPO_ROOT} (run make-bundle.sh)"

[[ "$(grep -cE '^[[:space:]]*targetRevision:' "${SRC}")" == "1" ]] \
  || die "expected exactly one targetRevision in ${SRC}"
current="$(awk '/^[[:space:]]*targetRevision:/{print $2; exit}' "${SRC}")"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
# The basename is the K3s manifest name (k3s_canonical_name).
manifest="${tmpdir}/teknoir-app-of-apps.yaml"
if [[ -n "${REVISION}" && "${REVISION}" != "${current}" ]]; then
  [[ "${REVISION}" =~ ^[0-9A-Za-z._+-]+$ ]] || die "invalid revision: ${REVISION}"
  sed -E "s|^([[:space:]]*targetRevision:).*|\\1 ${REVISION}|" "${SRC}" > "${manifest}"
  log "app-of-apps targetRevision ${current} -> ${REVISION} (source: ${SRC})"
else
  cp "${SRC}" "${manifest}"
  log "app-of-apps targetRevision ${current} (source: ${SRC})"
fi

k3s_deploy "${manifest}"

if [[ "${REFRESH}" == "1" ]]; then
  remote_kubectl "-n teknoir-system annotate application app-of-apps argocd.argoproj.io/refresh=normal --overwrite" >/dev/null
fi

# Read-only summary of what the cluster now runs.
live="$(remote_kubectl_query "-n teknoir-system get application app-of-apps -o jsonpath='{.spec.source.targetRevision} automated={.spec.syncPolicy.automated.enabled} sync={.status.sync.status} health={.status.health.status}'" 2>/dev/null || true)"
log "live Application app-of-apps: ${live:-not found}"
log "monitor: ssh ${TEKNOIR_HOST} sudo k3s kubectl -n teknoir-system get applications"
