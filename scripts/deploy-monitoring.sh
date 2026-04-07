#!/usr/bin/env bash
set -eo pipefail

cat <<EOF | ssh anders@r415 "sudo tee /opt/k3s/server/manifests/teknoir-monitoring.yaml >/dev/null"
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: backstage
  namespace: kube-system
spec:
  repo: https://teknoir.github.io/infra
  chart: monitoring
  version: 0.0.3
  targetNamespace: teknoir-system
  valuesContent: |-
    domain: "teknoir.cloud"
    grafana:
      grafana.ini:
        server:
          domain: "teknoir.cloud"
EOF