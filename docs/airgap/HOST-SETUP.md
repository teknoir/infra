# Preparing the node and the LAN host

The node is one x86-64 machine that only the LAN can reach. You install Debian 13
on it from the offline installation image and give a LAN host ssh access;
everything else (k3s, the platform, its certificates, name resolution, image
registry) comes from the bundle with `./teknoir-airgap up`
([OPERATE.md](OPERATE.md#3-first-install)).

Values below are those of the default site, `site/teknoir-local.env` in the
bundle. A different site needs its own values in that file.

| Setting | Value |
|---|---|
| Node address (`NODE_IP`) | `192.168.5.181`, fixed: static, or a DHCP reservation on the router ([Fixed address](#fixed-address)) |
| Node user (from `NODE`) | `teknoir` |
| Host name | `teknoir` |
| Platform domain | `teknoir.airgapped` (no DNS needed) |

## 1. What you need

**Node hardware.** x86-64, 8 or more cores, 16 GB RAM or more (the platform runs in
10 GB but with no headroom), 120 GB or more on one SSD (k3s data in `/opt/k3s`,
Harbor and Keycloak data in `/opt/teknoir`, two bundle payloads and three
backups in `/var/lib/teknoir-airgap`), one wired network port on the LAN.

**LAN host.** A Linux or macOS computer on the same LAN:

| LAN host | Support | Notes |
|---|---|---|
| macOS 13 or later, Apple silicon or Intel | supported | `/bin/bash` 3.2, OpenSSH, `shasum` and `tar` come with macOS |
| Debian 12/13, Ubuntu 22.04 or later, amd64 or arm64 | supported | needs `openssh-client` (installed by default on desktops) |
| Other Linux | `up` works | `trust` only knows the Debian/Ubuntu and macOS trust stores; `trust --print` shows what to do by hand |
| Windows | through WSL2 (Ubuntu) | run everything inside WSL2 |

The LAN host needs no other software: no Python, no kubectl, no Docker. The
bundle carries a `kubectl` for Linux (amd64) and macOS (arm64, amd64), used to
merge the kubeconfig.

**Installation medium.** On a connected machine, download the Debian 13
"DVD-1" image for amd64 (`debian-13.<x>.<y>-amd64-DVD-1.iso`, not the small
netinst image) and its `SHA256SUMS`, check it and write it to a USB stick:

```sh
sha256sum -c --ignore-missing SHA256SUMS   # macOS: compare `shasum -a 256 <iso>` with the ISO's line in SHA256SUMS
sudo dd if=debian-13.<x>.<y>-amd64-DVD-1.iso of=/dev/sdX bs=4M status=progress oflag=sync
# macOS: diskutil list; diskutil unmountDisk /dev/diskN; sudo dd if=... of=/dev/rdiskN bs=4m
```

`/dev/sdX` (or `/dev/rdiskN`) is the whole USB stick; everything on it is lost.

## 2. Install Debian 13 offline (node console)

Boot the node from the USB stick and choose "Install" or "Graphical install".
The answers that matter:

| Installer question | Answer | Why |
|---|---|---|
| Language, location, keyboard | your choice | |
| Network configuration | Configure it **manually**. Without a DHCP server the automatic attempt fails and offers manual configuration; on a LAN with DHCP, cancel or go back and choose manual configuration | the node needs a fixed address |
| IP address | `192.168.5.181/24` (your `NODE_IP` and LAN prefix) | `up` checks that `NODE_IP` is the node's address |
| Gateway | the LAN router if there is one, otherwise leave it empty | no route outside the LAN is needed |
| Name server addresses | leave empty | there is no DNS; the converge maps the platform names in `/etc/hosts` |
| Hostname | `teknoir` | |
| Domain name | leave empty | |
| Root password | **leave empty** (both times) | the installer then installs `sudo` and gives the first user sudo rights, which `teknoir-airgap` uses |
| Full name, user name | `Teknoir`, `teknoir` | the ssh user of `NODE` |
| User password | a strong password, stored in your password manager | asked by `ssh-copy-id` and once by the first `up` |
| Clock / time zone | your zone | the platform works in UTC internally |
| Partitioning | Guided, use entire disk, all files in one partition | all data lives under `/opt` and `/var/lib`; one file system cannot run out of space in the wrong place |
| Scan extra installation media | No | |
| Use a network mirror | **No** | offline install; no online package source is configured |
| Popularity contest | No | |
| Software selection | only **SSH server** and **standard system utilities**; clear every desktop entry | a headless node |
| Install GRUB | Yes, on the system disk | |

The installer names the network interface itself (for example `enp4s0` or
`eno1`) and writes `/etc/network/interfaces` for it; you do not need to know the
name. Do not install NVIDIA, CUDA or any other package from an online source.

A node installed from a Debian cloud image (the live teknoir-local node is a
`genericcloud` image with cloud-init) has no `/etc/network/interfaces`: there
cloud-init writes `/etc/netplan/50-cloud-init.yaml`, netplan renders it for
systemd-networkd, and the address usually comes from DHCP. That works as long
as the address stays `NODE_IP`; see [Fixed address](#fixed-address).

## 3. First boot (node console)

Log in as `teknoir`.

1. The address is the static one:

   ```sh
   ip -br -4 addr
   ```

   shows `192.168.5.181/24` on the network interface.

2. apt has no online source: the installer only configured the installation
   medium. Check that this prints only `cdrom:` lines:

   ```sh
   grep -rhE '^[^#]*(deb |URIs:)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
   ```

   Comment out any `http://` or `https://` entry.

3. Install `curl` from the installation medium (USB stick still inserted; the
   converge uses `curl` for the Harbor API):

   ```sh
   sudo apt-get install -y curl
   ```

   If apt cannot find the medium, register it first with `sudo apt-cdrom add`.
   Then remove the USB stick. chrony and `hwclock` (util-linux-extra) come with
   the bundle: the first `up` installs them offline, so installing chrony here
   is optional.

4. Set the clock if it is wrong (`date -u` shows it in UTC):

   ```sh
   sudo date -u -s 'YYYY-MM-DD HH:MM:SS'   # the time in UTC
   ```

   or skip this and let the first `./teknoir-airgap up --sync-clock` set the node
   clock from the LAN host. `timedatectl set-time` is refused while an NTP
   service (systemd-timesyncd or chrony) is active.

   `up` corrects a difference of up to 30 seconds between the node and the LAN
   host by itself (a node that is ahead is slewed back by chrony, not stepped),
   and refuses more unless you pass `--sync-clock`. It installs
   chrony, gives it the LAN host's time on every run and writes the hardware
   clock (RTC), so the node keeps time between updates and after a reboot.
   The node serves that time to the LAN (NTP on `NODE_IP`, port 123/udp):
   point Robots and cameras at it. If the LAN has an NTP server, name it in
   `TIME_SOURCE` in the site config (space-separated addresses or host names).

5. Write down the ssh host key fingerprint; the first connection asks you to
   confirm it:

   ```sh
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

## 4. Give the LAN host ssh access

On the LAN host:

1. Create a key if you have none (a passphrase is recommended; ssh-agent or the
   macOS keychain then remembers it):

   ```sh
   ssh-keygen -t ed25519
   ```

2. Install it on the node. `ssh-copy-id` shows the node's host key fingerprint
   (compare it with step 3.5) and asks for `teknoir`'s password:

   ```sh
   ssh-copy-id -i ~/.ssh/id_ed25519.pub teknoir@192.168.5.181
   ```

3. Check that ssh no longer asks for a password:

   ```sh
   ssh teknoir@192.168.5.181 true
   ```

4. Optional, once every operator's key is installed: allow key logins only. On
   the node:

   ```sh
   printf 'PasswordAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/10-teknoir.conf
   sudo systemctl reload ssh
   ```

Each operator's LAN host repeats this section with its own key.

## 5. Next: the first install

Carry and check a bundle, then run `./teknoir-airgap up` as described in
[OPERATE.md](OPERATE.md#3-first-install). The first `up` asks you to confirm the
host key fingerprint from step 3.5 and asks for `teknoir`'s sudo password once.
Afterwards, `./teknoir-airgap doctor` checks the node's address (and whether it
is a DHCP lease), clock, hardware clock, chrony and tools.

## Fixed address

`NODE_IP` must stay the node's address: the platform names, the k3s node
address and the LAN hosts' name entries all point at it. Two ways:

- **Static, at install time** (preferred for a new node): the manual network
  configuration in step 2.
- **A DHCP reservation on the router** (the live teknoir-local node, installed
  from a cloud image with DHCP): the router always hands the node's MAC address
  the same IPv4 address. On a UniFi gateway: Client Devices, select the node
  (teknoir-local: `teknoir`, MAC `58:47:ca:7d:39:f0`), Settings, turn on
  **Fixed IP Address**, enter `NODE_IP` on the node's network, apply. Nothing
  changes on the node. After the next lease renewal, check on the node that the
  lease still has `NODE_IP`:

  ```sh
  ip -o -4 addr show | grep ' 192.168.5.181/'   # a fresh "valid_lft" after the renewal
  ```

  Then set `NODE_IP_DHCP_RESERVED=yes` in the site config: `doctor` warns about
  a DHCP lease (`dynamic`) until then.

Keep the router as the node's default route and DNS server when the LAN host is
on another subnet (teknoir-local: the LAN host is on 192.168.2.0/24 and reaches
the node through 192.168.5.1). Do not switch a running node from DHCP to a
static address remotely: the DHCP client releases the lease, and a mistake
cuts off the ssh access `up` needs. If you need it, do it at the node console.

## Name resolution for devices

The cluster resolves every `<name>.<domain>` to `NODE_IP` itself (coredns-custom),
including the per-teamspace names such as `mqtt-<teamspace>.<domain>` (MQTT on
8883) and `deadend-<teamspace>.<domain>` (ssh tunnels on 2222). Robots, cameras
and other LAN devices that connect to a teamspace need the same answer from
their resolver: a wildcard `*.<domain>` record pointing at `NODE_IP` on the
LAN's DNS server (teknoir-local: a local DNS record on the UniFi gateway), or
an `/etc/hosts` entry per name. `./teknoir-airgap trust` only covers the
platform names on a LAN host.

## Inotify limits

Debian's `fs.inotify.max_user_instances=128` is too low for the teamspace
pods: Envoy (istio-proxy) aborts with `inotify_fd_ >= 0 ... Consider increasing
fs.inotify.max_user_instances`. There is nothing to set by hand: the host phase
of `./teknoir-airgap up` writes `/etc/sysctl.d/teknoir.inotify.conf`
(`max_user_instances=1024`, `max_user_watches=524288`) and applies it with
`sysctl --system`, without a reboot. A hand-made file of that name (the old
`HOST-SETUP` step 6) is rewritten to the managed content.

## More nodes

This release runs a single node. The node converge keeps a server/agent role so
agent nodes can be added later, but joining agents is not implemented or tested
yet.
