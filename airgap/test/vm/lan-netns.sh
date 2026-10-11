#!/usr/bin/env bash
# lan-netns.sh — the "LAN host" of the VM e2e test: network namespace tklan.
#
# DESIGN D13 / I-16: the e2e test uses the real domain (teknoir.airgapped)
# without touching the rig host's /etc/hosts or any live env. The LAN host is
# a network namespace on the rig host (the dev host, teknoir.airgapped;
# earlier: vpro):
#   - netns tklan with a veth (tklan0, 10.77.0.20/24) whose peer (tklan-br) is
#     a port of the isolated bridge tkvm0 (created by vm.sh net-up);
#   - no default route: the namespace reaches 10.77.0.0/24 and nothing else;
#   - /etc/netns/tklan/hosts maps <domain> and <name>.<domain> for every
#     TEKNOIR_HOSTNAMES entry of the site file to NODE_IP (10.77.0.10);
#     `ip netns exec` bind-mounts it over /etc/hosts inside the namespace
#     only. /etc/netns/tklan/nsswitch.conf ("hosts: files") and an empty
#     resolv.conf keep the host's resolver (systemd-resolved) out of the LAN
#     view. The host's own name is the platform domain here (the dev host is
#     called teknoir.airgapped, 127.0.1.1 in ITS /etc/hosts and "myhostname"
#     in its nsswitch): the namespace hosts file therefore has NO 127.0.1.1
#     line for the host name, or the domain would resolve to loopback first.
#     `up` and `status` verify that every platform name resolves to NODE_IP
#     only, inside the namespace, and that the host's default namespace does
#     not map the domain to NODE_IP;
#   - one iptables FORWARD rule accepts bridged frames between ports of tkvm0
#     (br_netfilter passes bridged traffic through FORWARD, where vm.sh's
#     "-i tkvm0 -j DROP" would otherwise drop LAN<->VM traffic); routed
#     traffic out of the bridge stays dropped. The rule is kept as the first
#     rule of FORWARD, ahead of Docker's jumps and of vm.sh's DROP rules
#     (Docker re-inserts its own jumps at the top whenever the daemon starts).
# Nothing else in the host's default namespace changes: no route, no address,
# no /etc/hosts entry.
#
# Usage: lan-netns.sh up|down|status|hosts|exec [--root] [--] CMD...
#   up      create or repair everything (idempotent)
#   down    remove the namespace, the veth, /etc/netns/tklan and the rule (idempotent)
#   status  print the namespace state and a reachability check (read-only)
#   hosts   print the hosts file the namespace gets (no root needed)
#   exec    run CMD in the namespace as the invoking user with HOME=$LAN_HOME
#           (--root: as root, for setup steps such as adding a test route)
# Environment: LAN_NETNS (tklan), LAN_BRIDGE (tkvm0), LAN_IP (10.77.0.20),
#   LAN_SITE (airgap/site/vmtest.env), LAN_HOME (~/vmtest/lanhome).
set -euo pipefail
# iptables, ip and sysctl live in the sbin dirs, which not every shell has on PATH
PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${D}/../../.." && pwd)"
NS="${LAN_NETNS:-tklan}"
BR="${LAN_BRIDGE:-tkvm0}"
VETH_HOST="${NS}-br"
VETH_NS="${NS}0"
LAN_IP="${LAN_IP:-10.77.0.20}"
CIDR=24
SITE="${LAN_SITE:-${REPO}/airgap/site/vmtest.env}"
LAN_HOME="${LAN_HOME:-${HOME}/vmtest/lanhome}"
ETC="/etc/netns/${NS}"
RULE=(-i "${BR}" -o "${BR}" -m comment --comment "teknoir-lan-netns: bridged ${BR} port-to-port only" -j ACCEPT)

