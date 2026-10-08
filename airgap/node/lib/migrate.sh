# shellcheck shell=bash
# shellcheck disable=SC2154  # DRY_RUN, K3S_DATA_DIR, NODE, TEKNOIR_DOMAIN: common.sh and the site env
#
# lib/migrate.sh — `teknoir-node migrate`: the one-time move of the live
# teknoir-local off K3s auto-deploy files (docs/airgap/DESIGN.md M3, M6, I-13).
# TEMPORARY: delete this file once teknoir-local is migrated (M8).
#
#   teknoir-node migrate [--dry-run]     detach every Teknoir K3s file, remove the
#                                        pre-fix bundle copies on the node, retire
#                                        the Harbor robot once ArgoCD pulls anonymously
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
#   5. assert that every one of those objects still exists with the same UID and no
#      K3s label, and that the CRD and Namespace counts equal the baseline. The
#      first mismatch stops the run.
# Order: orphan Addons (file gone), legacy manifest-*-secret, teknoir-*-secret,
# 00-teknoir-namespaces, teknoir-coredns-custom and teknoir-app-of-apps, the CRD
# files, then any other allow-listed name. teknoir-argo is never detached here
# (DESIGN M7a). Only allow-listed names are touched, never K3s's packaged addons.
# Every step is idempotent: a re-run (also after a failure) resumes.

MIGRATE_ALLOW_RE='^(teknoir-.+|00-teknoir-.+|05-teknoir-.+|10-teknoir-.+|manifest-.+-secret|app-of-apps)$'
MIGRATE_EXCLUDED="teknoir-argo"
MIGRATE_STRIP_PATCH='{"metadata":{"labels":{"objectset.rio.cattle.io/hash":null},"annotations":{"objectset.rio.cattle.io/applied":null,"objectset.rio.cattle.io/id":null,"objectset.rio.cattle.io/owner-gvk":null,"objectset.rio.cattle.io/owner-name":null,"objectset.rio.cattle.io/owner-namespace":null}}}'
MIGRATE_REPO_CREDS_NS="teknoir-system"
MIGRATE_REPO_CREDS="argocd-harbor-repo"
MIGRATE_ARGOCD_TIMEOUT="${MIGRATE_ARGOCD_TIMEOUT:-180}"

