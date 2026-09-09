# Air-Gap Host Setup Runbook (offline node preparation)

Prepare a bare Debian 13 (trixie) machine as the air-gapped K3s node **before**
the platform bootstrap. This is the step that
[AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) §2 assumes ("K3s installed with
`data-dir: /opt/k3s`"): here we install the OS offline, prepare the host, tune
the OS/K3s, install K3s from the bundle, and extract a kubeconfig for remote
management.

The node has **no internet access at any point** — not during the Debian
install, not for apt, not for K3s. Everything arrives on a USB drive prepared
on a connected workstation. Every command in the on-node sections
(§3 onward) is offline-safe by construction.

This runbook is the manual, offline-safe equivalent of the Teknoir OS
`cloud-init.yaml`. The bootstrap-specific and GPU parts of that cloud-init are
**intentionally out of scope** here — see §5's out-of-scope note.

## 1. Overview & machine model

Same three-machine model as [AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) §1. This
runbook prepares the **K3s node**; the connected workstation and the LAN laptop
are unchanged.

```
[connected workstation]         [USB]          [teknoir@teknoir.airgapped (K3s node)]
Debian 13 DVD-1 ISO  ───────────► USB ──► install Debian 13 offline
make-bundle.sh (incl. k3s/) ──┬─► USB ──► host prep + OS/K3s tuning
                              └─► rsync ► install K3s offline (INSTALL_K3S_SKIP_DOWNLOAD)
    (airgap/upload-bundle.sh, LAN ssh)    ──► node Ready, ready for bootstrap-airgap.sh
```

The DVD-1 ISO always travels on USB (the node has no OS yet). The **bundle** can
travel on the same USB **or**, once the node is installed and SSH-reachable, be
pushed over the LAN with `airgap/upload-bundle.sh` (rsync over ssh — §8.1).

After this runbook the node is a healthy single-node K3s cluster with traefik
disabled and `data-dir: /opt/k3s`, and the operator has a working kubeconfig.
Continue with [AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) for the platform
install.

## 2. Prerequisites (connected workstation)

Everything the node needs is assembled here, on a machine **with** internet,
and copied to USB.

1. **Debian 13 (trixie) DVD-1 ISO.** Download the DVD-1 image (not the small
   netinst — DVD-1 carries the packages needed for an offline install) and
   verify its checksum against the official `SHA256SUMS`:

   ```sh
   # on the connected workstation
   sha256sum debian-13.*-amd64-DVD-1.iso
   # compare against the SHA256SUMS published next to the ISO
   ```

2. **The air-gap bundle, including `k3s/`.** Build (or reuse) the bundle — it
   now ships the pinned K3s install artifacts under `k3s/`:

   ```sh
   ./airgap/make-bundle.sh          # add --dry-run to preview
   ```

   The `k3s/` directory contains (pins in `airgap/versions.env`,
   `K3S_VERSION` / `K3S_ARCH`):

   | File | Purpose |
   |---|---|
   | `k3s` | the K3s binary (→ `/usr/local/bin/k3s` on the node) |
   | `k3s-airgap-images-<arch>.tar.zst` | K3s' own images (→ `/opt/k3s/agent/images/`) |
   | `install.sh` | the `get.k3s.io` installer, fetched at **bundle-build time** on the connected workstation and shipped in the checksummed bundle (never fetched on the node) |
   | `sha256sum-<arch>.txt` | checksums `make-bundle.sh` verifies the binary + tarball against |

   > The exact `install.sh` bytes used on the node are captured in
   > `bundle-manifest.yaml`, so the unpinned installer is pinned in practice.

   The bundle is **self-contained**: alongside `k3s/` it also embeds the
   air-gapped side's operational scripts under `airgap/` (runtime tooling —
   `bootstrap-airgap.sh`, `push-to-harbor.sh`, `deploy-app-of-apps.sh`,
   `update-airgap.sh`, `upload-bundle.sh`, plus `lib.sh`/`versions.env`) and
   `scripts/` (the `gen-*.sh` secret generators + `deploy-secrets.sh`), and the
   bootstrap secret manifests under `bootstrap/secrets/`. So the same transfer
   that carries the install artifacts also carries every script and secret the
   runbooks expect — nothing extra needs to be copied next to the bundle. (The
   internet-only build steps — `make-bundle.sh`, `collect-*.sh`,
   `render-bootstrap.sh`, `verify-offline.sh` — are intentionally **not**
   bundled.)

