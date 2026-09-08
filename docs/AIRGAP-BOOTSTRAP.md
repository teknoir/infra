# Air-Gap Bootstrap Runbook (first install)

First-time installation of the Teknoir platform (`teknoir-local`) on an
air-gapped K3s node. All Helm charts and container images are delivered via a
portable bundle (USB) and served from the in-cluster Harbor registry — no
internet access is required on the node or the LAN.

## 1. Overview

Three machines are involved:

```
[connected workstation]              [laptop on LAN]                  [teknoir@teknoir.airgapped (K3s)]
make-bundle.sh ──► USB ──► bootstrap-airgap.sh ── ssh ──► CA + registries.yaml + /etc/hosts + image tarballs
                                                          restart k3s
                                                          secrets (incl. wildcard-tls) + coredns-custom
                                                          istio manifests → argo + harbor manifests
                                                          (auto-deploy → Istio gw :443, ArgoCD, Harbor up)
                           push-to-harbor.sh ── https ──► projects + robot$argocd, push charts + images
                           deploy-app-of-apps.sh ─ ssh ─► app-of-apps (oci://harbor…/teknoir/app-of-apps)
                                                          ArgoCD adopts istio + harbor, syncs auth,
                                                          cert-manager, monitoring, controllers
                           runbook (manual) ────────────► Keycloak clients (argocd, harbor) + Harbor OIDC
```

The **bootstrap tier** (Istio → ArgoCD → Harbor) is installed from static,
pre-rendered manifests via the K3s auto-deploy directory, in that order, with
health waits between tiers. Once Harbor is populated, ArgoCD **adopts** the
running Istio and Harbor through its own `istio`/`harbor` Applications
(`ServerSideApply=true`, same chart versions ⇒ no drift, no recreation) and
syncs the GitOps tier (auth, cert-manager, monitoring, controllers) from
`oci://harbor.teknoir.airgapped/teknoir`.

## 2. Prerequisites

### Connected workstation (bundle build)

* This repo (`infra`, branch `teknoir-local`) and the GitOps repo
  (`platform-applications-gitops`, branch `teknoir-local`) checked out as
  siblings — or set `GITOPS_REPO_DIR` (default: `../platform-applications-gitops`).
* Tools: `helm`, `crane`, `curl`, `tar`, `openssl`, `python3` (with PyYAML, or
  `yq`, for ArgoCD adoption labels).
* Internet access (to pull chart dependencies, images, and pinned tools).

### LAN laptop (air-gapped side)

* SSH access to the node with passwordless `sudo`
  (default target `teknoir@teknoir.airgapped`, override with `TEKNOIR_HOST` or `--host`).
  The SSH key pair is **generated externally** and kept under `.secrets/`; use
  the private key explicitly, e.g.:

  ```sh
  ssh teknoir@teknoir.airgapped -i .secrets/teknoir.airgapped.id_rsa
  ```
* Tools: `ssh`, `curl`, `helm`, `crane`, `python3`. Pinned `helm` and `crane`
  binaries for `linux/amd64` and `darwin/arm64` ship in the bundle under `tools/`.
* Name resolution for all platform hostnames pointing at the node IP. Both the
  apex `teknoir.airgapped` **and** the `*.teknoir.airgapped` wildcard (every
  subdomain — `harbor.`, `argocd.`, `auth.`, `keycloak.`, `grafana.`, …) must be
  resolvable on the LAN. `bootstrap-airgap.sh` only manages the *node's* own
  hosts file, so provide resolution on the laptop one of two ways:
  * **`/etc/hosts`** — list every hostname explicitly (hosts files cannot express
    a wildcard, so each subdomain must be spelled out):

    ```sh
    # /etc/hosts on the laptop (node static IP; see NODE_IP in airgap/versions.env)
    192.168.5.181 harbor.teknoir.airgapped argocd.teknoir.airgapped auth.teknoir.airgapped keycloak.teknoir.airgapped grafana.teknoir.airgapped teknoir.airgapped
    ```
  * **LAN DNS** — if a resolver is available, add an `A` record for
    `teknoir.airgapped` and a wildcard `*.teknoir.airgapped` `A` record, both
    pointing at the node IP (`192.168.5.181`).

### K3s node

