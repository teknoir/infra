# Infra

Air-gapped bootstrap of the Teknoir platform (`teknoir-local`) for a K3s node
with no internet access. Everything — Helm charts, container images, tools —
is built into a portable bundle on a connected workstation, carried over on
USB, and served from the in-cluster Harbor registry.

> The implementation is the bare minimum. It is not meant to be infinitely
> configurable, but to provide a repeatable way to bootstrap and update the
> platform on `teknoir@teknoir.airgapped`.

## Architecture

Two tiers:

* **Bootstrap tier — Istio → ArgoCD → Harbor.** Installed as ordered static
  manifests (`00-teknoir-istio.yaml`, `10-teknoir-argo.yaml`,
  `20-teknoir-harbor.yaml`) via the K3s auto-deploy directory
  (`/opt/k3s/server/manifests/`), with images shipped as containerd tarballs
  (`/opt/k3s/agent/images/`). Istio comes first because *everything* — Harbor
  included — is exposed only through the Istio ingressgateway, which
  terminates TLS with a pre-issued `*.teknoir.airgapped` wildcard cert signed by
  the local Teknoir Root CA.
* **GitOps tier — everything else.** ArgoCD pulls the `app-of-apps` chart and
  all platform charts from `oci://harbor.teknoir.airgapped/teknoir` and syncs
  auth (Keycloak/oauth2-proxy), cert-manager, monitoring, and the controllers.
  ArgoCD also **adopts** the bootstrap-installed Istio and Harbor via
  `ServerSideApply=true` Applications pinned to the same chart versions.

Harbor hosts the charts (project `teknoir`) and mirrors the five public
registries (`dockerhub`, `ghcr`, `gcr`, `quay`, `k8s` — wired into containerd
via `/etc/rancher/k3s/registries.yaml`). ArgoCD pulls with the `robot$argocd`
robot account. cert-manager renews the wildcard cert from the `teknoir-ca`
`ClusterIssuer` once the GitOps tier runs.

## Quick start

Follow the runbooks — they are the authoritative procedures:

* **First install:** [docs/AIRGAP-BOOTSTRAP.md](docs/AIRGAP-BOOTSTRAP.md)
* **Updates & rollback:** [docs/AIRGAP-UPDATE.md](docs/AIRGAP-UPDATE.md)

Condensed:

```sh
# connected workstation
./scripts/gen-local-ca-secret.sh && ./scripts/gen-harbor-secrets.sh   # …and the other gen-*.sh
./airgap/make-bundle.sh
./airgap/verify-offline.sh

# USB → LAN laptop
./airgap/bootstrap-airgap.sh                       # Istio → ArgoCD → Harbor up
HARBOR_ADMIN_PASSWORD='…' ./airgap/push-to-harbor.sh
./scripts/gen-argocd-harbor-repo-secret.sh && ./scripts/deploy-secrets.sh
./airgap/deploy-app-of-apps.sh                     # ArgoCD adopts istio+harbor, syncs the rest
# then: Keycloak clients + Harbor OIDC (runbook §8)
```

## Directory layout

| Path | Purpose |
|---|---|
| `airgap/` | Bundle build (connected side) + install/update tooling (LAN side); see script headers for usage |
| `airgap/versions.env` | Central version/config pinning (charts, Istio/ArgoCD/Harbor, tools, hostnames) |
| `airgap/images-extra.txt` | Images `helm template` cannot discover (sidecars, runtime pulls) |
| `charts/argo/` | Bootstrap ArgoCD umbrella chart (see [README_infra.md](README_infra.md)) |
| `scripts/` | Secret generators (`gen-*.sh`) + deploy helpers (`deploy-argo.sh`, `deploy-secrets.sh`) |
| `teknoir-local-app-of-apps.yaml` | AppProject + root Application (`oci://harbor.teknoir.airgapped/teknoir`, chart `app-of-apps`) |
| `docs/` | Bootstrap and update runbooks |
| `.secrets/` | Generated secret manifests (`manifest-*.yaml`), CA key material (`ca/`), and the operator SSH key — **gitignored**, never commit |
| `teknoir-root-ca.crt` | Public Root CA cert (generated, gitignored) |
| `bundle/` | Bundle build output (gitignored) |

Infra-chart and secrets-model details: [README_infra.md](README_infra.md).