3. **A USB drive** large enough for the DVD-1 ISO **and** the bundle (the bundle
   already embeds the `airgap/` + `scripts/` tooling — see §2 and
   [AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) §5).

   > The DVD-1 ISO must arrive on USB (the node has no OS yet). The **bundle**,
   > however, can be delivered either on the same USB or — once the node is
   > installed and SSH-reachable on the LAN — pushed over rsync with
   > `airgap/upload-bundle.sh` (§8.1). rsync runs over ssh on the LAN, so it does
   > not break the air gap.

## 3. Install Debian 13 (trixie) — offline

Write the DVD-1 ISO to USB on the connected workstation (adjust `/dev/sdX`):

```sh
sudo dd if=debian-13.*-amd64-DVD-1.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot the node from USB and run the installer. The air-gap-relevant choices:

| Installer step | Choice | Why |
|---|---|---|
| Network mirror | **No** (skip the network mirror) | offline install; apt is configured from the DVD in §4 |
| Hostname | `teknoir` | matches the platform naming |
| Domain | `teknoir.airgapped` | matches `TEKNOIR_DOMAIN` in `airgap/versions.env` |
| User account | create user **`teknoir`** | matches `TEKNOIR_HOST=teknoir@teknoir.airgapped` used by all airgap tooling |
| Partitioning | **Guided — use entire disk** | manual equivalent of the cloud-init `growpart` (use the whole disk from the start) |
| Software selection | **SSH server** + **standard system utilities** only (deselect the desktop) | headless node; smaller offline footprint |

When asked about a network mirror, choose **No** — the installer will fall back
to the DVD as the only apt source, which is exactly what §4 relies on.

## 4. Configure apt from the DVD (no internet)

The DVD-1 image is the **only** apt source. After first boot, either use
`apt-cdrom` with the DVD-1 medium (USB) inserted:

```sh
sudo apt-cdrom add        # register the DVD-1 medium as an apt source
sudo apt-get update
```

…or, if the ISO is copied onto the node, loop-mount it and add a `file:` source
in Debian 13's deb822 format:

```sh
sudo mkdir -p /srv/debian-dvd
sudo mount -o loop,ro /path/to/debian-13-DVD-1.iso /srv/debian-dvd
```

Create `/etc/apt/sources.list.d/debian-dvd.sources`:

```
Types: deb
URIs: file:/srv/debian-dvd
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
```

Then **disable any online entries** so `apt-get update` never reaches out:
comment out every stanza in `/etc/apt/sources.list.d/debian.sources` (the
default online source Debian 13 writes), and finally:

```sh
sudo apt-get update
```

Notes:

* The cloud-init adds `contrib non-free` components
  (`sed -i 's/main/main contrib non-free/g'`). DVD-1 provides **`main`**; add
  `contrib non-free non-free-firmware` to `Components:` **only** if the DVD you
  use carries them. Packages not present on DVD-1 are called out as **optional**
  in §5.
* No online-mirror apt lines (`http(s)://…` URIs) are used anywhere in this
  runbook — only the DVD `file:` source above.

## 5. Host preparation (cloud-init equivalent)

Manual steps mirroring `cloud-init.yaml`, each with a short "why". Run them as
root (or with `sudo`).

### 5.1 `teknoir` user

Cloud-init `users:` + `chpasswd:` blocks. If the installer already created
`teknoir`, only the sudoers drop-in, SSH key, and shell need attention.

```sh
# sudo group + passwordless sudo (cloud-init: groups: sudo, sudo: NOPASSWD:ALL)
sudo usermod -aG sudo teknoir
printf 'teknoir ALL=(ALL) NOPASSWD:ALL\n' | sudo tee /etc/sudoers.d/teknoir
sudo chmod 0440 /etc/sudoers.d/teknoir

# platform/operator public key (cloud-init: ssh-authorized-keys)
sudo -u teknoir mkdir -p /home/teknoir/.ssh
sudo -u teknoir tee -a /home/teknoir/.ssh/authorized_keys < /path/to/id_rsa.pub
sudo -u teknoir chmod 700 /home/teknoir/.ssh
sudo -u teknoir chmod 600 /home/teknoir/.ssh/authorized_keys

# login shell zsh (cloud-init: shell: /bin/zsh) — after zsh is installed (§5.4)
sudo chsh -s /bin/zsh teknoir

# non-expiring password (cloud-init: chpasswd.expire: false)
sudo chage -E -1 -M -1 teknoir
```

