# Plan: Air-gapped host preparation documentation + K3s artifacts in the bundle

## 1. Goal

Create a standalone runbook that documents how to prepare an **air-gapped** (no internet) host for the Teknoir platform — Debian 13 install, cloud-init-equivalent host prep, OS/K3s tuning, offline K3s install, and kubeconfig extraction — and extend the airgap bundle tooling so the bundle ships the pinned K3s install artifacts.

## 2. Approach

The repo already has two runbooks in `docs/` (`AIRGAP-BOOTSTRAP.md`, `AIRGAP-UPDATE.md`), and `AIRGAP-BOOTSTRAP.md` §2 simply *assumes* "K3s installed with `--data-dir /opt/k3s`" — the new doc `docs/AIRGAP-HOST-SETUP.md` fills exactly that gap and slots in as the step *before* the bootstrap runbook. It translates `/Volumes/GIT/ai/teknoir-os-base/cloud-init/cloud-init.yaml` into manual, offline-safe steps (skipping the bootstrap parts: K3s curl-install, TOE manifest, `/toe_conf`, and — per scope decision — all NVIDIA/GPU steps).

Per the confirmed scope decisions:
* **APT strategy:** the Debian 13 (trixie) DVD-1 image is the apt source — no online mirrors.
* **K3s delivery:** the bundle tooling is extended (following the existing pinned-tools pattern in `make-bundle.sh` step 5) so `make-bundle.sh` downloads the pinned k3s binary, `install.sh`, and the k3s airgap-images tarball into the bundle.
* **GPU:** out of scope entirely.

## 3. File Changes

| File | Action | Description |
|---|---|---|
| `docs/AIRGAP-HOST-SETUP.md` | **Create** | The new host-preparation runbook (detailed outline below) |
| `airgap/versions.env` | **Modify** | Add pinned `K3S_VERSION` (and arch) in the "Pinned upstream versions" section (~line 48–59, next to `PAUSE_IMAGE`) |
| `airgap/make-bundle.sh` | **Modify** | New download step for K3s artifacts into `<bundle>/k3s/`; renumber step logs (currently `step 1/6`…`6/6`, lines 72–153) and extend the usage layout text (lines 16–20) |
| `docs/AIRGAP-BOOTSTRAP.md` | **Modify** | §2 "K3s node" prerequisites (lines 59–64): link to the new doc; §4 bundle tree (lines 131–142): add the `k3s/` directory |
| `README_infra.md` | **Modify** | Add the new doc to the runbook references (lines 5–7) |

## 4. Implementation Steps

### Task 1: Write `docs/AIRGAP-HOST-SETUP.md`

Create the runbook with the following sections (style/tone matching `docs/AIRGAP-BOOTSTRAP.md`: numbered sections, fenced `sh` blocks, tables, air-gap rationale notes):

1. **Overview & machine model** — this doc prepares the node in the three-machine model of `AIRGAP-BOOTSTRAP.md` §1; the host has **no internet access at any point**; everything arrives via USB from a connected workstation.
2. **Prerequisites (connected workstation)** — download and verify (sha256) the Debian 13 DVD-1 ISO; build (or reuse) the airgap bundle which now includes `k3s/` artifacts; a USB drive for installer + bundle.
3. **Install Debian 13 (trixie)** — write DVD-1 ISO to USB; installer walkthrough with the air-gap-relevant choices called out:
   * no network mirror (offline install), hostname `teknoir`, domain per `TEKNOIR_DOMAIN` (`teknoir.local`),
   * create the `teknoir` user (matches `TEKNOIR_HOST=teknoir@teknoir.local` in `airgap/versions.env`),
   * guided partitioning using the whole disk (manual equivalent of cloud-init `growpart`),
   * software selection: **SSH server + standard system utilities only** (no desktop).
