# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016  # DRY_RUN, K3S_DATA_DIR, NODE, NODE_ROOT, TEKNOIR_DOMAIN come from common.sh and the site env; jq programs are single-quoted on purpose
#
# lib/migrate.sh — `teknoir-node migrate`: the one-time move of the live
# teknoir-local off K3s auto-deploy files (docs/airgap/DESIGN.md M3, M6, M7a,
# I-13). TEMPORARY: delete this file once teknoir-local is migrated (M8).
#
#   teknoir-node migrate [--dry-run]     detach every Teknoir K3s file except
#                                        teknoir-argo, remove the pre-fix bundle
#                                        copies on the node, retire the Harbor
#                                        robot once ArgoCD pulls anonymously (M3, M6)
#   teknoir-node migrate --argo [--dry-run]
#                                        M7a: detach teknoir-argo once the argo
#                                        Application (app-of-apps 0.0.4) runs ArgoCD
#   teknoir-node migrate --undo NAME     re-adopt one detached file (K3s re-applies it)
#
# Detach recipe, per name (never the K3s `disable:` list, which deletes objects):
#   1. create <manifests>/<name>.yaml.skip, so K3s ignores any later copy of the file;
#   2. move <name>.yaml to <data-dir>/server/manifests-retired/<UTC>/ (never edited);
#   3. strip the objectset.rio.cattle.io/hash label and the objectset annotations
#      (applied, id, owner-gvk, owner-name, owner-namespace) from every object the
#      Addon owns: the objects of each GVK in its addon.k3s.cattle.io/gvks annotation
#      that carry hash = sha1(id + owner-gvk + owner-name + owner-namespace);
#   4. delete the Addon object;
#   5. assert that every object of that name still exists with the same UID and
#      no K3s label.
# Safety net (DESIGN M3, I-13): before the first change, a baseline records the
# UID of every object of every Addon in this run, and the counts of namespaces,
# Secrets per namespace, CRDs, Applications and the istio/cert-manager kinds of
# DESIGN M2. After every name all of it is compared again: a lost or
# re-created object, or any changed count, stops the run with the undo command.
# Order: orphan Addons (file gone), legacy manifest-*-secret, teknoir-*-secret,
# 00-teknoir-namespaces, teknoir-coredns-custom and teknoir-app-of-apps, the CRD
# files, then any other allow-listed name. teknoir-argo is detached only by
# --argo (DESIGN M7a): ArgoCD must first run from its own Application, which
# app-of-apps 0.0.4 enables; run migrate --argo right after that up (no k3s
# restart in between, so K3s never re-applies its file over ArgoCD). Only
# allow-listed names are touched, never K3s's packaged addons. Every step is
# idempotent: a re-run (also after a failure) resumes.

MIGRATE_ALLOW_RE='^(teknoir-.+|00-teknoir-.+|05-teknoir-.+|10-teknoir-.+|manifest-.+-secret|app-of-apps)$'
MIGRATE_EXCLUDED="teknoir-argo"
MIGRATE_STRIP_PATCH='{"metadata":{"labels":{"objectset.rio.cattle.io/hash":null},"annotations":{"objectset.rio.cattle.io/applied":null,"objectset.rio.cattle.io/id":null,"objectset.rio.cattle.io/owner-gvk":null,"objectset.rio.cattle.io/owner-name":null,"objectset.rio.cattle.io/owner-namespace":null}}}'
MIGRATE_REPO_CREDS_NS="teknoir-system"
MIGRATE_REPO_CREDS="argocd-harbor-repo"
MIGRATE_ARGOCD_TIMEOUT="${MIGRATE_ARGOCD_TIMEOUT:-180}"
MIGRATE_ONLY=""
# counted in the baseline besides CRDs, Namespaces and Secrets per namespace (DESIGN M2)
MIGRATE_COUNT_KINDS="Application.argoproj.io VirtualService.networking.istio.io Gateway.networking.istio.io DestinationRule.networking.istio.io AuthorizationPolicy.security.istio.io PeerAuthentication.security.istio.io Certificate.cert-manager.io ClusterIssuer.cert-manager.io"
MIGRATE_ARGO_APP="argo"
MIGRATE_ARGO_APP_NS="${MIGRATE_ARGO_APP_NS:-teknoir-system}"
MIGRATE_ARGO_SETTLE="${MIGRATE_ARGO_SETTLE:-20}"

