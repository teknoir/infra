# shellcheck shell=bash
# backup.sh: backups on the node (DESIGN I-12).
#
# A backup is a directory /var/lib/teknoir-airgap/backups/<UTC> (0700) holding:
#   db/harbor.sql.gz, db/keycloak.sql.gz   pg_dumpall through kubectl exec
#   k3s/db/ (sqlite: copied during a brief `systemctl stop k3s`; pods keep
#           running) or k3s/etcd-snapshot (k3s etcd-snapshot save)
#   k3s/server/{token,tls,cred}, k3s/etc/{config.yaml,registries.yaml}
#   secrets/bootstrap-secrets.json          the Secrets a restore needs first
#                                           (CA, Harbor, Keycloak, clients, ...)
#   BACKUP.info, SHA256SUMS
# It is written as <UTC>.partial and renamed only when complete.
#
# Encryption (SEC-C8): when the site config sets BACKUP_AGE_RECIPIENTS
# (space-separated age X25519 public keys; public values, no secret), every
# backup is also written as /var/lib/teknoir-airgap/exports/<UTC>.tar.age
# (0600, encrypted to every recipient; .partial, then renamed). Then only the
# newest BACKUP_KEEP_PLAIN (default 1) plaintext sets stay, and BACKUP_KEEP
# (default 3) encrypted exports. An older plaintext set without an export is
# encrypted before it is pruned, and kept if that fails. Without recipients
# the node keeps BACKUP_KEEP plaintext sets, as before, and warns. The node
# never holds an age identity: decryption happens off the node.
#
# converge takes one automatically (phase backup) before changing a cluster
# that runs a different bundle than this one; a re-run of the deployed bundle
# takes none (it would rotate the useful pre-update backups out), and neither
# does a first install that has not reached the release phase yet. A database
# without a running pod is skipped with a warning (BACKUP.info databases=).
# `teknoir-node backup` takes one on demand; --recipient-site / --export /
# --stream / --recipient hand one to the LAN host age-encrypted (see
# cmd_backup). Nothing here prints secret values.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # jq programs use $variables in single quotes
# shellcheck source=common.sh
source "${NODE_ROOT}/lib/common.sh"

BACKUP_DIR="${STATE_DIR}/backups"
EXPORT_DIR="${STATE_DIR}/exports"
BACKUP_KEEP="${BACKUP_KEEP:-3}"              # encrypted exports (plaintext sets without recipients)
BACKUP_KEEP_PLAIN="${BACKUP_KEEP_PLAIN:-1}"  # plaintext sets when BACKUP_AGE_RECIPIENTS is set
BACKUP_MODE="${BACKUP_MODE:-auto}"   # auto | always | never (converge --backup / --no-backup)
BACKUP_LAST=""
BACKUP_LAST_EXPORT=""
BACKUP_RECIPIENTS=()
BACKUP_DBS=()
_K3S_STOPPED_FOR_BACKUP=0
BACKUP_NAME_RE='^[0-9]{8}T[0-9]{6}Z$'

# Secrets exported into every backup ("namespace name"); absent ones are
# skipped. The wildcard TLS is added at run time (its name follows the domain).
BACKUP_SECRETS=(
  "cert-manager teknoir-root-ca"
  "teknoir-system harbor-secret"
  "teknoir-system harbor-token-service"
  "teknoir-auth keycloak-db-secret"
  "teknoir-auth keycloak-admin"
  "teknoir-auth keycloak-client-secrets"
  "teknoir-auth oauth2-proxy-secret"
  "teknoir-auth oauth2-proxy-redis-secret"
  "teknoir-system argocd-oidc-secret"
  "teknoir-system harbor-oidc-secret"
  "teknoir-system backstage-keycloak-secrets"
  "teknoir-system backstage-postgres-secrets"
  "teknoir-system backstage-backend-auth"
  "teknoir-system argocd-admin-break-glass"
)

_backup_restart_k3s_if_stopped() {
  # Exit safety net: never leave k3s stopped after a failed sqlite copy.
  if (( _K3S_STOPPED_FOR_BACKUP == 1 )); then
    printf '%s [teknoir-node] restarting k3s after an interrupted backup\n' "$(date -u +%H:%M:%S)" >&2
    systemctl start k3s || true
    _K3S_STOPPED_FOR_BACKUP=0
  fi
}

