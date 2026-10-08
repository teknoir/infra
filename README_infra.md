# Infra Chart & Scripts

Details of the infra-side pieces of the air-gapped `teknoir-local` platform:
the ownership model, the bootstrap ArgoCD chart, the secret model, and the
`scripts/` helpers. For the end-to-end procedures see
[docs/AIRGAP-HOST-SETUP.md](docs/AIRGAP-HOST-SETUP.md) (offline node
preparation, before bootstrap),
[docs/AIRGAP-BOOTSTRAP.md](docs/AIRGAP-BOOTSTRAP.md) and
[docs/AIRGAP-UPDATE.md](docs/AIRGAP-UPDATE.md).

## Ownership model

Infra stays thin: it only bootstraps what must exist before ArgoCD can pull
from Harbor. Everything else is GitOps (`platform-applications-gitops`, branch
`teknoir-local`).

| Objects | Owner | Delivered by |
|---|---|---|
| Namespaces, istio + cert-manager CRDs, ArgoCD, root `app-of-apps`, secrets, `coredns-custom` | K3s | one file each in `/opt/k3s/server/manifests/` (table below) |
| Istio, Harbor | ArgoCD | one-shot apply at first bootstrap, then adopted by their Applications |
| auth, cert-manager, monitoring, controllers, and the controller + monitoring CRDs | ArgoCD | `app-of-apps` from `oci://harbor.teknoir.airgapped/teknoir` |
| Wildcard TLS secret `teknoir-airgapped-wildcard-tls` | cert-manager | placeholder created once at first bootstrap |

**K3s files: one canonical name per object.** K3s turns every file in the
manifests dir into an Addon that owns what it applies, so two files with the
same objects fight (a stale copy once reverted the Harbor robot token, and the
app-of-apps sync freeze had to be applied to two files). Every script deploys
through `airgap/lib.sh:k3s_deploy`, which writes the file atomically, waits
until K3s has applied it, and moves legacy duplicates to
`/opt/k3s/server/manifests-retired/` once the canonical Addon owns every
object:

| Canonical file | Written by | Legacy names retired |
|---|---|---|
| `00-teknoir-namespaces.yaml`, `00-teknoir-istio-crds.yaml`, `05-teknoir-certmanager-crds.yaml`, `teknoir-coredns-custom.yaml` | `bootstrap-airgap.sh` | — |
| `teknoir-argo.yaml` | `bootstrap-airgap.sh`, `scripts/deploy-argo.sh` | `10-teknoir-argo.yaml` |
| `teknoir-app-of-apps.yaml` | `bootstrap-airgap.sh`, `deploy-app-of-apps.sh`, `update-airgap.sh` | `app-of-apps.yaml` |
| `teknoir-<name>.yaml` (secrets, mode 600) | `scripts/deploy-secrets.sh` | `manifest-<name>.yaml` |

**CRDs.** ArgoCD manages CRDs (`charts/argo` no longer excludes them):

* controller (`teknoir.org`) and monitoring (`monitoring.coreos.com`) CRDs come
  from their charts, which mark them `Prune=false,Delete=false`;
* istio and cert-manager CRDs are bootstrap-owned (needed before ArgoCD runs).
  Their Applications set `helm.skipCrds`, the istio chart lists all of its
  templated CRDs in `istio-base.base.excludedCRDs` (the bootstrap render
  clears that list), and `render-bootstrap.sh` annotates them
  `argocd.argoproj.io/sync-options: Prune=false,Delete=false` +
  `compare-options: IgnoreExtraneous`, so ArgoCD can never delete them.
  ArgoCD is only (re)deployed once that holds (`lib.sh:argocd_crd_gate`).
  During the one-time hand-over from an ArgoCD that still excludes CRDs, the
  `istio` Application must also run a CRD-free istio (>= 0.0.2) first, and
  the automated syncs that failed under the exclusion are re-run afterwards
  ([AIRGAP-UPDATE.md §2.4](docs/AIRGAP-UPDATE.md)).