cmd_migrate() {
  local -a undo=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --undo) [[ $# -ge 2 ]] || die "--undo needs a name"; undo+=("$2"); shift 2 ;;
      --undo=*) undo+=("${1#*=}"); shift ;;
      -h|--help) migrate_usage; return 0 ;;
      *) die "migrate: unknown argument: $1 (see: teknoir-node migrate --help)" ;;
    esac
  done
  migrate_init
  local name
  if [[ ${#undo[@]} -gt 0 ]]; then
    for name in "${undo[@]}"; do
      migrate_undo "${name}"
    done
    return 0
  fi
  migrate_detach_all
  migrate_remove_old_bundles
  migrate_retire_robot
}

migrate_usage() {
  cat >&2 <<'EOF'
Usage: teknoir-node migrate [--dry-run]
       teknoir-node migrate --undo NAME [--undo NAME]...

Detaches the Teknoir K3s auto-deploy files (DESIGN M3): .skip guard, file moved to
<data-dir>/server/manifests-retired/<UTC>/, K3s labels stripped, Addon deleted,
object UIDs asserted. Then removes ~<user>/teknoir-airgap-bundle-* and, once ArgoCD
reads the public Harbor project without credentials, the robot repo-creds Secret
and robot$argocd (M6). Safe to re-run. --undo NAME puts a detached file back.
EOF
}

migrate_init() {
  local data="${K3S_DATA_DIR:-/opt/k3s}"
  MIGRATE_MANIFESTS="${data}/server/manifests"
  MIGRATE_RETIRED_ROOT="${data}/server/manifests-retired"
  MIGRATE_RETIRED="${MIGRATE_RETIRED_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
  [[ -d "${MIGRATE_MANIFESTS}" ]] || die "no K3s manifests dir ${MIGRATE_MANIFESTS} (K3S_DATA_DIR=${data})"
  MIGRATE_KINDS="$(kc api-resources --no-headers)" || die "cannot list the API resources"
  # "group/Kind" per served resource (APIVERSION is the third column from the end)
  MIGRATE_KINDS="$(awk '{v = $(NF-2); g = (index(v, "/") ? substr(v, 1, index(v, "/") - 1) : ""); print g "/" $NF}' <<<"${MIGRATE_KINDS}")"
}

migrate_allowed() {
  [[ "$1" =~ ${MIGRATE_ALLOW_RE} ]]
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

migrate_counts() {
  # sets MIGRATE_COUNTS to the CRD and Namespace counts (not for $(...): dies)
  local crds nss
  crds="$(kc get customresourcedefinitions.apiextensions.k8s.io -o name)" || die "cannot list the CRDs"
  nss="$(kc get namespaces -o name)" || die "cannot list the namespaces"
  MIGRATE_COUNTS="crds=$(grep -c . <<<"${crds}") namespaces=$(grep -c . <<<"${nss}")"
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
  rows="$(jq -r '.items[] | [.metadata.name, (.metadata.annotations["addon.k3s.cattle.io/gvks"] // ""), (.spec.source // "")] | map(gsub("[|\n]"; " ")) | join("|")' <<<"${addons}")" \
    || die "cannot parse the K3s Addons"
  while IFS='|' read -r name gvks src; do
    [[ -n "${name}" ]] || continue
    migrate_allowed "${name}" || continue
    [[ "${name}" != "${MIGRATE_EXCLUDED}" ]] || continue
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
    [[ "${name}" != "${MIGRATE_EXCLUDED}" ]] || continue
    [[ -z "${seen["${name}"]:-}" ]] || continue
    lines+="$(migrate_class "${name}" 1 0)|${name}|${base}|0|"$'\n'
  done
  MIGRATE_INVENTORY="$(sort -t '|' -k1,1n -k2,2 <<<"${lines}" | sed '/^$/d')"
}

migrate_detach_all() {
  local inventory class name base addon gvks baseline n=0 last_class=""
  migrate_inventory
  inventory="${MIGRATE_INVENTORY}"
  migrate_counts
  baseline="${MIGRATE_COUNTS}"
  log "migrate: baseline ${baseline}"
  if [[ -z "${inventory}" ]]; then
    log "migrate: no Teknoir K3s files or Addons left to detach (${MIGRATE_EXCLUDED} is migrated in M7)"
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
  while IFS='|' read -r class name base addon gvks; do
    [[ -n "${name}" ]] || continue
    migrate_detach "${name}" "${base}" "${addon}" "${gvks}"
    n=$((n + 1))
    if [[ "${DRY_RUN}" != "1" ]]; then
      migrate_counts
      [[ "${MIGRATE_COUNTS}" == "${baseline}" ]] \
        || die "migrate: object counts changed after ${name}: ${MIGRATE_COUNTS}, baseline ${baseline}; stopping (undo: teknoir-node migrate --undo ${name})"
    fi
  done <<<"${inventory}"
  migrate_report "${baseline}" "${n}"
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
  local baseline="$1" n="$2" left labelled
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] migrate: ${n} name(s) would be detached; nothing was changed"
    return 0
  fi
  migrate_counts
  log "migrate: ${n} name(s) processed; counts ${MIGRATE_COUNTS} (baseline ${baseline})"
  left="$(kc -n kube-system get addons.k3s.cattle.io -o name)" || die "cannot list the K3s Addons"
  left="$(awk -F / -v re="${MIGRATE_ALLOW_RE}" '$NF ~ re {printf "%s ", $NF}' <<<"${left}")"
  log "migrate: Teknoir Addons left: ${left:-none}$([[ "${left}" == "${MIGRATE_EXCLUDED} " ]] && echo "(expected: migrated in M7)")"
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
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would restore ${latest} to ${file} and remove ${file}.skip"
    return 0
  fi
  mv -- "${latest}" "${file}" || die "cannot restore ${latest}"
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
  # names only leave jq; the values stay in the pipe
  anon="$(kc -n "${ns}" get secrets -l argocd.argoproj.io/secret-type -o json | jq -r --arg url "${repo}" --arg skip "${legacy}" '
      [.items[]
       | select(.metadata.name != $skip)
       | select(.metadata.labels["argocd.argoproj.io/secret-type"] == "repository")
       | select((.data.username // "") == "" and (.data.password // "") == "")
       | select(((.data.url // "") | @base64d | sub("^oci://"; "") | sub("/+$"; "")) == $url)
       | .metadata.name][0] // empty')" || die "cannot list the ArgoCD repository Secrets"
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
  backup="$(kc -n "${ns}" get secret "${legacy}" -o json | jq -c 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])')" \
    || die "cannot read Secret ${ns}/${legacy}"
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
  crane="${NODE_ROOT}/bin/crane"
  [[ -x "${crane}" ]] || crane="$(command -v crane)" || die "crane not found (node/bin/crane)"
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
    state="$(kc -n "${ns}" get applications.argoproj.io app-of-apps -o json | jq -r '
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
