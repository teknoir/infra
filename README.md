# Infra

Airgapped installation of the Teknoir platform (`teknoir-local`, domain
`teknoir.airgapped`) on a k3s node with no internet access. Everything the node
needs (k3s, Helm charts, container images, tools) is built into one bundle file
on a connected machine, carried over on a USB medium and rolled out with one
command from a LAN host. The platform itself is GitOps: ArgoCD syncs the charts
of `platform-applications-gitops` (branch `teknoir-local`) from the in-cluster
Harbor registry.

> Infra stays thin: it only gets a node to the point where ArgoCD can pull from
> Harbor, and keeps the node itself (k3s, trust, name resolution, Harbor
> content) converged. Everything else is GitOps.

## How it works

```
[build machine, online]                        [LAN host]                   [node]
airgap/build/make-bundle.sh ──► .tar + .sha256 ──► USB ──► ./teknoir-airgap up ── ssh ──► teknoir-node converge
```

```sh
# connected build machine: both checkouts on branch teknoir-local, clean and pushed
airgap/build/make-bundle.sh --gitops ../platform-applications-gitops-teknoir-local

# LAN host, from the USB medium
sha256sum -c teknoir-airgap-<bundleId>.tar.sha256    # macOS: shasum -a 256 -c ...
tar -xf teknoir-airgap-<bundleId>.tar && cd teknoir-airgap-<bundleId>
./teknoir-airgap up        # first install and every update; safe to re-run
./teknoir-airgap trust     # once per LAN host: name resolution and CA trust
./teknoir-airgap status
```

`up` verifies the bundle, copies its node payload over ssh (only what the node
lacks), runs the converge on the node as root and fetches the kubeconfig
(context `teknoir-local`). No secret is ever in a bundle: the node creates them
inside the cluster.

## Docs

| Doc | For |
|---|---|
| [docs/airgap/OPERATE.md](docs/airgap/OPERATE.md) | operators: first install, update, rollback, status, credentials, users, backup and restore, rotation, troubleshooting, ownership |
| [docs/airgap/HOST-SETUP.md](docs/airgap/HOST-SETUP.md) | installing Debian 13 offline on the node, ssh access from the LAN host |
| [docs/airgap/BUILD.md](docs/airgap/BUILD.md) | building a bundle and making a release |
| [docs/airgap/CHANGELOG.md](docs/airgap/CHANGELOG.md) | history, incidents and the reasons behind the design |
| [docs/airgap/DESIGN.md](docs/airgap/DESIGN.md) | the design contract of the 2026-10 redesign |
| [README_infra.md](README_infra.md) | how the pieces fit: ownership, secrets, site config, versions |

The four runbooks ship in every bundle under `docs/`.

## Repository layout

| Path | Purpose |
|---|---|
| `airgap/teknoir-airgap` | LAN entrypoint (bash 3.2; ssh, tar and sha256sum/shasum only); copied to the bundle root |
| `airgap/node/` | the node runner `bin/teknoir-node` and its phases in `lib/` (host, secrets, one-shot, Harbor, release, backup, migrate) |
| `airgap/build/` | bundle build (connected machine): `make-bundle.sh` and its helpers |
| `airgap/site/` | site configs: `teknoir-local.env` (the live node), `vmtest.env` (the test VM) |
| `airgap/versions.env` | pinned versions: app-of-apps, k3s, tools (with sha256) |
| `airgap/images-extra.txt` | images `helm template` cannot discover (sidecars, run-time pulls) |
| `airgap/test/` | tests: LAN entrypoint (`test/lan/run.sh`), k3d ownership suite, VM end-to-end |
| `docs/airgap/` | runbooks and design |
| `dist/` | build output |
