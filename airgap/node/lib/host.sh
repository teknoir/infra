# shellcheck shell=bash
# host.sh: the node OS phase of teknoir-node converge (DESIGN I-06).
#
# Every file is written only when its content differs. k3s is installed or
# upgraded from node/k3s (INSTALL_K3S_SKIP_DOWNLOAD, binary sha256-checked)
# when the installed binary differs, and otherwise restarted only when
# config.yaml, registries.yaml or the registry CA differ from
# /var/lib/teknoir-airgap/restart.stamp, which is written after a successful
# (re)start. A run that dies before its restart therefore restarts on the
# next run. Bootstrap image tarballs are synced into <data-dir>/agent/images
# (stale ones pruned) and any image missing from containerd is imported with
# `k3s ctr` - no restart needed for that.
#
# Time (DESIGN D6, r5): the bundle's node packages (node/debs: chrony and
# util-linux-extra for hwclock) are installed offline when missing; chrony
# serves NTP to the LAN from a local stratum-10 reference that every up
# corrects with a LAN-host sample (or from TIME_SOURCE); the RTC is written
# when it is more than CLOCK_OK_SKEW seconds off, so a reboot starts right.
#
# Inotify limits (r5): Debian keeps fs.inotify.max_user_instances=128, and with
# the teamspace pods' istio-proxy sidecars Envoy aborts ("inotify_fd_ >= 0 ...
# Consider increasing fs.inotify.max_user_instances"). The host phase manages
# /etc/sysctl.d/teknoir.inotify.conf (the name of the hand-made file on the
# live node, which it adopts) before k3s starts, and applies it without reboot.
#
# k3s subcommands that take --data-dir get it explicitly (secrets-encrypt,
# etcd-snapshot, ...); ctr/kubectl/crictl find it through config.yaml.
# Role: only "server" is implemented (D11); "agent" is refused in preflight.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
source "${NODE_ROOT}/lib/common.sh"

K3S_CONFIG_DIR="${HOST_ROOT}/etc/rancher/k3s"
K3S_CONFIG_FILE="${K3S_CONFIG_DIR}/config.yaml"
K3S_RESOLV_FILE="${K3S_CONFIG_DIR}/resolv.conf"
RESOLVED_DROPIN="${HOST_ROOT}/etc/systemd/resolved.conf.d/teknoir-airgap.conf"
K3S_REGISTRIES_FILE="${K3S_CONFIG_DIR}/registries.yaml"
# The registry CA as k3s/containerd see it (registries.yaml ca_file).
K3S_CA_FILE="${HOST_ROOT}/etc/rancher/k3s/teknoir-root-ca.crt"
OS_CA_FILE="${HOST_ROOT}/usr/local/share/ca-certificates/teknoir-root-ca.crt"
K3S_UNIT_FILE="${HOST_ROOT}/etc/systemd/system/k3s.service"
HOSTS_FILE="${HOST_ROOT}/etc/hosts"
SYSCTL_INOTIFY_CONF="${HOST_ROOT}/etc/sysctl.d/teknoir.inotify.conf"
INOTIFY_PROC_DIR="${HOST_ROOT}/proc/sys/fs/inotify"
# the limits teknoir-node manages (name value), in file order
INOTIFY_LIMITS=("max_user_instances 1024" "max_user_watches 524288")
CHRONY_CONF_DIR="${HOST_ROOT}/etc/chrony/conf.d"
CHRONY_CONF="${CHRONY_CONF_DIR}/teknoir-airgap.conf"
RESTART_STAMP="${STATE_DIR}/restart.stamp"
K3S_IMPORT_WAIT="${K3S_IMPORT_WAIT:-600}"
K3S_READY_TIMEOUT="${K3S_READY_TIMEOUT:-300}"
K3S_SETTLE_TIMEOUT="${K3S_SETTLE_TIMEOUT:-600}"
K3S_SETTLE_DELAY="${K3S_SETTLE_DELAY:-15}"
K3S_SETTLE_INTERVAL="${K3S_SETTLE_INTERVAL:-10}"
# the namespaces whose pods must be Ready again after a k3s restart
K3S_SETTLE_NAMESPACES="${K3S_SETTLE_NAMESPACES:-kube-system istio-system cert-manager teknoir-system teknoir-auth}"
HOSTS_BEGIN="# BEGIN teknoir-airgap"
HOSTS_END="# END teknoir-airgap"
# Image tarball suffixes k3s imports from agent/images (prune candidates).
TARBALL_RE='\.(tar|tar\.zst|tar\.gz|tgz|tar\.lz4|tar\.bz2|tzst)$'

# Set by phase_host for the restart decision.
HOST_FILES_CHANGED=0
HOST_RESOLV_CHANGED=0
RESOLV_LINE=""
K3S_JUST_STARTED=0
declare -A _BUNDLE_SUMS=()

host_k3s_data_path() { printf '%s%s%s' "${HOST_ROOT}" "${K3S_DATA_DIR}" "${1:-}"; }
host_k3s_images_dir() { host_k3s_data_path /agent/images; }

host_k3s_datastore_exists() {
  # sqlite (state.db) or embedded etcd (db/etcd/member; db/etcd alone exists on sqlite too)
  [[ -e "$(host_k3s_data_path /server/db/state.db)" || -d "$(host_k3s_data_path /server/db/etcd/member)" ]]
}

