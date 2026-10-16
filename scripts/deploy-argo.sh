#!/bin/sh
# Install ArgoCD on the staging k3s server through k3s's auto-deploy manifests directory.
#   STAGING_HOST    ssh target (default anders@192.168.2.19, vpro; r415 until 2026-10-16)
#   K3S_MANIFESTS   k3s server manifests dir (default /var/lib/rancher/k3s/server/manifests;
#                   r415 used data-dir /opt/k3s)
set -e
STAGING_HOST=${STAGING_HOST:-anders@192.168.2.19}
K3S_MANIFESTS=${K3S_MANIFESTS:-/var/lib/rancher/k3s/server/manifests}

helm dependency build charts/argo >/dev/null
helm template --namespace teknoir-system --values charts/argo/values.yaml argo charts/argo > teknoir-argo.yaml

ssh "$STAGING_HOST" "sudo install -d $K3S_MANIFESTS && sudo tee $K3S_MANIFESTS/teknoir-argo.yaml >/dev/null" \
  < teknoir-argo.yaml
echo "deploy-argo: teknoir-argo.yaml applied on $STAGING_HOST"
