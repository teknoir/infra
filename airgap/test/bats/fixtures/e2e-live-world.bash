# shellcheck shell=bash
# e2e-live-world.bash — a stand-in node, LAN netns and operator for dry runs of
# e2e.sh's E13 (e13_checks: the non-admin, the monitoring UIs, ArgoCD, Harbor,
# platform-admin, controller RBAC, the backup, the ArgoCD admin rotation, the
# Keycloak database rotation, Prometheus) and E15 (e15_inject and the whole
# e15 sequence) in bats (harness.bats). Source e2e.sh, then this file, then
# call world_init. Nothing here reaches a VM, a cluster or the network.
#
# The world keeps its state in files under WD, so `up` with bundle B changes
# what the reads answer. These answer from it:
#   vm_kc    kubectl on the node (exact argument lists, as e2e.sh sends them)
#   vm_root  root scripts: each is checked with bash -n, then dispatched on its
#            "# vm-script: <name>" line (Keycloak admin API, read-only SQL,
#            the ArgoCD session check)
#   lan      kc-login.sh and curl in the netns (an HTTP table: who is signed
#            in is the cookie jar's file name)
#   tk       the operator's ./teknoir-airgap (up, migrate, admin-user,
#            credentials, rotate, backup)
#   vmx      the two node commands E13 runs
# Every call is logged to W/calls; an unexpected one prints "world:
# unexpected" on stderr and fails.
#
# WORLD_BREAK names one broken part. harness.bats lists, for each, the
# assertion(s) it must fail; nothing else may fail.
#   E13: nonadmin-k1-kept nonadmin-grafana admin-alertmanager grafana-anonymous
#        grafana-viewer argocd-nonadmin-apps argocd-admin-empty harbor-user
#        harbor-csrf harbor-create pa-enabled pa-login uc-star pc-exec
#        uc-forbidden prev-kept backup-tampered backup-plaintext argocd-rotate
#        argocd-initial-kept argocd-old-accepted argocd-creds-mode
#        argocd-new-refused argocd-sso-no-sync kcdb-rotate kcdb-apps
#        kcdb-login alert-errors
#   e15_inject: demo-create demo-apps monitoring-patch webhook-patch
#        master-seed master-grant master-sa
#   E15 sequence: master-lie a-no-legacy a-no-prev a-required-action
#        a-no-created b-up b-apps-unhealthy b-no-image-line
#        b-monitoring-failed b-cabundle-empty b-digest b-demo-github
#        b-legacy-kept b-k1-created b-pw-changed b-required-action
#        b-prev-kept b-master-kept b-rerun-fails b-rerun-writes
#        b-no-demo-claim b-login

WORLD_BREAK="${WORLD_BREAK:-}"
W="${W:?W must be a scratch dir}"
WORLD_N=0
WD=""

brk() { [[ " ${WORLD_BREAK} " == *" $1 "* ]]; }
world_phase() { cat "${WD}/phase"; }