**Charts are released once.** `airgap/versions.env` pins every chart version
the root app-of-apps deploys: `GITOPS_CHARTS` (built from the gitops working
tree at exactly that version) and `RELEASED_CHARTS` (already in Harbor, never
rebuilt). `push-to-harbor.sh` pushes only versions Harbor does not have, and a
tag-immutability rule on the project `teknoir` refuses overwrites. Changing a
chart means bumping its version.

## `charts/argo` — bootstrap ArgoCD

Umbrella chart around the upstream `argo-cd` chart (pinned dependency,
vendored for offline use), rendered by `airgap/lib.sh:helm_template_chart`
into `teknoir-argo.yaml` (by `render-bootstrap.sh` for the bundle and by
`scripts/deploy-argo.sh` from a checkout; both produce the same file).

* **Istio integration**: the chart's own templates add a `VirtualService`
  (`argocd.teknoir.airgapped` on the `istio-system/teknoir-gateway`), a
  `DestinationRule`, and an `AuthorizationPolicy`. TLS terminates at the
  gateway; ArgoCD runs with `--insecure` behind it.
* **OIDC**: native ArgoCD OIDC against Keycloak
  (`https://auth.teknoir.airgapped/auth/realms/master`, client `argocd`, secret
  from the `argocd-oidc-secret` Kubernetes secret). The Keycloak `admin` /
  `argocd-admins` groups map to `role:admin`; everyone else is read-only.
  Client setup walkthrough: `charts/argo/README.md`.
* **CA trust**: the Teknoir Root CA is injected at render time into
  `argocd-tls-certs-cm` (repo-server → Harbor) and the `oidc.config` `rootCA`
  (argocd-server → Keycloak).
* **Resource exclusions**: the upstream default list, with no CRD exclusion
  (see Ownership model).
* **Air-gap override**: the ArgoCD redis image is pinned to
  `docker.io/library/redis` (the upstream default lives on `public.ecr.aws`,
  which the Harbor mirrors do not cover).

Domain settings (`domain: teknoir.airgapped`,
`argo-cd.global.domain: argocd.teknoir.airgapped`) live in
`charts/argo/values.yaml`.

## Secret management

Secrets are NOT managed by Helm templates or ArgoCD. Generators in `scripts/`
write their `manifest-*.yaml` files into `.secrets/` (alongside the CA key
material under `.secrets/ca/`); `deploy-secrets.sh` installs them on the node.
The manifest names in the table below are relative to `.secrets/`.

**Gitignore policy:** the whole `.secrets/` directory (plus `airgap/.secrets/`,
any stray `manifest-*.yaml`, `teknoir-root-ca.crt`, `bundle/`) is gitignored.
Generated secrets exist only on the operator laptop / USB — never in git.

### Generators

| Script | Manifest | Secret (namespace) | Input |
|---|---|---|---|
| `gen-local-ca-secret.sh` | `manifest-teknoir-ca-secret.yaml`, `manifest-wildcard-tls-secret.yaml`, `manifest-teknoir-auth-ca-bundle-secret.yaml`, `manifest-teknoir-system-ca-bundle-secret.yaml` (+ `teknoir-root-ca.crt`) | `teknoir-root-ca` (`cert-manager`), `teknoir-airgapped-wildcard-tls` (`istio-system`), `teknoir-root-ca-bundle` (`teknoir-auth`, `teknoir-system`) | none — CA (10y) reused from `.secrets/ca/`, wildcard (1y) re-issued |
| `gen-harbor-secrets.sh` | `manifest-harbor-secret.yaml` | `harbor-secret` (`teknoir-system`) | none — random; prints the admin password |
| `gen-keycloak-db-secret.sh` | `manifest-keycloak-db-secret.yaml` | `keycloak-db-secret` (`teknoir-auth`) | optional `[username] [password]` args |
| `gen-oauth2-proxy-secrets.sh` | `manifest-oauth2-proxy-secret.yaml` | `oauth2-proxy-secret` (`teknoir-auth`) | prompts for the Keycloak `teknoir` client secret — run **after** the client exists in Keycloak |
| `gen-oauth2-proxy-redis-secret.sh` | `manifest-oauth2-proxy-redis-secret.yaml` | `oauth2-proxy-redis-secret` (`teknoir-auth`) | optional password arg |
| `gen-argocd-keycloak-secrets.sh` | `manifest-argocd-keycloak-secret.yaml` | `argocd-oidc-secret` (`teknoir-system`) | prompts for the Keycloak `argocd` client secret — run **after** the client exists in Keycloak |
| `gen-argocd-harbor-repo-secret.sh` | `manifest-argocd-harbor-repo-secret.yaml` | `argocd-harbor-repo` (`teknoir-system`) | `airgap/.secrets/robot-argocd.env`; admin fallback before the robot exists |

