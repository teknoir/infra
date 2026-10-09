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
#  3b. ... and only while that failure is about the spec the Application
#      keeps: spec 0.0.5 with a stale 0.0.4 Failed status gives no candidate
#      and no patch (post waits for the new revision); a root not reconciled
#      since this run's pin, OutOfSync, syncing or compared with its old pin
#      gives none; the root's own failure at its pin makes it the candidate;
#  3c. a Profile declared in GitOps is not ready until profile-controller ran
#      for it and created an Application per enabled chart plugin (none, some,
#      a run in progress); failed plugins (EMQX) and Profiles not in GitOps are
#      reported only; post fails naming profile/<name>; no plugin
#      configuration value reaches the output;
#   4. post_wait_applications: exactly one patch per run even when the
#      re-sync fails again (then post fails, naming the reason); a re-sync
#      that succeeds lets post pass; teamspaces not in GitOps are reported in
#      one WARN; dry-run patches nothing; a failed teamspace Application is
#      never patched and its reason says how to retry it;
#  4b. the wait: an update that creates a teamspace declared in GitOps (its
#      Profile not reconciled, Applications missing, or a not-ready one that
#      never synced) waits POST_WAIT_FIRST_INSTALL from the start; an
#      explicit --wait-timeout, a first install, a teamspace that synced
#      before, a run in progress alone and a Profile not in GitOps do not
#      extend it; the timeout error says re-running up is safe;
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
# profile-controller's status: run times, and per plugin enabled, chart name
# (the Application is <profile>-<name>) and apply status (live teknoir-demo
# shape of 2026-10-09; EMQX fails until its pod answers)
plugin() { jq -cn --arg k "$1" --argjson e "$2" --arg n "$3" --arg s "$4" '
  {($k): {info: {description: "x"}, applyStatus: {status: $s, applyTime: "2026-10-09T09:22:01Z"},
          appliedConfig: {settings: {enabled: $e, specific: {}},
                          pluginConfig: ({enabled: ($e | tostring), namespace: "ns", values: {password: "not-a-real-pass-4711"}}
                                         + (if $n != "" then {name: $n, version: "0.0.99"} else {} end))}}}'; }
profile() {
  # profile <name> <uid> <tracked 0|1> <start|-> <end|-> <plugin-json>...
  local n="$1" u="$2" t="$3" st="$4" en="$5"; shift 5
  jq -cn --arg n "${n}" --arg u "${u}" --arg t "${t}" --arg st "${st}" --arg en "${en}" --argjson pl "$(printf '%s\n' "$@" | jq -sc 'add // {}')" '
    {metadata: ({name: $n, uid: $u} + (if $t == "1" then {annotations: {"argocd.argoproj.io/tracking-id": "profile-controller:teknoir.org/Profile:/\($n)"}} else {} end)),
     spec: {owner: {kind: "User", name: "owner@example.test"}}}
    + (if $st == "-" then {} else {status: {appliedconfig: ({plugins: $pl, lastRunStart: $st} + (if $en == "-" then {} else {lastRunEnd: $en} end))}} end)'
}
DEFAULT_PLUGINS=("$(plugin ArgoCD true "" Success)" "$(plugin JWKS true jwks Success)" "$(plugin EMQX true emqx Fail)"
                 "$(plugin Grafana true grafana Success)" "$(plugin Postgres false postgres Success)")
profiles_json() { printf '%s\n' "$@" | jq -sc '{items: .}'; }
profiles_json \
  "$(profile teknoir-default u-default 1 2026-10-09T09:22:01Z 2026-10-09T09:22:01Z "${DEFAULT_PLUGINS[@]}")" \
  "$(profile teknoir-demo u-demo 0 2026-10-09T09:22:01Z 2026-10-09T09:22:02Z "$(plugin JWKS true jwks Success)")" > "${WORK}/profiles.json"

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
# the same with the teknoir-default Applications ready: only the strict
# blockers a re-sync can fix are left (monitoring)
jq -c '.items |= map(if .metadata.name | IN("teknoir-default-jwks", "teknoir-default-grafana")
                     then .status.sync.status = "Synced" | del(.status.conditions)
                          | .status.operationState = {phase: "Succeeded", syncResult: {revision: .status.sync.revision}}
                     else . end)' "${WORK}/apps.json.orig" > "${WORK}/apps.json.orig2"
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
check "a failed teamspace Application: the reason says post never re-syncs it and how to retry" \
  grep -qxF 'teknoir-default-grafana	last sync to 0.0.99 Failed: one or more synchronization tasks completed unsuccessfully (retried 5 times).; post re-syncs platform Applications only: Sync this one in the ArgoCD UI (or with the patch in OPERATE section 12), then run up again' "${WORK}/out"