Why: the airgap tooling connects as `teknoir@teknoir.airgapped` with passwordless
`sudo` (see [AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) §2, §6); the operator key
authorizes that access without a password.

> **Operator SSH key.** The key pair is **generated externally** (not by this
> runbook) and kept under `.secrets/` on the operator laptop. Install the
> matching public key as `id_rsa.pub` above, and connect with the private key
> explicitly:
>
> ```sh
> ssh teknoir@teknoir.airgapped -i .secrets/teknoir.airgapped.id_rsa
> ```

### 5.2 sshd hardening

Cloud-init `ssh_pwauth: false` — key-only login.

```sh
printf 'PasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/teknoir.conf
sudo systemctl restart ssh
```

Why: an air-gapped node must not accept password logins; the operator key from
§5.1 is the only way in.

### 5.3 Network — DHCP on the primary interface

Cloud-init `network:` (netplan) + the `write_files` `10-eth0.network`. Use
whichever manager the offline install set up.

**systemd-networkd** (matches the cloud-init `write_files` unit) — create
`/etc/systemd/network/10-eth0.network` (replace `eth0` with the real interface
name from `ip link`):

```
[Match]
Name=eth0
[Network]
DHCP=ipv4
```

```sh
sudo systemctl enable --now systemd-networkd
```

**NetworkManager** (if `network-manager` is installed and manages the link):

```sh
sudo nmcli connection modify "Wired connection 1" ipv4.method auto
sudo nmcli connection up "Wired connection 1"
```

Why: the node needs a stable LAN address so the laptop can reach it over SSH
and, later, on 443 via the node IP.

> **Name resolution.** Both the apex `teknoir.airgapped` **and** the
> `*.teknoir.airgapped` wildcard (every subdomain — `harbor.`, `argocd.`,
> `auth.`, `keycloak.`, `grafana.`, …) must be resolvable to this node's IP on
> the LAN. `bootstrap-airgap.sh` maintains the node's *own* `/etc/hosts`; every
> other client (e.g. the operator laptop) needs matching `/etc/hosts` entries
> (one line per hostname — hosts files cannot express a wildcard) or a LAN DNS
> `A` record for `teknoir.airgapped` plus a wildcard `*.teknoir.airgapped` record
> (see [AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) §2).

### 5.4 Packages from the DVD

Cloud-init `packages:` — installed here from the DVD apt source (§4):

```sh
sudo apt-get install -y \
  htop curl wget git gpg rsync \
  zsh zsh-autosuggestions zsh-syntax-highlighting \
  network-manager linux-headers-amd64
```

Optional (install only if present on your DVD — cosmetic, safe to skip):

```sh
sudo apt-get install -y zsh-theme-powerlevel9k || true
```

Why: these match the cloud-init package set minus the GPU toolchain.
`zsh-theme-powerlevel9k` is a theme and may not be on DVD-1 — the zsh config in
§5.6 tolerates its absence.

> **`rsync` enables the fast LAN upload path.** `airgap/upload-bundle.sh` (§8.1)
> prefers `rsync` over ssh but needs `rsync` on **both** ends; without it on the
> node the helper still works, falling back to streaming a gzip'd `tar` over ssh
> (slower, no incremental sync). Installing `rsync` here from the DVD keeps the
> efficient rsync path available. `tar` and `ssh` are already present from the
> base install, so the fallback needs nothing extra.

### 5.5 MOTD

Cloud-init `write_files` MOTD scripts. Create the three files, each
`chmod 0755`. The `nvidia-smi` line from the cloud-init `02-resources` is
**removed** (GPU is out of scope).

`/etc/update-motd.d/00-header`:

```sh
#!/bin/sh

printf " _____ _____ _  ___   _  ___ ___ ____ \n"
printf "|_   _| ____| |/ / \ | |/ _ \_ _|  _ \ \n"
printf "  | | |  _| | ' /|  \| | | | | || |_) | \n"
printf "  | | | |___| . \| |\  | |_| | ||  _ <  \n"
printf "  |_| |_____|_|\_\_| \_|\___/___|_| \_\ \n\n"

[ -r /etc/lsb-release ] && . /etc/lsb-release
if [ -z "$DISTRIB_DESCRIPTION" ] && [ -x /usr/bin/lsb_release ]; then
  DISTRIB_DESCRIPTION=$(lsb_release -s -d)
fi
printf "Teknoir OS built on %s (%s %s %s)\n" "$DISTRIB_DESCRIPTION" "$(uname -o)" "$(uname -r)" "$(uname -m)"
```

