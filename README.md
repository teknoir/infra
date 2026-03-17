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
helm dependency build charts/infra-stage-0
helm upgrade --install infra-stage-0 charts/infra-stage-0 -n cert-manager --create-namespace

helm dependency build charts/infra-stage-1
helm upgrade --install infra-stage-1 charts/infra-stage-1 -n istio-system --create-namespace

helm dependency build charts/infra-stage-2
helm upgrade --install infra-stage-2 charts/infra-stage-2 -n istio-system

helm dependency build charts/infra-stage-3
helm upgrade --install infra-stage-3 charts/infra-stage-3 -n istio-system
```

## Setup in Keycloak

Minimal client setup in master realm:
* Client ID: teknoir-online (or change oauth2-proxy to match)
* OpenID Connect 
* Client authentication: ON (this is “confidential”)
* Standard flow: ON 
* Service account roles: ON
* Valid redirect URI: https://teknoir.online/oauth2/callback
* Web origins: https://teknoir.online
Then update the secret
* Take the client secret from Keycloak
* Update oauth2-proxy-secret (by running `./scripts/gen-oauth2-proxy-secrets.sh`)
* `./scripts/deploy-local.sh` to deploy secret to cluster
Then add client scope
* Add (or create) a scope: teknoir-online
* Type: Default
Configure a new mapper for the scope
* Mapper type: Audience
* Included Client Audience: teknoir-online
* Add to access token: ON
Then add Service Account Role
* Go to Service Account Roles for the client click Assign Roles
* Assign "Client Roles": manage-users, query-users, view-users
Restart oauth2-proxy deployment to pick up new secret and scope changes.
* `kubectl -n teknoir-auth rollout restart deploy/oauth2-proxy`

TODO:
Figure out how to label namespaces:
```
kubectl label namespace teknoir-auth istio-injection=enabled --overwrite
kubectl label namespace teknoir-system istio-injection=enabled --overwrite
```


## Layout

- `charts/infra`: umbrella chart and values
- `charts/infra-stage-0`: cert-manager (cert-manager namespace)
- `charts/infra-stage-1`: istio-system namespace and Istio CRDs
- `charts/infra-stage-2`: Istio control plane and gateways
- `charts/infra-stage-3`: cert-manager Istio CSR integration
- `example-values.yaml`: optional overrides for dry runs
- `scripts/dry-run.sh`: renders manifests with debug output