world_init() {
  # world_init <phase> — a new world in a new dir: "none" (E15 starts from the
  # old layout) or "B" (an r5 node after its first admin, for E13)
  WORLD_N=$((WORLD_N + 1))
  WD="${W}/world.${WORLD_N}"
  mkdir -p "${WD}/users" "${WD}/k1" "${WD}/legacy" "${WD}/claims" "${WD}/changed" \
    "${W}/ids" "${E2E_WORK}" "${STATE}" "${HTTP_DIR}" "${LAN_HOME}/e2e"
  : > "${W}/calls"
  touch "${TRANSCRIPT}"
  echo "$1" > "${WD}/phase"
  touch "${WD}/argocd-initial"            # argocd-initial-admin-secret, until rotate argocd-admin
  if [[ "$1" == B ]]; then
    local n
    n="$(user_name "${ADMIN_EMAIL}")"
    touch "${WD}/users/${n}" "${WD}/changed/${n}"
    printf 'owner@%s\n' "${TEAMSPACE}" > "${WD}/claims/${n}"
    if brk prev-kept; then touch "${WD}/prev"; fi
  fi
  # the test age identities (vm.sh age-key --check) and a stub age that
  # "decrypts" the stand-in backup, a plain tar
  : > "${W}/ids/a.key"; : > "${W}/ids/b.key"
  VM="${W}/vm.sh"
  printf '#!/bin/sh\necho age1aaa %s/ids/a.key\necho age1bbb %s/ids/b.key\n' "${W}" "${W}" > "${VM}"
  # shellcheck disable=SC2016  # $4 is the stub's own argument
  printf '#!/bin/sh\nexec cat "$4"\n' > "${W}/age"
  chmod +x "${VM}" "${W}/age"
  # shellcheck disable=SC2034  # read by e2e.sh's age_bin
  E2E_AGE="${W}/age"
  rm -f "${LAN_HOME}/e2e"/nonadmin.* "${LAN_HOME}/e2e"/*.jar
}

# --- the operator, the VM ----------------------------------------------------------------
ensure_vm() { :; }
fresh_vm() { echo fresh_vm >> "${W}/calls"; }
bundle_dir() { printf '%s' "$1"; }
ca_file() { echo /dev/null; }
wait_until() { shift; "$@"; }   # one try: the world changes only through calls
wait_apps() { pass "every Application is Synced/Healthy (world)"; }
sleep() { :; }

tk() {
  local dir="$1" cmd="$2"
  shift 2
  echo "tk ${dir##*/} ${cmd}${*:+ $*}" >> "${W}/calls"
  case "${cmd}${*:+ $*}" in
    migrate)
      # the migration carries the old admin password over as previous-password
      if ! brk a-no-prev && [[ "$(world_phase)" == none ]]; then touch "${WD}/prev"; fi ;;
    "migrate --argo") : ;;
    "up"*) world_up "${dir}" "$@" ;;
    "admin-user --email "*" --out "*) world_admin_user "$2" "$4" ;;
    "credentials platform-admin --out "*) ( umask 077; printf 'pa-dummy' > "$3" ) ;;
    "credentials argocd-admin --out "*)
      ( umask 077; printf 'rotated-dummy' > "$3" )
      if brk argocd-creds-mode; then chmod 644 "$3"; fi ;;
    "rotate argocd-admin")
      if brk argocd-rotate; then return 1; fi
      if ! brk argocd-initial-kept; then rm -f "${WD}/argocd-initial"; fi ;;
    "rotate keycloak-db --i-know")
      touch "${WD}/kcdb-rotated"
      if brk kcdb-rotate; then return 1; fi ;;
    "backup --out "*) world_backup "$2" ;;
    *) echo "world: unexpected tk ${cmd} $*" >&2; return 1 ;;
  esac
}