* Host prepared per [AIRGAP-HOST-SETUP.md](AIRGAP-HOST-SETUP.md) — Debian 13
  installed offline, K3s installed with `data-dir: /opt/k3s` (`K3S_DATA_DIR`,
  override in the environment if different), traefik disabled, and
  `max-pods=250`. The tooling uses:
  * `/opt/k3s/server/manifests/` — auto-deploy manifests,
  * `/opt/k3s/agent/images/` — image tarballs re-imported on every K3s start.

## 3. Generate secrets (connected workstation)

All generators write their `manifest-*.yaml` files into `.secrets/` (alongside
the CA key material under `.secrets/ca/`). The whole `.secrets/` directory is
**gitignored** — the manifests contain live credentials and exist only on the
operator laptop / USB. `make-bundle.sh` copies them from `.secrets/` into
`bundle/…/bootstrap/secrets/`.

```sh
./scripts/gen-local-ca-secret.sh
./scripts/gen-harbor-secrets.sh                 # note the printed admin password
./scripts/gen-keycloak-db-secret.sh
./scripts/gen-oauth2-proxy-secrets.sh           # prompts for a Keycloak client secret (see note)
./scripts/gen-oauth2-proxy-redis-secret.sh
./scripts/gen-argocd-keycloak-secrets.sh        # prompts for a Keycloak client secret (see note)
./scripts/gen-argocd-harbor-repo-secret.sh      # admin fallback on first run (see note)
```

| Script | Manifest | Secret (namespace) |
|---|---|---|
| `gen-local-ca-secret.sh` | `manifest-teknoir-ca-secret.yaml` | `teknoir-root-ca` (`cert-manager`) |
| `gen-local-ca-secret.sh` | `manifest-wildcard-tls-secret.yaml` | `teknoir-local-wildcard-tls` (`istio-system`) |
| `gen-harbor-secrets.sh` | `manifest-harbor-secret.yaml` | `harbor-secret` (`teknoir-system`) |
| `gen-keycloak-db-secret.sh` | `manifest-keycloak-db-secret.yaml` | `keycloak-db-secret` (`teknoir-auth`) |
| `gen-oauth2-proxy-secrets.sh` | `manifest-oauth2-proxy-secret.yaml` | `oauth2-proxy-secret` (`teknoir-auth`) |
| `gen-oauth2-proxy-redis-secret.sh` | `manifest-oauth2-proxy-redis-secret.yaml` | `oauth2-proxy-redis-secret` (`teknoir-auth`) |
| `gen-argocd-keycloak-secrets.sh` | `manifest-argocd-keycloak-secret.yaml` | `argocd-oidc-secret` (`teknoir-system`) |
| `gen-argocd-harbor-repo-secret.sh` | `manifest-argocd-harbor-repo-secret.yaml` | `argocd-harbor-repo` (`teknoir-system`) |

Notes:

* **`gen-local-ca-secret.sh`** creates the Teknoir Local Root CA (10 years,
  key material under `.secrets/ca/`, reused on re-runs) and issues the
  pre-issued `*.teknoir.airgapped` wildcard server certificate (1 year) so the
  Istio gateway can terminate TLS from the very first boot. It also writes
  `teknoir-root-ca.crt` to the repo root — this public cert goes into the
  bundle, the node's containerd trust config, and your browsers (see §9).
  Once the GitOps tier runs, the cert-manager `ClusterIssuer` `teknoir-ca`
  (backed by the `teknoir-root-ca` secret) takes over wildcard-cert renewal
  in place (same `secretName`).
* **Keycloak client secrets are not available yet** at first bootstrap
  (Keycloak is GitOps-tier). Enter a placeholder when
  `gen-oauth2-proxy-secrets.sh` / `gen-argocd-keycloak-secrets.sh` prompt; you
  will regenerate and redeploy these secrets after creating the clients in §8.
* **`gen-argocd-harbor-repo-secret.sh`** prefers the `robot$argocd` credential
  written by `airgap/push-to-harbor.sh` to `airgap/.secrets/robot-argocd.env`.
  That file does not exist yet, so the first run falls back to the Harbor
  admin credential (parsed from `.secrets/manifest-harbor-secret.yaml`) — this is
  expected; you replace it with the robot credential in §6.
* Run `gen-harbor-secrets.sh` **before** `gen-argocd-harbor-repo-secret.sh`
  (the admin fallback parses its manifest).

