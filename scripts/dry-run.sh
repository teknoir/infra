#!/bin/sh
set -e

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update
helm dependency build charts/infra
helm -n istio-system template infra charts/infra --values example-values.yaml --debug --dry-run=client | yq
