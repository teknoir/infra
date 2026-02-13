#!/bin/sh
set -e

helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update

helm dependency build charts/infra-stage-0
helm -n cert-manager template infra-stage-0 charts/infra-stage-0 --values example-values.yaml --debug --dry-run=client | yq

helm dependency build charts/infra-stage-1
helm -n istio-system template infra-stage-1 charts/infra-stage-1 --values example-values.yaml --debug --dry-run=client | yq

helm dependency build charts/infra-stage-2
helm -n istio-system template infra-stage-2 charts/infra-stage-2 --values example-values.yaml --debug --dry-run=client | yq

helm dependency build charts/infra-stage-2b
helm -n istio-system template infra-stage-2 charts/infra-stage-2b --values example-values.yaml --debug --dry-run=client | yq

helm dependency build charts/infra-stage-3
helm -n istio-system template infra-stage-3 charts/infra-stage-3 --values example-values.yaml --debug --dry-run=client | yq
