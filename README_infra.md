# Infra Chart & Scripts

Details of the infra-side pieces of the air-gapped `teknoir-local` platform:
the bootstrap ArgoCD chart, the secret model, and the `scripts/` helpers.
For the end-to-end procedures see
[docs/AIRGAP-HOST-SETUP.md](docs/AIRGAP-HOST-SETUP.md) (offline node
preparation, before bootstrap),
[docs/AIRGAP-BOOTSTRAP.md](docs/AIRGAP-BOOTSTRAP.md) and
[docs/AIRGAP-UPDATE.md](docs/AIRGAP-UPDATE.md).

## `charts/argo` — bootstrap ArgoCD

Umbrella chart around the upstream `argo-cd` chart (pinned dependency,
vendored for offline use), rendered by `airgap/render-bootstrap.sh` into the
static bootstrap manifest `10-teknoir-argo.yaml`.

* **Istio integration**: the chart's own templates add a `VirtualService`
  (`argocd.teknoir.airgapped` on the `istio-system/teknoir-gateway`), a
  `DestinationRule`, and an `AuthorizationPolicy`. TLS terminates at the
  gateway; ArgoCD runs with `--insecure` behind it.
* **OIDC**: native ArgoCD OIDC against Keycloak
  (`https://auth.teknoir.airgapped/auth/realms/master`, client `argocd`, secret
  from the `argocd-oidc-secret` Kubernetes secret). The Keycloak `admin` /
  `argocd-admins` groups map to `role:admin`; everyone else is read-only.
  Client setup walkthrough: `charts/argo/README.md`.
* **Air-gap override**: the ArgoCD redis image is pinned to
  `docker.io/library/redis` (the upstream default lives on `public.ecr.aws`,
  which the Harbor mirrors do not cover).

Domain settings (`domain: teknoir.airgapped`,
`argo-cd.global.domain: argocd.teknoir.airgapped`) live in
`charts/argo/values.yaml`.

## Secret management

Secrets are NOT managed by Helm templates or ArgoCD. Generators in `scripts/`
write their `manifest-*.yaml` files into `.secrets/` (alongside the CA key
material under `.secrets/ca/`); `deploy-secrets.sh` copies them from there to
the node's K3s auto-deploy directory. The manifest names in the table below
are relative to `.secrets/`.

**Gitignore policy:** the whole `.secrets/` directory (plus `airgap/.secrets/`,
any stray `manifest-*.yaml`, `teknoir-root-ca.crt`, `bundle/`) is gitignored.
Generated secrets exist only on the operator laptop / USB — never in git.

### Generators

| Script | Manifest | Secret (namespace) | Input |
|---|---|---|---|
| `gen-local-ca-secret.sh` | `manifest-teknoir-ca-secret.yaml`, `manifest-wildcard-tls-secret.yaml` (+ `teknoir-root-ca.crt`) | `teknoir-root-ca` (`cert-manager`), `teknoir-local-wildcard-tls` (`istio-system`) | none — CA (10y) reused from `.secrets/ca/`, wildcard (1y) re-issued |
| `gen-harbor-secrets.sh` | `manifest-harbor-secret.yaml` | `harbor-secret` (`teknoir-system`) | none — random; prints the admin password |
| `gen-keycloak-db-secret.sh` | `manifest-keycloak-db-secret.yaml` | `keycloak-db-secret` (`teknoir-auth`) | optional `[username] [password]` args |
| `gen-oauth2-proxy-secrets.sh` | `manifest-oauth2-proxy-secret.yaml` | `oauth2-proxy-secret` (`teknoir-auth`) | prompts for the Keycloak `teknoir` client secret |
| `gen-oauth2-proxy-redis-secret.sh` | `manifest-oauth2-proxy-redis-secret.yaml` | `oauth2-proxy-redis-secret` (`teknoir-auth`) | optional password arg |
| `gen-argocd-keycloak-secrets.sh` | `manifest-argocd-keycloak-secret.yaml` | `argocd-oidc-secret` (`teknoir-system`) | prompts for the Keycloak `argocd` client secret |
| `gen-argocd-harbor-repo-secret.sh` | `manifest-argocd-harbor-repo-secret.yaml` | `argocd-harbor-repo` (`teknoir-system`) | `airgap/.secrets/robot-argocd.env` (from `push-to-harbor.sh`); admin fallback |

`argocd-harbor-repo` is an ArgoCD `repo-creds` secret
(`enableOCI: "true"`, `url: harbor.teknoir.airgapped/teknoir`) — it should carry
the `robot$argocd` credential, not admin. `push-to-harbor.sh` rotates that
robot credential on every run, so regenerate + redeploy after each push.

### Deploying secrets

```sh
TEKNOIR_HOST=teknoir@teknoir.airgapped ./scripts/deploy-secrets.sh
```

Copies every existing `.secrets/manifest-<name>.yaml` over ssh to
`/opt/k3s/server/manifests/teknoir-<name>.yaml` (the `teknoir-` prefix is
added unless already present); the K3s deploy controller applies them.
Missing manifests are warned about and skipped. During first bootstrap the
same manifests travel inside the bundle (`bootstrap/secrets/`) and are
deployed by `airgap/bootstrap-airgap.sh` instead.

## Deploy helpers

* `scripts/deploy-argo.sh` — renders `charts/argo` with
  `charts/argo/values.yaml` and copies the result to
  `/opt/k3s/server/manifests/teknoir-argo.yaml` over ssh. Useful for iterating
  on the ArgoCD chart directly against the node; the bundle flow renders the
  same chart into `10-teknoir-argo.yaml` instead.
* `scripts/deploy-secrets.sh` — see above.
* Both honor `TEKNOIR_HOST` (default `teknoir@teknoir.airgapped`).

## Domain cascading

The chart supports a `domain` setting that cascades to sub-charts
(`charts/argo/values.yaml`, and `--set domain=… --set global.domain=…` in the
airgap tooling — see `chart_template_args` in `airgap/lib.sh`). Sub-domains
like `argocd.teknoir.airgapped`, `harbor.teknoir.airgapped`, `auth.teknoir.airgapped`
derive from it. The full hostname list lives in `airgap/versions.env`
(`TEKNOIR_HOSTNAMES`).
