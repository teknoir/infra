#!/usr/bin/env bash
# vm.sh — disposable airgapped k3s test node for the Teknoir airgap procedure.
#
# The VM sits on an isolated Linux bridge (tkvm0, 10.77.0.0/24) with NO NAT
# and NO forwarding: it can reach the LAN namespace (airgap/test/vm/
# lan-netns.sh, 10.77.0.20) and, by ping only, the rig host's bridge address
# (10.77.0.1); no service of the host answers it and nothing is forwarded
# (the airgapped node never sees the internet either).
#
# The rig host is the dev host (hostname teknoir.airgapped, Debian 13, Docker,
# k3d); it was vpro before 2026-10-11. Docker keeps FORWARD's policy at DROP
# and puts its own jumps at the top of the chain whenever its daemon starts,
# so net-up keeps the DROP rules ahead of them (lan-netns.sh up then restores
# its accept rule ahead of the DROPs; e2e.sh does both on every start).
#
# DESIGN D13: the VM uses the real env's domain (teknoir.airgapped) at
# VM_IP 10.77.0.10 (airgap/site/vmtest.env). Name resolution for that domain
# exists only inside the LAN network namespace (its own /etc/hosts); this
# script never touches the host's /etc/hosts. The host's OWN name is
# teknoir.airgapped too (127.0.1.1), so nothing on the host may be used to
# test the platform: every test goes through `lan-netns.sh exec`.
#
# RAM: the VM takes VM_MEM_MB (default 10240) of the host's RAM; `start`
# refuses to boot it when MemAvailable is less than VM_MEM_MB plus
# VM_RAM_HEADROOM_MB (default 2048) instead of letting the kernel OOM-kill
# something (stop the k3d suites and other Docker workloads first: the VM and
# the k3d suites do not run at the same time). VM_SKIP_RAM_CHECK=1 skips it.
#
# VM state (disk overlay, cloud-init seed, ssh key, pid, console log) lives in
# VM_DIR (default ~/vmtest), never in the repo. The Debian 13 genericcloud
# base image is expected at $VM_DIR/images/debian-13-genericcloud-amd64.qcow2.
# The network stays static (cloud-init network-config, VM_IP/24, no DHCP on
# tkvm0).
#
# Test age identities (`age-key`): the VM site (airgap/site/vmtest.env)
# encrypts every node backup to two test recipients, BACKUP_AGE_RECIPIENTS.
# Their identities are VM_DIR/age/vmtest.key and vmtest-recovery.key (0600,
# made with age-keygen when missing; AGE_KEYGEN overrides the binary). They
# never go into the repo or onto the VM; e2e.sh E13 decrypts the LAN backup
# with each. `age-key --check SITE` exits 1 unless the site's recipients are
# exactly these two (after a new VM_DIR: put the printed recipients into
# vmtest.env).
#
# Usage: vm.sh net-up|net-down|create|start|stop|destroy|ssh [cmd...]|status|key
#              |age-key [--check SITE]|ram-check
#   net-down  remove the bridge, the tap and the firewall rules (the VM must
#             be stopped; run lan-netns.sh down first)
#   ram-check exit 1 unless the host has the RAM for the VM
# Every subcommand is idempotent. Requires: sudo, qemu-system-x86_64,
# qemu-img, cloud-localds, membership of group kvm (used through `sg kvm`);
# age-keygen for age-key.
set -euo pipefail
# iptables, ip and sysctl live in the sbin dirs, which not every shell has on PATH
PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

VM_DIR="${VM_DIR:-${HOME}/vmtest}"
NAME="${VM_NAME:-tk-airgap}"
BR=tkvm0; TAP=tktap0
HOST_IP=10.77.0.1; VM_IP="${VM_IP:-10.77.0.10}"; CIDR=24
MEM_MB="${VM_MEM_MB:-10240}"; RAM_HEADROOM_MB="${VM_RAM_HEADROOM_MB:-2048}"; CPUS="${VM_CPUS:-8}"; DISK_GB="${VM_DISK_GB:-120}"
DOMAIN="${VM_DOMAIN:-teknoir.airgapped}"
BASE="${VM_DIR}/images/debian-13-genericcloud-amd64.qcow2"
DISK="${VM_DIR}/${NAME}.qcow2"; SEED="${VM_DIR}/${NAME}-seed.iso"; PIDF="${VM_DIR}/${NAME}.pid"
CONSOLE="${VM_DIR}/${NAME}.console.log"
KEY="${VM_DIR}/id_ed25519"
AGE_DIR="${VM_DIR}/age"
AGE_IDS=(vmtest vmtest-recovery)