check "a failed platform Application: no such hint (post re-syncs it)" bash -c "! grep '^monitoring' '${WORK}/out' | grep -q 'platform Applications only'"
run_lib '_release_post_reported "$(_release_classify "$(cat "${W}/apps.json")" "$(cat "${W}/profiles.json")")"'
check "reported only: teknoir-demo-jwks (not in GitOps), the stale-uid teamspace, stray, teknoir-default's failed plugin" \
  eq "profile/teknoir-default stray teknoir-demo-jwks teknoir-stale-mongodb" "$(grep -v '^rc=' "${WORK}/out" | cut -f1 | sort | tr '\n' ' ' | sed 's/ $//')"
check "the report names the teamspace and why" grep -qF 'teknoir-demo-jwks	teamspace teknoir-demo, not declared in GitOps	Unknown/Healthy' "${WORK}/out"
check "a failed plugin of a teamspace declared in GitOps is reported, not waited for" \
  grep -qxF 'profile/teknoir-default	teamspace teknoir-default, plugin status (profile-controller retries)	plugin(s) not applied: EMQX Fail' "${WORK}/out"
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

echo "# 3b. re-sync only a failure of the spec the Application keeps (after a pin)"
cands() {
  # cands <apps-file> [pin-at] - the re-sync candidates, space separated, in ${WORK}/out
  run_lib "RELEASE_PIN_AT=${2:-0}"'; echo "candidates=[$(_release_resync_candidates "$(_release_classify "$(cat "${W}/'"$1"'")" "$(cat "${W}/profiles.json")")" | tr "\n" " " | sed "s/ $//")]"'
}
# the root pinned monitoring 0.0.5; ArgoCD has not compared it yet (status and failure still 0.0.4)
jq -c '(.items[] | select(.metadata.name == "monitoring")) |= (.spec.source.targetRevision = "0.0.5")' "${WORK}/apps.json.orig" > "${WORK}/ahead.json"
cands ahead.json
check "spec 0.0.5 with a stale 0.0.4 Failed status: no candidate" grep -qxF 'candidates=[]' "${WORK}/out"
run_lib '_release_post_not_ready "$(_release_classify "$(cat "${W}/ahead.json")" "$(cat "${W}/profiles.json")")" | grep "^monitoring"'
check "... and it is not ready because its status is stale" \
  grep -qF 'monitoring	last sync to 0.0.4 Failed: one or more synchronization tasks completed unsuccessfully (retried 5 times).; status not computed for the current spec yet (compared: 0.0.4); synced revision 0.0.4, pinned 0.0.5' "${WORK}/out"
jq -c '(.items[] | select(.metadata.name == "monitoring")) |= (.spec.source.targetRevision = "0.0.5")' "${WORK}/apps.json.orig2" > "${WORK}/apps.json"
: > "${WORK}/patches.log"
CTRL=fail run_lib 'WAIT_TIMEOUT=2; REC_SOURCE=configmap; post_wait_applications'
check "post with the pinned-ahead failure: no patch" eq 0 "$(grep -c . "${WORK}/patches.log" || true)"
check "... and post waits for the new revision instead (fails here, no controller compares it)" \
  grep -qE 'ERROR: post: after 2s .*monitoring \(last sync to 0\.0\.4 Failed: .*status not computed for the current spec yet' "${WORK}/out"
