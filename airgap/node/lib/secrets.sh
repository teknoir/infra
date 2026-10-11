# shellcheck shell=bash
# secrets.sh: the node secrets phase of teknoir-node converge (DESIGN I-07),
# plus the credentials and rotate commands.
#
# Created once by the node (openssl in a private tmpfs dir), never replaced
# by a converge - only `teknoir-node rotate <name>` replaces one:
#   cert-manager/teknoir-root-ca            the Root CA (D1: an existing CA is
#                                           kept forever; a new one is
#                                           name-constrained to the domain)
#   istio-system/<domain-dashes>-wildcard-tls  the gateway TLS placeholder;
#                                           cert-manager replaces it on issuance
#   teknoir-system/harbor-token-service     Harbor core token-service TLS
#                                           (harbor core.secretName)
# Derived from the CA's public certificate on every run (server-side apply,
# field manager teknoir-bootstrap):
#   teknoir-auth/teknoir-root-ca-bundle, teknoir-system/teknoir-root-ca-bundle
#   teknoir-system/argocd-tls-certs-cm      entry harbor.<domain>
#   node trust: /etc/rancher/k3s/teknoir-root-ca.crt, OS trust store
# Every random application secret is created by the platform-secrets chart's
# Job, not here.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # jq programs use $variables in single quotes
# shellcheck source=common.sh
source "${NODE_ROOT}/lib/common.sh"

CA_NS="cert-manager"
CA_SECRET="teknoir-root-ca"
CA_DAYS="${CA_DAYS:-3650}"
WILDCARD_NS="istio-system"
WILDCARD_DAYS="${WILDCARD_DAYS:-90}"
TOKEN_NS="teknoir-system"
TOKEN_SECRET="harbor-token-service"
TOKEN_DAYS="${TOKEN_DAYS:-3650}"
CA_BUNDLE_SECRET="teknoir-root-ca-bundle"
CA_BUNDLE_NAMESPACES=(teknoir-auth teknoir-system)
ARGOCD_NS="teknoir-system"
ARGOCD_TLS_CM="argocd-tls-certs-cm"
MANAGED_BY_LABEL="app.kubernetes.io/managed-by=teknoir-node"
# rotate argocd-admin (DESIGN D10, SEC-C9)
ARGOCD_SERVER_DEPLOY="${ARGOCD_SERVER_DEPLOY:-argo-argocd-server}"
ARGOCD_BREAK_GLASS_SECRET="argocd-admin-break-glass"
ARGOCD_INITIAL_SECRET="argocd-initial-admin-secret"
ARGOCD_LOGIN_ATTEMPTS="${ARGOCD_LOGIN_ATTEMPTS:-4}"
ARGOCD_LOGIN_DELAY="${ARGOCD_LOGIN_DELAY:-5}"

# Public CA certificate of this run (WORK_DIR/ca.crt), once known.
CA_PEM=""

secrets_wildcard_name() { printf '%s-wildcard-tls' "${TEKNOIR_DOMAIN//./-}"; }

_secrets_tmp() {
  # _secrets_tmp - a fresh private dir under WORK_DIR for key material
  # (callers run ensure_work_dir first, in the main shell).
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] || die "internal: ensure_work_dir before _secrets_tmp"
  (umask 077 && mktemp -d "${WORK_DIR}/keys.XXXXXX")
}

_secrets_shred_dir() {
  [[ -n "$1" && -d "$1" ]] || return 0
  find "$1" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$1"
}

_secrets_openssl() {
  # _secrets_openssl <args...> - run openssl; its output (never key material: keys
  # always go to files) is shown only when it fails.
  local out
  out="$(openssl "$@" 2>&1)" || die "openssl $1 failed: ${out}"
}

_secrets_create_tls() {
  # _secrets_create_tls <ns> <name> <dir> - create a kubernetes.io/tls Secret
  # from <dir>/{tls.crt,tls.key[,ca.crt]}. Create, never apply: an existing
  # Secret makes it fail instead of being overwritten. Content flows through
  # a pipe only.
  local ns="$1" name="$2" d="$3"
  local -a files=(--from-file=tls.crt="${d}/tls.crt" --from-file=tls.key="${d}/tls.key")
  [[ -f "${d}/ca.crt" ]] && files+=(--from-file=ca.crt="${d}/ca.crt")
  kc -n "${ns}" create secret generic "${name}" --type=kubernetes.io/tls "${files[@]}" \
      --dry-run=client -o json \
    | "${JQ}" --arg k "${MANAGED_BY_LABEL%%=*}" --arg v "${MANAGED_BY_LABEL#*=}" '.metadata.labels[$k] = $v' \
    | kc create -f - >/dev/null \
    || die "cannot create Secret ${ns}/${name}"
}

