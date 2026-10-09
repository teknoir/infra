#!/usr/bin/env bash
# release-ready-test.sh — unit test (no cluster) of lib/release.sh's post
# phase (r5: R2 classification, HYG-C3 failed-operation re-sync, SEC-C10
# keycloak-admin previous-password clean-up). Pure jq on fixture JSON, plus a
# stub kc for the wait loop:
#
#   1. classification: the root and every Application tracked by it
#      ("app-of-apps:..." or "<ns>_app-of-apps:...") are platform (strict); a
#      teamspace Application is strict only when its Profile carries an ArgoCD
#      tracking-id (and the ownerReference uid matches); anything else is
#      reported only;
#   2. readiness: teknoir-demo-* Unknown only warns; teknoir-default-* Unknown
#      (Profile declared in GitOps) is not ready; a stale Failed operation on
#      the current revision gives the reason "last sync to <rev> Failed: ...";
#      a Failed operation of an older revision gives none; a pending
#      .operation is not ready; a missing root is not ready;
#   3. re-sync: only platform Applications with a stale failed operation and
#      no pending operation are candidates; the merge patch body sets
#      .operation (revision, prune, syncOptions, retry from the spec) and
#      nulls status.operationState, guarded by resourceVersion;
#   4. post_wait_applications: exactly one patch per run even when the
#      re-sync fails again (then post fails, naming the reason); a re-sync
#      that succeeds lets post pass; teamspaces not in GitOps are reported in
#      one WARN; dry-run patches nothing;
#   5. post_keycloak_admin_cleanup: previous-password is removed (JSON patch
#      with a resourceVersion test) only after a 200 login with key password;
#      401 keeps it with a WARN; dry-run and a Secret without the key change
#      nothing; the password is never printed;
#   6. release_status prints one apps line per class.
#
# Usage: airgap/test/unit/release-ready-test.sh
# shellcheck disable=SC2016  # the scenario scripts expand in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-release.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/tmp"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
eq() { [[ "$1" == "$2" ]] || { printf '      want: %s\n      got:  %s\n' "$1" "$2"; return 1; }; }

# --- fixtures ---------------------------------------------------------------
# A ready chart Application: Synced/Healthy, compared at its spec, operation
# Succeeded. app <name> <chart> <version> [tracking-id] [owner-profile owner-uid]
app() {
  jq -cn --arg n "$1" --arg c "$2" --arg v "$3" --arg t "${4:-}" --arg o "${5:-}" --arg u "${6:-}" '
    {repoURL: "harbor.teknoir.airgapped/teknoir", chart: $c, targetRevision: $v} as $src
    | {apiVersion: "argoproj.io/v1alpha1", kind: "Application",
       metadata: ({name: $n, namespace: "teknoir-system", resourceVersion: "4711"}
                  + (if $t != "" then {annotations: {"argocd.argoproj.io/tracking-id": $t}} else {} end)
                  + (if $o != "" then {ownerReferences: [{apiVersion: "teknoir.org/v1", kind: "Profile", name: $o, uid: $u}]} else {} end)),
       spec: {project: "teknoir-local", source: $src,
              syncPolicy: {automated: {enabled: true, prune: true, selfHeal: true},
                           syncOptions: ["ServerSideApply=true", "RespectIgnoreDifferences=true"],
                           retry: {limit: 10, backoff: {duration: "30s", factor: 2, maxDuration: "5m"}}}},
       status: {sync: {status: "Synced", revision: $v, comparedTo: {source: $src}},
                health: {status: "Healthy"}, reconciledAt: "2026-10-09T07:33:24Z",
                operationState: {phase: "Succeeded", message: "successfully synced (all tasks run)",
                                 syncResult: {revision: $v}, operation: {sync: {revision: $v}}}}}'
}
tid() { printf 'app-of-apps:argoproj.io/Application:teknoir-system/%s' "$1"; }
# the live monitoring failure of 2026-10-09 (status Synced/Healthy, last op Failed on 0.0.4)
stale_failed() { jq -c '.status.operationState = {phase: "Failed", retryCount: 5,
  message: "one or more synchronization tasks completed unsuccessfully (retried 5 times).",
  syncResult: {revision: .status.sync.revision}, operation: {sync: {revision: .status.sync.revision}}}'; }
