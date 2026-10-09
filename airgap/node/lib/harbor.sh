# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016  # NODE_ROOT, DRY_RUN, TEKNOIR_DOMAIN come from common.sh and the site env; jq programs are single-quoted on purpose
#
# lib/harbor.sh — converge phase "harbor" (docs/airgap/DESIGN.md I-09), run on
# the node after the one-shot tiers:
#   - projects teknoir (Helm charts) and dockerhub, ghcr, gcr, quay, k8s
#     (registry mirrors), all public (D3), with a tag-immutability rule on
#     teknoir only (D9);
#   - charts from node/charts (pins.txt): pushed when absent; skipped when
#     Harbor holds the same chart (same content digest, or the same files in a
#     differently packed .tgz); refused when Harbor's copy of that version
#     differs: a released version is immutable;
#   - images from node/images (images.lock, OCI layouts) and
#     node/bootstrap-images (docker archives), linux/amd64: compared by image
#     config digest (the image ID, which survives re-compression and a
#     multi-platform index on the Harbor side); skipped when present, pushed
#     when absent, and a mirror tag that points at a different image is
#     refused unless --force-images;
#   - robot$argocd is deleted once no ArgoCD Secret uses it (D3; on the live
#     env `teknoir-node migrate` first retires the repo-creds Secret).
#
#   phase_harbor [--force-images]          (or HARBOR_FORCE_IMAGES=1)
#
# The admin password is read from Secret teknoir-system/harbor-secret into a
# variable only. curl gets it through a config on a pipe (-K <(...)), crane
# and helm through --password-stdin into a DOCKER_CONFIG / HELM_REGISTRY_CONFIG
# in a 0700 mktemp directory; the operator's ~/.docker and ~/.config/helm are
# never touched. Nothing prints a credential. The directory is removed at the
# end of the phase and, after a die, by the runner's at_exit list (common.sh);
# without at_exit, by a step chained onto the EXIT trap that keeps the exit
# status for the runner's own handler.
#
# Dry-run (DRY_RUN=1) reads only: with no reachable cluster, or before the
# one-shot tiers have created harbor-secret, or while Harbor does not answer,
# it prints the plan from the bundle alone.

HARBOR_CHART_PROJECT="teknoir"
HARBOR_MIRRORS="${HARBOR_MIRRORS:-docker.io=dockerhub ghcr.io=ghcr gcr.io=gcr quay.io=quay registry.k8s.io=k8s}"
HARBOR_PLATFORM="${HARBOR_PLATFORM:-linux/amd64}"
HARBOR_HEALTH_TIMEOUT="${HARBOR_HEALTH_TIMEOUT:-900}"
HARBOR_PUSH_ATTEMPTS="${HARBOR_PUSH_ATTEMPTS:-4}"
HARBOR_RETRY_DELAY="${HARBOR_RETRY_DELAY:-5}"
HARBOR_SECRET_NS="${HARBOR_SECRET_NS:-teknoir-system}"
HARBOR_SECRET_NAME="${HARBOR_SECRET_NAME:-harbor-secret}"
HARBOR_CHART_MEDIA_TYPE="application/vnd.cncf.helm.chart.content.v1.tar+gzip"
HARBOR_TMP=""
HARBOR_PW=""
HARBOR_PREV_EXIT=""
HARBOR_TRAP_CHAINED=0
HARBOR_AT_EXIT=0

phase_harbor() {
  local force="${HARBOR_FORCE_IMAGES:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-images) force=1; shift ;;
      *) die "phase_harbor: unknown argument: $1" ;;
    esac
  done
  if declare -F require_cluster >/dev/null; then
    require_cluster harbor || { harbor_init; harbor_plan_offline "the cluster is not reachable"; return 0; }
  fi
  if harbor_absent_in_dry_run; then
    harbor_plan_offline "Harbor is not installed yet (no Secret ${HARBOR_SECRET_NS}/${HARBOR_SECRET_NAME})"
    return 0
  fi
  harbor_session_begin
  wait_for "the Harbor API at ${HARBOR_API}" "${HARBOR_HEALTH_TIMEOUT}" harbor_healthy
  if [[ "${DRY_RUN}" == "1" ]] && ! harbor_healthy; then
    harbor_session_end
    harbor_plan_offline "Harbor does not answer at ${HARBOR_API} yet"
    return 0
  fi
  harbor_login
  local p
  harbor_ensure_project "${HARBOR_CHART_PROJECT}"
  for p in $(harbor_mirror_projects); do
    harbor_ensure_project "${p}"
  done
  harbor_ensure_immutability "${HARBOR_CHART_PROJECT}"
  harbor_retire_robot
  harbor_push_charts
  harbor_push_images "${force}"
  harbor_session_end
}

# --- session: credentials, temp dir, tools ------------------------------------

