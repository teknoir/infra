#!/bin/sh
set -e

# Colors
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#MANIFESTS
LETSENCRYPT_SECRET_MANIFEST_PATH=manifest-letsencrypt-dns-account-key.yaml
GODADDY_SECRET_MANIFEST_PATH=manifest-godaddy-secret.yaml
OAUTH2_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-secret.yaml
KEYCLOAK_DB_SECRET_MANIFEST_PATH=manifest-keycloak-db-secret.yaml
OAUTH2_REDIS_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-redis-secret.yaml
GCR_SECRET_MANIFEST_PATH=manifest-gcr-json-key-secret.yaml
GHCR_SECRET_MANIFEST_PATH=manifest-ghcr-token-secret.yaml
HARBOR_SECRET_MANIFEST_PATH=manifest-harbor-secret.yaml
BACKSTAGE_KEYCLOAK_MANIFEST_PATH=manifest-backstage-keycloak-secret.yaml
BACKSTAGE_SECRETS_MANIFEST_PATH=manifest-backstage-secrets.yaml
ARGOCD_KEYCLOAK_MANIFEST_PATH=manifest-argocd-keycloak-secret.yaml
TEKNOIR_GITHUB_MANIFEST_PATH=manifest-teknoir-github-secret.yaml

# Check for missing manifest files
MISSING=0
for manifest in \
  "${LETSENCRYPT_SECRET_MANIFEST_PATH}" \
  "${GODADDY_SECRET_MANIFEST_PATH}" \
  "${OAUTH2_SECRET_MANIFEST_PATH}" \
  "${KEYCLOAK_DB_SECRET_MANIFEST_PATH}" \
  "${OAUTH2_REDIS_SECRET_MANIFEST_PATH}" \
  "${GCR_SECRET_MANIFEST_PATH}" \
  "${GHCR_SECRET_MANIFEST_PATH}" \
  "${HARBOR_SECRET_MANIFEST_PATH}" \
  "${BACKSTAGE_KEYCLOAK_MANIFEST_PATH}" \
  "${BACKSTAGE_SECRETS_MANIFEST_PATH}" \
  "${ARGOCD_KEYCLOAK_MANIFEST_PATH}" \
  "${TEKNOIR_GITHUB_MANIFEST_PATH}"; do
  if [ ! -f "${manifest}" ]; then
    printf "${YELLOW}WARNING: Missing secret manifest: %s${NC}\n" "${manifest}" >&2
    MISSING=$((MISSING + 1))
  fi
done
if [ "${MISSING}" -gt 0 ]; then
  printf "${YELLOW}WARNING: %d secret manifest(s) missing. Skipping those.${NC}\n" "${MISSING}" >&2
  echo ""
fi

# SECRETS
if [ -f "${LETSENCRYPT_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-letsencrypt-secret.yaml >/dev/null" \
    < "${LETSENCRYPT_SECRET_MANIFEST_PATH}"
fi

if [ -f "${GODADDY_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-godaddy-secret.yaml >/dev/null" \
    < "${GODADDY_SECRET_MANIFEST_PATH}"
fi

if [ -f "${OAUTH2_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-oauth2-proxy-secret.yaml >/dev/null" \
    < "${OAUTH2_SECRET_MANIFEST_PATH}"
fi

if [ -f "${KEYCLOAK_DB_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-keycloak-db-secret.yaml >/dev/null" \
    < "${KEYCLOAK_DB_SECRET_MANIFEST_PATH}"
fi

if [ -f "${OAUTH2_REDIS_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-oauth2-proxy-redis-secret.yaml >/dev/null" \
    < "${OAUTH2_REDIS_SECRET_MANIFEST_PATH}"
fi

if [ -f "${GCR_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-gcr-json-key-secret.yaml >/dev/null" \
    < "${GCR_SECRET_MANIFEST_PATH}"
fi

if [ -f "${GHCR_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-ghcr-json-key-secret.yaml >/dev/null" \
    < "${GHCR_SECRET_MANIFEST_PATH}"
fi

if [ -f "${HARBOR_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-harbor-secret.yaml >/dev/null" \
    < "${HARBOR_SECRET_MANIFEST_PATH}"
fi

if [ -f "${BACKSTAGE_KEYCLOAK_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-backstage-keycloak-secrets.yaml >/dev/null" \
    < "${BACKSTAGE_KEYCLOAK_MANIFEST_PATH}"
fi

if [ -f "${BACKSTAGE_SECRETS_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-backstage-secrets.yaml >/dev/null" \
    < "${BACKSTAGE_SECRETS_MANIFEST_PATH}"
fi

if [ -f "${ARGOCD_KEYCLOAK_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-argocd-keycloak-secrets.yaml >/dev/null" \
    < "${ARGOCD_KEYCLOAK_MANIFEST_PATH}"
fi

if [ -f "${TEKNOIR_GITHUB_MANIFEST_PATH}" ]; then
  ssh anders@r415 \
    "sudo tee /opt/k3s/server/manifests/teknoir-github-secrets.yaml >/dev/null" \
    < "${TEKNOIR_GITHUB_MANIFEST_PATH}"
fi