unknown() { jq -c '.status.sync.status = "Unknown" | del(.status.operationState)
  | .status.conditions = [{type: "ComparisonError", message: "Failed to load target state: failed to fetch chart"}]'; }

{
  app app-of-apps app-of-apps 0.0.5
  app monitoring monitoring 0.0.4 "$(tid monitoring)" | stale_failed
  # a failure of an older revision, superseded by the current Synced one
  app auth auth 0.0.9 "$(tid auth)" | jq -c '.status.operationState = {phase: "Failed", message: "old", syncResult: {revision: "0.0.8"}}'
  app cert-manager cert-manager 0.0.2 "teknoir-system_$(tid cert-manager)"
  app teknoir-demo-jwks profile-plugin-jwks 0.0.99 "" teknoir-demo u-demo | unknown
  app teknoir-default-jwks profile-plugin-jwks 0.0.99 "" teknoir-default u-default | unknown
  app teknoir-default-emqx profile-plugin-emqx 0.0.99 "" teknoir-default u-default
  app teknoir-default-grafana profile-plugin-grafana 0.0.99 "" teknoir-default u-default | stale_failed
  app teknoir-stale-mongodb profile-plugin-mongodb 0.0.99 "" teknoir-default u-old | unknown
  app stray stray 1.0.0 | unknown
  app other-tracked x 1.0.0 "profile-controller:argoproj.io/Application:teknoir-system/other-tracked"
} | jq -sc '{apiVersion: "v1", kind: "List", items: .}' > "${WORK}/apps.json"
jq -cn '{items: [
  {metadata: {name: "teknoir-default", uid: "u-default",
               annotations: {"argocd.argoproj.io/tracking-id": "profile-controller:teknoir.org/Profile:/teknoir-default"}}},
  {metadata: {name: "teknoir-demo", uid: "u-demo"}}]}' > "${WORK}/profiles.json"

# --- scenario runner ----------------------------------------------------------
# run_lib <script> - source common.sh + release.sh in a child shell with a stub
# kc (state in ${WORK}/apps.json etc.), then run <script>. Output in
# ${WORK}/out, exit code appended as rc=N.
run_lib() {
  local rc=0
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${REPO}/airgap/node" JQ="$(command -v jq)" \
    TEKNOIR_DOMAIN=teknoir.airgapped NODE_IP=192.0.2.10 W="${WORK}" POST_POLL="${POST_POLL:-0.2}" \
    CTRL="${CTRL:-none}" DRY_RUN="${DRY_RUN:-0}" KC_META="${KC_META:-1234:upx}" KC_CODE="${KC_CODE:-200}" \
    SCRIPT="$1" bash -c '
      set -euo pipefail
      source "${NODE_ROOT}/lib/common.sh"
      source "${NODE_ROOT}/lib/release.sh"
      kc() {
        local a=" $* "
        echo "kc $*" >> "${W}/kc.log"
        case "${a}" in
          *" get crd "*) echo True ;;
          *" get applications.argoproj.io -o json "*)
            # the controller stand-in consumes a pending operation first
            case "${CTRL}" in
              fail) jq -c ".items |= map(if .operation then .status.operationState = {phase: \"Failed\", message: \"failed again\", syncResult: {revision: .status.sync.revision}} | del(.operation) else . end)" "${W}/apps.json" > "${W}/apps.tmp" && mv "${W}/apps.tmp" "${W}/apps.json" ;;
              succeed) jq -c ".items |= map(if .operation then .status.operationState = {phase: \"Succeeded\", message: \"ok\", syncResult: {revision: .status.sync.revision}} | del(.operation) else . end)" "${W}/apps.json" > "${W}/apps.tmp" && mv "${W}/apps.tmp" "${W}/apps.json" ;;
            esac
            cat "${W}/apps.json" ;;
          *" get profiles.teknoir.org -o json "*) cat "${W}/profiles.json" ;;
          *" patch applications.argoproj.io "*)
            local name="" body="" prev=""
            for w in "$@"; do
              case "${prev}" in applications.argoproj.io) name="${w}" ;; -p) body="${w}" ;; esac
              prev="${w}"
            done
            printf "%s %s\n" "${name}" "${body}" >> "${W}/patches.log"
            jq -c --arg n "${name}" --argjson b "${body}" \
              ".items |= map(if .metadata.name == \$n then (.operation = \$b.operation | del(.status.operationState)) else . end)" \
              "${W}/apps.json" > "${W}/apps.tmp" && mv "${W}/apps.tmp" "${W}/apps.json" ;;
          *" get secret keycloak-admin -o go-template="*) printf "%s" "${KC_META}" ;;
          *" get secret keycloak-admin "*"-o name "*) echo secret/keycloak-admin ;;
          *" get secret "*"-o name "*) ;;
          *" patch secret keycloak-admin "*) printf "%s\n" "$*" >> "${W}/secret-patches.log" ;;
          *) echo "unexpected kc call: $*" >&2; return 1 ;;
        esac
      }
      secret_value() { case "$3" in username) printf admin ;; password) printf "not-a-real-pass-4711" ;; *) return 1 ;; esac; }
      _release_kc_login() { RELEASE_KC_CODE="${KC_CODE}"; }
      eval "${SCRIPT}"
    ' > "${WORK}/out" 2>&1 || rc=$?
  echo "rc=${rc}" >> "${WORK}/out"
}
out() { cat "${WORK}/out"; }
reset_state() { cp "${WORK}/apps.json.orig" "${WORK}/apps.json"; : > "${WORK}/patches.log"; : > "${WORK}/kc.log"; : > "${WORK}/secret-patches.log"; }
cp "${WORK}/apps.json" "${WORK}/apps.json.orig"
reset_state

