# shellcheck shell=bash
# backup.sh: backups on the node (DESIGN I-12).
#
# A backup is a directory /var/lib/teknoir-airgap/backups/<UTC> (0700; the
# last 3 are kept) holding:
#   db/harbor.sql.gz, db/keycloak.sql.gz   pg_dumpall through kubectl exec
#   k3s/db/ (sqlite: copied during a brief `systemctl stop k3s`; pods keep
#           running) or k3s/etcd-snapshot (k3s etcd-snapshot save)
#   k3s/server/{token,tls,cred}, k3s/etc/{config.yaml,registries.yaml}
#   secrets/bootstrap-secrets.json          the Secrets a restore needs first
#                                           (CA, Harbor, Keycloak, clients, ...)
#   BACKUP.info, SHA256SUMS
# It is written as <UTC>.partial and renamed only when complete.
#
# converge takes one automatically (phase backup) before changing a cluster
# that runs a different bundle than this one; a re-run of the deployed bundle
# takes none (it would rotate the useful pre-update backups out).
# `teknoir-node backup` takes one on demand; --export / --stream /
# --recipient hand the latest one to the LAN host age-encrypted (see
# cmd_backup). Nothing here prints secret values.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # jq programs use $variables in single quotes
# shellcheck source=common.sh
source "${NODE_ROOT}/lib/common.sh"

BACKUP_DIR="${STATE_DIR}/backups"
EXPORT_DIR="${STATE_DIR}/exports"
BACKUP_KEEP="${BACKUP_KEEP:-3}"
BACKUP_MODE="${BACKUP_MODE:-auto}"   # auto | always | never (converge --backup / --no-backup)
BACKUP_LAST=""
_K3S_STOPPED_FOR_BACKUP=0

# Secrets exported into every backup ("namespace name"); absent ones are
# skipped. The wildcard TLS is added at run time (its name follows the domain).
BACKUP_SECRETS=(
  "cert-manager teknoir-root-ca"
  "teknoir-system harbor-secret"
  "teknoir-system harbor-token-service"
  "teknoir-auth keycloak-db-secret"
  "teknoir-auth keycloak-admin"
  "teknoir-auth keycloak-platform-admin"
  "teknoir-auth keycloak-client-secrets"
  "teknoir-auth oauth2-proxy-secret"
  "teknoir-auth oauth2-proxy-redis-secret"
  "teknoir-system argocd-oidc-secret"
  "teknoir-system harbor-oidc-secret"
  "teknoir-system backstage-keycloak-secrets"
  "teknoir-system backstage-postgres-secrets"
  "teknoir-system backstage-backend-auth"
)

_backup_restart_k3s_if_stopped() {
  # Exit safety net: never leave k3s stopped after a failed sqlite copy.
  if (( _K3S_STOPPED_FOR_BACKUP == 1 )); then
    printf '%s [teknoir-node] restarting k3s after an interrupted backup\n' "$(date -u +%H:%M:%S)" >&2
    systemctl start k3s || true
    _K3S_STOPPED_FOR_BACKUP=0
  fi
}

backup_pg() {
  # backup_pg <ns> <label-selector> <container> <shell command> <out.sql.gz>
  local ns="$1" sel="$2" ctr="$3" cmd="$4" out="$5" pod size
  pod="$(kc -n "${ns}" get pods -l "${sel}" --field-selector=status.phase=Running -o 'jsonpath={.items[0].metadata.name}')" \
    || die "backup: cannot list pods ${sel} in ${ns}"
  if [[ -z "${pod}" ]]; then
    log "backup: no running pod ${sel} in ${ns}: not dumped"
    return 0
  fi
  log "backup: pg_dumpall ${ns}/${pod}"
  kc -n "${ns}" exec "${pod}" -c "${ctr}" -- sh -c "${cmd}" | gzip -c > "${out}" \
    || die "backup: pg_dumpall in ${ns}/${pod} failed"
  size="$(stat -c %s "${out}")"
  (( size > 200 )) || die "backup: the dump of ${ns}/${pod} is empty"
}