world_up() {
  # world_up <bundle dir> [flags] — A or B (the dir's name) becomes the
  # platform; B (r5) converges the live state
  local ph="${1##*/}" n
  if [[ "${ph}" == B ]] && brk b-up; then echo "post: Applications not Synced/Healthy"; return 1; fi
  echo "${ph}" > "${WD}/phase"
  if [[ "${ph}" == B ]]; then
    brk b-legacy-kept || rm -f "${WD}"/legacy/*
    brk b-prev-kept || rm -f "${WD}/prev"
    brk b-master-kept || rm -f "${WD}/master"
    brk b-monitoring-failed || rm -f "${WD}/monitoring-failed"
    brk b-cabundle-empty || rm -f "${WD}"/ca-empty.*
    if brk b-k1-created; then n="$(user_name "${ADMIN_EMAIL}")"; touch "${WD}/k1/${n}"; fi
  fi
  if [[ "${ph}" != B ]] || ! brk b-no-image-line; then
    echo "live image check: 40 pullable from Harbor, 2 only in containerd, 0 missing" >> "${TRANSCRIPT}"
  fi
  return 0
}

world_admin_user() {
  # world_admin_user <email> <out file> — A records the legacy
  # status.set_initial_password; B's re-run hands nothing out and grants owner
  local n
  n="$(user_name "$1")"
  if [[ "$(world_phase)" == B ]]; then
    if brk b-rerun-fails; then return 1; fi
    printf 'owner@%s\n' "${TEAMSPACE}" > "${WD}/claims/${n}"
    brk b-no-demo-claim || printf 'owner@teknoir-demo\n' >> "${WD}/claims/${n}"
    if brk b-rerun-writes; then ( umask 077; printf 'x' > "$2" ); fi
    return 0
  fi
  touch "${WD}/users/${n}"
  brk a-no-legacy || touch "${WD}/legacy/${n}"
  ( umask 077; printf 'temporary-dummy' > "$2" )
}

world_backup() {
  # world_backup <out dir> — one encrypted (here: plain) backup with a SHA256SUMS
  local out="$1" s="${WD}/set/20261009T120000Z"
  mkdir -p "${s}/db" "${out}"
  echo info > "${s}/BACKUP.info"; echo dump > "${s}/db/keycloak.sql.gz"
  ( cd "${s}" && sha256sum BACKUP.info db/keycloak.sql.gz > SHA256SUMS )
  if brk backup-tampered; then echo tampered >> "${s}/BACKUP.info"; fi
  ( umask 077; tar -C "${WD}/set" -cf "${out}/teknoir-backup-vmtest-20261009T120000Z.tar.age" 20261009T120000Z )
}

vmx() {
  echo "vmx $*" >> "${W}/calls"
  case "$*" in
    "sudo find ${NODE_STATE_DIR}/backups -mindepth 1 -maxdepth 1 -type d -name 2*Z")
      echo "${NODE_STATE_DIR}/backups/20261009T120000Z"
      if brk backup-plaintext; then echo "${NODE_STATE_DIR}/backups/20261008T120000Z"; fi ;;
    "sudo rm -f /root/e2e-argocd-old.pw") : ;;
    *) echo "world: unexpected vmx $*" >&2; return 1 ;;
  esac
}

# --- kubectl on the node ---------------------------------------------------------------------
world_apps_json() {
  local ph mon=Succeeded demo="" dsync=Synced ts=0 async=Synced
  ph="$(world_phase)"
  [[ ! -e "${WD}/monitoring-failed" ]] || mon=Failed
  if [[ -e "${WD}/demo" ]] && ! brk demo-apps; then
    if [[ "${ph}" == B ]] && ! brk b-demo-github; then demo="harbor.${DOMAIN}/teknoir"
    else demo="https://teknoir.github.io/profile-plugins-helm" dsync=Unknown; fi
  fi
  [[ "${ph}" != B ]] || ts=1
  if { [[ "${ph}" == B ]] && brk b-apps-unhealthy; } || { [[ -e "${WD}/kcdb-rotated" ]] && brk kcdb-apps; }; then async=OutOfSync; fi
  jq -n --arg mon "${mon}" --arg demo "${demo}" --arg dsync "${dsync}" --argjson ts "${ts}" --arg async "${async}" \
        --arg h "harbor.${DOMAIN}/teknoir" --arg root "${ROOT_APP}" --argjson plugins "$(printf '%s\n' "${PLUGINS[@]}" | jq -R . | jq -cs .)" '
    def app($n; $tracked; $op; $sync; $repo): {
      metadata: {name: $n, annotations: (if $tracked then {"argocd.argoproj.io/tracking-id": "\($root):argoproj.io/Application:teknoir-system/\($n)"} else {} end)},
      spec: {project: "default", source: {repoURL: $repo, targetRevision: "0.0.5"}},
      status: {sync: {status: $sync, revision: "0.0.5"}, health: {status: "Healthy"}, operationState: {phase: $op}}};
    {items: ([app($root; false; "Succeeded"; "Synced"; $h), app("monitoring"; true; $mon; "Synced"; $h), app("auth"; true; "Succeeded"; $async; $h)]
      + (if $ts == 1 then [$plugins[] | app("teknoir-default-\(.)"; false; "Succeeded"; "Synced"; $h)] else [] end)
      + (if $demo != "" then [$plugins[] | app("teknoir-demo-\(.)"; false; "Succeeded"; $dsync; $demo)] else [] end))}'
}

world_webhooks() {
  # world_webhooks <validating|mutating>webhookconfigurations
  local kind="${1%s}" ca="LS0tLS1CRUdJTg==" hook
  [[ ! -e "${WD}/ca-empty.${kind}" ]] || ca=""
  hook="prometheusrulemutate.monitoring.coreos.com"
  [[ "${kind}" == mutating* ]] || hook="prometheusrulevalidate.monitoring.coreos.com"
  jq -n --arg ca "${ca}" --arg hook "${hook}" --arg kind "${kind}" '{items: (
    [{metadata: {name: "monitoring-kube-prometheus-admission"}, webhooks: [{name: $hook, clientConfig: {caBundle: $ca}}]}]
    + (if $kind | startswith("validating") then [{metadata: {name: "istio-validator-istio-system"}, webhooks: [{name: "x", clientConfig: {}}]}] else [] end))}'
}

world_pods_json() {
  local id="sha256:ab39"
  if [[ "$(world_phase)" == B ]] && brk b-digest; then id="sha256:ffff"; fi
  jq -n --arg id "${id}" '{items: [{metadata: {namespace: "teknoir-auth", name: "keycloak-0"},
    spec: {containers: [{name: "keycloak", image: "ghcr.io/teknoir/keycloak-theme:sha-29d2ed6a@sha256:ab39"}]},
    status: {phase: "Running", containerStatuses: [{name: "keycloak", imageID: ("ghcr.io/teknoir/keycloak-theme@" + $id)}]}}]}'
}

world_can_i() {
  # world_can_i auth can-i <args...> --as=system:serviceaccount:<ns>:<sa> — the rbac-k3d matrix
  local as="${*: -1}" q
  q="${*:3:$#-3}"
  case "${as##*:}|${q}" in
    "user-controller|create rolebindings --all-namespaces"|"user-controller|bind clusterroles/teknoir-admin"|"profile-controller|create rolebindings -n ${TEAMSPACE}")
      echo yes ;;
    "user-controller|* *") if brk uc-star; then echo yes; else echo no; fi ;;
    "profile-controller|create pods --subresource=exec -n ${TEAMSPACE}") if brk pc-exec; then echo yes; else echo no; fi ;;
    *) echo no ;;
  esac
}

vm_kc() {
  local a="$*" in="" n
  [[ "${a}" != "create -f -" ]] || in="$(cat)"
  echo "vm_kc ${a}" >> "${W}/calls"
  case "${a}" in
    "create -f -")
      case "$(jq -r .kind <<<"${in}")" in
        User)
          n="$(jq -r .metadata.name <<<"${in}")"
          [[ "$(jq -r '.spec.claims_v0.role' <<<"${in}")" == viewer ]] || return 1
          touch "${WD}/users/${n}" "${WD}/k1/${n}" ;;
        Profile)
          if brk demo-create; then return 1; fi
          jq -e --arg o "$(lower "${ADMIN_EMAIL}")" '.metadata.name == "teknoir-demo" and .spec.owner == {kind: "User", name: $o}' <<<"${in}" >/dev/null || return 1
          touch "${WD}/demo" ;;
        *) return 1 ;;
      esac ;;
    "get users.teknoir.org "*" -o name") [[ -e "${WD}/users/$3" ]] || return 1; echo "user.teknoir.org/$3" ;;
    "get users.teknoir.org "*" -o jsonpath={.status.computed_status}") [[ ! -e "${WD}/users/$3" ]] || printf 'Ready' ;;
    "get users.teknoir.org "*" -o go-template="*"{{with "*) [[ ! -e "${WD}/legacy/$3" ]] || printf 'legacy-dummy' ;;
    "get users.teknoir.org "*" -o go-template="*) [[ ! -e "${WD}/legacy/$3" ]] || printf 'yes' ;;
    "get users.teknoir.org "*" -o jsonpath={range .spec.claim_set[*]}"*) cat "${WD}/claims/$3" 2>/dev/null || true ;;
    "annotate users.teknoir.org "*" e2e.teknoir.org/poke="*" --overwrite")
      # user-controller's reconcile: the user has set a password (no UPDATE_PASSWORD): K1 case b
      if [[ -e "${WD}/changed/$3" ]] && ! brk nonadmin-k1-kept; then rm -f "${WD}/k1/$3"; fi ;;
    "-n ${CRED_NS} get secret user-initial-password-"*" -o jsonpath={.data.password}")
      [[ ! -e "${WD}/k1/${5#user-initial-password-}" ]] || printf '%s' "$(printf 'dummy-temporary' | base64)" ;;
    "-n ${CRED_NS} get secret user-initial-password-"*" --ignore-not-found -o name")
      [[ ! -e "${WD}/k1/${5#user-initial-password-}" ]] || echo "secret/$5" ;;
    "-n teknoir-system get applications.argoproj.io ${ROOT_APP} -o jsonpath={.spec.project}") printf 'default' ;;
    "-n teknoir-system get deployment "*" -o jsonpath={.spec.template.spec.serviceAccountName}") printf '%s' "$5" ;;
    "auth can-i "*) world_can_i "$@" ;;
    "-n teknoir-system logs deployment/"*" --tail=-1")
      echo 'INFO reconciled'
      if [[ "$4" == deployment/user-controller ]] && brk uc-forbidden; then
        echo 'ERROR rolebindings.rbac.authorization.k8s.io is forbidden: User "system:serviceaccount:teknoir-system:user-controller" cannot create'
      fi ;;
    "-n teknoir-system logs -l app.kubernetes.io/name=prometheus -c prometheus --since-time="*" --tail=-1")
      echo 'ts=2026-10-09T12:00:00Z level=info msg="Completed loading of configuration file"'
      if brk alert-errors; then echo 'ts=2026-10-09T12:01:00Z level=error component=notifier msg="Error sending alerts" err="403 Forbidden"'; fi ;;
    "-n teknoir-auth get secret keycloak-admin --ignore-not-found -o go-template="*)
      if [[ -e "${WD}/prev" ]]; then printf 'password previous-password username '; else printf 'password username '; fi ;;
    "-n teknoir-system get secret argocd-initial-admin-secret --ignore-not-found -o name")
      [[ ! -e "${WD}/argocd-initial" ]] || echo secret/argocd-initial-admin-secret ;;
    "-n teknoir-system get applications.argoproj.io -o json") world_apps_json ;;
    "-n teknoir-system get applications.argoproj.io -o name") world_apps_json | jq -r '.items[] | "application.argoproj.io/" + .metadata.name' ;;
    "-n teknoir-system get applications.argoproj.io --no-headers -o custom-columns="*)
      world_apps_json | jq -r '.items[] | "\(.metadata.name) \(.status.sync.status) \(.status.health.status) \(.spec.source.targetRevision) \(.status.sync.revision)"' ;;
    "-n teknoir-system get applications.argoproj.io monitoring -o jsonpath={.status.sync.revision}") printf '0.0.4' ;;
    "-n teknoir-system get applications.argoproj.io monitoring -o jsonpath={.status.operationState.phase}")
      world_apps_json | jq -r '.items[] | select(.metadata.name == "monitoring") | .status.operationState.phase' ;;
    "-n teknoir-system patch applications.argoproj.io monitoring --type=merge -p "*)
      if brk monitoring-patch; then return 1; fi
      # a stale Failed operation of the current revision, as on the live node
      jq -e '.status.operationState | .phase == "Failed" and .retryCount == 5 and .operation.sync.revision == "0.0.4"
             and .syncResult.revision == "0.0.4" and .operation.initiatedBy.automated == true' <<<"$8" >/dev/null || return 1
      touch "${WD}/monitoring-failed" ;;
    "get validatingwebhookconfigurations -o name"|"get mutatingwebhookconfigurations -o name")
      world_webhooks "$2" | jq -r --arg k "${2%s}" '.items[] | "\($k).admissionregistration.k8s.io/\(.metadata.name)"' ;;
    "get validatingwebhookconfigurations -o json"|"get mutatingwebhookconfigurations -o json") world_webhooks "$2" ;;
    "get "*"webhookconfiguration.admissionregistration.k8s.io/monitoring-kube-prometheus-admission -o json")
      world_webhooks "${2%%.*}s" | jq '.items[0]' ;;
    "patch "*"webhookconfiguration.admissionregistration.k8s.io/monitoring-kube-prometheus-admission --type=json -p "*)
      if brk webhook-patch; then return 1; fi
      jq -e '. == [{op: "add", path: "/webhooks/0/clientConfig/caBundle", value: ""}]' <<<"$5" >/dev/null || return 1
      touch "${WD}/ca-empty.${2%%.*}" ;;
    "get pods -A -o json") world_pods_json ;;
    *) echo "world: unexpected vm_kc ${a}" >&2; return 1 ;;
  esac
  return 0
}

# --- root scripts on the node ------------------------------------------------------------------
vm_root() {
  local s name u
  s="$(cat)"
  if ! bash -n <<<"${s}" 2>/dev/null; then echo "world: a VM root script does not parse" >&2; return 2; fi
  name="$(sed -n 's/^# vm-script: //p' <<<"${s}" | head -n1)"
  echo "vm_root ${name:-unnamed}" >> "${W}/calls"
  case "${name}" in
    kc_user_state)
      u="$(sed -n 's/^R=[^ ]* U=//p' <<<"${s}" | head -n1)"
      case "${u}" in
        platform-admin) if brk pa-enabled; then echo "enabled=true actions=0"; else echo "enabled=false actions=0"; fi ;;
        "${ADMIN_USER}")
          if { [[ "$(world_phase)" == B ]] && brk b-required-action; } || { [[ "$(world_phase)" != B ]] && brk a-required-action; }; then
            echo "enabled=true actions=1"
          else
            echo "enabled=true actions=0"
          fi ;;
        *) echo absent ;;
      esac ;;
    kc_master_clients) if [[ -e "${WD}/master" ]]; then echo "3 200"; else echo "0 401"; fi ;;
    e15_master_clients)
      printf 'seed teknoir 201\nseed argocd 201\n'
      if brk master-seed; then echo "seed harbor 409"; else echo "seed harbor 201"; fi
      brk master-lie || touch "${WD}/master"
      if brk master-grant; then echo "grant 403 3"; else echo "grant 204 3"; fi
      if brk master-sa; then echo "sa-users 403"; else echo "sa-users 200"; fi ;;
    kc_pw_created)
      if brk a-no-created; then :
      elif [[ "$(world_phase)" == B ]] && brk b-pw-changed; then echo " 1760000099000"
      else echo " 1760000000000"; fi ;;
    argocd_old_password) if [[ -e "${WD}/argocd-initial" ]]; then echo saved; else echo absent; fi ;;
    argocd_session_vm) if brk argocd-old-accepted; then printf '200'; else printf '401'; fi ;;
    *) echo "world: unexpected vm_root script ${name:-without a vm-script line}" >&2; return 1 ;;
  esac
}

# --- the LAN netns -------------------------------------------------------------------------------
lan() {
  shift   # the working directory
  case "$1" in
    "${KCLOGIN}") shift; world_kc_login "$@" ;;
    curl) shift; world_curl "$@" ;;
    *) echo "world: unexpected lan $*" >&2; return 1 ;;
  esac
}

world_kc_login() {
  # kc-login.sh: a password login (the forced change answered), or an SSO
  # login into ArgoCD or Harbor with the jar's Keycloak session
  local user="" sc="" newf="" n
  while (( $# )); do
    case "$1" in
      --user) user="$2"; shift ;;
      --session-cookie) sc="$2"; shift ;;
      --new-password-file) newf="$2"; shift ;;
      --url|--cookie-jar|--password-file|--cacert|--accept-status) shift ;;
    esac
    shift
  done
  echo "kc-login ${user:-sso:${sc}}" >> "${W}/calls"
  [[ -z "${sc}" ]] || return 0
  case "$(lower "${user}")" in
    platform-admin)
      if brk pa-login; then return 0; fi
      echo "kc-login: Keycloak refused the sign-in: Account is disabled"; return 1 ;;
    "$(lower "${ADMIN_USER}")")
      if [[ -e "${WD}/kcdb-rotated" ]] && brk kcdb-login; then echo "kc-login: Invalid username or password"; return 1; fi
      if [[ "$(world_phase)" == B ]] && brk b-login; then echo "kc-login: Invalid username or password"; return 1; fi
      touch "${WD}/changed/$(user_name "${user}")" ;;
    *)
      n="$(user_name "${user}")"
      [[ -e "${WD}/users/${n}" ]] || return 1
      [[ -z "${newf}" ]] || ( umask 077; printf 'changed-by-the-user' > "${newf}" )
      touch "${WD}/changed/${n}" ;;
  esac
}

R_CODE="" R_BODY="" R_HDRS=""
world_http() {
  # world_http <who> <method> <url> <data> <-H values...> — sets R_CODE, R_BODY, R_HDRS
  local who="$1" m="$2" url="$3" data="$4" d="${DOMAIN}" app h csrf=0 v
  shift 4
  R_CODE=000 R_BODY="" R_HDRS=""
  case "${m} ${url}" in
    "GET https://${d}/teknoir-system/grafana/api/user")
      [[ "${who}" == admin ]] || return 0
      v="${ADMIN_USER}"
      if brk grafana-anonymous; then v=anonymous; fi
      R_CODE=200 R_BODY="$(jq -cn --arg l "${v}" --arg e "${ADMIN_USER}" '{login: $l, email: $e}')" ;;
    "GET https://${d}/teknoir-system/grafana/api/user/orgs")
      v=Admin
      if brk grafana-viewer; then v=Viewer; fi
      R_CODE=200 R_BODY="[{\"orgId\": 1, \"name\": \"Main Org.\", \"role\": \"${v}\"}]" ;;
    "GET https://${d}/teknoir-system/"*/)
      app="${url#"https://${d}/teknoir-system/"}"; app="${app%/}"
      if [[ "${who}" == admin ]]; then R_CODE=200; if brk "admin-${app}"; then R_CODE=403; fi
      else R_CODE=403; if brk "nonadmin-${app}"; then R_CODE=200; fi; fi ;;
    "GET https://argocd.${d}/api/v1/applications")
      R_CODE=200 R_BODY='{"metadata": {}, "items": null}'
      if [[ "${who}" == admin ]] && ! brk argocd-admin-empty; then R_BODY='{"items": [{}, {}, {}]}'; fi
      if [[ "${who}" == nonadmin ]] && brk argocd-nonadmin-apps; then R_BODY='{"items": [{}, {}]}'; fi ;;
    "GET https://argocd.${d}/api/v1/account/can-i/applications/sync/default/${ROOT_APP}")
      R_CODE=200 R_BODY='{"value": "yes"}'
      if brk argocd-sso-no-sync; then R_BODY='{"value": "no"}'; fi ;;
    "POST https://argocd.${d}/api/v1/session")
      R_CODE=401
      if [[ "$(jq -r .password "${data#@}" 2>/dev/null)" == rotated-dummy ]] && ! brk argocd-new-refused; then R_CODE=200 R_BODY='{"token": "x"}'; fi ;;
    "GET https://harbor.${d}/api/v2.0/users/current")
      v="$(lower "${NONADMIN_EMAIL}")"
      if brk harbor-user; then v=someone-else; fi
      R_CODE=200 R_BODY="{\"username\": \"${v}\"}"
      brk harbor-csrf || R_HDRS=$'X-Harbor-CSRF-Token: tok-e2e\r\n' ;;
    "POST https://harbor.${d}/api/v2.0/projects")
      for h in "$@"; do
        [[ "${h}" != @* ]] || h="$(cat "${h#@}")"
        [[ "${h}" != "X-Harbor-CSRF-Token: tok-e2e" ]] || csrf=1
      done
      if (( ! csrf )); then R_CODE=403 R_BODY='{"errors": [{"code": "FORBIDDEN", "message": "CSRF token invalid"}]}'
      elif brk harbor-create; then R_CODE=201
      else R_CODE=403 R_BODY='{"errors": [{"code": "FORBIDDEN", "message": "forbidden"}]}'; fi ;;
    *) echo "world: unexpected curl ${m} ${url}" >&2 ;;
  esac
}