cmd_migrate() {
  local -a undo=()
  local argo=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --argo) argo=1; shift ;;
      --undo) [[ $# -ge 2 ]] || die "--undo needs a name"; undo+=("$2"); shift 2 ;;
      --undo=*) undo+=("${1#*=}"); shift ;;
      -h|--help) migrate_usage; return 0 ;;
      *) die "migrate: unknown argument: $1 (see: teknoir-node migrate --help)" ;;
    esac
  done
  [[ "${argo}" == "0" || ${#undo[@]} -eq 0 ]] || die "migrate: --argo and --undo cannot be combined"
  migrate_init
  local name
  if [[ ${#undo[@]} -gt 0 ]]; then
    for name in "${undo[@]}"; do
      migrate_undo "${name}"
    done
    return 0
  fi
  if [[ "${argo}" == "1" ]]; then
    migrate_argo
    return 0
  fi
  migrate_detach_all
  migrate_remove_old_bundles
  migrate_retire_robot
}

migrate_usage() {
  cat >&2 <<'EOF'
Usage: teknoir-node migrate [--dry-run]
       teknoir-node migrate --argo [--dry-run]
       teknoir-node migrate --undo NAME [--undo NAME]...

Detaches the Teknoir K3s auto-deploy files (DESIGN M3): .skip guard, file moved to
<data-dir>/server/manifests-retired/<UTC>/, K3s labels stripped, Addon deleted,
object UIDs and counts compared with a baseline after every name. Then removes
~<user>/teknoir-airgap-bundle-* and, once ArgoCD reads the public Harbor project
without credentials, the robot repo-creds Secret and robot$argocd (M6). Safe to
re-run. teknoir-argo stays until --argo (M7a), which needs the Application argo
(app-of-apps 0.0.4) Synced/Healthy and the argoproj CRDs protected
(Prune=false,Delete=false), and checks that no ArgoCD pod restarts.
--undo NAME puts a detached file back.
EOF
}

migrate_tool() {
  # migrate_tool <name> — the bundled node/bin/<name>, else one on PATH
  if [[ -x "${NODE_ROOT}/bin/$1" ]]; then
    echo "${NODE_ROOT}/bin/$1"
  elif command -v "$1" >/dev/null 2>&1; then
    command -v "$1"
  else
    die "$1 not found (expected ${NODE_ROOT}/bin/$1)"
  fi
}

migrate_init() {
  local data="${K3S_DATA_DIR:-/opt/k3s}"
  MIGRATE_JQ="$(migrate_tool jq)" || exit 1
  MIGRATE_MANIFESTS="${data}/server/manifests"
  MIGRATE_RETIRED_ROOT="${data}/server/manifests-retired"
  MIGRATE_RETIRED="${MIGRATE_RETIRED_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  [[ -d "${MIGRATE_MANIFESTS}" ]] || die "no K3s manifests dir ${MIGRATE_MANIFESTS} (K3S_DATA_DIR=${data})"
  local rc=0
  MIGRATE_KINDS="$(kc api-resources --no-headers 2>/dev/null)" || rc=$?
  [[ -n "${MIGRATE_KINDS}" ]] || die "cannot list the API resources"
  [[ "${rc}" == "0" ]] || warn "the API resource list is incomplete (an aggregated API is unavailable); kinds it does not serve are skipped"
  # "group/Kind" per served resource (APIVERSION is the third column from the end)
  MIGRATE_KINDS="$(awk '{v = $(NF-2); g = (index(v, "/") ? substr(v, 1, index(v, "/") - 1) : ""); print g "/" $NF}' <<<"${MIGRATE_KINDS}")"
}

migrate_allowed() {
  [[ "$1" =~ ${MIGRATE_ALLOW_RE} ]]
}

migrate_selected() {
  # migrate_selected <name> — 0 when this run processes <name>: only
  # MIGRATE_ONLY when set (--argo), else every allow-listed name but teknoir-argo
  if [[ -n "${MIGRATE_ONLY}" ]]; then
    [[ "$1" == "${MIGRATE_ONLY}" ]]
  else
    [[ "$1" != "${MIGRATE_EXCLUDED}" ]]
  fi
}

migrate_res_served() {
  # migrate_res_served <Kind.v1.|Kind.group> — 0 when the cluster serves the kind
  local kind="${1%%.*}" group="${1#*.}"
  [[ "${group}" != "v1." ]] || group=""
  grep -qxF -- "${group}/${kind}" <<<"${MIGRATE_KINDS}"
}

migrate_hash() {
  # K3s (wrangler apply) labels every object of an Addon with
  # sha1(objectset id "" + owner GVK + owner name + owner namespace)
  printf '%s' "k3s.cattle.io/v1, Kind=Addon${1}kube-system" | sha1sum | awk '{print $1}'
}

migrate_gvk_resource() {
  # migrate_gvk_resource "<group>/<version>, Kind=<Kind>" — sets MIGRATE_RES to the
  # kubectl resource argument for that GVK (Kind.v1. for core, Kind.group
  # otherwise); returns 1 when the cluster no longer serves the kind (then no
  # object of it can exist). Not for $(...): it dies on a malformed GVK.
  local gvk="$1" gv kind group version
  MIGRATE_RES=""
  gvk="${gvk#"${gvk%%[![:space:]]*}"}"
  gvk="${gvk%"${gvk##*[![:space:]]}"}"
  [[ "${gvk}" == *", Kind="* ]] || die "unexpected GVK '${gvk}' in an Addon's addon.k3s.cattle.io/gvks"
  gv="${gvk%%, Kind=*}"
  kind="${gvk##*Kind=}"
  if [[ "${gv}" == */* ]]; then group="${gv%%/*}"; version="${gv##*/}"; else group=""; version="${gv}"; fi
  grep -qxF -- "${group}/${kind}" <<<"${MIGRATE_KINDS}" || return 1
  if [[ -z "${group}" ]]; then
    MIGRATE_RES="${kind}.${version}."
  else
    MIGRATE_RES="${kind}.${group}"
  fi
}

migrate_objects() {
  # migrate_objects <addon> <gvks> — sets MIGRATE_OBJS to one line
  # "resource<TAB>namespace<TAB>name<TAB>uid" per object that K3s labelled as
  # owned by <addon>. Not for $(...): it dies on errors.
  local addon="$1" gvks="$2" hash entry out all=""
  local -a list=()
  MIGRATE_OBJS=""
  hash="$(migrate_hash "${addon}")"
  IFS=';' read -r -a list <<<"${gvks}"
  for entry in ${list[@]+"${list[@]}"}; do
    [[ -n "${entry// /}" ]] || continue
    migrate_gvk_resource "${entry}" || continue
    out="$(kc get "${MIGRATE_RES}" -A -l "objectset.rio.cattle.io/hash=${hash}" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.uid}{"\n"}{end}')" \
      || die "cannot list the ${MIGRATE_RES} objects of Addon ${addon}"
    [[ -n "${out}" ]] || continue
    all+="$(awk -v r="${MIGRATE_RES}" -F '|' 'NF >= 3 && $2 != "" {print r "|" $1 "|" $2 "|" $3}' <<<"${out}")"$'\n'
  done
  MIGRATE_OBJS="$(sort -u <<<"${all}" | sed '/^$/d')"
}

migrate_list() {
  # migrate_list <resource> — MIGRATE_LIST: "resource|namespace|name|uid" of
  # every object of that kind (names only leave kubectl). Not for $(...): dies.
  local out
  out="$(kc get "$1" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.uid}{"\n"}{end}')" \
    || die "cannot list $1"
  MIGRATE_LIST="$(awk -v r="$1" -F '|' 'NF >= 3 && $2 != "" {print r "|" $1 "|" $2 "|" $3}' <<<"${out}")"
}

migrate_count_key() {
  # the baseline's name for a counted kind
  case "$1" in
    CustomResourceDefinition.apiextensions.k8s.io) echo "crds" ;;
    Namespace.v1.) echo "namespaces" ;;
    *) echo "$1" ;;
  esac
}

migrate_snapshot() {
  # migrate_snapshot <resources> — MIGRATE_SNAP_OBJS: every object of those
  # kinds and of the counted kinds ("resource|namespace|name|uid", sorted);
  # MIGRATE_SNAP_COUNTS: sorted "key=count" lines for CRDs, Namespaces,
  # Secrets per namespace and MIGRATE_COUNT_KINDS. Not for $(...): dies.
  local res objs="" counts=""
  # shellcheck disable=SC2086  # resource names, one word each
  for res in $(printf '%s\n' CustomResourceDefinition.apiextensions.k8s.io Namespace.v1. Secret.v1. $1 ${MIGRATE_COUNT_KINDS} | sort -u); do
    migrate_res_served "${res}" || continue
    migrate_list "${res}"
    objs+="${MIGRATE_LIST}"$'\n'
    case " CustomResourceDefinition.apiextensions.k8s.io Namespace.v1. ${MIGRATE_COUNT_KINDS} " in
      *" ${res} "*) counts+="$(migrate_count_key "${res}")=$(grep -c . <<<"${MIGRATE_LIST}" || true)"$'\n' ;;
    esac
    if [[ "${res}" == "Secret.v1." ]]; then
      counts+="$(awk -F '|' 'NF {n[$2]++} END {for (k in n) print "secrets/" k "=" n[k]}' <<<"${MIGRATE_LIST}")"$'\n'
    fi
  done
  MIGRATE_SNAP_OBJS="$(sed '/^$/d' <<<"${objs}" | sort -u)"
  MIGRATE_SNAP_COUNTS="$(sed '/^$/d' <<<"${counts}" | LC_ALL=C sort -t '=' -k1,1)"
}

migrate_baseline() {
  # Before any change: MIGRATE_BASE_OBJS (every object of every Addon in
  # MIGRATE_INVENTORY, with its UID), MIGRATE_BASE_RES (their kinds) and
  # MIGRATE_BASE_COUNTS; logged as names and counts. Not for $(...): dies.
  local class name base addon gvks objs="" n_addons=0 res
  while IFS='|' read -r class name base addon gvks; do
    [[ -n "${name}" && "${addon}" == "1" ]] || continue
    [[ -n "${gvks}" ]] || die "Addon ${name} has no addon.k3s.cattle.io/gvks annotation; cannot select its objects safely"
    migrate_objects "${name}" "${gvks}"
    [[ -z "${MIGRATE_OBJS}" ]] || objs+="${MIGRATE_OBJS}"$'\n'
    n_addons=$((n_addons + 1))
  done <<<"${MIGRATE_INVENTORY}"
  MIGRATE_BASE_OBJS="$(sed '/^$/d' <<<"${objs}" | sort -u)"
  MIGRATE_BASE_RES="$(cut -d '|' -f1 <<<"${MIGRATE_BASE_OBJS}" | sed '/^$/d' | sort -u | tr '\n' ' ')"
  migrate_snapshot "${MIGRATE_BASE_RES}"
  MIGRATE_BASE_COUNTS="${MIGRATE_SNAP_COUNTS}"
  # every baseline object must be in the snapshot just taken (it was read moments ago)
  [[ -z "$(comm -23 <(printf '%s\n' "${MIGRATE_BASE_OBJS}") <(printf '%s\n' "${MIGRATE_SNAP_OBJS}"))" ]] \
    || die "migrate: the cluster changed while the baseline was taken; run migrate again"
  log "migrate: baseline: $(grep -c . <<<"${MIGRATE_BASE_OBJS}" || true) object(s) of ${n_addons} Addon(s), checked by UID after every name:"
  for res in ${MIGRATE_BASE_RES}; do
    log "    ${res}: $(awk -F '|' -v r="${res}" '$1 == r {printf "%s%s ", ($2 == "" ? "" : $2 "/"), $3}' <<<"${MIGRATE_BASE_OBJS}")"
  done
  log "migrate: baseline counts: $(tr '\n' ' ' <<<"${MIGRATE_BASE_COUNTS}")"
}

migrate_check_baseline() {
  # migrate_check_baseline <name just detached> — dies at the first lost or
  # re-created baseline object or changed count
  local after="$1" missing problems="" res ns oname uid changes
  migrate_snapshot "${MIGRATE_BASE_RES}"
  missing="$(comm -23 <(printf '%s\n' "${MIGRATE_BASE_OBJS}" | sed '/^$/d') <(printf '%s\n' "${MIGRATE_SNAP_OBJS}"))"
  if [[ -n "${missing}" ]]; then
    while IFS='|' read -r res ns oname uid; do
      if awk -F '|' -v r="${res}" -v n="${ns}" -v o="${oname}" '$1 == r && $2 == n && $3 == o {f = 1} END {exit !f}' <<<"${MIGRATE_SNAP_OBJS}"; then
        problems+=" ${res} ${ns:+${ns}/}${oname} re-created (new UID);"
      else
        problems+=" ${res} ${ns:+${ns}/}${oname} LOST;"
      fi
    done <<<"${missing}"
    die "migrate: after ${after}:${problems} stopping. Investigate before anything else (undo: teknoir-node migrate --undo ${after}); a re-run takes a new baseline"
  fi
  if [[ "${MIGRATE_SNAP_COUNTS}" != "${MIGRATE_BASE_COUNTS}" ]]; then
    changes="$(LC_ALL=C join -t '=' -a 1 -a 2 -e 0 -o 0,1.2,2.2 <(printf '%s\n' "${MIGRATE_BASE_COUNTS}") <(printf '%s\n' "${MIGRATE_SNAP_COUNTS}") \
      | awk -F '=' '$2 != $3 {printf "%s %s -> %s; ", $1, $2, $3}')"
    die "migrate: object counts changed after ${after}: ${changes}stopping. Investigate before anything else (undo: teknoir-node migrate --undo ${after}); a re-run takes a new baseline"
  fi
}

migrate_class() {
  # migrate_class <name> <file-present 0|1> <addon-present 0|1> — processing order
  if [[ "$3" == "1" && "$2" == "0" ]]; then echo 1; return 0; fi
  case "$1" in
    manifest-*-secret) echo 2 ;;
    teknoir-*-secret) echo 3 ;;
    00-teknoir-namespaces) echo 4 ;;
    teknoir-coredns-custom|teknoir-app-of-apps) echo 5 ;;
    00-teknoir-istio-crds|05-teknoir-certmanager-crds) echo 6 ;;
    *) echo 7 ;;
  esac
}

