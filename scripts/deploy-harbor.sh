#!/usr/bin/env bash
set -eo pipefail

cat <<EOF | ssh anders@r415 "sudo tee /opt/k3s/server/manifests/teknoir-harbor.yaml >/dev/null"
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: harbor
  namespace: teknoir-system
spec:
  repo: https://teknoir.github.io/infra
  chart: harbor
  version: 0.0.5
  targetNamespace: teknoir-system
  takeOwnership: true
  valuesContent: |-
    domain: "teknoir.cloud"
    hostname: "harbor.teknoir.cloud"
EOF