world_curl() {
  # curl in the netns: -D/-o/-w as http_req and app_status use them
  local hf="" bf="" wf="" jar="" url="" data="" m=GET who=none out
  local -a hs=()
  while (( $# )); do
    case "$1" in
      -D) hf="$2"; shift ;;
      -o) bf="$2"; shift ;;
      -w) wf="$2"; shift ;;
      -b) jar="$2"; shift ;;
      -H) hs+=("$2"); shift ;;
      --data-binary) data="$2" m=POST; shift ;;
      -c|-m|--cacert|--max-redirs) shift ;;
      -*) ;;
      *) url="$1" ;;
    esac
    shift
  done
  case "${jar##*/}" in admin.jar) who="admin" ;; nonadmin.jar) who="nonadmin" ;; esac
  echo "curl ${who} ${m} ${url}" >> "${W}/calls"
  world_http "${who}" "${m}" "${url}" "${data}" ${hs[@]+"${hs[@]}"}
  [[ -z "${hf}" ]] || printf 'HTTP/1.1 %s x\r\n%s\r\n' "${R_CODE}" "${R_HDRS}" > "${hf}"
  [[ -z "${bf}" || "${bf}" == /dev/null ]] || printf '%s' "${R_BODY}" > "${bf}"
  out="${wf//\\n/$'\n'}"
  out="${out//%\{http_code\}/${R_CODE}}"
  out="${out//%\{url_effective\}/${url}}"
  printf '%s' "${out}"
}

