#!/usr/bin/env bash
# Install or re-apply the devhost-ci k3s cluster on the dev host (plans/cicd/proposal-v4.md 5.1, step P1.2).
# Idempotent: safe to re-run after a config change (k3s restarts when the config differs).
# Run with sudo from a checkout of infra: sudo clusters/devhost-ci/install.sh
set -euo pipefail

K3S_VERSION="v1.34.13+k3s1"   # same minor as staging r415 (v1.34.5)
HERE="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

# 1. Host prerequisites -------------------------------------------------------
# Agent sessions (user.slice) must win CPU contention against CI pods (kubepods weight ~900).
systemctl set-property user.slice CPUWeight=1000

# Runner caches (UID 1001 = runner user in ghcr.io/actions/actions-runner) and BuildKit state (UID 1000, rootless).
for set in teknoir-ci teknoir-land teknoir-push; do
  install -d -o 1001 -g 1001 -m 0755 /var/lib/ci-cache/$set
  for d in go-mod go-build yarn npm tool-cache; do install -d -o 1001 -g 1001 -m 0755 /var/lib/ci-cache/$set/$d; done
done
install -d -o 1000 -g 1000 -m 0700 /var/lib/buildkit

# arm64 emulation for BuildKit: the Debian packages register binfmt with the F flag, persistent across boots.
if ! grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
  apt-get install -y qemu-user-static qemu-user-binfmt
fi

# 2. k3s ------------------------------------------------------------------------
install -d -m 0755 /etc/rancher/k3s
changed=0
if ! cmp -s "$HERE/k3s-config.yaml" /etc/rancher/k3s/config.yaml; then
  install -m 0644 "$HERE/k3s-config.yaml" /etc/rancher/k3s/config.yaml
  changed=1
fi

installed="$(k3s --version 2>/dev/null | awk 'NR==1{print $3}' || true)"
if [ "$installed" != "$K3S_VERSION" ]; then
  # A node password left from an earlier, removed k3s blocks a fresh node registration.
  [ -e /var/lib/rancher/k3s ] || rm -f /etc/rancher/node/password
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  curl -sfL https://get.k3s.io -o "$tmp"
  # INSTALL_K3S_SYMLINK=skip: keep the host's own kubectl (it must match staging, see install-devtools.sh).
  INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_SYMLINK=skip sh "$tmp"
elif [ "$changed" = 1 ]; then
  systemctl restart k3s
fi

echo "waiting for node devhost-ci to be Ready..."
for _ in $(seq 1 60); do
  k3s kubectl get node devhost-ci 2>/dev/null | grep -q ' Ready' && break
  sleep 5
done
k3s kubectl get node devhost-ci

cat <<'EOF'

Next (as the normal user, see README.md "Kubeconfig"):
  sudo cat /etc/rancher/k3s/k3s.yaml | sed 's/default/devhost-ci/g; s#127.0.0.1#192.168.2.181#' > ~/.kube/devhost-ci.yaml
  KUBECONFIG=~/.kube/config:~/.kube/devhost-ci.yaml kubectl config view --flatten > ~/.kube/config.new && mv ~/.kube/config.new ~/.kube/config
  kubectl --context devhost-ci get nodes
EOF