backup_secrets() {
  # backup_secrets <out.json> - one List of the bootstrap-tier Secrets, server
  # metadata stripped, written straight from a pipe into a 0600 file.
  local out="$1" entry ns name n=0
  local -a entries=("${BACKUP_SECRETS[@]}" "istio-system ${TEKNOIR_DOMAIN//./-}-wildcard-tls")
  ensure_work_dir
  : > "${WORK_DIR}/secrets.ndjson"
  for entry in "${entries[@]}"; do
    read -r ns name <<<"${entry}"
    in_cluster secret "${name}" "${ns}" || continue
    kc -n "${ns}" get secret "${name}" -o json \
      | "${JQ}" -c '{apiVersion, kind, type, data,
          metadata: {name: .metadata.name, namespace: .metadata.namespace, labels: (.metadata.labels // {})}}' \
      >> "${WORK_DIR}/secrets.ndjson" \
      || die "backup: cannot export Secret ${ns}/${name}"
    n=$(( n + 1 ))
  done
  ( umask 077 && "${JQ}" -s '{apiVersion: "v1", kind: "List", items: .}' "${WORK_DIR}/secrets.ndjson" > "${out}" ) \
    || die "backup: cannot write ${out}"
  shred -u "${WORK_DIR}/secrets.ndjson" 2>/dev/null || rm -f "${WORK_DIR}/secrets.ndjson"
  log "backup: ${n} Secrets exported"
}

backup_k3s() {
  # backup_k3s <dir> - datastore, token, tls, cred and the k3s config files.
  local out="$1" data f
  data="${HOST_ROOT}${K3S_DATA_DIR}"
  mkdir -p "${out}/server" "${out}/etc"
  for f in config.yaml registries.yaml; do
    [[ -f "${HOST_ROOT}/etc/rancher/k3s/${f}" ]] && cp -a "${HOST_ROOT}/etc/rancher/k3s/${f}" "${out}/etc/"
  done
  if [[ ! -d "${data}/server" ]]; then
    log "backup: no k3s server data in ${data}: datastore not copied"
    return 0
  fi
  for f in token tls cred; do
    [[ -e "${data}/server/${f}" ]] && cp -a "${data}/server/${f}" "${out}/server/"
  done
  if [[ -d "${data}/server/db/etcd" ]]; then
    log "backup: etcd snapshot"
    "${K3S_BIN}" etcd-snapshot save --data-dir "${K3S_DATA_DIR}" --dir "${out}" --name teknoir-backup >&2 \
      || die "backup: k3s etcd-snapshot save failed"
  elif [[ -f "${data}/server/db/state.db" ]]; then
    log "backup: stopping k3s briefly to copy the sqlite datastore (pods keep running)"
    _K3S_STOPPED_FOR_BACKUP=1
    systemctl stop k3s || die "backup: cannot stop k3s"
    cp -a "${data}/server/db" "${out}/db" || die "backup: copying ${data}/server/db failed (k3s is restarted at exit)"
    systemctl start k3s || die "backup: cannot start k3s again"
    _K3S_STOPPED_FOR_BACKUP=0
    host_k3s_wait_ready
  else
    log "backup: no datastore in ${data}/server/db"
  fi
}

backup_prune() {
  local old
  rm -rf "${BACKUP_DIR}"/*.partial
  while IFS= read -r old; do
    [[ -n "${old}" ]] || continue
    rm -rf "${old}"
    log "backup: pruned ${old}"
  done < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort -r | tail -n +$(( BACKUP_KEEP + 1 )))
}

backup_take() {
  # backup_take <label> - take a full backup; sets BACKUP_LAST.
  local label="$1" ts dir tmp
  ensure_work_dir
  mkdir -p "${BACKUP_DIR}"
  chmod 0700 "${BACKUP_DIR}"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="${BACKUP_DIR}/${ts}"
  tmp="${dir}.partial"
  [[ ! -e "${dir}" ]] || die "backup: ${dir} already exists"
  rm -rf "${BACKUP_DIR}"/*.partial
  ( umask 077 && mkdir -p "${tmp}/db" "${tmp}/k3s" "${tmp}/secrets" )
  at_exit "rm -rf $(printf '%q' "${tmp}")"
  at_exit "_backup_restart_k3s_if_stopped"
  log "backup (${label}) -> ${dir}"
  backup_pg teknoir-system "app=harbor,component=database" database 'pg_dumpall -U postgres' "${tmp}/db/harbor.sql.gz"
  backup_pg teknoir-auth "app=keycloak-db" postgres 'pg_dumpall -U "$POSTGRES_USER"' "${tmp}/db/keycloak.sql.gz"
  backup_secrets "${tmp}/secrets/bootstrap-secrets.json"
  backup_k3s "${tmp}/k3s"
  {
    printf 'createdAt=%s\n' "${ts}"
    printf 'label=%s\n' "${label}"
    printf 'bundleId=%s\n' "${BUNDLE_ID:-}"
    printf 'appOfAppsVersion=%s\n' "${APP_OF_APPS_VERSION:-}"
    printf 'k3s=%s\n' "$("${K3S_BIN}" --version 2>/dev/null | head -1 || true)"
    printf 'dataDir=%s\n' "${K3S_DATA_DIR}"
    printf 'domain=%s\n' "${TEKNOIR_DOMAIN}"
  } > "${tmp}/BACKUP.info"
  ( cd "${tmp}" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) > "${WORK_DIR}/backup.sums" \
    || die "backup: cannot checksum ${tmp}"
  mv -f "${WORK_DIR}/backup.sums" "${tmp}/SHA256SUMS"
  mv "${tmp}" "${dir}"
  chmod -R go-rwx "${dir}"
  backup_prune
  BACKUP_LAST="${dir}"
  log "backup complete: ${dir} ($(du -sh "${dir}" | cut -f1))"
}

phase_backup() {
  if ! cluster_up; then
    if [[ -e "${HOST_ROOT}${K3S_DATA_DIR}/server/db/state.db" || -d "${HOST_ROOT}${K3S_DATA_DIR}/server/db/etcd" ]]; then
      if [[ "${BACKUP_MODE}" == "never" ]]; then
        warn "the k3s API is down; no pre-change backup (--no-backup)"
        return 0
      fi
      dry_run && { warn "[dry-run] the k3s API is down: the pre-change backup would fail (--no-backup skips it)"; return 0; }
      die "a k3s datastore exists but the API is not reachable, so the pre-change backup cannot run; start k3s, or re-run with --no-backup"
    fi
    log "no cluster yet: nothing to back up"
    return 0
  fi
  case "${BACKUP_MODE}" in
    never)
      warn "pre-change backup skipped (--no-backup)"
      return 0
      ;;
    auto)
      release_load_record
      if [[ "${REC_SOURCE}" == "configmap" && "${REC_BUNDLE}" == "${BUNDLE_ID}" && "${REC_SHA}" == "${MANIFEST_SHA256}" ]]; then
        log "bundle ${BUNDLE_ID} is already deployed: no pre-change backup (--backup forces one)"
        return 0
      fi
      ;;
  esac
  if dry_run; then
    log "[dry-run] would take a pre-change backup into ${BACKUP_DIR}/<UTC> (pg_dumpall harbor + keycloak, k3s datastore with a brief k3s stop, token/tls/cred, bootstrap Secrets; keep ${BACKUP_KEEP})"
    return 0
  fi
  backup_take "pre-change to ${BUNDLE_ID}"
}

backup_latest() {
  find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' 2>/dev/null | sort | tail -1
}

cmd_backup() {
  # backup                      take a full backup now; prints its path on stdout
  # backup --list               list the backups
  # backup --export [--take]    age -p (passphrase from the terminal: run over
  #                             ssh -t) of the latest backup into
  #                             /var/lib/teknoir-airgap/exports/<name>.tar.age;
  #                             prints that path on stdout
  # backup --stream FILE [--keep]   write an export to stdout (never to a
  #                             terminal), then delete it unless --keep
  # backup --recipient AGE1... [--take]   stream the latest backup encrypted
  #                             to an age public key to stdout; no terminal needed
  local mode="take" file="" keep=0 take=0 recipient="" latest name out real
  while (( $# > 0 )); do
    case "$1" in
      --list) mode="list" ;;
      --export) mode="export" ;;
      --stream) [[ -n "${2:-}" ]] || die "backup: --stream needs a file"; mode="stream"; file="$2"; shift ;;
      --recipient) [[ -n "${2:-}" ]] || die "backup: --recipient needs an age public key"; mode="recipient"; recipient="$2"; shift ;;
      --keep) keep=1 ;;
      --take) take=1 ;;
      *) die "backup: unknown argument $1" ;;
    esac
    shift
  done
  case "${mode}" in
    list)
      [[ -d "${BACKUP_DIR}" ]] || { log "no backups yet"; return 0; }
      find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | while IFS= read -r d; do
        printf '%s %s %s\n' "$(basename "${d}")" "$(du -sh "${d}" | cut -f1)" "$(grep '^label=' "${d}/BACKUP.info" 2>/dev/null | cut -d= -f2-)"
      done
      return 0
      ;;
    take)
      require_cluster backup || return 0
      dry_run && { log "[dry-run] would take a full backup into ${BACKUP_DIR}/<UTC>"; return 0; }
      backup_take "on demand"
      printf '%s\n' "${BACKUP_LAST}"
      return 0
      ;;
    stream)
      [[ ! -t 1 ]] || die "backup --stream: refusing to write binary data to a terminal; redirect stdout"
      real="$(readlink -f "${file}")" || die "backup --stream: ${file} not found"
      [[ "$(dirname "${real}")" == "$(readlink -f "${EXPORT_DIR}")" && -f "${real}" ]] \
        || die "backup --stream: ${file} is not an export in ${EXPORT_DIR}"
      cat "${real}" || die "backup --stream: reading ${real} failed"
      if (( keep == 0 )); then
        rm -f "${real}"
        log "backup --stream: sent and removed ${real}"
      fi
      return 0
      ;;
  esac
  # export / recipient
  command -v "${AGE}" >/dev/null 2>&1 || die "backup: age not found (expected the bundled ${NODE_ROOT}/bin/age)"
  if (( take == 1 )); then
    require_cluster backup || return 0
    backup_take "for export"
  fi
  latest="$(backup_latest)"
  [[ -n "${latest}" ]] || die "backup: no backup yet (run teknoir-node backup, or add --take)"
  name="$(basename "${latest}")"
  if [[ "${mode}" == "recipient" ]]; then
    [[ "${recipient}" =~ ^age1[0-9a-z]{58}$ ]] || die "backup --recipient: not an age X25519 public key (age1...)"
    [[ ! -t 1 ]] || die "backup --recipient: refusing to write binary data to a terminal; redirect stdout"
    log "backup: streaming ${name} encrypted to ${recipient:0:12}..."
    tar -C "${BACKUP_DIR}" -cf - "${name}" | "${AGE}" -r "${recipient}" || die "backup: encrypting ${name} failed"
    return 0
  fi
  # export: age -p reads the passphrase from /dev/tty.
  [[ -r /dev/tty ]] || die "backup --export needs a terminal for the passphrase (ssh -t); or use --recipient"
  mkdir -p "${EXPORT_DIR}"
  chmod 0700 "${EXPORT_DIR}"
  out="${EXPORT_DIR}/teknoir-backup-${name}.tar.age"
  log "backup: encrypting ${name} with a passphrase (age -p); you are asked for it now"
  tar -C "${BACKUP_DIR}" -cf - "${name}" | "${AGE}" -p -o "${out}.partial" || { rm -f "${out}.partial"; die "backup: encryption failed"; }
  mv -f "${out}.partial" "${out}"
  chmod 0600 "${out}"
  log "backup: export ${out} ($(du -h "${out}" | cut -f1)); fetch it with: teknoir-node backup --stream ${out}"
  printf '%s\n' "${out}"
}