migrate_class_label() {
  case "$1" in
    1) echo "orphan Addon (file already gone)" ;;
    2) echo "legacy manifest-*-secret" ;;
    3) echo "teknoir-*-secret" ;;
    4) echo "namespaces" ;;
    5) echo "coredns-custom / root app-of-apps" ;;
    6) echo "CRDs" ;;
    *) echo "other Teknoir file" ;;
  esac
}

migrate_inventory() {
  # Sets MIGRATE_INVENTORY to one line per Teknoir K3s file or Addon still to
  # detach, in processing order:
  #   class<TAB>name<TAB>file basename|-<TAB>addon present 0|1<TAB>gvks
  # Not for $(...): it dies on errors.
  local addons rows name gvks src base f file_present lines=""
  local -A seen=()
  addons="$(kc -n kube-system get addons.k3s.cattle.io -o json)" || die "cannot list the K3s Addons"
  rows="$("${MIGRATE_JQ}" -r '.items[] | [.metadata.name, (.metadata.annotations["addon.k3s.cattle.io/gvks"] // ""), (.spec.source // "")] | map(gsub("[|\n]"; " ")) | join("|")' <<<"${addons}")" \
    || die "cannot parse the K3s Addons"
  while IFS='|' read -r name gvks src; do
    [[ -n "${name}" ]] || continue
    migrate_allowed "${name}" || continue
    migrate_selected "${name}" || continue
    seen["${name}"]=1
    base="-"
    file_present=0
    if [[ -n "${src}" ]]; then
      [[ "$(basename "$(dirname "${src}")")" == "manifests" ]] \
        || die "Addon ${name}: source ${src} is not a top-level file of the manifests dir; refusing"
      base="$(basename "${src}")"
      [[ ! -e "${MIGRATE_MANIFESTS}/${base}" ]] || file_present=1
    fi
    lines+="$(migrate_class "${name}" "${file_present}" 1)|${name}|${base}|1|${gvks}"$'\n'
  done <<<"${rows}"
  # files without an Addon (never applied, or dropped next to their .skip)
  for f in "${MIGRATE_MANIFESTS}"/*.yaml "${MIGRATE_MANIFESTS}"/*.yml "${MIGRATE_MANIFESTS}"/*.json; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    name="${base%.*}"
    migrate_allowed "${name}" || continue
    migrate_selected "${name}" || continue
    [[ -z "${seen["${name}"]:-}" ]] || continue
    lines+="$(migrate_class "${name}" 1 0)|${name}|${base}|0|"$'\n'
  done
  MIGRATE_INVENTORY="$(sort -t '|' -k1,1n -k2,2 <<<"${lines}" | sed '/^$/d')"
}

migrate_detach_all() {
  local inventory class name base addon gvks n=0 last_class=""
  migrate_inventory
  inventory="${MIGRATE_INVENTORY}"
  if [[ -z "${inventory}" ]]; then
    if [[ -n "${MIGRATE_ONLY}" ]]; then
      log "migrate: ${MIGRATE_ONLY} is detached already (no file, no Addon)"
    else
      log "migrate: no Teknoir K3s files or Addons left to detach (${MIGRATE_EXCLUDED} is detached by migrate --argo, DESIGN M7a)"
    fi
  else
    log "migrate: plan ($(grep -c . <<<"${inventory}") names, in this order):"
    while IFS='|' read -r class name base addon gvks; do
      if [[ "${class}" != "${last_class}" ]]; then
        log "  [$(migrate_class_label "${class}")]"
        last_class="${class}"
      fi
      log "    ${name} (file: ${base}, Addon: $([[ "${addon}" == "1" ]] && echo present || echo absent))"
    done <<<"${inventory}"
  fi
  migrate_baseline
  while IFS='|' read -r class name base addon gvks; do
    [[ -n "${name}" ]] || continue
    migrate_detach "${name}" "${base}" "${addon}" "${gvks}"
    n=$((n + 1))
    [[ "${DRY_RUN}" == "1" ]] || migrate_check_baseline "${name}"
  done <<<"${inventory}"
  migrate_report "${n}"
}

migrate_detach() {
  # migrate_detach <name> <file basename|-> <addon present 0|1> <gvks>
  local name="$1" base="$2" addon="$3" gvks="$4" file skip objs count=0
  [[ "${base}" != "-" ]] || base="${name}.yaml"
  file="${MIGRATE_MANIFESTS}/${base}"
  skip="${file}.skip"
  objs=""
  if [[ "${addon}" == "1" ]]; then
    [[ -n "${gvks}" ]] || die "Addon ${name} has no addon.k3s.cattle.io/gvks annotation; cannot select its objects safely"
    migrate_objects "${name}" "${gvks}"
    objs="${MIGRATE_OBJS}"
    [[ -z "${objs}" ]] || count="$(grep -c . <<<"${objs}")"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] ${name}: would $([[ -e "${skip}" ]] || echo "create ${base}.skip, ")$([[ -e "${file}" ]] && echo "move ${base} to ${MIGRATE_RETIRED}/, ")strip ${count} object(s)$([[ "${addon}" == "1" ]] && echo ", delete the Addon")"
    [[ -z "${objs}" ]] || awk -F '|' '{print "[teknoir-node]   [dry-run]   " $1 " " ($2 == "" ? "" : $2 "/") $3}' <<<"${objs}" >&2
    return 0
  fi
  log "${name}: detaching (${count} object(s))"
  [[ -z "${objs}" ]] || awk -F '|' '{print "[teknoir-node]     " $1 " " ($2 == "" ? "" : $2 "/") $3}' <<<"${objs}" >&2
  # 1. guard: K3s skips <file>.skip's file, so no old bundle can re-create it
  if [[ ! -e "${skip}" ]]; then
    ( umask 077 && : > "${skip}" ) || die "cannot create ${skip}"
    changed "K3s guard ${skip}"
  fi
  # 2. retire the file, unmodified
  if [[ -e "${file}" ]]; then
    install -d -m 0700 "${MIGRATE_RETIRED_ROOT}" "${MIGRATE_RETIRED}" || die "cannot create ${MIGRATE_RETIRED}"
    [[ ! -e "${MIGRATE_RETIRED}/${base}" ]] || die "${MIGRATE_RETIRED}/${base} exists already"
    mv -- "${file}" "${MIGRATE_RETIRED}/${base}" || die "cannot move ${file}"
    changed "retired ${base} to ${MIGRATE_RETIRED}/"
  fi
  # 3. strip K3s's ownership from the objects (they stay where they are)
  local res ns oname uid
  while IFS='|' read -r res ns oname uid; do
    [[ -n "${oname}" ]] || continue
    if [[ -n "${ns}" ]]; then
      kc -n "${ns}" patch "${res}" "${oname}" --type=merge -p "${MIGRATE_STRIP_PATCH}" -o name >/dev/null \
        || die "cannot strip the K3s labels from ${res} ${ns}/${oname}"
    else
      kc patch "${res}" "${oname}" --type=merge -p "${MIGRATE_STRIP_PATCH}" -o name >/dev/null \
        || die "cannot strip the K3s labels from ${res} ${oname}"
    fi
  done <<<"${objs}"
  [[ "${count}" == "0" ]] || changed "stripped K3s ownership from ${count} object(s) of ${name}"
  # 4. the Addon object
  if [[ "${addon}" == "1" ]] && in_cluster addons.k3s.cattle.io "${name}" kube-system; then
    kc -n kube-system delete addons.k3s.cattle.io "${name}" --wait=true >/dev/null \
      || die "cannot delete Addon ${name}"
    changed "deleted Addon ${name}"
  fi
  # 5. every object survived, unchanged identity, no K3s label
  migrate_assert_objects "${name}" "${objs}"
}

migrate_assert_objects() {
  local name="$1" objs="$2" res ns oname uid got guid ghash
  while IFS='|' read -r res ns oname uid; do
    [[ -n "${oname}" ]] || continue
    if [[ -n "${ns}" ]]; then
      got="$(kc -n "${ns}" get "${res}" "${oname}" --ignore-not-found \
        -o jsonpath='{.metadata.uid}{"|"}{.metadata.labels.objectset\.rio\.cattle\.io/hash}{"\n"}')" \
        || die "cannot read ${res} ${ns}/${oname}"
    else
      got="$(kc get "${res}" "${oname}" --ignore-not-found \
        -o jsonpath='{.metadata.uid}{"|"}{.metadata.labels.objectset\.rio\.cattle\.io/hash}{"\n"}')" \
        || die "cannot read ${res} ${oname}"
    fi
    [[ -n "${got}" ]] || die "LOST after detaching ${name}: ${res} ${ns:+${ns}/}${oname}; stopping (undo: teknoir-node migrate --undo ${name})"
    IFS='|' read -r guid ghash <<<"${got}"
    [[ "${guid}" == "${uid}" ]] || die "${res} ${ns:+${ns}/}${oname} was re-created (UID changed) while detaching ${name}; stopping"
    [[ -z "${ghash}" ]] || die "${res} ${ns:+${ns}/}${oname} still carries a K3s label after detaching ${name}; stopping"
  done <<<"${objs}"
}

migrate_report() {
  local n="$1" left labelled expect=""
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] migrate: ${n} name(s) would be detached; nothing was changed"
    return 0
  fi
  log "migrate: ${n} name(s) processed; every baseline object kept its UID, counts as in the baseline"
  left="$(kc -n kube-system get addons.k3s.cattle.io -o name)" || die "cannot list the K3s Addons"
  left="$(awk -F / -v re="${MIGRATE_ALLOW_RE}" '$NF ~ re {printf "%s ", $NF}' <<<"${left}")"
  [[ "${left}" != "${MIGRATE_EXCLUDED} " ]] || expect="(expected until DESIGN M7a: teknoir-node migrate --argo)"
  log "migrate: Teknoir Addons left: ${left:-none}${expect}"
  labelled="$(kc get customresourcedefinitions.apiextensions.k8s.io,namespaces -l objectset.rio.cattle.io/hash \
    -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}{"\n"}{end}')" \
    || die "cannot list the K3s-labelled CRDs and namespaces"
  labelled="$(awk -v re="${MIGRATE_ALLOW_RE}" '$2 ~ re {printf "%s (%s) ", $1, $2}' <<<"${labelled}")"
  log "migrate: CRDs/namespaces still owned by a Teknoir K3s file: ${labelled:-none}"
}

migrate_undo() {
  # migrate_undo <name> — put the newest retired copy back and drop the .skip;
  # K3s then re-applies the file and re-labels its objects
  local name="$1" latest="" f file
  migrate_allowed "${name}" || die "--undo ${name}: not a Teknoir K3s file name"
  for f in "${MIGRATE_RETIRED_ROOT}"/*/"${name}".yaml "${MIGRATE_RETIRED_ROOT}"/*/"${name}".yml "${MIGRATE_RETIRED_ROOT}"/*/"${name}".json; do
    [[ -f "${f}" ]] || continue
    if [[ -z "${latest}" || "$(basename "$(dirname "${f}")")" > "$(basename "$(dirname "${latest}")")" ]]; then
      latest="${f}"
    fi
  done
  [[ -n "${latest}" ]] || die "--undo ${name}: no retired copy under ${MIGRATE_RETIRED_ROOT}/<UTC>/ (orphan Addons have no file to restore)"
  file="${MIGRATE_MANIFESTS}/$(basename "${latest}")"
  [[ ! -e "${file}" ]] || die "--undo ${name}: ${file} exists already"
  if [[ "${name}" == "${MIGRATE_EXCLUDED}" ]] && in_cluster applications.argoproj.io "${MIGRATE_ARGO_APP}" "${MIGRATE_ARGO_APP_NS}"; then
    warn "--undo ${name}: the Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP} also manages ArgoCD; with the file back, K3s and ArgoCD both own it (every k3s restart re-applies the file, selfHeal reverts it)"
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would restore ${latest} to ${file} and remove ${file}.skip"
    return 0
  fi
  mv -- "${latest}" "${file}" || die "cannot restore ${latest}"
  # mv keeps the mtime, and K3s's deploy watcher skips a file whose mtime it
  # has seen before (since its last start): a second undo of the same file
  # would never be applied. A fresh mtime, the content stays as it was.
  touch -- "${file}" || die "cannot touch ${file}"
  rm -f -- "${file}.skip" || die "cannot remove ${file}.skip"
  changed "restored ${file} (undo); K3s re-adopts it"
  wait_for "K3s to re-apply ${name}" 180 migrate_addon_applied "${name}" "$(sha256_file "${file}")"
  log "${name}: K3s owns it again"
}

