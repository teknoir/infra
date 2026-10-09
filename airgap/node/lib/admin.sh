# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016  # DRY_RUN, NODE_ROOT, TEKNOIR_DOMAIN come from common.sh and the site env; jq programs are single-quoted on purpose
#
# lib/admin.sh — `teknoir-node admin-user`: a named platform administrator
# (docs/airgap/DESIGN.md "First admin user", docs/airgap/OPERATE.md section 9).
#
#   teknoir-node admin-user --email ADDR --out FILE [--display-name NAME]
#                           [--teamspace NAME]... [--reset-password] [--dry-run]
#
# Steps, in this order. Each one converges, so a re-run resumes after a failure:
#   1. ensure the users.teknoir.org User <name> = lowercased email with "@"
#      replaced by "-at-" (the Backstage catalog entity user:default/<name>
#      that sign-in resolves), spec: email, email_verified true, enabled true,
#      claims_v0.role superadmin, plugins []. An existing User only gets the
#      missing owner claims of step 4;
#   2. wait until user-controller has reconciled it (status.computed_status),
#      then put the Keycloak user into group `admin` of realm `teknoir` through
#      the Keycloak admin REST API, logged in as the master-realm admin from
#      Secret teknoir-auth/keycloak-admin (credentials on a curl config pipe);
#   3. hand the temporary password over exactly once. It is read from Secret
#      <credentials namespace>/user-initial-password-<name> (user-controller
#      r5), or else from the legacy status.set_initial_password (older
#      user-controller), written to FILE (0600, temp file + rename, sha256
#      checked), and then the Secret is deleted or the status field removed.
#      With nothing on record, FILE is not written and a warning says so.
#      --reset-password instead sets a new temporary password through the
#      Keycloak admin API (temporary=true: the user must change it at the next
#      sign-in) and writes it to FILE first;
#   4. grant ClaimSet `owner` on every teamspace (Profile) whose spec.owner is
#      the address (only the --teamspace ones when given): add the missing
#      {name: owner, namespace: <profile>} entries to spec.claim_set (JSON
#      patch guarded by the resourceVersion, retried on conflict), then wait
#      for user-controller's RoleBinding user-<name>-teknoir-role-binding;
#   5. wait until the Backstage catalog lists user:default/<name> with
#      group:<ns>/<ns> in its memberOf for every teamspace of step 4 (read-only
#      psql query on backstage-postgres-0). Backstage is never restarted: a
#      restart does not run its user provider any earlier.
# FILE is never overwritten or truncated: a FILE that exists and is not empty
# is refused before a password is handed out (an empty one, such as the LAN
# tool's fresh temp file, is fine). No password is ever printed, logged or
# passed as a command-line argument.

ADMIN_NS="${ADMIN_NS:-teknoir-system}"
ADMIN_TIMEOUT="${ADMIN_TIMEOUT:-300}"
ADMIN_CATALOG_TIMEOUT="${ADMIN_CATALOG_TIMEOUT:-240}"
# Namespace of user-controller's temporary-password Secrets; empty: its
# ConfigMap's USER_CREDENTIALS_NAMESPACE, else the controller's default.
ADMIN_CREDENTIALS_NS="${ADMIN_CREDENTIALS_NS:-}"
ADMIN_TOKEN=""
ADMIN_KC_URL=""
ADMIN_KC_REALM=""
ADMIN_KC_UID=""
ADMIN_KC_CODE=""
ADMIN_KC_BODY=""

