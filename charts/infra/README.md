# Infra

Umbrella Helm chart for installing Istio (sidecar mode, ingress/egress) plus
cert-manager and cert-manager-istio-csr for certificate issuance.

> The implementation of the Helm chart is the bare minimum.
> The Helm Chart is not meant to be infinitely configurable, but to provide a quick way to deploy to a Kubernetes cluster.

## Quick start

Run a local dry run render:

```sh
./scripts/dry-run.sh
```

Install into a cluster:
Use the HelmChart to deploy to a K3s cluster:
```yaml
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: infra
  namespace: istio-system
spec:
  repo: https://teknoir.github.io/infra
  chart: infra
  targetNamespace: istio-system
  valuesContent: |-
    # Example for minimal configuration
```