migrate_addon_applied() {
  [[ "$(kc -n kube-system get addons.k3s.cattle.io "$1" --ignore-not-found -o jsonpath='{.spec.checksum}')" == "$2" ]]
}

migrate_remove_old_bundles() {
  # The pre-fix bundle copies in the node user's home hold the CA key and the
  # Harbor/Keycloak secrets at mode 0644 (DESIGN M1, L-01).
  local user home d
  if [[ -n "${MIGRATE_LEGACY_HOME:-}" ]]; then
    home="${MIGRATE_LEGACY_HOME}"
  else
    user="teknoir"
    [[ "${NODE:-}" != *@* ]] || user="${NODE%%@*}"
    home="$(getent passwd "${user}" | cut -d: -f6)" || home=""
  fi
  if [[ -z "${home}" || ! -d "${home}" ]]; then
    warn "migrate: no home directory for the node user; old bundle copies not checked"
    return 0
  fi
  for d in "${home}"/teknoir-airgap-bundle-*; do
    [[ -e "${d}" || -L "${d}" ]] || continue
    if [[ "${DRY_RUN}" == "1" ]]; then
      log "[dry-run] would remove ${d} (pre-fix bundle copy with plaintext secrets)"
      continue
    fi
    if [[ -L "${d}" || ! -d "${d}" ]]; then
      rm -f -- "${d}" || die "cannot remove ${d}"
    else
      rm -rf --one-file-system -- "${d}" || die "cannot remove ${d}"
    fi
    changed "removed ${d} (pre-fix bundle copy with plaintext secrets)"
  done
}

