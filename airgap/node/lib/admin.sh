# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016  # DRY_RUN, NODE_ROOT, TEKNOIR_DOMAIN come from common.sh and the site env; jq programs are single-quoted on purpose
#
# lib/admin.sh — `teknoir-node admin-user`: the first platform administrator
# (docs/airgap/DESIGN.md "First admin user", adversarial review corrections).
#
#   teknoir-node admin-user --email ADDR --out FILE [--display-name NAME] [--dry-run]
#
#   1. create the users.teknoir.org User <name> = lowercased email with "@"
#      replaced by "-at-" (the Backstage catalog entity default/<name> that
#      sign-in resolves), spec: email, email_verified true, enabled true,
#      claims_v0.role superadmin, plugins []. An existing User is not modified;
#   2. wait until user-controller has created the Keycloak user
#      (status.computed_status set);
#   3. put that Keycloak user into group `admin` of realm `teknoir` through the
#      Keycloak admin REST API, logged in as the master-realm admin from
#      Secret teknoir-auth/keycloak-admin (credentials on a curl config pipe);
#   4. restart Deployment backstage-api once, unless all its pods started after
#      the User was created (the catalog reads Users only every 30 minutes);
#   5. write status.set_initial_password to FILE (mode 0600, owned by
#      $SUDO_USER when set). The password is never printed; Keycloak asks for
#      a new one at the first login.
# Re-running is safe and converges (e.g. after a timeout).

ADMIN_NS="${ADMIN_NS:-teknoir-system}"
ADMIN_TIMEOUT="${ADMIN_TIMEOUT:-300}"
ADMIN_TOKEN=""

cmd_admin_user() {
  local email="" out="" display="" name dir
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --email) [[ $# -ge 2 ]] || die "--email needs an address"; email="$2"; shift 2 ;;
      --email=*) email="${1#*=}"; shift ;;
      --out) [[ $# -ge 2 ]] || die "--out needs a file"; out="$2"; shift 2 ;;
      --out=*) out="${1#*=}"; shift ;;
      --display-name) [[ $# -ge 2 ]] || die "--display-name needs a value"; display="$2"; shift 2 ;;
      --display-name=*) display="${1#*=}"; shift ;;
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
  [[ ! -L "${out}" && ! -d "${out}" ]] || die "admin-user: --out ${out} is a symlink or a directory"
  dir="$(dirname "${out}")"
  [[ -d "${dir}" ]] || die "admin-user: directory ${dir} does not exist"
  ADMIN_JQ="$(admin_tool jq)" || exit 1

  in_cluster customresourcedefinitions.apiextensions.k8s.io users.teknoir.org \
    || die "admin-user: the users.teknoir.org CRD is missing (is user-controller deployed?)"
  admin_ensure_user "${name}" "${email}" "${display}" || return 0
  wait_for "user-controller to create ${email} in Keycloak (logs: kubectl -n ${ADMIN_NS} logs deploy/user-controller)" \
    "${ADMIN_TIMEOUT}" admin_user_reconciled "${name}"
  admin_keycloak_group "${email}"
  admin_restart_backstage "${name}"
  admin_write_password "${name}" "${email}" "${out}"
}

admin_usage() {
  cat >&2 <<'EOF'
Usage: teknoir-node admin-user --email ADDR --out FILE [--display-name NAME] [--dry-run]

Creates the first platform administrator: a superadmin User (name: the email
with @ -> -at-), Keycloak group `admin` in realm teknoir, a one-time restart
of backstage-api so the catalog knows the user, and the temporary password in
FILE (mode 0600, never printed). Safe to re-run.
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
  # admin_ensure_user <name> <email> <display-name> — 1 in dry-run when the
  # User does not exist yet (nothing further can be checked then)
  local name="$1" email="$2" display="$3" have manifest
  if in_cluster users.teknoir.org "${name}"; then
    have="$(kc get users.teknoir.org "${name}" -o jsonpath='{.spec.email}')" || die "cannot read User ${name}"
    [[ "${have,,}" == "${email}" ]] || die "User ${name} exists with another email (${have}); not touching it"
    log "User ${name} exists; left as it is"
    return 0
  fi
  manifest="$("${ADMIN_JQ}" -cn --arg n "${name}" --arg e "${email}" --arg d "${display}" '
      {apiVersion: "teknoir.org/v1", kind: "User", metadata: {name: $n},
       spec: ({email: $e, email_verified: true, enabled: true, claims_v0: {role: "superadmin"}, plugins: []}
              + (if $d != "" then {display_name: $d} else {} end))}')"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would create User ${name} (superadmin, ${email}), wait for user-controller, add it to Keycloak group admin, restart backstage-api once, and write its temporary password"
    return 1
  fi
  kc create -f - <<<"${manifest}" >/dev/null || die "cannot create User ${name}"
  changed "User ${name} (superadmin, ${email})"
}

admin_user_reconciled() {
  [[ -n "$(kc get users.teknoir.org "$1" -o jsonpath='{.status.computed_status}' 2>/dev/null)" ]]
}

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

