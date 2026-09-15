#!/usr/bin/env bash
# extract-kubeconfig.sh — pull the node's kubeconfig and rewrite it for the
# operator laptop (LAN side, over ssh to $TEKNOIR_HOST).
#
# K3s writes /etc/rancher/k3s/k3s.yaml with `server: https://127.0.0.1:6443`
# and every cluster/user/context named `default`. This script fetches it and:
#   * replaces the loopback server with the node IP (or a --server URL),
#   * renames cluster/user/context from `default` to a unique name,
#   * imports the result into a multi-context kubeconfig ($HOME/.kube/config by
#     default) — or writes a standalone file with --output.
#
# The unique cluster/user/context name is what makes the extracted kubeconfig
# safe to merge into a kubeconfig that already holds many contexts: nothing is
# named `default` and the operator's current-context is left untouched.
#
# Usage: airgap/extract-kubeconfig.sh [--host H] [--ssh-key FILE]
#         [--node-ip IP | --server URL] [--context NAME]
#         [--output FILE | --kubeconfig FILE] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Fetches the K3s node kubeconfig over ssh and rewrites it for the laptop:
loopback server -> node IP, and cluster/user/context renamed from 'default' to
a unique name. By default the result is imported into a multi-context
kubeconfig ($(printf '%s' "${HOME}/.kube/config")) so it can be used alongside
other clusters; use --output to write a standalone file instead.

Options:
  --host H          ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE    ssh identity file, e.g. .secrets/teknoir.airgapped.id_rsa
                    (default: \$SSH_KEY, else auto-detected [${SSH_KEY:-none}])
  --node-ip IP      node IP used to build the server URL (default:
                    NODE_IP from versions.env [${NODE_IP:-unset}]; auto-detected
                    over ssh when empty)
  --server URL      full server URL override, e.g. https://teknoir.airgapped:6443
                    (default: https://<node-ip>:6443)
  --context NAME    cluster/user/context name to use (default: teknoir-airgapped)
  --output FILE     write a standalone kubeconfig file instead of importing
  --kubeconfig FILE import target (default: ${HOME}/.kube/config)
  --dry-run         print the planned rewrite, fetch/write nothing
  -h, --help        show this help
EOF
}

CONTEXT_NAME="${CONTEXT_NAME:-teknoir-airgapped}"
SERVER="${SERVER:-}"
OUTPUT_FILE="${OUTPUT_FILE:-}"
TARGET_KUBECONFIG="${TARGET_KUBECONFIG:-${HOME}/.kube/config}"

# NODE_IP is inherited from versions.env (default 192.168.5.181).
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --node-ip) NODE_IP="$2"; shift ;;
    --server) SERVER="$2"; shift ;;
    --context) CONTEXT_NAME="$2"; shift ;;
    --output) OUTPUT_FILE="$2"; shift ;;
    --kubeconfig) TARGET_KUBECONFIG="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh sed
apply_ssh_key

resolve_server() {
  if [[ -n "${SERVER}" ]]; then
    echo "${SERVER}"
  elif [[ -n "${NODE_IP}" ]]; then
    echo "https://${NODE_IP}:6443"
  else
    echo "https://<node-ip>:6443"
  fi
}

if [[ "${DRY_RUN}" == "1" ]]; then
  SERVER="$(resolve_server)"
  log "[dry-run] fetch /etc/rancher/k3s/k3s.yaml from ${TEKNOIR_HOST}"
  log "[dry-run] rewrite server -> ${SERVER}"
  log "[dry-run] rename cluster/user/context 'default' -> '${CONTEXT_NAME}'"
  if [[ -n "${OUTPUT_FILE}" ]]; then
    log "[dry-run] write standalone kubeconfig -> ${OUTPUT_FILE}"
  else
    log "[dry-run] import into ${TARGET_KUBECONFIG}"
  fi
  exit 0
fi

# --- resolve the server address (node IP unless --server) --------------------
if [[ -z "${SERVER}" && -z "${NODE_IP}" ]]; then
  log "auto-detecting node IP on ${TEKNOIR_HOST}"
  NODE_IP="$(ssh_query "hostname -I 2>/dev/null | awk '{print \$1}' || ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true)"
  NODE_IP="$(echo "${NODE_IP}" | head -1 | tr -d '[:space:]')"
fi
SERVER="$(resolve_server)"
if [[ "${SERVER}" == "https://<node-ip>:6443" ]]; then
  die "could not determine the node IP (use --node-ip or --server)"
fi

# --- fetch the node kubeconfig ------------------------------------------------
log "fetching kubeconfig from ${TEKNOIR_HOST}:/etc/rancher/k3s/k3s.yaml"
remote_cfg="$(ssh_run "sudo cat /etc/rancher/k3s/k3s.yaml")"

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

# Rewrite: loopback server -> node IP/URL, and every cluster/user/context named
# 'default' (plus the context's cluster:/user: references and current-context)
# -> the unique context name. Only the key-scoped values are touched, never the
# base64 certificate material.
printf '%s\n' "${remote_cfg}" | sed \
  -e "s|server: https://[^[:space:]]*|server: ${SERVER}|" \
  -e "s|name: default|name: ${CONTEXT_NAME}|g" \
  -e "s|cluster: default|cluster: ${CONTEXT_NAME}|" \
  -e "s|user: default|user: ${CONTEXT_NAME}|" \
  -e "s|current-context: default|current-context: ${CONTEXT_NAME}|" > "${tmp}"
chmod 600 "${tmp}"

# --- standalone vs. import -----------------------------------------------------
if [[ -n "${OUTPUT_FILE}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  cp "${tmp}" "${OUTPUT_FILE}"
  chmod 600 "${OUTPUT_FILE}"
  log "standalone kubeconfig written: ${OUTPUT_FILE} (context ${CONTEXT_NAME})"
  log "use: kubectl --kubeconfig ${OUTPUT_FILE} get nodes"
else
  mkdir -p "$(dirname "${TARGET_KUBECONFIG}")"
  if [[ ! -f "${TARGET_KUBECONFIG}" ]]; then
    cp "${tmp}" "${TARGET_KUBECONFIG}"
    chmod 600 "${TARGET_KUBECONFIG}"
    log "kubeconfig created: ${TARGET_KUBECONFIG} (context ${CONTEXT_NAME})"
  else
    require_cmd kubectl
    merged="$(mktemp)"
    # Target first so its existing current-context and entries win; the new
    # context is appended without silently switching the operator's context.
    KUBECONFIG="${TARGET_KUBECONFIG}:${tmp}" kubectl config view --flatten > "${merged}"
    chmod 600 "${merged}"
    mv "${merged}" "${TARGET_KUBECONFIG}"
    log "imported context '${CONTEXT_NAME}' into ${TARGET_KUBECONFIG}"
  fi
  log "switch to it with: kubectl config use-context ${CONTEXT_NAME}"
fi