echo "# 1. classification"
run_lib '_release_classify "$(cat "${W}/apps.json")" "$(cat "${W}/profiles.json")" | jq -r ".items[] | \"\(.metadata.name) \(.teknoirPost.class) \(.teknoirPost.strict)\"" | sort'
check "classes: root/tracked platform, GitOps teamspace strict, others reported only" eq "$(cat <<'EOF'
app-of-apps platform true
auth platform true
cert-manager platform true
monitoring platform true
other-tracked other false
stray other false
teknoir-default-emqx teamspace true
teknoir-default-grafana teamspace true
teknoir-default-jwks teamspace true
teknoir-demo-jwks teamspace false
teknoir-stale-mongodb teamspace false
rc=0
EOF
)" "$(out)"

echo "# 2. readiness"
run_lib '_release_post_not_ready "$(_release_classify "$(cat "${W}/apps.json")" "$(cat "${W}/profiles.json")")"'
check "strict not-ready list: monitoring, teknoir-default-grafana, teknoir-default-jwks only" \
  eq "monitoring teknoir-default-grafana teknoir-default-jwks" "$(grep -v '^rc=' "${WORK}/out" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
check "a stale Failed operation of the current revision gives the reason" \
  grep -qF 'monitoring	last sync to 0.0.4 Failed: one or more synchronization tasks completed unsuccessfully (retried 5 times).' "${WORK}/out"
check "a Failed operation of an older revision gives none (auth is ready)" bash -c "! grep -q '^auth' '${WORK}/out'"
check "teknoir-demo-jwks (Profile not in GitOps) does not block" bash -c "! grep -q '^teknoir-demo-jwks' '${WORK}/out'"
check "teknoir-default-jwks Unknown (Profile in GitOps) is not ready" grep -qE '^teknoir-default-jwks	Unknown/Healthy' "${WORK}/out"
run_lib '_release_post_reported "$(_release_classify "$(cat "${W}/apps.json")" "$(cat "${W}/profiles.json")")"'
check "reported only: teknoir-demo-jwks (not in GitOps), the stale-uid teamspace and stray" \
  eq "stray teknoir-demo-jwks teknoir-stale-mongodb" "$(grep -v '^rc=' "${WORK}/out" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
check "the report names the teamspace and why" grep -qF 'teknoir-demo-jwks	teamspace teknoir-demo, not declared in GitOps	Unknown/Healthy' "${WORK}/out"
jq -c '.items |= map(select(.metadata.name != "app-of-apps"))' "${WORK}/apps.json" > "${WORK}/noroot.json"
run_lib '_release_post_not_ready "$(_release_classify "$(cat "${W}/noroot.json")" "$(cat "${W}/profiles.json")")"'
check "a missing root is not ready" grep -qF 'app-of-apps	not created yet' "${WORK}/out"
jq -c '(.items[] | select(.metadata.name == "monitoring")) |= (.operation = {sync: {revision: "0.0.4"}})' "${WORK}/apps.json" > "${WORK}/pending.json"
run_lib 'j="$(_release_classify "$(cat "${W}/pending.json")" "$(cat "${W}/profiles.json")")"; _release_post_not_ready "${j}" | grep "^monitoring"; echo "candidates=[$(_release_resync_candidates "${j}" | tr "\n" " ")]"'
check "a pending operation is not ready and no longer reports the stale failure" \
  grep -qxF 'monitoring	sync operation requested, not started yet' "${WORK}/out"