# ArgoCD compared 0.0.5 (OutOfSync, last operation still the 0.0.4 failure): auto-sync's job, not post's
jq -c '(.items[] | select(.metadata.name == "monitoring")) |= (.status.sync = {status: "OutOfSync", revision: "0.0.5", comparedTo: {source: .spec.source}})' "${WORK}/ahead.json" > "${WORK}/compared.json"
cands compared.json
check "compared at 0.0.5 with the 0.0.4 failure: no candidate (a superseded failure)" grep -qxF 'candidates=[]' "${WORK}/out"
# the root: pinned by this run but not reconciled since; children may be about to change
cands apps.json.orig "$(date +%s)"
check "a root not reconciled since this run's pin: no candidate" grep -qxF 'candidates=[]' "${WORK}/out"
cands apps.json.orig 1000
check "a root reconciled after the pin: monitoring is a candidate" grep -qxF 'candidates=[monitoring]' "${WORK}/out"
jq -c '(.items[] | select(.metadata.name == "app-of-apps")) |= (.status.sync.status = "OutOfSync")' "${WORK}/apps.json.orig" > "${WORK}/rootoos.json"
cands rootoos.json
check "a root OutOfSync (its sync has not updated the children yet): no candidate" grep -qxF 'candidates=[]' "${WORK}/out"
jq -c '(.items[] | select(.metadata.name == "app-of-apps")) |= (.status.operationState.phase = "Running")' "${WORK}/apps.json.orig" > "${WORK}/rootrun.json"
cands rootrun.json
check "a root sync running: no candidate" grep -qxF 'candidates=[]' "${WORK}/out"
jq -c '(.items[] | select(.metadata.name == "app-of-apps")) |= (.status.sync.comparedTo.source.targetRevision = "0.0.4")' "${WORK}/apps.json.orig" > "${WORK}/rootstale.json"
cands rootstale.json
check "a root compared with its old pin: no candidate" grep -qxF 'candidates=[]' "${WORK}/out"
jq -c '(.items[] | select(.metadata.name == "app-of-apps")) |= (.status.sync.status = "OutOfSync"
        | .status.operationState = {phase: "Failed", message: "x", syncResult: {revision: "0.0.5"}})' "${WORK}/apps.json.orig" > "${WORK}/rootfailed.json"
cands rootfailed.json
check "the root's own failure at its current pin: the root is the candidate, its children wait" grep -qxF 'candidates=[app-of-apps]' "${WORK}/out"

echo "# 3c. a Profile declared in GitOps: its Applications must exist (TS-C6)"
prof_not_ready() {
  # prof_not_ready <apps-file> <profile-json>... - post's strict list for these Profiles, in ${WORK}/out
  profiles_json "${@:2}" > "${WORK}/p.json"
  run_lib '_release_post_not_ready "$(_release_classify "$(cat "${W}/'"$1"'")" "$(cat "${W}/p.json")")" | grep "^profile/" || true; _release_post_reported "$(_release_classify "$(cat "${W}/'"$1"'")" "$(cat "${W}/p.json")")" | grep "^profile/" | sed "s/^/reported: /" || true'
}
jq -c '.items |= map(select(.metadata.name | test("^teknoir-default-") | not))' "${WORK}/apps.json.orig" > "${WORK}/nodefault.json"
T0=2026-10-09T09:22:01Z T1=2026-10-09T09:22:05Z
prof_not_ready apps.json.orig "$(profile teknoir-default u-default 1 - -)"
check "not reconciled by profile-controller yet (no status): not ready" \
  grep -qxF 'profile/teknoir-default	not reconciled by profile-controller yet' "${WORK}/out"
prof_not_ready nodefault.json "$(profile teknoir-default u-default 1 "${T0}" "${T0}" "${DEFAULT_PLUGINS[@]}")"
check "reconciled, no Application: not ready, naming the expected ones" \
  grep -qxF 'profile/teknoir-default	no Applications yet (expected 3: teknoir-default-emqx, teknoir-default-grafana, teknoir-default-jwks)' "${WORK}/out"
jq -c '.items |= map(select(.metadata.name != "teknoir-default-grafana"))' "${WORK}/apps.json.orig" > "${WORK}/somedefault.json"
prof_not_ready somedefault.json "$(profile teknoir-default u-default 1 "${T0}" "${T0}" "${DEFAULT_PLUGINS[@]}")"
check "only some Applications: not ready, naming the missing one" \
  grep -qxF 'profile/teknoir-default	Applications not created yet: teknoir-default-grafana' "${WORK}/out"
prof_not_ready apps.json.orig "$(profile teknoir-default u-default 1 "${T1}" "${T0}" "${DEFAULT_PLUGINS[@]}")"
check "a profile-controller run in progress (lastRunEnd before lastRunStart): not ready" \
  grep -qxF "profile/teknoir-default	profile-controller run in progress (started ${T1})" "${WORK}/out"