`/etc/update-motd.d/01-help-text`:

```sh
#!/bin/sh

printf "\n"
printf " * Documentation:  https://teknoir.airgapped\n"
printf " * Support:        https://www.teknoir.ai\n"
```

`/etc/update-motd.d/02-resources` (no `GPU:` / `nvidia-smi` line):

```sh
#!/bin/sh

printf "\n"
printf "CPU: $(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)\n"
printf "RAM: $(free -h | grep Mem | awk '{print $2}')\n"
printf "Disk: $(df -h / | grep / | awk '{print $2}')\n"
printf "\n"
printf "Uptime: $(uptime -p | awk '{print $2,$3,$4,$5,$6,$7}')\n"
printf "\n"
```

```sh
sudo chmod 0755 /etc/update-motd.d/00-header /etc/update-motd.d/01-help-text /etc/update-motd.d/02-resources
```

### 5.6 zsh configuration (teknoir + root)

Cloud-init `runcmd` zsh block, written to tolerate a missing theme:

```sh
for home_user in "teknoir:/home/teknoir" "root:/root"; do
  u="${home_user%%:*}"; h="${home_user##*:}"
  sudo cp /etc/zsh/newuser.zshrc.recommended "${h}/.zshrc"
  # source the theme only if it is actually installed (powerlevel9k is optional)
  echo '[ -r /usr/share/powerlevel9k/powerlevel9k.zsh-theme ] && source /usr/share/powerlevel9k/powerlevel9k.zsh-theme' | sudo tee -a "${h}/.zshrc"
  echo '[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh' | sudo tee -a "${h}/.zshrc"
  echo '[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh' | sudo tee -a "${h}/.zshrc"
  sudo chown "${u}:${u}" "${h}/.zshrc" 2>/dev/null || sudo chown "${u}:root" "${h}/.zshrc"
done
sudo chsh -s /bin/zsh root
```

### Out of scope (intentionally skipped cloud-init parts)

These parts of `cloud-init.yaml` are **not** done in this runbook:

* **K3s via `get.k3s.io`** — the cloud-init pipes the online installer; here K3s
  is installed **offline** from the bundle in §8.
* **TOE manifest / `/toe_conf`** — the reverse-tunnel `rsa_private.pem` copy and
  the `teknoir.yaml` TOE helm-chart symlink into the K3s manifests dir. TOE is a
  later platform concern, not host prep.
* **NVIDIA driver / CUDA / container-toolkit** — all GPU steps (the NVIDIA apt
  keyring/source, `nvidia-driver`, `cuda`, `nvidia-container-toolkit`) are out
  of scope entirely; none of their online repositories are contacted.

## 6. OS tuning — inotify limits

Create `/etc/sysctl.d/teknoir.inotify.conf`:

```
fs.inotify.max_user_instances=1024
```

```sh
printf 'fs.inotify.max_user_instances=1024\n' | sudo tee /etc/sysctl.d/teknoir.inotify.conf
sudo sysctl --system
```

Why: a Kubernetes node runs many pods, log watchers, and controllers, each
consuming inotify instances; the Debian default is easily exhausted, causing
"too many open files" and crash-looping watchers.

## 7. K3s configuration (before install)

Write the K3s config **before** the first start so K3s comes up with the right
data dir, disabled components, and TLS SAN:

```sh
sudo mkdir -p /etc/rancher/k3s
```

`/etc/rancher/k3s/config.yaml`:

```yaml
kubelet-arg:
  - "max-pods=250"
data-dir: /opt/k3s
disable:
  - traefik
tls-san:
  - "teknoir.airgapped"
```

Rationale:

* `data-dir: /opt/k3s` matches `K3S_DATA_DIR` used by **all** airgap tooling
  (`airgap/versions.env`; `bootstrap-airgap.sh` writes to
  `/opt/k3s/server/manifests` and `/opt/k3s/agent/images`).
* `disable: traefik` — the Istio ingressgateway owns 80/443
  (see [AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) §10); traefik would conflict.
* `tls-san: ["teknoir.airgapped"]` — so the kubeconfig extracted in §9 validates
  against `teknoir.airgapped` from the operator laptop. Setting it **before** the
  first start avoids regenerating the API server certificate later.
