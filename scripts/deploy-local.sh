#!/bin/sh
set -e

MANIFEST_PATH=manifest-local.yaml
SECRET_MANIFEST_PATH=manifest-clouddns-secret.yaml
OAUTH2_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-secret.yaml
KEYCLOAK_DB_SECRET_MANIFEST_PATH=manifest-keycloak-db-secret.yaml
OAUTH2_REDIS_SECRET_MANIFEST_PATH=manifest-oauth2-proxy-redis-secret.yaml
GCR_SECRET_MANIFEST_PATH=manifest-gcr-json-key-secret.yaml




# SECRETS
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

if [ -f "${OAUTH2_REDIS_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@rtx2000-pro-bw-se.teknoir \
    "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-oauth2-proxy-redis-secret.yaml >/dev/null" \
    < "${OAUTH2_REDIS_SECRET_MANIFEST_PATH}"
fi

if [ -f "${GCR_SECRET_MANIFEST_PATH}" ]; then
  ssh anders@rtx2000-pro-bw-se.teknoir \
    "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-gcr-json-key-secret.yaml >/dev/null" \
    < "${GCR_SECRET_MANIFEST_PATH}"
fi


#helm -n teknoir-system template profile-controller ./charts/profile-controller \
#  --include-crds \
#  --values ./scripts/teknoir-online-values.yaml \
#  --set image.tag=${TAG} \
#  --set image.repository="us-central1-docker.pkg.dev/${PROJECT_ID}/controllers/profile-controller" | \
#ssh anders@rtx2000-pro-bw-se.teknoir \
#  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-profile-controller.yaml >/dev/null"


ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-1-istio-base.yaml >/dev/null" \
  < "stage-1-istio-base.yaml"

ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-2-istiod.yaml >/dev/null" \
  < "stage-2-istiod.yaml"

ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-3-ingressgateway.yaml >/dev/null" \
  < "stage-3-ingressgateway.yaml"

ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-4-egressgateway.yaml >/dev/null" \
  < "stage-4-egressgateway.yaml"

ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-5-cert-manager.yaml >/dev/null" \
  < "stage-5-cert-manager.yaml"

helm -n istio-system template teknoir-gateway ./charts/stage-6-teknoir-gateway | \
ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-6-teknoir-gateway.yaml >/dev/null"
#ssh anders@rtx2000-pro-bw-se.teknoir \
#  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-6-teknoir-gateway.yaml >/dev/null" \
#  < "stage-6-teknoir-gateway.yaml"

helm -n teknoir-auth template teknoir-gateway ./charts/stage-7-auth | \
ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-7-auth.yaml >/dev/null"
#ssh anders@rtx2000-pro-bw-se.teknoir \
#  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-stage-7-auth.yaml >/dev/null" \
#  < "stage-7-auth.yaml"