4. **Configure apt from the DVD (no internet)** — `apt-cdrom add` (or mount the ISO and add a `file:` deb822 source); comment out any online entries in `/etc/apt/sources.list.d/debian.sources`; note the cloud-init `main contrib non-free` tweak and that DVD-1 covers `main` — packages not on DVD-1 are explicitly noted as optional.
5. **Host preparation (cloud-init equivalent)** — manual steps mirroring `cloud-init.yaml`, each with a short "why":
   * `teknoir` user: `sudo` group + `NOPASSWD:ALL` sudoers drop-in (`/etc/sudoers.d/teknoir`), `~/.ssh/authorized_keys` with the platform/operator public key, shell `zsh`, non-expiring password (cloud-init `users:` + `chpasswd:` blocks),
   * sshd hardening: `PasswordAuthentication no` (cloud-init `ssh_pwauth: false`),
   * network: DHCP on the primary interface (cloud-init `network:` + `write_files` 10-eth0.network — documented for both NetworkManager and systemd-networkd, whichever the installer set up),
   * packages from the DVD: `htop curl wget git gpg zsh zsh-autosuggestions zsh-syntax-highlighting network-manager linux-headers-amd64` (`zsh-theme-powerlevel9k` marked optional — may not be on DVD-1),
   * MOTD files `/etc/update-motd.d/00-header`, `01-help-text`, `02-resources` (from cloud-init `write_files`, with the `nvidia-smi` line guarded/removed since GPU is out of scope),
   * zsh configuration for `teknoir` and `root` (cloud-init `runcmd` zsh block),
   * explicit **out-of-scope** note: K3s install via `get.k3s.io`, TOE manifest link, `/toe_conf`, and NVIDIA driver/CUDA steps from cloud-init are intentionally *not* done here (K3s is installed offline in §7; TOE comes later).
6. **OS tuning** — create `/etc/sysctl.d/teknoir.inotify.conf` with `fs.inotify.max_user_instances=1024`, reload via `sysctl --system` (rationale: many pods/log watchers exhaust the default inotify instances).
7. **K3s configuration (before install)** — `mkdir -p /etc/rancher/k3s` and write `/etc/rancher/k3s/config.yaml`:
   ```yaml
   kubelet-arg:
     - "max-pods=250"
   data-dir: /opt/k3s
   disable:
     - traefik
   tls-san:
     - "teknoir.local"
   ```
   with rationale: `data-dir: /opt/k3s` matches `K3S_DATA_DIR` used by all airgap tooling (`airgap/versions.env` line 17, `bootstrap-airgap.sh` uses `/opt/k3s/server/manifests` + `/opt/k3s/agent/images`); `disable: traefik` because the Istio ingressgateway owns 80/443 (`AIRGAP-BOOTSTRAP.md` §10); `tls-san` so the extracted kubeconfig works against `teknoir.local` remotely.
8. **Install K3s offline** — using the bundle's `k3s/` directory (from Task 2), transferred via USB:
   * copy `k3s` binary → `/usr/local/bin/k3s` (`chmod 755`),
   * copy the airgap images tarball → `/opt/k3s/agent/images/` (data-dir-relative, **not** `/var/lib/rancher`),
   * run `INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh` (config.yaml from §7 is picked up automatically),
   * verify: `systemctl status k3s`, `k3s kubectl get nodes` shows `Ready`, `k3s kubectl get pods -A` has no traefik pods, `k3s kubectl describe node | grep -i pods` shows capacity 250.
9. **Extract the kubeconfig for remote management** — copy `/etc/rancher/k3s/k3s.yaml` to the operator laptop, replace `127.0.0.1` with the node IP (or `teknoir.local` — requires the `tls-san` from §7 and the laptop `/etc/hosts` entry from `AIRGAP-BOOTSTRAP.md` §2), `chmod 600`, verify with `kubectl --kubeconfig … get nodes`.
10. **Next** — link to `docs/AIRGAP-BOOTSTRAP.md` for the platform install.

### Task 2: Ship K3s artifacts in the bundle

1. `airgap/versions.env` — add to the "Pinned upstream versions" section:
   * `K3S_VERSION="${K3S_VERSION:-v1.33.5+k3s1}"` (aligned with the `KUBE_VERSION` 1.33 helm-template default in `airgap/lib.sh` line 106),
   * `K3S_ARCH="${K3S_ARCH:-amd64}"`.
2. `airgap/make-bundle.sh` — insert a new step after the pinned-tools step (line 148), following the same idempotent + `--dry-run` pattern:
   * download into `${BUNDLE}/k3s/`: the `k3s` binary, `k3s-airgap-images-${K3S_ARCH}.tar.zst`, and `sha256sum-${K3S_ARCH}.txt` from `https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/…`, plus `install.sh` from `https://get.k3s.io`,
   * verify the binary/tarball against the downloaded `sha256sum` file; `chmod +x` the binary and `install.sh`,
   * skip downloads when files already exist (like the crane/helm step),
   * renumber all step logs from `x/6` to `x/7` (lines 72, 75, 78, 84, 113, 153) and add `k3s/` to the usage layout text (lines 16–20). The existing step-6 checksum manifest automatically covers the new files.