log() { printf '\033[1;35m[vm]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[vm] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ssh_vm() {
  # Harness access with the VM's own key. The host key is not pinned: the VM
  # is re-created often (the LAN entrypoint pins it in its own known_hosts).
  ssh -i "${KEY}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes "teknoir@${VM_IP}" "$@"
}

ipt() { sudo iptables "$@"; }

forward_ours_on_top() {
  # forward_ours_on_top — 0 when both bridge DROP rules sit ahead of every
  # foreign rule of FORWARD (lan-netns.sh's accept rule is ours as well).
  # Docker (re-)inserts DOCKER-USER/DOCKER-FORWARD jumps at the top when its
  # daemon starts; a published port or a container network behind them could
  # otherwise accept traffic that comes in on the bridge.
  ipt -S FORWARD | awk -v i="-A FORWARD -i ${BR} -j DROP" -v o="-A FORWARD -o ${BR} -j DROP" '
    /^-A / { if (stop) next
             if ($0 ~ /teknoir-lan-netns:/) next
             if ($0 == i || $0 == o) { d++; next }
             stop = 1 }
    END { exit (d == 2 ? 0 : 1) }'
}

net_up() {
  if ! ip link show "${BR}" >/dev/null 2>&1; then
    log "creating isolated bridge ${BR} (${HOST_IP}/${CIDR}, no NAT)"
    sudo ip link add "${BR}" type bridge
    sudo ip addr add "${HOST_IP}/${CIDR}" dev "${BR}"
    sudo ip link set "${BR}" up
  fi
  if ! ip link show "${TAP}" >/dev/null 2>&1; then
    sudo ip tuntap add dev "${TAP}" mode tap user "$(id -un)"
    sudo ip link set "${TAP}" master "${BR}" up
  fi
  # IPv4 only: no IPv6 link-local on the bridge or the tap
  sudo sysctl -q -w "net.ipv6.conf.${BR}.disable_ipv6=1" "net.ipv6.conf.${TAP}.disable_ipv6=1" >/dev/null
  # Airgap: never forward or masquerade anything from or to the bridge.
  if ! ipt -C FORWARD -i "${BR}" -j DROP 2>/dev/null || ! ipt -C FORWARD -o "${BR}" -j DROP 2>/dev/null || ! forward_ours_on_top; then
    while ipt -D FORWARD -i "${BR}" -j DROP 2>/dev/null; do :; done
    while ipt -D FORWARD -o "${BR}" -j DROP 2>/dev/null; do :; done
    ipt -I FORWARD 1 -o "${BR}" -j DROP
    ipt -I FORWARD 1 -i "${BR}" -j DROP
    log "FORWARD: DROP rules for ${BR} are at the top (run lan-netns.sh up to restore the LAN accept rule)"
  fi
  # The host is not part of the airgapped LAN: the VM may ping the bridge
  # address (routing tests, diagnostics) but reaches no host service.
  # The replies to what the host itself starts (vm.sh ssh, ping) come back
  # on the bridge and must pass: accept only ESTABLISHED,RELATED, never NEW.
  ipt -C INPUT -i "${BR}" -j DROP 2>/dev/null || ipt -I INPUT 1 -i "${BR}" -j DROP
  ipt -C INPUT -i "${BR}" -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null \
    || ipt -I INPUT 1 -i "${BR}" -p icmp --icmp-type echo-request -j ACCEPT
  ipt -C INPUT -i "${BR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
    || ipt -I INPUT 1 -i "${BR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  log "bridge ${BR} up; forwarding to/from it is dropped, the host answers ping only"
}