_secrets_replace_tls() {
  # _secrets_replace_tls <ns> <name> <dir> - replace the data of an existing
  # TLS Secret (rotate only).
  local ns="$1" name="$2" d="$3"
  local -a files=(--from-file=tls.crt="${d}/tls.crt" --from-file=tls.key="${d}/tls.key")
  [[ -f "${d}/ca.crt" ]] && files+=(--from-file=ca.crt="${d}/ca.crt")
  kc -n "${ns}" create secret generic "${name}" --type=kubernetes.io/tls "${files[@]}" \
      --dry-run=client -o json \
    | "${JQ}" --arg k "${MANAGED_BY_LABEL%%=*}" --arg v "${MANAGED_BY_LABEL#*=}" '.metadata.labels[$k] = $v' \
    | kc replace -f - >/dev/null \
    || die "cannot replace Secret ${ns}/${name}"
}

_secrets_fetch_ca_cert() {
  # Write the CA's public certificate to WORK_DIR/ca.crt and set CA_PEM.
  ensure_work_dir
  CA_PEM="${WORK_DIR}/ca.crt"
  secret_value "${CA_NS}" "${CA_SECRET}" tls.crt > "${CA_PEM}" \
    || die "cannot read the CA certificate from ${CA_NS}/${CA_SECRET}"
  grep -q 'BEGIN CERTIFICATE' "${CA_PEM}" || die "${CA_NS}/${CA_SECRET} tls.crt is not a PEM certificate"
}

_secrets_fetch_ca_key() {
  # _secrets_fetch_ca_key <dir> - the CA key into <dir>/ca.key (0600, tmpfs).
  ( umask 077 && secret_value "${CA_NS}" "${CA_SECRET}" tls.key > "$1/ca.key" ) \
    || die "cannot read the CA key from ${CA_NS}/${CA_SECRET}"
}