backup_recipients_load() {
  # backup_recipients_load - BACKUP_RECIPIENTS from the site's
  # BACKUP_AGE_RECIPIENTS (space-separated). Dies on an invalid entry (the
  # one validator, site_age_recipients_check in lib/common.sh, that load_site
  # already ran: it never echoes a private key); returns 1 when none is set.
  local problem
  problem="$(site_age_recipients_check "${BACKUP_AGE_RECIPIENTS:-}")" \
    || die "${SITE_FILE:-the site config}: ${problem}"
  BACKUP_RECIPIENTS=()
  read -r -a BACKUP_RECIPIENTS <<<"${BACKUP_AGE_RECIPIENTS:-}"
  (( ${#BACKUP_RECIPIENTS[@]} > 0 ))
}

backup_keep_check() {
  local v
  for v in BACKUP_KEEP BACKUP_KEEP_PLAIN; do
    [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "backup: ${v} must be a whole number of at least 1 (got '${!v}')"
  done
}

backup_need_age() {
  command -v "${AGE}" >/dev/null 2>&1 || die "backup: age not found (expected the bundled ${NODE_ROOT}/bin/age)"
}

backup_encrypt() {
  # backup_encrypt <ts> - EXPORT_DIR/<ts>.tar.age (0600): the set backups/<ts>
  # as a tar stream, encrypted with age to every BACKUP_RECIPIENTS key. It is
  # written as <ts>.tar.age.partial and renamed only after age succeeded, so a
  # failed or interrupted run never leaves a file that looks complete. An
  # existing export of the set is replaced (re-encrypted to the current
  # recipients). Returns 1 on failure, with no partial file left.
  local ts="$1" out part r
  local -a rargs=()
  for r in ${BACKUP_RECIPIENTS[@]+"${BACKUP_RECIPIENTS[@]}"}; do rargs+=(-r "${r}"); done
  (( ${#rargs[@]} > 0 )) || die "internal: backup_encrypt without recipients"
  [[ -d "${BACKUP_DIR}/${ts}" ]] || die "backup: no backup ${ts} in ${BACKUP_DIR}"
  backup_need_age
  ( umask 077 && mkdir -p "${EXPORT_DIR}" )
  chmod 0700 "${EXPORT_DIR}"
  out="${EXPORT_DIR}/${ts}.tar.age"
  part="${out}.partial"
  rm -f "${part}"
  at_exit "rm -f $(printf '%q' "${part}")"
  if ! ( umask 077 && tar -C "${BACKUP_DIR}" -cf - "${ts}" | "${AGE}" "${rargs[@]}" -o "${part}" ); then
    rm -f "${part}"
    return 1
  fi
  if [[ ! -s "${part}" ]]; then
    rm -f "${part}"
    return 1
  fi
  chmod 0600 "${part}"
  mv -f "${part}" "${out}"
  log "backup: ${ts} encrypted to ${#BACKUP_RECIPIENTS[@]} age recipient(s): ${out} ($(du -h "${out}" | cut -f1))"
}

backup_pg() {
  # backup_pg <ns> <label-selector> <container> <shell command> <out.sql.gz>
  # A database without a running pod (not deployed yet, or restarting) is not
  # dumped: warned, and left out of BACKUP.info's databases list.
  local ns="$1" sel="$2" ctr="$3" cmd="$4" out="$5" pods pod size
  # {.items[*]}, not {.items[0]}: on an empty list the index form fails
  # (array index out of bounds), which would read as a listing error.
  pods="$(kc -n "${ns}" get pods -l "${sel}" --field-selector=status.phase=Running -o 'jsonpath={.items[*].metadata.name}')" \
    || die "backup: cannot list pods ${sel} in ${ns}"
  pod="${pods%% *}"
  if [[ -z "${pod}" ]]; then
    warn "backup: no running pod ${sel} in ${ns}: that database is NOT in this backup"
    return 0
  fi
  log "backup: pg_dumpall ${ns}/${pod}"
  kc -n "${ns}" exec "${pod}" -c "${ctr}" -- sh -c "${cmd}" | gzip -c > "${out}" \
    || die "backup: pg_dumpall in ${ns}/${pod} failed"
  size="$(stat -c %s "${out}")"
  (( size > 200 )) || die "backup: the dump of ${ns}/${pod} is empty"
  BACKUP_DBS+=("$(basename "${out}" .sql.gz)")
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
  # embedded etcd keeps its data in db/etcd/member; k3s on sqlite also creates
  # db/etcd (holding only a name file), so that directory alone means nothing
  if [[ -d "${data}/server/db/etcd/member" ]]; then
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
    host_k3s_wait_settled
  else
    log "backup: no datastore in ${data}/server/db"
  fi
}

backup_prune() {
  # Plaintext sets: keep BACKUP_KEEP, or BACKUP_KEEP_PLAIN with recipients; a
  # set to prune that has no encrypted export yet is encrypted first (and
  # kept when that fails). Encrypted exports <ts>.tar.age: keep BACKUP_KEEP.
  # Passphrase exports (teknoir-backup-*.tar.age) wait for the LAN host's
  # --stream and are not touched here.
  local old ts keep="${BACKUP_KEEP}" encrypt=0
  local -a olds=()
  rm -rf "${BACKUP_DIR}"/*.partial
  rm -f "${EXPORT_DIR}"/*.partial 2>/dev/null || true
  if (( ${#BACKUP_RECIPIENTS[@]} > 0 )); then
    keep="${BACKUP_KEEP_PLAIN}"
    encrypt=1
  fi
  while IFS= read -r old; do
    [[ -n "${old}" ]] && olds+=("${old}")
  done < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort -r | tail -n +$(( keep + 1 )))
  for old in ${olds[@]+"${olds[@]}"}; do
    ts="$(basename "${old}")"
    if (( encrypt == 1 )) && [[ ! -f "${EXPORT_DIR}/${ts}.tar.age" ]]; then
      if ! backup_encrypt "${ts}"; then
        warn "backup: encrypting the older backup ${ts} failed; it stays unencrypted in ${BACKUP_DIR}"
        continue
      fi
    fi
    rm -rf "${old}"
    log "backup: pruned ${old}"
  done
  [[ -d "${EXPORT_DIR}" ]] || return 0
  olds=()
  while IFS= read -r old; do
    [[ -n "${old}" ]] && olds+=("${old}")
  done < <(find "${EXPORT_DIR}" -mindepth 1 -maxdepth 1 -type f -name '2*Z.tar.age' | sort -r | tail -n +$(( BACKUP_KEEP + 1 )))
  for old in ${olds[@]+"${olds[@]}"}; do
    rm -f "${old}"
    log "backup: pruned ${old}"
  done
}

backup_take() {
  # backup_take <label> - take a full backup; sets BACKUP_LAST and, with
  # BACKUP_AGE_RECIPIENTS, BACKUP_LAST_EXPORT (its encrypted export).
  local label="$1" ts dir tmp
  # settings first: nothing (k3s least of all) is stopped for a backup that
  # could not be encrypted as configured
  backup_keep_check
  if backup_recipients_load; then
    backup_need_age
  fi
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
  BACKUP_DBS=()
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
    printf 'databases=%s\n' "${BACKUP_DBS[*]}"
  } > "${tmp}/BACKUP.info"
  ( cd "${tmp}" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) > "${WORK_DIR}/backup.sums" \
    || die "backup: cannot checksum ${tmp}"
  mv -f "${WORK_DIR}/backup.sums" "${tmp}/SHA256SUMS"
  mv "${tmp}" "${dir}"
  chmod -R go-rwx "${dir}"
  BACKUP_LAST="${dir}"
  BACKUP_LAST_EXPORT=""
  if (( ${#BACKUP_RECIPIENTS[@]} > 0 )); then
    backup_encrypt "${ts}" \
      || die "backup: encrypting ${ts} with age failed; the unencrypted backup ${dir} is complete and nothing was pruned"
    BACKUP_LAST_EXPORT="${EXPORT_DIR}/${ts}.tar.age"
  else
    warn "backup: BACKUP_AGE_RECIPIENTS is not set in the site config, so this backup exists only unencrypted on the node (OPERATE.md section 10)"
  fi
  backup_prune
  log "backup complete: ${dir} ($(du -sh "${dir}" | cut -f1))${BACKUP_LAST_EXPORT:+, encrypted export ${BACKUP_LAST_EXPORT}}"
}

phase_backup() {
  if ! cluster_up; then
    if [[ -e "${HOST_ROOT}${K3S_DATA_DIR}/server/db/state.db" || -d "${HOST_ROOT}${K3S_DATA_DIR}/server/db/etcd/member" ]]; then
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
      if [[ "${REC_SOURCE}" == "none" ]]; then
        # No release record and no root Application: nothing was deployed
        # yet (a first install, or a re-run of one interrupted before the
        # release phase). The DBs may not even exist; the CA and the
        # platform Secrets are create-if-absent, so a re-run keeps them.
        log "no release deployed yet (first install): no pre-change backup (--backup forces one)"
        return 0
      fi
      if [[ "${REC_SOURCE}" == "configmap" && "${REC_BUNDLE}" == "${BUNDLE_ID}" && "${REC_SHA}" == "${MANIFEST_SHA256}" ]]; then
        log "bundle ${BUNDLE_ID} is already deployed: no pre-change backup (--backup forces one)"
        return 0
      fi
      ;;
  esac
  if dry_run; then
    backup_keep_check
    if backup_recipients_load; then
      log "[dry-run] would take a pre-change backup into ${BACKUP_DIR}/<UTC> (pg_dumpall harbor + keycloak, k3s datastore with a brief k3s stop, token/tls/cred, bootstrap Secrets), encrypt it to ${#BACKUP_RECIPIENTS[@]} age recipient(s) into ${EXPORT_DIR}/<UTC>.tar.age, and keep ${BACKUP_KEEP_PLAIN} unencrypted set(s) and ${BACKUP_KEEP} encrypted export(s)"
    else
      log "[dry-run] would take a pre-change backup into ${BACKUP_DIR}/<UTC> (pg_dumpall harbor + keycloak, k3s datastore with a brief k3s stop, token/tls/cred, bootstrap Secrets; keep ${BACKUP_KEEP}); no BACKUP_AGE_RECIPIENTS, so not encrypted"
    fi
    return 0
  fi
  backup_take "pre-change to ${BUNDLE_ID}"
}

backup_latest() {
  find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' 2>/dev/null | sort | tail -1
}

cmd_backup() {
  # backup                      take a full backup now (with BACKUP_AGE_RECIPIENTS
  #                             also its encrypted export); prints the backup
  #                             directory on stdout
  # backup --list               list the backups and the encrypted exports
  # backup --recipient-site [--take | --name TS]
  #                             encrypt a new (--take), the named or the latest
  #                             backup to the site's BACKUP_AGE_RECIPIENTS into
  #                             /var/lib/teknoir-airgap/exports/<ts>.tar.age (an
  #                             existing export is re-encrypted to the current
  #                             list) and print that path on stdout; no terminal
  #                             needed (teknoir-airgap backup --out DIR uses it)
  # backup --export [--take | --name TS]
  #                             age -p (passphrase from the terminal: run over
  #                             ssh -t) into exports/teknoir-backup-<ts>.tar.age;
  #                             prints that path on stdout
  # backup --stream FILE [--keep]   write an export to stdout (never to a
  #                             terminal), then delete it unless --keep
  # backup --recipient AGE1... [--recipient AGE1...] [--take | --name TS]
  #                             stream a backup encrypted to these age public
  #                             keys to stdout; no terminal needed
  local mode="take" file="" keep=0 take=0 name="" out real d f r
  local -a recipients=() rargs=() ws=()
  while (( $# > 0 )); do
    case "$1" in
      --list) mode="list" ;;
      --export) mode="export" ;;
      --recipient-site) mode="recipient-site" ;;
      --stream) [[ -n "${2:-}" ]] || die "backup: --stream needs a file"; mode="stream"; file="$2"; shift ;;
      --recipient) [[ -n "${2:-}" ]] || die "backup: --recipient needs an age public key"; mode="recipient"; recipients+=("$2"); shift ;;
      --name) [[ -n "${2:-}" ]] || die "backup: --name needs a backup name (teknoir-node backup --list)"; name="$2"; shift ;;
      --keep) keep=1 ;;
      --take) take=1 ;;
      *) die "backup: unknown argument $1" ;;
    esac
    shift
  done
  if (( ${#recipients[@]} > 0 )) && [[ "${mode}" != "recipient" ]]; then
    die "backup: --recipient goes with no other mode (--list, --export, --recipient-site, --stream)"
  fi
  if [[ -n "${name}" ]]; then
    [[ "${mode}" =~ ^(export|recipient|recipient-site)$ ]] || die "backup: --name goes with --recipient-site, --recipient or --export"
    (( take == 0 )) || die "backup: --take and --name exclude each other"
    [[ "${name}" =~ ${BACKUP_NAME_RE} ]] || die "backup: --name ${name}: a backup name is a UTC timestamp such as 20261009T051050Z (teknoir-node backup --list)"
  fi
  case "${mode}" in
    list)
      [[ -d "${BACKUP_DIR}" || -d "${EXPORT_DIR}" ]] || { log "no backups yet"; return 0; }
      if [[ -d "${BACKUP_DIR}" ]]; then
        find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | while IFS= read -r d; do
          printf '%s %s %s\n' "$(basename "${d}")" "$(du -sh "${d}" | cut -f1)" "$(grep '^label=' "${d}/BACKUP.info" 2>/dev/null | cut -d= -f2-)"
        done
      fi
      if [[ -d "${EXPORT_DIR}" ]]; then
        find "${EXPORT_DIR}" -mindepth 1 -maxdepth 1 -type f -name '*.tar.age' | sort | while IFS= read -r f; do
          printf '%s %s %s\n' "$(basename "${f}")" "$(du -h "${f}" | cut -f1)" "encrypted export (age)"
        done
      fi
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
  # recipient-site / recipient / export: check the keys before any backup is taken
  case "${mode}" in
    recipient-site)
      backup_recipients_load \
        || die "backup --recipient-site: BACKUP_AGE_RECIPIENTS is not set in ${SITE_FILE:-the site config} (space-separated age public keys)"
      ;;
    recipient)
      for f in "${recipients[@]}"; do
        d="$(site_age_recipients_check "${f}" "--recipient")" || die "backup: ${d}"
        read -r -a ws <<<"${f}"
        for r in ${ws[@]+"${ws[@]}"}; do rargs+=(-r "${r}"); done
      done
      (( ${#rargs[@]} > 0 )) || die "backup: --recipient needs an age public key"
      [[ ! -t 1 ]] || die "backup --recipient: refusing to write binary data to a terminal; redirect stdout"
      ;;
  esac
  backup_need_age
  if dry_run; then
    d="${name:-the latest backup}"
    (( take == 0 )) || d="a new backup"
    log "[dry-run] backup --${mode}: would encrypt ${d}; nothing changed"
    return 0
  fi
  if (( take == 1 )); then
    require_cluster backup || return 0
    backup_take "for export"
    name="$(basename "${BACKUP_LAST}")"
  elif [[ -n "${name}" ]]; then
    if [[ ! -d "${BACKUP_DIR}/${name}" ]]; then
      # pruned to its encrypted export: hand that out as it is
      if [[ "${mode}" == "recipient-site" && -f "${EXPORT_DIR}/${name}.tar.age" ]]; then
        log "backup: ${name} exists only encrypted (to the recipients of its day): ${EXPORT_DIR}/${name}.tar.age"
        printf '%s\n' "${EXPORT_DIR}/${name}.tar.age"
        return 0
      fi
      die "backup: no backup ${name} in ${BACKUP_DIR} (teknoir-node backup --list)"
    fi
  else
    d="$(backup_latest)"
    [[ -n "${d}" ]] || die "backup: no backup yet (run teknoir-node backup, or add --take)"
    name="$(basename "${d}")"
  fi
  case "${mode}" in
    recipient-site)
      out="${EXPORT_DIR}/${name}.tar.age"
      if [[ "${BACKUP_LAST_EXPORT}" != "${out}" ]]; then
        backup_encrypt "${name}" || die "backup: encrypting ${name} with age failed"
      fi
      printf '%s\n' "${out}"
      return 0
      ;;
    recipient)
      log "backup: streaming ${name} encrypted to ${#recipients[@]} age recipient(s)"
      tar -C "${BACKUP_DIR}" -cf - "${name}" | "${AGE}" "${rargs[@]}" || die "backup: encrypting ${name} failed"
      return 0
      ;;
  esac
  # export: age -p reads the passphrase from /dev/tty.
  [[ -r /dev/tty ]] || die "backup --export needs a terminal for the passphrase (ssh -t); or use --recipient-site"
  ( umask 077 && mkdir -p "${EXPORT_DIR}" )
  chmod 0700 "${EXPORT_DIR}"
  out="${EXPORT_DIR}/teknoir-backup-${name}.tar.age"
  at_exit "rm -f $(printf '%q' "${out}.partial")"
  log "backup: encrypting ${name} with a passphrase (age -p); you are asked for it now"
  ( umask 077 && tar -C "${BACKUP_DIR}" -cf - "${name}" | "${AGE}" -p -o "${out}.partial" ) \
    || { rm -f "${out}.partial"; die "backup: encryption failed"; }
  chmod 0600 "${out}.partial"
  mv -f "${out}.partial" "${out}"
  log "backup: export ${out} ($(du -h "${out}" | cut -f1)); fetch it with: teknoir-node backup --stream ${out}"
  printf '%s\n' "${out}"
}