net_down() {
  running && die "the VM is running: vm.sh stop first"
  while ipt -D FORWARD -i "${BR}" -j DROP 2>/dev/null; do :; done
  while ipt -D FORWARD -o "${BR}" -j DROP 2>/dev/null; do :; done
  while ipt -D INPUT -i "${BR}" -j DROP 2>/dev/null; do :; done
  while ipt -D INPUT -i "${BR}" -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do :; done
  while ipt -D INPUT -i "${BR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
  if ip link show "${TAP}" >/dev/null 2>&1; then sudo ip link del "${TAP}"; fi
  if ip link show "${BR}" >/dev/null 2>&1; then sudo ip link del "${BR}"; fi
  log "bridge ${BR}, tap ${TAP} and their firewall rules removed"
}

ram_check() {
  # ram_check — fail clearly when the host cannot hold the VM
  local avail need
  [[ "${VM_SKIP_RAM_CHECK:-0}" == 1 ]] && return 0
  avail="$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)"
  need=$(( MEM_MB + RAM_HEADROOM_MB ))
  if (( avail < need )); then
    die "not enough free RAM for the VM: MemAvailable ${avail} MiB < ${need} MiB (VM_MEM_MB ${MEM_MB} + headroom ${RAM_HEADROOM_MB}). Stop k3d clusters or Docker workloads (the VM and the k3d suites do not run at the same time), or lower VM_MEM_MB only if the scenarios allow it (E15 needs 10240); VM_SKIP_RAM_CHECK=1 overrides"
  fi
  log "RAM ok: MemAvailable ${avail} MiB >= ${need} MiB"
}

create() {
  [[ -f "${BASE}" ]] || die "missing base image ${BASE}"
  mkdir -p "${VM_DIR}"
  [[ -f "${KEY}" ]] || ssh-keygen -q -t ed25519 -N '' -C "vmtest" -f "${KEY}"
  if [[ ! -f "${DISK}" ]]; then
    log "creating ${DISK} (${DISK_GB}G overlay on the Debian 13 cloud image)"
    qemu-img create -q -f qcow2 -F qcow2 -b "${BASE}" "${DISK}" "${DISK_GB}G"
  fi
  local w; w="$(mktemp -d)"
  cat > "${w}/user-data" <<EOF
#cloud-config
hostname: ${DOMAIN}
fqdn: ${DOMAIN}
manage_etc_hosts: false
users:
  - name: teknoir
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat "${KEY}.pub")
ssh_pwauth: false
timezone: UTC
EOF
  cat > "${w}/network-config" <<EOF
version: 2
ethernets:
  nic0:
    match: {name: "e*"}
    addresses: [${VM_IP}/${CIDR}]
EOF
  printf 'instance-id: %s\nlocal-hostname: %s\n' "${NAME}" "${DOMAIN}" > "${w}/meta-data"
  cloud-localds --network-config "${w}/network-config" "${SEED}" "${w}/user-data" "${w}/meta-data"
  rm -rf "${w}"
  log "seed ${SEED} ready (hostname ${DOMAIN}, ${VM_IP})"
}

running() { [[ -f "${PIDF}" ]] && kill -0 "$(cat "${PIDF}")" 2>/dev/null; }

start() {
  net_up
  [[ -f "${DISK}" && -f "${SEED}" ]] || create
  if running; then log "already running (pid $(cat "${PIDF}"))"; else
    [[ -r /dev/kvm ]] || sg kvm -c 'test -r /dev/kvm' 2>/dev/null || die "/dev/kvm is not usable (is $(id -un) in group kvm?)"
    ram_check
    log "starting ${NAME}: ${CPUS} vCPU, ${MEM_MB} MiB"
    sg kvm -c "qemu-system-x86_64 -name ${NAME} -machine q35,accel=kvm -cpu host -smp ${CPUS} -m ${MEM_MB} \
      -drive file=${DISK},if=virtio,cache=none,discard=unmap \
      -drive file=${SEED},if=virtio,format=raw,readonly=on \
      -netdev tap,id=n0,ifname=${TAP},script=no,downscript=no -device virtio-net-pci,netdev=n0,mac=52:54:00:77:00:10 \
      -display none -serial file:${CONSOLE} -daemonize -pidfile ${PIDF}"
  fi
  log "waiting for ssh on ${VM_IP} ..."
  local _; for _ in $(seq 1 90); do ssh_vm true 2>/dev/null && { log "ssh ready"; return 0; }; sleep 2; done
  die "VM did not come up (see ${CONSOLE})"
}

