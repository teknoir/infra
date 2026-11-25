# Infra

Umbrella Helm chart for bootstrapping ArgoCD GitOps for Infrastructure and Platform.

> The implementation of the Helm chart is the bare minimum.
> The Helm Chart is not meant to be infinitely configurable, but to provide a quick way to deploy to a Kubernetes cluster.

## Quick start

The infrastructure is now managed via GitOps from the repo `https://github.com/teknoir/platform-applications-gitops`.

### 1. Prerequisites (Secrets)

Secrets are managed manually. Generate them before deploying:

```sh
./scripts/create-clouddns-secret.sh <KEY_PATH>
./scripts/create-gcr-json-key-secret.sh <KEY_PATH>
./scripts/gen-harbor-secrets.sh
./scripts/gen-keycloak-db-secret.sh
./scripts/gen-oauth2-proxy-secrets.sh
./scripts/gen-oauth2-proxy-redis-secret.sh
...
```

#### STUNner TURN secret (WireGuard / ZTNA, staging)

`./scripts/gen-stunner-auth-secret.sh --context <context>` creates `stunner-system/stunner-auth-secret`
(`type: ephemeral`, `secret: <48 random bytes>`), the TURN-REST shared secret of the STUNner gateway in
`platform-applications-gitops` (`charts/stunner`, enabled with `ztna.enabled` on `teknoir-cloud`). Unlike the
scripts above it applies the Secret straight to the cluster and prints nothing secret. It needs an explicit
`--context` (never the current one), is idempotent (an existing Secret is left alone), creates the namespace with
`istio-injection=disabled` if missing, and refuses a production-looking context without `--allow-production`.
Rotating the secret (delete it, re-run the script) resets every WireGuard tunnel. Test:
`scripts/tests/gen-stunner-auth-secret-test.sh` (throwaway local apiserver, needs envtest).

### 2. Deploy

```sh
./scripts/staging-bootstrap.sh --context r415   # fresh r415 host: namespaces, Secrets, ArgoCD, the root
```

`deploy-argo.sh` is the first install only. `platform-applications-gitops` (staging: branch `main`, renamed from `teknoir-cloud` 2026-11-24) renders the Application
`teknoir-system/argo` from its own copy of `charts/argo`, with the same Helm release name (`argo`), so ArgoCD adopts this
install and manages itself; from then on change ArgoCD there, not in `charts/argo` here. Once that Application exists,
`deploy-argo.sh` changes nothing in the cluster: when it is Synced/Healthy it moves `teknoir-argo.yaml` out of the k3s
manifests directory (to `manifests-detached/`, so a k3s restart no longer re-applies it over the Application) and
otherwise warns; if it cannot read the cluster it stops without changing anything. `FORCE_DEPLOY=1` writes the file
anyway (break-glass, only when ArgoCD cannot fix itself): turn off automated sync on `app-of-apps` first (its selfHeal
would restore the next step), then on `argo`, run it, fix `charts/argo` in gitops to match, re-enable (`argo`, then
`app-of-apps`), and re-run `deploy-argo.sh` without `FORCE_DEPLOY` to detach the file again.

#### r415 root (the only staging root since CI v4 P7.1)

r415's root Application points at one **verified** commit of `platform-applications-gitops`, not at a branch or at a
`staging-YYYYMMDD.N` release, and Stage `platform/staging` moves `targetRevision` from then on. Three files, all infra
`main`:

- `clusters/r415/root.yaml`: the AppProject `default` plus the `teknoir-system/app-of-apps` Application with
  `targetRevision: __VERIFIED_SHA__`, the `kargo.akuity.io/authorized-stage: "platform:staging"` annotation and helm
  parameter `release=$ARGOCD_APP_REVISION`. The placeholder is never applied as is.
- `scripts/kargo-root.sh`: fills it from `--sha <40-hex>` or the newest stamped `verified/<UTC yyyymmddThhmmssZ>-<sha8>`
  tag, after checking that the commit is an ancestor of the gitops default branch. Print by default; `--check` prints
  `<sha> <tag>`; `--apply` needs `--context r415` and refuses to move a live root.
- `clusters/r415/BREAK-GLASS.md`: the only way to move a live root by hand. **Anders only**; agents never run it.

A fresh host is brought up with `scripts/staging-bootstrap.sh --context r415` (`--sha` names the commit), which
resolves and verifies the commit first (`kargo-root.sh --check`), before any namespace, Secret or ArgoCD change, and
passes it to `--apply` in step 3. `--host` defaults to `anders@192.168.2.166`; `K3S_MANIFESTS` defaults to
`/opt/k3s/server/manifests` (r415's k3s data-dir) and is passed to `deploy-argo.sh`. `--no-ci` skips the `teknoir-ci`
namespace and its `github-ci` Secret.
The external credentials come from the environment and are never printed; the script's header lists them. One of
them is TeknoirBot's model key: `TEKNOIRBOT_MODEL_KEY` (an Anthropic API key, best from a workspace with a monthly
spend limit) becomes data key `teknoir-demo` of Secret `teknoir-system/teknoirbot-model-keys`, which backstage-api
reads. A missing credential only warns; an existing Secret (for the model key: an existing `teknoir-demo` entry) is
kept unless `FORCE=1`. Add another teamspace's key with `kubectl patch` or
`kubectl apply --server-side --field-manager=teknoirbot-<namespace>`: if it is added under `staging-bootstrap` or with
a client-side `kubectl apply`, `FORCE=1` (and the next such apply) deletes the other entries.
Design: `plans/cicd/proposal-v4.md` sections 3.1-3.4 and 6.2; tests: `scripts/tests/kargo-root-test.sh`.

### 3. Important manual steps

**Setup in Keycloak**

Client setup in master realm:
* Client ID: teknoir (or change oauth2-proxy to match)
* OpenID Connect
* Client authentication: ON (this is “confidential”)
* Standard flow: ON
* Service account roles: ON
* Valid redirect URI: https://teknoir.cloud/oauth2/callback
* Web origins: https://teknoir.cloud

Then update the secret:
* Take the client secret from Keycloak
* Update oauth2-proxy-secret (by running `./scripts/gen-oauth2-proxy-secrets.sh`)
* `./scripts/deploy-secrets.sh` to deploy secret to cluster

Then go to Client scopes menu:
* Add (or create) a scope: teknoir
* Type: Default
  
Configure a new mapper for the scope:
* Mapper type: Audience
* Included Client Audience: teknoir
* Add to access token: ON

Then add Service Account Role:
* Go to Client menu for teknoir -> Service Account Roles for the client click Assign Roles
* Assign "Client Roles": manage-users, query-users, view-users

Restart oauth2-proxy deployment to pick up new secret and scope changes:
```bash
kubectl -n teknoir-auth rollout restart deploy/oauth2-proxy
```

## Backstage Keycloak secrets

The Backstage Keycloak client secrets are no longer generated by this repo as a k3s manifest
(`scripts/gen-backstage-keycloak-secrets.sh` was removed). They are managed by the GitOps
`platform-secrets` chart in `platform-applications-gitops` (branch `main` for staging).
On an existing host, remove the stale `/opt/k3s/server/manifests/teknoir-backstage-keycloak-secrets.yaml` manually.
