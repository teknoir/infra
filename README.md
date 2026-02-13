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

## Staged install

Install in order to avoid CRD race conditions:

```sh
helm dependency build charts/infra-stage-1
helm upgrade --install infra-stage-1 charts/infra-stage-1 -n istio-system --create-namespace

helm dependency build charts/infra-stage-2
helm upgrade --install infra-stage-2 charts/infra-stage-2 -n istio-system

helm dependency build charts/infra-stage-3
helm upgrade --install infra-stage-3 charts/infra-stage-3 -n istio-system
```

## Layout

- `charts/infra`: umbrella chart and values
- `charts/infra-stage-1`: namespace, cert-manager, and Istio CRDs
- `charts/infra-stage-2`: Istio control plane and gateways
- `charts/infra-stage-3`: cert-manager Istio CSR integration
- `example-values.yaml`: optional overrides for dry runs
- `scripts/dry-run.sh`: renders manifests with debug output
