#!/usr/bin/env bash
# update-airgap.sh — roll the platform to a new app-of-apps chart version
# after push-to-harbor.sh has uploaded the updated charts/images (LAN side).
#
# Because app-of-apps is managed by the K3s deploy controller (a file in
# <data-dir>/server/manifests/), the targetRevision is patched *in that file*
# on the node (a live `kubectl patch` alone would be reverted by the deploy
# controller). The controller re-applies the change; ArgoCD then syncs the new
# chart versions from Harbor. Chart-only updates need nothing else.
#
# Usage: airgap/update-airgap.sh [--host user@host] [--ssh-key FILE] [--bundle DIR] [--dry-run] <new-target-revision>
#        airgap/update-airgap.sh --from-bundle [--bundle DIR] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <new-target-revision>
       $(basename "$0") --from-bundle [options]

Patches the app-of-apps targetRevision on the node (chart-only update path,
run after push-to-harbor.sh).

Options:
  --from-bundle  instead of patching, re-copy the bundle's app-of-apps.yaml
                 (delegates to deploy-app-of-apps.sh)
  --host H       ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE ssh identity file, e.g. .secrets/teknoir.airgapped.id_rsa
                 (default: \$SSH_KEY, else auto-detected [${SSH_KEY:-none}])
  --bundle DIR   bundle directory (default: $(bundle_dir))
  --dry-run      print actions without mutating the node
  -h, --help     show this help
EOF
}

FROM_BUNDLE=0
NEW_REVISION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-bundle) FROM_BUNDLE=1 ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown argument: $1 (see --help)" ;;
    *)
      [[ -z "${NEW_REVISION}" ]] || die "unexpected extra argument: $1"
      NEW_REVISION="$1"
      ;;
  esac
  shift
done

require_cmd ssh
apply_ssh_key

MANIFEST_ON_NODE="${K3S_DATA_DIR}/server/manifests/teknoir-app-of-apps.yaml"

if [[ "${FROM_BUNDLE}" == "1" ]]; then
  log "re-deploying app-of-apps.yaml from the bundle"
  args=()
  if [[ "${DRY_RUN}" == "1" ]]; then
    args+=(--dry-run)
  fi
  exec "${AIRGAP_DIR}/deploy-app-of-apps.sh" "${args[@]}" \
    --bundle "$(bundle_dir)" --host "${TEKNOIR_HOST}"
fi

[[ -n "${NEW_REVISION}" ]] || { usage; die "missing <new-target-revision> (or use --from-bundle)"; }

log "patching targetRevision -> ${NEW_REVISION} in ${MANIFEST_ON_NODE}"
ssh_run "test -f '${MANIFEST_ON_NODE}'" \
  || die "app-of-apps manifest not found on node: ${MANIFEST_ON_NODE} (run deploy-app-of-apps.sh first)"
ssh_run "sudo sed -i -E 's|^(\\s*targetRevision:).*|\\1 ${NEW_REVISION}|' '${MANIFEST_ON_NODE}'"

# Belt-and-braces: patch the live Application too so the sync starts
# immediately (the deploy controller keeps the file authoritative).
log "patching live Application app-of-apps (immediate reconcile)"
remote_kubectl "-n teknoir-system patch application app-of-apps --type merge -p '{\"spec\":{\"source\":{\"targetRevision\":\"${NEW_REVISION}\"}}}'" \
  || warn "live patch failed (Application not created yet?) — deploy controller will still apply the file"

if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] update complete (no changes made)"
else
  log "update to ${NEW_REVISION} triggered — monitor: ssh ${TEKNOIR_HOST} sudo k3s kubectl -n teknoir-system get applications"
fi