check "a pending operation is not a re-sync candidate" grep -qxF 'candidates=[]' "${WORK}/out"

echo "# 3. re-sync candidates and patch body"
run_lib '_release_resync_candidates "$(_release_classify "$(cat "${W}/apps.json")" "$(cat "${W}/profiles.json")")"'
check "only the platform Application with a stale failed op is a candidate (not the teamspace one)" eq "monitoring
rc=0" "$(out)"
run_lib '_release_resync_patch "$(jq -c ".items[] | select(.metadata.name == \"monitoring\")" "${W}/apps.json")"'
body="$(head -1 "${WORK}/out")"
check "the patch body nulls status.operationState" eq "true" "$(jq -c '.status | has("operationState") and .operationState == null' <<<"${body}")"
check "the patch body sets the operation from the spec (revision, prune, syncOptions, retry, initiatedBy)" \
  eq '{"initiatedBy":{"username":"teknoir-node"},"sync":{"prune":true,"syncOptions":["ServerSideApply=true","RespectIgnoreDifferences=true"],"revision":"0.0.4"},"retry":{"limit":10,"backoff":{"duration":"30s","factor":2,"maxDuration":"5m"}}}' \
  "$(jq -c '.operation' <<<"${body}")"
check "the patch body is guarded by the resourceVersion read" eq '"4711"' "$(jq -c '.metadata.resourceVersion' <<<"${body}")"
check "the patch body touches nothing else" eq '["metadata","operation","status"]' "$(jq -c 'keys' <<<"${body}")"
run_lib '_release_resync_patch "$(jq -c ".items[] | select(.metadata.name == \"monitoring\") | del(.spec.syncPolicy.retry, .spec.syncPolicy.automated.prune, .spec.syncPolicy.syncOptions)" "${W}/apps.json")"'
check "without retry/prune/syncOptions in the spec: ArgoCD's defaults (limit 5, no prune)" \
  eq '{"initiatedBy":{"username":"teknoir-node"},"sync":{"prune":false,"revision":"0.0.4"},"retry":{"limit":5}}' "$(head -1 "${WORK}/out" | jq -c .operation)"

echo "# 4. post_wait_applications"
# only the strict blockers that a re-sync can fix: drop the teamspace failures for these runs
jq -c '.items |= map(select(.metadata.name | IN("teknoir-default-jwks", "teknoir-default-grafana") | not))' "${WORK}/apps.json.orig" > "${WORK}/apps.json.orig2"
cp "${WORK}/apps.json.orig2" "${WORK}/apps.json"; : > "${WORK}/patches.log"
CTRL=fail run_lib 'WAIT_TIMEOUT=3; REC_SOURCE=configmap; post_wait_applications'
check "a re-sync that fails again: post fails after the timeout" grep -q '^rc=1$' "${WORK}/out"
check "... with the reason" grep -qE 'ERROR: post: after 3s these Applications are not Synced/Healthy at this release: monitoring \(last sync to 0.0.4 Failed: failed again\)' "${WORK}/out"
check "exactly one patch in the run" eq 1 "$(grep -c . "${WORK}/patches.log")"
check "one re-sync recorded as a change" eq 1 "$(grep -c 'changed: re-synced Application monitoring once (last sync to 0.0.4 Failed)' "${WORK}/out")"
check "the patch set .operation and nulled status.operationState in the same request" \
  eq 'monitoring true true' "$(awk '{print $1}' "${WORK}/patches.log") $(cut -d' ' -f2- "${WORK}/patches.log" | jq -c '.operation.sync.revision == "0.0.4"') $(cut -d' ' -f2- "${WORK}/patches.log" | jq -c '.status.operationState == null')"
