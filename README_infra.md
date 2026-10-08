# Infra: how the airgap pieces fit

Background for maintainers of the airgapped `teknoir-local` tooling. Operators
need only the runbooks: [docs/airgap/OPERATE.md](docs/airgap/OPERATE.md),
[docs/airgap/HOST-SETUP.md](docs/airgap/HOST-SETUP.md) and
[docs/airgap/BUILD.md](docs/airgap/BUILD.md). The design contract with all
decisions is [docs/airgap/DESIGN.md](docs/airgap/DESIGN.md).

## Three programs

| Program | Runs on | Does |
|---|---|---|
| `airgap/build/make-bundle.sh` | the connected build machine (bash 4.4+) | packages charts, images, k3s and tools into `dist/teknoir-airgap-<bundleId>.tar`, with `MANIFEST.yaml` and hard gates (no secrets, offline-complete, single-platform) |
| `teknoir-airgap` (from `airgap/teknoir-airgap`) | the LAN host (bash 3.2+, ssh, tar, sha256sum or shasum) | verifies the bundle, pins the node's ssh host key, sets up sudo once, syncs `node/` by content, runs `teknoir-node`, fetches the kubeconfig and the CA; also `trust`, `credentials`, `admin-user`, `backup`, `rotate`, `status`, `doctor` |
| `teknoir-node` (from `airgap/node/bin/`) | the node, as root, under a lock | `converge` (verify, preflight, backup, host, cluster-base, secrets, one-shot, Harbor, release, post) and the commands `teknoir-airgap` wraps |

The LAN host stays a thin orchestrator: the node already has `k3s kubectl`, trusts
the CA and resolves Harbor, so admin credentials never leave it.

## Ownership

Every object has exactly one owner; the table is in
[OPERATE.md § Who owns what](docs/airgap/OPERATE.md#13-who-owns-what). In short:

- **Node files** (k3s, `config.yaml`, `registries.yaml`, CA trust, the
  `/etc/hosts` block, chrony, bootstrap image tarballs): the converge's host
  phase, written only when the content differs.
- **Re-applied by every `up`** (server-side apply, field manager
  `teknoir-bootstrap`): `kube-system/coredns-custom` with `NODE_IP`, the root
  Application `teknoir-system/app-of-apps` at the bundle's version, the release
  ConfigMap `teknoir-system/teknoir-airgap-release`, and the public CA copies.
- **Created once, replaced only by `rotate`**: the CA, the wildcard certificate
  placeholder, the Harbor token certificate (node), and every random secret
  (`platform-secrets` chart).
- **One-shot, then ArgoCD**: platform-secrets, istio, harbor and argo are applied
  once from the bundle's override-free renders (equal to ArgoCD's render), then
  their Applications own them.
- **ArgoCD (GitOps)**: everything else, including CRDs (annotated
  `Prune=false,Delete=false`), cert-manager's issuer and wildcard Certificate,
  the Keycloak realm, monitoring, the controllers and Backstage.
- **k3s auto-deploy directory** `/opt/k3s/server/manifests`: no Teknoir files.
  k3s re-applies those files on every start and deletes objects a file no longer
  lists, whatever ArgoCD's Prune=false says, which is why nothing of ours lives
  there.

## Secrets

No secret is generated outside the cluster or carried in a bundle.

- The node converge creates, if absent: the Root CA `cert-manager/teknoir-root-ca`
  (new installs: name-constrained to the domain; the CA key never leaves the
  cluster), the `istio-system` wildcard placeholder (cert-manager replaces it),
  and `teknoir-system/harbor-token-service`. It refreshes on every run the public
  copies `teknoir-root-ca-bundle` (`teknoir-auth`, `teknoir-system`) and the
  Harbor entry in `argocd-tls-certs-cm`.
- The `platform-secrets` chart's Job creates every random secret if absent and
  re-syncs copies: Keycloak client secrets live in
  `teknoir-auth/keycloak-client-secrets` and are copied to their consumers
  (oauth2-proxy, ArgoCD, Harbor, user-controller). A new secret is a GitOps
  change to that chart's values.
- Values are handed out only into 0600 files (`teknoir-airgap credentials`,
  `admin-user`, `backup`), never printed.

## Site config

`airgap/site/<site>.env` (committed, public, no secrets) holds what differs per
installation: `TEKNOIR_ENV`, `TEKNOIR_DOMAIN`, `NODE_IP`, `NODE` (ssh target),
`TEKNOIR_HOSTNAMES` (short names; the domain itself is always added),
`TIME_SOURCE` and `K3S_DATA_DIR=/opt/k3s`. The bundle carries the env's site
file; `teknoir-airgap --site FILE` uses another one (the VM test uses
`vmtest.env`). `NODE_IP` is applied at run time, so a bundle does not depend on
the node's address. The domain is per environment, because the gitops branch
bakes it into the chart values.

## Versions

`airgap/versions.env` pins the root `APP_OF_APPS_VERSION`, k3s and the tools
(each with its sha256), and the app-of-apps versions that must never be deployed
(0.0.1, 0.0.2). Every other chart version is whatever that app-of-apps pins, so
GitOps owns it. Chart versions are released once: Harbor's `teknoir` project is
tag-immutable and the node refuses a chart whose digest differs from Harbor's.
How to cut a release: [BUILD.md § Making a release](docs/airgap/BUILD.md#6-making-a-release).

## ArgoCD

ArgoCD is self-managed: its chart (`charts/argo`) lives in
`platform-applications-gitops` with the other charts, and the bundle's one-shot
`argo` tier installs it on a new node. It reads the Harbor `teknoir` project
without credentials (the project is public on the LAN), signs users in through
Keycloak realm `teknoir` (client `argocd`; group `admin` maps to `role:admin`),
and keeps its local `admin` as break-glass.