## 4. Build the bundle (connected workstation)

Versions are pinned centrally in `airgap/versions.env` (chart versions, Istio /
ArgoCD / Harbor versions, tool versions, mirrored registries, hostnames).
Extra images that `helm template` cannot discover (Istio sidecar `proxyv2`,
pause, busybox, redis, postgres) are listed in `airgap/images-extra.txt`.

```sh
./airgap/make-bundle.sh                 # add --dry-run to preview
./airgap/verify-offline.sh              # offline-readiness gate (see below)
```

`make-bundle.sh` orchestrates seven steps and produces
`bundle/teknoir-airgap-bundle-<version>/`:

```
teknoir-airgap-bundle-<version>/
├── bundle-manifest.yaml          # sha256 checksum of every file
├── bootstrap/
│   ├── images/                   # containerd tarballs: istio (pilot, proxyv2), argo-cd, harbor, pause
│   ├── manifests/                # 00-teknoir-istio.yaml, 10-teknoir-argo.yaml, 20-teknoir-harbor.yaml, app-of-apps.yaml
│   ├── secrets/                  # the manifest-*.yaml files from §3
│   └── k3s/                      # registries.yaml, teknoir-root-ca.crt, coredns-custom.yaml
├── charts/                       # <chart>-<version>.tgz for every GitOps chart (deps vendored)
├── images/                       # workload images as OCI layouts (crane), digest-deduplicated
├── tools/                        # pinned crane + helm binaries (linux-amd64, darwin-arm64)
└── k3s/                          # offline K3s install: k3s binary, install.sh, airgap-images tarball (see AIRGAP-HOST-SETUP.md)
```

The individual steps can also be run standalone (each supports `--dry-run` and
`--bundle-dir DIR`):

* `airgap/collect-charts.sh` — `helm dependency build` + `helm package` every
  GitOps chart plus the infra `argo` chart into `charts/`.
* `airgap/collect-images.sh` — extracts image refs from the rendered charts,
  merges `images-extra.txt`, pulls everything as OCI layouts; bootstrap-tier
  images (istio, argo, harbor, pause) additionally as containerd tarballs.
* `airgap/render-bootstrap.sh` — `helm template` of gitops `charts/istio`,
  infra `charts/argo`, gitops `charts/harbor` with `teknoir.airgapped` values into
  the ordered `00-`/`10-`/`20-` manifests (istio/harbor renders are labeled
  `app.kubernetes.io/instance: <app>` for ArgoCD adoption); also emits
  `registries.yaml`, `coredns-custom.yaml`, and copies `teknoir-root-ca.crt`.

`verify-offline.sh` syntax-checks every script (`bash -n` + `shellcheck`),
templates every chart, and fails on any rendered reference to
`teknoir.cloud`, `github.com`, or `storage.googleapis.com`.

## 5. Transfer via USB

Copy the **infra repo checkout including `bundle/`** to the USB drive and then
onto the LAN laptop — the laptop needs both the `airgap/` scripts and the
bundle (plus `scripts/gen-argocd-harbor-repo-secret.sh` and
`scripts/deploy-secrets.sh` for §6).

Verify integrity after the copy using the checksum manifest:

```sh
cd bundle/teknoir-airgap-bundle-<version>
awk '/^  - path: /{p=$3} /^    sha256: /{print $2 "  " p}' bundle-manifest.yaml | shasum -a 256 -c -
```

## 6. Install (LAN laptop)

### 6.1 Bootstrap the node

```sh
./airgap/bootstrap-airgap.sh [--host teknoir@teknoir.airgapped] [--node-ip IP] [--dry-run]
```

Over SSH this: installs the Root CA (`/etc/rancher/k3s/teknoir-root-ca.crt` +
system trust), installs the K3s registry mirrors
(`/etc/rancher/k3s/registries.yaml` — all five upstream registries rewritten to
`https://harbor.teknoir.airgapped`), writes the `/etc/hosts` marker block on the
node, copies the bootstrap image tarballs to `/opt/k3s/agent/images/`, restarts
K3s (re-importing the tarballs), deploys all secret manifests plus the
`coredns-custom` ConfigMap, and then lands the ordered bootstrap manifests in
`/opt/k3s/server/manifests/` — waiting for health between tiers:

