#!/usr/bin/env bash
# update-airgap.sh — roll the platform to an app-of-apps chart version after
# push-to-harbor.sh has uploaded the charts/images (LAN side).
#
# The root Application is owned by the K3s auto-deploy manifest
# teknoir-app-of-apps.yaml, so it is changed by redeploying that whole file
# (the bundle's content with the requested targetRevision) through
# deploy-app-of-apps.sh, never by patching the file or the live object: a
# `kubectl patch` would be reverted by K3s, and an in-place edit would leave
# the rest of the file (e.g. a temporarily disabled sync policy) as it was.
# The legacy duplicate app-of-apps.yaml is retired on the way, so it can never
# flip the revision back. ArgoCD then syncs the new chart versions from Harbor.
#
# Usage: airgap/update-airgap.sh [options] <app-of-apps-version>
#        airgap/update-airgap.sh [options] --from-bundle
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <app-of-apps-version>
       $(basename "$0") [options] --from-bundle

Deploys the bundle's app-of-apps manifest with targetRevision set to
<app-of-apps-version> (rollback: pass an older version). --from-bundle keeps
the bundle's own targetRevision.

Options:
  --from-bundle  deploy the bundle's manifest unchanged
  --refresh      also ask ArgoCD to refresh app-of-apps right away
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
args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-bundle) FROM_BUNDLE=1 ;;
    --refresh) args+=(--refresh) ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --dry-run) args+=(--dry-run) ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown argument: $1 (see --help)" ;;
    *)
      [[ -z "${NEW_REVISION}" ]] || die "unexpected extra argument: $1"
      NEW_REVISION="$1"
      ;;
  esac
  shift
done

if [[ "${FROM_BUNDLE}" == "1" ]]; then
  [[ -z "${NEW_REVISION}" ]] || die "use either <app-of-apps-version> or --from-bundle"
else
  [[ -n "${NEW_REVISION}" ]] || { usage; die "missing <app-of-apps-version> (or use --from-bundle)"; }
  args+=(--revision "${NEW_REVISION}")
fi
apply_ssh_key

# ${a[@]+...}: empty arrays under set -u on bash 3.2 (macOS laptops)
exec "${AIRGAP_DIR}/deploy-app-of-apps.sh" ${args[@]+"${args[@]}"} \
  --bundle "$(bundle_dir)" --host "${TEKNOIR_HOST}"