migrate_retire_robot() {
  # M6: once ArgoCD can read the public Harbor `teknoir` project through the
  # credential-less repository Secret (argo chart), delete the robot repo-creds
  # Secret and then robot$argocd. Until then report what is missing and leave
  # both alone; a later `migrate` (after `up`) finishes it.
  local ns="${MIGRATE_REPO_CREDS_NS}" legacy="${MIGRATE_REPO_CREDS}" host repo k3s_hash anon rev backup t0
  host="${HARBOR_HOST:-harbor.${TEKNOIR_DOMAIN}}"
  repo="${host}/teknoir"
  if ! in_cluster secret "${legacy}" "${ns}"; then
    log "robot: repo-creds Secret ${ns}/${legacy} is gone"
    harbor_retire_robot
    return 0
  fi
  k3s_hash="$(kc -n "${ns}" get secret "${legacy}" -o jsonpath='{.metadata.labels.objectset\.rio\.cattle\.io/hash}')" \
    || die "cannot read Secret ${ns}/${legacy}"
  if [[ -n "${k3s_hash}" ]]; then
    log "robot: not yet: ${ns}/${legacy} is still owned by a K3s file (it is detached above unless --dry-run)"
    return 0
  fi
  # names only leave jq; the values stay in memory
  anon="$(kc -n "${ns}" get secrets -l argocd.argoproj.io/secret-type -o json)" || die "cannot list the ArgoCD repository Secrets"
  anon="$("${MIGRATE_JQ}" -r --arg url "${repo}" --arg skip "${legacy}" '
      [.items[]
       | select(.metadata.name != $skip)
       | select(.metadata.labels["argocd.argoproj.io/secret-type"] == "repository")
       | select((.data.username // "") == "" and (.data.password // "") == "")
       | select(((.data.url // "") | @base64d | sub("^oci://"; "") | sub("/+$"; "")) == $url)
       | .metadata.name][0] // empty' <<<"${anon}")" || die "cannot parse the ArgoCD repository Secrets"
  if [[ -z "${anon}" ]]; then
    log "robot: not yet: no credential-less ArgoCD repository Secret for ${repo} (it comes with the argo chart; run up first)"
    return 0
  fi
  if ! in_cluster applications.argoproj.io app-of-apps "${ns}"; then
    log "robot: not yet: no Application app-of-apps"
    return 0
  fi
  rev="$(kc -n "${ns}" get applications.argoproj.io app-of-apps -o jsonpath='{.spec.source.targetRevision}')" \
    || die "cannot read Application app-of-apps"
  if ! migrate_anonymous_pull "${repo}/app-of-apps:${rev}"; then
    log "robot: not yet: an anonymous pull of ${repo}/app-of-apps:${rev} fails (project teknoir must be public: run up)"
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] robot: would delete Secret ${ns}/${legacy} (ArgoCD then uses ${anon}), verify app-of-apps, then delete robot\$argocd"
    return 0
  fi
  # Keep a copy in memory only, to put back if ArgoCD cannot read the chart without it.
  backup="$(kc -n "${ns}" get secret "${legacy}" -o json)" || die "cannot read Secret ${ns}/${legacy}"
  backup="$("${MIGRATE_JQ}" -c 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])' <<<"${backup}")" \
    || die "cannot copy Secret ${ns}/${legacy}"
  "${MIGRATE_JQ}" -e '.kind == "Secret" and (.data | length > 0)' <<<"${backup}" >/dev/null || die "the in-memory copy of ${ns}/${legacy} is incomplete; not deleting it"
  t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  kc -n "${ns}" delete secret "${legacy}" >/dev/null || die "cannot delete Secret ${ns}/${legacy}"
  if ! migrate_argocd_reads_anonymously "${ns}" "${t0}"; then
    printf '%s' "${backup}" | kc create -f - >/dev/null \
      || die "ArgoCD cannot read app-of-apps without ${legacy}, and putting it back FAILED: restore it from the backup (OPERATE.md)"
    backup=""
    die "ArgoCD cannot read app-of-apps without ${legacy}; the Secret was put back. Check the repository Secret ${anon} and the Harbor project teknoir"
  fi
  backup=""
  changed "deleted the robot repo-creds Secret ${ns}/${legacy}; ArgoCD reads ${repo} anonymously"
  harbor_retire_robot
}

migrate_anonymous_pull() {
  # migrate_anonymous_pull <ref> — 0 when <ref> can be read without credentials
  local cfg rc=0 crane
  crane="$(migrate_tool crane)" || exit 1
  cfg="$(mktemp -d)" || die "mktemp failed"
  DOCKER_CONFIG="${cfg}" "${crane}" manifest "$1" >/dev/null 2>&1 || rc=$?
  rm -rf -- "${cfg}"
  return "${rc}"
}

migrate_argocd_reads_anonymously() {
  # Hard-refresh app-of-apps and wait until ArgoCD has compared it again after
  # <since>; 1 when the comparison reports an error (or never happens).
  local ns="$1" since="$2" deadline state reconciled errors status refresh
  kc -n "${ns}" annotate applications.argoproj.io app-of-apps argocd.argoproj.io/refresh=hard --overwrite >/dev/null \
    || return 1
  deadline=$(( $(date +%s) + MIGRATE_ARGOCD_TIMEOUT ))
  while (( $(date +%s) < deadline )); do
    sleep 5
    state="$(kc -n "${ns}" get applications.argoproj.io app-of-apps -o json | "${MIGRATE_JQ}" -r '
        [(.status.reconciledAt // ""),
         ([(.status.conditions // [])[] | select(.type | test("Error$")) | .type] | join(",")),
         (.status.sync.status // ""),
         (.metadata.annotations["argocd.argoproj.io/refresh"] // "")] | join("|")')" || continue
    IFS='|' read -r reconciled errors status refresh <<<"${state}"
    [[ -z "${refresh}" && -n "${reconciled}" && ! "${reconciled}" < "${since}" ]] || continue
    if [[ -n "${errors}" || "${status}" == "Unknown" || -z "${status}" ]]; then
      warn "app-of-apps after the refresh: sync ${status:-unknown}, conditions ${errors:-none}"
      return 1
    fi
    log "app-of-apps compared at ${reconciled} without the robot credential: ${status}"
    return 0
  done
  warn "ArgoCD did not compare app-of-apps within ${MIGRATE_ARGOCD_TIMEOUT}s"
  return 1
}

# --- DESIGN M7a: teknoir-argo ------------------------------------------------------

migrate_argo() {
  # Detach teknoir-argo.yaml once ArgoCD runs from its own Application (argo,
  # enabled in app-of-apps 0.0.4): the Application must be Synced/Healthy and
  # the argoproj CRDs protected before the K3s owner goes; afterwards no
  # ArgoCD pod may have restarted. Same recipe and baseline as the M3 pass.
  local ns state before after untracked
  MIGRATE_ONLY="${MIGRATE_EXCLUDED}"
  migrate_inventory
  if [[ -z "${MIGRATE_INVENTORY}" ]]; then
    log "migrate --argo: ${MIGRATE_ONLY} is detached already (no file, no Addon)"
    return 0
  fi
  # 1. ArgoCD runs from its own Application
  in_cluster applications.argoproj.io "${MIGRATE_ARGO_APP}" "${MIGRATE_ARGO_APP_NS}" \
    || die "migrate --argo: there is no Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP}. ArgoCD manages itself from app-of-apps 0.0.4 (DESIGN M7a): run up with that bundle first. Until then ${MIGRATE_ONLY}.yaml stays ArgoCD's owner"
  state="$(kc -n "${MIGRATE_ARGO_APP_NS}" get applications.argoproj.io "${MIGRATE_ARGO_APP}" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}')" || die "cannot read Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP}"
  [[ "${state}" == "Synced/Healthy" ]] \
    || die "migrate --argo: Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP} is ${state} (sync/health), not Synced/Healthy; ${MIGRATE_ONLY}.yaml stays until ArgoCD has adopted itself"
  ns="$(kc -n "${MIGRATE_ARGO_APP_NS}" get applications.argoproj.io "${MIGRATE_ARGO_APP}" -o jsonpath='{.spec.destination.namespace}')" \
    || die "cannot read Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP}"
  ns="${ns:-${MIGRATE_ARGO_APP_NS}}"
  log "migrate --argo: Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP} is Synced/Healthy (ArgoCD in ${ns})"
  # 2. its CRDs survive any prune or cascade once ArgoCD is their only owner
  migrate_argo_crds_protected || die "migrate --argo: argoproj CRD(s) without Prune=false,Delete=false: ${MIGRATE_UNPROTECTED}; the argo chart's crds.annotations must set both before ArgoCD is their only owner"
  # 3. which pods must not restart
  migrate_argo_pods "${ns}"
  before="${MIGRATE_PODS}"
  [[ -n "${before}" ]] || die "migrate --argo: no running ArgoCD pod (label app.kubernetes.io/part-of=argocd) in ${ns}"
  log "migrate --argo: $(grep -c . <<<"${before}") running ArgoCD pod(s) recorded by UID"
  # 4. the M3 recipe for this one name, with the baseline check
  migrate_detach_all
  [[ "${DRY_RUN}" != "1" ]] || return 0
  # 5. nothing restarted, the CRDs are still protected, the Application is fine
  log "migrate --argo: waiting ${MIGRATE_ARGO_SETTLE}s before comparing the ArgoCD pods"
  sleep "${MIGRATE_ARGO_SETTLE}"
  migrate_argo_pods "${ns}"
  after="${MIGRATE_PODS}"
  [[ "${after}" == "${before}" ]] \
    || die "migrate --argo: the ArgoCD pods changed during the detach (gone or new: $(comm -3 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | tr -d '\t' | cut -d '|' -f1 | tr '\n' ' ')); check ArgoCD before anything else"
  migrate_argo_crds_protected || die "migrate --argo: argoproj CRD(s) lost Prune=false,Delete=false: ${MIGRATE_UNPROTECTED}"
  migrate_argo_untracked
  untracked="${MIGRATE_UNTRACKED}"
  [[ -z "${untracked}" ]] \
    || warn "migrate --argo: these objects of ${MIGRATE_ONLY}.yaml are not in the Application ${MIGRATE_ARGO_APP} and now have no owner (left in place; delete them by hand once you know they are unused): ${untracked}"
  state="$(kc -n "${MIGRATE_ARGO_APP_NS}" get applications.argoproj.io "${MIGRATE_ARGO_APP}" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}')" || die "cannot read Application ${MIGRATE_ARGO_APP_NS}/${MIGRATE_ARGO_APP}"
  [[ "${state}" == "Synced/Healthy" ]] || warn "migrate --argo: Application ${MIGRATE_ARGO_APP} is now ${state}; check it in ArgoCD"
  log "migrate --argo: done; ArgoCD's pods kept their UIDs and ${MIGRATE_ARGO_APP} is its only owner"
}

migrate_argo_pods() {
  # migrate_argo_pods <ns> — MIGRATE_PODS: sorted "name|uid" of the running
  # ArgoCD pods. Not for $(...): dies.
  local out
  out="$(kc -n "$1" get pods -l app.kubernetes.io/part-of=argocd -o json)" || die "cannot list the ArgoCD pods in $1"
  MIGRATE_PODS="$("${MIGRATE_JQ}" -r '.items[] | select(.status.phase == "Running") | "\(.metadata.name)|\(.metadata.uid)"' <<<"${out}" | sort)" \
    || die "cannot parse the ArgoCD pods"
}

migrate_argo_crds_protected() {
  # 0 when every argoproj.io CRD (at least one) carries Prune=false and
  # Delete=false; MIGRATE_UNPROTECTED names the others. Dies on errors.
  local out
  out="$(kc get customresourcedefinitions.apiextensions.k8s.io -o json)" || die "cannot list the CRDs"
  MIGRATE_UNPROTECTED="$("${MIGRATE_JQ}" -r '
      [.items[] | select(.spec.group == "argoproj.io")] as $c
      | if ($c | length) == 0 then "(no argoproj.io CRD found)"
        else [$c[] | select(((.metadata.annotations["argocd.argoproj.io/sync-options"] // "") | split(",") | map(gsub("\\s"; ""))) as $o
                            | ($o | index("Prune=false")) == null or ($o | index("Delete=false")) == null)
                   | .metadata.name] | join(" ") end' <<<"${out}")" || die "cannot parse the CRDs"
  [[ -z "${MIGRATE_UNPROTECTED}" ]]
}

migrate_argo_untracked() {
  # MIGRATE_UNTRACKED: baseline objects without the argo Application's
  # tracking annotation (ArgoCD's default annotation tracking: "<app>:...")
  local res out
  MIGRATE_UNTRACKED=""
  for res in ${MIGRATE_BASE_RES}; do
    out="$(kc get "${res}" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}')" \
      || die "cannot list ${res}"
    MIGRATE_UNTRACKED+="$(awk -F '|' -v r="${res}" -v app="${MIGRATE_ARGO_APP}" '
        NR == FNR { if ($1 == r) want[$2 "|" $3] = 1; next }
        ($1 "|" $2) in want && $3 !~ ("^([^:]*_)?" app ":") { printf "%s %s%s; ", r, ($1 == "" ? "" : $1 "/"), $2 }' \
      <(printf '%s\n' "${MIGRATE_BASE_OBJS}") <(printf '%s\n' "${out}"))"
  done
}
