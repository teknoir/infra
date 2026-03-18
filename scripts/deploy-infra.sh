#!/bin/sh
set -e

# Generate the consolidated manifest and apply namespace mappings
helm template infra ./charts/infra -n istio-system \
  > infra.yaml

# Deploy to the remote K3s cluster
ssh anders@r415 \
  "sudo tee /opt/k3s/server/manifests/teknoir-infra.yaml >/dev/null" \
  < infra.yaml

echo "Infra chart deployed successfully."
