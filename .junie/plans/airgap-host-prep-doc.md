---
sessionId: session-260907-202124-8m2w
---

# Requirements

### Overview & Goals
Create a standalone, air-gap-aware runbook `docs/AIRGAP-HOST-SETUP.md` documenting how to prepare a host (Debian 13, no internet access) for the Teknoir platform, filling the gap before `docs/AIRGAP-BOOTSTRAP.md` (which assumes K3s is already installed with `data-dir /opt/k3s`).

### Scope
**In scope:**
- Debian 13 offline install from DVD-1 ISO
- Cloud-init-equivalent host prep (user, SSH, network, packages, MOTD, zsh) translated from `/Volumes/GIT/ai/teknoir-os-base/cloud-init/cloud-init.yaml`
- inotify sysctl tuning (`fs.inotify.max_user_instances=1024`)
- K3s pre-install config (`max-pods=250`, `data-dir: /opt/k3s`, traefik disabled)
- Offline K3s install + kubeconfig extraction for remote management
- Bundle tooling extension: ship pinned K3s artifacts in the bundle

**Out of scope (user-confirmed):**
- NVIDIA/GPU driver installation
- K3s curl-install from `get.k3s.io` on the host, TOE manifest, `/toe_conf` (done later per the bootstrap runbook)

### Functional Requirements
- Every host-side instruction must work without internet (DVD apt source, USB-delivered artifacts)
- Paths must match existing tooling: `/opt/k3s/agent/images/`, `/opt/k3s/server/manifests/`, `/etc/rancher/k3s/`, user `teknoir@teknoir.local`
- Skipped cloud-init parts are explicitly listed as out of scope in the doc

# Technical Design

### Current Implementation
- `docs/AIRGAP-BOOTSTRAP.md` §2 assumes K3s installed with `--data-dir /opt/k3s` — no doc explains host prep
- `airgap/versions.env` pins all versions centrally (`K3S_DATA_DIR=/opt/k3s`, no `K3S_VERSION` yet)
- `airgap/make-bundle.sh` has 6 steps; step 5 downloads pinned tools (crane/helm) idempotently with `--dry-run` support

### Key Decisions
- **APT strategy:** Debian 13 DVD-1 as the sole apt source (user-confirmed)
- **K3s delivery:** extend bundle tooling — `make-bundle.sh` downloads k3s binary, `install.sh`, airgap-images tarball, sha256 file into `<bundle>/k3s/` (user-confirmed)
- **`tls-san: teknoir.local`** added to K3s config so the extracted kubeconfig works remotely without cert regeneration

### Proposed Changes
 File | Action | Change |
---|---|---|
 `docs/AIRGAP-HOST-SETUP.md` | Create | New runbook: Debian install, DVD apt, host prep, sysctl, K3s config, offline install, kubeconfig |
 `airgap/versions.env` | Modify | Add `K3S_VERSION` (~v1.33.5+k3s1, matching `KUBE_VERSION` 1.33 in `lib.sh`) and `K3S_ARCH` |
 `airgap/make-bundle.sh` | Modify | New step downloading K3s artifacts into `<bundle>/k3s/`; renumber logs to x/7; update usage text |
 `docs/AIRGAP-BOOTSTRAP.md` | Modify | §2 link to new doc; §4 bundle tree adds `k3s/` |
 `README_infra.md` | Modify | Reference the new runbook |

### Key config documented
```yaml
# /etc/rancher/k3s/config.yaml
kubelet-arg:
  - "max-pods=250"
data-dir: /opt/k3s
disable:
  - traefik
tls-san:
  - "teknoir.local"
```

### Risks
- `zsh-theme-powerlevel9k` may be absent from DVD-1 → marked optional
- K3s asset naming may change → verified against release `sha256sum-amd64.txt`, `K3S_VERSION` env-overridable
- Unpinned `install.sh` → exact bytes captured in `bundle-manifest.yaml` checksums

# Testing

### Validation Approach
Documentation + shell tooling changes validated via the existing offline-readiness gate and dry-run.

