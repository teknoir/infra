#!/bin/sh
set -e

#MANIFESTS
LETSENCRYPT_SECRET_MANIFEST_PATH=manifest-letsencrypt-dns-account-key.yaml
GODADDY_SECRET_MANIFEST_PATH=manifest-godaddy-secret.yaml
OAUTH2_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-secret.yaml
KEYCLOAK_DB_SECRET_MANIFEST_PATH=manifest-keycloak-db-secret.yaml
OAUTH2_REDIS_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-redis-secret.yaml
GCR_SECRET_MANIFEST_PATH=manifest-gcr-json-key-secret.yaml
HARBOR_SECRET_MANIFEST_PATH=manifest-harbor-secret.yaml
BACKSTAGE_KEYCLOAK_MANIFEST_PATH=manifest-backstage-keycloak-secret.yaml
BACKSTAGE_SECRETS_MANIFEST_PATH=manifest-backstage-secrets.yaml
ARGOCD_KEYCLOAK_MANIFEST_PATH=manifest-argocd-keycloak-secret.yaml
TEKNOIR_GITHUB_MANIFEST_PATH=manifest-teknoir-github-secret.yaml

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
