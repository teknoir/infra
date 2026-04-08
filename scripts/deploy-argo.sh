#!/bin/sh
set -e

helm template --namespace teknoir-system --values charts/argo/values.yaml argo charts/argo --debug > teknoir-argo.yaml

ssh anders@r415 \
  "sudo tee /opt/k3s/server/manifests/teknoir-argo.yaml >/dev/null" \
  < teknoir-argo.yaml