# --- the driver --------------------------------------------------------------------------------
# shellcheck disable=SC2034,SC2317  # the e15 mode's settings and stubs are read and called by e2e.sh's e15
world_dry_run() {
  # world_dry_run e13|inject|e15 [break...] — one dry run per break ("" = the
  # healthy world): its stderr goes to W/out.<break>, its calls to
  # W/calls.<break> (<break> "none" for ""); prints "<break> FAILED=<n> PASSED=<n>"
  #   e13     e13_checks on an r5 node with its first admin
  #   inject  e15_inject on bundle A's platform
  #   e15     the whole e15, from the old layout to the checks after B; its
  #           step 5 (e11_checks, e13_checks, e14_checks) is only recorded,
  #           their own dry runs cover them
  local mode="$1" b
  shift
  if [[ "${mode}" == e15 ]]; then
    E2E_BUNDLE="${W}/A" E2E_BUNDLE_B="${W}/B" E2E_OLD_SETUP="echo old-setup >> '${W}/calls'" ALLOW_DESTROY=1
    bundle_profile_owner() { echo owner@example.com; }
    e11_checks() { echo e11_checks >> "${W}/calls"; }
    e13_checks() { echo "e13_checks ${1##*/}" >> "${W}/calls"; }
    e14_checks() { echo e14_checks >> "${W}/calls"; }
  fi
  for b in "$@"; do
    WORLD_BREAK="${b}"
    TL_NFAIL=0 TL_NPASS=0
    case "${mode}" in
      e13)
        set_admin owner@example.com; world_init B
        tl_case E13 "world ${b:-healthy}"; e13_checks "${W}/B" 2> "${W}/out.${b:-none}" ;;
      inject)
        set_admin owner@example.com; world_init A
        tl_case E15 "inject ${b:-healthy}"; e15_inject 2> "${W}/out.${b:-none}" ;;
      e15) world_init none; e15 2> "${W}/out.${b:-none}" ;;
      *) echo "world_dry_run: unknown mode ${mode}" >&2; return 2 ;;
    esac
    cp "${W}/calls" "${W}/calls.${b:-none}"
    printf '%s FAILED=%s PASSED=%s\n' "${b:-none}" "${TL_NFAIL}" "${TL_NPASS}"
  done
}
