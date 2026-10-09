# shellcheck shell=bash
# release.sh: the release and post phases of teknoir-node converge
# (DESIGN I-10).
#
# release: server-side apply the root AppProject `default` + Application
#   app-of-apps from templates/app-of-apps.yaml.tmpl at the bundle's
#   APP_OF_APPS_VERSION (field manager teknoir-bootstrap), and keep the
#   release record ConfigMap teknoir-system/teknoir-airgap-release.
#   Guard: versions in the broken list are always refused; a version older
#   than the deployed one only with --rollback (which is recorded, so the
#   next plain converge with that bundle is not a downgrade any more).
# post: wait until every Application of the platform is Synced/Healthy at its
#   current spec (report per app on timeout), check every running image is
#   re-pullable (Harbor) or present (containerd), remove the Keycloak admin's
#   previous-password once the current one works, and prune old bundle
#   payloads (keep current + previous).
#   Which Applications post waits for (r5, R2): the platform ones - the root
#   ROOT_APP and every Application whose argocd.argoproj.io/tracking-id names
#   the root ("<ROOT_APP>:...", ArgoCD annotation tracking) - and the
#   teamspace ones (an ownerReference of kind Profile) whose Profile is
#   declared in GitOps (the Profile itself carries an ArgoCD tracking-id, e.g.
#   teknoir-default). Other teamspaces (created in Backstage, e.g.
#   teknoir-demo) and any other Application are reported, never waited for.
#   A platform Application whose last sync of its current revision Failed (or
#   Errored) and that has no operation pending is not ready, and post re-syncs
#   it once per run the way ArgoCD's own API does: one merge patch that sets
#   .operation and clears .status.operationState (never .operation alone: the
#   controller would resume the stale failed state).
#   Synced/Healthy alone is not enough: right after the pin changes, ArgoCD
#   still shows the old revision's status until it has compared again (and
#   the children go through the same window after the root syncs). An
#   Application counts as ready only when its status was computed for its
#   current spec (status.sync.comparedTo equals spec.source[s]; for a chart
#   pinned to an exact version, status.sync.revision is that version), no
#   sync operation is running, and - for the root, when this run applied the
#   pin - status.reconciledAt is later than the pin. The release phase asks
#   ArgoCD to refresh the root right after the pin, so that wait is seconds.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # jq programs use $variables in single quotes
# lib/migrate.sh sources this file lazily (migrate --finalize) after
# common.sh is loaded, possibly from a payload without lib/ (test drivers).
if [[ -z "${TEKNOIR_COMMON_SOURCED:-}" ]]; then
  # shellcheck source=common.sh
  source "${NODE_ROOT}/lib/common.sh"
fi

RELEASE_NS="teknoir-system"
RELEASE_CM="teknoir-airgap-release"
ROOT_APP="app-of-apps"
APP_CRD="applications.argoproj.io"
# app-of-apps versions that must never be deployed: their Harbor contents
# were overwritten on 2026-09-14 (harbor 0.0.8 = Harbor 2.15.2 with a one-way
# DB migration; auth 0.0.6/0.0.7). MANIFEST.yaml may add more
# (brokenAppOfApps).
BROKEN_APP_OF_APPS_DEFAULT="0.0.1 0.0.2"
RELEASE_HISTORY_MAX=10
POST_WAIT_DEFAULT=1200
POST_WAIT_FIRST_INSTALL=2700
POST_POLL="${POST_POLL:-15}"
BUNDLES_KEEP_PREVIOUS=1
# Epoch second just before this run applied the root pin (0: not this run).
RELEASE_PIN_AT=0
PROFILE_CRD="profiles.teknoir.org"
# Platform Applications re-synced by this run (post re-syncs each at most once).
declare -gA RELEASE_RESYNCED=()
# Keycloak master admin (gitops charts/auth): key previous-password is only
# needed until the auth sync has rotated the admin to key password.
RELEASE_KC_NS="teknoir-auth"
RELEASE_KC_SECRET="keycloak-admin"
RELEASE_KC_CODE=""
ARGOCD_INITIAL_ADMIN_SECRET="argocd-initial-admin-secret"

