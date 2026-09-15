#!/usr/bin/env bash
# install-k3s.sh — offline K3s configuration + install on the air-gapped node
# (on-node script; run as the teknoir user, it re-execs itself under sudo).
#
# Reads the pinned K3s artifacts shipped in the bundle's k3s/ directory
# (docs/AIRGAP-HOST-SETUP.md §8) and, in order:
#   1. writes /etc/rancher/k3s/config.yaml BEFORE the first start (data-dir
#      /opt/k3s, traefik disabled, max-pods=250, tls-san teknoir.airgapped),
#   2. installs the K3s binary to /usr/local/bin/k3s,
#   3. stages K3s' own airgap images into the data-dir-relative images dir,
#   4. runs the bundled get.k3s.io installer with INSTALL_K3S_SKIP_DOWNLOAD=true,
#   5. waits for the node to become Ready and reports pods / max-pods.
#
# This replaces the manual §7 + §8.2 steps in docs/AIRGAP-HOST-SETUP.md.
#
# Usage: airgap/install-k3s.sh [--k3s-dir DIR] [--domain DOMAIN] [--data-dir DIR]
#                              [--skip-config] [--no-verify] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

On-node offline K3s install. Run from the bundle directory (the script ships
under the bundle's airgap/). Writes /etc/rancher/k3s/config.yaml, then installs
the K3s binary + airgap images from the bundle's k3s/ and starts K3s with
downloads disabled.

Options:
  --k3s-dir DIR    directory holding the K3s artifacts (default: ${REPO_ROOT}/k3s)
  --domain DOMAIN  TLS SAN hostname (default: ${TEKNOIR_DOMAIN})
  --data-dir DIR   K3s data dir (default: ${K3S_DATA_DIR})
  --skip-config    do not (re)write /etc/rancher/k3s/config.yaml
  --no-verify      do not wait for the node to become Ready after install
  --dry-run        print every action without touching the node
  -h, --help       show this help
EOF
}

K3S_DIR="${K3S_DIR:-${REPO_ROOT}/k3s}"
DOMAIN="${TEKNOIR_DOMAIN}"
DATA_DIR="${K3S_DATA_DIR}"
SKIP_CONFIG=0
NO_VERIFY=0

# Keep the original argv for the sudo re-exec below (the while loop shifts it away).
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k3s-dir) K3S_DIR="$2"; shift ;;
    --domain) DOMAIN="$2"; shift ;;
    --data-dir) DATA_DIR="$2"; shift ;;
    --skip-config) SKIP_CONFIG=1 ;;
    --no-verify) NO_VERIFY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# Requires root to write /etc, /usr/local/bin and the data dir. Passwordless
# sudo is configured during host prep (docs/AIRGAP-HOST-SETUP.md §5.1), so
# re-exec under sudo when not already root. Dry-run needs no privileges.
if [[ "${DRY_RUN}" != "1" && "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "${ORIG_ARGS[@]}"
fi

CONFIG_FILE="/etc/rancher/k3s/config.yaml"
IMAGES_DIR="${DATA_DIR}/agent/images"
K3S_BIN="${K3S_DIR}/k3s"
INSTALL_SH="${K3S_DIR}/install.sh"

write_config() {
  cat <<EOF
kubelet-arg:
  - "max-pods=250"
data-dir: ${DATA_DIR}
disable:
  - traefik
tls-san:
  - "${DOMAIN}"
EOF
}

if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] write ${CONFIG_FILE} (skip-config=${SKIP_CONFIG})"
  log "[dry-run] install ${K3S_BIN} -> /usr/local/bin/k3s"
  log "[dry-run] copy ${K3S_DIR}/k3s-airgap-images-*.tar.zst -> ${IMAGES_DIR}/"
  log "[dry-run] run INSTALL_K3S_SKIP_DOWNLOAD=true ${INSTALL_SH}"
  if [[ "${NO_VERIFY}" == "1" ]]; then
    log "[dry-run] skip post-install verification (--no-verify)"
  else
    log "[dry-run] wait for node Ready and report pods / max-pods"
  fi
  exit 0
fi

# --- preflight: the k3s/ artifacts must be present in the bundle --------------
require_cmd install
[[ -x "${K3S_BIN}" ]] || die "k3s binary not found/executable: ${K3S_BIN}"
[[ -x "${INSTALL_SH}" ]] || die "install.sh not found/executable: ${INSTALL_SH}"

shopt -s nullglob
images_tarballs=("${K3S_DIR}"/k3s-airgap-images-*.tar.zst)
shopt -u nullglob
[[ ${#images_tarballs[@]} -gt 0 ]] || die "no k3s-airgap-images-*.tar.zst found in ${K3S_DIR}"
IMAGES_TAR="${images_tarballs[0]}"

# --- 1. K3s config.yaml (before first start) ---------------------------------
if [[ "${SKIP_CONFIG}" == "1" ]]; then
  log "skipping ${CONFIG_FILE} (--skip-config)"
else
  log "writing ${CONFIG_FILE} (data-dir ${DATA_DIR}, traefik disabled, tls-san ${DOMAIN})"
  mkdir -p "$(dirname "${CONFIG_FILE}")"
  write_config > "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"
fi

# --- 2. install the K3s binary ------------------------------------------------
log "installing ${K3S_BIN} -> /usr/local/bin/k3s"
install -m 0755 "${K3S_BIN}" /usr/local/bin/k3s

# --- 3. stage K3s' own airgap images (data-dir-relative) ----------------------
log "staging ${IMAGES_TAR} -> ${IMAGES_DIR}/"
mkdir -p "${IMAGES_DIR}"
cp "${IMAGES_TAR}" "${IMAGES_DIR}/"

# --- 4. run the bundled installer with downloads disabled ---------------------
log "running installer (INSTALL_K3S_SKIP_DOWNLOAD=true)"
INSTALL_K3S_SKIP_DOWNLOAD=true "${INSTALL_SH}"

# --- 5. verify the node comes up Ready ----------------------------------------
if [[ "${NO_VERIFY}" == "1" ]]; then
  log "skipping post-install verification (--no-verify)"
  exit 0
fi

log "waiting for the K3s node to become Ready"
ready=0
for ((i = 0; i < 60; i++)); do
  if k3s kubectl get nodes 2>/dev/null | grep -qw Ready; then
    ready=1
    break
  fi
  sleep 2
done

if [[ "${ready}" == "1" ]]; then
  log "node Ready:"
  k3s kubectl get nodes
else
  warn "node not Ready after ~120s — check: sudo systemctl status k3s --no-pager"
fi

log "pods (traefik must be absent):"
k3s kubectl get pods -A || true
log "allocatable pods (expect 250):"
k3s kubectl describe node | grep -i '  pods' || true
