#!/usr/bin/env bash
set -e

# Colors
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TEKNOIR_HOST="${TEKNOIR_HOST:-teknoir@teknoir.airgapped}"

# Secret manifests are generated under .secrets/ (gitignored) by scripts/gen-*.sh
SECRETS_DIR=".secrets"

# SSH identity: use $SSH_KEY if set, else auto-detect the node key in .secrets/
# (the node only accepts publickey auth).
SSH_KEY="${SSH_KEY:-}"
if [ -z "${SSH_KEY}" ] && [ -f "${SECRETS_DIR}/teknoir.airgapped.id_rsa" ]; then
  SSH_KEY="${SECRETS_DIR}/teknoir.airgapped.id_rsa"
fi
SSH_OPTS=()
if [ -n "${SSH_KEY}" ]; then
  SSH_OPTS+=(-i "${SSH_KEY}")
fi

# MANIFESTS: local secret manifests copied to the K3s auto-deploy directory
SECRET_MANIFESTS=(
  manifest-harbor-secret.yaml
  manifest-keycloak-db-secret.yaml
  manifest-oauth2-proxy-secret.yaml
  manifest-oauth2-proxy-redis-secret.yaml
  manifest-argocd-keycloak-secret.yaml
  manifest-teknoir-ca-secret.yaml
  manifest-wildcard-tls-secret.yaml
  manifest-argocd-harbor-repo-secret.yaml
)

MISSING=0
for manifest in "${SECRET_MANIFESTS[@]}"; do
  if [ ! -f "${SECRETS_DIR}/${manifest}" ]; then
    printf "${YELLOW}WARNING: Missing secret manifest: %s${NC}\n" "${SECRETS_DIR}/${manifest}" >&2
    MISSING=$((MISSING + 1))
  fi
done
if [ "${MISSING}" -gt 0 ]; then
  printf "${YELLOW}WARNING: %d secret manifest(s) missing. Skipping those.${NC}\n" "${MISSING}" >&2
  echo ""
fi

for manifest in "${SECRET_MANIFESTS[@]}"; do
  if [ -f "${SECRETS_DIR}/${manifest}" ]; then
    dest="${manifest#manifest-}"
    case "${dest}" in
      teknoir-*) ;;
      *) dest="teknoir-${dest}" ;;
    esac
    echo "Deploying ${SECRETS_DIR}/${manifest} to ${TEKNOIR_HOST}:/opt/k3s/server/manifests/${dest}"
    ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
      "sudo tee /opt/k3s/server/manifests/${dest} >/dev/null" \
      < "${SECRETS_DIR}/${manifest}"
  fi
done