admin_kc() {
  # admin_kc <method> <path> — Keycloak admin API call with the bearer token on
  # a pipe; prints the body, dies unless 2xx
  local resp code
  # shellcheck disable=SC2086  # ADMIN_CURL_OPTS: extra curl flags (e.g. --cacert FILE)
  resp="$(curl -sS -w '\n%{http_code}' -X "$1" ${ADMIN_CURL_OPTS:-} \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "${ADMIN_TOKEN}") "${ADMIN_KC_URL}$2")" \
    || die "Keycloak admin API $1 $2: request failed"
  code="${resp##*$'\n'}"
  [[ "${code}" == 2* ]] || die "Keycloak admin API $1 $2: HTTP ${code}"
  printf '%s' "${resp%"${code}"}"
}

admin_keycloak_group() {
  local email="$1" realm user pass resp code uid gid member body
  ADMIN_KC_URL="${ADMIN_KEYCLOAK_URL:-https://auth.${TEKNOIR_DOMAIN}}"
  realm="${ADMIN_KEYCLOAK_REALM:-teknoir}"
  user="$(secret_value teknoir-auth keycloak-admin username)" || die "cannot read Secret teknoir-auth/keycloak-admin"
  pass="$(secret_value teknoir-auth keycloak-admin password)" || die "cannot read Secret teknoir-auth/keycloak-admin"
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
  # admin_kc dies on errors, so its output is captured before jq reads it
  body="$(admin_kc GET "/admin/realms/${realm}/users?username=${email/@/%40}&exact=true")" || die "cannot look up ${email}"
  uid="$("${ADMIN_JQ}" -r --arg e "${email}" '[.[]? | select((.username // "" | ascii_downcase) == $e)][0].id // empty' <<<"${body}")" \
    || die "cannot parse the users of realm ${realm}"
  [[ -n "${uid}" ]] || die "no Keycloak user ${email} in realm ${realm} (user-controller must run with KEYCLOAK_REALM=${realm})"
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
  ADMIN_TOKEN=""
}

admin_rolled_out() {
  kc -n "${ADMIN_NS}" rollout status deployment/backstage-api --timeout=10s >/dev/null 2>&1
}

admin_restart_backstage() {
  local name="$1" created deploy sel pods oldest
  if ! in_cluster deployment backstage-api "${ADMIN_NS}"; then
    warn "no Deployment ${ADMIN_NS}/backstage-api: once Backstage runs, its catalog reads the User within 30 minutes (or restart it)"
    return 0
  fi
  created="$(kc get users.teknoir.org "${name}" -o jsonpath='{.metadata.creationTimestamp}')" || die "cannot read User ${name}"
  deploy="$(kc -n "${ADMIN_NS}" get deployment backstage-api -o json)" || die "cannot read Deployment backstage-api"
  sel="$("${ADMIN_JQ}" -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"${deploy}")"
  [[ -n "${sel}" ]] || die "Deployment backstage-api has no matchLabels selector"
  pods="$(kc -n "${ADMIN_NS}" get pods -l "${sel}" -o json)" || die "cannot list the backstage-api pods"
  oldest="$("${ADMIN_JQ}" -r '[.items[] | select(.metadata.deletionTimestamp == null) | .status.startTime // empty] | min // ""' <<<"${pods}")"
  if [[ -z "${oldest}" ]]; then
    log "backstage-api has no running pod; it reads the User when it starts"
    return 0
  fi
  if [[ "${oldest}" > "${created}" ]]; then
    log "backstage-api started after User ${name} was created: its catalog has the user"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would restart backstage-api once, so its catalog reads User ${name} now"
    return 0
  fi
  kc -n "${ADMIN_NS}" rollout restart deployment/backstage-api >/dev/null || die "cannot restart backstage-api"
  changed "restarted backstage-api once, so its catalog reads User ${name}"
  wait_for "backstage-api to roll out" "${ADMIN_TIMEOUT}" admin_rolled_out
}

admin_write_password() {
  local name="$1" email="$2" out="$3" pw tmp
  pw="$(kc get users.teknoir.org "${name}" -o jsonpath='{.status.set_initial_password}')" || die "cannot read User ${name}"
  if [[ -z "${pw}" ]]; then
    warn "User ${name} records no temporary password (the Keycloak user existed before user-controller saw it): set one in Keycloak, realm teknoir, Users > ${email} > Credentials"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    pw=""
    log "[dry-run] would write the temporary password of ${email} to ${out} (mode 0600)"
    return 0
  fi
  tmp="$(mktemp "$(dirname "${out}")/.teknoir-admin-user.XXXXXX")" || die "cannot create a file next to ${out}"
  chmod 0600 "${tmp}"
  printf '%s\n' "${pw}" > "${tmp}" || { rm -f -- "${tmp}"; die "cannot write ${out}"; }
  pw=""
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown "${SUDO_USER}:" "${tmp}" 2>/dev/null || warn "cannot hand ${out} to ${SUDO_USER}; it stays root's"
  fi
  mv -f -- "${tmp}" "${out}" || { rm -f -- "${tmp}"; die "cannot write ${out}"; }
  log "temporary password of ${email} written to ${out} (mode 0600, not shown); Keycloak asks for a new one at the first login"
}