1. `00-teknoir-istio.yaml` → waits for `istiod` and `istio-ingressgateway`,
2. `10-teknoir-argo.yaml` → waits for `argocd-server`,
3. `20-teknoir-harbor.yaml` → waits for Harbor pods **and** verifies every
   Harbor pod carries an `istio-proxy` sidecar (STRICT mTLS sanity check).

The node IP defaults to `NODE_IP` in `airgap/versions.env` (`192.168.5.181`); if
that is unset it is auto-detected over SSH. Pass `--node-ip` to override either.

### 6.2 Populate Harbor

```sh
HARBOR_ADMIN_PASSWORD='<from gen-harbor-secrets.sh>' ./airgap/push-to-harbor.sh [--dry-run]
```

Idempotently: creates the six Harbor projects (`teknoir` private for charts;
`dockerhub`, `ghcr`, `gcr`, `quay`, `k8s` public mirrors so containerd can pull
unauthenticated), creates/rotates the system robot account **`robot$argocd`**
(pull-only on all projects) and writes its credential to
`airgap/.secrets/robot-argocd.env`, `helm push`es every chart to
`oci://harbor.teknoir.airgapped/teknoir`, and `crane push`es every image into its
mirror project. TLS uses the bundle's `teknoir-root-ca.crt` (or `--insecure`).

### 6.3 Switch ArgoCD to the robot credential

The `argocd-harbor-repo` secret generated in §3 used the admin fallback.
Regenerate it with the robot credential and redeploy:

```sh
./scripts/gen-argocd-harbor-repo-secret.sh    # now picks up airgap/.secrets/robot-argocd.env
./scripts/deploy-secrets.sh                   # copies all manifest-*.yaml to the node's auto-deploy dir
```

> `push-to-harbor.sh` **rotates** the robot secret on every run — repeat this
> step after each future push.

### 6.4 Deploy the app-of-apps

```sh
./airgap/deploy-app-of-apps.sh [--dry-run]
```

Copies the bundle's `app-of-apps.yaml` (AppProject + Application with source
`oci://harbor.teknoir.airgapped/teknoir`, chart `app-of-apps`, pinned
`targetRevision`) to `/opt/k3s/server/manifests/teknoir-app-of-apps.yaml`.
ArgoCD then adopts the bootstrap-installed `istio` and `harbor` (both
Applications sync with `ServerSideApply=true`, project `teknoir-local`) and
syncs `auth`, `cert-manager`, `monitoring`, and the controllers.

## 7. Verification

```sh
# Gateway terminates 443 on the node IP
curl --cacert teknoir-root-ca.crt -sSI https://harbor.teknoir.airgapped/ | head -1
curl --cacert teknoir-root-ca.crt -sSI https://argocd.teknoir.airgapped/ | head -1

# All Applications Synced/Healthy
ssh teknoir@teknoir.airgapped sudo k3s kubectl -n teknoir-system get applications

# Istio adoption OK: empty diff = ArgoCD render matches the bootstrap render
argocd login argocd.teknoir.airgapped --grpc-web
argocd app diff istio        # no output = adopted without drift
argocd app diff harbor
```

Also check in a browser (after §9 CA distribution): `https://harbor.teknoir.airgapped`
and `https://argocd.teknoir.airgapped` load with a trusted certificate.

## 8. Keycloak configuration (mandatory)

Keycloak arrives with the GitOps `auth` chart at
`https://auth.teknoir.airgapped/auth/` (realm `master`). Log in with the Keycloak
admin credential, then create the OIDC clients:

### 8.1 `argocd` client

* Client ID: `argocd`, protocol OpenID Connect
* Client authentication: ON (confidential), Standard flow: ON
* Valid redirect URI: `https://argocd.teknoir.airgapped/auth/callback`
* Add a `groups` client scope with a Group Membership mapper (token claim
  `groups`, full group path OFF) and assign it to the client — ArgoCD maps the
  Keycloak `admin` group to `role:admin` (see `charts/argo/values.yaml` and
  `charts/argo/README.md` for the detailed walkthrough).

Then feed the client secret to ArgoCD:

```sh
./scripts/gen-argocd-keycloak-secrets.sh      # paste the client secret
./scripts/deploy-secrets.sh
ssh teknoir@teknoir.airgapped sudo k3s kubectl -n teknoir-system rollout restart deploy -l app.kubernetes.io/name=argocd-server
```