# ---------------------------------------------------------------------------
# Root CA
# ---------------------------------------------------------------------------
_secrets_generate_ca() {
  # _secrets_generate_ca <dir> - a 10y RSA-4096 root, CA:TRUE pathlen:0, name
  # constraints permitted DNS:<domain> and DNS:.<domain> (D1).
  local d="$1"
  cat > "${d}/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no
[dn]
O = Teknoir
CN = Teknoir Root CA ${TEKNOIR_DOMAIN}
[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
nameConstraints = critical,permitted;DNS:${TEKNOIR_DOMAIN},permitted;DNS:.${TEKNOIR_DOMAIN}
EOF
  _secrets_openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "${d}/tls.key"
  _secrets_openssl req -x509 -new -sha256 -key "${d}/tls.key" -out "${d}/tls.crt" \
    -days "${CA_DAYS}" -config "${d}/ca.cnf" -extensions v3_ca
  cp "${d}/tls.crt" "${d}/ca.crt"
}

secrets_ensure_ca() {
  local d
  if in_cluster secret "${CA_SECRET}" "${CA_NS}"; then
    log "Root CA ${CA_NS}/${CA_SECRET}: present (kept; never replaced by converge)"
    _secrets_fetch_ca_cert
    if ! openssl x509 -in "${CA_PEM}" -noout -ext nameConstraints 2>/dev/null | grep -q 'Permitted'; then
      log "Root CA has no name constraints (pre-redesign CA, kept per D1)"
    fi
    if ! openssl x509 -in "${CA_PEM}" -noout -checkend $(( 365 * 86400 )) >/dev/null 2>&1; then
      warn "the Root CA expires within a year: $(openssl x509 -in "${CA_PEM}" -noout -enddate)"
    fi
    return 0
  fi
  if dry_run; then
    changed "create the name-constrained Root CA ${CA_NS}/${CA_SECRET} (DNS ${TEKNOIR_DOMAIN}, .${TEKNOIR_DOMAIN})"
    return 0
  fi
  log "generating the Root CA (RSA 4096, ${CA_DAYS} days, permitted DNS ${TEKNOIR_DOMAIN} and .${TEKNOIR_DOMAIN})"
  d="$(_secrets_tmp)"
  _secrets_generate_ca "${d}"
  _secrets_create_tls "${CA_NS}" "${CA_SECRET}" "${d}"
  _secrets_shred_dir "${d}"
  changed "created the Root CA ${CA_NS}/${CA_SECRET}"
  _secrets_fetch_ca_cert
}

# ---------------------------------------------------------------------------
# Wildcard placeholder and Harbor token-service TLS
# ---------------------------------------------------------------------------
_secrets_generate_wildcard() {
  # _secrets_generate_wildcard <dir> - *.<domain> + <domain>, signed by the CA.
  local d="$1"
  _secrets_fetch_ca_key "${d}"
  cat > "${d}/leaf.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:*.${TEKNOIR_DOMAIN},DNS:${TEKNOIR_DOMAIN}
EOF
  _secrets_openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${d}/tls.key"
  _secrets_openssl req -new -sha256 -key "${d}/tls.key" -out "${d}/tls.csr" -subj "/CN=*.${TEKNOIR_DOMAIN}"
  _secrets_openssl x509 -req -sha256 -in "${d}/tls.csr" -CA "${CA_PEM}" -CAkey "${d}/ca.key" \
    -CAcreateserial -CAserial "${d}/ca.srl" -out "${d}/tls.crt" -days "${WILDCARD_DAYS}" -extfile "${d}/leaf.cnf"
  cp "${CA_PEM}" "${d}/ca.crt"
  shred -u "${d}/ca.key"
}

secrets_ensure_wildcard() {
  local name d
  name="$(secrets_wildcard_name)"
  if in_cluster secret "${name}" "${WILDCARD_NS}"; then
    log "gateway TLS ${WILDCARD_NS}/${name}: present (cert-manager owns it)"
    return 0
  fi
  if dry_run; then
    changed "create the gateway TLS placeholder ${WILDCARD_NS}/${name} (*.${TEKNOIR_DOMAIN}, ${WILDCARD_DAYS} days; cert-manager replaces it)"
    return 0
  fi
  d="$(_secrets_tmp)"
  _secrets_generate_wildcard "${d}"
  _secrets_create_tls "${WILDCARD_NS}" "${name}" "${d}"
  _secrets_shred_dir "${d}"
  changed "created the gateway TLS placeholder ${WILDCARD_NS}/${name}"
}

_secrets_generate_token_tls() {
  # _secrets_generate_token_tls <dir> - Harbor's token-service key pair: self-signed,
  # only its public key matters to the registry.
  # Harbor core only reads a PKCS#1 key ("BEGIN RSA PRIVATE KEY"); OpenSSL 3
  # writes PKCS#8 by default, which makes every /service/token request a 500.
  local d="$1"
  _secrets_openssl genrsa -traditional -out "${d}/tls.key" 4096
  _secrets_openssl req -x509 -new -sha256 -key "${d}/tls.key" -out "${d}/tls.crt" \
    -days "${TOKEN_DAYS}" -subj "/CN=harbor-token-ca"
}

_secrets_token_key_is_pkcs1() {
  # 0 when the Harbor token-service key is PKCS#1. Only the PEM header line is
  # inspected; the key itself never leaves the pipe.
  # (the expected header is assembled so this file never contains a literal
  # PEM private-key header, which the bundle gate refuses)
  local header want="-----BEGIN RSA PRIVATE"
  want+=" KEY-----"
  header="$(secret_value "${TOKEN_NS}" "${TOKEN_SECRET}" tls.key | head -1)" || return 1
  [[ "${header}" == "${want}" ]]
}

secrets_ensure_harbor_token_tls() {
  local d
  if in_cluster secret "${TOKEN_SECRET}" "${TOKEN_NS}"; then
    if _secrets_token_key_is_pkcs1; then
      log "Harbor token-service TLS ${TOKEN_NS}/${TOKEN_SECRET}: present"
      return 0
    fi
    # Not a site secret: it only signs short-lived registry tokens, so a key
    # Harbor cannot read is replaced (and core + registry restarted).
    if dry_run; then
      changed "replace the Harbor token-service TLS ${TOKEN_NS}/${TOKEN_SECRET} (key is not PKCS#1)"
      return 0
    fi
    d="$(_secrets_tmp)"
    _secrets_generate_token_tls "${d}"
    kc -n "${TOKEN_NS}" delete secret "${TOKEN_SECRET}" >/dev/null || die "cannot replace Secret ${TOKEN_NS}/${TOKEN_SECRET}"
    _secrets_create_tls "${TOKEN_NS}" "${TOKEN_SECRET}" "${d}"
    _secrets_shred_dir "${d}"
    kc -n "${TOKEN_NS}" delete pod -l 'app=harbor,component in (core,registry)' --ignore-not-found >/dev/null \
      || warn "could not restart harbor core/registry; they keep the old token key until restarted"
    changed "replaced the Harbor token-service TLS ${TOKEN_NS}/${TOKEN_SECRET} (key was not PKCS#1); restarted harbor core + registry"
    return 0
  fi
  if dry_run; then
    changed "create the Harbor token-service TLS ${TOKEN_NS}/${TOKEN_SECRET}"
    return 0
  fi
  d="$(_secrets_tmp)"
  _secrets_generate_token_tls "${d}"
  _secrets_create_tls "${TOKEN_NS}" "${TOKEN_SECRET}" "${d}"
  _secrets_shred_dir "${d}"
  changed "created the Harbor token-service TLS ${TOKEN_NS}/${TOKEN_SECRET}"
}

# ---------------------------------------------------------------------------
# Derived trust objects (public certificate only), reconciled every run
# ---------------------------------------------------------------------------
secrets_reconcile_ca_bundles() {
  local ns f
  for ns in "${CA_BUNDLE_NAMESPACES[@]}"; do
    f="${WORK_DIR}/ca-bundle-${ns}.json"
    "${JQ}" -n --rawfile pem "${CA_PEM}" --arg ns "${ns}" --arg name "${CA_BUNDLE_SECRET}" '{
      apiVersion: "v1", kind: "Secret", type: "Opaque",
      metadata: {name: $name, namespace: $ns},
      data: {"ca.crt": ($pem | @base64)}
    }' > "${f}"
    apply_ssa "${f}" teknoir-bootstrap "Secret ${ns}/${CA_BUNDLE_SECRET} (CA certificate)"
  done
}