harbor_init() {
  # hosts and bundled tools; no credentials
  HARBOR_HOST="${HARBOR_HOST:-harbor.${TEKNOIR_DOMAIN}}"
  HARBOR_API="${HARBOR_API:-https://${HARBOR_HOST}/api/v2.0}"
  HARBOR_REGISTRY="${HARBOR_REGISTRY:-${HARBOR_HOST}}"
  HARBOR_CRANE="$(harbor_tool crane)" || exit 1
  HARBOR_HELM="$(harbor_tool helm)" || exit 1
  HARBOR_JQ="$(harbor_tool jq)" || exit 1
}

harbor_absent_in_dry_run() {
  # 0 in dry-run when harbor-secret does not exist yet (the one-shot tiers of
  # this converge would create it, and Harbor with it); dies on errors
  [[ "${DRY_RUN}" == "1" ]] || return 1
  harbor_init
  ! in_cluster secret "${HARBOR_SECRET_NAME}" "${HARBOR_SECRET_NS}"
}

harbor_plan_offline() {
  # harbor_plan_offline <reason> — the dry-run plan from the bundle alone
  local charts=0 images=0 pins="${NODE_ROOT}/charts/pins.txt"
  [[ ! -f "${pins}" ]] || charts="$(grep -cvE '^[[:space:]]*(#|$)' "${pins}" || true)"
  harbor_image_sources
  [[ -z "${HARBOR_SOURCES}" ]] || images="$(grep -c . <<<"${HARBOR_SOURCES}")"
  log "[dry-run] $1: would create the public projects ${HARBOR_CHART_PROJECT} $(harbor_mirror_projects | tr '\n' ' ')(tag immutability on ${HARBOR_CHART_PROJECT}), push ${charts} chart(s) and ${images} image(s), and delete robot\$argocd once unused"
}

harbor_session_begin() {
  [[ -z "${HARBOR_TMP}" ]] || return 0
  harbor_init
  HARBOR_PW="$(secret_value "${HARBOR_SECRET_NS}" "${HARBOR_SECRET_NAME}" HARBOR_ADMIN_PASSWORD)" \
    || die "cannot read the Harbor admin password from Secret ${HARBOR_SECRET_NS}/${HARBOR_SECRET_NAME}"
  [[ -n "${HARBOR_PW}" ]] || die "Secret ${HARBOR_SECRET_NS}/${HARBOR_SECRET_NAME} has an empty HARBOR_ADMIN_PASSWORD"
  [[ "${HARBOR_PW}" != *$'\n'* ]] || die "the Harbor admin password contains a newline"
  # the runner's exit-time leak check proves it never reached the log
  if declare -F mark_sensitive >/dev/null; then mark_sensitive "${HARBOR_PW}"; fi
  harbor_cleanup_register
  HARBOR_TMP="$(mktemp -d)" || die "mktemp failed"
  chmod 0700 "${HARBOR_TMP}"
  mkdir -p "${HARBOR_TMP}/docker" "${HARBOR_TMP}/helm/config" "${HARBOR_TMP}/helm/cache" "${HARBOR_TMP}/helm/data"
  HARBOR_LOGGED_IN=0
}

harbor_session_end() {
  harbor_session_wipe
  if [[ "${HARBOR_TRAP_CHAINED}" == "1" ]]; then
    # put the runner's own EXIT trap back, verbatim
    if [[ -n "${HARBOR_PREV_EXIT}" ]]; then
      trap -- "${HARBOR_PREV_EXIT}" EXIT
    else
      trap - EXIT
    fi
    HARBOR_TRAP_CHAINED=0
    HARBOR_PREV_EXIT=""
  fi
}

harbor_session_wipe() {
  # remove the temp dir (registry logins) and forget the password; always 0
  if [[ -n "${HARBOR_TMP}" ]]; then
    rm -rf -- "${HARBOR_TMP}" || true
  fi
  HARBOR_TMP=""
  HARBOR_PW=""
}

harbor_exit_cleanup() {
  # EXIT-trap step: wipe the session and return the status the shell is
  # exiting with, so the next step of the trap (the runner's handler) sees it
  local rc=$?
  harbor_session_wipe
  return "${rc}"
}

harbor_cleanup_register() {
  # Clean up after a die too. common.sh's at_exit list runs from the runner's
  # EXIT handler, which keeps the exit status: register there, once.
  if declare -F at_exit >/dev/null; then
    if [[ "${HARBOR_AT_EXIT}" != "1" ]]; then
      at_exit harbor_session_wipe
      HARBOR_AT_EXIT=1
    fi
    return 0
  fi
  harbor_trap_install
}

harbor_trap_install() {
  # No at_exit: chain onto the EXIT trap. The runner's handler reads $? as the
  # exit status, and under `set -e` a non-zero step would end the trap before
  # it, so both branches of the `if` run it, with $? = the original status.
  local t prev
  local -a parts=()
  [[ "${HARBOR_TRAP_CHAINED}" != "1" ]] || return 0
  HARBOR_PREV_EXIT=""
  t="$(trap -p EXIT)"
  if [[ -n "${t}" ]]; then
    # "trap -- '<command>' EXIT", quoted by bash for re-use
    eval "parts=(${t})"
    HARBOR_PREV_EXIT="${parts[2]:-}"
  fi
  prev="${HARBOR_PREV_EXIT:-:}"
  # shellcheck disable=SC2064  # expand the previous command now
  trap "if harbor_exit_cleanup; then ${prev}
else ${prev}
fi" EXIT
  HARBOR_TRAP_CHAINED=1
}

