#!/usr/bin/env bash
# vm.sh — disposable airgapped k3s test node for the Teknoir airgap procedure.
#
# The VM sits on an isolated Linux bridge (tkvm0, 10.77.0.0/24) with NO NAT
# and NO forwarding: it can reach vpro (10.77.0.1) and the LAN namespace
# (airgap/test/vm/lan-netns.sh, 10.77.0.20) and nothing else, exactly like
# the real airgapped node.
#
# DESIGN D13: the VM uses the real env's domain (teknoir.airgapped) at
# VM_IP 10.77.0.10 (airgap/site/vmtest.env). Name resolution for that domain
# exists only inside the LAN network namespace (its own /etc/hosts); this
# script never touches vpro's /etc/hosts.
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
# Usage: vm.sh net-up|create|start|stop|destroy|ssh [cmd...]|status|key
#              |age-key [--check SITE]
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
MEM_MB="${VM_MEM_MB:-10240}"; CPUS="${VM_CPUS:-8}"; DISK_GB="${VM_DISK_GB:-120}"
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
  # Airgap: never forward or masquerade anything from or to the bridge.
  sudo iptables -C FORWARD -i "${BR}" -j DROP 2>/dev/null || sudo iptables -I FORWARD -i "${BR}" -j DROP
  sudo iptables -C FORWARD -o "${BR}" -j DROP 2>/dev/null || sudo iptables -I FORWARD -o "${BR}" -j DROP
  log "bridge ${BR} up; forwarding to/from it is dropped"
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
    if running; then kill "$(cat "${PIDF}")"; fi
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
  net-up) net_up ;; create) create ;; start) start ;; stop) stop ;; destroy) destroy ;;
  ssh) ssh_vm "$@" ;; status) status ;;
  key) printf '%s\n' "${KEY}" ;;
  age-key) age_key "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command ${cmd} (see --help)" ;;
esac
