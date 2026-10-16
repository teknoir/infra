#!/usr/bin/env bash
# ci-node-setup.sh: host setup for the on-cluster CI (platform-applications-gitops charts/ci).
#
#   ci-node-setup.sh server [--restart]   on the k3s server (r415)
#   ci-node-setup.sh agent  --server-ip IP --node-ip IP [--token-file FILE]
#                                          on a dedicated CI build node (vpro)
#
# Idempotent: every step checks first and only changes what differs. Run as root.
#
# Both roles:
#   - qemu-user-static + binfmt (BuildKit multi-arch: arm64, arm/v7)
#   - kubelet image retention drop-in: unused images go after 14 days, disk-pressure GC
#     at 75 % -> 60 % (k3s reads kubelet.conf.d at start; `server --restart` restarts k3s)
#   - journald size cap
#   - BuildKit cache directory (server: /srv/buildkit on the SSD; agent: /var/lib/buildkit)
# agent only:
#   - Docker disabled (k3s brings its own containerd), root LV grown to the whole VG
#   - ufw: the k3s server and the pod/service CIDRs may reach the node
#   - k3s agent joined with taint teknoir.org/ci=true:NoSchedule and label
#     teknoir.org/ci-builder=true. Label the role from the server afterwards:
#       kubectl label node <name> node-role.kubernetes.io/ci-builder=true
#     The join token is read from --token-file (default /etc/rancher/k3s/agent-token,
#     mode 0600); copy it from the server's <data-dir>/server/node-token without printing:
#       ssh r415 sudo cat /opt/k3s/server/node-token | ssh <node> sudo install -m 0600 /dev/stdin /etc/rancher/k3s/agent-token
set -euo pipefail

K3S_VERSION=${K3S_VERSION:-v1.34.5+k3s1}
CLUSTER_CIDRS=(10.42.0.0/16 10.43.0.0/16)

log() { printf 'ci-node-setup: %s\n' "$*"; }
die() { printf 'ci-node-setup: ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

role=${1:-}; shift || true
restart=false server_ip='' node_ip='' token_file=/etc/rancher/k3s/agent-token
while [ $# -gt 0 ]; do
	case $1 in
	--restart) restart=true ;;
	--server-ip) server_ip=$2; shift ;;
	--node-ip) node_ip=$2; shift ;;
	--token-file) token_file=$2; shift ;;
	*) die "unknown argument $1" ;;
	esac
	shift
done

write_if_changed() { # <path> <mode>; content on stdin. Prints "changed" when it wrote.
	local tmp; tmp=$(mktemp)
	cat >"$tmp"
	if [ -f "$1" ] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 0; fi
	install -D -m "$2" "$tmp" "$1"; rm -f "$tmp"
	log "wrote $1"; echo changed
}

binfmt() {
	if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && grep -q 'flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64; then
		log "binfmt: qemu already registered (fix-binary)"
		return
	fi
	apt-get update -q >/dev/null
	DEBIAN_FRONTEND=noninteractive apt-get install -y -q qemu-user-static binfmt-support >/dev/null
	systemctl restart systemd-binfmt 2>/dev/null || true
	grep -q 'flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 || die "qemu-aarch64 binfmt not registered with F"
	log "binfmt: qemu-user-static installed"
}

journald() {
	write_if_changed /etc/systemd/journald.conf.d/teknoir.conf 0644 <<-EOF >/dev/null
		[Journal]
		SystemMaxUse=$1
		RuntimeMaxUse=100M
	EOF
}

kubelet_gc() { # <kubelet.conf.d dir>
	write_if_changed "$1/50-teknoir-gc.conf" 0644 <<-'EOF'
		# Teknoir: image retention (plans/ci-argo-workflows.md). Unused images older than 14 days
		# are removed; disk-pressure GC starts at 75 % and frees down to 60 %.
		apiVersion: kubelet.config.k8s.io/v1beta1
		kind: KubeletConfiguration
		imageGCHighThresholdPercent: 75
		imageGCLowThresholdPercent: 60
		imageMaximumGCAge: 336h
	EOF
}

case $role in
server)
	data_dir=$(sed -n 's/^data-dir: *//p' /etc/rancher/k3s/config.yaml 2>/dev/null)
	data_dir=${data_dir:-/var/lib/rancher/k3s}
	binfmt
	journald 200M
	install -d -m 0711 /srv/buildkit
	if [ -n "$(kubelet_gc "$data_dir/agent/etc/kubelet.conf.d")" ]; then
		if $restart; then
			systemctl restart k3s && log "k3s restarted (kubelet GC settings applied)"
		else
			log "kubelet GC drop-in written; applied at the next k3s restart (or rerun with --restart)"
		fi
	fi
	;;
agent)
	[ -n "$server_ip" ] && [ -n "$node_ip" ] || die "agent needs --server-ip and --node-ip"
	[ -s "$token_file" ] || die "join token $token_file missing (see the header)"
	binfmt
	journald 500M
	install -d -m 0711 /var/lib/buildkit
	if systemctl is-enabled -q docker.service 2>/dev/null; then
		systemctl disable docker.service docker.socket containerd.service >/dev/null 2>&1 || true
		log "docker disabled at boot"
	fi
	if command -v lvs >/dev/null && vg=$(vgs --noheadings -o vg_name 2>/dev/null | head -n1 | tr -d ' ') && [ -n "$vg" ]; then
		free=$(vgs --noheadings --units b -o vg_free "$vg" | tr -dc 0-9)
		root_lv=$(findmnt -n -o SOURCE /)
		if [ "${free:-0}" -gt 1073741824 ]; then lvextend -r -l +100%FREE "$root_lv" >/dev/null && log "root LV extended"; fi
	fi
	if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
		for src in "$server_ip" "${CLUSTER_CIDRS[@]}"; do ufw allow from "$src" comment k3s >/dev/null; done
		for c in "${CLUSTER_CIDRS[@]}"; do ufw route allow from "$c" >/dev/null; ufw route allow to "$c" >/dev/null; done
		log "ufw: k3s server and cluster CIDRs allowed"
	fi
	write_if_changed /etc/rancher/k3s/config.yaml 0600 <<-EOF >/dev/null
		# k3s agent of the staging cluster (CI build node). See plans/ci-argo-workflows.md.
		server: https://${server_ip}:6443
		token-file: ${token_file}
		node-ip: ${node_ip}
		node-label:
		  - teknoir.org/ci-builder=true
		node-taint:
		  - teknoir.org/ci=true:NoSchedule
		kubelet-arg:
		  - container-log-max-size=10Mi
		  - container-log-max-files=3
	EOF
	gc_changed=$(kubelet_gc /var/lib/rancher/k3s/agent/etc/kubelet.conf.d)
	if ! systemctl is-active -q k3s-agent; then
		curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
		INSTALL_K3S_VERSION=$K3S_VERSION INSTALL_K3S_EXEC=agent sh /tmp/k3s-install.sh
		log "k3s agent $K3S_VERSION installed"
	elif [ -n "$gc_changed" ]; then
		systemctl restart k3s-agent && log "k3s-agent restarted (kubelet GC settings applied)"
	fi
	;;
*) die "usage: $0 server [--restart] | agent --server-ip IP --node-ip IP [--token-file FILE]" ;;
esac
log "done ($role)"