harbor_tool() {
  if [[ -x "${NODE_ROOT}/bin/$1" ]]; then
    echo "${NODE_ROOT}/bin/$1"
  elif command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
  else
    die "$1 not found (expected ${NODE_ROOT}/bin/$1)"
  fi
}

harbor_crane() {
  DOCKER_CONFIG="${HARBOR_TMP}/docker" "${HARBOR_CRANE}" "$@"
}

harbor_helm() {
  # shellcheck disable=SC2086  # HARBOR_HELM_OPTS: extra flags (tests: --plain-http)
  HELM_REGISTRY_CONFIG="${HARBOR_TMP}/helm/registry.json" HELM_CONFIG_HOME="${HARBOR_TMP}/helm/config" \
    HELM_CACHE_HOME="${HARBOR_TMP}/helm/cache" HELM_DATA_HOME="${HARBOR_TMP}/helm/data" \
    HELM_REPOSITORY_CONFIG="${HARBOR_TMP}/helm/repositories.yaml" HELM_REPOSITORY_CACHE="${HARBOR_TMP}/helm/cache/repository" \
    DOCKER_CONFIG="${HARBOR_TMP}/docker" "${HARBOR_HELM}" "$@" ${HARBOR_HELM_OPTS:-}
}

harbor_curl_cfg() {
  # curl config carrying the admin credential; only ever read through a pipe
  local pw="${HARBOR_PW//\\/\\\\}"
  pw="${pw//\"/\\\"}"
  printf 'user = "admin:%s"\n' "${pw}"
}

harbor_req() {
  # harbor_req <method> <api-path> [json-body] — prints the HTTP status; the
  # response body is in ${HARBOR_TMP}/body. Non-zero when curl itself fails.
  local method="$1" path="$2" body="${3-}" code
  local -a args=(-sS -o "${HARBOR_TMP}/body" -w '%{http_code}' -X "${method}" -H 'Accept: application/json')
  [[ -z "${body}" ]] || args+=(-H 'Content-Type: application/json' --data-binary "${body}")
  : > "${HARBOR_TMP}/body"
  # shellcheck disable=SC2086  # HARBOR_CURL_OPTS: extra curl flags (e.g. --cacert FILE)
  code="$(curl "${args[@]}" ${HARBOR_CURL_OPTS:-} -K <(harbor_curl_cfg) "${HARBOR_API}${path}")" || return 1
  printf '%s' "${code}"
}

harbor_api() {
  # harbor_api <expected-status...> -- <method> <path> [body] — dies unless the
  # status is one of the expected ones; prints the status
  local -a ok=()
  local code
  while [[ "$1" != "--" ]]; do ok+=("$1"); shift; done
  shift
  code="$(harbor_req "$@")" || die "Harbor API $1 $2: request failed"
  [[ " ${ok[*]} " == *" ${code} "* ]] || die "Harbor API $1 $2: HTTP ${code}: $(head -c 300 "${HARBOR_TMP}/body")"
  printf '%s' "${code}"
}

harbor_healthy() {
  local code
  code="$(harbor_req GET /health 2>/dev/null)" || return 1
  [[ "${code}" == "200" ]] || return 1
  "${HARBOR_JQ}" -e '.status == "healthy"
      or ([.components[]? | select(.name == "core" or .name == "registry" or .name == "database") | .status == "healthy"]
          | length > 0 and all)' "${HARBOR_TMP}/body" >/dev/null 2>&1
}

