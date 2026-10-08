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
CHRONY_CONF_DIR="${HOST_ROOT}/etc/chrony/conf.d"
CHRONY_CONF="${CHRONY_CONF_DIR}/teknoir-airgap.conf"
RESTART_STAMP="${STATE_DIR}/restart.stamp"
K3S_IMPORT_WAIT="${K3S_IMPORT_WAIT:-600}"
K3S_READY_TIMEOUT="${K3S_READY_TIMEOUT:-300}"
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

host_ipv4_network() {
  # host_ipv4_network <ip> <prefix> - the network address of ip/prefix.
  local ip="$1" prefix="$2" a b c d n mask
  IFS=. read -r a b c d <<<"${ip}"
  n=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  n=$(( n & mask ))
  printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

host_chrony() {
  # chrony (if installed) serves time to the LAN from the node; TIME_SOURCE
  # (site env) adds an upstream server. Without chrony, preflight still checks
  # the skew against the LAN host.
  if ! command -v chronyd >/dev/null 2>&1 && [[ ! -x "${HOST_ROOT}/usr/sbin/chronyd" ]]; then
    log "chrony is not installed: the node does not serve time (skew is checked against the LAN host)"
    return 0
  fi
  ensure_work_dir
  local cidr prefix net conf="${WORK_DIR}/chrony.conf"
  cidr="$(ip -o -4 addr show 2>/dev/null | awk -v ip="${NODE_IP}" '{split($4, a, "/"); if (a[1] == ip) {print $4; exit}}')"
  [[ -n "${cidr}" ]] || die "cannot find the prefix length of ${NODE_IP} for chrony's allow rule"
  prefix="${cidr#*/}"
  net="$(host_ipv4_network "${NODE_IP}" "${prefix}")/${prefix}"
  {
    printf '# Managed by teknoir-node (host phase): serve time to the airgapped LAN.\n'
    if [[ -n "${TIME_SOURCE}" ]]; then
      printf 'server %s iburst prefer\n' "${TIME_SOURCE}"
    fi
    printf 'allow %s\n' "${net}"
    printf 'local stratum 10\n'
  } > "${conf}"
  ensure_dir "${CHRONY_CONF_DIR}" 0755
  install_file "${conf}" "${CHRONY_CONF}" 0644 "chrony: serve ${net}${TIME_SOURCE:+, source ${TIME_SOURCE}}"
  if (( FILE_CHANGED )) && systemctl is-active --quiet chrony 2>/dev/null; then
    run systemctl restart chrony
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
  local ref="$1" first rest
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
      host_k3s_wait_ready
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
  host_node_files
  host_hosts_block
  host_chrony
  host_sync_tarballs
  host_k3s_reconcile
  host_import_images
}