### 8.2 `harbor` client

* Client ID: `harbor`, protocol OpenID Connect
* Client authentication: ON (confidential), Standard flow: ON
* Valid redirect URIs: `https://harbor.teknoir.airgapped/*`
* Base URL: `https://harbor.teknoir.airgapped`

Copy the client secret from the **Credentials** tab, then in the Harbor UI
(logged in as `admin`) go to **Configuration → Authentication**:

| Setting | Value |
|---|---|
| Auth Mode | `OIDC` |
| OIDC Provider Name | `Keycloak` |
| OIDC Endpoint | `https://auth.teknoir.airgapped/auth/realms/master` |
| OIDC Client ID | `harbor` |
| OIDC Client Secret | (from Keycloak) |
| Scope | `openid,profile,email` |
| Verify Certificate | **ON** (the endpoint serves the wildcard cert signed by the Teknoir Root CA — see §9) |
| OIDC User Claim | `preferred_username` |
| OIDC Admin Group | `admin` |

**Break-glass:** the local `admin` account (password from
`gen-harbor-secrets.sh` / `harbor-secret`) remains available at
`https://harbor.teknoir.airgapped/account/sign-in` even with OIDC enabled.

**CLI access:** Docker/Helm CLIs cannot follow OIDC redirects. Use **robot
accounts** for automation (as `push-to-harbor.sh` and ArgoCD do), or your
personal **CLI secret** (Harbor UI → profile → CLI Secret) as the CLI password.
The registry/API path is unaffected by the auth mode.

### 8.3 `teknoir` client (oauth2-proxy)

The `auth` chart's oauth2-proxy protects the remaining UIs. Create a `teknoir`
client (confidential, standard flow, service account roles ON) with redirect
URI `https://teknoir.airgapped/oauth2/callback`, add a `teknoir` client scope with
an Audience mapper (included audience `teknoir`, add to access token), and
assign the service-account client roles `manage-users`, `query-users`,
`view-users`. Then:

```sh
./scripts/gen-oauth2-proxy-secrets.sh         # paste the client secret
./scripts/deploy-secrets.sh
ssh teknoir@teknoir.airgapped sudo k3s kubectl -n teknoir-auth rollout restart deploy/oauth2-proxy
```

## 9. CA distribution

`teknoir-root-ca.crt` (public certificate only) must be trusted by everything
that talks TLS to the gateway:

| Consumer | How |
|---|---|
| Node containerd (image pulls via mirrors) | `/etc/rancher/k3s/registries.yaml` → `ca_file: /etc/rancher/k3s/teknoir-root-ca.crt` (installed by `bootstrap-airgap.sh`) |
| Node OS trust store | `/usr/local/share/ca-certificates/` + `update-ca-certificates` (installed by `bootstrap-airgap.sh`) |
| LAN-side scripts (`push-to-harbor.sh`) | automatic (`--cacert` / `SSL_CERT_FILE` from the bundle) |
| Operator laptops / browsers | import `teknoir-root-ca.crt` into the OS keychain / browser trust store |
| Harbor OIDC "Verify Certificate" | works because the in-cluster trust chain covers `auth.teknoir.airgapped` |

The private key never leaves `.secrets/ca/` on the connected workstation
(except inside the `teknoir-root-ca` secret consumed by cert-manager).

## 10. Why `/etc/hosts` AND the coredns-custom ConfigMap?

Istio only *routes*; it does not *resolve*. With no DNS server in the air gap,
name resolution is solved twice, for two different resolvers:

| Concern | Mechanism |
|---|---|
| Name resolution on the node (containerd pulls, host tools) | `/etc/hosts` entry `<node-ip> harbor.teknoir.airgapped …` |
| Name resolution inside pods (ArgoCD repo-server → Harbor) | CoreDNS custom import (`coredns-custom` ConfigMap, natively supported by K3s CoreDNS) |
| Routing + TLS termination on 80/443 | Istio ingressgateway (published on the node IP by K3s klipper-lb) |

Both are installed by `bootstrap-airgap.sh`; both must stay in place. The
laptop additionally needs its own `/etc/hosts` entries (§2).

## Next

Updates and rollbacks: see [AIRGAP-UPDATE.md](AIRGAP-UPDATE.md).