log() { printf '\033[1;36m[lan-netns]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[lan-netns] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=()
[[ "$(id -u)" == 0 ]] || SUDO=(sudo)
as_root() { "${SUDO[@]}" "$@"; }

ns_exists() { ip netns list | awk '{print $1}' | grep -qx -- "${NS}"; }

site_var() {
  # site_var <NAME> — read one variable from the site file in a subshell
  [[ -f "${SITE}" ]] || die "site file ${SITE} not found"
  # shellcheck disable=SC1090
  ( set +u; . "${SITE}"; eval "printf '%s' \"\${$1:-}\"" )
}

name_listed() {
  # name_listed <name> <space-separated names> — 0 when <name> is one of them
  local n
  for n in $2; do [[ "${n}" == "$1" ]] && return 0; done
  return 1
}

platform_names() {
  # platform_names — the domain and <name>.<domain> for every TEKNOIR_HOSTNAMES entry
  local domain h names
  domain="$(site_var TEKNOIR_DOMAIN)"
  [[ -n "${domain}" ]] || die "${SITE} must set TEKNOIR_DOMAIN"
  names="${domain}"
  for h in $(site_var TEKNOIR_HOSTNAMES); do names+=" ${h}.${domain}"; done
  printf '%s' "${names}"
}

hosts_content() {
  local domain node_ip names
  domain="$(site_var TEKNOIR_DOMAIN)"; node_ip="$(site_var NODE_IP)"
  [[ -n "${domain}" && -n "${node_ip}" ]] || die "${SITE} must set TEKNOIR_DOMAIN and NODE_IP"
  names="$(platform_names)"
  printf '127.0.0.1\tlocalhost\n'
  # The UTS namespace is shared with the host, so uname -n is the host's name,
  # which on the dev host IS the platform domain: never map it to loopback.
  if ! name_listed "$(uname -n)" "${names}"; then printf '127.0.1.1\t%s\n' "$(uname -n)"; fi
  printf '::1\tlocalhost ip6-localhost ip6-loopback\n'
  printf '# managed by airgap/test/vm/lan-netns.sh (site %s): the airgapped LAN view\n' "$(basename "${SITE}")"
  printf '%s\t%s\n' "${node_ip}" "${names}"
}

nsswitch_content() {
  # the host's nsswitch.conf with name resolution limited to the hosts file
  if [[ -f /etc/nsswitch.conf ]]; then
    sed -E 's/^hosts:.*/hosts:          files/' /etc/nsswitch.conf
  else
    printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files\n'
  fi
}

resolv_content() {
  printf '# no DNS in the airgapped LAN namespace (lan-netns.sh); names come from hosts\noptions timeout:1 attempts:1\n'
}

write_if_changed() {
  # write_if_changed <path> <mode> — stdin to <path> (root) only when it differs
  local dst="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  if ! as_root cmp -s "${tmp}" "${dst}" 2>/dev/null; then
    as_root install -D -m "${mode}" "${tmp}" "${dst}"
    log "wrote ${dst}"
  fi
  rm -f "${tmp}"
}

rule_first() {
  # true when the accept rule is the first rule of FORWARD
  [[ "$(as_root iptables -S FORWARD | awk '/^-A /{print; exit}')" == *"teknoir-lan-netns:"* ]]
}

verify_view() {
  # verify_view — the name view of the rig, both sides:
  #  - inside the namespace every platform name resolves to NODE_IP and
  #    nothing else (a name that resolved to the host would send a test to the
  #    dev host, whose own name is the platform domain);
  #  - the host's default namespace must not map them to NODE_IP (the rig
  #    never writes the host's /etc/hosts; a leftover entry is only warned).
  local node_ip n got bad=""
  node_ip="$(site_var NODE_IP)"
  for n in $(platform_names); do
    got="$(as_root ip netns exec "${NS}" getent ahostsv4 "${n}" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd' ')"
    [[ "${got}" == "${node_ip}" ]] || bad+=" ${n} -> [${got:-nothing}]"
  done
  [[ -z "${bad}" ]] || die "namespace ${NS}: platform names must resolve to ${node_ip} only, but:${bad} (see ${ETC}/hosts)"
  for n in $(platform_names); do
    if getent ahostsv4 "${n}" 2>/dev/null | awk '{print $1}' | grep -qx -- "${node_ip}"; then
      log "WARNING: the host itself resolves ${n} to ${node_ip} (a leftover /etc/hosts entry?); the rig does not need it"
    fi
  done
}

up() {
  [[ -d "/sys/class/net/${BR}" ]] || die "bridge ${BR} missing: run airgap/test/vm/vm.sh net-up first"
  if ! ns_exists; then as_root ip netns add "${NS}"; log "created netns ${NS}"; fi
  if ip link show "${VETH_HOST}" >/dev/null 2>&1 && ! as_root ip -n "${NS}" link show "${VETH_NS}" >/dev/null 2>&1; then
    as_root ip link del "${VETH_HOST}"   # orphaned host end (its namespace was re-created)
  fi
  if ! ip link show "${VETH_HOST}" >/dev/null 2>&1; then
    as_root ip link add "${VETH_HOST}" type veth peer name "${VETH_NS}" netns "${NS}"
    log "created veth ${VETH_HOST} <-> ${NS}/${VETH_NS}"
  fi
  # a bridge port needs no address of its own (no IPv6 link-local in the host's namespace)
  as_root sh -c "echo 1 > /proc/sys/net/ipv6/conf/${VETH_HOST}/disable_ipv6"
  as_root ip link set "${VETH_HOST}" master "${BR}" up
  as_root ip -n "${NS}" link set lo up
  as_root ip -n "${NS}" link set "${VETH_NS}" up
  if ! as_root ip -n "${NS}" -4 addr show dev "${VETH_NS}" | grep -q "inet ${LAN_IP}/${CIDR} "; then
    as_root ip -n "${NS}" addr flush dev "${VETH_NS}"
    as_root ip -n "${NS}" addr add "${LAN_IP}/${CIDR}" dev "${VETH_NS}"
  fi
  while [[ -n "$(as_root ip -n "${NS}" route show default)" ]]; do as_root ip -n "${NS}" route del default; done
  as_root ip netns exec "${NS}" sh -c 'echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6'
  hosts_content | write_if_changed "${ETC}/hosts" 0644
  nsswitch_content | write_if_changed "${ETC}/nsswitch.conf" 0644
  resolv_content | write_if_changed "${ETC}/resolv.conf" 0644
  if ! rule_first; then
    while as_root iptables -C FORWARD "${RULE[@]}" 2>/dev/null; do as_root iptables -D FORWARD "${RULE[@]}"; done
    as_root iptables -I FORWARD 1 "${RULE[@]}"
    log "FORWARD: accept bridged ${BR} port-to-port traffic (rule 1)"
  fi
  install -d -m 0700 "${LAN_HOME}"
  verify_view
  log "netns ${NS} up: ${LAN_IP}/${CIDR} on ${BR}, no default route, hosts -> $(site_var NODE_IP)"
}

down() {
  if ns_exists; then as_root ip netns del "${NS}"; log "deleted netns ${NS}"; fi
  # deleting the namespace removes the veth pair asynchronously: the host end
  # may vanish between the check and the delete
  if ip link show "${VETH_HOST}" >/dev/null 2>&1; then as_root ip link del "${VETH_HOST}" 2>/dev/null || true; fi
  if [[ -d "${ETC}" ]]; then as_root rm -rf "${ETC}"; log "removed ${ETC}"; fi
  if [[ -d /etc/netns ]]; then as_root rmdir --ignore-fail-on-non-empty /etc/netns; fi
  while as_root iptables -C FORWARD "${RULE[@]}" 2>/dev/null; do as_root iptables -D FORWARD "${RULE[@]}"; log "removed the FORWARD accept rule"; done
  log "netns ${NS} down"
}

status() {
  if ! ns_exists; then log "netns ${NS} absent"; return 0; fi
  log "netns ${NS}:"
  as_root ip -n "${NS}" -br addr
  printf 'routes:\n'; as_root ip -n "${NS}" route
  printf 'default route: %s\n' "$(as_root ip -n "${NS}" route show default | grep -q . && echo PRESENT || echo none)"
  printf 'hosts (%s):\n' "${ETC}/hosts"; as_root cat "${ETC}/hosts" 2>/dev/null || echo "  missing"
  printf 'FORWARD rule first: %s\n' "$(rule_first && echo yes || echo no)"
  ( verify_view ) && printf 'name view: platform names -> %s only, inside the namespace\n' "$(site_var NODE_IP)" || printf 'name view: WRONG (see above)\n'
  local ip; ip="$(site_var NODE_IP)"
  if as_root ip netns exec "${NS}" ping -c1 -W2 "${ip}" >/dev/null 2>&1; then
    printf 'node %s: reachable\n' "${ip}"
  else
    printf 'node %s: unreachable (is the VM running?)\n' "${ip}"
  fi
}

exec_in() {
  local root=0
  [[ "${1:-}" == --root ]] && { root=1; shift; }
  [[ "${1:-}" == -- ]] && shift
  (( $# )) || die "exec: no command"
  ns_exists || die "netns ${NS} absent: run lan-netns.sh up"
  if (( root )); then
    exec "${SUDO[@]}" ip netns exec "${NS}" "$@"
  fi
  # SSH_AUTH_SOCK is a filesystem socket, so an agent works across the netns
  # boundary (OpenSSH reads ~/.ssh from the passwd home, not from $HOME).
  exec "${SUDO[@]}" ip netns exec "${NS}" sudo -u "$(id -un)" -- env HOME="${LAN_HOME}" PATH="${PATH}" \
    LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"} "$@"
}

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

cmd="${1:-status}"; shift || true
case "${cmd}" in
  up) up ;;
  down) down ;;
  status) status ;;
  hosts) hosts_content ;;
  exec) exec_in "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command ${cmd} (see --help)" ;;
esac
