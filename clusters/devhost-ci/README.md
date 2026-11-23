# devhost-ci

Single-node k3s on the dev host teknoir.airgapped (192.168.2.181) that runs the GitHub Actions runners for private repos (ARC), plus a rootless BuildKit daemon. Design: `plans/cicd/proposal-v4.md` section 5 (in the `~/git/ai/plans` folder).

| What | Where |
|---|---|
| k3s config | `k3s-config.yaml` (installed to `/etc/rancher/k3s/config.yaml`) |
| Install / re-apply | `sudo clusters/devhost-ci/install.sh` (idempotent; pins k3s `v1.34.13+k3s1`) |
| Uninstall | `sudo /usr/local/bin/k3s-uninstall.sh` (keeps `/var/lib/ci-cache` and `/var/lib/buildkit`) |
| Runner and BuildKit config | gitops `charts/ci-runners/` (helm until v4 P6.3, then ArgoCD on r415) |
| Secrets (names only) | `secrets.md` |

## Host state outside k3s (set by install.sh)
- `user.slice` `CPUWeight=1000` (`/etc/systemd/system.control/user.slice.d/50-CPUWeight.conf`): agent sessions beat CI pods (kubepods weight about 900) under CPU contention.
- `/var/lib/ci-cache/<scale-set>/{go-mod,go-build,yarn,npm,tool-cache}` owned by 1001:1001; `/var/lib/buildkit` owned by 1000:1000.
- QEMU binfmt for arm64 from the Debian packages `qemu-user-static` and `qemu-user-binfmt` (flags `POF`, persistent).
- Swap: `/swapfile` 32 GiB, `vm.swappiness=10` (`/etc/sysctl.d/90-swap.conf`). Pods never swap.
- The DHCP reservation for 192.168.2.181 is on the office router (Anders).

## Checks after install (2026-11-23, all passed)
- `kubectl --context devhost-ci get nodes`: Ready, v1.34.13+k3s1. Allocatable 23 CPU, about 22.8 GiB.
- `/sys/fs/cgroup/kubepods.slice/memory.max` is 24.8 GiB (capacity minus system- and kube-reserved).
- A busybox pod resolves DNS and reaches api.github.com:443, harbor.teknoir.cloud (401 on `/v2/`), r415 on the LAN and the cluster service network. Docker's `FORWARD DROP` policy did not block pod traffic, so no `DOCKER-USER` rule is needed. If a future docker upgrade breaks pod egress, add `iptables -I DOCKER-USER -s 10.52.0.0/16 -j ACCEPT` here.
- `which -a kubectl` unchanged (`INSTALL_K3S_SYMLINK=skip`).

## Kubeconfig
`install.sh` prints the commands that copy `/etc/rancher/k3s/k3s.yaml` into `~/.kube/config` as context `devhost-ci` with server `https://192.168.2.181:6443`. Always pass `--context devhost-ci` (or `--kube-context devhost-ci`); it is never the current context.

## Network
6443/tcp should only be reachable from r415 (192.168.2.166, for ArgoCD from P6.3) and the host itself; the host firewall is off today, so this relies on the office LAN.
