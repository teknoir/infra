#!/usr/bin/env bash
# deploy-app-of-apps.sh — copy the bundle's app-of-apps.yaml into the K3s
# server manifests dir over ssh (LAN-laptop side). The K3s deploy controller
# applies it; ArgoCD then adopts istio + harbor and syncs the GitOps tier
# from oci://harbor.teknoir.airgapped/teknoir.
#
# Usage: airgap/deploy-app-of-apps.sh [--bundle DIR] [--host user@host] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR   bundle directory (default: $(bundle_dir))
  --host H       ssh target (default: ${TEKNOIR_HOST})
  --dry-run      print actions without mutating the node
  -h, --help     show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh

BUNDLE="$(bundle_dir)"
SRC="${BUNDLE}/bootstrap/manifests/app-of-apps.yaml"
DST="${K3S_DATA_DIR}/server/manifests/teknoir-app-of-apps.yaml"

[[ -f "${SRC}" ]] || die "missing ${SRC} (run render-bootstrap.sh / make-bundle.sh)"

log "deploying app-of-apps to ${TEKNOIR_HOST}:${DST}"
ssh_sudo_write "${SRC}" "${DST}" 0644

if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] would verify Application app-of-apps exists in teknoir-system"
else
  log "app-of-apps deployed — verify with: ssh ${TEKNOIR_HOST} sudo k3s kubectl -n teknoir-system get applications"
fi
