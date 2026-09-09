#!/usr/bin/env bash
# upload-bundle.sh — copy the air-gap bundle onto the K3s node over ssh
# (operator/LAN-laptop side). Uses rsync when both ends have it, otherwise
# falls back to streaming a gzip'd tar over ssh (the node may lack rsync).
#
# The node has no internet, but it IS reachable on the LAN over ssh (that is how
# bootstrap-airgap.sh drives it). This mirrors the built bundle directory into
# the teknoir user's home so the on-node steps of docs/AIRGAP-HOST-SETUP.md can
# consume it — in particular §8 (offline K3s install from the bundle's k3s/).
# rsync is a LAN transfer, not an internet fetch, so it stays within the air gap.
#
# It is an alternative to the USB transfer in docs/AIRGAP-HOST-SETUP.md §2/§3 for
# when the node is already on the LAN and SSH-reachable.
#
# Usage: airgap/upload-bundle.sh [--bundle DIR] [--host user@host]
#                                [--ssh-key FILE] [--dest DIR]
#                                [--delete] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Remote parent directory the bundle is copied INTO. The bundle lands as
# ${REMOTE_DEST%/}/<bundle-name>/ on the node. Default: the teknoir user's home.
REMOTE_DEST="${REMOTE_DEST:-~/}"
RSYNC_DELETE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Copies the air-gap bundle to the K3s node over ssh. Uses rsync when both ends
have it, otherwise falls back to tar-over-ssh (the node may lack rsync). The
bundle directory is copied into REMOTE_DEST on the node (default: teknoir's
home), landing as <REMOTE_DEST>/$(basename "$(bundle_dir)")/.

Options:
  --bundle DIR    bundle directory to upload (default: $(bundle_dir))
  --host H        ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE  ssh identity file, e.g. .secrets/teknoir.airgapped.id_rsa
                  (default: \$SSH_KEY, else auto-detected [${SSH_KEY:-none}])
  --dest DIR      remote parent directory to copy into (default: ${REMOTE_DEST})
  --delete        mirror exactly (rsync --delete: remove remote extras;
                  ignored in the tar fallback)
  --dry-run       show what rsync would transfer, write nothing on the node
  -h, --help      show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --dest) REMOTE_DEST="$2"; shift ;;
    --delete) RSYNC_DELETE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh tar
apply_ssh_key

BUNDLE="$(bundle_dir)"
[[ -d "${BUNDLE}" ]] || die "bundle not found: ${BUNDLE} (run make-bundle.sh first)"
if [[ ! -f "${BUNDLE}/bundle-manifest.yaml" ]]; then
  warn "bundle-manifest.yaml missing under ${BUNDLE} — bundle may be incomplete"
fi

REMOTE_PATH="${REMOTE_DEST%/}/$(basename "${BUNDLE}")"

# The transfer prefers rsync, but the air-gapped node may not have rsync
# installed (the failure looks like `zsh:1: command not found: rsync` coming
# from the remote shell). rsync needs its counterpart on BOTH ends, so only use
# it when this host AND the node have it; otherwise fall back to tar-over-ssh,
# which only needs the (universally present) tar on each end.
use_rsync=0
if command -v rsync >/dev/null 2>&1; then
  if ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" 'command -v rsync >/dev/null 2>&1'; then
    use_rsync=1
  else
    warn "remote ${TEKNOIR_HOST} has no rsync — falling back to tar-over-ssh"
  fi
else
  warn "local rsync not found — falling back to tar-over-ssh"
fi

log "uploading ${BUNDLE}"
log "     -> ${TEKNOIR_HOST}:${REMOTE_PATH}/"
[[ "${DRY_RUN}" == "1" ]] && log "[dry-run] preview — nothing is written on the node"

if [[ "${use_rsync}" == "1" ]]; then
  rsync_flags=(-az --human-readable)
  # --info=progress2 needs rsync >= 3.1.0. macOS ships openrsync (reports as
  # "rsync 2.6.9 compatible"), which rejects it; fall back to --progress there,
  # and to no progress output if even that is unsupported.
  if rsync --info=progress2 --version >/dev/null 2>&1; then
    rsync_flags+=(--info=progress2)
  elif rsync --progress --version >/dev/null 2>&1; then
    rsync_flags+=(--progress)
  fi
  [[ "${RSYNC_DELETE}" == "1" ]] && rsync_flags+=(--delete)
  [[ "${DRY_RUN}" == "1" ]] && rsync_flags+=(--dry-run --itemize-changes)

  # Source has NO trailing slash so the bundle directory itself is created under
  # REMOTE_DEST (rather than its contents being splattered into REMOTE_DEST).
  rsync "${rsync_flags[@]}" -e "ssh ${SSH_OPTS[*]}" "${BUNDLE}" "${TEKNOIR_HOST}:${REMOTE_DEST}"
else
  # tar-over-ssh fallback: stream the bundle directory as a gzip'd tar and
  # unpack it under REMOTE_DEST on the node. As with the rsync call, the bundle
  # directory itself (its basename) is recreated under REMOTE_DEST. REMOTE_DEST
  # is left unquoted on the remote so a leading ~ still expands to the home dir.
  [[ "${RSYNC_DELETE}" == "1" ]] && \
    warn "--delete is ignored in the tar fallback (remote extras are NOT removed)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    ( cd "$(dirname "${BUNDLE}")" && find "$(basename "${BUNDLE}")" -print ) >&2
  else
    # shellcheck disable=SC2029  # client-side expansion of REMOTE_DEST is intended
    tar -C "$(dirname "${BUNDLE}")" -czf - "$(basename "${BUNDLE}")" \
      | ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" "mkdir -p ${REMOTE_DEST} && tar -C ${REMOTE_DEST} -xzf -"
  fi
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  log "dry-run complete (no files transferred)"
else
  log "upload complete: ${TEKNOIR_HOST}:${REMOTE_PATH}/"
  log "on the node, the K3s install artifacts are at ${REMOTE_PATH}/k3s/ (docs/AIRGAP-HOST-SETUP.md §8)"
fi