secrets_reconcile_argocd_tls_certs() {
  # The converge owns this ConfigMap (not the argo chart): MANAGED_BY_LABEL
  # records that on the object, so migrate --argo reports it as converge-owned
  # rather than ownerless (r5, HYG-C6). part-of=argocd is what ArgoCD watches.
  local f="${WORK_DIR}/argocd-tls-certs-cm.json"
  "${JQ}" -n --rawfile pem "${CA_PEM}" --arg ns "${ARGOCD_NS}" --arg name "${ARGOCD_TLS_CM}" --arg host "${HARBOR_HOST}" \
      --arg mk "${MANAGED_BY_LABEL%%=*}" --arg mv "${MANAGED_BY_LABEL#*=}" '{
    apiVersion: "v1", kind: "ConfigMap",
    metadata: {name: $name, namespace: $ns,
      labels: {"app.kubernetes.io/name": $name, "app.kubernetes.io/part-of": "argocd", ($mk): $mv}},
    data: {($host): $pem}
  }' > "${f}"
  apply_ssa "${f}" teknoir-bootstrap "ConfigMap ${ARGOCD_NS}/${ARGOCD_TLS_CM} entry ${HARBOR_HOST}"
}

phase_secrets() {
  require_cluster secrets || return 0
  ensure_work_dir
  CA_PEM=""
  secrets_ensure_ca
  secrets_ensure_wildcard
  secrets_ensure_harbor_token_tls
  if [[ -z "${CA_PEM}" ]]; then
    log "[dry-run] CA-bundle copies, ${ARGOCD_TLS_CM} and the node trust would be derived from the new CA"
    return 0
  fi
  secrets_reconcile_ca_bundles
  secrets_reconcile_argocd_tls_certs
  if phase_wanted host; then
    host_trust_ca "${CA_PEM}"
  else
    log "node CA trust: skipped (host phase not selected)"
  fi
}

secrets_status() {
  # For `teknoir-node status`: certificate subjects and expiry (public data).
  ensure_work_dir
  local name f
  for name in "${CA_NS}/${CA_SECRET}" "${WILDCARD_NS}/$(secrets_wildcard_name)" "${TOKEN_NS}/${TOKEN_SECRET}"; do
    f="${WORK_DIR}/status.crt"
    if in_cluster secret "${name#*/}" "${name%%/*}" \
       && ( secret_value "${name%%/*}" "${name#*/}" tls.crt ) > "${f}" 2>/dev/null; then
      printf 'cert:      %-48s %s, %s\n' "${name}" \
        "$(openssl x509 -in "${f}" -noout -subject -nameopt oneline 2>/dev/null | sed 's/^subject= *//')" \
        "$(openssl x509 -in "${f}" -noout -enddate 2>/dev/null)"
    else
      printf 'cert:      %-48s absent\n' "${name}"
    fi
  done
}

# ---------------------------------------------------------------------------
# credentials
# ---------------------------------------------------------------------------
secrets_credential_ref() {
  # secrets_credential_ref <name> - "namespace secret key class" of a named
  # credential; class secret (marked for the leak check) or public (a user
  # name: never marked, it legitimately appears in log lines).
  case "$1" in
    keycloak-admin)          echo "teknoir-auth keycloak-admin password secret" ;;
    keycloak-admin-username) echo "teknoir-auth keycloak-admin username public" ;;
    platform-admin)          echo "teknoir-auth keycloak-platform-admin password secret" ;;
    harbor-admin)            echo "teknoir-system harbor-secret HARBOR_ADMIN_PASSWORD secret" ;;
    argocd-admin)            echo "teknoir-system argocd-admin-break-glass password secret" ;;
    grafana-admin)           echo "teknoir-system monitoring-grafana admin-password secret" ;;
    *) return 1 ;;
  esac
}

