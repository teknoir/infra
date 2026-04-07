#!/usr/bin/env bash
set -eo pipefail

cat <<EOF | ssh anders@r415 "sudo tee /opt/k3s/server/manifests/teknoir-monitoring.yaml >/dev/null"
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: harbor
  namespace: kube-system
spec:
  repo: https://teknoir.github.io/infra
  chart: harbor
  version: 0.0.3
  targetNamespace: teknoir-system
  valuesContent: |-
    domain: "teknoir.cloud"
    hostname: "harbor.teknoir.cloud"
EOF