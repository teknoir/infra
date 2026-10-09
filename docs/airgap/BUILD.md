# Building an airgap bundle

A bundle is one file, `teknoir-airgap-<bundleId>.tar`, with its checksum file
`teknoir-airgap-<bundleId>.tar.sha256`. It holds everything the airgapped node
and the LAN host need: k3s, the platform's charts and images, the node runner,
the LAN entrypoint `teknoir-airgap` and these docs. It holds no secrets: every
password, key and token is created inside the cluster on the node.

You build it on a connected Linux machine, carry the two files to the LAN on a
USB medium, and roll it out with `./teknoir-airgap up`
([OPERATE.md](OPERATE.md)).

Since r5 (app-of-apps 0.0.5) a bundle also carries the teamspace plugin charts
and their images (so teamspaces work offline), the node's time packages
(chrony, util-linux-extra) as pinned `.deb` files, and only pinned Teknoir
images (G-09).

## 1. Prerequisites

- A Linux x86-64 machine with internet access, bash 4.4 or later, `git`,
  `curl`, `tar`, `sha256sum`, `sha1sum`, and about 20 GB free disk space (build
  cache and output; a bundle is about 5.8 GB). `dpkg-deb`, when installed, adds
  a check of the bundled `.deb` files.
- Two checkouts, both on branch `teknoir-local` (or both on a release
  integration branch such as `r5` before it is merged), clean (no uncommitted
  changes) and pushed:
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
- a Teknoir image in a platform chart is not pinned as
  `<repo>:<immutable tag>@sha256:<linux/amd64 manifest>` (G-09, section 6), a
  pinned digest is a multi-platform index, or a one-shot tier image (istio,
  harbor, argo, platform-secrets, the bootstrap extras) carries a digest;
- the teamspace plugin supply is incomplete: profile-controller's
  `PLUGIN_CHART_REPO` is not `harbor.<domain>/teknoir`, a plugin chart is
  missing or differs from its pin, or a plugin image is not in the bundle;
- `node/debs` is not exactly `NODE_DEBS` with their pinned sha256;
- any file contains a private key, a Kubernetes Secret with data, or a known
  literal default password;
- a download does not match its pinned sha256;
- the tar is larger than `BUNDLE_MAX_BYTES` (6.5 GiB).

## 3. Copy to the USB medium

```sh
cp dist/teknoir-airgap-<bundleId>.tar dist/teknoir-airgap-<bundleId>.tar.sha256 /media/$USER/<usb>/
```

Use an exFAT or ext4 medium: a bundle is about 5.8 GB. A FAT32 medium cannot
hold files over 4 GB: build with `--split`, which also writes the tar as 3900 MiB parts
`teknoir-airgap-<bundleId>.tar.part-00`, `-01`, ... (with
`teknoir-airgap-<bundleId>.tar.parts.sha256`). Copy the parts and the
`.tar.sha256`; on the LAN host, join them before checking:

```sh
cat teknoir-airgap-<bundleId>.tar.part-* > teknoir-airgap-<bundleId>.tar
```

## 4. Check a build

- [ ] `sha256sum -c dist/teknoir-airgap-<bundleId>.tar.sha256` prints `OK`.
- [ ] The tar is under 6.5 GiB (about 5.8 GB with the teamspace plugins).
- [ ] The bundle id has no `-dirty`, `-mutable` or `-incomplete` suffix.
- [ ] `MANIFEST.yaml` lists the 9 `profile-plugin-*` charts under
      `teamspacePlugins`, the two packages under `debs`, and
      `mutableTeknoirTags: false`; `teamspace_mutable_images` lists the plugin
      images still on mutable tags (accepted for r5).
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
    charts/                  every chart app-of-apps pins (.tgz), the teamspace plugin
                             charts (profile-plugin-*.tgz), and pins.txt
    images/                  every other image, one OCI layout each, and images.lock
    debs/                    the node's offline packages (<pkg>_<version>_<arch>.deb)
                             and debs.lock: "<pkg> <version> <arch> <sha256> <file>"
    site/                    a copy of the site config