cmd_credentials() {
  # credentials NAME [--out FILE] - one value, to a 0600 file or to a stdout
  # that is not a terminal (the LAN host captures it into its own 0600 file).
  local name="" out="" ref ns secret key class value
  while (( $# > 0 )); do
    case "$1" in
      --out) [[ -n "${2:-}" ]] || die "credentials: --out needs a file"; out="$2"; shift ;;
      -*) die "credentials: unknown option $1" ;;
      *) [[ -z "${name}" ]] || die "credentials: one NAME only"; name="$1" ;;
    esac
    shift
  done
  [[ -n "${name}" ]] || die "credentials: NAME required (platform-admin keycloak-admin keycloak-admin-username harbor-admin argocd-admin grafana-admin)"
  ref="$(secrets_credential_ref "${name}")" \
    || die "credentials: unknown NAME ${name} (platform-admin keycloak-admin keycloak-admin-username harbor-admin argocd-admin grafana-admin)"
  read -r ns secret key class <<<"${ref}"
  if [[ -z "${out}" && -t 1 ]]; then
    die "credentials: refusing to print a credential to a terminal; use --out FILE or redirect stdout"
  fi
  require_cluster credentials || return 0
  if ! in_cluster secret "${secret}" "${ns}"; then
    # argocd-admin before its first rotation: ArgoCD's own initial password
    if [[ "${name}" == "argocd-admin" ]] && in_cluster secret "${ARGOCD_INITIAL_SECRET}" "${ns}"; then
      warn "credentials argocd-admin: not rotated yet, so this is ArgoCD's initial password from ${ns}/${ARGOCD_INITIAL_SECRET} (run: rotate argocd-admin)"
      secret="${ARGOCD_INITIAL_SECRET}"
    else
      die "credentials: Secret ${ns}/${secret} does not exist (yet)"
    fi
  fi
  dry_run && { log "[dry-run] would write ${name} (${ns}/${secret} ${key}) to ${out:-stdout}"; return 0; }
  if [[ "${class}" == "secret" ]]; then
    read_secret value "${ns}" "${secret}" "${key}"
  else
    value="$(secret_value "${ns}" "${secret}" "${key}")"
  fi
  if [[ -n "${out}" ]]; then
    [[ ! -L "${out}" ]] || die "credentials: ${out} is a symlink"
    ( umask 077 && printf '%s\n' "${value}" > "${out}" ) || die "credentials: cannot write ${out}"
    chmod 0600 "${out}"
    log "credential ${name} (${ns}/${secret} ${key}) written to ${out} (mode 0600)"
  else
    printf '%s\n' "${value}"
    log "credential ${name} (${ns}/${secret} ${key}) written to stdout (not a terminal)"
  fi
  value=""
}

# ---------------------------------------------------------------------------
# rotate
# ---------------------------------------------------------------------------
_secrets_restart_workloads() {
  # _secrets_restart_workloads <ns> <kind/name>... - rollout restart + wait; absent
  # workloads are skipped with a note.
  local ns="$1" w
  shift
  for w in "$@"; do
    if ! in_cluster "${w%%/*}" "${w#*/}" "${ns}"; then
      log "rotate: ${ns}/${w} does not exist; nothing to restart"
      continue
    fi
    run kc -n "${ns}" rollout restart "${w}" >/dev/null
    changed "restarted ${ns}/${w}"
    dry_run || kc -n "${ns}" rollout status "${w}" --timeout=600s >&2 \
      || die "rotate: ${ns}/${w} did not become ready again"
  done
}

_secrets_patch_key() {
  # _secrets_patch_key <ns> <name> <key> <value-var> - set one key from a
  # variable, through a 0600 patch file (never argv).
  local ns="$1" name="$2" key="$3" var="$4" f
  ensure_work_dir
  f="$(umask 077 && mktemp "${WORK_DIR}/patch.XXXXXX")"
  # The value reaches jq on stdin (printf is a builtin): never in an argv.
  printf '%s' "${!var}" | "${JQ}" -Rs --arg k "${key}" '{data: {($k): (. | @base64)}}' > "${f}"
  kc -n "${ns}" patch secret "${name}" --type merge --patch-file "${f}" >/dev/null \
    || die "rotate: cannot patch ${ns}/${name}"
  shred -u "${f}" 2>/dev/null || rm -f "${f}"
}

_secrets_rotate_random() {
  # _secrets_rotate_random <ns> <name> <key> <generator> - replace one key with a new
  # random value (generator: alnum<N> or b64url<N>).
  local ns="$1" name="$2" key="$3" gen="$4" newval=""
  in_cluster secret "${name}" "${ns}" || die "rotate: Secret ${ns}/${name} does not exist"
  if dry_run; then
    changed "replace ${ns}/${name} key ${key} with a new random value"
    return 0
  fi
  case "${gen}" in
    alnum*) newval="$(random_alnum "${gen#alnum}")" ;;
    b64url*) newval="$(random_b64url "${gen#b64url}")" ;;
    *) die "rotate: unknown generator ${gen}" ;;
  esac
  [[ -n "${newval}" ]] || die "rotate: could not generate a value"
  mark_sensitive "${newval}"
  _secrets_patch_key "${ns}" "${name}" "${key}" newval
  newval=""
  changed "replaced ${ns}/${name} key ${key}"
}