prof_not_ready apps.json.orig "$(profile teknoir-default u-default 1 "${T1}" - "${DEFAULT_PLUGINS[@]}")"
check "a run that never ended (no lastRunEnd): not ready" grep -qF 'profile/teknoir-default	profile-controller run in progress' "${WORK}/out"
prof_not_ready nodefault.json "$(profile teknoir-default u-default 1 "${T0}" "${T0}")"
check "a run that applied no plugin and created nothing: not ready" grep -qxF 'profile/teknoir-default	no Applications yet' "${WORK}/out"
prof_not_ready nodefault.json "$(profile teknoir-default u-default 1 "${T0}" "${T0}" "$(plugin ArgoCD true "" Success)" "$(plugin Postgres false postgres Success)")"
check "every chart plugin disabled: no Application expected, ready" eq "rc=0" "$(out)"
prof_not_ready apps.json.orig "$(profile teknoir-default u-default 1 "${T0}" "${T0}" "${DEFAULT_PLUGINS[@]}")"
check "every Application there, EMQX Fail: ready, the failure only reported" eq "reported: profile/teknoir-default	teamspace teknoir-default, plugin status (profile-controller retries)	plugin(s) not applied: EMQX Fail
rc=0" "$(out)"
prof_not_ready nodefault.json "$(profile teknoir-default u-default 0 "${T0}" "${T0}" "${DEFAULT_PLUGINS[@]}")"
check "a Profile not in GitOps without Applications: reported only" \
  grep -qxF 'reported: profile/teknoir-default	teamspace teknoir-default, not declared in GitOps	no Applications yet (expected 3: teknoir-default-emqx, teknoir-default-grafana, teknoir-default-jwks)' "${WORK}/out"
check "... never in post's strict list" bash -c "! grep -q '^profile/' '${WORK}/out'"
prof_not_ready apps.json.orig "$(profile teknoir-default u-other 1 "${T0}" "${T0}" "${DEFAULT_PLUGINS[@]}")"
check "Applications owned by another Profile uid do not count" grep -qF 'profile/teknoir-default	no Applications yet' "${WORK}/out"
run_lib '_release_classify "$(cat "${W}/apps.json.orig")" "$(cat "${W}/profiles.json")"; release_status'
check "no plugin configuration value reaches the classified JSON or status" bash -c "! grep -qF 'not-a-real-pass-4711' '${WORK}/out'"
# post itself: the controller stand-in finishes monitoring; the Profile has no Application
jq -c '.items |= map(select(.metadata.name | test("^teknoir-default-") | not))' "${WORK}/apps.json.orig2" > "${WORK}/apps.json"
: > "${WORK}/patches.log"
CTRL=succeed run_lib 'WAIT_TIMEOUT=2; REC_SOURCE=configmap; post_wait_applications'
check "post: a Profile declared in GitOps with no Application fails post, named" \
  grep -qE 'ERROR: post: after 2s these Applications are not Synced/Healthy at this release: profile/teknoir-default \(no Applications yet \(expected 3: ' "${WORK}/out"
check "... and the table says why" grep -qF '  profile/teknoir-default: no Applications yet (expected 3:' "${WORK}/out"

echo "# 4. post_wait_applications"
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
check "... and the error says how to retry it" \
  grep -qF 'teknoir-default-grafana (last sync to 0.0.99 Failed: one or more synchronization tasks completed unsuccessfully (retried 5 times).; post re-syncs platform Applications only: Sync this one in the ArgoCD UI' "${WORK}/out"
check "the timeout error says re-running up is safe" grep -qF '(running up again is safe: every phase skips what is done and post waits again)' "${WORK}/out"

