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
# post: wait until every Application is Synced/Healthy (report per app on
#   timeout), check every running image is re-pullable (Harbor) or present
#   (containerd), and prune old bundle payloads (keep current + previous).
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # jq programs use $variables in single quotes
# shellcheck source=common.sh
source "${NODE_ROOT}/lib/common.sh"

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
  apply_ssa "${f}" teknoir-bootstrap "root AppProject default + Application ${ROOT_APP} at ${APP_OF_APPS_VERSION}"
  release_record
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
}

# ---------------------------------------------------------------------------
# post
# ---------------------------------------------------------------------------
_release_applications_json() {
  kc -n "${RELEASE_NS}" get "${APP_CRD}" -o json || die "cannot list Applications"
}

post_application_table() {
  # Name, sync, health, revision; plus the last operation message of every
  # Application that is not Synced/Healthy.
  local json
  if ! crd_established "${APP_CRD}"; then
    printf 'apps:      ArgoCD is not installed\n'
    return 0
  fi
  json="$(_release_applications_json)"
  "${JQ}" -r '
    def rev: (.status.sync.revision // .spec.source.targetRevision // "-");
    .items | sort_by(.metadata.name)[] |
    [.metadata.name, (.status.sync.status // "Unknown"), (.status.health.status // "Unknown"), rev] | @tsv' <<<"${json}" \
    | awk -F'\t' 'BEGIN {printf "%-26s %-10s %-12s %s\n", "APPLICATION", "SYNC", "HEALTH", "REVISION"}
                  {printf "%-26s %-10s %-12s %s\n", $1, $2, $3, $4}'
  "${JQ}" -r '
    .items[] | select((.status.sync.status // "") != "Synced" or (.status.health.status // "") != "Healthy") |
    "  \(.metadata.name): \((.status.operationState.phase // "no operation")) \((.status.operationState.message // (.status.conditions // [] | map(.message) | join("; ")) // "") | .[0:300])"' <<<"${json}"
}

_release_post_not_ready() {
  # Names of Applications not Synced/Healthy (all names when none exist).
  "${JQ}" -r 'if (.items | length) == 0 then "(no Applications yet)" else
    .items[] | select((.status.sync.status // "") != "Synced" or (.status.health.status // "") != "Healthy") | .metadata.name end' <<<"$1"
}

post_wait_applications() {
  local timeout json bad last_report=0 refreshed=0 deadline
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
    bad="$(_release_post_not_ready "${json}")"
    if [[ -z "${bad}" ]]; then
      post_application_table >&2
      log "every Application is Synced/Healthy"
      return 0
    fi
    if dry_run; then
      post_application_table >&2
      log "[dry-run] would wait up to ${timeout}s for: $(tr '\n' ' ' <<<"${bad}")"
      return 0
    fi
    if (( refreshed == 0 )) && grep -qxF "${ROOT_APP}" <<<"${bad}"; then
      # Ask ArgoCD to re-read the root chart now (the harbor phase may just
      # have pushed it) instead of waiting for the next poll.
      kc -n "${RELEASE_NS}" annotate "${APP_CRD}" "${ROOT_APP}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 \
        || warn "could not request a refresh of ${ROOT_APP}"
      refreshed=1
    fi
    if (( SECONDS >= deadline )); then
      post_application_table >&2
      die "post: after ${timeout}s these Applications are not Synced/Healthy: $(tr '\n' ' ' <<<"${bad}")"
    fi
    if (( SECONDS - last_report >= 60 )); then
      log "waiting for Synced/Healthy ($(( deadline - SECONDS ))s left): $(tr '\n' ' ' <<<"${bad}")"
      last_report=${SECONDS}
    fi
    sleep "${POST_POLL}"
  done
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
  post_image_check
  post_prune_bundles
}
