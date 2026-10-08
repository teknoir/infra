# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016  # NODE_ROOT, DRY_RUN, K3S_DATA_DIR come from common.sh and the site env; jq programs are single-quoted on purpose
#
# lib/oneshot.sh — converge phase "oneshot" (docs/airgap/DESIGN.md I-08).
#
# For every tier in node/oneshot/TIERS, in order (platform-secrets istio harbor
# argo): while the ArgoCD Application teknoir-system/<tier> does not exist,
# server-side apply the bundle's override-free render of that tier as field
# manager argocd-controller, CRDs first (waiting until they are Established),
# and wait for its workloads and Jobs. Once the Application exists, ArgoCD owns
# the tier and this phase leaves it alone; `--reapply <tier>` is the
# break-glass that applies it anyway.
#
#   phase_oneshot [--reapply TIER]...      (or ONESHOT_REAPPLY="tier ...")
#
# Dry-run (DRY_RUN=1) only reads; when the cluster is not reachable yet (a
# fresh node before the host phase installs k3s) it lists the tiers it would
# apply.
#
# Inputs (node/ payload): oneshot/TIERS (tier names in order, one per line; an
# optional second column names the namespace for objects without one, default
# istio-system for istio, teknoir-system otherwise), oneshot/<tier>-crds.yaml
# (optional) and oneshot/<tier>.yaml.
#
# What is applied mirrors what ArgoCD applies from the same render:
#   - objects without metadata.namespace get the tier namespace when their
#     kind is namespaced (ArgoCD's destination namespace);
#   - ArgoCD hooks run here only if they are PreSync/Sync hooks (Helm
#     pre-install/pre-upgrade count as PreSync): the platform-secrets Job runs,
#     PostSync jobs (e.g. Harbor's OIDC config, which needs Keycloak) are left
#     for ArgoCD;
#   - a tier whose render equals the live objects (kubectl diff --server-side)
#     is not re-applied, so a re-run reports no change.
# A tier still owned by a K3s auto-deploy file (teknoir-<tier>.yaml or
# 10-teknoir-<tier>.yaml without its .skip, e.g. teknoir-argo before DESIGN M7)
# is never applied: K3s would revert it on its next restart.

ONESHOT_MANAGER="argocd-controller"
ONESHOT_APP_NS="${ONESHOT_APP_NS:-teknoir-system}"
ONESHOT_TIMEOUT="${ONESHOT_TIMEOUT:-900}"
ONESHOT_REAPPLY="${ONESHOT_REAPPLY:-}"

