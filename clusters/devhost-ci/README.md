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

## Runner image import (until `ghcr.io/teknoir/ci-runner` is public)

The ARC scale sets run `ghcr.io/teknoir/ci-runner:<ver>-<n>@sha256:…` (Dockerfile in `teknoir/ci-workflows`
`runner-image/`). The ghcr package is private and devhost-ci has no ghcr pull secret, so the image is imported into
the node's containerd and also tagged by digest, which is the reference kubelet looks up (`IfNotPresent`):

```sh
docker pull ghcr.io/teknoir/ci-runner:2.338.2-1        # or build it from runner-image/
docker save ghcr.io/teknoir/ci-runner:2.338.2-1 | sudo k3s ctr -n k8s.io images import -
sudo k3s ctr -n k8s.io images tag ghcr.io/teknoir/ci-runner:2.338.2-1 \
  ghcr.io/teknoir/ci-runner@sha256:5034edd365726c3e259ec0946764c0ef08ba825c5426e09df6d390564f38be3a
```

Repeat after every runner image bump and after anything that prunes node images (kubelet image GC above 85 % disk).
Once the package is public (GitHub UI: package settings, Change visibility), kubelet pulls it and this step goes away.