check "teamspaces not in GitOps are reported in a WARN" grep -qE 'WARN: not ready, not waited for .*teknoir-demo-jwks \[teamspace teknoir-demo, not declared in GitOps\]' "${WORK}/out"
CTRL=fail run_lib 'WAIT_TIMEOUT=2; REC_SOURCE=configmap; post_wait_applications'
check "the next run patches once more (once per run)" eq 2 "$(grep -c . "${WORK}/patches.log")"
cp "${WORK}/apps.json.orig2" "${WORK}/apps.json"; : > "${WORK}/patches.log"
CTRL=succeed run_lib 'WAIT_TIMEOUT=10; REC_SOURCE=configmap; post_wait_applications'
check "a re-sync that succeeds: post passes" grep -q '^rc=0$' "${WORK}/out"
check "... after one patch" eq 1 "$(grep -c . "${WORK}/patches.log")"
check "... and says what it waited for" grep -q 'every platform Application (and every teamspace declared in GitOps) is Synced/Healthy' "${WORK}/out"
check "the table marks reported-only Applications" grep -qE '^teknoir-demo-jwks +Unknown +Healthy +0\.0\.99 +teamspace/teknoir-demo\*$' "${WORK}/out"
cp "${WORK}/apps.json.orig2" "${WORK}/apps.json"; : > "${WORK}/patches.log"
DRY_RUN=1 CTRL=fail run_lib 'WAIT_TIMEOUT=10; REC_SOURCE=configmap; post_wait_applications'
check "dry-run: exits 0, patches nothing" eq "rc=0 0" "$(tail -1 "${WORK}/out") $(grep -c . "${WORK}/patches.log" || true)"
check "dry-run: reports the re-sync it would make" grep -q 'would change: re-sync Application monitoring once (last sync to 0.0.4 Failed)' "${WORK}/out"
cp "${WORK}/apps.json.orig" "${WORK}/apps.json"; : > "${WORK}/patches.log"
CTRL=succeed run_lib 'WAIT_TIMEOUT=2; REC_SOURCE=configmap; post_wait_applications'
check "a teamspace declared in GitOps that stays Unknown fails post, named" \
  grep -qE 'ERROR: post: after 2s .*teknoir-default-jwks \(Unknown/Healthy' "${WORK}/out"
check "a teamspace Application with a failed op is never re-synced by post" bash -c "! grep -q '^teknoir-default-grafana' '${WORK}/patches.log'"

echo "# 5. post_keycloak_admin_cleanup"
reset_state
KC_CODE=200 run_lib 'post_keycloak_admin_cleanup; summary'
check "login 200: previous-password removed with a resourceVersion test" \
  grep -qF '"op":"test","path":"/metadata/resourceVersion","value":"1234"},{"op":"remove","path":"/data/previous-password"}' "${WORK}/secret-patches.log"
check "login 200: recorded as a change" grep -q 'changed: removed key previous-password from Secret teknoir-auth/keycloak-admin' "${WORK}/out"
check "the password is never printed" bash -c "! grep -qF 'not-a-real-pass-4711' '${WORK}/out' '${WORK}/kc.log' '${WORK}/secret-patches.log'"
reset_state
KC_CODE=401 run_lib 'post_keycloak_admin_cleanup; summary'
check "login 401: kept, with a WARN, nothing patched" \
  eq "1 0" "$(grep -c 'WARN: keycloak-admin: the master admin does not log in with key password .*(HTTP 401): previous-password is kept' "${WORK}/out") $(grep -c . "${WORK}/secret-patches.log" || true)"
reset_state
KC_CODE=000 run_lib 'post_keycloak_admin_cleanup'
check "Keycloak unreachable: kept, with a WARN" grep -q 'WARN: keycloak-admin: cannot check the master admin login at Keycloak (HTTP 000): previous-password is kept' "${WORK}/out"
reset_state
KC_META='1234:up' run_lib 'post_keycloak_admin_cleanup; summary'
check "no previous-password key: nothing to do" eq "0 1" "$(grep -c . "${WORK}/secret-patches.log" || true) $(grep -c 'summary: 0 changes' "${WORK}/out")"
reset_state
KC_META='1234:ux' run_lib 'post_keycloak_admin_cleanup'
check "previous-password without password: kept, with a WARN" grep -q 'has previous-password but no password yet' "${WORK}/out"
reset_state
DRY_RUN=1 run_lib 'post_keycloak_admin_cleanup'
check "dry-run: no login, nothing patched" eq "0" "$(grep -c . "${WORK}/secret-patches.log" || true)"

echo "# 6. release_status"
reset_state
run_lib 'release_load_record() { REC_SOURCE=none; }; release_status'
check "status: one apps line per class, with not-ready counts" eq "$(cat <<'EOF'
release:   nothing deployed yet
apps:      other: 2 Application(s), 1 not ready (reported only, never block up)
apps:      platform: 4 Application(s), 1 not ready (up waits for them)
apps:      teamspace teknoir-default: 1 Application(s), 1 not ready (reported only, never block up)
apps:      teamspace teknoir-default: 3 Application(s), 2 not ready (up waits for them)
apps:      teamspace teknoir-demo: 1 Application(s), 1 not ready (reported only, never block up)
rc=0
EOF
)" "$(out)"

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