* `max-pods=250` — headroom for the platform's many small pods.

## 8. Install K3s — offline

### 8.1 Transfer the bundle to the node

The on-node install below reads from the bundle's `k3s/` directory (§2). Get the
bundle onto the node one of two ways:

* **USB** (fully offline) — copy the bundle directory from the USB drive to the
  node, e.g. into the `teknoir` user's home.
* **LAN rsync** (when the node is already SSH-reachable) — from the operator
  laptop, use the helper. It rsyncs over ssh on the LAN (not an internet fetch),
  so it stays within the air gap:

  ```sh
  # operator laptop, from the infra repo checkout
  ./airgap/upload-bundle.sh
  # the key at .secrets/teknoir.airgapped.id_rsa is auto-detected; a key
  # elsewhere: --ssh-key FILE (or SSH_KEY=FILE ./airgap/upload-bundle.sh)
  # preview with --dry-run; upload a specific bundle with --bundle DIR
  ```

  This mirrors `bundle/teknoir-airgap-bundle-<version>/` into the `teknoir`
  user's home (override the parent dir with `--dest`), so the install artifacts
  land at `~/teknoir-airgap-bundle-<version>/k3s/` on the node. The ssh target
  (`teknoir@teknoir.airgapped`) and bundle version default from
  `airgap/versions.env`; the same `SSH_KEY` auto-detection / override is
  honored by the other airgap scripts (e.g. `bootstrap-airgap.sh`).

  Because the bundle is self-contained (§2), the upload also delivers the
  embedded `airgap/` runtime scripts, the `scripts/` secret generators, and the
  `bootstrap/secrets/` manifests to the node in one shot — so everything the
  bootstrap runbook runs is present on the target, not just the K3s install
  files.

### 8.2 Install K3s from the bundle

K3s is installed **without any download** (`INSTALL_K3S_SKIP_DOWNLOAD=true`):

```sh
# from the bundle's k3s/ directory on the node
# (e.g. cd ~/teknoir-airgap-bundle-<version>/k3s):

# 1. the K3s binary
sudo install -m 0755 k3s /usr/local/bin/k3s

# 2. K3s' own airgap images, into the data-dir-relative images dir
#    (NOT /var/lib/rancher — data-dir is /opt/k3s per §7)
sudo mkdir -p /opt/k3s/agent/images
sudo cp k3s-airgap-images-*.tar.zst /opt/k3s/agent/images/

# 3. run the bundled installer with downloads disabled
#    (config.yaml from §7 is picked up automatically)
sudo INSTALL_K3S_SKIP_DOWNLOAD=true ./install.sh
```

Verify:

```sh
sudo systemctl status k3s --no-pager
sudo k3s kubectl get nodes                       # STATUS: Ready
sudo k3s kubectl get pods -A                      # no traefik pods
sudo k3s kubectl describe node | grep -i '  pods' # capacity/allocatable pods: 250
```

## 9. Extract the kubeconfig for remote management

Copy the node kubeconfig to the operator laptop and point it at the node
instead of `127.0.0.1`:

```sh
# on the node — show the kubeconfig (server is https://127.0.0.1:6443)
sudo cat /etc/rancher/k3s/k3s.yaml
```

On the operator laptop, save it and replace the loopback address with the node
IP (or `teknoir.airgapped`):

```sh
# replace 127.0.0.1 with the node IP … (node static IP; NODE_IP in airgap/versions.env)
sed 's/127.0.0.1/192.168.5.181/' k3s.yaml > ~/.kube/teknoir.yaml
# … or with teknoir.airgapped (needs the §7 tls-san AND the laptop /etc/hosts
#    entry from AIRGAP-BOOTSTRAP.md §2)
# sed 's/127.0.0.1/teknoir.airgapped/' k3s.yaml > ~/.kube/teknoir.yaml

chmod 600 ~/.kube/teknoir.yaml
kubectl --kubeconfig ~/.kube/teknoir.yaml get nodes
```

Why the `tls-san`: without `teknoir.airgapped` in the API server certificate (§7),
TLS validation fails when the kubeconfig server is `teknoir.airgapped`; using the
node IP works because K3s adds node IPs to the cert automatically.

## Next

The node is now a healthy K3s cluster with traefik disabled and
`data-dir: /opt/k3s`. Continue with
[AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md) to install the Teknoir platform
(CA, registries, secrets, Istio → ArgoCD → Harbor, and the GitOps tier).
