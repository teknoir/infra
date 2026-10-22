#!/usr/bin/env bash
# ci-node-setup.sh: host setup for the on-cluster CI (platform-applications-gitops charts/ci).
#
#   ci-node-setup.sh server [--restart] [--agent-ip IP]... [REGISTRY OPTIONS]
#                                          on the k3s server (r415, now vpro); --agent-ip opens ufw
#                                          for an agent node: flannel VXLAN (8472/udp) and the
#                                          kubelet (10250/tcp) from it, and the pod/service CIDRs
#   ci-node-setup.sh agent  --server-ip IP --node-ip IP [--token-file FILE]
#                          [--keep-docker] [--no-grow-root] [--label K=V]... [--taint K=V:EFFECT]...
#                          [REGISTRY OPTIONS]
#                                          on a dedicated CI build node (vpro), or a shared host
#                                          such as the dev host (virtual devices + CI tests):
#     --keep-docker   leave Docker enabled (the host uses it; k3s has its own containerd anyway)
#     --no-grow-root  do not extend the root LV over the free space of its VG
#     --label/--taint replace the default label teknoir.org/ci-builder=true and taint
#                     teknoir.org/ci=true:NoSchedule (give each flag once per value)
#
# REGISTRY OPTIONS (plans/harbor-proxy-staging.md): pull images through the Harbor proxy-cache
# projects, with the upstream registry as the fallback (k3s always tries its default endpoint last):
#   --registry-mirror HOST|none   write /etc/rancher/k3s/registries.yaml (mode 0600, first line
#                                 `# managed by ci-node-setup.sh`) mirroring docker.io, ghcr.io,
#                                 gcr.io, quay.io, registry.k8s.io and nvcr.io to HOST's projects
#                                 dockerhub/ ghcr/ gcr/ quay/ k8s/ nvcr/. `none` removes a managed
#                                 file (rollback). A registries.yaml without the marker is never
#                                 overwritten or removed. Without the option the file is left alone.
#   --registry-auth-file FILE     required with HOST: one line `username:password` (the robot
#                                 $nodes of Harbor, Secret teknoir-system/harbor-nodes-pull), mode
#                                 0600 and owned by root. The password is never printed.
#                                 CAVEAT: the $nodes robot can pull the private ghcr.io/teknoir/*
#                                 images, so any pod on this node, in any namespace and without a
#                                 pull secret, can pull them too. Fine on staging; on a cluster with
#                                 customer teamspaces use a robot without ghcr (plans/new-cluster-
#                                 requirements.md section 10).
#                                 NOTE: a pod's own upstream imagePullSecret (docker.io, ghcr.io,
#                                 nvcr.io) is sent to the mirror too (kubelet never sets the
#                                 credential's server address): Harbor rejects it and the pull
#                                 bypasses the cache (plans/harbor-proxy-staging.md).
#   An agent restarts k3s-agent when the file changed. The server restarts k3s only with --restart
#   (the API is down for about a minute; pods keep running, KillMode=process); otherwise it logs
#   that the change applies at the next restart.
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

# shellcheck source=lib/registries.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/registries.sh"

K3S_VERSION=${K3S_VERSION:-v1.34.5+k3s1}
CLUSTER_CIDRS=(10.42.0.0/16 10.43.0.0/16)
REGISTRIES_FILE=${REGISTRIES_FILE:-/etc/rancher/k3s/registries.yaml}

log() { printf 'ci-node-setup: %s\n' "$*"; }
die() { printf 'ci-node-setup: ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"

role=${1:-}; shift || true
restart=false server_ip='' node_ip='' token_file=/etc/rancher/k3s/agent-token
keep_docker=false grow_root=true labels=() taints=() agent_ips=()
registry_mirror='' registry_auth_file=''
while [ $# -gt 0 ]; do
	case $1 in
	--restart) restart=true ;;
	--server-ip) server_ip=$2; shift ;;
	--node-ip) node_ip=$2; shift ;;
	--token-file) token_file=$2; shift ;;
	--keep-docker) keep_docker=true ;;
	--agent-ip) agent_ips+=("$2"); shift ;;
	--no-grow-root) grow_root=false ;;
	--label) labels+=("$2"); shift ;;
	--taint) taints+=("$2"); shift ;;
	--registry-mirror) registry_mirror=$2; shift ;;
	--registry-auth-file) registry_auth_file=$2; shift ;;
	*) die "unknown argument $1" ;;
	esac
	shift
done
if [ -n "$registry_mirror" ] && [ "$registry_mirror" != none ]; then
	registries_valid_host "$registry_mirror" || die "invalid --registry-mirror '$registry_mirror' (a host name, or none)"
	[ -n "$registry_auth_file" ] || die "--registry-mirror $registry_mirror needs --registry-auth-file (the proxy projects are private)"
elif [ -n "$registry_auth_file" ] && [ -z "$registry_mirror" ]; then
	die "--registry-auth-file needs --registry-mirror HOST"
fi
if [ -n "$registry_mirror" ]; then # fail before the first change when the file or the auth is unusable
	registries_check "$registry_mirror" "$registry_auth_file" "$REGISTRIES_FILE" || die "registries.yaml not applied (see above)"
fi

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