host_bundle_sha() {
  # host_bundle_sha <path relative to node/> - the sha256 recorded in
  # node/SHA256SUMS (verified by the verify phase), else computed.
  local rel="$1" line p
  if (( ${#_BUNDLE_SUMS[@]} == 0 )) && [[ -f "${NODE_ROOT}/SHA256SUMS" ]]; then
    while IFS= read -r line; do
      p="${line:66}"
      p="${p#./}"
      _BUNDLE_SUMS["${p}"]="${line:0:64}"
    done < "${NODE_ROOT}/SHA256SUMS"
  fi
  if [[ -n "${_BUNDLE_SUMS[${rel}]+x}" ]]; then
    printf '%s' "${_BUNDLE_SUMS[${rel}]}"
  else
    sha256_file "${NODE_ROOT}/${rel}"
  fi
}

host_check_k3s_payload() {
  # The k3s binary and airgap images must match the upstream checksum file.
  local sums="${NODE_ROOT}/k3s/sha256sum-amd64.txt" f want got
  [[ -f "${sums}" ]] || die "missing ${sums}"
  for f in k3s k3s-airgap-images-amd64.tar.zst; do
    [[ -f "${NODE_ROOT}/k3s/${f}" ]] || die "missing ${NODE_ROOT}/k3s/${f}"
    want="$(awk -v f="${f}" '$2 == f || $2 == "*" f {print $1; exit}' "${sums}")"
    [[ -n "${want}" ]] || die "${sums} has no checksum for ${f}"
    got="$(host_bundle_sha "k3s/${f}")"
    [[ "${want}" == "${got}" ]] || die "k3s/${f} does not match the upstream ${sums}"
  done
  [[ -f "${NODE_ROOT}/k3s/install.sh" ]] || die "missing ${NODE_ROOT}/k3s/install.sh"
}

# ---------------------------------------------------------------------------
# Rendered node files
# ---------------------------------------------------------------------------
host_secrets_encryption_line() {
  # secrets-encryption only for NEW installs (D6). An existing cluster keeps
  # what it has; enabling it there is an explicit later step (I-17).
  if ! host_k3s_datastore_exists \
     || [[ -f "$(host_k3s_data_path /server/cred/encryption-config.json)" ]] \
     || grep -qE '^secrets-encryption:[[:space:]]*"?true"?[[:space:]]*$' "${K3S_CONFIG_FILE}" 2>/dev/null; then
    printf 'secrets-encryption: true'
  fi
}

host_flannel_iface_line() {
  # flannel picks the interface of the default route, and an airgapped node
  # may have none ("flannel exited: failed to get default interface", k3s then
  # restarts forever). Pin it to the interface that holds NODE_IP.
  local iface
  iface="$(ip -o -4 addr show 2>/dev/null | awk -v ip="${NODE_IP}" '{ split($4, a, "/"); if (a[1] == ip) { print $2; exit } }')"
  if [[ -z "${iface}" ]]; then
    # preflight already refuses a NODE_IP that is not local on a real node
    warn "no local interface holds NODE_IP ${NODE_IP}: flannel keeps its default-route choice"
    return 0
  fi
  printf 'flannel-iface: %s' "${iface}"
}

host_system_dns() {
  # host_system_dns - the node's non-loopback nameservers (what k3s itself
  # would find in /etc/resolv.conf or systemd-resolved's resolv.conf)
  awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ { print $2 }' \
    "${HOST_ROOT}/etc/resolv.conf" "${HOST_ROOT}/run/systemd/resolve/resolv.conf" 2>/dev/null | awk '!seen[$0]++'
}

host_resolved_stub() {
  # host_resolved_stub on|off - expose systemd-resolved's stub on NODE_IP (or
  # stop doing so). With no upstream it answers at once: names from the node's
  # /etc/hosts (the managed teknoir block) and NXDOMAIN/SERVFAIL for the rest.
  local want="$1" d
  d="$(dirname "${RESOLVED_DROPIN}")"
  if [[ "${want}" == on ]]; then
    ensure_work_dir
    printf '# written by teknoir-node (host phase): resolved stub on NODE_IP for CoreDNS\n[Resolve]\nDNSStubListenerExtra=%s\n' \
      "${NODE_IP}" > "${WORK_DIR}/resolved-teknoir.conf"
    ensure_dir "${d}" 0755
    install_file "${WORK_DIR}/resolved-teknoir.conf" "${RESOLVED_DROPIN}" 0644 "systemd-resolved stub on ${NODE_IP}"
  elif [[ -f "${RESOLVED_DROPIN}" ]]; then
    run rm -f "${RESOLVED_DROPIN}"
    changed "removed ${RESOLVED_DROPIN} (an upstream resolver is configured now)"
    FILE_CHANGED=1
  else
    FILE_CHANGED=0
  fi
  if (( FILE_CHANGED )) && ! dry_run; then
    systemctl restart systemd-resolved || die "cannot restart systemd-resolved"
  fi
}

host_resolv_conf_prepare() {
  # CoreDNS forwards unknown names to the resolvers k3s finds on the node. With
  # only a loopback stub and no upstream (a true air gap), k3s falls back to
  # 8.8.8.8 and every lookup it cannot answer locally waits for a timeout
  # (VM e2e: ArgoCD repo-server's self health check took 2 s, gRPC's
  # _grpclb SRV lookups, and the pod was restarted over and over). So:
  #   UPSTREAM_DNS in the site config  -> CoreDNS uses those servers;
  #   a non-loopback upstream on the node -> nothing changes (k3s default);
  #   no upstream at all -> systemd-resolved's stub, exposed on NODE_IP, which
  #   answers at once (a closed port is not enough: the kernel rate-limits the
  #   ICMP port-unreachable replies, so bursts of lookups still time out).
  # Runs in the main shell (not in $(...)), so the resolved drop-in, its
  # restart and the change records are kept; sets RESOLV_LINE for config.yaml.
  local servers="" s
  RESOLV_LINE=""
  if [[ -n "${UPSTREAM_DNS:-}" ]]; then
    servers="${UPSTREAM_DNS}"
    host_resolved_stub off
  elif [[ -n "$(host_system_dns)" ]]; then
    host_resolved_stub off
    return 0
  else
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      host_resolved_stub on
    else
      warn "no upstream DNS and no systemd-resolved: names CoreDNS cannot answer will time out; set UPSTREAM_DNS in the site config"
    fi
    servers="${NODE_IP}"
  fi
  ensure_work_dir
  {
    echo "# written by teknoir-node (host phase): CoreDNS upstream for k3s (resolv-conf)"
    for s in ${servers}; do echo "nameserver ${s}"; done
  } > "${WORK_DIR}/k3s-resolv.conf"
  RESOLV_LINE="resolv-conf: ${K3S_RESOLV_FILE#"${HOST_ROOT}"}"
}

host_node_files() {
  ensure_work_dir
  local cfg="${WORK_DIR}/config.yaml" reg="${WORK_DIR}/registries.yaml"
  host_resolv_conf_prepare
  if [[ -n "${RESOLV_LINE}" ]]; then
    ensure_dir "${K3S_CONFIG_DIR}" 0755
    install_file "${WORK_DIR}/k3s-resolv.conf" "${K3S_RESOLV_FILE}" 0644 "k3s CoreDNS upstream"
    if (( FILE_CHANGED )); then HOST_FILES_CHANGED=1; HOST_RESOLV_CHANGED=1; fi
  fi
  render_template "${NODE_ROOT}/templates/config.yaml.tmpl" \
    "SECRETS_ENCRYPTION=$(host_secrets_encryption_line)" \
    "FLANNEL_IFACE=$(host_flannel_iface_line)" "RESOLV_CONF=${RESOLV_LINE}" > "${cfg}"
  render_template "${NODE_ROOT}/templates/registries.yaml.tmpl" > "${reg}"
  ensure_dir "${K3S_CONFIG_DIR}" 0755
  install_file "${cfg}" "${K3S_CONFIG_FILE}" 0600 "k3s config"
  (( FILE_CHANGED )) && HOST_FILES_CHANGED=1
  install_file "${reg}" "${K3S_REGISTRIES_FILE}" 0600 "k3s registry mirrors -> ${HARBOR_HOST}"
  (( FILE_CHANGED )) && HOST_FILES_CHANGED=1
  return 0
}

host_hosts_block() {
  # Managed block: every Teknoir name -> NODE_IP. Replaces any older
  # "# BEGIN teknoir-airgap ..." block in place of being appended twice.
  ensure_work_dir
  local want="${WORK_DIR}/hosts" block
  block="${HOSTS_BEGIN} (managed by teknoir-node)"$'\n'"${NODE_IP} $(teknoir_fqdns)"$'\n'"${HOSTS_END}"
  # The block replaces the first old one in place (other lines keep their
  # order); without one it is appended.
  if [[ -f "${HOSTS_FILE}" ]]; then
    BLOCK="${block}" awk -v b="${HOSTS_BEGIN}" -v e="${HOSTS_END}" '
      index($0, b) == 1 { if (!done) print ENVIRON["BLOCK"]; done = 1; skip = 1; next }
      skip && index($0, e) == 1 { skip = 0; next }
      !skip { print }
      END { if (!done) print ENVIRON["BLOCK"] }' "${HOSTS_FILE}" > "${want}"
  else
    printf '%s\n' "${block}" > "${want}"
  fi
  if [[ -f "${HOSTS_FILE}" ]] && cmp -s "${want}" "${HOSTS_FILE}"; then
    return 0
  fi
  if dry_run; then
    changed "write the managed block in ${HOSTS_FILE}: ${NODE_IP} $(teknoir_fqdns)"
    return 0
  fi
  # Rewrite in place (keeps the inode: /etc/hosts may be a bind mount).
  cat "${want}" > "${HOSTS_FILE}" || die "cannot write ${HOSTS_FILE}"
  changed "managed block in ${HOSTS_FILE}: ${NODE_IP} $(teknoir_fqdns)"
}

host_sysctl_bin() {
  # host_sysctl_bin - sysctl: $SYSCTL, else on PATH, else in sbin (the
  # converge PATH may lack it). Empty when the node has none.
  local c
  for c in "${SYSCTL:-}" "$(command -v sysctl 2>/dev/null || true)" /usr/sbin/sysctl /sbin/sysctl; do
    if [[ -n "${c}" && -x "${c}" ]]; then printf '%s' "${c}"; return 0; fi
  done
  return 0
}

host_inotify_lower() {
  # host_inotify_lower - names of the managed limits whose running value is
  # below the wanted one. An unreadable value counts as fine.
  local entry name want have
  for entry in "${INOTIFY_LIMITS[@]}"; do
    read -r name want <<<"${entry}"
    have="$(cat "${INOTIFY_PROC_DIR}/${name}" 2>/dev/null)" || continue
    [[ "${have}" =~ ^[0-9]+$ ]] || continue
    (( have >= want )) || printf '%s ' "${name}"
  done
}

host_sysctl_inotify() {
  # Manage the inotify limits (see the header) and apply them with
  # `sysctl --system` when the file changed or a running value is lower than
  # the file's. Nothing is written or run on a node that is already right.
  ensure_work_dir
  local conf="${WORK_DIR}/teknoir.inotify.conf" entry name want lower sysctl_bin
  {
    printf '# Managed by teknoir-node (host phase); every up rewrites it.\n'
    printf '# Envoy (istio-proxy) aborts with Debian'"'"'s default of 128 inotify instances.\n'
    for entry in "${INOTIFY_LIMITS[@]}"; do
      read -r name want <<<"${entry}"
      printf 'fs.inotify.%s=%s\n' "${name}" "${want}"
    done
  } > "${conf}"
  ensure_dir "$(dirname "${SYSCTL_INOTIFY_CONF}")" 0755
  install_file "${conf}" "${SYSCTL_INOTIFY_CONF}" 0644 "fs.inotify limits for istio-proxy"
  lower="$(host_inotify_lower)"
  if (( ! FILE_CHANGED )) && [[ -z "${lower}" ]]; then
    log "inotify limits: ${SYSCTL_INOTIFY_CONF#"${HOST_ROOT}"} in place and applied"
    return 0
  fi
  if dry_run; then
    changed "apply the inotify limits with sysctl --system${lower:+ (running ${lower% } below the wanted value)}"
    return 0
  fi
  sysctl_bin="$(host_sysctl_bin)"
  if [[ -z "${sysctl_bin}" ]]; then
    warn "sysctl not found: the inotify limits apply at the next boot (istio-proxy may abort until then)"
    return 0
  fi
  if ! "${sysctl_bin}" --system >/dev/null; then
    warn "sysctl --system failed: the inotify limits may not be applied until the next boot"
    return 0
  fi
  changed "applied the inotify limits (sysctl --system)"
  lower="$(host_inotify_lower)"
  [[ -z "${lower}" ]] || warn "inotify ${lower% } still below ${SYSCTL_INOTIFY_CONF#"${HOST_ROOT}"} after sysctl --system: another /etc/sysctl.d file sets it later"
  return 0
}

host_ipv4_network() {
  # host_ipv4_network <ip> <prefix> - the network address of ip/prefix.
  local ip="$1" prefix="$2" a b c d n mask
  IFS=. read -r a b c d <<<"${ip}"
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  n=$(( n & mask ))
  printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# ---------------------------------------------------------------------------
# Host packages from the bundle (node/debs): chrony and util-linux-extra
# (hwclock), installed offline
# ---------------------------------------------------------------------------
# What an install from node/debs may remove: chrony and systemd-timesyncd
# both provide time-daemon and conflict, so apt replaces timesyncd.
HOST_PKG_REMOVALS_OK="systemd-timesyncd"
# 1 when this run (or, in dry-run, the plan) installs the bundle's packages
HOST_PACKAGES_PLANNED=0

host_join() {
  # host_join <separator> <word>... - the words joined by the separator
  local sep="$1" out="" w
  shift
  for w in "$@"; do out+="${out:+${sep}}${w}"; done
  printf '%s' "${out}"
}

host_pkg_installed_version() {
  # host_pkg_installed_version <pkg> - the installed version, empty when the
  # package is not installed (removed-but-configured counts as not installed)
  local out
  # shellcheck disable=SC2016  # a dpkg-query format, not a shell expansion
  out="$(dpkg-query -W -f '${db:Status-Status} ${Version}' "$1" 2>/dev/null)" || return 0
  [[ "${out}" == "installed "* ]] && printf '%s' "${out#installed }"
  return 0
}

host_packages() {
  # Install the bundle's node packages (node/debs/debs.lock lines: <pkg>
  # <version> <arch> <sha256> <file>) when the node lacks those exact
  # versions. apt simulates first, offline (--no-download): any plan other
  # than installing these packages and removing systemd-timesyncd, or a plan
  # that fails, is a WARN and the step is skipped. A node on another Debian
  # point release must not be blocked from a platform update; preflight keeps
  # checking the clock, and doctor shows the gap.
  #
  # Both apt calls see an empty lists dir and no binary caches, so the local
  # .debs are the only origin apt knows and nothing can be fetched. With the
  # node's lists in view, a version that a repository also offers (the live
  # node's lists, from its install, carry both pins) makes apt plan the fetch
  # from that repository, which --no-download refuses: "E: Unable to fetch
  # some archives", exit 100. The node's installed packages (the dpkg status)
  # are still all in view. The install itself runs without --no-download:
  # with it, apt 3.0 never runs the file method that resolves a local .deb's
  # path and fails after its removals ("E: Internal Error, Pathname to install
  # is not absolute"), leaving the node with neither systemd-timesyncd nor
  # chrony (found by airgap/test/node/packages-test.sh).
  local lock="${NODE_ROOT}/debs/debs.lock" pkg ver sha file deb have sim rc=0 op what bad="" removed="" gone="" list
  local -a debs=() names=() apt_offline=()
  if [[ ! -f "${lock}" ]]; then
    log "host packages: this payload has no node/debs (nothing to install)"
    return 0
  fi
  if ! have_tool dpkg-query || ! have_tool apt-get; then
    warn "host packages: dpkg-query or apt-get not found: the bundle's node packages (chrony, hwclock) are not installed"
    return 0
  fi
  while read -r pkg ver _ sha file; do
    [[ -z "${pkg}" || "${pkg}" == \#* ]] && continue
    if [[ ! "${pkg}" =~ ^[a-z0-9][a-z0-9.+-]+$ || ! "${ver}" =~ ^[A-Za-z0-9.+:~-]+$ || ! "${sha}" =~ ^[0-9a-f]{64}$ \
          || ! "${file}" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*\.deb$ ]]; then
      warn "host packages: malformed line in node/debs/debs.lock (${pkg:-?} ${ver:-?}): skipped"
      continue
    fi
    deb="${NODE_ROOT}/debs/${file}"
    if [[ ! -f "${deb}" ]] || [[ "$(host_bundle_sha "debs/${file}")" != "${sha}" ]]; then
      warn "host packages: debs/${file} is missing or does not match its pin in debs.lock: ${pkg} is not installed"
      continue
    fi
    have="$(host_pkg_installed_version "${pkg}")"
    if [[ "${have}" == "${ver}" ]]; then
      continue
    fi
    if [[ -n "${have}" ]] && have_tool dpkg && dpkg --compare-versions "${have}" gt "${ver}"; then
      log "host packages: ${pkg} ${have} is newer than the bundle's ${ver}: kept"
      continue
    fi
    debs+=("${deb}")
    names+=("${pkg} ${ver}${have:+ (was ${have})}")
  done < "${lock}"
  list="$(host_join ", " "${names[@]}")"
  if (( ${#debs[@]} == 0 )); then
    log "host packages: the bundle's node packages are installed ($(awk 'NF && $1 !~ /^#/ {printf "%s%s %s", s, $1, $2; s = ", "}' "${lock}"))"
    return 0
  fi
  ensure_work_dir
  mkdir -p "${WORK_DIR}/apt-lists/partial"
  apt_offline=(-o "Dir::State::Lists=${WORK_DIR}/apt-lists" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=)
  sim="$(LC_ALL=C apt-get install -s --no-download "${apt_offline[@]}" --no-install-recommends "${debs[@]}" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    warn "host packages: apt cannot install ${list} offline (simulate exit ${rc}: $(grep -E '^(E:|W:)' <<<"${sim}" | tail -n 3 | tr '\n' ' ')): skipped; the node keeps its clock tools as they are"
    return 0
  fi
  while read -r op what _; do
    case "${op}" in
      Inst|Remv|Purg) ;;
      *) continue ;;
    esac
    if [[ "${op}" == Inst ]] && printf '%s\n' "${names[@]}" | awk '{print $1}' | grep -qxF -- "${what}"; then
      continue
    fi
    if [[ "${op}" == Remv && " ${HOST_PKG_REMOVALS_OK} " == *" ${what} "* ]]; then
      removed+="${removed:+, }${what}"
      continue
    fi
    bad+="${bad:+; }${op} ${what}"
  done <<<"${sim}"
  if [[ -n "${bad}" ]]; then
    warn "host packages: apt's offline plan for ${list} also changes other packages (${bad}): skipped; the node keeps its clock tools as they are"
    return 0
  fi
  HOST_PACKAGES_PLANNED=1
  if dry_run; then
    changed "install ${list} from the bundle${removed:+ (removes ${removed})}"
    return 0
  fi
  # DPkg::Lock::Timeout: unattended-upgrades and apt-daily may hold the lock
  if ! run env DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=1 apt-get install -y "${apt_offline[@]}" \
       --no-install-recommends -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold "${debs[@]}" >&2; then
    HOST_PACKAGES_PLANNED=0
    # apt removes before it installs: say so when the node lost its time client
    for pkg in ${removed//,/ }; do
      [[ -n "$(host_pkg_installed_version "${pkg}")" ]] || gone+="${gone:+, }${pkg}"
    done
    warn "host packages: apt-get install of ${list} failed (see /var/log/apt/term.log; dpkg --audit)${gone:+; apt had already removed ${gone}, so the node has no time service until the packages are installed}: the converge goes on without them"
    return 0
  fi
  changed "installed ${list} from the bundle${removed:+ (removed ${removed})}"
}

# ---------------------------------------------------------------------------
# Time: chrony serves the LAN; every up corrects the clock and the RTC
# ---------------------------------------------------------------------------
# |skew| at or below this many seconds needs no correction
CLOCK_OK_SKEW="${CLOCK_OK_SKEW:-2}"
RTC_EPOCH_FILE="${HOST_ROOT}/sys/class/rtc/rtc0/since_epoch"
# chrony fits a clock rate only across LAN-time samples at least this many
# seconds apart (clock_manual_guard): a second of sample error over 12 h is
# a rate error of 23 ppm (over 1 min, 16700 ppm)
CLOCK_RATE_MIN_AGE="${CLOCK_RATE_MIN_AGE:-43200}"
# chrony's maxdrift (ppm) in the drop-in: the largest clock rate correction
# chrony may use, 8.6 s a day (chrony's default is 500000)
CHRONY_MAXDRIFT=100
# 1 once this run gave chrony its LAN-time sample (settime runs once per up)
CLOCK_SAMPLE_SENT=0
# 1 once this run wrote (in dry-run: would write) the RTC
CLOCK_RTC_WRITTEN=0

clock_chrony_installed() { have_tool "${CHRONYC}"; }

clock_chrony_active() {
  clock_chrony_installed && systemctl is-active --quiet chrony 2>/dev/null
}

clock_mono_cs() {
  # clock_mono_cs - centiseconds of a clock that no setting of the wall clock
  # moves (CLOCK_BOOTTIME, /proc/uptime). bash's SECONDS follows the wall
  # clock, so after preflight steps the clock it would carry the step into the
  # LAN-time estimate. SECONDS only when /proc/uptime cannot be read.
  local up
  if { read -r up _ < "${HOST_ROOT}/proc/uptime"; } 2>/dev/null && [[ "${up}" =~ ^([0-9]+)\.([0-9]{2}) ]]; then
    printf '%s' "$(( 10#${BASH_REMATCH[1]}${BASH_REMATCH[2]} ))"
  else
    printf '%s' "$(( SECONDS * 100 ))"
  fi
}

clock_lan_now() {
  # clock_lan_now - the LAN host's clock now: --lan-time plus the time since
  # it was parsed (LAN_TIME_MONO, clock_mono_cs), rounded to whole seconds.
  # Setting the node clock does not change it. Empty without --lan-time.
  [[ -n "${LAN_TIME:-}" ]] || return 0
  local now_cs at_cs
  now_cs="$(clock_mono_cs)"
  at_cs="${LAN_TIME_MONO:-${now_cs}}"
  printf '%s' "$(( LAN_TIME + (now_cs - at_cs + 50) / 100 ))"
}

clock_tracking() {
  # clock_tracking - "<reference id> <stratum> <frequency...>" from
  # `chronyc -n tracking` (a monitoring command, read-only); empty when chrony
  # does not answer
  "${CHRONYC}" -n tracking 2>/dev/null | awk -F': *' '
    /^Reference ID/ { split($2, a, " "); ref = a[1]; name = a[2]; gsub(/[()]/, "", name) }
    /^Stratum/ { st = $2 }
    /^Frequency/ { fr = $2 }
    END { if (ref != "") printf "%s %s %s %s", ref, (name == "" ? "-" : name), (st == "" ? "?" : st), fr }' || true
}

clock_source_label() {
  # clock_source_label <reference id> <name> - LOCAL (local stratum), MANU
  # (manual samples), none (no reference yet), else the source's name
  case "$1" in
    7F7F0101) printf 'LOCAL' ;;
    4D414E55) printf 'MANU' ;;
    00000000|"") printf 'none' ;;
    *) if [[ "$2" != "-" && -n "$2" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi ;;
  esac
}

clock_source_selected() {
  # clock_source_selected - 0 when chrony has selected an NTP source ('^*')
  "${CHRONYC}" -n sources 2>/dev/null | grep -q '^\^\*'
}

clock_rtc_offset() {
  # clock_rtc_offset - RTC minus system clock in seconds; empty when the node
  # has no readable RTC
  local rtc
  rtc="$(cat "${RTC_EPOCH_FILE}" 2>/dev/null)" || return 0
  [[ "${rtc}" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$(( rtc - $(date +%s) ))"
}

clock_rtc_local() {
  # clock_rtc_local - 0 when /etc/adjtime says the RTC keeps local time
  [[ "$(sed -n 3p "${HOST_ROOT}/etc/adjtime" 2>/dev/null)" == LOCAL ]]
}

clock_write_rtc() {
  # clock_write_rtc <why> - set the RTC from the system clock (UTC)
  if ! have_tool "${HWCLOCK}"; then
    warn "hwclock is not installed (util-linux-extra): the RTC is not written; the next boot starts from it ($1)"
    return 0
  fi
  if clock_rtc_local; then
    warn "the RTC keeps local time (/etc/adjtime): teknoir-node does not write it ($1)"
    return 0
  fi
  if run "${HWCLOCK}" --systohc --utc; then
    CLOCK_RTC_WRITTEN=1
    changed "RTC set from the system clock ($1)"
  else
    warn "hwclock --systohc --utc failed: the RTC keeps its time ($1)"
  fi
}

clock_manual_guard() {
  # clock_manual_guard - before a LAN-time sample. chrony fits a clock rate
  # (frequency) across its manual samples, and each sample is only good to
  # about a second (whole seconds, ssh latency): two samples a minute apart
  # taught the bundled chrony 4.6.1 a rate error of 16455 ppm. So when its
  # newest sample is younger than CLOCK_RATE_MIN_AGE (a re-run, a second up
  # the same day), or the list cannot be read, the samples are dropped
  # (manual reset): the new sample then corrects the offset only and the rate
  # learned so far stays. Samples at least that far apart still teach chrony
  # the node's drift (live: about 45 ppm); maxdrift bounds any fit.
  local out newest="" age=""
  if out="$("${CHRONYC}" -c manual list 2>/dev/null)"; then
    # chrony 4.6: "<index>,<YYYY-MM-DD HH:MM:SS (UTC)>,<slewed>,<original>,
    # <residual>" per sample, nothing when there is none
    newest="$(awk -F, '
      NF == 0 { next }
      $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ { if ($2 > m) m = $2; next }
      { bad = 1 }
      END { if (bad) print "unknown"; else print m }' <<<"${out}")"
    [[ -n "${newest}" ]] || return 0
    [[ "${newest}" == unknown ]] || newest="$(date -u -d "${newest}" +%s 2>/dev/null)" || newest=unknown
  else
    newest=unknown
  fi
  if [[ "${newest}" != unknown ]]; then
    age=$(( $(date +%s) - newest ))
    if (( age >= CLOCK_RATE_MIN_AGE )); then
      log "chrony: its newest LAN-time sample is ${age}s old: this one may also refine the clock rate"
      return 0
    fi
  fi
  local why="their list could not be read"
  [[ -z "${age}" ]] || why="the newest is ${age}s old, under ${CLOCK_RATE_MIN_AGE}s"
  if run "${CHRONYC}" manual reset >/dev/null; then
    log "chrony: dropped its manual samples (${why}): this sample corrects the offset only"
  else
    warn "chronyc manual reset failed: chrony may fit a clock rate across close samples (maxdrift ${CHRONY_MAXDRIFT} ppm bounds it)"
  fi
}

clock_settime() {
  # clock_settime <epoch> - give chrony the LAN host's time as a manual sample
  # (needs 'manual' in its configuration, which host_chrony writes). chrony
  # corrects the clock from it, and learns the drift from samples at least
  # CLOCK_RATE_MIN_AGE apart (clock_manual_guard; driftfile). Returns
  # non-zero when chrony refuses it.
  local when out
  when="$(LC_ALL=C date -u -d "@$1" '+%b %d, %Y %H:%M:%S')" || return 1
  clock_manual_guard
  out="$(run env TZ=UTC "${CHRONYC}" settime "${when}" 2>&1)" || { warn "chronyc settime failed: $(tr '\n' ' ' <<<"${out}")"; return 1; }
  CLOCK_SAMPLE_SENT=1
  log "chrony: LAN-time sample ${when} UTC: $(grep -v '^200 OK' <<<"${out}" | tr '\n' ' ')"
}

clock_step() {
  # clock_step <epoch> <skew> <sync|auto> - set the node clock to the LAN
  # host's time now: through chrony when it runs (sample + makestep), else
  # with date -u -s. A clock that cannot be set stops the run only for
  # --sync-clock (sync); in the automatic correction (auto) it is a WARN, as
  # time must not block a platform update.
  local lan="$1" skew="$2" mode="$3"
  if clock_chrony_active && clock_settime "${lan}"; then
    run "${CHRONYC}" makestep >/dev/null || warn "chronyc makestep failed (chrony slews the rest)"
    changed "node clock set from the LAN host through chrony (skew was ${skew}s)"
  elif run "${DATE_BIN}" -u -s "@${lan}" >/dev/null; then
    changed "node clock set from the LAN host with date (skew was ${skew}s)"
  elif [[ "${mode}" == sync ]]; then
    die "cannot set the node clock (date -u -s)"
  else
    warn "cannot set the node clock (date -u -s): it stays ${skew}s off the LAN host; chrony corrects it once it runs, or re-run with --sync-clock"
  fi
}

clock_status_line() {
  # clock_status_line - for status: "<utc> source=<LOCAL|MANU|none|name>
  # stratum N freq X ppm ... NTPSynchronized=..; RTC <+-N> s; chrony <state>"
  local line tr ref name st fr off sync="?" chrony=absent
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if clock_chrony_installed; then
    chrony=inactive
    systemctl is-active --quiet chrony 2>/dev/null && chrony=active
    tr="$(clock_tracking)"
    if [[ -n "${tr}" ]]; then
      read -r ref name st fr <<<"${tr}"
      line+=" source=$(clock_source_label "${ref}" "${name}") stratum ${st} freq ${fr:-?}"
    fi
  fi
  if have_tool timedatectl; then
    sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '?')"
  fi
  line+=" NTPSynchronized=${sync:-?}"
  off="$(clock_rtc_offset)"
  if [[ -n "${off}" ]]; then line+="; RTC $(printf '%+d' "${off}") s"; else line+="; RTC unreadable"; fi
  printf '%s; chrony %s' "${line}" "${chrony}"
}

host_time() {
  # After host_chrony: when chrony keeps only its local or manual reference
  # (no NTP source answers, the air-gap normal case), give it this run's
  # LAN-time sample (once per up); then write the RTC when it is more than
  # CLOCK_OK_SKEW seconds off the system clock, so a reboot starts from the
  # right time. Dry-run only reports.
  local tr ref name label lan skew off
  if clock_chrony_active; then
    tr="$(clock_tracking)"
    # no answer (chrony just restarted): as with no reference yet
    read -r ref name _ _ <<<"${tr:-00000000 -}"
    label="$(clock_source_label "${ref}" "${name}")"
    lan="$(clock_lan_now)"
    if [[ "${label}" != LOCAL && "${label}" != MANU && "${label}" != none ]] || clock_source_selected; then
      log "chrony follows the NTP source ${label}: no LAN-time sample"
    elif [[ -z "${lan}" ]]; then
      log "chrony reference ${label}; no --lan-time given: no LAN-time sample"
    elif (( CLOCK_SAMPLE_SENT )); then
      log "chrony already has this run's LAN-time sample"
    elif dry_run; then
      log "[dry-run] chrony (reference ${label}) would get a LAN-time sample"
    else
      skew=$(( $(date +%s) - lan ))
      if ! clock_settime "${lan}"; then
        :
      elif (( skew < -CLOCK_OK_SKEW )); then
        # a node behind: apply the correction now (slewing 20 s at chrony's
        # maximum rate takes about 4 minutes); a step forward only
        run "${CHRONYC}" makestep >/dev/null || warn "chronyc makestep failed (chrony slews the rest)"
        changed "node clock set forward through chrony (was ${skew}s off the LAN host)"
      elif (( skew > CLOCK_OK_SKEW )); then
        # a node ahead: teknoir-node does not step a running node back without
        # --sync-clock; chrony slews it (or steps it itself under its own
        # 'makestep' rule in its first updates after a start)
        changed "node clock ${skew}s ahead of the LAN host: chrony corrects it from the sample (no step back by teknoir-node)"
      fi
    fi
  elif clock_chrony_installed; then
    log "chrony is installed but not active: the clock is checked against the LAN host only"
  fi
  off="$(clock_rtc_offset)"
  if (( CLOCK_RTC_WRITTEN )); then
    log "RTC: written in this run's preflight"
  elif [[ -z "${off}" ]]; then
    log "no RTC to check (${RTC_EPOCH_FILE#"${HOST_ROOT}"} not readable)"
  elif (( ${off#-} <= CLOCK_OK_SKEW )); then
    log "RTC: ${off}s from the system clock"
  elif dry_run; then
    if have_tool "${HWCLOCK}" || (( HOST_PACKAGES_PLANNED )); then
      changed "set the RTC from the system clock (it is ${off}s off)"
    else
      warn "the RTC is ${off}s off the system clock and hwclock is not installed"
    fi
  else
    clock_write_rtc "was ${off}s off"
  fi
}

host_chrony() {
  # chrony serves time to the LAN from the node: a local stratum-10 reference
  # that every up corrects with a LAN-time sample (manual, host_time), or the
  # TIME_SOURCE servers (site env, space-separated) when they answer. Without
  # chrony, preflight still checks the skew against the LAN host.
  if ! clock_chrony_installed; then
    if (( HOST_PACKAGES_PLANNED )) && dry_run; then
      log "[dry-run] chrony is not installed yet: its drop-in ${CHRONY_CONF} would be written after the install"
    else
      log "chrony is not installed: the node does not serve time (skew is checked against the LAN host)"
    fi
    return 0
  fi
  ensure_work_dir
  local cidr prefix net s conf="${WORK_DIR}/chrony.conf"
  local -a sources=()
  read -r -a sources <<<"${TIME_SOURCE:-}"
  cidr="$(ip -o -4 addr show 2>/dev/null | awk -v ip="${NODE_IP}" '{split($4, a, "/"); if (a[1] == ip) {print $4; exit}}')"
  [[ -n "${cidr}" ]] || die "cannot find the prefix length of ${NODE_IP} for chrony's allow rule"
  prefix="${cidr#*/}"
  net="$(host_ipv4_network "${NODE_IP}" "${prefix}")/${prefix}"
  {
    printf '# Managed by teknoir-node (host phase); every up rewrites it.\n'
    printf '# Serves NTP to the LAN (Robots, cameras: server NODE_IP). Without an\n'
    printf '# answering server below, the reference is the local clock (stratum 10),\n'
    printf '# which up corrects with the LAN host time (chronyc settime, needs manual).\n'
    printf '# maxdrift bounds the clock rate chrony may learn (%s ppm).\n' "${CHRONY_MAXDRIFT}"
    for s in ${sources[@]+"${sources[@]}"}; do
      printf 'server %s iburst prefer\n' "${s}"
    done
    printf 'allow %s\n' "${net}"
    printf 'local stratum 10\n'
    printf 'manual\n'
    printf 'maxdrift %s\n' "${CHRONY_MAXDRIFT}"
  } > "${conf}"
  ensure_dir "${CHRONY_CONF_DIR}" 0755
  install_file "${conf}" "${CHRONY_CONF}" 0644 "chrony: serve ${net}${TIME_SOURCE:+, source ${TIME_SOURCE}}"
  # time must not block the platform update: a chrony that fails is a WARN
  if systemctl is-active --quiet chrony 2>/dev/null; then
    if (( FILE_CHANGED )); then
      if run systemctl restart chrony; then
        changed "restarted chrony for its new drop-in"
      else
        warn "chrony did not restart with ${CHRONY_CONF} (journalctl -u chrony): the node does not serve time"
      fi
    fi
  elif run systemctl enable --now chrony; then
    changed "enabled and started chrony (it was installed but not active)"
  else
    warn "chrony is installed but does not start (journalctl -u chrony): the node does not serve time"
  fi
  if ! grep -qsE '^[[:space:]]*confdir[[:space:]]+/etc/chrony/conf\.d' "${HOST_ROOT}/etc/chrony/chrony.conf"; then
    warn "/etc/chrony/chrony.conf has no 'confdir /etc/chrony/conf.d': ${CHRONY_CONF} is not read"
  fi
}

# ---------------------------------------------------------------------------
# Bootstrap image tarballs
# ---------------------------------------------------------------------------
_host_tarball_cache_file() { printf '%s/cache/agent-images.sums' "${STATE_DIR}"; }

_host_tarball_dest_sha() {
  # _host_tarball_dest_sha <file> - sha256 of a file in agent/images, cached by
  # (size, mtime) so an unchanged multi-GB set is not re-hashed every run.
  local f="$1" key cache sha
  key="$(stat -c '%s %Y' "${f}")"
  cache="$(_host_tarball_cache_file)"
  if [[ -f "${cache}" ]]; then
    sha="$(awk -v n="$(basename "${f}")" -v k="${key}" '$1 == n && ($2 " " $3) == k {print $4; exit}' "${cache}")"
    if [[ -n "${sha}" ]]; then
      printf '%s' "${sha}"
      return 0
    fi
  fi
  sha="$(sha256_file "${f}")"
  if ! dry_run; then
    mkdir -p "$(dirname "${cache}")"
    { [[ -f "${cache}" ]] && awk -v n="$(basename "${f}")" '$1 != n' "${cache}"
      printf '%s %s %s\n' "$(basename "${f}")" "${key}" "${sha}"; } > "${cache}.tmp"
    mv -f "${cache}.tmp" "${cache}"
  fi
  printf '%s' "${sha}"
}

host_bundle_tarballs() {
  # host_bundle_tarballs - "relpath" of every tarball k3s must import.
  local t
  printf '%s\n' "k3s/k3s-airgap-images-amd64.tar.zst"
  shopt -s nullglob
  for t in "${NODE_ROOT}"/bootstrap-images/*.tar; do
    printf '%s\n' "bootstrap-images/$(basename "${t}")"
  done
  shopt -u nullglob
}

host_sync_tarballs() {
  local dir rel name dst want have f n=0
  local -A desired=()
  dir="$(host_k3s_images_dir)"
  ensure_dir "$(host_k3s_data_path)" 0755
  ensure_dir "$(host_k3s_data_path /agent)" 0755
  ensure_dir "${dir}" 0755
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    name="$(basename "${rel}")"
    desired["${name}"]=1
    n=$(( n + 1 ))
    dst="${dir}/${name}"
    want="$(host_bundle_sha "${rel}")"
    have=""
    [[ -f "${dst}" ]] && have="$(_host_tarball_dest_sha "${dst}")"
    [[ "${have}" == "${want}" ]] && continue
    if dry_run; then
      changed "copy image tarball ${name} -> ${dir}"
      continue
    fi
    cp -f "${NODE_ROOT}/${rel}" "${dir}/.${name}.teknoir-tmp" || die "cannot copy ${rel} to ${dir}"
    mv -f "${dir}/.${name}.teknoir-tmp" "${dst}"
    changed "image tarball ${name} -> ${dir}"
  done < <(host_bundle_tarballs)
  [[ -d "${dir}" ]] || return 0
  for f in "${dir}"/*; do
    [[ -f "${f}" ]] || continue
    name="$(basename "${f}")"
    [[ "${name}" =~ ${TARBALL_RE} ]] || continue
    [[ -n "${desired[${name}]+x}" ]] && continue
    run rm -f "${f}"
    changed "pruned stale image tarball ${name} (not in this bundle)"
  done
  log "image tarballs: ${n} in this bundle, synced to ${dir}"
}

host_normalize_image_ref() {
  # host_normalize_image_ref <ref> - containerd's name for a docker reference.
  # A reference with both a tag and a digest (G-09 pins,
  # "<repo>:<tag>@sha256:<d>") is named "<repo>@sha256:<d>": containerd's
  # ParseDockerRef drops the tag when a digest is present.
  local ref="$1" first rest last
  first="${ref%%/*}"
  if [[ "${ref}" != */* ]]; then
    ref="docker.io/library/${ref}"
  elif [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
    ref="docker.io/${ref}"
  fi
  if [[ "${ref}" == docker.io/* ]]; then
    rest="${ref#docker.io/}"
    [[ "${rest}" == */* ]] || ref="docker.io/library/${rest}"
  fi
  [[ "${ref##*/}" == *[:@]* ]] || ref="${ref}:latest"
  if [[ "${ref}" == *@sha256:* ]]; then
    rest="${ref%%@*}"
    last="${rest##*/}"
    [[ "${last}" != *:* ]] || ref="${rest%:*}@${ref#*@}"
  fi
  printf '%s' "${ref}"
}

host_tarball_image_refs() {
  # host_tarball_image_refs <relpath> - the RepoTags of a docker-archive tarball,
  # normalized; cached by the tarball's sha256.
  local rel="$1" sha cache ref
  sha="$(host_bundle_sha "${rel}")"
  cache="${STATE_DIR}/cache/refs-${sha}"
  if [[ ! -f "${cache}" ]]; then
    local refs
    refs="$(tar -xOf "${NODE_ROOT}/${rel}" manifest.json 2>/dev/null | "${JQ}" -r '.[].RepoTags[]?' 2>/dev/null)" || refs=""
    if dry_run; then
      for ref in ${refs}; do host_normalize_image_ref "${ref}"; printf '\n'; done
      return 0
    fi
    mkdir -p "$(dirname "${cache}")"
    for ref in ${refs}; do host_normalize_image_ref "${ref}"; printf '\n'; done > "${cache}.tmp"
    mv -f "${cache}.tmp" "${cache}"
  fi
  cat "${cache}"
}

host_containerd_images() {
  # host_containerd_images - every image name in containerd's k8s.io namespace.
  # Dies when containerd cannot be queried (never read as "no images").
  "${K3S_BIN}" ctr -n k8s.io images ls -q || die "cannot list containerd images (k3s ctr)"
}

host_missing_bootstrap_tarballs() {
  # host_missing_bootstrap_tarballs - relpaths of bootstrap tarballs with at least
  # one image not in containerd.
  local present rel refs ref
  present="$(host_containerd_images)"
  shopt -s nullglob
  for rel in "${NODE_ROOT}"/bootstrap-images/*.tar; do
    rel="bootstrap-images/$(basename "${rel}")"
    refs="$(host_tarball_image_refs "${rel}")"
    if [[ -z "${refs}" ]]; then
      warn "${rel}: no RepoTags in manifest.json (not a docker archive?); import not checked"
      continue
    fi
    for ref in ${refs}; do
      if ! grep -qxF "${ref}" <<<"${present}"; then
        printf '%s\n' "${rel}"
        break
      fi
    done
  done
  shopt -u nullglob
}

host_import_images() {
  local missing rel ref deadline
  if [[ ! -x "${K3S_BIN}" ]] || ! cluster_up; then
    dry_run && { log "[dry-run] bootstrap images would be imported once k3s runs"; return 0; }
    die "k3s is not running: cannot check the bootstrap images"
  fi
  missing="$(host_missing_bootstrap_tarballs)"
  if [[ -n "${missing}" && "${K3S_JUST_STARTED}" == "1" ]] && ! dry_run; then
    # k3s imports agent/images itself after a start, asynchronously.
    log "waiting up to ${K3S_IMPORT_WAIT}s for k3s to import $(grep -c . <<<"${missing}") bootstrap tarball(s) ..."
    deadline=$(( SECONDS + K3S_IMPORT_WAIT ))
    while [[ -n "${missing}" ]] && (( SECONDS < deadline )); do
      sleep 10
      missing="$(host_missing_bootstrap_tarballs)"
    done
  fi
  for rel in ${missing}; do
    if dry_run; then
      changed "import ${rel} into containerd"
      continue
    fi
    "${K3S_BIN}" ctr -n k8s.io images import "${NODE_ROOT}/${rel}" >/dev/null \
      || die "k3s ctr images import ${rel} failed"
    # Pin like k3s pins its own airgap imports, so kubelet image GC keeps them.
    for ref in $(host_tarball_image_refs "${rel}"); do
      "${K3S_BIN}" ctr -n k8s.io images label "${ref}" io.cri-containerd.pinned=pinned >/dev/null 2>&1 \
        || warn "could not pin ${ref}"
    done
    changed "imported ${rel} into containerd"
  done
  [[ -n "${missing}" ]] || log "bootstrap images: all present in containerd"
}

# ---------------------------------------------------------------------------
# k3s install / upgrade / restart
# ---------------------------------------------------------------------------
_host_sha_or_absent() {
  if [[ -f "$1" ]]; then sha256_file "$1"; else printf 'absent'; fi
}

host_stamp_value() {
  # What the running k3s must have loaded: config.yaml, registries.yaml and
  # the registry CA (k3s may skip a ca_file that did not exist at start).
  printf 'config=%s registries=%s ca=%s resolv=%s' \
    "$(_host_sha_or_absent "${K3S_CONFIG_FILE}")" \
    "$(_host_sha_or_absent "${K3S_REGISTRIES_FILE}")" \
    "$(_host_sha_or_absent "${K3S_CA_FILE}")" \
    "$(_host_sha_or_absent "${K3S_RESOLV_FILE}")"
}

host_restart_state() {
  # For status: does the running k3s match the files on disk?
  local cur
  cur="$(cat "${RESTART_STAMP}" 2>/dev/null || true)"
  if [[ -z "${cur}" ]]; then
    printf 'no restart stamp yet'
  elif [[ "${cur}" == "$(host_stamp_value)" ]]; then
    printf 'k3s runs with the current config.yaml/registries.yaml/CA'
  else
    printf 'k3s restart pending (config.yaml, registries.yaml or CA changed)'
  fi
}

_host_k3s_started_after_files() {
  # 0 when k3s (active) started after the last change of every stamped file:
  # it has loaded them. Used only to adopt a node that has no stamp yet.
  local ts started f m
  ts="$(systemctl show k3s -p ActiveEnterTimestamp --value 2>/dev/null)" || return 1
  [[ -n "${ts}" && "${ts}" != "n/a" ]] || return 1
  started="$(date -d "${ts}" +%s 2>/dev/null)" || return 1
  for f in "${K3S_CONFIG_FILE}" "${K3S_REGISTRIES_FILE}" "${K3S_CA_FILE}" "${K3S_RESOLV_FILE}"; do
    [[ -f "${f}" ]] || continue
    m="$(stat -c %Y "${f}")"
    (( m < started )) || return 1
  done
  return 0
}

host_k3s_wait_ready() {
  wait_for "the k3s API" "${K3S_READY_TIMEOUT}" cluster_up
  wait_for "the k3s node to be Ready" "${K3S_READY_TIMEOUT}" kc wait --for=condition=Ready node --all --timeout=10s
}

host_pods_unsettled() {
  # print "ns/name" of every pod in K3S_SETTLE_NAMESPACES that should run but
  # is not Running and Ready (Job pods and finished pods do not count)
  local out
  out="$(kc get pods -A -o json)" || { echo "(cannot list pods)"; return 0; }
  # shellcheck disable=SC2016  # a jq program
  "${JQ}" -r --arg nss " ${K3S_SETTLE_NAMESPACES} " '.items[]?
      | select(.metadata.namespace as $ns | $nss | contains(" \($ns) "))
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | select([(.metadata.ownerReferences // [])[].kind] | index("Job") | not)
      | select(.status.phase != "Running" or ([.status.conditions[]? | select(.type == "Ready") | .status] != ["True"]))
      | "\(.metadata.namespace)/\(.metadata.name)"' <<<"${out}" 2>/dev/null || echo "(cannot parse the pod list)"
}

host_k3s_wait_settled() {
  # After k3s restarts under a running platform, kubelet runs every readiness
  # probe again and pods drop out of their Services for a while (the gateway
  # answers 503 "no healthy upstream"; VM e2e E4 hit it in the harbor phase).
  # Wait until every platform pod is Running and Ready in 3 checks in a row.
  # A pod that stays unready only warns: it may be what this update fixes.
  local ok=0 left deadline=$((SECONDS + K3S_SETTLE_TIMEOUT))
  host_k3s_wait_ready
  sleep "${K3S_SETTLE_DELAY}"
  while (( ok < 3 )); do
    left="$(host_pods_unsettled)"
    if [[ -z "${left}" ]]; then ok=$((ok + 1)); else ok=0; fi
    (( ok < 3 )) || break
    if (( SECONDS >= deadline )); then
      warn "after the k3s restart these pods are still not Ready (${K3S_SETTLE_TIMEOUT}s): $(tr '\n' ' ' <<<"${left}")"
      return 0
    fi
    sleep "${K3S_SETTLE_INTERVAL}"
  done
  log "after the k3s restart every platform pod is Running and Ready again"
}

host_write_stamp() {
  dry_run && return 0
  mkdir -p "$(dirname "${RESTART_STAMP}")"
  host_stamp_value > "${RESTART_STAMP}.tmp"
  mv -f "${RESTART_STAMP}.tmp" "${RESTART_STAMP}"
}

host_k3s_install() {
  # Install or upgrade from the bundle: binary first (atomic rename; a running
  # k3s keeps its old inode), then install.sh writes the unit and (re)starts.
  local from="$1"
  if dry_run; then
    changed "install k3s $(_host_k3s_bundle_version) (${from}) with INSTALL_K3S_SKIP_DOWNLOAD"
    return 0
  fi
  mkdir -p "$(dirname "${K3S_BIN}")"
  install -m 0755 "${NODE_ROOT}/k3s/k3s" "${K3S_BIN}.teknoir-new" || die "cannot stage the k3s binary"
  mv -f "${K3S_BIN}.teknoir-new" "${K3S_BIN}"
  log "running the bundled k3s install.sh (INSTALL_K3S_SKIP_DOWNLOAD=true)"
  # A clean environment, so no stray K3S_* variable ends up in the unit's
  # env file. The test sandbox (HOST_ROOT) keeps PATH and its STUB_* vars.
  local -a sandbox_env=()
  if [[ -n "${HOST_ROOT}" ]]; then
    sandbox_env=("PATH=${PATH}")
    while IFS= read -r v; do sandbox_env+=("${v}"); done < <(env | grep '^STUB_' || true)
  fi
  env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    ${sandbox_env[@]+"${sandbox_env[@]}"} \
    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_SKIP_SELINUX_RPM=true \
    INSTALL_K3S_SELINUX_WARN=true \
    INSTALL_K3S_EXEC=server \
    INSTALL_K3S_BIN_DIR="${HOST_ROOT}/usr/local/bin" \
    INSTALL_K3S_SYSTEMD_DIR="${HOST_ROOT}/etc/systemd/system" \
    sh "${NODE_ROOT}/k3s/install.sh" >&2 \
    || die "k3s install.sh failed (see: journalctl -u k3s --no-pager -n 100)"
  changed "installed k3s $(_host_k3s_bundle_version) (${from})"
  K3S_JUST_STARTED=1
}

_host_k3s_bundle_version() {
  "${NODE_ROOT}/k3s/k3s" --version 2>/dev/null | awk 'NR == 1 {print $3}' || true
}

host_k3s_reconcile() {
  # Install, upgrade, start or restart k3s - each only when needed - then wait
  # for it and record the stamp.
  local want have stamp_now stamp_want action=""
  want="$(host_bundle_sha k3s/k3s)"
  have=""
  [[ -f "${K3S_BIN}" ]] && have="$(sha256_file "${K3S_BIN}")"
  if [[ -z "${have}" ]]; then
    action="install"
  elif [[ "${have}" != "${want}" ]]; then
    action="upgrade"
  elif [[ ! -f "${K3S_UNIT_FILE}" ]]; then
    action="install"
  elif ! systemctl is-active --quiet k3s; then
    action="start"
  else
    stamp_now="$(cat "${RESTART_STAMP}" 2>/dev/null || true)"
    stamp_want="$(host_stamp_value)"
    if dry_run && (( HOST_FILES_CHANGED )); then
      action="restart"
    elif [[ "${stamp_now}" != "${stamp_want}" ]]; then
      if [[ -z "${stamp_now}" ]] && (( HOST_FILES_CHANGED == 0 )) && _host_k3s_started_after_files; then
        log "k3s started after its config files were last written: recording the restart stamp, no restart"
        host_write_stamp
        return 0
      fi
      action="restart"
    fi
  fi
  case "${action}" in
    "")
      log "k3s: binary, unit and config unchanged; running - no restart"
      return 0
      ;;
    install)
      host_k3s_install "fresh install"
      ;;
    upgrade)
      host_k3s_install "upgrade from $("${K3S_BIN}" --version 2>/dev/null | awk 'NR == 1 {print $3}' || echo unknown)"
      ;;
    start)
      run systemctl start k3s
      changed "started k3s (it was not active)"
      K3S_JUST_STARTED=1
      ;;
    restart)
      run systemctl restart k3s
      changed "restarted k3s (config.yaml, registries.yaml, the registry CA or the CoreDNS upstream changed)"
      K3S_JUST_STARTED=1
      ;;
  esac
  dry_run && return 0
  host_k3s_wait_ready
  if (( HOST_RESOLV_CHANGED )) && [[ "${action}" == "restart" ]]; then
    # CoreDNS (dnsPolicy Default) reads the node resolv-conf only when its pod
    # is created; a k3s restart keeps the running pod
    if kc -n kube-system delete pod -l k8s-app=kube-dns --ignore-not-found >/dev/null; then
      changed "restarted CoreDNS for its new upstream"
    else
      warn "could not restart CoreDNS; it keeps its old upstream until its pod is re-created"
    fi
  fi
  [[ "${action}" != "restart" ]] || host_k3s_wait_settled
  host_write_stamp
}

# ---------------------------------------------------------------------------
# Node CA trust (called by the secrets phase once the CA Secret exists)
# ---------------------------------------------------------------------------
host_trust_ca() {
  # host_trust_ca <pem-file> - the Root CA into the k3s registry trust path,
  # the OS trust store (update-ca-certificates runs every time; it is cheap)
  # and STATE_DIR (for the LAN host to fetch). Restarts k3s once if the CA
  # appeared or changed after k3s started (restart stamp).
  local pem="$1" any=0
  ensure_dir "${K3S_CONFIG_DIR}" 0755
  install_file "${pem}" "${K3S_CA_FILE}" 0644 "registry CA for containerd"
  (( FILE_CHANGED )) && any=1
  ensure_dir "$(dirname "${OS_CA_FILE}")" 0755
  install_file "${pem}" "${OS_CA_FILE}" 0644 "Teknoir Root CA in the OS trust store"
  ensure_dir "${STATE_DIR}" 0755
  install_file "${pem}" "${STATE_DIR}/teknoir-root-ca.crt" 0644 "CA copy for the LAN host"
  if command -v update-ca-certificates >/dev/null 2>&1; then
    run update-ca-certificates >/dev/null
  else
    warn "update-ca-certificates not found: the OS trust store was not refreshed"
  fi
  if (( any )) && dry_run; then
    log "[dry-run] k3s would restart if it started without this CA (restart stamp)"
    return 0
  fi
  if [[ -x "${K3S_BIN}" ]] && systemctl is-active --quiet k3s 2>/dev/null; then
    local stamp_now
    stamp_now="$(cat "${RESTART_STAMP}" 2>/dev/null || true)"
    if [[ -n "${stamp_now}" && "${stamp_now}" != "$(host_stamp_value)" ]]; then
      run systemctl restart k3s
      changed "restarted k3s (the registry CA changed since its start)"
      dry_run && return 0
      host_k3s_wait_settled
      host_write_stamp
    fi
  fi
}

# ---------------------------------------------------------------------------
# Phase
# ---------------------------------------------------------------------------
phase_host() {
  [[ "${ROLE:-server}" == "server" ]] || die "host: role ${ROLE} is not implemented (D11)"
  HOST_FILES_CHANGED=0
  HOST_RESOLV_CHANGED=0
  K3S_JUST_STARTED=0
  host_check_k3s_payload
  host_sysctl_inotify
  host_node_files
  host_hosts_block
  host_packages
  host_chrony
  host_time
  host_sync_tarballs
  host_k3s_reconcile
  host_import_images
}
