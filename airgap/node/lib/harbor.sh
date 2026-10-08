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
# in a 0700 mktemp directory that an EXIT trap removes; the operator's
# ~/.docker and ~/.config/helm are never touched. Nothing prints a credential.

HARBOR_CHART_PROJECT="teknoir"
HARBOR_MIRRORS="${HARBOR_MIRRORS:-docker.io=dockerhub ghcr.io=ghcr gcr.io=gcr quay.io=quay registry.k8s.io=k8s}"
HARBOR_PLATFORM="${HARBOR_PLATFORM:-linux/amd64}"
HARBOR_HEALTH_TIMEOUT="${HARBOR_HEALTH_TIMEOUT:-900}"
HARBOR_SECRET_NS="${HARBOR_SECRET_NS:-teknoir-system}"
HARBOR_SECRET_NAME="${HARBOR_SECRET_NAME:-harbor-secret}"
HARBOR_CHART_MEDIA_TYPE="application/vnd.cncf.helm.chart.content.v1.tar+gzip"
HARBOR_TMP=""
HARBOR_PW=""
HARBOR_PREV_EXIT=""

phase_harbor() {
  local force="${HARBOR_FORCE_IMAGES:-0}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force-images) force=1; shift ;;
      *) die "phase_harbor: unknown argument: $1" ;;
    esac
  done
  harbor_session_begin
  wait_for "the Harbor API at ${HARBOR_API}" "${HARBOR_HEALTH_TIMEOUT}" harbor_healthy
  if [[ "${DRY_RUN}" == "1" ]] && ! harbor_healthy; then
    log "[dry-run] Harbor is not reachable yet: would create the projects and push every chart and image"
    harbor_session_end
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

harbor_session_begin() {
  [[ -z "${HARBOR_TMP}" ]] || return 0
  HARBOR_HOST="${HARBOR_HOST:-harbor.${TEKNOIR_DOMAIN}}"
  HARBOR_API="${HARBOR_API:-https://${HARBOR_HOST}/api/v2.0}"
  HARBOR_REGISTRY="${HARBOR_REGISTRY:-${HARBOR_HOST}}"
  HARBOR_CRANE="$(harbor_tool crane)" || exit 1
  HARBOR_HELM="$(harbor_tool helm)" || exit 1
  HARBOR_JQ="$(harbor_tool jq)" || exit 1
  HARBOR_PW="$(secret_value "${HARBOR_SECRET_NS}" "${HARBOR_SECRET_NAME}" HARBOR_ADMIN_PASSWORD)" \
    || die "cannot read the Harbor admin password from Secret ${HARBOR_SECRET_NS}/${HARBOR_SECRET_NAME}"
  [[ -n "${HARBOR_PW}" ]] || die "Secret ${HARBOR_SECRET_NS}/${HARBOR_SECRET_NAME} has an empty HARBOR_ADMIN_PASSWORD"
  [[ "${HARBOR_PW}" != *$'\n'* ]] || die "the Harbor admin password contains a newline"
  harbor_trap_install
  HARBOR_TMP="$(mktemp -d)" || die "mktemp failed"
  chmod 0700 "${HARBOR_TMP}"
  mkdir -p "${HARBOR_TMP}/docker" "${HARBOR_TMP}/helm/config" "${HARBOR_TMP}/helm/cache" "${HARBOR_TMP}/helm/data"
  HARBOR_LOGGED_IN=0
}

harbor_session_end() {
  harbor_session_cleanup
  if [[ -n "${HARBOR_PREV_EXIT}" ]]; then
    # shellcheck disable=SC2064  # restore the runner's own EXIT trap verbatim
    trap -- "${HARBOR_PREV_EXIT}" EXIT
  else
    trap - EXIT
  fi
  HARBOR_PREV_EXIT=""
}

harbor_session_cleanup() {
  if [[ -n "${HARBOR_TMP}" ]]; then
    rm -rf -- "${HARBOR_TMP}"
  fi
  HARBOR_TMP=""
  HARBOR_PW=""
}

harbor_trap_install() {
  # chain onto the runner's EXIT trap (lock, log) instead of replacing it
  local t
  local -a parts=()
  HARBOR_PREV_EXIT=""
  t="$(trap -p EXIT)"
  if [[ -n "${t}" ]]; then
    # "trap -- '<command>' EXIT", quoted by bash for re-use
    eval "parts=(${t})"
    HARBOR_PREV_EXIT="${parts[2]:-}"
  fi
  # shellcheck disable=SC2064  # expand the previous command now
  trap "harbor_session_cleanup${HARBOR_PREV_EXIT:+; ${HARBOR_PREV_EXIT}}" EXIT
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

harbor_remote_manifest() {
  # harbor_remote_manifest <ref> — 0 and HARBOR_REMOTE=<manifest json> when
  # present, 1 when absent; dies on any other error
  HARBOR_REMOTE=""
  if harbor_crane manifest "$1" > "${HARBOR_TMP}/out" 2> "${HARBOR_TMP}/err"; then
    HARBOR_REMOTE="$(cat "${HARBOR_TMP}/out")"
    return 0
  fi
  harbor_absent_error && return 1
  die "cannot read $1 from Harbor: $(tail -1 "${HARBOR_TMP}/err")"
}

harbor_remote_config_digest() {
  # harbor_remote_config_digest <ref> — HARBOR_REMOTE_CFG: sha256 of the image
  # config for HARBOR_PLATFORM ("" when the tag is absent, "other-platforms"
  # when the tag holds no image for that platform); dies on other errors
  HARBOR_REMOTE_CFG=""
  if harbor_crane config --platform "${HARBOR_PLATFORM}" "$1" > "${HARBOR_TMP}/out" 2> "${HARBOR_TMP}/err"; then
    HARBOR_REMOTE_CFG="sha256:$(sha256_file "${HARBOR_TMP}/out")"
    return 0
  fi
  harbor_absent_error && return 0
  if grep -q 'no child with platform' "${HARBOR_TMP}/err"; then
    HARBOR_REMOTE_CFG="other-platforms"
    return 0
  fi
  die "cannot read $1 from Harbor: $(tail -1 "${HARBOR_TMP}/err")"
}

# --- charts -----------------------------------------------------------------------

harbor_chart_tree() {
  # harbor_chart_tree <tgz> — "sha256  path" of every file in the chart archive
  local d
  d="$(mktemp -d "${HARBOR_TMP}/tree.XXXXXX")" || return 1
  tar -xzf "$1" -C "${d}" || { rm -rf "${d}"; return 1; }
  (cd "${d}" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum)
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
    harbor_helm push "${tgz}" "oci://${HARBOR_REGISTRY}/${HARBOR_CHART_PROJECT}" >/dev/null 2> "${HARBOR_TMP}/err" \
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
    harbor_crane push "${src}" "${target}" >/dev/null 2> "${HARBOR_TMP}/err" \
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