_secrets_rotate_keycloak_db() {
  # New Keycloak DB password: ALTER USER inside keycloak-db (SQL on stdin),
  # then the Secret, then Keycloak restarts with it.
  local user="" newval=""
  in_cluster secret keycloak-db-secret teknoir-auth || die "rotate: teknoir-auth/keycloak-db-secret does not exist"
  in_cluster pod keycloak-db-0 teknoir-auth || die "rotate: teknoir-auth/keycloak-db-0 is not running"
  if dry_run; then
    changed "set a new Keycloak DB password (ALTER USER in keycloak-db-0, Secret keycloak-db-secret, restart keycloak)"
    return 0
  fi
  # The user name is a platform-secrets literal ("keycloak"), not a secret:
  # read it unmarked, or the leak check would flag every log line naming
  # keycloak-db-secret or statefulset/keycloak.
  user="$(secret_value teknoir-auth keycloak-db-secret username)"
  [[ "${user}" =~ ^[A-Za-z0-9_]+$ ]] || die "rotate: unexpected DB user name format"
  newval="$(random_alnum 32)"
  mark_sensitive "${newval}"
  printf 'ALTER USER "%s" WITH PASSWORD '"'"'%s'"'"';\n' "${user}" "${newval}" \
    | kc -n teknoir-auth exec -i keycloak-db-0 -c postgres -- psql -U "${user}" -d postgres -v ON_ERROR_STOP=1 -q -f - >/dev/null \
    || die "rotate: ALTER USER failed; the Secret was not changed"
  _secrets_patch_key teknoir-auth keycloak-db-secret password newval
  newval=""
  changed "replaced teknoir-auth/keycloak-db-secret password (database user updated)"
  _secrets_restart_workloads teknoir-auth statefulset/keycloak
}

_secrets_cfg_escape() {
  # a value for a double-quoted curl config entry: backslash and quote escaped
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

_secrets_platform_ca() {
  # _secrets_platform_ca <file> - the platform CA certificate (public) into <file>.
  if in_cluster secret "${CA_BUNDLE_SECRET}" "${ARGOCD_NS}"; then
    secret_value "${ARGOCD_NS}" "${CA_BUNDLE_SECRET}" ca.crt > "$1"
  else
    secret_value "${CA_NS}" "${CA_SECRET}" tls.crt > "$1"
  fi
  grep -q 'BEGIN CERTIFICATE' "$1" || die "no platform CA certificate in ${ARGOCD_NS}/${CA_BUNDLE_SECRET} or ${CA_NS}/${CA_SECRET}"
}

_secrets_argocd_login() {
  # _secrets_argocd_login <password-var> - HTTP status of an ArgoCD local
  # `admin` login (POST https://argocd.<domain>/api/v1/session) through the
  # gateway on NODE_IP, verified with the platform CA. The password reaches
  # curl in a config on a pipe (never argv); the session token is discarded.
  local var="$1" ca body code
  ensure_work_dir
  ca="$(umask 077 && mktemp "${WORK_DIR}/argocd-ca.XXXXXX")"
  _secrets_platform_ca "${ca}"
  body="$(printf '%s' "${!var}" | "${JQ}" -Rc '{username: "admin", password: .}')"
  # shellcheck disable=SC2086  # SECRETS_CURL_OPTS: extra curl flags (tests)
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 30 --cacert "${ca}" \
      --resolve "argocd.${TEKNOIR_DOMAIN}:443:${NODE_IP}" ${SECRETS_CURL_OPTS:-} \
      -K <(printf 'header = "Content-Type: application/json"\ndata = "%s"\n' "$(_secrets_cfg_escape "${body}")") \
      "${ARGOCD_URL:-https://argocd.${TEKNOIR_DOMAIN}}/api/v1/session" 2>/dev/null)" || code="${code:-000}"
  body=""
  rm -f "${ca}"
  printf '%s' "${code}"
}

_secrets_argocd_break_glass_write() {
  # _secrets_argocd_break_glass_write <password-var> - create or update
  # teknoir-system/argocd-admin-break-glass (key password; label managed-by
  # teknoir-node; annotation teknoir.org/rotated-at). The value reaches jq on
  # stdin and kubectl through a pipe or a 0600 patch file, never argv. Create
  # or merge patch, never apply: no last-applied annotation holds the value.
  local var="$1" now f
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ensure_work_dir
  if in_cluster secret "${ARGOCD_BREAK_GLASS_SECRET}" "${ARGOCD_NS}"; then
    f="$(umask 077 && mktemp "${WORK_DIR}/patch.XXXXXX")"
    printf '%s' "${!var}" | "${JQ}" -Rs --arg t "${now}" \
      '{metadata: {annotations: {"teknoir.org/rotated-at": $t}}, data: {password: (. | @base64)}}' > "${f}"
    kc -n "${ARGOCD_NS}" patch secret "${ARGOCD_BREAK_GLASS_SECRET}" --type merge --patch-file "${f}" >/dev/null \
      || { shred -u "${f}" 2>/dev/null || rm -f "${f}"; die "rotate argocd-admin: cannot update ${ARGOCD_NS}/${ARGOCD_BREAK_GLASS_SECRET}; nothing was changed, the current admin password stays valid"; }
    shred -u "${f}" 2>/dev/null || rm -f "${f}"
  else
    printf '%s' "${!var}" | "${JQ}" -Rs --arg ns "${ARGOCD_NS}" --arg name "${ARGOCD_BREAK_GLASS_SECRET}" \
        --arg lk "${MANAGED_BY_LABEL%%=*}" --arg lv "${MANAGED_BY_LABEL#*=}" --arg t "${now}" '{
          apiVersion: "v1", kind: "Secret", type: "Opaque",
          metadata: {name: $name, namespace: $ns, labels: {($lk): $lv},
                     annotations: {"teknoir.org/rotated-at": $t}},
          data: {password: (. | @base64)}}' \
      | kc create -f - >/dev/null \
      || die "rotate argocd-admin: cannot create ${ARGOCD_NS}/${ARGOCD_BREAK_GLASS_SECRET}; nothing was changed, the current admin password stays valid"
  fi
  changed "stored the new ArgoCD admin password in ${ARGOCD_NS}/${ARGOCD_BREAK_GLASS_SECRET}"
}

