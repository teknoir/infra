#!/usr/bin/env bash
# deploy-secrets.sh — install the generated secret manifests (.secrets/, from
# scripts/gen-*.sh) into the K3s auto-deploy dir of the air-gapped node.
#
# Each secret is K3s-owned through exactly one canonical file
# (teknoir-<name>.yaml, mode 600); legacy duplicates written by older tooling
# (manifest-*.yaml) are retired once the canonical file owns the objects.
# Idempotent: unchanged secrets are rewritten byte-identically and K3s does not
# re-apply them.
#
# The cert-manager-owned wildcard TLS secret is NOT deployed by default: it is
# a bootstrap placeholder that cert-manager replaces, and re-applying it would
# overwrite the issued certificate. Use --bootstrap-wildcard only on a fresh
# cluster.
#
# Usage: scripts/deploy-secrets.sh [--only <manifest>]... [--bootstrap-wildcard]
#                                  [--host user@host] [--ssh-key FILE] [--dry-run]
set -euo pipefail

# shellcheck source=../airgap/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/airgap/lib.sh"

SECRETS_DIR="${REPO_ROOT}/.secrets"

# Read-only secrets that live in the K3s manifests dir.
SECRET_MANIFESTS=(
  manifest-harbor-secret.yaml
  manifest-keycloak-db-secret.yaml
  manifest-oauth2-proxy-secret.yaml
  manifest-oauth2-proxy-redis-secret.yaml
  manifest-argocd-keycloak-secret.yaml
  manifest-teknoir-ca-secret.yaml
  manifest-argocd-harbor-repo-secret.yaml
  manifest-teknoir-auth-ca-bundle-secret.yaml
  manifest-teknoir-system-ca-bundle-secret.yaml
)
WILDCARD_MANIFEST="manifest-wildcard-tls-secret.yaml"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --only NAME           deploy only this manifest (repeatable), e.g.
                        --only manifest-argocd-harbor-repo-secret.yaml
  --bootstrap-wildcard  also one-shot apply ${WILDCARD_MANIFEST}
                        (fresh cluster only; cert-manager owns it afterwards)
  --host H              ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE        ssh identity file (default: \$SSH_KEY, else auto-detected)
  --dry-run             print actions without mutating the node
  -h, --help            show this help
EOF
}

ONLY=()
BOOTSTRAP_WILDCARD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift ;;
    --bootstrap-wildcard) BOOTSTRAP_WILDCARD=1 ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh sha256sum
apply_ssh_key

if [[ ${#ONLY[@]} -gt 0 ]]; then
  for m in "${ONLY[@]}"; do
    [[ " ${SECRET_MANIFESTS[*]} " == *" ${m} "* ]] || die "--only ${m}: not a known secret manifest"
  done
  SECRET_MANIFESTS=("${ONLY[@]}")
fi

missing=0
for manifest in "${SECRET_MANIFESTS[@]}"; do
  if [[ -f "${SECRETS_DIR}/${manifest}" ]]; then
    log "deploying ${manifest} -> ${K3S_MANIFESTS_DIR}/$(k3s_canonical_name "${manifest}")"
    k3s_deploy "${SECRETS_DIR}/${manifest}" 0600
  else
    warn "missing ${SECRETS_DIR}/${manifest} — skipped (generate it with scripts/gen-*.sh)"
    missing=$((missing + 1))
  fi
done

if [[ "${BOOTSTRAP_WILDCARD}" == "1" ]]; then
  [[ -f "${SECRETS_DIR}/${WILDCARD_MANIFEST}" ]] || die "missing ${SECRETS_DIR}/${WILDCARD_MANIFEST}"
  log "one-shot apply ${WILDCARD_MANIFEST} (cert-manager takes it over)"
  remote_kubectl apply -f - < "${SECRETS_DIR}/${WILDCARD_MANIFEST}"
fi

(( missing == 0 )) || warn "${missing} secret manifest(s) missing"
log "deploy-secrets complete"