harbor_push_retry() {
  # harbor_push_retry <description> <landed-check> [args...] -- <push command...>
  # Harbor answers 502/503 for a while when its pods settle, e.g. after the
  # k3s restart of the pre-change backup. A failed push is retried once Harbor
  # reports healthy again, HARBOR_PUSH_ATTEMPTS times in all; before each retry
  # <landed-check> [args] says whether the failed attempt landed after all
  # (project teknoir's tags are immutable: that push must not be repeated).
  # The last attempt's stderr is left in ${HARBOR_TMP}/err.
  local desc="$1" n=1 delay="${HARBOR_RETRY_DELAY}"
  local -a check=()
  shift
  while [[ $# -gt 0 && "$1" != "--" ]]; do check+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] || die "harbor_push_retry: missing -- before the push command"
  shift
  until "$@" >/dev/null 2> "${HARBOR_TMP}/err.push"; do
    if (( n >= HARBOR_PUSH_ATTEMPTS )); then
      cp "${HARBOR_TMP}/err.push" "${HARBOR_TMP}/err"
      return 1
    fi
    warn "${desc}: attempt ${n} of ${HARBOR_PUSH_ATTEMPTS} failed ($(tail -1 "${HARBOR_TMP}/err.push" | cut -c1-200)); retrying once Harbor is healthy"
    sleep "${delay}"
    wait_for "the Harbor API at ${HARBOR_API}" "${HARBOR_HEALTH_TIMEOUT}" harbor_healthy
    if "${check[@]}"; then
      log "${desc}: the failed attempt landed after all"
      return 0
    fi
    n=$((n + 1))
    delay=$((delay * 2))
  done
}

harbor_chart_landed() {
  # harbor_chart_landed <ref> <tgz> — the chart is in Harbor with this content
  local d
  harbor_remote_manifest "$1" || return 1
  d="$("${HARBOR_JQ}" -r --arg mt "${HARBOR_CHART_MEDIA_TYPE}" '[.layers[]? | select(.mediaType == $mt) | .digest][0] // empty' <<<"${HARBOR_REMOTE}")"
  [[ "${d}" == "sha256:$(sha256_file "$2")" ]]
}

harbor_image_landed() {
  # harbor_image_landed <target> <config-digest|""> — the image is in Harbor
  if [[ -n "$2" ]]; then
    harbor_remote_config_digest "$1"
    [[ "${HARBOR_REMOTE_CFG}" == "$2" ]]
  else
    harbor_remote_manifest "$1"
  fi
}

harbor_login() {
  # crane (reads and image pushes) logs in to the temp DOCKER_CONFIG; it does
  # not contact the registry. helm logs in only when a chart is pushed.
  printf '%s' "${HARBOR_PW}" | harbor_crane auth login "${HARBOR_REGISTRY}" -u admin --password-stdin >/dev/null 2>&1 \
    || die "crane auth login ${HARBOR_REGISTRY} failed"
}

harbor_helm_login() {
  [[ "${HARBOR_LOGGED_IN}" == "1" ]] && return 0
  printf '%s' "${HARBOR_PW}" | harbor_helm registry login "${HARBOR_REGISTRY}" --username admin --password-stdin >/dev/null \
    || die "helm registry login ${HARBOR_REGISTRY} failed"
  HARBOR_LOGGED_IN=1
}

# --- projects, immutability, robot -------------------------------------------

harbor_mirror_projects() {
  local e
  for e in ${HARBOR_MIRRORS}; do echo "${e#*=}"; done
}

harbor_project() {
  # harbor_project <name> — HARBOR_PROJECT: its JSON (exact name), empty if absent
  harbor_api 200 -- GET "/projects?name=$1&page_size=100" >/dev/null
  HARBOR_PROJECT="$("${HARBOR_JQ}" -c --arg n "$1" '[.[]? | select(.name == $n)][0] // empty' "${HARBOR_TMP}/body")" \
    || die "cannot parse the Harbor project list"
}

harbor_ensure_project() {
  local name="$1" id public
  harbor_project "${name}"
  if [[ -z "${HARBOR_PROJECT}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "[dry-run] would create Harbor project ${name} (public)"
      return 0
    fi
    harbor_api 201 409 -- POST /projects "{\"project_name\":\"${name}\",\"metadata\":{\"public\":\"true\"}}" >/dev/null
    changed "Harbor project ${name} created (public)"
    return 0
  fi
  public="$("${HARBOR_JQ}" -r '.metadata.public // "false"' <<<"${HARBOR_PROJECT}")"
  [[ "${public}" != "true" ]] || return 0
  id="$("${HARBOR_JQ}" -r '.project_id' <<<"${HARBOR_PROJECT}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would make Harbor project ${name} public (D3)"
    return 0
  fi
  harbor_api 200 -- PUT "/projects/${id}" '{"metadata":{"public":"true"}}' >/dev/null
  changed "Harbor project ${name} made public (D3)"
}

harbor_ensure_immutability() {
  # one rule on the project: all repositories, all tags immutable
  local name="$1" id state
  harbor_project "${name}"
  if [[ -z "${HARBOR_PROJECT}" ]]; then
    [[ "${DRY_RUN}" == "1" ]] || die "Harbor project ${name} not found"
    log "[dry-run] would add the tag-immutability rule (all repositories, all tags) to ${name}"
    return 0
  fi
  id="$("${HARBOR_JQ}" -r '.project_id' <<<"${HARBOR_PROJECT}")"
  harbor_api 200 -- GET "/projects/${id}/immutabletagrules" >/dev/null
  state="$("${HARBOR_JQ}" -r '
      [.[]? | select(any(.tag_selectors[]?; .decoration == "matches" and .pattern == "**")
                     and any(.scope_selectors.repository[]?; .decoration == "repoMatches" and .pattern == "**"))
            | if .disabled then "disabled" else "enabled" end]
      | if index("enabled") then "enabled" elif index("disabled") then "disabled" else "absent" end' "${HARBOR_TMP}/body")" \
    || die "cannot parse the immutability rules of ${name}"
  case "${state}" in
    enabled) ;;
    disabled) warn "the tag-immutability rule on Harbor project ${name} is DISABLED; left as is (re-enable it under Projects > ${name} > Policy)" ;;
    *)
      if [[ "${DRY_RUN}" == "1" ]]; then
        log "[dry-run] would add the tag-immutability rule (all repositories, all tags) to ${name}"
        return 0
      fi
      harbor_api 201 -- POST "/projects/${id}/immutabletagrules" \
        '{"disabled":false,"action":"immutable","template":"immutable_template","tag_selectors":[{"kind":"doublestar","decoration":"matches","pattern":"**"}],"scope_selectors":{"repository":[{"kind":"doublestar","decoration":"repoMatches","pattern":"**"}]}}' >/dev/null
      changed "tag-immutability rule on Harbor project ${name}"
      ;;
  esac
}

harbor_robot_refs() {
  # ArgoCD Secrets that still log in as robot$argocd (names only leave jq)
  local all
  all="$(kc get secrets -A -l argocd.argoproj.io/secret-type -o json)" || return 1
  "${HARBOR_JQ}" -r '[.items[] | select(((.data.username // "") | @base64d) == "robot$argocd")
                     | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")' <<<"${all}"
}

harbor_retire_robot() {
  # Delete robot$argocd (D3) once no ArgoCD Secret uses it. Usable outside the
  # phase (teknoir-node migrate): it opens its own session then.
  local own=0 id refs
  if [[ -z "${HARBOR_TMP}" ]]; then
    if harbor_absent_in_dry_run; then
      log "[dry-run] robot: Harbor is not installed (no Secret ${HARBOR_SECRET_NS}/${HARBOR_SECRET_NAME}); nothing to retire"
      return 0
    fi
    harbor_session_begin
    own=1
  fi
  harbor_api 200 -- GET '/robots?q=name%3Dargocd&page_size=100' >/dev/null
  id="$("${HARBOR_JQ}" -r '[.[]? | select(.name == "robot$argocd")][0].id // empty' "${HARBOR_TMP}/body")" \
    || die "cannot parse the Harbor robot list"
  if [[ -n "${id}" ]]; then
    refs="$(harbor_robot_refs)" || die "cannot list the ArgoCD repository Secrets"
    if [[ -n "${refs}" ]]; then
      log "robot\$argocd kept: ArgoCD still logs in with it (${refs}); teknoir-node migrate retires that Secret once ArgoCD reads the public project"
    elif [[ "${DRY_RUN}" == "1" ]]; then
      log "[dry-run] would delete the Harbor robot account robot\$argocd (unused, D3)"
    else
      harbor_api 200 -- DELETE "/robots/${id}" >/dev/null
      changed "deleted the Harbor robot account robot\$argocd (D3)"
    fi
  fi
  [[ "${own}" == "0" ]] || harbor_session_end
}

# --- registry reads -------------------------------------------------------------

harbor_absent_error() {
  # crane's error text for a tag or repository that does not exist
  grep -qE 'MANIFEST_UNKNOWN|NAME_UNKNOWN|NOT_FOUND|status code 404|404 Not Found' "${HARBOR_TMP}/err"
}

harbor_transient_error() {
  # the last crane/helm error (${HARBOR_TMP}/err) is Harbor or the gateway
  # not answering for a moment: 5xx, "no healthy upstream", a dropped connection
  grep -qiE 'status code 5[0-9][0-9]|: 5[0-9][0-9] |no healthy upstream|connection refused|connection reset|unexpected EOF|i/o timeout|TLS handshake timeout' \
    "${HARBOR_TMP}/err" 2>/dev/null
}

harbor_read_retry() {
  # harbor_read_retry <n> <what> — after a transient read error: wait for
  # Harbor and say whether to try again (attempt <n> of HARBOR_PUSH_ATTEMPTS)
  harbor_transient_error || return 1
  (( $1 < HARBOR_PUSH_ATTEMPTS )) || return 1
  warn "reading $2 from Harbor: attempt $1 of ${HARBOR_PUSH_ATTEMPTS} failed ($(tail -1 "${HARBOR_TMP}/err" | cut -c1-200)); retrying once Harbor is healthy"
  sleep "$(( HARBOR_RETRY_DELAY * $1 ))"
  wait_for "the Harbor API at ${HARBOR_API}" "${HARBOR_HEALTH_TIMEOUT}" harbor_healthy
}

harbor_remote_manifest() {
  # harbor_remote_manifest <ref> — 0 and HARBOR_REMOTE=<manifest json> when
  # present, 1 when absent; transient errors are retried; dies on any other
  local n=1
  HARBOR_REMOTE=""
  until harbor_crane manifest "$1" > "${HARBOR_TMP}/out" 2> "${HARBOR_TMP}/err"; do
    harbor_absent_error && return 1
    harbor_read_retry "${n}" "$1" || die "cannot read $1 from Harbor: $(tail -1 "${HARBOR_TMP}/err")"
    n=$((n + 1))
  done
  HARBOR_REMOTE="$(cat "${HARBOR_TMP}/out")"
}

harbor_remote_config_digest() {
  # harbor_remote_config_digest <ref> — HARBOR_REMOTE_CFG: sha256 of the image
  # config for HARBOR_PLATFORM ("" when the tag is absent, "other-platforms"
  # when the tag holds no image for that platform); dies on other errors
  local n=1
  HARBOR_REMOTE_CFG=""
  until harbor_crane config --platform "${HARBOR_PLATFORM}" "$1" > "${HARBOR_TMP}/out" 2> "${HARBOR_TMP}/err"; do
    harbor_absent_error && return 0
    if grep -q 'no child with platform' "${HARBOR_TMP}/err"; then
      HARBOR_REMOTE_CFG="other-platforms"
      return 0
    fi
    harbor_read_retry "${n}" "$1" || die "cannot read $1 from Harbor: $(tail -1 "${HARBOR_TMP}/err")"
    n=$((n + 1))
  done
  HARBOR_REMOTE_CFG="sha256:$(sha256_file "${HARBOR_TMP}/out")"
}

# --- charts -----------------------------------------------------------------------

harbor_chart_tree() {
  # harbor_chart_tree <tgz> — "sha256  path" of every file in the chart archive
  # but Chart.lock: dependency-resolution metadata that rendering never reads,
  # with a build timestamp (generated:) and present or not depending on how the
  # chart was packed (the pre-redesign bundles shipped monitoring 0.0.4 with
  # different Chart.lock files and nothing else different)
  local d
  d="$(mktemp -d "${HARBOR_TMP}/tree.XXXXXX")" || return 1
  tar -xzf "$1" -C "${d}" || { rm -rf "${d}"; return 1; }
  (cd "${d}" && find . -type f ! -name Chart.lock -print0 | sort -z | xargs -0 -r sha256sum)
  rm -rf "${d}"
}

harbor_push_charts() {
  local pins="${NODE_ROOT}/charts/pins.txt" name version tgz ref repo local_d remote_d a b line n=0
  local -a push=() refused=()
  [[ -f "${pins}" ]] || die "missing ${pins}"
  while read -r name version _; do
    [[ -n "${name}" && "${name}" != \#* ]] || continue
    tgz="${NODE_ROOT}/charts/${name}-${version}.tgz"
    [[ -f "${tgz}" ]] || die "chart ${name} ${version} is pinned in pins.txt but ${tgz} is missing"
    repo="${HARBOR_REGISTRY}/${HARBOR_CHART_PROJECT}/${name}"
    ref="${repo}:${version}"
    if ! harbor_remote_manifest "${ref}"; then
      push+=("${tgz}|${name}|${version}")
      continue
    fi
    local_d="sha256:$(sha256_file "${tgz}")"
    remote_d="$("${HARBOR_JQ}" -r --arg mt "${HARBOR_CHART_MEDIA_TYPE}" '[.layers[]? | select(.mediaType == $mt) | .digest][0] // empty' <<<"${HARBOR_REMOTE}")"
    if [[ "${remote_d}" == "${local_d}" ]]; then
      continue
    fi
    if [[ -n "${remote_d}" ]]; then
      harbor_crane blob "${repo}@${remote_d}" > "${HARBOR_TMP}/remote.tgz" 2> "${HARBOR_TMP}/err" \
        || die "cannot read ${ref} from Harbor: $(tail -1 "${HARBOR_TMP}/err")"
      a="$(harbor_chart_tree "${tgz}")" || die "cannot unpack ${tgz}"
      b="$(harbor_chart_tree "${HARBOR_TMP}/remote.tgz")" || die "cannot unpack Harbor's ${ref}"
      if [[ -n "${a}" && "${a}" == "${b}" ]]; then
        log "chart ${name} ${version}: Harbor's copy has the same files (packed differently); kept"
        continue
      fi
    fi
    refused+=("${name} ${version}")
  done < "${pins}"
  if [[ ${#refused[@]} -gt 0 ]]; then
    die "Harbor already holds a DIFFERENT chart under: $(printf '%s, ' "${refused[@]}" | sed 's/, $//'). A released chart version is immutable: bump the chart version in the gitops repo and rebuild the bundle"
  fi
  for line in ${push[@]+"${push[@]}"}; do
    IFS='|' read -r tgz name version <<<"${line}"
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "[dry-run] would push chart ${name} ${version} to oci://${HARBOR_REGISTRY}/${HARBOR_CHART_PROJECT}"
      continue
    fi
    harbor_helm_login
    harbor_push_retry "helm push ${name} ${version}" \
        harbor_chart_landed "${HARBOR_REGISTRY}/${HARBOR_CHART_PROJECT}/${name}:${version}" "${tgz}" -- \
        harbor_helm push "${tgz}" "oci://${HARBOR_REGISTRY}/${HARBOR_CHART_PROJECT}" \
      || die "helm push ${name} ${version} failed: $(tail -1 "${HARBOR_TMP}/err")"
    harbor_remote_manifest "${HARBOR_REGISTRY}/${HARBOR_CHART_PROJECT}/${name}:${version}" \
      || die "chart ${name} ${version} is not in Harbor after the push"
    remote_d="$("${HARBOR_JQ}" -r --arg mt "${HARBOR_CHART_MEDIA_TYPE}" '[.layers[]? | select(.mediaType == $mt) | .digest][0] // empty' <<<"${HARBOR_REMOTE}")"
    [[ "${remote_d}" == "sha256:$(sha256_file "${tgz}")" ]] || die "chart ${name} ${version}: Harbor holds a different digest after the push"
    changed "pushed chart ${name} ${version}"
    n=$((n + 1))
  done
  log "charts: $(grep -cvE '^[[:space:]]*(#|$)' "${pins}") pinned, ${#push[@]} to push$([[ "${DRY_RUN}" == "1" ]] || echo ", ${n} pushed")"
}

# --- images -------------------------------------------------------------------------

harbor_normalize_ref() {
  # docker.io[/library] for short names, as containerd resolves them
  local ref="$1" first rest
  [[ "${ref}" != index.docker.io/* ]] || ref="docker.io/${ref#index.docker.io/}"
  first="${ref%%/*}"
  if [[ "${ref}" != */* ]]; then
    ref="docker.io/library/${ref}"
  elif [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
    ref="docker.io/${ref}"
  fi
  if [[ "${ref}" == docker.io/* ]]; then
    rest="${ref#docker.io/}"
    [[ "${rest}" == */* ]] || ref="docker.io/library/${rest}"
  fi
  printf '%s\n' "${ref}"
}

harbor_mirror_ref() {
  # harbor_mirror_ref <ref> — the mirror location in Harbor; 1 when no project mirrors its registry
  local e
  for e in ${HARBOR_MIRRORS}; do
    if [[ "$1" == "${e%%=*}/"* ]]; then
      printf '%s/%s/%s\n' "${HARBOR_REGISTRY}" "${e#*=}" "${1#"${e%%=*}"/}"
      return 0
    fi
  done
  return 1
}

harbor_local_config_digest() {
  # harbor_local_config_digest <oci-layout-dir|docker-archive.tar> — HARBOR_LOCAL_CFG
  # (sha256 of the image config) and HARBOR_LOCAL_MANIFEST (the layout's manifest digest)
  local src="$1" n mt mdig cfg
  HARBOR_LOCAL_CFG=""
  HARBOR_LOCAL_MANIFEST=""
  if [[ -d "${src}" ]]; then
    n="$("${HARBOR_JQ}" '.manifests | length' "${src}/index.json")" || die "cannot read ${src}/index.json"
    [[ "${n}" == "1" ]] || die "${src}: expected exactly one image in the layout, found ${n}"
    mt="$("${HARBOR_JQ}" -r '.manifests[0].mediaType // ""' "${src}/index.json")"
    case "${mt}" in
      *index*|*manifest.list*) die "${src}: a multi-platform index; the bundle must hold one ${HARBOR_PLATFORM} image" ;;
    esac
    mdig="$("${HARBOR_JQ}" -r '.manifests[0].digest' "${src}/index.json")"
    [[ -f "${src}/blobs/${mdig/://}" ]] || die "${src}: manifest blob ${mdig} missing"
    cfg="$("${HARBOR_JQ}" -r '.config.digest' "${src}/blobs/${mdig/://}")" || die "${src}: unreadable manifest"
    HARBOR_LOCAL_MANIFEST="${mdig}"
    HARBOR_LOCAL_CFG="${cfg}"
  else
    cfg="$(tar -xOf "${src}" manifest.json | "${HARBOR_JQ}" -r 'if length == 1 then .[0].Config else error("expected one image") end')" \
      || die "${src}: not a single-image docker archive"
    tar -xOf "${src}" "${cfg}" > "${HARBOR_TMP}/cfg" || die "${src}: config ${cfg} missing"
    HARBOR_LOCAL_CFG="sha256:$(sha256_file "${HARBOR_TMP}/cfg")"
  fi
}

harbor_image_sources() {
  # HARBOR_SOURCES: "<src>|<upstream ref>" per image: images.lock entries
  # (OCI layouts, or a bootstrap archive with the same slug), then every
  # bootstrap archive by its RepoTags
  local lock="${NODE_ROOT}/images/images.lock" tok slug ref src t tags lines="" seen=" "
  if [[ -f "${lock}" ]]; then
    while read -r tok slug _; do
      [[ -n "${tok}" && "${tok}" != \#* ]] || continue
      [[ -n "${slug}" ]] || die "${lock}: no slug for ${tok}"
      ref="${tok%@sha256:*}"
      if [[ -f "${NODE_ROOT}/images/${slug}/index.json" ]]; then
        src="${NODE_ROOT}/images/${slug}"
      elif [[ -f "${NODE_ROOT}/bootstrap-images/${slug}.tar" ]]; then
        src="${NODE_ROOT}/bootstrap-images/${slug}.tar"
      else
        die "${lock}: ${ref} has no layout images/${slug}/ and no bootstrap-images/${slug}.tar"
      fi
      ref="$(harbor_normalize_ref "${ref}")"
      [[ "${seen}" != *" ${ref} "* ]] || continue
      seen+="${ref} "
      lines+="${src}|${ref}"$'\n'
    done < "${lock}"
  elif [[ -d "${NODE_ROOT}/images" ]]; then
    die "missing ${lock}"
  fi
  for t in "${NODE_ROOT}"/bootstrap-images/*.tar; do
    [[ -f "${t}" ]] || continue
    tags="$(tar -xOf "${t}" manifest.json | "${HARBOR_JQ}" -r '.[0].RepoTags[]?')" || die "${t}: not a docker archive"
    [[ -n "${tags}" ]] || die "${t}: no RepoTags, cannot tell where to push it"
    while read -r ref; do
      [[ -n "${ref}" ]] || continue
      ref="$(harbor_normalize_ref "${ref}")"
      [[ "${seen}" != *" ${ref} "* ]] || continue
      seen+="${ref} "
      lines+="${t}|${ref}"$'\n'
    done <<<"${tags}"
  done
  HARBOR_SOURCES="$(sed '/^$/d' <<<"${lines}")"
}

harbor_push_images() {
  local force="$1" src ref target pin line cfg present=0 pushed=0
  local -a todo=() refused=()
  harbor_image_sources
  while IFS='|' read -r src ref; do
    [[ -n "${src}" ]] || continue
    pin=""
    if [[ "${ref}" == *@sha256:* ]]; then
      pin="${ref##*@}"
      ref="${ref%@*}"
    fi
    target="$(harbor_mirror_ref "${ref}")" || die "no Harbor mirror project for ${ref} (HARBOR_MIRRORS: ${HARBOR_MIRRORS})"
    harbor_local_config_digest "${src}"
    if [[ "${ref##*/}" != *:* ]]; then
      # digest-only reference: its manifest can only be pushed by digest
      [[ -n "${HARBOR_LOCAL_MANIFEST}" ]] || die "${ref}: an untagged reference needs an OCI layout, not ${src}"
      [[ -z "${pin}" || "${pin}" == "${HARBOR_LOCAL_MANIFEST}" ]] \
        || warn "${ref}@${pin}: the bundle holds manifest ${HARBOR_LOCAL_MANIFEST}; pods that pin ${pin} will not resolve through the mirror"
      target="${target}@${HARBOR_LOCAL_MANIFEST}"
      if harbor_remote_manifest "${target}"; then present=$((present + 1)); else todo+=("${src}|${target}|${ref}|"); fi
      continue
    fi
    [[ -z "${pin}" ]] || warn "${ref}@${pin}: pushed by tag; a pod that pins ${pin} needs that exact manifest in the mirror"
    harbor_remote_config_digest "${target}"
    if [[ -z "${HARBOR_REMOTE_CFG}" ]]; then
      todo+=("${src}|${target}|${ref}|${HARBOR_LOCAL_CFG}")
    elif [[ "${HARBOR_REMOTE_CFG}" == "${HARBOR_LOCAL_CFG}" ]]; then
      present=$((present + 1))
    elif [[ "${force}" == "1" ]]; then
      warn "--force-images: ${target} points at another image (${HARBOR_REMOTE_CFG}); replacing it with the bundle's (${HARBOR_LOCAL_CFG})"
      todo+=("${src}|${target}|${ref}|${HARBOR_LOCAL_CFG}")
    else
      refused+=("${target}")
    fi
  done <<<"${HARBOR_SOURCES}"
  if [[ ${#refused[@]} -gt 0 ]]; then
    die "Harbor mirror tag(s) already point at a different image: $(printf '%s ' "${refused[@]}")— a mutable upstream tag moved since the last bundle. Re-run with --force-images to move them to the bundle's images"
  fi
  for line in ${todo[@]+"${todo[@]}"}; do
    IFS='|' read -r src target ref cfg <<<"${line}"
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "[dry-run] would push ${ref} -> ${target}"
      continue
    fi
    harbor_push_retry "crane push ${ref}" harbor_image_landed "${target}" "${cfg}" -- \
        harbor_crane push "${src}" "${target}" \
      || die "crane push ${ref} -> ${target} failed: $(tail -1 "${HARBOR_TMP}/err")"
    if [[ -n "${cfg}" ]]; then
      harbor_remote_config_digest "${target}"
      [[ "${HARBOR_REMOTE_CFG}" == "${cfg}" ]] || die "${target}: Harbor holds a different image after the push"
    else
      harbor_remote_manifest "${target}" || die "${target}: not in Harbor after the push"
    fi
    changed "pushed image ${ref} -> ${target}"
    pushed=$((pushed + 1))
  done
  log "images: $(grep -c . <<<"${HARBOR_SOURCES}") in the bundle, ${present} already in Harbor, ${#todo[@]} to push$([[ "${DRY_RUN}" == "1" ]] || echo ", ${pushed} pushed")"
}
