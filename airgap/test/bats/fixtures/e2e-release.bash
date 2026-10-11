# shellcheck shell=bash
# e2e-release.bash — stand-ins for dry runs of e2e.sh's E1 and E4 in bats
# (harness.bats): source e2e.sh, then this file. W is a scratch dir. Nothing
# here reaches a VM, a cluster or the network.
#
# RELEASE says how the installed platform behaves:
#   r4  bundle A (app-of-apps 0.0.4): admin-user keeps
#       status.set_initial_password and restarts backstage-api, the realm shows
#       the Update Profile form, Backstage does not resolve the session in
#       time, monitoring's last operation failed and a webhook has no caBundle
#   r5  all of that fixed
# ROLLBACK says what `up --rollback` with a pre-r5 A does after an r5 B (E4):
#   gap    today's design: post fails, profile-controller and user-controller
#          stay OutOfSync (the kept Profile and Namespace wait for a prune),
#          the release record stays at B
#   fixed  the state the rollback design must reach

RELEASE="${RELEASE:-r5}"
ROLLBACK="${ROLLBACK:-gap}"
W="${W:?W must be a scratch dir}"
mkdir -p "${W}" "${STATE}" "${HTTP_DIR}" "${LAN_HOME}/e2e"
: > "${TRANSCRIPT}"
: > "${W}/calls"

make_bundle() {
  # make_bundle <dir> <app-of-apps version> [<chart> <version>]... — MANIFEST.yaml and node/charts/pins.txt
  local d="$1" v="$2"
  shift 2
  mkdir -p "${d}/node/charts"
  printf 'bundleId: %s\nappOfAppsVersion: %s # from pins\nbrokenAppOfApps: [0.0.1]\n' "$(basename "${d}")" "${v}" > "${d}/MANIFEST.yaml"
  { echo "app-of-apps ${v}"; while (( $# >= 2 )); do echo "$1 $2"; shift 2; done; } > "${d}/node/charts/pins.txt"
}

# --- the VM, the bundles, the operator's commands ------------------------------------
fresh_vm() { :; }
ensure_vm() { :; }
dotdirs() { echo none; }
bundle_dir() { printf '%s' "$1"; }
wait_apps() { pass "every Application is Synced/Healthy (stand-in)"; }
wait_until() { shift; "$@"; }   # one try: the stand-in state does not change while waiting
apps_healthy() { :; }
ca_file() { echo /dev/null; }
lan_https() { printf '200'; }
# shellcheck disable=SC2034  # P_CODE and P_LOC are read by e2e.sh
probe() { P_CODE=302 P_LOC="https://auth.${DOMAIN}/auth/realms/teknoir/protocol/openid-connect/auth?x=1"; }

up_in() {
  echo "up $*" >> "${W}/calls"
  echo "live image check: 40 pullable from Harbor, 2 only in containerd, 0 missing" >> "${TRANSCRIPT}"
  case "$*" in
    "${W}/B"*) cp "${W}/revs.B" "${W}/revs"; echo "B update" > "${W}/record"; rm -f "${W}/legacy" ;;
    "${W}/A --rollback")
      if [[ "${ROLLBACK}" == fixed ]]; then
        { cat "${W}/revs.A"; grep '^teknoir-default-' "${W}/revs.B"; } > "${W}/revs"; echo "A rollback" > "${W}/record"
      else
        cat "${W}/revs.A" > "${W}/revs"
        echo "post: Applications not Synced/Healthy after 1200 s"; return 1
      fi ;;
    "${W}/A")
      if [[ "$(cat "${W}/record" 2>/dev/null)" == "A rollback" ]]; then return 0; fi
      if [[ -s "${W}/record" ]]; then echo "bundle A is older than the deployed B: use --rollback"; return 1; fi
      if [[ -f "${W}/revs.A" ]]; then cp "${W}/revs.A" "${W}/revs"; fi
      echo "A install" > "${W}/record" ;;
  esac
}

tk() {
  # tk <dir> admin-user --email <e> --out <file>
  echo "tk $*" >> "${W}/calls"
  [[ "$2" == admin-user ]] || return 1
  ( umask 077; echo dummy-temporary > "${*: -1}" )
  if [[ "${RELEASE}" == r4 ]]; then touch "${W}/legacy" "${W}/restarted"; fi
}

lan() {
  # the netns: only kc-login.sh is expected (login_check)
  shift
  echo "lan $*" >> "${W}/calls"
  [[ "$1" == "${KCLOGIN}" ]] || { echo "release: unexpected lan $*" >&2; return 1; }
  if [[ "${RELEASE}" == r4 && " $* " == *" --forbid-profile-form "* ]]; then
    echo "kc-login: Keycloak shows the Update Profile form: forbidden by --forbid-profile-form" >&2
    return 1
  fi
  return 0
}

# --- cluster reads ---------------------------------------------------------------------
platform_ops_not_succeeded() { [[ "${RELEASE}" == r4 ]] && printf 'monitoring=Failed '; return 0; }
admission_ca() { if [[ "${RELEASE}" == r4 ]]; then echo "2 monitoring-admission/a.monitoring.coreos.com"; else echo "2 "; fi; }
digest_mismatches() { :; }
profile_owner() { [[ "${RELEASE}" == r5 ]] && echo Owner@Example.com; return 0; }
pod_states() {
  [[ "$2" == backstage-api ]] || { echo absent; return 0; }
  if [[ -e "${W}/restarted" ]]; then echo "u1 0"; else echo "u0 0"; fi
}
user_has_legacy_pw() { [[ -e "${W}/legacy" ]]; }
user_reconciled() { [[ -e "${W}/legacy" || -s "${W}/record" ]]; }
k1_secret() { :; }
bs_token() {
  : > "$2"
  [[ "${RELEASE}" == r5 ]] && echo "user:default/$(user_name "${ADMIN_EMAIL}")"
  return 0
}
release_state() { local r; r="$(cat "${W}/record" 2>/dev/null)"; printf '%s %s' "$(bundle_id "${W}/${r%% *}")" "${r#* }"; }
app_revs() { cat "${W}/revs"; }
bundle_profile_owner() { [[ "$1" == "${W}/B" ]] && echo owner@example.com; return 0; }
app_sync() {
  if [[ "${ROLLBACK}" == gap && "$(cat "${W}/record")" == "B update" ]] && grep -q -- --rollback "${W}/calls"; then
    echo OutOfSync/Healthy
  else
    echo Synced/Healthy
  fi
}
apps_unhealthy_except() {
  local a
  for a in profile-controller user-controller; do
    [[ "$(app_sync "${a}")" == Synced/Healthy ]] || printf '%s=%s ' "${a}" "$(app_sync "${a}")"
  done
}
apps_healthy_except() { [[ -z "$(apps_unhealthy_except "$1")" ]]; }
ts_apps_report() { echo "${TEAMSPACE}-emqx=Unknown/Healthy@https://teknoir.github.io/profile-plugins-helm"; }
vm_kc() {
  case "$*" in
    "get users.teknoir.org "*" -o jsonpath={.metadata.creationTimestamp}") echo 2020-01-01T00:00:00Z ;;
    "get profiles.teknoir.org ${TEAMSPACE} -o name") echo "profile.teknoir.org/${TEAMSPACE}" ;;
    "get namespace ${CRED_NS} -o name") echo "namespace/${CRED_NS}" ;;
    *) echo "release: unexpected vm_kc $*" >&2; return 1 ;;
  esac
}