```

Where it comes from:

| Part | Source |
|---|---|
| Charts | the gitops checkout at the recorded commit: app-of-apps at `APP_OF_APPS_VERSION` (from `airgap/versions.env`) and every chart version it pins |
| One-shot renders | `helm template --include-crds` of the bundled chart `.tgz` with no value overrides, so they equal what ArgoCD renders |
| Teamspace plugin charts | the published archives of `PROFILE_PLUGIN_CHARTS` from `PROFILE_PLUGIN_SOURCE` (teknoir.github.io/profile-plugins-helm), at the version profile-controller's ConfigMap pins (`PLUGIN_CHART_VERSION`), byte for byte; each must equal its sha256 in `airgap/versions.env` and the repo index |
| Images | every image the rendered charts use (the plugin charts included, rendered for the first GitOps Profile, else `teknoir-default`) plus `airgap/images-extra.txt`, pulled for linux/amd64 and recorded by digest |
| Node packages | `NODE_DEBS` from deb.debian.org (else snapshot.debian.org by sha1), checked against the sha256 pins in `airgap/versions.env` |
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

### Pinned Teknoir images (G-09)

Every Teknoir image (`ghcr.io/teknoir/*`) in a platform chart is pinned as
`<repo>:<immutable tag>@sha256:<digest>`:

- the tag is immutable: the CI's `sha-<first 8 hex of the commit>`, its
  `<branch>-YYYYMMDD-HHMMSS` build tag, or a semantic version (never `latest`
  or a branch name, which CI moves);
- the digest is the **linux/amd64 manifest**, never the multi-platform index
  (the index digest changes with every build's provenance attestation; the
  bundle and Harbor carry only the amd64 manifest);
- `pullPolicy: IfNotPresent`.

`airgap/build/pin-images.sh <repo>:<sha-tag> ...` prints the pinned
references; `pin-images.sh --verify <pinned ref> ...` checks existing pins. The
one-shot tiers (istio, harbor, argo, platform-secrets) stay tag-only: the node
imports them as docker archives, which crane re-manifests.
`ALLOW_MUTABLE_TEKNOIR_TAGS=1 make-bundle.sh ...` builds anyway, marked
`-mutable`; such a bundle is for tests only.

The teamspace plugin charts are published bytes and still use `:latest` for
11 Teknoir images and `alpine:latest`; they only warn and are listed in
`MANIFEST.yaml` (`teamspace_mutable_images`). Their digests are recorded in
`images.lock`; a later bundle in which such a tag moved needs
`./teknoir-airgap up --force-images`.

### Teamspace plugin charts

profile-controller deploys the plugins of every teamspace from
`PLUGIN_CHART_REPO` at `PLUGIN_CHART_VERSION` (its ConfigMap, set in the gitops
`profile-controller` chart values). On the airgap the repo is
`harbor.<domain>/teknoir`; the build refuses anything else. To move to another
plugin chart version: set it in the gitops chart, add the
`PINNED_SHA256[profile-plugin-<name>-<version>]` entries (the digests in
`<PROFILE_PLUGIN_SOURCE>/index.yaml`, after checking them against the
downloaded archives) and build. Airgap Profiles must not enable plugins
outside `PROFILE_PLUGIN_CHARTS` (postgres, claims) or set another version.

A rollback bundle for an app-of-apps whose profile-controller has no
`PLUGIN_CHART_REPO` (0.0.4 and older) sets `PROFILE_PLUGIN_CHARTS=""` in
`airgap/versions.env` (committed): it carries no plugins, so teamspaces do not
work offline with it.

### Node packages

`NODE_DEBS` lists the Debian packages the node installs offline (chrony and
util-linux-extra for the clock). After changing a version, run
`airgap/build/fetch-tools.sh --print-pins`: it looks the packages up in the
current trixie, trixie-updates and trixie-security indexes and prints the
`PINNED_SHA256`, `NODE_DEB_POOL` and `PINNED_DEB_SHA1` entries. Cross-check the
sha256 against the node's own signed apt metadata (`apt-cache show
<pkg>=<version>` on the node) before committing.

Never reuse a version that Harbor already has, even one that was never deployed:
app-of-apps 0.0.1 and 0.0.2 were overwritten in Harbor once, and both are now
refused forever (see [CHANGELOG.md](CHANGELOG.md)).