`gen-oauth2-proxy-secrets.sh` and `gen-argocd-keycloak-secrets.sh` prompt for a
Keycloak client secret, which only exists after Keycloak is deployed and the
`teknoir` / `argocd` clients have been created manually. Run them as part of the
Keycloak configuration steps (§8 in
[docs/AIRGAP-BOOTSTRAP.md](docs/AIRGAP-BOOTSTRAP.md)), not during initial secret
generation.

### Harbor robot credential (never rotated implicitly)

`argocd-harbor-repo` is an ArgoCD `repo-creds` secret (`enableOCI: "true"`,
`url: harbor.teknoir.airgapped/teknoir`) carrying the `robot$argocd`
credential. `airgap/.secrets/robot-argocd.env` is its single source of truth.
`airgap/push-to-harbor.sh` creates the robot if missing (with the stored
credential, or a newly generated one when there is no file yet), enforces its
pull-only permissions on every run, and regenerates the manifest
(byte-identical when nothing changed). It sets the robot's secret in Harbor
only when it creates the robot, or with `--rotate-robot`. If the robot exists
and the file is missing, or Harbor rejects the stored credential (a stale
copy: the robot was rotated from another machine), it refuses instead of
overwriting Harbor, which would break the credential ArgoCD uses.

The file is gitignored and never travels in a bundle. Running from a bundle
directory (or another checkout), copy the operator's `robot-argocd.env` to
`<dir>/airgap/.secrets/`, or point `--robot-env FILE` (`ROBOT_ENV_FILE`) at it.

```sh
HARBOR_ADMIN_PASSWORD='…' ./airgap/push-to-harbor.sh --robot-only    # robot + manifest only
HARBOR_ADMIN_PASSWORD='…' ./airgap/push-to-harbor.sh --rotate-robot  # deliberate rotation
./scripts/deploy-secrets.sh --only manifest-argocd-harbor-repo-secret.yaml
```

### Deploying secrets

```sh
./scripts/deploy-secrets.sh [--only manifest-<name>.yaml] [--dry-run]
```

Installs every existing `.secrets/manifest-<name>.yaml` over ssh as
`/opt/k3s/server/manifests/teknoir-<name>.yaml` (mode 600, via `k3s_deploy`,
retiring a legacy `manifest-<name>.yaml`). Unchanged secrets are not re-applied
by K3s. The wildcard TLS placeholder is only created with
`--bootstrap-wildcard`, and only when the Secret does not exist (cert-manager
owns it afterwards). The first bootstrap deploys the bundle copies with
`--secrets-dir <bundle>/bootstrap/secrets --create-only`, which never replaces
a Secret that already exists.

## Deploy helpers

* `scripts/deploy-argo.sh [--out FILE] [--dry-run]` — renders this checkout's
  `charts/argo` (same render as the bundle) and deploys it as
  `teknoir-argo.yaml`, retiring `10-teknoir-argo.yaml`. From an unpacked bundle,
  use `airgap/bootstrap-airgap.sh --update` instead.
* `scripts/deploy-secrets.sh` — see above.
* Both run from any directory and honor `TEKNOIR_HOST` (default
  `teknoir@teknoir.airgapped`) and `SSH_KEY`.

## Domain cascading

The chart supports a `domain` setting that cascades to sub-charts
(`charts/argo/values.yaml`, and `--set domain=… --set global.domain=…` in the
airgap tooling — see `chart_template_args` in `airgap/lib.sh`). Sub-domains
like `argocd.teknoir.airgapped`, `harbor.teknoir.airgapped`, `auth.teknoir.airgapped`
derive from it. The full hostname list lives in `airgap/versions.env`
(`TEKNOIR_HOSTNAMES`).