registries() { # prints "changed" when registries.yaml was written or removed (no-op without --registry-mirror)
	[ -n "$registry_mirror" ] || return 0
	local rc=0
	registries_apply "$registry_mirror" "$registry_auth_file" "$REGISTRIES_FILE" || rc=$?
	[ "$rc" -eq 0 ] || die "registries.yaml not applied (see above)"
}

case $role in
server)
	data_dir=$(sed -n 's/^data-dir: *//p' /etc/rancher/k3s/config.yaml 2>/dev/null)
	data_dir=${data_dir:-/var/lib/rancher/k3s}
	binfmt
	journald 200M
	install -d -m 0711 /srv/buildkit
	if [ ${#agent_ips[@]} -gt 0 ] && command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
		for ip in "${agent_ips[@]}"; do
			ufw allow proto udp from "$ip" to any port 8472 comment 'k3s flannel vxlan' >/dev/null
			ufw allow proto tcp from "$ip" to any port 10250 comment 'k3s kubelet' >/dev/null
		done
		for c in "${CLUSTER_CIDRS[@]}"; do
			ufw allow from "$c" comment k3s >/dev/null
			ufw route allow from "$c" >/dev/null; ufw route allow to "$c" >/dev/null
		done
		# `ufw allow` alone left the new rules out of the live chains on vpro (2026-10-16:
		# flannel VXLAN from the agent was dropped); a reload loads them.
		ufw reload >/dev/null
		log "ufw: agents ${agent_ips[*]} and the cluster CIDRs allowed"
	fi
	changed=''
	[ -z "$(kubelet_gc "$data_dir/agent/etc/kubelet.conf.d")" ] || changed="kubelet GC drop-in"
	reg=$(registries) || exit 1
	[ -z "$reg" ] || changed="${changed:+$changed and }registries.yaml"
	if [ -n "$changed" ]; then
		if $restart; then
			systemctl restart k3s && log "k3s restarted ($changed applied)"
		else
			log "$changed written; applied at the next k3s restart (or rerun with --restart)"
		fi
	fi
	;;
agent)
	[ -n "$server_ip" ] && [ -n "$node_ip" ] || die "agent needs --server-ip and --node-ip"
	[ -s "$token_file" ] || die "join token $token_file missing (see the header)"
	binfmt
	journald 500M
	install -d -m 0711 /var/lib/buildkit
	[ ${#labels[@]} -gt 0 ] || labels=(teknoir.org/ci-builder=true)
	[ ${#taints[@]} -gt 0 ] || taints=(teknoir.org/ci=true:NoSchedule)
	if ! $keep_docker && systemctl is-enabled -q docker.service 2>/dev/null; then
		systemctl disable docker.service docker.socket containerd.service >/dev/null 2>&1 || true
		log "docker disabled at boot"
	fi
	if $grow_root && command -v lvs >/dev/null && vg=$(vgs --noheadings -o vg_name 2>/dev/null | head -n1 | tr -d ' ') && [ -n "$vg" ]; then
		free=$(vgs --noheadings --units b -o vg_free "$vg" | tr -dc 0-9)
		root_lv=$(findmnt -n -o SOURCE /)
		if [ "${free:-0}" -gt 1073741824 ]; then lvextend -r -l +100%FREE "$root_lv" >/dev/null && log "root LV extended"; fi
	fi
	if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
		for src in "$server_ip" "${CLUSTER_CIDRS[@]}"; do ufw allow from "$src" comment k3s >/dev/null; done
		for c in "${CLUSTER_CIDRS[@]}"; do ufw route allow from "$c" >/dev/null; ufw route allow to "$c" >/dev/null; done
		ufw reload >/dev/null
		log "ufw: k3s server and cluster CIDRs allowed"
	fi
	write_if_changed /etc/rancher/k3s/config.yaml 0600 <<-EOF >/dev/null
		# k3s agent of the staging cluster (CI build node). See plans/ci-argo-workflows.md.
		server: https://${server_ip}:6443
		token-file: ${token_file}
		node-ip: ${node_ip}
		node-label:
		$(printf '  - %s\n' "${labels[@]}")
		node-taint:
		$(printf '  - %s\n' "${taints[@]}")
		kubelet-arg:
		  - container-log-max-size=10Mi
		  - container-log-max-files=3
	EOF
	gc_changed=$(kubelet_gc /var/lib/rancher/k3s/agent/etc/kubelet.conf.d)
	# registries.yaml before the installer, so a first start already uses it
	reg_changed=$(registries) || exit 1
	if ! systemctl is-active -q k3s-agent; then
		curl -sfL https://get.k3s.io -o /tmp/k3s-install.sh
		INSTALL_K3S_VERSION=$K3S_VERSION INSTALL_K3S_EXEC=agent sh /tmp/k3s-install.sh
		log "k3s agent $K3S_VERSION installed"
	elif [ -n "$gc_changed$reg_changed" ]; then
		systemctl restart k3s-agent && log "k3s-agent restarted (${gc_changed:+kubelet GC settings}${gc_changed:+${reg_changed:+ and }}${reg_changed:+registries.yaml} applied)"
	fi
	;;
*) die "usage: $0 server [--restart] [--agent-ip IP]... | agent --server-ip IP --node-ip IP [--token-file FILE] [--keep-docker] [--no-grow-root] [--label K=V]... [--taint K=V:EFFECT]... (both: [--registry-mirror HOST|none --registry-auth-file FILE])" ;;
esac
log "done ($role)"