cmd_admin_user() {
  local email="" out="" display="" reset=0 name dir t
  local -a teamspaces=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --email) [[ $# -ge 2 ]] || die "--email needs an address"; email="$2"; shift 2 ;;
      --email=*) email="${1#*=}"; shift ;;
      --out) [[ $# -ge 2 ]] || die "--out needs a file"; out="$2"; shift 2 ;;
      --out=*) out="${1#*=}"; shift ;;
      --display-name) [[ $# -ge 2 ]] || die "--display-name needs a value"; display="$2"; shift 2 ;;
      --display-name=*) display="${1#*=}"; shift ;;
      --teamspace) [[ $# -ge 2 ]] || die "--teamspace needs a name"; teamspaces+=("$2"); shift 2 ;;
      --teamspace=*) teamspaces+=("${1#*=}"); shift ;;
      --reset-password) reset=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) admin_usage; return 0 ;;
      *) die "admin-user: unknown argument: $1 (see: teknoir-node admin-user --help)" ;;
    esac
  done
  [[ -n "${email}" ]] || die "admin-user: --email is required"
  [[ -n "${out}" ]] || die "admin-user: --out FILE is required (the temporary password is never printed)"
  email="${email,,}"
  [[ "${email}" =~ ^[a-z0-9]+([.-][a-z0-9]+)*@[a-z0-9]+([.-][a-z0-9]+)*\.[a-z]{2,}$ ]] \
    || die "admin-user: ${email}: only a-z, 0-9, '.' and '-' are supported (the User name must be a valid Kubernetes and Backstage entity name)"
  name="${email/@/-at-}"
  (( ${#name} <= 63 )) || die "admin-user: User name ${name} is longer than 63 characters (Backstage entity names are limited to 63)"
  for t in ${teamspaces[@]+"${teamspaces[@]}"}; do
    [[ "${t}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "admin-user: --teamspace ${t}: not a teamspace (Kubernetes namespace) name"
  done
  [[ ! -L "${out}" && ! -d "${out}" ]] || die "admin-user: --out ${out} is a symlink or a directory"
  [[ ! -e "${out}" || -f "${out}" ]] || die "admin-user: --out ${out} is not a regular file"
  dir="$(dirname "${out}")"
  [[ -d "${dir}" ]] || die "admin-user: directory ${dir} does not exist"
  if (( reset )) && [[ -s "${out}" ]]; then
    die "admin-user: --out ${out} exists and is not empty; admin-user never overwrites a file: give a new file name"
  fi
  ADMIN_JQ="$(admin_tool jq)" || exit 1

  in_cluster customresourcedefinitions.apiextensions.k8s.io users.teknoir.org \
    || die "admin-user: the users.teknoir.org CRD is missing (is user-controller deployed?)"
  # the teamspaces are known before anything changes: a wrong --teamspace fails here
  admin_teamspaces "${email}" ${teamspaces[@]+"${teamspaces[@]}"}
  admin_ensure_user "${name}" "${email}" "${display}" "${reset}" || return 0
  wait_for "user-controller to create ${email} in Keycloak (logs: kubectl -n ${ADMIN_NS} logs deploy/user-controller)" \
    "${ADMIN_TIMEOUT}" admin_user_reconciled "${name}"
  admin_keycloak_login
  admin_keycloak_group "${email}"
  if (( reset )); then
    admin_reset_password "${name}" "${email}" "${out}"
  else
    admin_handover_password "${name}" "${email}" "${out}"
  fi
  ADMIN_TOKEN=""
  admin_grant_teamspaces "${name}" "${email}"
  admin_wait_catalog "${name}" "${email}"
}

admin_usage() {
  cat >&2 <<'EOF'
Usage: teknoir-node admin-user --email ADDR --out FILE [--display-name NAME]
                               [--teamspace NAME]... [--reset-password] [--dry-run]

Creates or completes a platform administrator: a superadmin User (name: the
email with @ -> -at-), Keycloak group `admin` in realm teknoir, the temporary
password handed over once into FILE (mode 0600, never printed; afterwards it
is deleted from the cluster), ClaimSet `owner` on every teamspace the address
owns (only the --teamspace ones when given), and a wait until Backstage's
catalog knows the user as a member of those teamspaces. An existing User only
gets missing owner claims.

FILE is never overwritten: it must not exist or be empty. When no temporary
password is on record (already handed out, or the user has signed in), FILE
is not written. --reset-password sets a new temporary password in Keycloak
(the current one stops working) and writes it to FILE. Safe to re-run.
EOF
}

admin_tool() {
  if [[ -x "${NODE_ROOT}/bin/$1" ]]; then
    echo "${NODE_ROOT}/bin/$1"
  elif command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
  else
    die "$1 not found (expected ${NODE_ROOT}/bin/$1)"
  fi
}

admin_ensure_user() {
  # admin_ensure_user <name> <email> <display-name> <reset> — 1 in dry-run
  # when the User does not exist yet (nothing further can be checked then)
  local name="$1" email="$2" display="$3" reset="$4" have manifest pw ts="add no owner claim (it owns no teamspace)"
  if in_cluster users.teknoir.org "${name}"; then
    have="$(kc get users.teknoir.org "${name}" -o jsonpath='{.spec.email}')" || die "cannot read User ${name}"
    [[ "${have,,}" == "${email}" ]] || die "User ${name} exists with another email (${have}); not touching it"
    log "User ${name} exists; only missing owner claims are added"
    return 0
  fi
  manifest="$("${ADMIN_JQ}" -cn --arg n "${name}" --arg e "${email}" --arg d "${display}" '
      {apiVersion: "teknoir.org/v1", kind: "User", metadata: {name: $n},
       spec: ({email: $e, email_verified: true, enabled: true, claims_v0: {role: "superadmin"}, plugins: []}
              + (if $d != "" then {display_name: $d} else {} end))}')"
  if [[ "${DRY_RUN}" == "1" ]]; then
    pw="hand over its temporary password"
    [[ "${reset}" == "1" ]] && pw="set a new temporary password in Keycloak"
    (( ${#ADMIN_TEAMSPACES[@]} == 0 )) || ts="grant it owner on ${ADMIN_TEAMSPACES[*]}"
    log "[dry-run] would create User ${name} (superadmin, ${email}), wait for user-controller, add it to Keycloak group admin, ${pw} into the --out file, ${ts}, and wait for the Backstage catalog to list it"
    return 1
  fi
  kc create -f - <<<"${manifest}" >/dev/null || die "cannot create User ${name}"
  changed "User ${name} (superadmin, ${email})"
}

admin_user_reconciled() {
  [[ -n "$(kc get users.teknoir.org "$1" -o jsonpath='{.status.computed_status}' 2>/dev/null)" ]]
}

# ---------------------------------------------------------------------------
# Keycloak admin API (realm teknoir, as the master-realm admin)
# ---------------------------------------------------------------------------
admin_cfg_escape() {
  # escape for a double-quoted curl config value
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

admin_token_cfg() {
  printf 'data-urlencode = "grant_type=password"\n'
  printf 'data-urlencode = "client_id=admin-cli"\n'
  printf 'data-urlencode = "username=%s"\n' "$(admin_cfg_escape "$1")"
  printf 'data-urlencode = "password=%s"\n' "$(admin_cfg_escape "$2")"
}

admin_kc_call() {
  # admin_kc_call <method> <path> [json-body-file] — one Keycloak admin API
  # call with the bearer token on a pipe. Sets ADMIN_KC_CODE and
  # ADMIN_KC_BODY; returns 1 when there was no HTTP answer. Call it in the
  # main shell (not in $(...)), so the globals reach the caller.
  local resp
  local -a body=()
  [[ -z "${3:-}" ]] || body=(-H 'Content-Type: application/json' --data-binary "@$3")
  ADMIN_KC_CODE=""
  ADMIN_KC_BODY=""
  # shellcheck disable=SC2086  # ADMIN_CURL_OPTS: extra curl flags (e.g. --cacert FILE)
  resp="$(curl -sS -w '\n%{http_code}' -X "$1" ${ADMIN_CURL_OPTS:-} ${body[@]+"${body[@]}"} \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "${ADMIN_TOKEN}") "${ADMIN_KC_URL}$2")" || return 1
  ADMIN_KC_CODE="${resp##*$'\n'}"
  ADMIN_KC_BODY="${resp%"${ADMIN_KC_CODE}"}"
  [[ "${ADMIN_KC_CODE}" =~ ^[0-9]{3}$ ]] || return 1
}

admin_kc() {
  # admin_kc <method> <path> — prints the body, dies unless 2xx
  admin_kc_call "$1" "$2" || die "Keycloak admin API $1 $2: request failed"
  [[ "${ADMIN_KC_CODE}" == 2* ]] || die "Keycloak admin API $1 $2: HTTP ${ADMIN_KC_CODE}"
  printf '%s' "${ADMIN_KC_BODY}"
}

admin_keycloak_login() {
  local user pass resp code
  # Keycloak serves under /auth (KC_HTTP_RELATIVE_PATH in the auth chart)
  ADMIN_KC_URL="${ADMIN_KEYCLOAK_URL:-https://auth.${TEKNOIR_DOMAIN}/auth}"
  ADMIN_KC_REALM="${ADMIN_KEYCLOAK_REALM:-teknoir}"
  user="$(secret_value teknoir-auth keycloak-admin username)" || die "cannot read Secret teknoir-auth/keycloak-admin"
  pass="$(secret_value teknoir-auth keycloak-admin password)" || die "cannot read Secret teknoir-auth/keycloak-admin"
  if declare -F mark_sensitive >/dev/null; then mark_sensitive "${pass}"; fi
  # shellcheck disable=SC2086
  resp="$(curl -sS -w '\n%{http_code}' ${ADMIN_CURL_OPTS:-} -K <(admin_token_cfg "${user}" "${pass}") \
    "${ADMIN_KC_URL}/realms/master/protocol/openid-connect/token")" \
    || die "cannot reach Keycloak at ${ADMIN_KC_URL}"
  pass=""
  code="${resp##*$'\n'}"
  [[ "${code}" == "200" ]] || die "Keycloak admin login (master realm, Secret teknoir-auth/keycloak-admin) failed: HTTP ${code}"
  ADMIN_TOKEN="$("${ADMIN_JQ}" -r '.access_token // empty' <<<"${resp%"${code}"}")"
  resp=""
  [[ -n "${ADMIN_TOKEN}" ]] || die "Keycloak returned no access token"
}

admin_keycloak_group() {
  # admin_keycloak_group <email> — also sets ADMIN_KC_UID (the Keycloak user id)
  local email="$1" realm="${ADMIN_KC_REALM}" uid gid member body
  # admin_kc dies on errors, so its output is captured before jq reads it
  body="$(admin_kc GET "/admin/realms/${realm}/users?username=${email/@/%40}&exact=true")" || die "cannot look up ${email}"
  uid="$("${ADMIN_JQ}" -r --arg e "${email}" '[.[]? | select((.username // "" | ascii_downcase) == $e)][0].id // empty' <<<"${body}")" \
    || die "cannot parse the users of realm ${realm}"
  [[ -n "${uid}" ]] || die "no Keycloak user ${email} in realm ${realm} (user-controller must run with KEYCLOAK_REALM=${realm})"
  [[ "${uid}" =~ ^[A-Za-z0-9-]+$ ]] || die "unexpected Keycloak user id for ${email}"
  ADMIN_KC_UID="${uid}"
  body="$(admin_kc GET "/admin/realms/${realm}/groups?search=admin&exact=true&briefRepresentation=true")" || die "cannot look up group admin"
  gid="$("${ADMIN_JQ}" -r '[.[]? | select(.name == "admin" and ((.path // "/admin") == "/admin"))][0].id // empty' <<<"${body}")" \
    || die "cannot parse the groups of realm ${realm}"
  [[ -n "${gid}" ]] || die "realm ${realm} has no group admin (the auth chart's realm import creates it)"
  body="$(admin_kc GET "/admin/realms/${realm}/users/${uid}/groups?briefRepresentation=true")" || die "cannot read the groups of ${email}"
  member="$("${ADMIN_JQ}" -r --arg g "${gid}" 'any(.[]?; .id == $g)' <<<"${body}")" || die "cannot parse the groups of ${email}"
  if [[ "${member}" == "true" ]]; then
    log "${email} is in Keycloak group admin (realm ${realm})"
  elif [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would add ${email} to Keycloak group admin (realm ${realm})"
  else
    admin_kc PUT "/admin/realms/${realm}/users/${uid}/groups/${gid}" >/dev/null
    changed "${email} added to Keycloak group admin (realm ${realm})"
  fi
}

# ---------------------------------------------------------------------------
# Step 3: the temporary password, handed over exactly once
# ---------------------------------------------------------------------------
admin_sha() {
  # admin_sha <value> — sha256 of "<value>\n", the content admin-user writes
  # (printf is a builtin: the value is not in any process's argv)
  local s
  s="$(printf '%s\n' "$1" | sha256sum)" || die "sha256sum failed"
  printf '%s' "${s%% *}"
}

admin_credentials_ns() {
  # the namespace of user-controller's temporary-password Secrets (contract K1)
  local ns="${ADMIN_CREDENTIALS_NS}"
  if [[ -z "${ns}" ]]; then
    ns="$(kc -n "${ADMIN_NS}" get configmap user-controller-config --ignore-not-found \
      -o jsonpath='{.data.USER_CREDENTIALS_NAMESPACE}' 2>/dev/null)" || ns=""
  fi
  ns="${ns:-teknoir-user-credentials}"
  [[ "${ns}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "invalid credentials namespace '${ns}'"
  printf '%s' "${ns}"
}

admin_write_file() {
  # admin_write_file <file> <value> — "<value>\n" into <file>, mode 0600 (owned
  # by $SUDO_USER when set), through a temp file and a rename; the content is
  # checked by sha256. Never replaces a non-empty file.
  local out="$1" want tmp
  want="$(admin_sha "$2")"
  tmp="$(mktemp "$(dirname "${out}")/.teknoir-admin-user.XXXXXX")" || die "cannot create a file next to ${out}"
  chmod 0600 "${tmp}"
  printf '%s\n' "$2" > "${tmp}" || { rm -f -- "${tmp}"; die "cannot write ${out}"; }
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown "${SUDO_USER}:" "${tmp}" 2>/dev/null || warn "cannot hand ${out} to ${SUDO_USER}; it stays root's"
  fi
  if [[ -s "${out}" || -L "${out}" ]]; then
    rm -f -- "${tmp}"
    die "${out} appeared meanwhile and is not empty; admin-user never overwrites a file: run it again with a new --out FILE"
  fi
  mv -f -- "${tmp}" "${out}" || { rm -f -- "${tmp}"; die "cannot write ${out}"; }
  [[ "$(sha256_file "${out}")" == "${want}" ]] || die "${out} does not hold what was written (sha256 mismatch); run admin-user again with a new --out FILE"
}

admin_recorded() {
  # admin_recorded <name> — what is on record for the User, as globals:
  # ADMIN_PW (value, empty when none), ADMIN_PW_FROM (secret|status|""),
  # ADMIN_SECRET_NS/_NAME/_UID/_RV (the Secret, when it exists) and
  # ADMIN_LEGACY (1 when status.set_initial_password is set).
  local name="$1" json b64 legacy
  ADMIN_PW="" ADMIN_PW_FROM="" ADMIN_SECRET_UID="" ADMIN_SECRET_RV="" ADMIN_LEGACY=0
  ADMIN_SECRET_NS="$(admin_credentials_ns)"
  ADMIN_SECRET_NAME="user-initial-password-${name}"
  json="$(kc -n "${ADMIN_SECRET_NS}" get secret "${ADMIN_SECRET_NAME}" --ignore-not-found -o json)" \
    || die "cannot read Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME}"
  if [[ -n "${json}" ]]; then
    ADMIN_SECRET_UID="$(printf '%s' "${json}" | "${ADMIN_JQ}" -r '.metadata.uid // empty')"
    ADMIN_SECRET_RV="$(printf '%s' "${json}" | "${ADMIN_JQ}" -r '.metadata.resourceVersion // empty')"
    b64="$(printf '%s' "${json}" | "${ADMIN_JQ}" -r '.data.password // empty')"
    json=""
    if [[ -n "${b64}" ]]; then
      ADMIN_PW="$(printf '%s' "${b64}" | base64 -d)" || die "Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME}: key password is not valid base64"
      ADMIN_PW_FROM=secret
    else
      warn "Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME} has no key password"
    fi
    b64=""
  fi
  # the legacy field, read through a pipe so the whole object never sits in a variable
  legacy="$(kc get users.teknoir.org "${name}" -o json | "${ADMIN_JQ}" -r '.status.set_initial_password // empty')" \
    || die "cannot read User ${name}"
  if [[ -n "${legacy}" ]]; then
    ADMIN_LEGACY=1
    if [[ -z "${ADMIN_PW_FROM}" ]]; then
      ADMIN_PW="${legacy}"
      ADMIN_PW_FROM=status
    fi
  fi
  legacy=""
  if [[ -n "${ADMIN_PW}" ]] && declare -F mark_sensitive >/dev/null; then mark_sensitive "${ADMIN_PW}"; fi
}

admin_delete_secret() {
  # admin_delete_secret — delete the Secret admin_recorded found, only if it is
  # still the same object (uid and resourceVersion preconditions)
  local body out
  body="$(printf '{"kind":"DeleteOptions","apiVersion":"v1","preconditions":{"uid":"%s","resourceVersion":"%s"}}' \
    "${ADMIN_SECRET_UID}" "${ADMIN_SECRET_RV}")"
  if out="$(kc delete --raw "/api/v1/namespaces/${ADMIN_SECRET_NS}/secrets/${ADMIN_SECRET_NAME}" -f - <<<"${body}" 2>&1)"; then
    return 0
  fi
  [[ "${out}" == *NotFound* || "${out}" == *"not found"* ]] && return 0
  die "cannot delete Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME} (it changed since it was read, e.g. a new temporary password; run admin-user again with a new --out FILE): ${out}"
}

admin_clear_legacy() {
  # admin_clear_legacy <name> [sha] — remove status.set_initial_password,
  # guarded by the resourceVersion (retried). With <sha>, only while the field
  # still holds that value. The JSON patch never carries the value.
  local name="$1" sha="${2:-}" i view v rv out=""
  for i in 1 2 3 4 5; do
    view="$(kc get users.teknoir.org "${name}" -o json | "${ADMIN_JQ}" -c '{rv: .metadata.resourceVersion, has: (.status.set_initial_password // "" | length > 0)}')" \
      || die "cannot read User ${name}"
    [[ "$("${ADMIN_JQ}" -r '.has' <<<"${view}")" == "true" ]] || return 0
    if [[ -n "${sha}" ]]; then
      v="$(kc get users.teknoir.org "${name}" -o json | "${ADMIN_JQ}" -r '.status.set_initial_password // empty')" || die "cannot read User ${name}"
      if [[ "$(admin_sha "${v}")" != "${sha}" ]]; then
        v=""
        die "status.set_initial_password of User ${name} changed during the handover; run admin-user again with a new --out FILE"
      fi
      v=""
    fi
    rv="$("${ADMIN_JQ}" -r '.rv' <<<"${view}")"
    [[ "${rv}" =~ ^[0-9]+$ ]] || die "User ${name} has an unexpected resourceVersion"
    if out="$(kc patch users.teknoir.org "${name}" --subresource=status --type=json \
        -p "[{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"${rv}\"},{\"op\":\"remove\",\"path\":\"/status/set_initial_password\"}]" 2>&1)"; then
      return 0
    fi
    sleep 1
  done
  die "cannot remove status.set_initial_password of User ${name}: ${out}"
}

admin_handover_password() {
  local name="$1" email="$2" out="$3" from sha what
  admin_recorded "${name}"
  if [[ -z "${ADMIN_PW}" ]]; then
    warn "no temporary password of ${email} is on record: it was handed out already, or ${email} has signed in and set a password (${out} is not written). To issue a new one: admin-user --email ${email} --reset-password --out NEW-FILE"
    return 0
  fi
  case "${ADMIN_PW_FROM}" in
    secret) from="Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME}" ;;
    *) from="the legacy status.set_initial_password of User ${name}" ;;
  esac
  if [[ "${DRY_RUN}" == "1" ]]; then
    ADMIN_PW=""
    log "[dry-run] would write the temporary password of ${email} (from ${from}) to ${out} (mode 0600), then delete it from the cluster"
    return 0
  fi
  sha="$(admin_sha "${ADMIN_PW}")"
  if [[ -s "${out}" ]]; then
    if [[ -f "${out}" && "$(sha256_file "${out}")" == "${sha}" ]]; then
      log "${out} already holds the temporary password of ${email} (an earlier run stopped before deleting it from the cluster)"
    else
      ADMIN_PW=""
      die "${out} exists and is not empty; admin-user never overwrites a file: run it again with a new --out FILE (the temporary password stays on record until it is written)"
    fi
  else
    admin_write_file "${out}" "${ADMIN_PW}"
  fi
  ADMIN_PW=""
  if [[ "${ADMIN_PW_FROM}" == "secret" ]]; then
    admin_delete_secret
    what="deleted Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME}"
    if (( ADMIN_LEGACY )); then
      admin_clear_legacy "${name}"
      what="${what} and the legacy status.set_initial_password"
    fi
  else
    admin_clear_legacy "${name}" "${sha}"
    what="removed status.set_initial_password of User ${name}"
  fi
  changed "temporary password of ${email} written to ${out} (mode 0600, not shown); ${what}"
  log "Keycloak asks ${email} for a new password at the first sign-in; delete ${out} afterwards"
}

admin_reset_password() {
  # --reset-password: a new temporary password through the Keycloak admin API.
  # FILE is written first (never a password set without a recorded copy); a
  # refused reset removes it again.
  local name="$1" email="$2" out="$3" realm="${ADMIN_KC_REALM}" pw body
  [[ -n "${ADMIN_KC_UID}" ]] || die "internal: no Keycloak user id for ${email}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would set a new temporary password for ${email} in Keycloak (realm ${realm}; the current password stops working), write it to ${out} (mode 0600), and delete any temporary password on record"
    return 0
  fi
  ensure_work_dir
  pw="$(random_alnum 20)"
  if declare -F mark_sensitive >/dev/null; then mark_sensitive "${pw}"; fi
  body="$(umask 077 && mktemp "${WORK_DIR}/reset-password.XXXXXX")" || die "cannot create a private temp file"
  printf '%s' "${pw}" | "${ADMIN_JQ}" -Rsc '{type: "password", temporary: true, value: .}' > "${body}" \
    || { rm -f -- "${body}"; die "cannot build the reset-password request"; }
  admin_write_file "${out}" "${pw}"
  pw=""
  if ! admin_kc_call PUT "/admin/realms/${realm}/users/${ADMIN_KC_UID}/reset-password" "${body}"; then
    shred -u -- "${body}" 2>/dev/null || rm -f -- "${body}"
    die "the reset-password request for ${email} got no answer: the new password in ${out} may or may not be set; run admin-user --reset-password again with a new --out FILE"
  fi
  shred -u -- "${body}" 2>/dev/null || rm -f -- "${body}"
  if [[ "${ADMIN_KC_CODE}" != 2* ]]; then
    shred -u -- "${out}" 2>/dev/null || rm -f -- "${out}"
    die "Keycloak refused the new password of ${email} (HTTP ${ADMIN_KC_CODE}); nothing changed and ${out} was removed"
  fi
  changed "new temporary password of ${email} (Keycloak realm ${realm}) written to ${out} (mode 0600, not shown)"
  # anything still on record is a superseded password now
  admin_recorded "${name}"
  ADMIN_PW=""
  if [[ -n "${ADMIN_SECRET_UID}" ]]; then
    admin_delete_secret
    changed "deleted the superseded Secret ${ADMIN_SECRET_NS}/${ADMIN_SECRET_NAME}"
  fi
  if (( ADMIN_LEGACY )); then
    admin_clear_legacy "${name}"
    changed "removed the superseded status.set_initial_password of User ${name}"
  fi
  log "Keycloak asks ${email} for a new password at the next sign-in; delete ${out} afterwards"
}

# ---------------------------------------------------------------------------
# Step 4: owner of the user's teamspaces
# ---------------------------------------------------------------------------
admin_crd_established() {
  [[ "$(kc get crd "$1" --ignore-not-found -o 'jsonpath={.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" == "True" ]]
}

admin_ns_owned() {
  # admin_ns_owned <namespace> <email> — the namespace exists, annotated owner=<email>
  local owner
  owner="$(kc get namespace "$1" --ignore-not-found -o jsonpath='{.metadata.annotations.owner}' 2>/dev/null)" || return 1
  [[ -n "${owner}" && "${owner,,}" == "$2" ]]
}

admin_rolebinding() {
  # admin_rolebinding <namespace> <name> — user-controller's RoleBinding exists
  [[ -n "$(kc -n "$1" get rolebinding "user-$2-teknoir-role-binding" --ignore-not-found -o name 2>/dev/null)" ]]
}

ADMIN_TEAMSPACES=()

admin_teamspaces() {
  # admin_teamspaces <email> [teamspace...] — ADMIN_TEAMSPACES: the Profiles
  # whose spec.owner.name is <email> (any case), or the given ones, each of
  # which must exist and belong to <email>
  local email="$1" profiles owner p
  shift
  ADMIN_TEAMSPACES=()
  if ! admin_crd_established profiles.teknoir.org; then
    (( $# == 0 )) || die "--teamspace: there are no teamspaces (the profiles.teknoir.org CRD is missing; is profile-controller deployed?)"
    return 0
  fi
  profiles="$(kc get profiles.teknoir.org -o json)" || die "cannot list the teamspaces (profiles.teknoir.org)"
  if (( $# > 0 )); then
    for p in "$@"; do
      owner="$("${ADMIN_JQ}" -r --arg p "${p}" '[.items[] | select(.metadata.name == $p)] | if length == 0 then "absent" else "owner:" + (.[0].spec.owner.name // "") end' <<<"${profiles}")"
      [[ "${owner}" == owner:* ]] || die "--teamspace ${p}: there is no Profile ${p}"
      owner="${owner#owner:}"
      [[ "${owner,,}" == "${email}" ]] || die "--teamspace ${p}: Profile ${p} is owned by '${owner}', not ${email}; admin-user grants owner only on the user's own teamspaces"
      [[ " ${ADMIN_TEAMSPACES[*]} " == *" ${p} "* ]] || ADMIN_TEAMSPACES+=("${p}")
    done
    return 0
  fi
  while IFS= read -r p; do
    [[ -n "${p}" ]] && ADMIN_TEAMSPACES+=("${p}")
  done < <("${ADMIN_JQ}" -r --arg e "${email}" '.items[] | select((.spec.owner.name // "" | ascii_downcase) == $e) | .metadata.name' <<<"${profiles}" | LC_ALL=C sort)
  return 0
}

admin_grant_teamspaces() {
  # admin_grant_teamspaces <name> <email> — owner on ADMIN_TEAMSPACES
  local name="$1" email="$2" p want view patch added i out=""
  local -a list=(${ADMIN_TEAMSPACES[@]+"${ADMIN_TEAMSPACES[@]}"})
  if (( ${#list[@]} == 0 )); then
    log "${email} owns no teamspace (Profile): no owner claims to add"
    return 0
  fi
  log "teamspaces owned by ${email}: ${list[*]}"
  for p in "${list[@]}"; do
    wait_for "profile-controller to create namespace ${p} for ${email} (annotation owner)" "${ADMIN_TIMEOUT}" admin_ns_owned "${p}" "${email}"
  done
  want="$(printf '%s\n' "${list[@]}" | "${ADMIN_JQ}" -Rsc 'split("\n") | map(select(. != ""))')"
  for i in 1 2 3 4 5; do
    # only the fields needed, through a pipe (the User may carry a legacy password)
    view="$(kc get users.teknoir.org "${name}" -o json \
      | "${ADMIN_JQ}" -c '{rv: .metadata.resourceVersion, has: ((.spec.claim_set // null) != null), cs: (.spec.claim_set // [])}')" \
      || die "cannot read User ${name}"
    patch="$("${ADMIN_JQ}" -c --argjson want "${want}" '
        . as $u
        | [$want[] | . as $ns | select(any($u.cs[]?; .name == "owner" and .namespace == $ns) | not) | {name: "owner", namespace: $ns}] as $add
        | if ($add | length) == 0 then empty
          else [{op: "test", path: "/metadata/resourceVersion", value: $u.rv}]
               + (if $u.has then [$add[] | {op: "add", path: "/spec/claim_set/-", value: .}]
                  else [{op: "add", path: "/spec/claim_set", value: $add}] end)
          end' <<<"${view}")" || die "cannot compute the owner claims of User ${name}"
    if [[ -z "${patch}" ]]; then
      log "User ${name} has owner on: ${list[*]}"
      break
    fi
    added="$("${ADMIN_JQ}" -r '[.[] | select(.op == "add") | (.value | if type == "array" then .[] else . end) | "owner@\(.namespace)"] | join(", ")' <<<"${patch}")"
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "[dry-run] would add to User ${name}: claim ${added}"
      return 0
    fi
    if out="$(kc patch users.teknoir.org "${name}" --type=json -p "${patch}" 2>&1)"; then
      changed "User ${name}: claim ${added}"
      break
    fi
    (( i < 5 )) || die "cannot add the owner claims to User ${name}: ${out}"
    log "User ${name} changed meanwhile; reading it again"
    sleep 1
  done
  for p in "${list[@]}"; do
    wait_for "user-controller to make ${email} owner of ${p} (RoleBinding ${p}/user-${name}-teknoir-role-binding; logs: kubectl -n ${ADMIN_NS} logs deploy/user-controller)" \
      "${ADMIN_TIMEOUT}" admin_rolebinding "${p}" "${name}"
  done
}

# ---------------------------------------------------------------------------
# Step 5: Backstage's catalog knows the user, with its teamspaces
# ---------------------------------------------------------------------------
admin_catalog_state() {
  # admin_catalog_state <entity-ref> <groups> — read-only query on Backstage's
  # catalog database through the postgres container's local socket (no
  # credentials). Prints "member" when final_entities lists the entity and its
  # spec.memberOf holds every group in <groups> (comma-separated; empty: no
  # group needed), "listed" when it lists the entity without all of them, and
  # nothing when it does not list it; returns 1 when the query fails. The SQL
  # goes on stdin; the ref and the groups travel as psql variables, never
  # inside the SQL.
  local out
  out="$(kc -n "${ADMIN_NS}" exec -i backstage-postgres-0 -c postgres -- sh -c \
      'exec psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d backstage_plugin_catalog -v ref="$1" -v grps="$2" -tA' \
      _ "$1" "$2" 2>/dev/null <<'SQL'
select case when :'grps' = ''
              or coalesce((final_entity::jsonb -> 'spec' -> 'memberOf') ?& string_to_array(:'grps', ','), false)
            then 'member' else 'listed' end
  from final_entities
 where entity_ref = :'ref' and final_entity is not null
 limit 1;
SQL
  )" || return 1
  printf '%s' "${out//[[:space:]]/}"
}

admin_wait_catalog() {
  # admin_wait_catalog <name> <email> — until the catalog lists
  # user:default/<name>, and (sign-in takes the user's teamspaces from that
  # entity) its memberOf has group:<ns>/<ns> for every teamspace of step 4.
  # The user provider derives memberOf from spec.claim_set on its next run, so
  # for an existing User the entity is there long before the new claims are.
  local name="$1" email="$2" ref="user:default/$1" grps="" what p state deadline hint
  for p in ${ADMIN_TEAMSPACES[@]+"${ADMIN_TEAMSPACES[@]}"}; do
    grps="${grps:+${grps},}group:${p}/${p}"
  done
  what="${ref}"
  [[ -z "${grps}" ]] || what="${ref} as a member of ${grps//,/, }"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would wait up to ${ADMIN_CATALOG_TIMEOUT}s until the Backstage catalog lists ${what}"
    return 0
  fi
  if ! in_cluster statefulset backstage-postgres "${ADMIN_NS}"; then
    warn "Backstage is not deployed (no StatefulSet ${ADMIN_NS}/backstage-postgres): its catalog reads User ${name} when it starts"
    return 0
  fi
  state="$(admin_catalog_state "${ref}" "${grps}")" || state=error
  if [[ "${state}" != member ]]; then
    log "waiting up to ${ADMIN_CATALOG_TIMEOUT}s until the Backstage catalog lists ${what} (its user provider runs every minute) ..."
    deadline=$(( SECONDS + ADMIN_CATALOG_TIMEOUT ))
    while [[ "${state}" != member ]]; do
      if (( SECONDS >= deadline )); then
        case "${state}" in
          listed) hint="The catalog lists ${ref}, but its memberOf lacks one of ${grps//,/, }: the user provider has not run since the owner claims were added, or Backstage does not know the ClaimSet owner of that teamspace (the provider log then warns: Claimset 'group:<teamspace>/owner' ... not found)" ;;
          error) hint="The catalog query on ${ADMIN_NS}/backstage-postgres-0 (database backstage_plugin_catalog) failed" ;;
          *) hint="The catalog does not list ${ref}" ;;
        esac
        die "timed out after ${ADMIN_CATALOG_TIMEOUT}s waiting until the Backstage catalog lists ${what}. ${hint}. Check the user provider's schedule (catalog.providers.k8s.users in the backstage chart: every minute since 0.0.84) and its log (kubectl -n ${ADMIN_NS} logs deploy/backstage-api | grep -i -e user-provider -e claimset). A Backstage restart does not help (the scheduler keeps the next run). Run admin-user again to resume"
      fi
      sleep "${WAIT_INTERVAL:-5}"
      state="$(admin_catalog_state "${ref}" "${grps}")" || state=error
    done
  fi
  log "the Backstage catalog lists ${what}: ${email} can sign in to Backstage"
}
