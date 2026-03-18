#!/bin/sh
set -e

# Add repositories for external dependencies
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update

# Build/Update dependencies for the infra chart
echo "Building dependencies for charts/infra..."
helm dependency update charts/infra

# Validate the infra chart by generating templates with namespace mapping
echo "Dry-run validation for charts/infra..."
helm -n istio-system template infra charts/infra --debug --dry-run=client \
  > test-output.yaml

echo "Infra chart validation successful."