### Key Scenarios
- `airgap/verify-offline.sh` step 1 (`bash -n` + shellcheck on `airgap/*.sh`) passes with the modified `make-bundle.sh`
- `airgap/make-bundle.sh --dry-run` prints the new K3s artifact step with correct URLs, target `<bundle>/k3s/`, and consistent 7-step numbering
- Grep the new doc for forbidden host-side online patterns (`get.k3s.io | sh`, `nvidia.github.io`, online apt mirrors) — zero hits

### Edge Cases
- No unbound-variable errors under `set -euo pipefail` in dry-run
- Doc paths cross-checked against `versions.env` (`K3S_DATA_DIR`, `TEKNOIR_HOST`, `TEKNOIR_DOMAIN`)
- Markdown links between `AIRGAP-BOOTSTRAP.md` and `AIRGAP-HOST-SETUP.md` resolve

# Delivery Steps

###   Step 1: Write docs/AIRGAP-HOST-SETUP.md — OS install and host prep sections
The new runbook exists and covers everything up to (but excluding) K3s.

- Create `docs/AIRGAP-HOST-SETUP.md` with overview + machine model referencing `AIRGAP-BOOTSTRAP.md` §1.
- Prerequisites: DVD-1 ISO download/verify on connected workstation, USB transfer.
- Debian 13 install walkthrough: no network mirror, hostname `teknoir`, `teknoir` user, whole-disk partitioning, SSH-server-only selection.
- DVD-as-apt-source section (`apt-cdrom add`, disable online sources in `/etc/apt/sources.list.d/debian.sources`).
- Cloud-init-equivalent prep: sudoers drop-in, `authorized_keys`, `PasswordAuthentication no`, DHCP networking, DVD packages, MOTD files (nvidia-smi line removed/guarded), zsh setup.
- Explicit out-of-scope note for K3s curl-install, TOE, `/toe_conf`, NVIDIA.

###   Step 2: Add OS tuning, K3s config, offline install, and kubeconfig sections
The runbook is complete through K3s install and remote management.

- Add sysctl section: `/etc/sysctl.d/teknoir.inotify.conf` with `fs.inotify.max_user_instances=1024` + `sysctl --system`.
- Add K3s config section: `/etc/rancher/k3s/config.yaml` with `max-pods=250`, `data-dir: /opt/k3s`, `disable: traefik`, `tls-san: teknoir.local`, each with rationale.
- Add offline K3s install: binary to `/usr/local/bin/k3s`, images tarball to `/opt/k3s/agent/images/`, `INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh`, verification commands.
- Add kubeconfig extraction: copy `/etc/rancher/k3s/k3s.yaml`, replace `127.0.0.1`, `chmod 600`, test with `kubectl get nodes`.
- Add 'Next' link to `AIRGAP-BOOTSTRAP.md`.

###   Step 3: Extend bundle tooling to ship K3s artifacts
The bundle build downloads pinned K3s artifacts into `<bundle>/k3s/`.

- Add `K3S_VERSION` and `K3S_ARCH` pins to `airgap/versions.env` (pinned-versions section).
- Add a new step in `airgap/make-bundle.sh` after the tools step: download k3s binary, `k3s-airgap-images-<arch>.tar.zst`, `sha256sum-<arch>.txt` from the k3s GitHub release, plus `install.sh` from `get.k3s.io`; verify checksums; idempotent + `--dry-run` support.
- Renumber step logs from x/6 to x/7 and update the usage layout text.
- Validate with `bash -n`, shellcheck, and `make-bundle.sh --dry-run`.

###   Step 4: Cross-link documentation
All runbooks reference each other consistently.

- Update `docs/AIRGAP-BOOTSTRAP.md` §2 'K3s node' prerequisites to link to the new doc.
- Add `k3s/` to the §4 bundle layout tree in `AIRGAP-BOOTSTRAP.md`.
- Add the new runbook to the references in `README_infra.md`.
- Verify all Markdown links resolve.