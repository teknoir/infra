#!/bin/sh
set -e

TEKNOIR_HOST="${TEKNOIR_HOST:-teknoir@teknoir.airgapped}"

helm template --namespace teknoir-system --values charts/argo/values.yaml argo charts/argo --debug > teknoir-argo.yaml

ssh "${TEKNOIR_HOST}" \
  "sudo tee /opt/k3s/server/manifests/teknoir-argo.yaml >/dev/null" \
  < teknoir-argo.yaml