3. `docs/AIRGAP-BOOTSTRAP.md` — update the §4 bundle tree (lines 131–142) to show the `k3s/` directory with a one-line comment.

### Task 3: Cross-link the docs

1. `docs/AIRGAP-BOOTSTRAP.md` §2 "K3s node" (lines 59–64): replace the bare assumption with "Host prepared per [AIRGAP-HOST-SETUP.md](AIRGAP-HOST-SETUP.md) — K3s installed with `data-dir: /opt/k3s`, traefik disabled, …".
2. `README_infra.md` (lines 5–7): add `docs/AIRGAP-HOST-SETUP.md` to the runbook list.

## 5. Acceptance Criteria

1. `docs/AIRGAP-HOST-SETUP.md` exists and contains numbered sections covering: Debian 13 offline install, DVD apt source, user/ssh/network/packages/MOTD/zsh prep, the exact `fs.inotify.max_user_instances=1024` sysctl file, the exact `/etc/rancher/k3s/config.yaml` (max-pods=250, `data-dir: /opt/k3s`, traefik disabled), offline K3s install via `INSTALL_K3S_SKIP_DOWNLOAD=true`, and kubeconfig extraction with the `127.0.0.1` → node-IP replacement.
2. The doc contains **zero** instructions that require internet on the host: no `curl https://get.k3s.io | sh`, no NVIDIA repo/keyring steps, no online apt mirrors.
3. The doc explicitly lists the skipped cloud-init parts (K3s curl-install, TOE, `/toe_conf`, NVIDIA) as out of scope.
4. `airgap/versions.env` pins `K3S_VERSION`, overridable from the environment like every other pin.
5. `airgap/make-bundle.sh --dry-run` prints the planned K3s artifact downloads to `<bundle>/k3s/` and shows 7 steps with consistent numbering.
6. `bash -n airgap/make-bundle.sh` passes and `shellcheck -x -P airgap airgap/make-bundle.sh` reports no new issues (the gate `airgap/verify-offline.sh` step 1 enforces this).
7. `docs/AIRGAP-BOOTSTRAP.md` §2 links to the new doc and §4's bundle tree includes `k3s/`; `README_infra.md` references the new doc.
8. All commands in the new doc use paths consistent with the tooling: `/opt/k3s/agent/images/`, `/opt/k3s/server/manifests/`, `/etc/rancher/k3s/`, user `teknoir@teknoir.local`.

## 6. Verification Steps

1. Run `airgap/verify-offline.sh` — step 1 (`bash -n` + shellcheck over `airgap/*.sh`) must pass with the modified `make-bundle.sh`.
2. Run `airgap/make-bundle.sh --dry-run` — confirm the new step logs the three K3s release URLs + `get.k3s.io/install.sh` and the target `<bundle>/k3s/`, with no unbound-variable errors (`set -euo pipefail`).
3. Grep the new doc for forbidden online patterns in host-side instructions: `get.k3s.io | sh`, `nvidia.github.io`, `developer.download.nvidia.com`, `deb http` — zero hits in sections executed **on the host**.
4. Manually cross-check every path in the doc against `airgap/versions.env` (`K3S_DATA_DIR`, `TEKNOIR_HOST`, `TEKNOIR_DOMAIN`) — no contradictions.
5. Markdown check: links `docs/AIRGAP-BOOTSTRAP.md` ↔ `docs/AIRGAP-HOST-SETUP.md` resolve; code fences balanced.

## 7. Risks & Mitigations

* **`zsh-theme-powerlevel9k` (and possibly other packages) may be absent from DVD-1** — the doc marks cosmetic packages as optional and keeps required packages to what DVD-1 provides; the zsh config lines are written to tolerate a missing theme.
* **K3s sha256/asset naming may change between releases** — the download step verifies against the release's own `sha256sum-amd64.txt` and fails loudly; `K3S_VERSION` is env-overridable for quick pin bumps.
* **`install.sh` from get.k3s.io is unpinned** — the doc/tooling note records that the installer script is fetched at bundle-build time and shipped in the checksummed bundle, so the exact bytes used on the host are captured in `bundle-manifest.yaml`.
* **Kubeconfig via `teknoir.local` fails without a matching TLS SAN** — the doc adds `tls-san: ["teknoir.local"]` to `config.yaml` *before* the first K3s start, avoiding certificate regeneration later.