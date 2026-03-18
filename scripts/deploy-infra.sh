#!/bin/sh
set -e

# Generate the consolidated manifest and apply namespace mappings
helm template infra ./charts/infra -n istio-system | \
  yq '(select(.metadata.namespace != null and .metadata.name == "keycloak*") | .metadata.namespace) = "teknoir-auth" | (select(.metadata.namespace != null and .metadata.name == "harbor*") | .metadata.namespace) = "teknoir-system" | (select(.metadata.namespace != null and .metadata.name == "infra-cert-manager*") | .metadata.namespace) = "cert-manager"' \
  > infra.yaml

# Deploy to the remote K3s cluster
ssh anders@r415 \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-infra.yaml >/dev/null" \
  < infra.yaml

echo "Infra chart deployed successfully."
