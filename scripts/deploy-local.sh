#!/bin/sh
set -e

MANIFEST_PATH=manifest-local.yaml
SECRET_MANIFEST_PATH=manifest-clouddns-secret.yaml
OAUTH2_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-secret.yaml
KEYCLOAK_DB_SECRET_MANIFEST_PATH=manifest-keycloak-db-secret.yaml

ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-infra.yaml >/dev/null" \
  < "${MANIFEST_PATH}"

if [ -f "${SECRET_MANIFEST_PATH}" ]; then
  ssh anders@rtx2000-pro-bw-se.teknoir \
    "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-clouddns-secret.yaml >/dev/null" \
    < "${SECRET_MANIFEST_PATH}"
fi

if [ -f "${OAUTH2_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@rtx2000-pro-bw-se.teknoir \
    "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-oauth2-proxy-secret.yaml >/dev/null" \
    < "${OAUTH2_SECRET_MANIFEST_PATH}"
fi

if [ -f "${KEYCLOAK_DB_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@rtx2000-pro-bw-se.teknoir \
    "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-keycloak-db-secret.yaml >/dev/null" \
    < "${KEYCLOAK_DB_SECRET_MANIFEST_PATH}"
fi