stop() {
  if running; then
    ssh_vm 'sudo poweroff' 2>/dev/null || true
    local _; for _ in $(seq 1 30); do running || break; sleep 2; done
    if running; then
      local pid; pid="$(cat "${PIDF}")"
      kill "${pid}"
      # qemu holds the tap until it has exited: a start right after must not race it
      for _ in $(seq 1 20); do kill -0 "${pid}" 2>/dev/null || break; sleep 1; done
      if kill -0 "${pid}" 2>/dev/null; then kill -9 "${pid}" 2>/dev/null || true; fi
    fi
  fi
  rm -f "${PIDF}"; log "stopped"
}

destroy() { stop; rm -f "${DISK}" "${SEED}" "${CONSOLE}"; log "destroyed ${NAME} disk + seed"; }

status() {
  if running; then log "running (pid $(cat "${PIDF}")), ${DOMAIN} at ${VM_IP}"; else log "not running"; fi
  ssh_vm 'hostname; uptime; free -g | head -2; df -h / | tail -1; (curl -s -m 5 -o /dev/null -w "internet: %{http_code}\n" https://deb.debian.org || echo "internet: unreachable (expected)")' 2>/dev/null || true
}

site_recipients() {
  # site_recipients <site> — BACKUP_AGE_RECIPIENTS of a site file, one per line
  # (read in a subshell; the site file is plain KEY=value)
  # shellcheck disable=SC1090,SC2086  # the value is a space-separated list
  ( set +u -f; . "$1"; printf '%s\n' ${BACKUP_AGE_RECIPIENTS:-} )
}

age_key() {
  # age_key [--check SITE] — ensure the test identities, print
  # "<recipient> <identity file>" per key; with --check, compare with SITE
  local site="" keygen id f pub out=""
  case "${1:-}" in
    --check) site="${2:-}"; [[ -f "${site}" ]] || die "age-key --check needs a site file" ;;
    "") ;;
    *) die "age-key: unknown argument $1" ;;
  esac
  keygen="${AGE_KEYGEN:-$(command -v age-keygen || true)}"
  [[ -n "${keygen}" && -x "${keygen}" ]] || die "age-keygen not found (install-devtools.sh installs it; or set AGE_KEYGEN)"
  install -d -m 0700 "${AGE_DIR}"
  for id in "${AGE_IDS[@]}"; do
    f="${AGE_DIR}/${id}.key"
    if [[ ! -s "${f}" ]]; then
      ( umask 077; "${keygen}" -o "${f}" 2>/dev/null ) || die "age-keygen failed for ${f}"
      log "created test age identity ${f}"
    fi
    chmod 600 "${f}"
    pub="$("${keygen}" -y "${f}")" || die "cannot read the recipient of ${f}"
    [[ "${pub}" =~ ^age1[0-9a-z]{58}$ ]] || die "${f}: unexpected recipient format"
    out+="${pub} ${f}"$'\n'
  done
  printf '%s' "${out}"
  if [[ -n "${site}" ]]; then
    if [[ "$(site_recipients "${site}" | sort)" != "$(awk 'NF {print $1}' <<<"${out}" | sort)" ]]; then
      die "${site}: BACKUP_AGE_RECIPIENTS are not the recipients of ${AGE_DIR}/{$(IFS=,; echo "${AGE_IDS[*]}")}.key (put the recipients above into it)"
    fi
    log "${site}: BACKUP_AGE_RECIPIENTS match the test identities in ${AGE_DIR}"
  fi
}

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

cmd="${1:-status}"; shift || true
case "${cmd}" in
  net-up) net_up ;; net-down) net_down ;; ram-check) ram_check ;; create) create ;; start) start ;; stop) stop ;; destroy) destroy ;;
  ssh) ssh_vm "$@" ;; status) status ;;
  key) printf '%s\n' "${KEY}" ;;
  age-key) age_key "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command ${cmd} (see --help)" ;;
esac