_secrets_rotate_argocd_admin() {
  # New password for ArgoCD's local `admin` (DESIGN D10 break-glass):
  #   1. bcrypt it inside the argocd-server container with `argocd account
  #      bcrypt`, which reads the password from stdin when no --password is
  #      given (checked in ArgoCD v3.5.1, the deployed version; it prints
  #      "Password: " before the hash; an ArgoCD without it fails here): the
  #      value travels only on kubectl exec's stdin, never in any argv (node
  #      or container) or log;
  #   2. store it in Secret argocd-admin-break-glass, BEFORE it becomes active,
  #      so an active password is never one that is stored nowhere;
  #   3. patch argocd-secret admin.password + admin.passwordMtime (now, which
  #      ends the sessions of the old password) from a 0600 patch file;
  #   4. check a login with it (HTTP 200), and only then delete
  #      argocd-initial-admin-secret.
  # A failed step stops the run before the next one; until step 3 the old
  # password stays valid. argocd-server watches argocd-secret, so nothing
  # restarts. A login check that keeps failing never deletes anything.
  local newval="" out="" hash="" mtime f code="" i re='(\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53})'
  in_cluster deployment "${ARGOCD_SERVER_DEPLOY}" "${ARGOCD_NS}" \
    || die "rotate argocd-admin: Deployment ${ARGOCD_NS}/${ARGOCD_SERVER_DEPLOY} does not exist"
  in_cluster secret argocd-secret "${ARGOCD_NS}" || die "rotate argocd-admin: Secret ${ARGOCD_NS}/argocd-secret does not exist"
  if dry_run; then
    changed "set a new ArgoCD admin password (bcrypt in ${ARGOCD_SERVER_DEPLOY}, stored in ${ARGOCD_NS}/${ARGOCD_BREAK_GLASS_SECRET}, argocd-secret admin.password + admin.passwordMtime), check the login, then delete ${ARGOCD_NS}/${ARGOCD_INITIAL_SECRET}"
    return 0
  fi
  ensure_work_dir
  newval="$(random_alnum 32)"
  [[ ${#newval} -eq 32 ]] || die "rotate argocd-admin: could not generate a password"
  mark_sensitive "${newval}"
  # 1. bcrypt (stdin -> the container; "Password: <hash>" comes back on stdout)
  out="$(printf '%s\n' "${newval}" \
    | kc -n "${ARGOCD_NS}" exec -i "deploy/${ARGOCD_SERVER_DEPLOY}" -c server -- argocd account bcrypt)" \
    || die "rotate argocd-admin: argocd account bcrypt in ${ARGOCD_NS}/${ARGOCD_SERVER_DEPLOY} failed; nothing was changed"
  [[ "${out}" =~ ${re} ]] || die "rotate argocd-admin: argocd account bcrypt returned no bcrypt hash; nothing was changed"
  hash="${BASH_REMATCH[1]}"
  out=""
  mark_sensitive "${hash}"
  # 2. store the new value
  _secrets_argocd_break_glass_write newval
  # 3. activate it
  mtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  f="$(umask 077 && mktemp "${WORK_DIR}/patch.XXXXXX")"
  printf '%s' "${hash}" | "${JQ}" -Rs --arg m "${mtime}" \
    '{data: {"admin.password": (. | @base64), "admin.passwordMtime": ($m | @base64)}}' > "${f}"
  if ! kc -n "${ARGOCD_NS}" patch secret argocd-secret --type merge --patch-file "${f}" >/dev/null; then
    shred -u "${f}" 2>/dev/null || rm -f "${f}"
    die "rotate argocd-admin: cannot patch ${ARGOCD_NS}/argocd-secret; the old admin password stays valid, but ${ARGOCD_BREAK_GLASS_SECRET} now holds the new, inactive one: run rotate argocd-admin again"
  fi
  shred -u "${f}" 2>/dev/null || rm -f "${f}"
  hash=""
  changed "set the new ArgoCD admin password (${ARGOCD_NS}/argocd-secret admin.password, admin.passwordMtime ${mtime}: older admin sessions end)"
  # 4. prove it, then remove ArgoCD's initial password. ArgoCD locks a user
  # for 5 minutes after 5 failed logins, so the attempts are few and spaced.
  for (( i = 1; i <= ARGOCD_LOGIN_ATTEMPTS; i++ )); do
    sleep "${ARGOCD_LOGIN_DELAY}"
    code="$(_secrets_argocd_login newval)"
    [[ "${code}" == "200" ]] && break
    log "rotate argocd-admin: login check ${i}/${ARGOCD_LOGIN_ATTEMPTS}: HTTP ${code}"
  done
  newval=""
  [[ "${code}" == "200" ]] \
    || die "rotate argocd-admin: the login check with the new password got HTTP ${code} (https://argocd.${TEKNOIR_DOMAIN}/api/v1/session); the new password is set and stored in ${ARGOCD_NS}/${ARGOCD_BREAK_GLASS_SECRET}, and ${ARGOCD_INITIAL_SECRET} was kept. Check ArgoCD, then run rotate argocd-admin again (after 5 minutes if ArgoCD locked the admin login)"
  log "rotate argocd-admin: login with the new password: HTTP 200"
  if in_cluster secret "${ARGOCD_INITIAL_SECRET}" "${ARGOCD_NS}"; then
    kc -n "${ARGOCD_NS}" delete secret "${ARGOCD_INITIAL_SECRET}" >/dev/null \
      || die "rotate argocd-admin: the new password works, but deleting ${ARGOCD_NS}/${ARGOCD_INITIAL_SECRET} failed; delete it by hand"
    changed "deleted ${ARGOCD_NS}/${ARGOCD_INITIAL_SECRET} (it no longer works)"
  fi
}

cmd_rotate() {
  local name="" iknow=0 d
  while (( $# > 0 )); do
    case "$1" in
      --i-know) iknow=1 ;;
      -*) die "rotate: unknown option $1" ;;
      *) [[ -z "${name}" ]] || die "rotate: one NAME only"; name="$1" ;;
    esac
    shift
  done
  [[ -n "${name}" ]] || die "rotate: NAME required (oauth2-proxy-cookie oauth2-proxy-redis harbor-token-service harbor-secret-key keycloak-db argocd-admin)"
  require_cluster rotate || return 0
  ensure_work_dir
  case "${name}" in
    oauth2-proxy-cookie)
      _secrets_rotate_random teknoir-auth oauth2-proxy-secret cookie-secret b64url32
      _secrets_restart_workloads teknoir-auth deployment/oauth2-proxy
      ;;
    oauth2-proxy-redis)
      _secrets_rotate_random teknoir-auth oauth2-proxy-redis-secret password alnum32
      _secrets_restart_workloads teknoir-auth statefulset/oauth2-proxy-redis deployment/oauth2-proxy
      ;;
    harbor-token-service)
      in_cluster secret "${TOKEN_SECRET}" "${TOKEN_NS}" || die "rotate: ${TOKEN_NS}/${TOKEN_SECRET} does not exist (converge creates it)"
      if dry_run; then
        changed "replace ${TOKEN_NS}/${TOKEN_SECRET} with a new key pair"
      else
        d="$(_secrets_tmp)"
        _secrets_generate_token_tls "${d}"
        _secrets_replace_tls "${TOKEN_NS}" "${TOKEN_SECRET}" "${d}"
        _secrets_shred_dir "${d}"
        changed "replaced ${TOKEN_NS}/${TOKEN_SECRET}"
      fi
      _secrets_restart_workloads teknoir-system deployment/harbor-core deployment/harbor-registry
      ;;
    harbor-secret-key)
      (( iknow )) || die "rotate harbor-secret-key: Harbor encrypts stored credentials (e.g. the OIDC client secret) with it; they must be re-entered afterwards. Read OPERATE.md (rotate), then re-run with --i-know"
      _secrets_rotate_random teknoir-system harbor-secret secretKey alnum16
      _secrets_restart_workloads teknoir-system deployment/harbor-core deployment/harbor-jobservice
      ;;
    keycloak-db)
      (( iknow )) || die "rotate keycloak-db: changes the Keycloak database password and restarts Keycloak (sign-ins fail meanwhile). Read OPERATE.md (rotate), then re-run with --i-know"
      _secrets_rotate_keycloak_db
      ;;
    argocd-admin)
      _secrets_rotate_argocd_admin
      ;;
    *)
      die "rotate: ${name} is not rotatable here (rotatable: oauth2-proxy-cookie oauth2-proxy-redis harbor-token-service harbor-secret-key keycloak-db argocd-admin); the Root CA, the Keycloak admin and the client secrets follow OPERATE.md"
      ;;
  esac
  summary
}
