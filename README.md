# Infra

Umbrella Helm chart for installing Istio (sidecar mode, ingress/egress) plus
cert-manager and cert-manager-istio-csr for certificate issuance.

> The implementation of the Helm chart is the bare minimum.
> The Helm Chart is not meant to be infinitely configurable, but to provide a quick way to deploy to a Kubernetes cluster.

## Quick start

The infrastructure is now managed via a single umbrella Helm chart located in `charts/infra`.

### 1. Prerequisites (Secrets)

Secrets are managed manually. Generate them before deploying:

```sh
./scripts/create-clouddns-secret.sh <KEY_PATH>
./scripts/create-gcr-json-key-secret.sh <KEY_PATH>
./scripts/gen-harbor-secrets.sh
./scripts/gen-keycloak-db-secret.sh
./scripts/gen-oauth2-proxy-secrets.sh
./scripts/gen-oauth2-proxy-redis-secret.sh
```

### 2. Deploy

```sh
helm dependency update charts/infra
./scripts/deploy-infra.sh
```

### 3. Important manual steps

**Setup in Keycloak**

Client setup in master realm:
* Client ID: teknoir (or change oauth2-proxy to match)
* OpenID Connect
* Client authentication: ON (this is “confidential”)
* Standard flow: ON
* Service account roles: ON
* Valid redirect URI: https://teknoir.online/oauth2/callback
* Web origins: https://teknoir.online

Then update the secret:
* Take the client secret from Keycloak
* Update oauth2-proxy-secret (by running `./scripts/gen-oauth2-proxy-secrets.sh`)
* `./scripts/deploy-local.sh` to deploy secret to cluster

Then add client scope:
* Add (or create) a scope: teknoir
* Type: Default
  
Configure a new mapper for the scope:
* Mapper type: Audience
* Included Client Audience: teknoir
* Add to access token: ON

Then add Service Account Role:
* Go to Service Account Roles for the client click Assign Roles
* Assign "Client Roles": manage-users, query-users, view-users

Restart oauth2-proxy deployment to pick up new secret and scope changes:
```bash
kubectl -n teknoir-auth rollout restart deploy/oauth2-proxy
```

## Domain Cascading

You can change the entire environment domain by setting `global.domain` in `charts/infra/values.yaml` or via CLI:

```sh
helm template infra ./charts/infra --set global.domain=my-new-domain.com
```

## Layout

- `charts/infra`: umbrella chart combining all components.
- `charts/teknoir-gateway`: Istio Gateway and Cert-manager Certificate templates.
- `charts/auth`: Keycloak and OAuth2-proxy configuration.
- `charts/harbor`: Harbor configuration.
- `scripts/`: helper scripts for secret generation and deployment.
