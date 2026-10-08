# Building an airgap bundle

A bundle is one file, `teknoir-airgap-<bundleId>.tar`, with its checksum file
`teknoir-airgap-<bundleId>.tar.sha256`. It holds everything the airgapped node
and the LAN host need: k3s, the platform's charts and images, the node runner,
the LAN entrypoint `teknoir-airgap` and these docs. It holds no secrets: every
password, key and token is created inside the cluster on the node.

You build it on a connected Linux machine, carry the two files to the LAN on a
USB medium, and roll it out with `./teknoir-airgap up`
([OPERATE.md](OPERATE.md)).

## 1. Prerequisites

- A Linux x86-64 machine with internet access, bash 4.4 or later, `git`,
  `curl`, `tar`, `sha256sum`, and about 15 GB free disk space (build cache and
  output; a bundle is about 3 GB).
- Two checkouts, both on branch `teknoir-local`, clean (no uncommitted changes)
  and pushed:
  - `infra` (this repository), for example `~/git/ai/infra-teknoir-local`;
  - `platform-applications-gitops`, for example
    `~/git/ai/platform-applications-gitops-teknoir-local`.

Nothing else needs installing. The build downloads its tools (helm, crane, jq,
age, kubectl), k3s and the k3s installer at the versions pinned in
`airgap/versions.env`, checks each against its pinned sha256, and caches them in
`~/.cache/teknoir-airgap/` by version.

## 2. Build

```sh
cd ~/git/ai/infra-teknoir-local
airgap/build/make-bundle.sh --gitops ../platform-applications-gitops-teknoir-local
```

The result is in `dist/`:

```
dist/teknoir-airgap-teknoir-local-aoa0.0.4-20261009-i1a2b3c4-g5d6e7f8.tar
dist/teknoir-airgap-teknoir-local-aoa0.0.4-20261009-i1a2b3c4-g5d6e7f8.tar.sha256
```

The bundle id names everything that went in:
`<env>-aoa<app-of-apps version>-<build date>-i<infra commit>-g<gitops commit>`.
A bundle built from uncommitted changes (`--allow-dirty`, for tests only) gets
the suffix `-dirty`; never roll one out to the live environment.

The build works in a fresh staging directory and only moves the result into
`dist/` when every check passed. It fails, leaving nothing in `dist/`, when:

- a checkout is not clean (unless `--allow-dirty`);
- the app-of-apps version is in the broken list (0.0.1 and 0.0.2, see the
  CHANGELOG);
- an image that a rendered chart uses is not in the bundle, or an image has more
  than one platform (bundles are linux/amd64 only);
- any file contains a private key, a Kubernetes Secret with data, or a known
  literal default password;
- a download does not match its pinned sha256.

## 3. Copy to the USB medium

```sh
cp dist/teknoir-airgap-<bundleId>.tar dist/teknoir-airgap-<bundleId>.tar.sha256 /media/$USER/<usb>/
```

Use an exFAT or ext4 medium. A FAT32 medium cannot hold files over 4 GB: build
with `--split`, which also writes the tar as 3900 MiB parts
`teknoir-airgap-<bundleId>.tar.part-00`, `-01`, ... (with
`teknoir-airgap-<bundleId>.tar.parts.sha256`). Copy the parts and the
`.tar.sha256`; on the LAN host, join them before checking:

```sh
cat teknoir-airgap-<bundleId>.tar.part-* > teknoir-airgap-<bundleId>.tar
```

## 4. Check a build

- [ ] `sha256sum -c dist/teknoir-airgap-<bundleId>.tar.sha256` prints `OK`.
- [ ] The tar is under 3.5 GB.
- [ ] Extracted into an empty directory, the bundle verifies and names the
      expected versions:

      ```sh
      mkdir /tmp/check && tar -C /tmp/check -xf dist/teknoir-airgap-<bundleId>.tar
      cd /tmp/check/teknoir-airgap-<bundleId>
      ./teknoir-airgap verify
      ./teknoir-airgap version
      ```

## 5. What is in a bundle

```
teknoir-airgap-<bundleId>/
  teknoir-airgap             LAN entrypoint (bash 3.2; ssh, tar and sha256sum/shasum only)
  MANIFEST.yaml              bundle id, env, domain, build time, infra and gitops commits,
                             dirty flag, app-of-apps and k3s versions, image digests,
                             and the sha256 of every file
  site/teknoir-local.env     default site config: domain, NODE_IP, NODE, host names
  docs/                      BUILD.md, HOST-SETUP.md, OPERATE.md, CHANGELOG.md
  tools/<os>-<arch>/kubectl  for the LAN host's kubeconfig (linux-amd64, darwin-arm64, darwin-amd64)
  node/                      the payload copied to the node
    SHA256SUMS               sha256 of every file under node/
    bin/teknoir-node         node runner (converge, status, credentials, backup, rotate, migrate)
    bin/helm, crane, jq, age node tools (linux-amd64)
    lib/                     the runner's phases
    k3s/                     k3s binary, k3s airgap images, install.sh, sha256sum file
    templates/               k3s config, registries.yaml, coredns-custom, root Application
    oneshot/                 one-time renders of platform-secrets, istio, harbor, argo
    bootstrap-images/        image archives the node imports into containerd directly
    charts/                  every chart app-of-apps pins (.tgz) and pins.txt
    images/                  every other image, one OCI layout each, and images.lock
    site/                    a copy of the site config
```

Where it comes from:

| Part | Source |
|---|---|
| Charts | the gitops checkout at the recorded commit: app-of-apps at `APP_OF_APPS_VERSION` (from `airgap/versions.env`) and every chart version it pins |
| One-shot renders | `helm template --include-crds` of the bundled chart `.tgz` with no value overrides, so they equal what ArgoCD renders |
| Images | every image the rendered charts use plus `airgap/images-extra.txt`, pulled for linux/amd64 and recorded by digest |
| k3s | the `K3S_VERSION` release: binary, airgap image archive and checksums; `install.sh` from `raw.githubusercontent.com/k3s-io/k3s/<K3S_VERSION>/install.sh` |
| Tools | pinned versions from `airgap/versions.env`, sha256-checked |
| Docs | `docs/airgap/` of the infra checkout |

## 6. Making a release

Chart versions are released once. Harbor's `teknoir` project refuses to
overwrite a tag, and the node refuses to push a chart whose digest differs from
the one Harbor already has. So every chart change is a new version:

1. In `platform-applications-gitops` (branch `teknoir-local`): change the chart,
   bump its `Chart.yaml` version, set that version as the `targetRevision` in
   `charts/app-of-apps/templates/<chart>.yaml`, and bump the app-of-apps
   `Chart.yaml` version. Commit and push.
2. In `infra` (branch `teknoir-local`): set `APP_OF_APPS_VERSION` in
   `airgap/versions.env` to the new app-of-apps version. Add any image that
   `helm template` cannot see (sidecars, images a controller starts at run time)
   to `airgap/images-extra.txt`. Commit and push.
3. Build (section 2), check (section 4), carry, and run `./teknoir-airgap up`.

A tool or k3s upgrade is a change to its version and sha256 in
`airgap/versions.env`; the cache is keyed by version, so the next build fetches
the new one.

Never reuse a version that Harbor already has, even one that was never deployed:
app-of-apps 0.0.1 and 0.0.2 were overwritten in Harbor once, and both are now
refused forever (see [CHANGELOG.md](CHANGELOG.md)).