# jq: why($root; $pinAt) is "" for a ready Application, else the reasons.
# A Failed/Error last operation counts only when it synced the revision the
# Application is at now (an older failure was superseded) and no operation is
# pending (.operation set: requested or running).
RELEASE_JQ_READY='
def exactver: test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?$");
def epoch: (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0);
def nilempty: if . == [] or . == {} then null else . end;
def revstr: if type == "array" then join(",") else tostring end;
def oprev: (.status.operationState.syncResult.revision // .status.operationState.syncResult.revisions
            // .status.operationState.operation.sync.revision // .status.operationState.operation.sync.revisions // null);
def currev: (.status.sync.revision // .status.sync.revisions // null);
def failedop: ((.status.operationState.phase // "") | IN("Failed", "Error"))
              and .operation == null and oprev != null and oprev == currev;
def why($root; $pinAt):
  (.spec.source // null) as $src
  | [ (if (.status.sync.status // "") != "Synced" or (.status.health.status // "") != "Healthy"
       then "\(.status.sync.status // "Unknown")/\(.status.health.status // "Unknown")" else empty end),
      (if ((.status.operationState.phase // "") | IN("Running", "Terminating"))
       then "sync operation \(.status.operationState.phase)"
       elif .operation != null then "sync operation requested, not started yet"
       else empty end),
      (if failedop
       then "last sync to \(oprev | revstr) \(.status.operationState.phase): \((.status.operationState.message // "no message") | .[0:200])"
       else empty end),
      (if ($src | nilempty) != (.status.sync.comparedTo.source // null | nilempty)
          or (.spec.sources // null | nilempty) != (.status.sync.comparedTo.sources // null | nilempty)
       then "status not computed for the current spec yet (compared: \(.status.sync.comparedTo.source.targetRevision // "nothing"))"
       else empty end),
      (if ($src.chart // "") != "" and (($src.targetRevision // "") | exactver)
          and (.status.sync.revision // "") != $src.targetRevision
       then "synced revision \(.status.sync.revision // "none"), pinned \($src.targetRevision)" else empty end),
      (if .metadata.name == $root and $pinAt > 0 and ((.status.reconciledAt // "") | epoch) <= $pinAt
       then "not reconciled since this run pinned it" else empty end)
    ] | join("; ");
'

# jq: classify($root; $profiles) - which Applications post waits for (R2).
#   platform   the root, or tracked by it (tracking-id "<root>:..." or, with
#              apps in any namespace, "<ns>_<root>:..."): strict
#   teamspace  an ownerReference of kind Profile: strict only when that
#              Profile carries an ArgoCD tracking-id (declared in GitOps)
#   other      anything else: reported only
# $profiles: {"<name>": {"uid": "...", "tracked": true|false}}. The result is
# stored on each item as .teknoirPost = {class, strict, profile}.
RELEASE_JQ_CLASSIFY='
def tracked_by($app): ((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | test("^([^:]*_)?" + $app + ":"));
def classify($root; $profiles):
  ([.metadata.ownerReferences[]? | select(.kind == "Profile")][0] // null) as $own
  | if .metadata.name == $root or tracked_by($root) then {class: "platform", strict: true, profile: ""}
    elif $own != null then
      ($profiles[$own.name] // null) as $p
      | {class: "teamspace", profile: $own.name,
         strict: ($p != null and $p.tracked and (($own.uid // "") == "" or $own.uid == $p.uid))}
    else {class: "other", strict: false, profile: ""} end;
'

# jq: resync_patch - the one merge patch that re-syncs an Application the way
# ArgoCD's SetAppOperation and auto-sync do: the operation (revision it is at,
# prune and syncOptions of its sync policy, its retry or ArgoCD's default 5)
# plus status.operationState cleared in the same write, guarded by the
# resourceVersion it was read at (a concurrent change makes it fail: 409).
RELEASE_JQ_RESYNC='
def resync_patch:
  {metadata: {resourceVersion: .metadata.resourceVersion},
   operation: {initiatedBy: {username: "teknoir-node"},
               sync: ({prune: (.spec.syncPolicy.automated.prune // false),
                       syncOptions: (.spec.syncPolicy.syncOptions // null)}
                      + (if (.spec.sources // [] | length) > 0
                         then {revisions: (.status.sync.revisions // null)}
                         else {revision: (.status.sync.revision // null)} end)
                      | with_entries(select(.value != null))),
               retry: (.spec.syncPolicy.retry // {limit: 5})},
   status: {operationState: null}};
'

# Filled by release_load_record.
REC_SOURCE=""          # configmap | application | none
REC_AOA=""
REC_BUNDLE=""
REC_SHA=""
REC_MODE=""
REC_HISTORY=""
REC_PREV_BUNDLE=""

release_broken_list() {
  local extra
  extra="$(manifest_get brokenAppOfApps | tr -d '[],"'"'" | tr -s ' ')"
  printf '%s %s' "${BROKEN_APP_OF_APPS_DEFAULT}" "${extra}"
}

release_load_record() {
  # The deployed state: the release ConfigMap, else (a pre-redesign cluster)
  # the live root Application's targetRevision, else none.
  local json
  REC_SOURCE="none" REC_AOA="" REC_BUNDLE="" REC_SHA="" REC_MODE="" REC_HISTORY="" REC_PREV_BUNDLE=""
  if in_cluster configmap "${RELEASE_CM}" "${RELEASE_NS}"; then
    json="$(kc -n "${RELEASE_NS}" get configmap "${RELEASE_CM}" -o json)" \
      || die "cannot read ${RELEASE_NS}/${RELEASE_CM}"
    REC_SOURCE="configmap"
    REC_AOA="$("${JQ}" -r '.data.appOfAppsVersion // ""' <<<"${json}")"
    REC_BUNDLE="$("${JQ}" -r '.data.bundleId // ""' <<<"${json}")"
    REC_SHA="$("${JQ}" -r '.data.manifestSha256 // ""' <<<"${json}")"
    REC_MODE="$("${JQ}" -r '.data.mode // ""' <<<"${json}")"
    REC_HISTORY="$("${JQ}" -r '.data.history // ""' <<<"${json}")"
    REC_PREV_BUNDLE="$("${JQ}" -r '.data.previousBundleId // ""' <<<"${json}")"
    return 0
  fi
  if in_cluster "${APP_CRD}" "${ROOT_APP}" "${RELEASE_NS}"; then
    REC_AOA="$(kc -n "${RELEASE_NS}" get "${APP_CRD}" "${ROOT_APP}" -o 'jsonpath={.spec.source.targetRevision}')" \
      || die "cannot read the root Application"
    [[ -n "${REC_AOA}" ]] && REC_SOURCE="application"
  fi
  return 0
}

release_guard() {
  # Dies on a broken or unpinned version, or on a downgrade without
  # --rollback. Read-only; runs in preflight and again in the release phase.
  local target="${APP_OF_APPS_VERSION:-}" b
  [[ -n "${target}" ]] || die "this payload has no app-of-apps version (MANIFEST.yaml appOfAppsVersion or charts/pins.txt)"
  [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
    || die "app-of-apps version '${target}' is not a pinned release version"
  for b in $(release_broken_list); do
    [[ "${target}" != "${b}" ]] \
      || die "app-of-apps ${target} must never be deployed (broken list: its Harbor content was overwritten); not even with --rollback"
  done
  release_load_record
  if [[ "${REC_SOURCE}" == "none" ]]; then
    log "release guard: no deployed release recorded; app-of-apps ${target} is a first install"
    return 0
  fi
  if version_lt "${target}" "${REC_AOA}"; then
    if [[ "${ROLLBACK}" == "1" ]]; then
      warn "rollback: app-of-apps ${REC_AOA} -> ${target} (--rollback)"
      return 0
    fi
    die "this bundle pins app-of-apps ${target}, older than the deployed ${REC_AOA} (${REC_SOURCE}${REC_BUNDLE:+, bundle ${REC_BUNDLE}}); refusing a downgrade - re-run with --rollback to roll back deliberately"
  fi
  if [[ "${ROLLBACK}" == "1" ]]; then
    warn "--rollback given, but app-of-apps ${target} is not older than the deployed ${REC_AOA}: a normal converge"
  fi
  log "release guard: deployed ${REC_AOA} (${REC_SOURCE}), this bundle ${target}: ok"
}

release_mode() {
  if [[ "${REC_SOURCE}" == "none" ]]; then
    printf 'install'
  elif version_lt "${APP_OF_APPS_VERSION}" "${REC_AOA}"; then
    printf 'rollback'
  elif [[ "${REC_MODE}" == "rollback" && "${APP_OF_APPS_VERSION}" == "${REC_AOA}" ]]; then
    printf 'rollback'
  else
    printf 'update'
  fi
}

release_record() {
  # Rewrite the record only when the deployed identity changes, so an
  # idempotent re-run reports 0 changes.
  local mode now operator line history f
  mode="$(release_mode)"
  if [[ "${REC_SOURCE}" == "configmap" && "${REC_BUNDLE}" == "${BUNDLE_ID}" \
        && "${REC_SHA}" == "${MANIFEST_SHA256}" && "${REC_AOA}" == "${APP_OF_APPS_VERSION}" ]]; then
    log "release record: bundle ${BUNDLE_ID} already recorded"
    return 0
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  operator="${LAN_USER:-unknown}@lan via ${SUDO_USER:-root}@$(hostname 2>/dev/null || echo node)"
  line="${now} ${mode} ${BUNDLE_ID} app-of-apps=${APP_OF_APPS_VERSION} by ${operator}"
  history="$(printf '%s\n%s\n' "${line}" "${REC_HISTORY}" | sed '/^$/d' | head -n "${RELEASE_HISTORY_MAX}")"
  ensure_work_dir
  f="${WORK_DIR}/release.json"
  "${JQ}" -n \
    --arg ns "${RELEASE_NS}" --arg name "${RELEASE_CM}" \
    --arg bundleId "${BUNDLE_ID}" --arg aoa "${APP_OF_APPS_VERSION}" \
    --arg sha "${MANIFEST_SHA256}" --arg infra "${INFRA_COMMIT:-}" --arg gitops "${GITOPS_COMMIT:-}" \
    --arg mode "${mode}" --arg at "${now}" --arg op "${operator}" \
    --arg prev "${REC_BUNDLE}" --arg prevAoa "${REC_AOA}" --arg hist "${history}" '{
      apiVersion: "v1", kind: "ConfigMap",
      metadata: {name: $name, namespace: $ns,
        labels: {"app.kubernetes.io/managed-by": "teknoir-node"}},
      data: {bundleId: $bundleId, appOfAppsVersion: $aoa, manifestSha256: $sha,
        infraCommit: $infra, gitopsCommit: $gitops, mode: $mode, updatedAt: $at,
        operator: $op, previousBundleId: $prev, previousAppOfAppsVersion: $prevAoa,
        history: $hist}
    }' > "${f}"
  apply_ssa "${f}" teknoir-bootstrap "ConfigMap ${RELEASE_NS}/${RELEASE_CM} (${mode} to ${BUNDLE_ID})"
}

phase_release() {
  local f
  require_cluster release || return 0
  release_guard
  if ! crd_established "${APP_CRD}"; then
    if dry_run; then
      log "[dry-run] the ArgoCD CRDs are not installed yet: the root Application ${ROOT_APP} ${APP_OF_APPS_VERSION} would be applied after the one-shot argo tier"
      return 0
    fi
    die "release: CRD ${APP_CRD} is not Established (ArgoCD missing? the oneshot phase installs it)"
  fi
  ensure_work_dir
  f="${WORK_DIR}/app-of-apps.yaml"
  render_template "${NODE_ROOT}/templates/app-of-apps.yaml.tmpl" > "${f}"
  dry_run || RELEASE_PIN_AT="$(date +%s)"
  apply_ssa "${f}" teknoir-bootstrap "root AppProject default + Application ${ROOT_APP} at ${APP_OF_APPS_VERSION}"
  dry_run || release_request_refresh
  release_record
}

release_request_refresh() {
  # Ask ArgoCD to compare the root now, in a later second than the pin:
  # status.reconciledAt has second resolution, and post requires the root's
  # to be later than RELEASE_PIN_AT. Not recorded as a change: a request
  # ArgoCD consumes (and removes); the pin itself is reported by apply_ssa.
  while (( $(date +%s) <= RELEASE_PIN_AT )); do
    sleep 0.2
  done
  if kc -n "${RELEASE_NS}" annotate "${APP_CRD}" "${ROOT_APP}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1; then
    log "requested an ArgoCD refresh of ${ROOT_APP}"
  else
    warn "could not request a refresh of ${ROOT_APP}; post waits for ArgoCD's next periodic reconcile"
  fi
}

release_status() {
  release_load_record
  case "${REC_SOURCE}" in
    configmap)
      printf 'release:   app-of-apps %s, bundle %s (%s)\n' "${REC_AOA}" "${REC_BUNDLE}" "${REC_MODE}"
      printf '%s\n' "${REC_HISTORY}" | sed '/^$/d; s/^/history:   /'
      ;;
    application) printf 'release:   no release record; root Application pins app-of-apps %s\n' "${REC_AOA}" ;;
    none) printf 'release:   nothing deployed yet\n' ;;
  esac
  crd_established "${APP_CRD}" || return 0
  # which Applications `up` waits for (R2), with how many are not ready
  _release_applications_json | "${JQ}" -r --arg root "${ROOT_APP}" "${RELEASE_JQ_READY}"'
    [.items[] | {k: (if .teknoirPost.class == "platform" then "platform"
                     elif .teknoirPost.class == "teamspace" then "teamspace \(.teknoirPost.profile)"
                     else "other" end),
                 strict: .teknoirPost.strict, bad: (why($root; 0) != "")}]
    | group_by([.k, .strict])[]
    | "apps:      \(.[0].k): \(length) Application(s), \(map(select(.bad)) | length) not ready (\(
        if .[0].strict then "up waits for them" else "reported only, never block up" end))"'
}

# ---------------------------------------------------------------------------
# post
# ---------------------------------------------------------------------------
_release_profiles_map() {
  # _release_profiles_map <profiles-list-json> - {"<name>": {uid, tracked}}:
  # names, uids and whether ArgoCD tracks the Profile (declared in GitOps).
  "${JQ}" -c '[.items[]? | {key: .metadata.name,
                value: {uid: (.metadata.uid // ""),
                        tracked: ((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") != "")}}]
              | from_entries' <<<"$1"
}

_release_classify() {
  # _release_classify <applications-list-json> <profiles-list-json> - the
  # Application list with .teknoirPost = {class, strict, profile} on every item.
  "${JQ}" -c --arg root "${ROOT_APP}" --argjson profiles "$(_release_profiles_map "$2")" "${RELEASE_JQ_CLASSIFY}"'
    .items |= map(. + {teknoirPost: classify($root; $profiles)})' <<<"$1"
}

_release_applications_json() {
  # Every Application in RELEASE_NS, classified (_release_classify) against
  # the Profiles (none while the Profile CRD is not installed).
  local apps profiles='{"items":[]}'
  apps="$(kc -n "${RELEASE_NS}" get "${APP_CRD}" -o json)" || die "cannot list Applications"
  if crd_established "${PROFILE_CRD}"; then
    profiles="$(kc get "${PROFILE_CRD}" -o json)" || die "cannot list Profiles"
  fi
  _release_classify "${apps}" "${profiles}"
}

post_application_table() {
  # Name, sync, health, revision and class; plus, for every Application that
  # is not ready (see RELEASE_JQ_READY), why and its last operation message.
  # Classes marked * are reported only: they never make post wait or fail.
  local json
  if ! crd_established "${APP_CRD}"; then
    printf 'apps:      ArgoCD is not installed\n'
    return 0
  fi
  json="$(_release_applications_json)"
  "${JQ}" -r '
    def rev: (.status.sync.revision // .spec.source.targetRevision // "-");
    def cls: (if .teknoirPost.class == "platform" then "platform"
              elif .teknoirPost.class == "teamspace" then "teamspace/\(.teknoirPost.profile)"
              else "other" end) + (if .teknoirPost.strict then "" else "*" end);
    .items | sort_by(.metadata.name)[] |
    [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown"), rev, cls] | @tsv' <<<"${json}" \
    | awk -F'\t' 'BEGIN {printf "%-32s %-10s %-12s %-10s %s\n", "APPLICATION", "SYNC", "HEALTH", "REVISION", "CLASS"}
                  {printf "%-32s %-10s %-12s %-10s %s\n", $1, $2, $3, $4, $5}'
  "${JQ}" -r --arg root "${ROOT_APP}" --argjson pinAt "${RELEASE_PIN_AT:-0}" "${RELEASE_JQ_READY}"'
    if any(.items[]; .teknoirPost.strict | not) then "(* reported only: up never waits for these)" else empty end,
    (.items[] | why($root; $pinAt) as $w | select($w != "") |
    "  \(.metadata.name)\(if .teknoirPost.strict then "" else " [reported only]" end): \($w) | \((.status.operationState.phase // "no operation")) \((.status.operationState.message // (.status.conditions // [] | map(.message) | join("; ")) // "") | .[0:300])")' <<<"${json}"
}

_release_post_not_ready() {
  # "name<TAB>reasons" of every strict Application (platform, or a teamspace
  # declared in GitOps) that is not ready; one line while the root
  # Application does not exist yet.
  "${JQ}" -r --arg root "${ROOT_APP}" --argjson pinAt "${RELEASE_PIN_AT:-0}" "${RELEASE_JQ_READY}"'
    if any(.items[]; .metadata.name == $root) | not then "\($root)\tnot created yet (waiting for the release phase or ArgoCD)" else
    .items[] | select(.teknoirPost.strict) | why($root; $pinAt) as $w | select($w != "") | "\(.metadata.name)\t\($w)" end' <<<"$1"
}

_release_post_reported() {
  # "name<TAB>class<TAB>reasons" of every not-ready Application post only
  # reports (a teamspace not declared in GitOps, or no known owner).
  "${JQ}" -r --arg root "${ROOT_APP}" "${RELEASE_JQ_READY}"'
    .items[] | select(.teknoirPost.strict | not) | why($root; 0) as $w | select($w != "")
    | "\(.metadata.name)\t\(if .teknoirPost.class == "teamspace" then "teamspace \(.teknoirPost.profile), not declared in GitOps" else "no Teknoir owner" end)\t\($w)"' <<<"$1"
}

_release_resync_candidates() {
  # Names of the platform Applications whose last sync of their current
  # revision Failed/Errored and that have no operation pending (HYG-C3).
  "${JQ}" -r --arg root "${ROOT_APP}" "${RELEASE_JQ_READY}"'
    .items[] | select(.teknoirPost.class == "platform") | select(failedop) | .metadata.name' <<<"$1"
}

_release_resync_patch() {
  # _release_resync_patch <application-json> - the merge patch body (one line).
  "${JQ}" -c "${RELEASE_JQ_RESYNC}"'resync_patch' <<<"$1"
}

post_resync_failed() {
  # post_resync_failed <classified-applications-json> - re-sync each platform
  # Application whose last sync of its current revision failed, at most once
  # per run (RELEASE_RESYNCED): ArgoCD's auto-sync never retries a revision
  # whose sync failed ("failed previous sync attempt"), so without this the
  # Application stays that way until the next chart version. A 409 (it changed
  # since it was read) is retried at the next poll.
  local json="$1" name app body reason
  while IFS= read -r name; do
    [[ -n "${name}" && -z "${RELEASE_RESYNCED[${name}]:-}" ]] || continue
    app="$("${JQ}" -c --arg n "${name}" '.items[] | select(.metadata.name == $n) | del(.teknoirPost)' <<<"${json}")"
    reason="$("${JQ}" -r --arg root "${ROOT_APP}" "${RELEASE_JQ_READY}"'
      "last sync to \(oprev | revstr) \(.status.operationState.phase)"' <<<"${app}")"
    if dry_run; then
      RELEASE_RESYNCED["${name}"]=1
      changed "re-sync Application ${name} once (${reason}): one merge patch sets .operation and clears .status.operationState"
      continue
    fi
    body="$(_release_resync_patch "${app}")"
    if kc -n "${RELEASE_NS}" patch "${APP_CRD}" "${name}" --type merge -p "${body}" >/dev/null 2>&1; then
      RELEASE_RESYNCED["${name}"]=1
      changed "re-synced Application ${name} once (${reason}): .operation set and .status.operationState cleared in one merge patch"
    else
      warn "could not re-sync Application ${name} now (changed since it was read?); trying again at the next poll"
    fi
  done < <(_release_resync_candidates "${json}")
}

post_wait_applications() {
  local timeout json bad names last_report=0 refreshed=0 deadline
  if ! crd_established "${APP_CRD}"; then
    dry_run && { log "[dry-run] ArgoCD is not installed yet: post would wait for the Applications"; return 0; }
    die "post: CRD ${APP_CRD} is not Established"
  fi
  timeout="${WAIT_TIMEOUT:-}"
  if [[ -z "${timeout}" ]]; then
    timeout="${POST_WAIT_DEFAULT}"
    if [[ "${REC_SOURCE}" == "none" || "${REC_MODE}" == "install" ]]; then
      timeout="${POST_WAIT_FIRST_INSTALL}"
    fi
  fi
  deadline=$(( SECONDS + timeout ))
  while :; do
    json="$(_release_applications_json)"
    post_resync_failed "${json}"
    bad="$(_release_post_not_ready "${json}")"
    if [[ -z "${bad}" ]]; then
      post_application_table >&2
      log "every platform Application (and every teamspace declared in GitOps) is Synced/Healthy at its current spec"
      post_report_unwaited "${json}"
      return 0
    fi
    names="$(cut -f1 <<<"${bad}" | tr '\n' ' ')"
    if dry_run; then
      post_application_table >&2
      log "[dry-run] would wait up to ${timeout}s for: ${names}"
      post_report_unwaited "${json}"
      return 0
    fi
    if (( refreshed == 0 )) && cut -f1 <<<"${bad}" | grep -qxF "${ROOT_APP}"; then
      # Ask ArgoCD to re-read the root chart now (the harbor phase may just
      # have pushed it) instead of waiting for the next poll.
      kc -n "${RELEASE_NS}" annotate "${APP_CRD}" "${ROOT_APP}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 \
        || warn "could not request a refresh of ${ROOT_APP}"
      refreshed=1
    fi
    if (( SECONDS >= deadline )); then
      post_application_table >&2
      post_report_unwaited "${json}"
      die "post: after ${timeout}s these Applications are not Synced/Healthy at this release: $(awk -F'\t' '{printf "%s (%s) ", $1, $2}' <<<"${bad}")"
    fi
    if (( SECONDS - last_report >= 60 )); then
      log "waiting for Synced/Healthy ($(( deadline - SECONDS ))s left): ${names}"
      last_report=${SECONDS}
    fi
    sleep "${POST_POLL}"
  done
}

post_report_unwaited() {
  # One WARN for the not-ready Applications post does not wait for.
  local reported
  reported="$(_release_post_reported "$1")"
  [[ -n "${reported}" ]] || return 0
  warn "not ready, not waited for (teamspaces not declared in GitOps and Applications without a Teknoir owner never block up): $(awk -F'\t' '{printf "%s [%s] (%s); ", $1, $2, $3}' <<<"${reported}")"
}

_release_mirror_ref() {
  # _release_mirror_ref <normalized ref> - where the node pulls it from: Harbor's
  # mirror project for the upstream registry (registries.yaml), else itself.
  local ref="$1" reg rest
  reg="${ref%%/*}"
  rest="${ref#*/}"
  case "${reg}" in
    docker.io) printf '%s/dockerhub/%s' "${HARBOR_HOST}" "${rest}" ;;
    ghcr.io) printf '%s/ghcr/%s' "${HARBOR_HOST}" "${rest}" ;;
    gcr.io) printf '%s/gcr/%s' "${HARBOR_HOST}" "${rest}" ;;
    quay.io) printf '%s/quay/%s' "${HARBOR_HOST}" "${rest}" ;;
    registry.k8s.io) printf '%s/k8s/%s' "${HARBOR_HOST}" "${rest}" ;;
    *) printf '%s' "${ref}" ;;
  esac
}

post_image_check() {
  # Every image of a running container must be re-pullable from Harbor, or at
  # least present in containerd (warned: lost on image GC). Missing from both
  # fails.
  local images present ref norm ok=0 local_only=0 missing=0 missing_list="" local_list=""
  if [[ ! -x "${K3S_BIN}" ]]; then
    log "live image check: skipped (no k3s binary on this host)"
    return 0
  fi
  images="$(kc get pods -A -o json | "${JQ}" -r '.items[] | select(.status.phase == "Running") |
              (.spec.containers[].image, (.spec.initContainers // [])[].image)' | sort -u)" \
    || die "cannot list pod images"
  present="$(host_containerd_images)"
  for ref in ${images}; do
    norm="$(host_normalize_image_ref "${ref}")"
    if [[ -x "${CRANE}" ]] && "${CRANE}" digest --platform linux/amd64 "$(_release_mirror_ref "${norm}")" >/dev/null 2>&1; then
      ok=$(( ok + 1 ))
    elif grep -qxF "${norm}" <<<"${present}"; then
      local_only=$(( local_only + 1 ))
      (( local_only <= 10 )) && local_list+=" ${norm}"
    else
      missing=$(( missing + 1 ))
      missing_list+=" ${norm}"
    fi
  done
  log "live image check: ${ok} pullable from Harbor, ${local_only} only in containerd, ${missing} missing"
  if (( local_only > 0 )); then
    (( local_only > 10 )) && local_list+=" ... and $(( local_only - 10 )) more"
    warn "running images not pullable from ${HARBOR_HOST} (kept only by containerd, lost on image GC):${local_list}"
  fi
  (( missing == 0 )) || die "post: running images neither in Harbor nor in containerd:${missing_list}"
}

_release_kc_cfg_escape() {
  # curl config quoting: backslash and double quote escaped
  local v="${1//\\/\\\\}"
  printf '%s' "${v//\"/\\\"}"
}

_release_kc_login() {
  # _release_kc_login <user> <password> - RELEASE_KC_CODE: the HTTP status of
  # a master-realm password-grant token request (client admin-cli) at
  # https://auth.<domain>/auth, through the gateway on NODE_IP and with the
  # platform CA when its public copy exists. The credentials reach curl in a
  # config file on a pipe, never on argv; only the status code is kept. Not
  # for $(...): call ensure_work_dir first, in the main shell.
  local ca="" code url
  local -a cacert=()
  if in_cluster secret teknoir-root-ca-bundle "${RELEASE_NS}"; then
    ca="$(umask 077 && mktemp "${WORK_DIR}/kc-ca.XXXXXX")" || die "cannot create a temp file"
    secret_value "${RELEASE_NS}" teknoir-root-ca-bundle ca.crt > "${ca}"
    cacert=(--cacert "${ca}")
  fi
  url="${RELEASE_KEYCLOAK_URL:-https://auth.${TEKNOIR_DOMAIN}/auth}"
  # shellcheck disable=SC2086  # RELEASE_CURL_OPTS: extra curl flags (tests)
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 30 ${cacert[@]+"${cacert[@]}"} \
      --resolve "auth.${TEKNOIR_DOMAIN}:443:${NODE_IP}" ${RELEASE_CURL_OPTS:-} \
      -K <(printf 'data-urlencode = "grant_type=password"\ndata-urlencode = "client_id=admin-cli"\ndata-urlencode = "username=%s"\ndata-urlencode = "password=%s"\n' \
             "$(_release_kc_cfg_escape "$1")" "$(_release_kc_cfg_escape "$2")") \
      "${url}/realms/master/protocol/openid-connect/token" 2>/dev/null)" || code="${code:-000}"
  [[ -z "${ca}" ]] || rm -f "${ca}"
  RELEASE_KC_CODE="${code:-000}"
}

post_keycloak_admin_cleanup() {
  # Key previous-password of Secret teknoir-auth/keycloak-admin (the master
  # admin's password before the migration, see migrate) is only needed until
  # the auth sync's admin check has rotated the admin to key password. Remove
  # it once a master-realm login with key password works (HTTP 200); else keep
  # it and warn. The removal is guarded by the resourceVersion that was read,
  # so a password changed in between is never paired with a stale check.
  local meta rv keys user="admin" pass=""
  in_cluster secret "${RELEASE_KC_SECRET}" "${RELEASE_KC_NS}" || return 0
  # resourceVersion and which keys exist; never a value
  meta="$(kc -n "${RELEASE_KC_NS}" get secret "${RELEASE_KC_SECRET}" \
    -o 'go-template={{ .metadata.resourceVersion }}:{{ with .data }}{{ if index . "username" }}u{{ end }}{{ if index . "password" }}p{{ end }}{{ if index . "previous-password" }}x{{ end }}{{ end }}')" \
    || die "cannot read Secret ${RELEASE_KC_NS}/${RELEASE_KC_SECRET}"
  if [[ ! "${meta}" =~ ^([0-9]+):([upx]*)$ ]]; then
    warn "keycloak-admin: unexpected metadata of Secret ${RELEASE_KC_NS}/${RELEASE_KC_SECRET}; previous-password not checked"
    return 0
  fi
  rv="${BASH_REMATCH[1]}" keys="${BASH_REMATCH[2]}"
  [[ "${keys}" == *x* ]] || return 0
  if [[ "${keys}" != *p* ]]; then
    warn "keycloak-admin: Secret ${RELEASE_KC_NS}/${RELEASE_KC_SECRET} has previous-password but no password yet (the platform-secrets Job adds it): previous-password is kept"
    return 0
  fi
  if dry_run; then
    log "[dry-run] keycloak-admin: has previous-password; post would remove it once the master admin logs in with key password"
    return 0
  fi
  if [[ "${keys}" == *u* ]]; then
    user="$(secret_value "${RELEASE_KC_NS}" "${RELEASE_KC_SECRET}" username)"
  fi
  read_secret pass "${RELEASE_KC_NS}" "${RELEASE_KC_SECRET}" password
  ensure_work_dir
  _release_kc_login "${user}" "${pass}"
  pass=""
  case "${RELEASE_KC_CODE}" in
    200)
      if kc -n "${RELEASE_KC_NS}" patch secret "${RELEASE_KC_SECRET}" --type=json \
           -p "[{\"op\":\"test\",\"path\":\"/metadata/resourceVersion\",\"value\":\"${rv}\"},{\"op\":\"remove\",\"path\":\"/data/previous-password\"}]" >/dev/null 2>&1; then
        changed "removed key previous-password from Secret ${RELEASE_KC_NS}/${RELEASE_KC_SECRET} (the master admin logs in with key password)"
      else
        warn "keycloak-admin: could not remove previous-password from Secret ${RELEASE_KC_NS}/${RELEASE_KC_SECRET} (changed since it was read?); the next up tries again"
      fi
      ;;
    400|401)
      warn "keycloak-admin: the master admin does not log in with key password of Secret ${RELEASE_KC_NS}/${RELEASE_KC_SECRET} (HTTP ${RELEASE_KC_CODE}): previous-password is kept; the auth sync's admin check rotates the admin with it (see the keycloak-config Job log)"
      ;;
    *)
      warn "keycloak-admin: cannot check the master admin login at Keycloak (HTTP ${RELEASE_KC_CODE}): previous-password is kept"
      ;;
  esac
}

post_argocd_initial_admin() {
  # ArgoCD's first admin password stays readable in this Secret until the
  # local admin is rotated (`teknoir-airgap rotate argocd-admin` deletes it).
  in_cluster secret "${ARGOCD_INITIAL_ADMIN_SECRET}" "${RELEASE_NS}" || return 0
  warn "Secret ${RELEASE_NS}/${ARGOCD_INITIAL_ADMIN_SECRET} still holds ArgoCD's initial admin password: run teknoir-airgap rotate argocd-admin (it rotates the local admin and deletes that Secret)"
}

post_prune_bundles() {
  # Keep the current payload and the previous one; remove older ones.
  local bundles current d keep_prev="" n=0
  bundles="${STATE_DIR}/bundles"
  current="$(cd "${NODE_ROOT}/.." && pwd)"
  [[ "$(dirname "${current}")" == "${bundles}" ]] || { log "payload is not under ${bundles}: no bundle pruning"; return 0; }
  if [[ -n "${REC_PREV_BUNDLE}" && "${REC_PREV_BUNDLE}" != "${BUNDLE_ID}" && -d "${bundles}/${REC_PREV_BUNDLE}" ]]; then
    keep_prev="${bundles}/${REC_PREV_BUNDLE}"
  fi
  while IFS= read -r d; do
    [[ -n "${d}" && "${d}" != "${current}" ]] || continue
    if [[ -z "${keep_prev}" ]] && (( n < BUNDLES_KEEP_PREVIOUS )); then
      keep_prev="${d}"
    fi
    n=$(( n + 1 ))
    [[ "${d}" == "${keep_prev}" ]] && continue
    run rm -rf "${d}"
    changed "pruned old bundle payload ${d}"
  done < <(find "${bundles}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

phase_post() {
  require_cluster post || return 0
  # release_load_record reflects what the release phase recorded.
  release_load_record
  post_wait_applications
  post_keycloak_admin_cleanup
  post_argocd_initial_admin
  post_image_check
  post_prune_bundles
}