# jq: split a tier's objects. Input: array of objects. Output: {crds, rest,
# hooks_skipped}. Hook phases follow ArgoCD's mapping of Helm hooks.
ONESHOT_JQ_SPLIT='
def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
def phases:
  (.metadata.annotations // {}) as $a
  | if ($a["argocd.argoproj.io/hook"] // "") != "" then ($a["argocd.argoproj.io/hook"] | split(",") | map(trim))
    elif ($a["helm.sh/hook"] // "") != "" then ($a["helm.sh/hook"] | split(",") | map(trim)
      | map(if . == "pre-install" or . == "pre-upgrade" then "PreSync"
            elif . == "post-install" or . == "post-upgrade" then "PostSync"
            else "helm:" + . end))
    else [] end;
def id: "\(.kind) \(.metadata.namespace // "-")/\(.metadata.name)";
{
  crds: map(select(.kind == "CustomResourceDefinition" and ((.apiVersion // "") | startswith("apiextensions.k8s.io/")))),
  rest: map(select(.kind != "CustomResourceDefinition")
            | select((phases | length) == 0 or any(phases[]; . == "PreSync" or . == "Sync"))),
  hooks_skipped: map(select(.kind != "CustomResourceDefinition")
            | select((phases | length) > 0 and (any(phases[]; . == "PreSync" or . == "Sync") | not))
            | id + " (" + (phases | join(",")) + ")")
}'

# jq: default the namespace like ArgoCD does. Input: array of objects;
# $scope: {"group/Kind": true (namespaced) | false (cluster)}; $ns: tier ns.
ONESHOT_JQ_NAMESPACE='
def key: ((.apiVersion // "") | if test("/") then split("/")[0] else "" end) + "/" + .kind;
{
  apply: map(if (.metadata.namespace // "") == "" and $scope[key] == true
             then .metadata.namespace = $ns else . end),
  defaulted: map(select((.metadata.namespace // "") == "" and $scope[key] == true) | "\(.kind) \(.metadata.name)"),
  unknown: map(select($scope[key] == null) | "\(.apiVersion) \(.kind) \(.metadata.name)")
} | .apply |= map(select($scope[key] != null))'

phase_oneshot() {
  local reapply="${ONESHOT_REAPPLY}" tiers_file line tier ns t force
  local -a lines=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reapply) [[ $# -ge 2 ]] || die "--reapply needs a tier name"; reapply+=" $2"; shift 2 ;;
      --reapply=*) reapply+=" ${1#*=}"; shift ;;
      *) die "phase_oneshot: unknown argument: $1" ;;
    esac
  done
  tiers_file="${NODE_ROOT}/oneshot/TIERS"
  [[ -f "${tiers_file}" ]] || die "missing ${tiers_file}"
  mapfile -t lines < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "${tiers_file}")
  [[ ${#lines[@]} -gt 0 ]] || die "${tiers_file} lists no tier"
  for t in ${reapply}; do
    printf '%s\n' "${lines[@]}" | awk -v t="${t}" '$1 == t {f = 1} END {exit !f}' \
      || die "--reapply ${t}: not a tier in ${tiers_file} ($(awk '{printf "%s ", $1}' < <(printf '%s\n' "${lines[@]}")))"
  done
  ONESHOT_JQ="$(oneshot_tool jq)" || exit 1
  if declare -F require_cluster >/dev/null && ! require_cluster oneshot; then
    # dry-run before k3s is up: no tier can exist yet, so every tier would be applied
    log "[dry-run] would apply the one-shot tiers, in order: $(awk '{printf "%s ", $1}' < <(printf '%s\n' "${lines[@]}"))(each while its Application does not exist)"
    return 0
  fi
  for line in "${lines[@]}"; do
    read -r tier ns _ <<<"${line}"
    [[ "${tier}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "${tiers_file}: bad tier name '${tier}'"
    [[ -n "${ns}" ]] || ns="$(oneshot_default_namespace "${tier}")"
    force=0
    [[ " ${reapply} " != *" ${tier} "* ]] || force=1
    oneshot_tier "${tier}" "${ns}" "${force}"
  done
}

oneshot_default_namespace() {
  case "$1" in
    istio) echo "istio-system" ;;
    *) echo "teknoir-system" ;;
  esac
}

oneshot_tool() {
  # oneshot_tool <name> — the bundled node/bin/<name>, else one on PATH
  if [[ -x "${NODE_ROOT}/bin/$1" ]]; then
    echo "${NODE_ROOT}/bin/$1"
  elif command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
  else
    die "$1 not found (expected ${NODE_ROOT}/bin/$1)"
  fi
}

oneshot_k3s_owned() {
  # oneshot_k3s_owned <tier> — 0 (and ONESHOT_K3S_FILE set) when a live K3s
  # auto-deploy file still owns the tier's objects
  local dir="${K3S_DATA_DIR:-/opt/k3s}/server/manifests" n
  ONESHOT_K3S_FILE=""
  for n in "teknoir-$1" "10-teknoir-$1"; do
    if [[ -e "${dir}/${n}.yaml" && ! -e "${dir}/${n}.yaml.skip" ]]; then
      ONESHOT_K3S_FILE="${dir}/${n}.yaml"
      return 0
    fi
  done
  return 1
}

oneshot_adopted() {
  # oneshot_adopted <tier> — 0 when the ArgoCD Application <tier> exists
  in_cluster customresourcedefinitions.apiextensions.k8s.io applications.argoproj.io || return 1
  in_cluster applications.argoproj.io "$1" "${ONESHOT_APP_NS}"
}

oneshot_load() {
  # oneshot_load <file>... — ONESHOT_DOCS: JSON array of the objects in the
  # files (YAML converted offline by kubectl; nothing is sent to the API server)
  local f raw all=""
  for f in "$@"; do
    [[ -f "${f}" ]] || continue
    raw="$(kc annotate --local -o json -f "${f}" teknoir.org/oneshot-)" || die "cannot parse ${f}"
    all+="${raw}"$'\n'
  done
  ONESHOT_DOCS="$("${ONESHOT_JQ}" -cs 'map(select(type == "object" and has("kind")))
      | map(if (.metadata.annotations // {}) == {} then del(.metadata.annotations) else . end)' <<<"${all}")" \
    || die "cannot read the objects of $*"
}

oneshot_scope_map() {
  # ONESHOT_SCOPE: {"group/Kind": namespaced?} from discovery plus the tier's own CRDs
  local resources crds_json="$1" disc rc=0
  resources="$(kc api-resources --no-headers 2>/dev/null)" || rc=$?
  [[ -n "${resources}" ]] || die "cannot list the API resources"
  [[ "${rc}" == "0" ]] || warn "the API resource list is incomplete (an aggregated API is unavailable); using what was served"
  disc="$(awk '{v = $(NF-2); g = (index(v, "/") ? substr(v, 1, index(v, "/") - 1) : ""); print g "/" $NF " " $(NF-1)}' <<<"${resources}" \
    | "${ONESHOT_JQ}" -Rcn '[inputs | split(" ") | {(.[0]): (.[1] == "true")}] | add // {}')" \
    || die "cannot parse the API resources"
  # through files, not --argjson: one argv string is capped at 128 KiB
  # (MAX_ARG_STRLEN) and istio's 14 CRDs alone are ~800 KiB
  local tmp
  tmp="$(mktemp -d)" || die "cannot create a temp dir"
  printf '%s' "${disc}" > "${tmp}/disc.json"
  printf '%s' "${crds_json}" > "${tmp}/crds.json"
  ONESHOT_SCOPE="$("${ONESHOT_JQ}" -cn --slurpfile d "${tmp}/disc.json" --slurpfile c "${tmp}/crds.json" \
    '$d[0] + ([$c[0][] | {("\(.spec.group)/\(.spec.names.kind)"): (.spec.scope == "Namespaced")}] | add // {})')" \
    || { rm -rf "${tmp}"; die "cannot build the scope map"; }
  rm -rf "${tmp}"
}

oneshot_reinject_auto_pods() {
  # Delete pods that still carry the injection placeholder image "auto": their
  # ReplicaSet re-creates them and istiod's webhook injects the real image.
  local pods ns name
  pods="$(kc get pods -A -o json | "${ONESHOT_JQ}" -r '.items[]
      | select(any(.spec.containers[]?; .image == "auto")) | "\(.metadata.namespace) \(.metadata.name)"')" \
    || die "cannot list pods for the injection check"
  while read -r ns name; do
    [[ -n "${name}" ]] || continue
    if dry_run; then log "[dry-run] would re-create pod ${ns}/${name} (image \"auto\" was never injected)"; continue; fi
    kc -n "${ns}" delete pod "${name}" --wait=false >/dev/null || die "cannot delete pod ${ns}/${name}"
    changed "re-created pod ${ns}/${name}: it was created before istiod could inject its proxy image"
  done <<<"${pods}"
}

oneshot_crds_established() {
  local n s
  for n in "$@"; do
    s="$(kc get customresourcedefinitions.apiextensions.k8s.io "${n}" --ignore-not-found \
      -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')" || return 1
    [[ "${s}" == "True" ]] || return 1
  done
}

oneshot_rolled_out() {
  # oneshot_rolled_out <ns> <kind> <name>
  kc -n "$1" rollout status "$2/$3" --timeout=10s >/dev/null 2>&1
}

oneshot_job_state() {
  # oneshot_job_state <ns> <name> — sets ONESHOT_JOB to Complete, Failed,
  # Running or Absent (not for $(...): it dies when the Job cannot be read)
  local c
  c="$(kc -n "$1" get job "$2" --ignore-not-found \
    -o jsonpath='{.metadata.name}{" "}{range .status.conditions[*]}{.type}={.status}{" "}{end}')" \
    || die "cannot read Job $1/$2"
  if [[ -z "${c}" ]]; then ONESHOT_JOB=Absent
  elif [[ " ${c} " == *" Complete=True "* ]]; then ONESHOT_JOB=Complete
  elif [[ " ${c} " == *" Failed=True "* ]]; then ONESHOT_JOB=Failed
  else ONESHOT_JOB=Running
  fi
}

oneshot_job_finished() {
  oneshot_job_state "$1" "$2"
  [[ "${ONESHOT_JOB}" == "Complete" || "${ONESHOT_JOB}" == "Failed" ]]
}

oneshot_tier() {
  # oneshot_tier <tier> <namespace> <force 0|1>
  local tier="$1" ns="$2" force="$3"
  local main="${NODE_ROOT}/oneshot/${tier}.yaml" crds_file="${NODE_ROOT}/oneshot/${tier}-crds.yaml"
  local split crds rest list objs line kind jns jname crd_names
  [[ -f "${main}" ]] || die "missing ${main}"
  if oneshot_k3s_owned "${tier}"; then
    [[ "${force}" != "1" ]] || die "--reapply ${tier}: refused, the K3s file ${ONESHOT_K3S_FILE} still owns this tier (detach it first, DESIGN M7)"
    warn "tier ${tier}: skipped, the K3s file ${ONESHOT_K3S_FILE} still owns it (DESIGN M7)"
    return 0
  fi
  if oneshot_adopted "${tier}"; then
    if [[ "${force}" != "1" ]]; then
      log "tier ${tier}: Application ${ONESHOT_APP_NS}/${tier} exists, ArgoCD owns it: skipped"
      return 0
    fi
    warn "tier ${tier}: --reapply: applying the bundle render over ArgoCD's Application ${tier} (break-glass)"
  fi

  oneshot_load "${crds_file}" "${main}"
  split="$("${ONESHOT_JQ}" -c "${ONESHOT_JQ_SPLIT}" <<<"${ONESHOT_DOCS}")" || die "cannot split ${tier}"
  crds="$("${ONESHOT_JQ}" -c '.crds' <<<"${split}")"
  rest="$("${ONESHOT_JQ}" -c '.rest' <<<"${split}")"
  while IFS= read -r line; do
    [[ -z "${line}" ]] || log "tier ${tier}: left to ArgoCD (hook): ${line}"
  done < <("${ONESHOT_JQ}" -r '.hooks_skipped[]' <<<"${split}")
  log "tier ${tier}: $("${ONESHOT_JQ}" 'length' <<<"${crds}") CRD(s), $("${ONESHOT_JQ}" 'length' <<<"${rest}") object(s), namespace ${ns}"

  # 1. CRDs, Established before anything that uses them
  crd_names="$("${ONESHOT_JQ}" -r '.[].metadata.name' <<<"${crds}")"
  if [[ -n "${crd_names}" ]]; then
    list="$("${ONESHOT_JQ}" -c '{apiVersion: "v1", kind: "List", items: .}' <<<"${crds}")"
    oneshot_converge "${tier} CRDs" "${list}" "[]"
    # shellcheck disable=SC2086  # CRD names, one word each
    wait_for "the ${tier} CRDs to be Established" 180 oneshot_crds_established ${crd_names}
  fi

  # 2. the rest, namespaces defaulted the way ArgoCD does
  oneshot_scope_map "${crds}"
  objs="$("${ONESHOT_JQ}" -c --argjson scope "${ONESHOT_SCOPE}" --arg ns "${ns}" "${ONESHOT_JQ_NAMESPACE}" <<<"${rest}")" \
    || die "cannot prepare ${tier}"
  line="$("${ONESHOT_JQ}" -r '.unknown | join(", ")' <<<"${objs}")"
  [[ -z "${line}" ]] || warn "tier ${tier}: left to ArgoCD, their kinds are not served yet and the tier defines no CRD for them: ${line}"
  line="$("${ONESHOT_JQ}" -r '.defaulted | join(", ")' <<<"${objs}")"
  [[ -z "${line}" ]] || log "tier ${tier}: namespace ${ns} set (as ArgoCD would) on: ${line}"
  rest="$("${ONESHOT_JQ}" -c '.apply' <<<"${objs}")"
  [[ "$("${ONESHOT_JQ}" 'length' <<<"${rest}")" != "0" ]] || { log "tier ${tier}: nothing to apply"; return 0; }
  list="$("${ONESHOT_JQ}" -c '{apiVersion: "v1", kind: "List", items: .}' <<<"${rest}")"

  oneshot_converge "${tier}" "${list}" "${rest}"

  # 3. wait until the tier runs. Istio gateways use image "auto", which
  # istiod's injection webhook fills in when the pod is created; a gateway pod
  # created before istiod answered keeps "auto" for good (ImagePullBackOff), so
  # once istiod is up such pods are re-created.
  if "${ONESHOT_JQ}" -e 'any(.[]; .kind == "Deployment" and .metadata.name == "istiod")' <<<"${rest}" >/dev/null; then
    wait_for "Deployment istio-system/istiod to roll out" "${ONESHOT_TIMEOUT}" oneshot_rolled_out istio-system deployment istiod
    oneshot_reinject_auto_pods
  fi
  while read -r kind jns jname; do
    [[ -n "${jname}" ]] || continue
    wait_for "${kind} ${jns}/${jname} to roll out" "${ONESHOT_TIMEOUT}" oneshot_rolled_out "${jns}" "${kind,,}" "${jname}"
  done < <("${ONESHOT_JQ}" -r '.[] | select((.apiVersion // "") | startswith("apps/"))
      | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
      | "\(.kind) \(.metadata.namespace) \(.metadata.name)"' <<<"${rest}")
  while read -r jns jname; do
    [[ -n "${jname}" ]] || continue
    wait_for "Job ${jns}/${jname} to finish" "${ONESHOT_TIMEOUT}" oneshot_job_finished "${jns}" "${jname}"
    [[ "${DRY_RUN}" == "1" ]] && continue
    oneshot_job_state "${jns}" "${jname}"
    [[ "${ONESHOT_JOB}" == "Complete" ]] \
      || die "tier ${tier}: Job ${jns}/${jname} ${ONESHOT_JOB} (logs: kubectl -n ${jns} logs job/${jname}); a re-run re-creates it"
    log "tier ${tier}: Job ${jns}/${jname} complete"
  done < <(oneshot_jobs "${rest}")
  # 4. a finished ArgoCD hook Job carries no tracking: remove it, ArgoCD runs its own
  while read -r jns jname; do
    [[ -n "${jname}" ]] || continue
    [[ "${DRY_RUN}" != "1" ]] || continue
    oneshot_job_state "${jns}" "${jname}"
    if [[ "${ONESHOT_JOB}" == "Complete" ]]; then
      kc -n "${jns}" delete job "${jname}" --cascade=background --wait=false >/dev/null \
        || die "cannot delete the finished Job ${jns}/${jname}"
    fi
  done < <("${ONESHOT_JQ}" -r '.[] | select(.kind == "Job" and ((.metadata.annotations // {})["argocd.argoproj.io/hook"] // "") != "")
      | "\(.metadata.namespace) \(.metadata.name)"' <<<"${rest}")
  log "tier ${tier}: ready"
}

oneshot_jobs() {
  # oneshot_jobs <objects-json> — "namespace name" of each batch Job
  "${ONESHOT_JQ}" -r '.[] | select(.kind == "Job" and ((.apiVersion // "") | startswith("batch/")))
      | "\(.metadata.namespace) \(.metadata.name)"' <<<"$1"
}

oneshot_converge() {
  # oneshot_converge <description> <List-json> <objects-json (for its Jobs)> —
  # apply only when the live objects differ from the render (kubectl diff
  # --server-side as the same field manager), so a re-run changes nothing.
  # A failed Job is re-created; Job templates are immutable, so an existing
  # Job is replaced when the render differs.
  local desc="$1" list="$2" objs="$3" rc=0 err jns jname
  while read -r jns jname; do
    [[ -n "${jname}" ]] || continue
    oneshot_job_state "${jns}" "${jname}"
    if [[ "${ONESHOT_JOB}" == "Failed" ]]; then
      warn "${desc}: Job ${jns}/${jname} failed earlier; re-creating it"
      run kc -n "${jns}" delete job "${jname}" --cascade=foreground --wait=true >/dev/null
    fi
  done < <(oneshot_jobs "${objs}")
  err="$(kc diff --server-side --field-manager="${ONESHOT_MANAGER}" --force-conflicts -f - <<<"${list}" 2>&1 >/dev/null)" || rc=$?
  if [[ "${rc}" == "0" ]]; then
    log "${desc}: the live objects equal the render: nothing applied"
    return 0
  fi
  [[ "${rc}" == "1" ]] || log "${desc}: kubectl diff could not compare (${err##*$'\n'}); applying"
  while read -r jns jname; do
    [[ -n "${jname}" ]] || continue
    oneshot_job_state "${jns}" "${jname}"
    [[ "${ONESHOT_JOB}" != "Absent" ]] || continue
    run kc -n "${jns}" delete job "${jname}" --cascade=foreground --wait=true >/dev/null
  done < <(oneshot_jobs "${objs}")
  oneshot_apply "${desc}" "${list}"
}

oneshot_apply() {
  # oneshot_apply <description> <List-json> — server-side apply as ArgoCD's field manager
  local desc="$1" list="$2" n
  n="$("${ONESHOT_JQ}" '.items | length' <<<"${list}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would server-side apply ${desc} (${n} object(s)) as ${ONESHOT_MANAGER}"
    return 0
  fi
  kc apply --server-side --field-manager="${ONESHOT_MANAGER}" --force-conflicts -o name -f - <<<"${list}" >/dev/null \
    || die "server-side apply of ${desc} failed"
  changed "applied ${desc} (${n} object(s)) as ${ONESHOT_MANAGER}"
}