echo "# 4b. the wait: an update that creates a teamspace declared in GitOps waits as long as a first install"
cp "${WORK}/profiles.json" "${WORK}/profiles.json.orig"
# history: ArgoCD's record of successful syncs (an Application that never synced has none)
synced_before() { jq -c '.items |= map(if .metadata.name | test("^teknoir-default-") then .status.history = [{id: 0, revision: .status.sync.revision}] else . end)' "$1"; }
wait_case() {
  # wait_case <apps-file> <profiles-file> <script-prefix> - post_wait_applications
  # on an update with POST_WAIT_DEFAULT=1 and POST_WAIT_FIRST_INSTALL=3; output in ${WORK}/out
  cp "${WORK}/$1" "${WORK}/apps.json"; cp "${WORK}/$2" "${WORK}/profiles.json"; : > "${WORK}/patches.log"
  CTRL=succeed run_lib 'POST_WAIT_DEFAULT=1; POST_WAIT_FIRST_INSTALL=3; REC_SOURCE=configmap; REC_MODE=update; '"$3"' post_wait_applications'
  cp "${WORK}/profiles.json.orig" "${WORK}/profiles.json"
}
waited() { grep -oE 'ERROR: post: after [0-9]+s' "${WORK}/out" | grep -oE '[0-9]+s'; }
jq -c '.items |= map(select(.metadata.name | test("^teknoir-default-") | not))' "${WORK}/apps.json.orig2" > "${WORK}/w-nodefault.json"
profiles_json "$(profile teknoir-default u-default 1 - -)" > "${WORK}/w-unreconciled.json"
profiles_json "$(profile teknoir-default u-default 1 "${T0}" "${T0}" "${DEFAULT_PLUGINS[@]}")" > "${WORK}/w-reconciled.json"
profiles_json "$(profile teknoir-default u-default 1 "${T1}" "${T0}" "${DEFAULT_PLUGINS[@]}")" > "${WORK}/w-running.json"
profiles_json "$(profile teknoir-default u-default 0 - -)" > "${WORK}/w-untracked.json"
wait_case w-nodefault.json w-unreconciled.json ''
check "Profile not reconciled yet: the wait grows to the first-install one (3s, not 1s)" eq 3s "$(waited)"
check "... and says so once, naming the teamspace" \
  eq 1 "$(grep -c 'this run creates teamspace(s) declared in GitOps (teknoir-default): post waits up to 3s in all, as on a first install' "${WORK}/out")"
wait_case w-nodefault.json w-reconciled.json ''
check "Profile reconciled, no Application yet: first-install wait" eq 3s "$(waited)"
# every teknoir-default Application created, jwks Unknown and never synced
jq -c '.items |= map(if .metadata.name == "teknoir-default-jwks" then .status.sync.status = "Unknown" else . end)' "${WORK}/apps.json.orig2" > "${WORK}/w-new.json"
wait_case w-new.json w-reconciled.json ''
check "all Applications created, one not ready that never synced: first-install wait" eq 3s "$(waited)"
synced_before "${WORK}/w-new.json" > "${WORK}/w-old.json"
wait_case w-old.json w-reconciled.json ''
check "the same Application with a successful sync before: the update wait (1s)" eq 1s "$(waited)"
check "... and no extension logged" eq 0 "$(grep -c 'this run creates teamspace' "${WORK}/out" || true)"
wait_case w-old.json w-running.json ''
check "a profile-controller run in progress alone (Applications there, synced before): the update wait" eq 1s "$(waited)"
wait_case w-nodefault.json w-unreconciled.json 'WAIT_TIMEOUT=1;'
check "an explicit --wait-timeout is never extended" eq "1s 0" "$(waited) $(grep -c 'this run creates teamspace' "${WORK}/out" || true)"
wait_case w-nodefault.json w-unreconciled.json 'release_load_record() { :; }; REC_SOURCE=none; REC_MODE=;'
check "a first install already waits the first-install time (no extension logged)" eq "3s 0" "$(waited) $(grep -c 'this run creates teamspace' "${WORK}/out" || true)"
# a Profile not in GitOps without Applications, plus a stray platform blocker: never extends
jq -c '(.items[] | select(.metadata.name == "auth")) |= (.status.health.status = "Degraded")' "${WORK}/w-nodefault.json" > "${WORK}/w-degraded.json"
wait_case w-degraded.json w-untracked.json ''
check "a Profile not declared in GitOps being created: the update wait" eq 1s "$(waited)"
DRY_RUN=1 wait_case w-nodefault.json w-unreconciled.json ''
check "dry-run: reports the first-install wait it would make" grep -qF '[dry-run] would wait up to 3s for: ' "${WORK}/out"
check "every 4b case left profiles.json as it was" cmp -s "${WORK}/profiles.json" "${WORK}/profiles.json.orig"

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
profile:   teknoir-default (declared in GitOps, up waits for it): 3 Application(s) created; plugin(s) not applied: EMQX Fail (reported only)
profile:   teknoir-demo (not in GitOps, reported only): 1 Application(s) created
rc=0
EOF
)" "$(out)"

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
