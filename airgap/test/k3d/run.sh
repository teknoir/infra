#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# run.sh — K3s ownership suite (docs/airgap/DESIGN.md, test plan section 2).
#
# Proves, on the live K3s version, which K3s actions delete objects and which
# do not. The airgap design depends on these semantics: they must pass before
# any step on the live env (M0).
#
#   T1   a manifests-dir file creates an Addon; its objects carry the objectset
#        hash label and owner annotations (and no ownerReferences)
#   T2   HAZARD: dropping an object from a file deletes it, Prune=false or not
#   T3   deleting a file leaves its objects and its Addon; a restart neither
#        re-creates nor removes them
#   T4   detach recipe (.skip, move, strip, delete Addon) keeps every object
#        across restarts; an old file next to the .skip is ignored; undo
#        re-adopts the objects
#   T4N  control for T4: without the strip, an Addon of the same name that comes
#        back garbage-collects the old objects (why the strip is mandatory)
#   T5   a restart re-applies every file: an edit to a file-owned Secret is
#        reverted (why secrets must not be K3s files)
#   T6   ArgoCD adopts a one-shot server-side-applied render (field manager
#        argocd-controller) without restarting pods; the CRDs become Synced
#        resources of the Application (ArgoCD 3.5 writes no tracking-id on
#        CRDs) and keep Prune=false;
#        removing a CRD from a chart and deleting the Application keep objects
#        [needs T6_ISTIO_CHART; pulls ArgoCD, istio and registry:2 images]
#   T9   migration rehearsal: a fixture of the live teknoir-local K3s layout,
#        then `teknoir-node migrate` (dry-run, run, re-run, --undo), then a
#        restart: nothing lost, no Teknoir Addons left but teknoir-argo
#        [needs airgap/node/bin/teknoir-node with the migrate command]
#
# T1-T5 and T4N share one cluster; T6 and T9 each get a fresh cluster, because
# both install the same CRD names (istio, argoproj) by different means.
#
# Usage: airgap/test/k3d/run.sh [--list] [--keep] [--reuse] [TEST...]
#   (default: all tests; T6/T9 are skipped when their inputs are missing)
#   --keep    do not delete the clusters afterwards (debugging)
#   --reuse   use an existing cluster of the same name instead of refusing
# Environment:
#   K3S_IMAGE        default rancher/k3s:v1.33.5-k3s1 (the live version)
#   K3D_CLUSTER      cluster name prefix, default k3sown (contexts k3d-<name>)
#   K3D_WORK         work dir, default ${TMPDIR:-/tmp}/teknoir-airgap-k3d
#   K3D_QUIET        seconds to wait for "nothing happens" checks (default 35;
#                    K3s rescans its manifests dir every 15 s)
#   T6_ISTIO_CHART   istio chart dir or .tgz (gitops charts/istio >= 0.0.3)
#   T6_ARGO_CHART    ArgoCD chart dir or .tgz; default: upstream argo-cd
#                    ${T6_ARGOCD_CHART_VERSION:-10.4.0} (what infra charts/argo pins)
#   T9_NODE_DIR      node payload dir, default <repo>/airgap/node
#
# Every kubectl call passes --context k3d-<name> and a kubeconfig in the work
# dir; the default kubeconfig is never modified.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
TL_NAME=k3d
# shellcheck source=../lib/testlib.sh
source "${HERE}/../lib/testlib.sh"

K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
PREFIX="${K3D_CLUSTER:-k3sown}"
WORK_BASE="${K3D_WORK:-${TMPDIR:-/tmp}/teknoir-airgap-k3d}"
QUIET="${K3D_QUIET:-35}"
K3S_MANIFESTS=/var/lib/rancher/k3s/server/manifests
IN_MAN="${K3S_MANIFESTS}/teknoir"   # set per cluster by use_cluster
KEEP=0 REUSE=0
ALL_TESTS=(T1 T2 T3 T4 T4N T5 T6 T9)
# Names of the Teknoir files and Addons on the live node (I-13 allow-list).
TEKNOIR_ADDON_RE='^(teknoir-.*|00-teknoir-.*|05-teknoir-.*|10-teknoir-.*|manifest-.*-secret|app-of-apps)$'

# Set by use_cluster:
CLUSTER="" CTX="" SERVER="" WORK="" MAN="" RETIRED=""
declare -a CREATED_CLUSTERS=()

usage() { sed -n '3,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# cluster lifecycle
# ---------------------------------------------------------------------------
need() { local t; for t in "$@"; do command -v "${t}" >/dev/null 2>&1 || tl_die "missing tool: ${t}"; done; }

kc() { kubectl --context "${CTX}" "$@"; }

use_cluster() {
  # use_cluster <name> [top] [disable] — create (or with --reuse adopt) cluster <name>.
  # The work dir's manifests/ is mounted at <manifests>/teknoir, so K3s keeps
  # its own packaged files out of it; with "top" it is the manifests dir
  # itself, as on the node (T9: migrate only accepts top-level files).
  # <disable> is the K3s --disable list (default traefik,servicelb,metrics-server).
  CLUSTER="$1" CTX="k3d-$1" SERVER="k3d-$1-server-0"
  local disable="${3:-traefik,servicelb,metrics-server}"
  if [[ "${2:-}" == top ]]; then IN_MAN="${K3S_MANIFESTS}"; else IN_MAN="${K3S_MANIFESTS}/teknoir"; fi
  WORK="${WORK_BASE}/$1" MAN="${WORK_BASE}/$1/manifests" RETIRED="${WORK_BASE}/$1/manifests-retired"
  export KUBECONFIG="${WORK}/kubeconfig"
  local exists
  exists="$(k3d cluster list -o json | jq -r --arg c "${CLUSTER}" '[.[] | select(.name == $c)] | length')"
  if [[ "${exists}" != 0 ]]; then
    (( REUSE )) || tl_die "k3d cluster ${CLUSTER} already exists; delete it (k3d cluster delete ${CLUSTER}) or pass --reuse"
    [[ -d "${MAN}" ]] || tl_die "--reuse: ${MAN} is missing; this cluster was not created by run.sh"
    tl_log "reusing cluster ${CLUSTER}"
  else
    rm -rf "${WORK}"
    mkdir -p "${MAN}" "${RETIRED}"
    tl_log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE}); manifests dir ${MAN} -> ${IN_MAN}"
    k3d cluster create "${CLUSTER}" --image "${K3S_IMAGE}" --servers 1 --agents 0 --no-lb \
      --k3s-arg "--disable=${disable}@server:0" \
      --volume "${MAN}:${IN_MAN}@server:0" \
      --kubeconfig-update-default=false --kubeconfig-switch-context=false \
      --wait --timeout 300s >/dev/null
  fi
  CREATED_CLUSTERS+=("${CLUSTER}")
  k3d kubeconfig get "${CLUSTER}" > "${KUBECONFIG}"
  chmod 600 "${KUBECONFIG}"
  wait_until 180 kc get --raw /readyz >/dev/null 2>&1 || tl_die "API of ${CLUSTER} not ready"
  local want got
  want="${K3S_IMAGE##*:}"; want="${want/-k3s/+k3s}"
  got="$(kc version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)"
  [[ "${got}" == "${want}" ]] || tl_die "server version ${got}, expected ${want}"
  # The sentinel tells restart_k3s when K3s has re-applied its files.
  if [[ ! -f "${MAN}/zz-k3d-sentinel.yaml" ]]; then
    put_manifest zz-k3d-sentinel <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: zz-k3d-sentinel
  namespace: kube-system
data:
  stamp: from-file
EOF
    wait_applied zz-k3d-sentinel 120 || tl_die "K3s never applied the sentinel file; is ${MAN} mounted?"
  fi
}

drop_cluster() {
  local c="$1" d="${WORK_BASE:?}/$1"
  (( KEEP )) && { tl_log "keeping cluster ${c} (--keep); kubeconfig ${d}/kubeconfig"; return 0; }
  k3d cluster delete "${c}" >/dev/null 2>&1 || tl_warn "k3d cluster delete ${c} failed"
  if ! rm -rf "${d}" 2>/dev/null; then
    # K3s wrote its packaged manifests (as root) into a top-level mount
    docker run --rm --entrypoint /bin/sh -v "${d}:/w" "${K3S_IMAGE}" -c 'rm -rf /w/manifests' >/dev/null 2>&1 || true
    rm -rf "${d}" || tl_warn "could not remove ${d}"
  fi
}

cleanup() {
  local c rc=$?
  for c in "${CREATED_CLUSTERS[@]}"; do drop_cluster "${c}"; done
  CREATED_CLUSTERS=()
  [[ -n "${PF_PID:-}" ]] && kill "${PF_PID}" 2>/dev/null
  return "${rc}"
}

finish_cluster() {
  # finish_cluster — delete the current cluster now (frees memory before the next)
  local c="${CLUSTER}" i
  drop_cluster "${c}"
  for i in "${!CREATED_CLUSTERS[@]}"; do [[ "${CREATED_CLUSTERS[i]}" == "${c}" ]] && unset 'CREATED_CLUSTERS[i]'; done
  CREATED_CLUSTERS=("${CREATED_CLUSTERS[@]}")
}

restart_k3s() {
  # docker restart, then wait until K3s has re-applied its manifests (sentinel)
  tl_log "restarting k3s (docker restart ${SERVER})"
  kc -n kube-system patch configmap zz-k3d-sentinel --type merge -p '{"data":{"stamp":"edited"}}' >/dev/null
  docker restart "${SERVER}" >/dev/null
  wait_until 180 kc get --raw /readyz >/dev/null 2>&1 || tl_die "API not ready after the restart"
  if ! wait_until 120 _sentinel_is from-file; then
    tl_warn "K3s did not re-apply the sentinel within 120 s; waiting ${QUIET} s instead"
    sleep "${QUIET}"
  fi
  sleep 5   # the startup pass applies every file within milliseconds of each other
}
_sentinel_is() { [[ "$(kc -n kube-system get configmap zz-k3d-sentinel -o jsonpath='{.data.stamp}' 2>/dev/null)" == "$1" ]]; }

# ---------------------------------------------------------------------------
# object helpers (rc != 0 from kubectl is fatal, never "absent")
# ---------------------------------------------------------------------------
put_manifest() {
  # put_manifest <name> < yaml — atomic write of <name>.yaml into the manifests dir
  local tmp="${WORK}/.put.$$"
  cat > "${tmp}"
  mv -f "${tmp}" "${MAN}/$1.yaml"
}

file_sha() { sha256sum "$1" | cut -d' ' -f1; }

wait_applied() {
  # wait_applied <name> [timeout] — until Addon <name> has the file's checksum
  local want
  want="$(file_sha "${MAN}/$1.yaml")"
  wait_until "${2:-120}" _addon_checksum_is "$1" "${want}"
}
_addon_checksum_is() { [[ "$(kc -n kube-system get addons.k3s.cattle.io "$1" -o jsonpath='{.spec.checksum}' 2>/dev/null)" == "$2" ]]; }

exists() {
  # exists <resource> <name> [namespace]
  local out
  out="$(kc get "$1" "$2" ${3:+-n "$3"} --ignore-not-found -o name)" || tl_die "kubectl get $1 $2 ${3:-} failed"
  [[ -n "${out}" ]]
}
absent() { ! exists "$@"; }
addon_exists() { exists addons.k3s.cattle.io "$1" kube-system; }

uid_of() {
  # uid_of <resource> <name> [namespace] — empty when absent
  local out
  out="$(kc get "$1" "$2" ${3:+-n "$3"} --ignore-not-found -o jsonpath='{.metadata.uid}')" || tl_die "kubectl get $1 $2 failed"
  printf '%s' "${out}"
}

meta_of() {
  # meta_of <resource> <name> [namespace] — compact JSON of the K3s ownership metadata
  kc get "$1" "$2" ${3:+-n "$3"} -o json | jq -c '.metadata | {
      hash: (.labels["objectset.rio.cattle.io/hash"] // ""),
      owner: (.annotations["objectset.rio.cattle.io/owner-name"] // ""),
      ownerns: (.annotations["objectset.rio.cattle.io/owner-namespace"] // ""),
      ownergvk: (.annotations["objectset.rio.cattle.io/owner-gvk"] // ""),
      applied: ((.annotations // {}) | has("objectset.rio.cattle.io/applied")),
      refs: ((.ownerReferences // []) | length)}'
}

secret_key() { kc -n "$1" get secret "$2" -o jsonpath="{.data.$3}" | base64 -d; }
_secret_key_is() { [[ "$(secret_key "$1" "$2" "$3")" == "$4" ]]; }
cm_key() { kc -n "$1" get configmap "$2" -o jsonpath="{.data.$3}"; }

objset_labelled() {
  # objset_labelled <resource> <name> [ns] — true when the K3s hash label is present
  [[ -n "$(kc get "$1" "$2" ${3:+-n "$3"} -o jsonpath='{.metadata.labels.objectset\.rio\.cattle\.io/hash}')" ]]
}

crd_yaml() {
  # crd_yaml <plural> <group> <Kind> [version] — a minimal CRD document (version default v1)
  cat <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $1.$2
spec:
  group: $2
  names: {kind: $3, plural: $1, singular: $(tr '[:upper:]' '[:lower:]' <<<"$3")}
  scope: Namespaced
  versions:
  - name: ${4:-v1}
    served: true
    storage: true
    schema:
      openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
}

# ---------------------------------------------------------------------------
# the M3 detach recipe (reference implementation used by T4/T4N)
# ---------------------------------------------------------------------------
gvk_resource() {
  # "networking.k8s.io/v1, Kind=NetworkPolicy" -> NetworkPolicy.v1.networking.k8s.io
  # "/v1, Kind=Secret" -> Secret.v1.  (kubectl's kind.version.group form)
  local g="$1" gv kind group version
  gv="${g%%, Kind=*}" kind="${g##*Kind=}"
  group="${gv%/*}" version="${gv##*/}"
  printf '%s.%s.%s' "${kind}" "${version}" "${group}"
}

strip_addon_objects() {
  # strip_addon_objects <addon> — remove the K3s ownership label/annotations
  # from every object the Addon owns, per GVK in its gvks annotation
  local name="$1" gvks g res ns obj rows
  local -a list
  gvks="$(kc -n kube-system get addons.k3s.cattle.io "${name}" -o jsonpath='{.metadata.annotations.addon\.k3s\.cattle\.io/gvks}')"
  IFS=';' read -r -a list <<<"${gvks}"
  for g in "${list[@]}"; do
    res="$(gvk_resource "${g}")"
    rows="$(kc get "${res}" -A -l objectset.rio.cattle.io/hash -o json | jq -r --arg n "${name}" '
      .items[] | select(.metadata.annotations["objectset.rio.cattle.io/owner-name"] == $n
                    and .metadata.annotations["objectset.rio.cattle.io/owner-namespace"] == "kube-system")
               | [(.metadata.namespace // "-"), .metadata.name] | @tsv')"
    while IFS=$'\t' read -r ns obj; do
      [[ -n "${obj}" ]] || continue
      [[ "${ns}" == "-" ]] && ns=""
      kc label "${res}" "${obj}" ${ns:+-n "${ns}"} objectset.rio.cattle.io/hash- >/dev/null
      kc annotate "${res}" "${obj}" ${ns:+-n "${ns}"} objectset.rio.cattle.io/applied- objectset.rio.cattle.io/id- \
        objectset.rio.cattle.io/owner-gvk- objectset.rio.cattle.io/owner-name- objectset.rio.cattle.io/owner-namespace- >/dev/null
    done <<<"${rows}"
  done
}

detach_addon() {
  # detach_addon <name> [--no-strip] — (1) .skip (2) move (3) strip (4) delete Addon
  local name="$1" strip=1 dest
  [[ "${2:-}" == --no-strip ]] && strip=0
  : > "${MAN}/${name}.yaml.skip"
  if [[ -f "${MAN}/${name}.yaml" ]]; then
    dest="${RETIRED}/${name}"
    mkdir -p "${dest}"
    mv "${MAN}/${name}.yaml" "${dest}/${name}.yaml"
  fi
  (( strip )) && strip_addon_objects "${name}"
  kc -n kube-system delete addons.k3s.cattle.io "${name}" --ignore-not-found --wait=true >/dev/null
}

# ---------------------------------------------------------------------------
# T1
# ---------------------------------------------------------------------------
t1() {
  tl_case T1 "a K3s file creates an Addon whose objects carry the objectset hash label and owner annotations"
  put_manifest t1 <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: t1}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t1-cm, namespace: t1}
data: {k: v}
---
apiVersion: v1
kind: Secret
metadata: {name: t1-secret, namespace: t1}
stringData: {k: dummy-value}
---
$(crd_yaml t1widgets t1.teknoir.test T1Widget)
EOF
  if ! wait_applied t1; then fail "Addon kube-system/t1 never reached the file's checksum"; return 0; fi
  pass "Addon kube-system/t1 exists; spec.checksum is the file's sha256"
  local gvks g obj meta h first=""
  gvks="$(kc -n kube-system get addons.k3s.cattle.io t1 -o jsonpath='{.metadata.annotations.addon\.k3s\.cattle\.io/gvks}')"
  for g in "/v1, Kind=Namespace" "/v1, Kind=ConfigMap" "/v1, Kind=Secret" "apiextensions.k8s.io/v1, Kind=CustomResourceDefinition"; do
    if [[ ";${gvks};" == *";${g};"* ]]; then pass "Addon annotation addon.k3s.cattle.io/gvks lists ${g}"; else fail "gvks annotation lacks ${g}: ${gvks}"; fi
  done
  assert_eq "Addon spec.source is the file path inside the server" "${IN_MAN}/t1.yaml" \
    "$(kc -n kube-system get addons.k3s.cattle.io t1 -o jsonpath='{.spec.source}')"
  for obj in "namespace t1" "configmap t1-cm t1" "secret t1-secret t1" "crd t1widgets.t1.teknoir.test"; do
    # shellcheck disable=SC2086  # word splitting of the spec is intended
    meta="$(meta_of ${obj})"
    assert_eq "${obj}: owner annotations name the Addon" \
      '{"owner":"t1","ownerns":"kube-system","ownergvk":"k3s.cattle.io/v1, Kind=Addon","applied":true}' \
      "$(jq -c '{owner, ownerns, ownergvk, applied}' <<<"${meta}")"
    assert_eq "${obj}: no ownerReferences (K3s GC is its own apply GC, not Kubernetes cascading GC)" 0 "$(jq -r .refs <<<"${meta}")"
    h="$(jq -r .hash <<<"${meta}")"
    if [[ -z "${h}" ]]; then fail "${obj}: no objectset.rio.cattle.io/hash label"; continue; fi
    if [[ -z "${first}" ]]; then first="${h}"; pass "${obj}: has objectset.rio.cattle.io/hash=${h}"
    else assert_eq "${obj}: same hash label as the other objects of the Addon" "${first}" "${h}"; fi
  done
}

# ---------------------------------------------------------------------------
# T2
# ---------------------------------------------------------------------------
t2_file() {
  cat <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: t2}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t2-keep, namespace: t2}
data: {k: v}
EOF
  [[ "${1:-}" == with-secret ]] || return 0
  cat <<'EOF'
---
apiVersion: v1
kind: Secret
metadata:
  name: t2-drop
  namespace: t2
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
stringData: {k: dummy-value}
EOF
}

t2() {
  tl_case T2 "HAZARD: dropping an object from a K3s file deletes it, even with Prune=false,Delete=false"
  t2_file with-secret | put_manifest t2
  if ! wait_applied t2; then fail "Addon t2 never applied"; return 0; fi
  if exists secret t2-drop t2; then pass "Secret t2-drop exists (annotated Prune=false,Delete=false)"; else fail "Secret t2-drop was never created"; return 0; fi
  t2_file | put_manifest t2
  if ! wait_applied t2; then fail "Addon t2 never applied the shrunk file"; return 0; fi
  if wait_until 60 absent secret t2-drop t2; then
    pass "K3s garbage-collected Secret t2-drop when it left the file, ignoring Prune=false,Delete=false"
  else
    fail "Secret t2-drop survived: the K3s GC hazard was NOT observed (harness self-test failed)"
  fi
  assert_cmd "ConfigMap t2-keep (still in the file) is untouched" exists configmap t2-keep t2
}

# ---------------------------------------------------------------------------
# T3
# ---------------------------------------------------------------------------
t3() {
  tl_case T3 "deleting a K3s file leaves its objects and Addon; a restart neither re-creates nor removes them"
  put_manifest t3 <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: t3}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t3-a, namespace: t3}
data: {k: v}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t3-b, namespace: t3}
data: {k: v}
EOF
  if ! wait_applied t3; then fail "Addon t3 never applied"; return 0; fi
  local uid_a
  uid_a="$(uid_of configmap t3-a t3)"
  rm -f "${MAN}/t3.yaml"
  tl_log "file removed; waiting ${QUIET}s (more than two K3s rescans)"
  sleep "${QUIET}"
  assert_cmd "the Addon of a deleted file remains (an orphan Addon)" addon_exists t3
  assert_cmd "t3-a remains after its file is deleted" exists configmap t3-a t3
  assert_cmd "t3-b remains after its file is deleted" exists configmap t3-b t3
  kc -n t3 delete configmap t3-b >/dev/null
  restart_k3s
  assert_cmd "the orphan Addon t3 survives a restart (K3s never cleans up orphan Addons)" addon_exists t3
  assert_cmd "a restart does not re-create t3-b from the orphan Addon" absent configmap t3-b t3
  assert_eq "a restart neither removes nor re-creates t3-a (same uid)" "${uid_a}" "$(uid_of configmap t3-a t3)"
}

# ---------------------------------------------------------------------------
# T4
# ---------------------------------------------------------------------------
T4_OBJS=("namespace t4" "configmap t4-cm t4" "secret t4-secret t4" "crd t4things.t4.teknoir.test")

t4_uids() {
  local o
  # shellcheck disable=SC2086
  for o in "${T4_OBJS[@]}"; do printf '%s=%s\n' "${o}" "$(uid_of ${o})"; done
}

t4() {
  tl_case T4 "detach recipe keeps every object across restarts; an old file next to .skip is ignored; undo re-adopts"
  put_manifest t4 <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: t4}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t4-cm, namespace: t4}
data: {v: "1"}
---
apiVersion: v1
kind: Secret
metadata: {name: t4-secret, namespace: t4}
stringData: {k: dummy-value}
---
$(crd_yaml t4things t4.teknoir.test T4Thing)
EOF
  if ! wait_applied t4; then fail "Addon t4 never applied"; return 0; fi
  local before o labelled=0
  before="$(t4_uids)"
  detach_addon t4
  assert_cmd "(1) t4.yaml.skip exists" test -f "${MAN}/t4.yaml.skip"
  assert_cmd "(2) t4.yaml moved out of the manifests dir" test ! -e "${MAN}/t4.yaml" -a -f "${RETIRED}/t4/t4.yaml"
  assert_cmd "(4) Addon t4 deleted" absent addons.k3s.cattle.io t4 kube-system
  assert_eq "every object survives the detach (same uids)" "${before}" "$(t4_uids)"
  # shellcheck disable=SC2086
  for o in "${T4_OBJS[@]}"; do objset_labelled ${o} && labelled=$((labelled + 1)); done
  assert_eq "(3) no object carries the objectset hash label any more" 0 "${labelled}"

  restart_k3s
  assert_eq "every object survives a k3s restart after the detach" "${before}" "$(t4_uids)"
  assert_cmd "Addon t4 does not re-appear after the restart" absent addons.k3s.cattle.io t4 kube-system

  # An old bundle drops the old name next to the .skip, with other content:
  # changed data, one new object, and the Secret and CRD left out (applying
  # it would delete them).
  put_manifest t4 <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: t4}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t4-cm, namespace: t4}
data: {v: "2"}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t4-extra, namespace: t4}
data: {v: "2"}
EOF
  tl_log "old file dropped next to t4.yaml.skip; waiting ${QUIET}s"
  sleep "${QUIET}"
  t4_assert_ignored "while running"
  restart_k3s
  t4_assert_ignored "on the forced startup pass"

  # undo (what `migrate --undo t4` does): remove the stray file, restore the
  # retired one, then remove the .skip so K3s applies it again
  rm -f "${MAN}/t4.yaml"
  mv "${RETIRED}/t4/t4.yaml" "${MAN}/t4.yaml"
  rm -f "${MAN}/t4.yaml.skip"
  if wait_applied t4; then pass "undo: K3s re-creates Addon t4 from the restored file"; else fail "undo: Addon t4 not re-created"; return 0; fi
  assert_eq "undo re-adopts the existing objects without re-creating them (same uids)" "${before}" "$(t4_uids)"
  local owners=""
  # shellcheck disable=SC2086
  for o in "${T4_OBJS[@]}"; do owners+="$(meta_of ${o} | jq -r .owner) "; done
  assert_eq "undo: every object is owned by Addon t4 again" "t4 t4 t4 t4 " "${owners}"
}

t4_assert_ignored() {
  local when="$1"
  assert_cmd "${when}: no Addon t4 for a file next to its .skip" absent addons.k3s.cattle.io t4 kube-system
  assert_cmd "${when}: t4-extra from the ignored file is not created" absent configmap t4-extra t4
  assert_eq "${when}: t4-cm keeps its value" 1 "$(cm_key t4 t4-cm v)"
  assert_cmd "${when}: t4-secret (left out of the ignored file) still exists" exists secret t4-secret t4
}

# ---------------------------------------------------------------------------
# T4N
# ---------------------------------------------------------------------------
t4n() {
  tl_case T4N "control: without the strip, an Addon of the same name that comes back GCs the old objects"
  put_manifest t4n <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: t4n}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t4n-old, namespace: t4n}
data: {k: v}
EOF
  if ! wait_applied t4n; then fail "Addon t4n never applied"; return 0; fi
  detach_addon t4n --no-strip
  sleep 10
  assert_cmd "observed: deleting a still-labelled Addon does not by itself delete its objects" exists configmap t4n-old t4n
  assert_cmd "the unstripped object keeps its hash label" objset_labelled configmap t4n-old t4n
  # the hazard: the same name comes back without the guard (an old bundle,
  # or a .skip removed), with other content
  rm -f "${MAN}/t4n.yaml.skip"
  put_manifest t4n <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: t4n}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: t4n-new, namespace: t4n}
data: {k: v}
EOF
  if ! wait_applied t4n; then fail "Addon t4n never re-applied"; return 0; fi
  if wait_until 60 absent configmap t4n-old t4n; then
    pass "the returning Addon t4n GC'd the unstripped t4n-old (the hash label derives from the Addon name): the strip step is mandatory"
  else
    fail "t4n-old survived: an unstripped object is not GC'd by a returning Addon of the same name (update the design rationale)"
  fi
}

# ---------------------------------------------------------------------------
# T5
# ---------------------------------------------------------------------------
t5() {
  tl_case T5 "a restart re-applies K3s files: an edit to a file-owned Secret is reverted"
  put_manifest t5 <<'EOF'
apiVersion: v1
kind: Namespace
metadata: {name: t5}
---
apiVersion: v1
kind: Secret
metadata: {name: t5-secret, namespace: t5}
stringData: {k: original}
EOF
  if ! wait_applied t5; then fail "Addon t5 never applied"; return 0; fi
  kc -n t5 patch secret t5-secret --type merge -p '{"stringData":{"k":"edited","extra":"added"}}' >/dev/null
  tl_log "Secret edited (a 'rotation'); waiting ${QUIET}s without a restart"
  sleep "${QUIET}"
  assert_eq "without a restart the edit stays (K3s re-applies only when the file changes)" edited "$(secret_key t5 t5-secret k)"
  restart_k3s
  if wait_until 60 _secret_key_is t5 t5-secret k original; then
    pass "the restart reverted the edited key to the file's value (a K3s-file secret cannot be rotated)"
  else
    fail "the restart did not revert the edit (k=$(secret_key t5 t5-secret k))"
  fi
  assert_eq "a key the file never had survives the re-apply (3-way merge)" added "$(secret_key t5 t5-secret extra)"
}

# ---------------------------------------------------------------------------
# T6 — ArgoCD adoption of a one-shot render
# ---------------------------------------------------------------------------
T6_ARGOCD_CHART_VERSION="${T6_ARGOCD_CHART_VERSION:-10.4.0}"
T6_REGISTRY_IMAGE="${T6_REGISTRY_IMAGE:-docker.io/library/registry:2.8.3}"
T6_REPO="registry.t6-registry.svc.cluster.local:5000/teknoir"
PF_PID=""

t6_ready() {
  [[ -n "${T6_ISTIO_CHART:-}" && -e "${T6_ISTIO_CHART}" ]] || {
    T6_WHY="set T6_ISTIO_CHART to the istio chart dir or .tgz (gitops G-01, renders its CRDs)"; return 1; }
  if ! command -v helm >/dev/null || ! command -v yq >/dev/null; then T6_WHY="needs helm and yq"; return 1; fi
}

t6_package() {
  # t6_package <chart dir|tgz> <outdir> — prints the path of the packaged .tgz.
  # A chart dir is copied first: dependency builds never write into the source.
  local src="$1" out="$2" copy
  if [[ -f "${src}" ]]; then cp "${src}" "${out}/"; printf '%s/%s' "${out}" "$(basename "${src}")"; return 0; fi
  copy="${out}/src-$(basename "${src}")"
  rm -rf "${copy}"
  cp -a "${src}" "${copy}"
  if [[ -f "${copy}/Chart.lock" || -n "$(yq '.dependencies // [] | length | select(. > 0)' "${copy}/Chart.yaml")" ]]; then
    helm dependency build "${copy}" >/dev/null
  fi
  helm package "${copy}" -d "${out}" | sed -n 's/^Successfully packaged chart and saved it to: //p'
}

t6_registry() {
  kc create namespace t6-registry --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc -n t6-registry apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: registry}
spec:
  selector: {matchLabels: {app: registry}}
  template:
    metadata: {labels: {app: registry}}
    spec:
      containers:
      - name: registry
        image: ${T6_REGISTRY_IMAGE}
        ports: [{containerPort: 5000}]
---
apiVersion: v1
kind: Service
metadata: {name: registry}
spec:
  selector: {app: registry}
  ports: [{port: 5000, targetPort: 5000}]
EOF
  kc -n t6-registry rollout status deploy/registry --timeout=300s >/dev/null
  local port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' 2>/dev/null || echo 15000)"
  kc -n t6-registry port-forward svc/registry "${port}:5000" >/dev/null 2>&1 &
  PF_PID=$!
  wait_until 30 curl -fsS "http://127.0.0.1:${port}/v2/" -o /dev/null 2>/dev/null || tl_die "registry port-forward not ready"
  T6_PUSH="oci://127.0.0.1:${port}/teknoir"
}

t6_push() { helm push "$1" "${T6_PUSH}" --plain-http >/dev/null; }

t6_argocd() {
  local render="${WORK}/t6/argocd.yaml"
  kc create namespace teknoir-system --dry-run=client -o yaml | kc apply -f - >/dev/null
  if [[ -n "${T6_ARGO_CHART:-}" ]]; then
    local tgz
    tgz="$(t6_package "${T6_ARGO_CHART}" "${WORK}/t6")"
    helm template argo "${tgz}" --namespace teknoir-system --include-crds > "${render}"
  else
    helm template argo argo-cd --repo https://argoproj.github.io/argo-helm --version "${T6_ARGOCD_CHART_VERSION}" \
      --namespace teknoir-system --include-crds \
      --set dex.enabled=false --set notifications.enabled=false --set applicationSet.enabled=false > "${render}"
  fi
  kc apply --server-side --field-manager=t6-setup --force-conflicts -f "${render}" >/dev/null
  kc -n teknoir-system rollout status statefulset -l app.kubernetes.io/name=argocd-application-controller --timeout=600s >/dev/null 2>&1 \
    || kc -n teknoir-system wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-application-controller --timeout=600s >/dev/null
  kc -n teknoir-system wait --for=condition=Available deploy --all --timeout=600s >/dev/null
  # credential-less repository config for the in-cluster OCI registry
  kc -n teknoir-system apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: t6-registry
  labels: {argocd.argoproj.io/secret-type: repository}
stringData:
  type: helm
  name: t6
  url: ${T6_REPO}
  enableOCI: "true"
  insecureOCIForceHttp: "true"
EOF
}

t6_app() {
  # t6_app <name> <namespace> <chart> <version> — the Application as app-of-apps renders it
  kc -n teknoir-system apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: $1}
spec:
  project: default
  destination: {namespace: $2, server: https://kubernetes.default.svc}
  source: {repoURL: ${T6_REPO}, chart: $3, targetRevision: $4}
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [ServerSideApply=true, CreateNamespace=true]
    retry: {limit: 10, backoff: {duration: 10s, factor: 2, maxDuration: 2m}}
  ignoreDifferences:
  - group: admissionregistration.k8s.io
    kind: ValidatingWebhookConfiguration
    jsonPointers: [/webhooks/0/clientConfig/caBundle, /webhooks/0/failurePolicy]
EOF
}

_app_synced_at() {
  # _app_synced_at <app> <revision> — last operation succeeded at <revision>
  local s
  s="$(kc -n teknoir-system get applications.argoproj.io "$1" -o json 2>/dev/null)" || return 1
  [[ "$(jq -r '.status.operationState.phase // ""' <<<"${s}")" == Succeeded ]] &&
    [[ "$(jq -r '.status.sync.revision // ""' <<<"${s}")" == "$2" ]]
}
_app_healthy_synced() {
  local s
  s="$(kc -n teknoir-system get applications.argoproj.io "$1" -o json 2>/dev/null)" || return 1
  [[ "$(jq -r '"\(.status.sync.status)/\(.status.health.status)"' <<<"${s}")" == Synced/Healthy ]]
}

pods_uids() { kc -n "$1" get pods -o json | jq -r '[.items[] | "\(.metadata.name)=\(.metadata.uid)"] | sort | join(" ")'; }

t6() {
  tl_case T6 "ArgoCD adopts the one-shot SSA render (argocd-controller): no pod restarts, CRDs adopted with Prune=false"
  mkdir -p "${WORK}/t6"
  local istio_tgz ver crds rest crd_names n uids_before managers
  istio_tgz="$(t6_package "${T6_ISTIO_CHART}" "${WORK}/t6")"
  ver="$(helm show chart "${istio_tgz}" | yq -r .version)"
  crds="${WORK}/t6/istio-crds.yaml" rest="${WORK}/t6/istio.yaml"
  helm template istio "${istio_tgz}" --namespace istio-system --include-crds > "${WORK}/t6/render.yaml"
  yq 'select(.kind == "CustomResourceDefinition")' "${WORK}/t6/render.yaml" > "${crds}"
  yq 'select(.kind != "CustomResourceDefinition" and .kind != null)' "${WORK}/t6/render.yaml" > "${rest}"
  crd_names="$(yq -r 'select(.kind == "CustomResourceDefinition") | .metadata.name' "${WORK}/t6/render.yaml" | grep -v -- '^---$' | sort || true)"
  n="$(grep -c . <<<"${crd_names}" || true)"
  if (( n == 0 )); then fail "istio chart ${ver} renders no CRDs; T6 needs the G-01 chart (>= 0.0.3)"; return 0; fi
  pass "istio ${ver} renders ${n} CRDs"

  tl_log "installing ArgoCD and an in-cluster OCI registry (pulls images)"
  t6_argocd
  t6_registry
  t6_push "${istio_tgz}"

  tl_log "one-shot: server-side apply of the render as argocd-controller"
  kc create namespace istio-system --dry-run=client -o yaml | kc apply -f - >/dev/null
  t6_secret_placeholders "${rest}"
  kc apply --server-side --field-manager=argocd-controller --force-conflicts -f "${crds}" >/dev/null
  kc wait --for=condition=Established -f "${crds}" --timeout=120s >/dev/null
  kc apply --server-side --field-manager=argocd-controller --force-conflicts -f "${rest}" >/dev/null
  if ! kc -n istio-system wait --for=condition=Available deploy/istiod --timeout=900s >/dev/null; then
    fail "istiod not Available after the one-shot apply"; return 0
  fi
  t6_reinject
  kc -n istio-system wait --for=condition=Available deploy --all --timeout=900s >/dev/null || fail "istio deployments not Available after the one-shot apply"
  uids_before="$(pods_uids istio-system)"

  t6_app istio istio-system istio "${ver}"
  if wait_until 900 _app_healthy_synced istio; then pass "Application istio is Synced/Healthy"; else fail "Application istio not Synced/Healthy within 15 min"; fi
  assert_eq "no istio-system pod was restarted or replaced by the adoption (pod UIDs)" "${uids_before}" "$(pods_uids istio-system)"
  # ArgoCD 3.5 writes no tracking-id annotation on CRDs (neither adopted nor
  # created ones; verified here and on teknoir-local's monitoring CRDs): a
  # CRD belongs to the app when the Application lists it as a resource.
  local name opts untracked=0 unprotected=0 app_crds
  app_crds="$(kc -n teknoir-system get applications.argoproj.io istio -o json |
    jq -r '.status.resources[]? | select(.kind == "CustomResourceDefinition" and .status == "Synced") | .name' | sort)"
  while read -r name; do
    [[ -n "${name}" ]] || continue
    opts="$(kc get crd "${name}" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}')"
    grep -qxF "${name}" <<<"${app_crds}" || { untracked=$((untracked + 1)); tl_warn "CRD ${name} is not a Synced resource of Application istio"; }
    [[ "${opts}" == *Prune=false* && "${opts}" == *Delete=false* ]] || { unprotected=$((unprotected + 1)); tl_warn "CRD ${name} sync-options=[${opts}]"; }
  done <<<"${crd_names}"
  assert_eq "every chart CRD is a Synced resource of Application istio" 0 "${untracked}"
  assert_eq "every chart CRD carries Prune=false,Delete=false" 0 "${unprotected}"
  managers="$(kc -n istio-system get deploy istiod -o json --show-managed-fields | jq -r '[(.metadata.managedFields // [])[] | select(.operation == "Apply") | .manager] | unique | join(",")')"
  assert_eq "istiod: the only Apply field manager is argocd-controller" argocd-controller "${managers}"

  # Removing a CRD from a chart must not delete it (Prune=false), on a mini chart
  t6_crd_chart 0.1.0 a b
  t6_crd_chart 0.2.0 a
  t6_app t6crd t6crd t6crd 0.1.0
  if wait_until 600 _app_synced_at t6crd 0.1.0; then pass "t6crd 0.1.0 synced (CRDs a and b)"; else fail "t6crd 0.1.0 did not sync"; fi
  kc -n teknoir-system patch applications.argoproj.io t6crd --type merge -p '{"spec":{"source":{"targetRevision":"0.2.0"}}}' >/dev/null
  if wait_until 600 _app_synced_at t6crd 0.2.0; then pass "t6crd 0.2.0 synced (CRD b removed from the chart)"; else fail "t6crd 0.2.0 did not sync"; fi
  assert_cmd "CRD b survives its removal from the chart (Prune=false), with prune: true" exists crd t6bs.t6.teknoir.test

  # Deleting the Application without a resources finalizer leaves everything
  local istiod_uid
  istiod_uid="$(uid_of deploy istiod istio-system)"
  kc -n teknoir-system delete applications.argoproj.io istio --wait=true >/dev/null
  sleep 10
  assert_eq "deleting Application istio (no finalizer) leaves istiod (same uid)" "${istiod_uid}" "$(uid_of deploy istiod istio-system)"
  local gone=0
  while read -r name; do [[ -z "${name}" ]] || exists crd "${name}" || gone=$((gone + 1)); done <<<"${crd_names}"
  assert_eq "deleting Application istio leaves every istio CRD" 0 "${gone}"
  [[ -n "${PF_PID}" ]] && { kill "${PF_PID}" 2>/dev/null || true; PF_PID=""; }
}

t6_secret_placeholders() {
  # t6_secret_placeholders <render> — stand-ins for what the node's secrets
  # phase (I-07) creates before the one-shot tiers: every non-optional Secret
  # a rendered Deployment mounts (istiod: teknoir-airgapped-wildcard-tls for
  # its JWKS CA) gets a throwaway self-signed TLS Secret when absent.
  local name d="${WORK}/t6/tls"
  for name in $(yq -r 'select(.kind == "Deployment") | .spec.template.spec.volumes[]? | select(.secret != null and .secret.optional != true) | .secret.secretName' "$1" | grep -v -- '^---$' | sort -u || true); do
    exists secret "${name}" istio-system && continue
    mkdir -p "${d}"
    ( umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=k3d T6 throwaway test cert" \
        -keyout "${d}/tls.key" -out "${d}/tls.crt" >/dev/null 2>&1 )
    cp "${d}/tls.crt" "${d}/ca.crt"
    kc -n istio-system create secret generic "${name}" --type=kubernetes.io/tls \
      --from-file="${d}/ca.crt" --from-file="${d}/tls.crt" --from-file="${d}/tls.key" >/dev/null
    rm -rf "${d}"
    tl_log "created the placeholder Secret istio-system/${name} (the node's secrets phase does this)"
  done
}

t6_reinject() {
  # Gateway pods created before istiod's injection webhook served keep the
  # unresolved image "auto" (ErrImagePull) until they are re-created.
  local pods
  pods="$(kc -n istio-system get pods -o json | jq -r '.items[] | select(any(.spec.containers[]; .image == "auto")) | .metadata.name')"
  [[ -n "${pods}" ]] || return 0
  tl_warn "$(wc -l <<<"${pods}") istio pod(s) were created before the injection webhook served (image \"auto\"); re-creating them. The one-shot istio tier (I-08) must handle this ordering (wait for istiod, then restart the gateways)."
  # shellcheck disable=SC2086  # one pod name per word
  kc -n istio-system delete pod ${pods} --wait=false >/dev/null
}

t6_crd_chart() {
  # t6_crd_chart <version> <crd letters...> — package and push a mini CRD chart
  local ver="$1" d="${WORK}/t6/t6crd-$1" l
  shift
  mkdir -p "${d}/templates"
  printf 'apiVersion: v2\nname: t6crd\nversion: %s\n' "${ver}" > "${d}/Chart.yaml"
  for l in "$@"; do
    crd_yaml "t6${l}s" t6.teknoir.test "T6${l^^}" |
      yq '.metadata.annotations."argocd.argoproj.io/sync-options" = "Prune=false,Delete=false"' > "${d}/templates/crd-${l}.yaml"
  done
  t6_push "$(helm package "${d}" -d "${WORK}/t6" | sed -n 's/^Successfully packaged chart and saved it to: //p')"
}

# ---------------------------------------------------------------------------
# T9 — migration rehearsal on the legacy fixture
# ---------------------------------------------------------------------------
# The fixture mirrors the live teknoir-local Addons (read-only inventory of
# 2026-10-08): 00-teknoir-namespaces, 00-teknoir-istio-crds,
# 05-teknoir-certmanager-crds, teknoir-coredns-custom, teknoir-app-of-apps,
# teknoir-argo, 9 canonical teknoir-*-secret files, 8 legacy
# manifest-*-secret duplicates, and 3 orphan Addons (10-teknoir-argo,
# app-of-apps, manifest-argocd-harbor-repo-secret). Values are random dummies.
# "<crd name> <Kind>" (the live names; the fixture schemas are minimal)
ISTIO_CRDS="authorizationpolicies.security.istio.io AuthorizationPolicy
destinationrules.networking.istio.io DestinationRule
envoyfilters.networking.istio.io EnvoyFilter
gateways.networking.istio.io Gateway
peerauthentications.security.istio.io PeerAuthentication
proxyconfigs.networking.istio.io ProxyConfig
requestauthentications.security.istio.io RequestAuthentication
serviceentries.networking.istio.io ServiceEntry
sidecars.networking.istio.io Sidecar
telemetries.telemetry.istio.io Telemetry
virtualservices.networking.istio.io VirtualService
wasmplugins.extensions.istio.io WasmPlugin
workloadentries.networking.istio.io WorkloadEntry
workloadgroups.networking.istio.io WorkloadGroup"
CERTMANAGER_CRDS="certificaterequests.cert-manager.io CertificateRequest
certificates.cert-manager.io Certificate
challenges.acme.cert-manager.io Challenge
clusterissuers.cert-manager.io ClusterIssuer
issuers.cert-manager.io Issuer
orders.acme.cert-manager.io Order"
ARGO_CRDS="applications.argoproj.io Application
applicationsets.argoproj.io ApplicationSet
appprojects.argoproj.io AppProject"
# canonical file name -> namespace/secret (type)
T9_SECRETS="teknoir-argocd-harbor-repo-secret teknoir-system/argocd-harbor-repo Opaque
teknoir-argocd-keycloak-secret teknoir-system/argocd-oidc-secret Opaque
teknoir-auth-ca-bundle-secret teknoir-auth/teknoir-root-ca-bundle Opaque
teknoir-ca-secret cert-manager/teknoir-root-ca kubernetes.io/tls
teknoir-harbor-secret teknoir-system/harbor-secret Opaque
teknoir-keycloak-db-secret teknoir-auth/keycloak-db-secret Opaque
teknoir-oauth2-proxy-redis-secret teknoir-auth/oauth2-proxy-redis-secret Opaque
teknoir-oauth2-proxy-secret teknoir-auth/oauth2-proxy-secret Opaque
teknoir-system-ca-bundle-secret teknoir-system/teknoir-root-ca-bundle Opaque"
T9_ORPHANS="10-teknoir-argo app-of-apps manifest-argocd-harbor-repo-secret"
declare -a T9_INVENTORY=()   # "resource name [namespace]" of every fixture object

t9_node_bin() { printf '%s/bin/teknoir-node' "${T9_NODE_DIR:-${REPO}/airgap/node}"; }

t9_ready() {
  [[ -x "$(t9_node_bin)" ]] || { T9_WHY="$(t9_node_bin) not found (node runner not implemented yet)"; return 1; }
  grep -q 'cmd_migrate' "${T9_NODE_DIR:-${REPO}/airgap/node}"/lib/*.sh 2>/dev/null || { T9_WHY="no cmd_migrate in the node lib (I-13 not implemented yet)"; return 1; }
}

legacy_name() {
  # canonical -> legacy file name, as k3s_legacy_names did (manifest-teknoir-* for teknoir-*-ca*-secret)
  case "$1" in
    teknoir-auth-ca-bundle-secret|teknoir-system-ca-bundle-secret|teknoir-ca-secret) printf 'manifest-%s' "$1" ;;
    teknoir-*) printf 'manifest-%s' "${1#teknoir-}" ;;
  esac
}

dummy() { head -c 24 /dev/urandom | base64 | tr -d '/+=\n'; }

t9_secret_doc() {
  # t9_secret_doc <ns/name> <type>
  local ns="${1%%/*}" name="${1#*/}" type="$2"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: %s\nstringData:\n' "${name}" "${ns}" "${type}"
  if [[ "${type}" == kubernetes.io/tls ]]; then
    printf '  tls.crt: dummy-%s\n  tls.key: dummy-%s\n' "$(dummy)" "$(dummy)"
  else
    printf '  value: dummy-%s\n' "$(dummy)"
  fi
}

t9_fixture() {
  local f name ns rest type n
  local gen="${WORK}/t9/gen.yaml"
  # phase 1: namespaces, CRDs, ArgoCD stand-in under its old name
  # (no pipelines into put_manifest here: T9_INVENTORY must grow in this shell)
  : > "${gen}"
  for ns in cert-manager istio-system teknoir-auth teknoir-system; do
    printf -- '---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n' "${ns}" >> "${gen}"
    T9_INVENTORY+=("namespace ${ns}")
  done
  put_manifest 00-teknoir-namespaces < "${gen}"
  t9_crds 00-teknoir-istio-crds "${ISTIO_CRDS}"
  t9_crds 05-teknoir-certmanager-crds "${CERTMANAGER_CRDS}"
  t9_argo_doc | put_manifest 10-teknoir-argo
  for f in 00-teknoir-namespaces 00-teknoir-istio-crds 05-teknoir-certmanager-crds 10-teknoir-argo; do
    wait_applied "${f}" || tl_die "fixture: ${f} not applied"
  done
  kc wait --for=condition=Established crd applications.argoproj.io appprojects.argoproj.io --timeout=60s >/dev/null
  # phase 2: the legacy duplicates (the old names applied first)
  while read -r f rest type; do
    t9_secret_doc "${rest}" "${type}" > "${WORK}/t9/${f}.yaml"
    ns="${rest%%/*}" name="${rest#*/}"
    T9_INVENTORY+=("secret ${name} ${ns}")
    cp "${WORK}/t9/${f}.yaml" "${WORK}/t9/$(legacy_name "${f}").yaml"
    put_manifest "$(legacy_name "${f}")" < "${WORK}/t9/${f}.yaml"
  done <<<"${T9_SECRETS}"
  t9_app_of_apps_doc | put_manifest app-of-apps
  while read -r f _ _; do wait_applied "$(legacy_name "${f}")" || tl_die "fixture: $(legacy_name "${f}") not applied"; done <<<"${T9_SECRETS}"
  wait_applied app-of-apps || tl_die "fixture: app-of-apps not applied"
  # phase 3: the canonical names take over (applied last, as on the live node)
  while read -r f _ _; do put_manifest "${f}" < "${WORK}/t9/${f}.yaml"; done <<<"${T9_SECRETS}"
  t9_app_of_apps_doc | put_manifest teknoir-app-of-apps
  t9_argo_doc | put_manifest teknoir-argo
  put_manifest teknoir-coredns-custom <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  teknoir.override: |
    # k3d T9 fixture (no-op)
EOF
  T9_INVENTORY+=("configmap coredns-custom kube-system" "applications.argoproj.io app-of-apps teknoir-system"
                 "appprojects.argoproj.io default teknoir-system")
  while read -r f _ _; do wait_applied "${f}" || tl_die "fixture: ${f} not applied"; done <<<"${T9_SECRETS}"
  for f in teknoir-app-of-apps teknoir-argo teknoir-coredns-custom; do wait_applied "${f}" || tl_die "fixture: ${f} not applied"; done
  # phase 4: orphans — the old files are gone, their Addons stay
  for f in ${T9_ORPHANS}; do rm -f "${MAN}/${f}.yaml"; done
  n="$(kc -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -cE "${TEKNOIR_ADDON_RE}" || true)"
  tl_log "fixture ready: ${n} Teknoir Addons, ${#T9_INVENTORY[@]} objects"
}

t9_crds() {
  # t9_crds <file> <"crd Kind" lines>
  local file="$1" crd kind gen="${WORK}/t9/gen-crds.yaml"
  : > "${gen}"
  while read -r crd kind; do
    [[ -n "${crd}" ]] || continue
    { printf -- '---\n'; crd_yaml "${crd%%.*}" "${crd#*.}" "${kind}"; } >> "${gen}"
    T9_INVENTORY+=("crd ${crd}")
  done <<<"$2"
  put_manifest "${file}" < "${gen}"
}

t9_argo_doc() {
  local crd kind
  while read -r crd kind; do
    printf -- '---\n'
    crd_yaml "${crd%%.*}" "${crd#*.}" "${kind}" v1alpha1
  done <<<"${ARGO_CRDS}"
  printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: argocd-cm\n  namespace: teknoir-system\ndata:\n  url: https://argocd.teknoir.airgapped\n'
}

t9_app_of_apps_doc() {
  cat <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: default, namespace: teknoir-system}
spec:
  sourceRepos: ['*']
  destinations: [{namespace: '*', server: '*'}]
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: app-of-apps, namespace: teknoir-system}
spec:
  project: default
  destination: {namespace: teknoir-system, server: https://kubernetes.default.svc}
  source: {repoURL: harbor.teknoir.airgapped/teknoir, chart: app-of-apps, targetRevision: 0.0.3}
EOF
}

t9_snapshot() {
  # uid and resourceVersion of every fixture object, one per line
  local o res name ns
  for o in "${T9_INVENTORY[@]}"; do
    read -r res name ns <<<"${o}"
    printf '%s %s\n' "${o}" "$(kc get "${res}" "${name}" ${ns:+-n "${ns}"} --ignore-not-found \
      -o jsonpath='{.metadata.uid}/{.metadata.resourceVersion}')"
  done
}
t9_uids() { t9_snapshot | sed -E 's|/[0-9]+$||'; }

t9_teknoir_addons() { kc -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -E "${TEKNOIR_ADDON_RE}" | sort || true; }
t9_other_addons() { kc -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -vE "${TEKNOIR_ADDON_RE}" | sort || true; }
t9_files() { (cd "${MAN}" && find . -maxdepth 1 -type f | sed 's|^\./||' | sort); }

t9_node() {
  # t9_node <args...> — the real node runner against this cluster, as
  # non-root: TEKNOIR_HOST_ROOT (the runner's test sandbox, which also allows
  # non-root) prefixes host paths; lock, log, state and the legacy bundle
  # home are kept in the work dir as well.
  env KUBECTL="kubectl --context ${CTX}" KUBECONFIG="${KUBECONFIG}" \
    TEKNOIR_HOST_ROOT="${WORK}/t9/root" TEKNOIR_LOCK_FILE="${WORK}/t9/teknoir-airgap.lock" \
    TEKNOIR_LOG_DIR="${WORK}/t9/log" STATE_DIR="${WORK}/t9/state" MIGRATE_LEGACY_HOME="${WORK}/t9/home" \
    "${WORK}/t9/payload/node/bin/teknoir-node" "$@"
}

t9_stage() {
  # stage the node payload as the bundle would (with node/SHA256SUMS) and a
  # site file whose K3S_DATA_DIR maps onto the k3d manifests dir
  local src="${T9_NODE_DIR:-${REPO}/airgap/node}" k3s="${WORK}/t9/k3s"
  rm -rf "${WORK}/t9/payload"
  mkdir -p "${WORK}/t9/payload" "${WORK}/t9/log" "${WORK}/t9/state" "${WORK}/t9/home" "${k3s}/server" \
    "${WORK}/t9/root${k3s}/server"
  cp -a "${src}" "${WORK}/t9/payload/node"
  (cd "${WORK}/t9/payload/node" && rm -f SHA256SUMS &&
    find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS)
  # The k3d manifests dir and a sibling retired dir, reachable as
  # K3S_DATA_DIR and as HOST_ROOT + K3S_DATA_DIR (whichever the code uses).
  ln -sfn "${MAN}" "${k3s}/server/manifests"
  ln -sfn "${MAN}" "${WORK}/t9/root${k3s}/server/manifests"
  mkdir -p "${WORK}/t9/retired"
  ln -sfn "${WORK}/t9/retired" "${k3s}/server/manifests-retired"
  ln -sfn "${WORK}/t9/retired" "${WORK}/t9/root${k3s}/server/manifests-retired"
  cat > "${WORK}/t9/site.env" <<EOF
TEKNOIR_ENV=k3d
TEKNOIR_DOMAIN=teknoir.airgapped
NODE_IP=127.0.0.1
NODE=root@127.0.0.1
TEKNOIR_HOSTNAMES="harbor argocd auth keycloak grafana"
K3S_DATA_DIR=${k3s}
EOF
}

t9() {
  tl_case T9 "migration rehearsal: legacy K3s layout -> teknoir-node migrate -> restart: nothing lost, no Teknoir Addons"
  mkdir -p "${WORK}/t9"
  t9_fixture
  t9_stage
  local base_snap base_others base_files base_addons out rc name missing=0 left post_snap
  base_snap="$(t9_snapshot)"
  base_others="$(t9_other_addons)"
  base_files="$(t9_files)"
  base_addons="$(t9_teknoir_addons)"
  # sanity: the canonical Addons own the secrets, like on the live node
  local f rest wrong=0
  while read -r f rest _; do
    [[ "$(meta_of secret "${rest#*/}" "${rest%%/*}" | jq -r .owner)" == "${f}" ]] || wrong=$((wrong + 1))
  done <<<"${T9_SECRETS}"
  assert_eq "fixture: every secret is owned by its canonical Addon (as on teknoir-local)" 0 "${wrong}"

  set +e; out="$(t9_node migrate --site "${WORK}/t9/site.env" --dry-run 2>&1)"; rc=$?; set -e
  assert_eq "migrate --dry-run exits 0" 0 "${rc}"
  (( rc == 0 )) || printf '%s\n' "${out}" | tail -20 >&2
  for name in $(t9_teknoir_addons | grep -vx teknoir-argo); do
    grep -qF -- "${name}" <<<"${out}" || { missing=$((missing + 1)); tl_warn "dry-run does not mention ${name}"; }
  done
  assert_eq "migrate --dry-run lists every Teknoir Addon but teknoir-argo" 0 "${missing}"
  assert_eq "dry-run changed no object" "${base_snap}" "$(t9_snapshot)"
  assert_eq "dry-run changed no manifests-dir file" "${base_files}" "$(t9_files)"
  assert_eq "dry-run deleted no Addon" "${base_addons}" "$(t9_teknoir_addons)"

  set +e; out="$(t9_node migrate --site "${WORK}/t9/site.env" 2>&1)"; rc=$?; set -e
  assert_eq "migrate exits 0" 0 "${rc}"
  (( rc == 0 )) || printf '%s\n' "${out}" | tail -20 >&2
  t9_assert_detached "after migrate" "${base_snap}" "${base_others}"

  set +e; out="$(t9_node migrate --site "${WORK}/t9/site.env" 2>&1)"; rc=$?; set -e
  assert_eq "a second migrate exits 0 (idempotent)" 0 "${rc}"
  t9_assert_detached "after a second migrate" "${base_snap}" "${base_others}"

  # an old bundle re-adds a legacy file next to its .skip, with another value
  post_snap="$(t9_snapshot)"
  t9_secret_doc teknoir-system/harbor-secret Opaque | put_manifest manifest-harbor-secret
  restart_k3s
  t9_assert_detached "after a k3s restart" "${base_snap}" "${base_others}"
  assert_eq "after a k3s restart: no detached object changed (resourceVersions)" "${post_snap}" "$(t9_snapshot)"
  rm -f "${MAN}/manifest-harbor-secret.yaml"

  # --undo re-adopts one name; migrate detaches it again
  set +e; out="$(t9_node migrate --site "${WORK}/t9/site.env" --undo teknoir-coredns-custom 2>&1)"; rc=$?; set -e
  assert_eq "migrate --undo teknoir-coredns-custom exits 0" 0 "${rc}"
  if wait_applied teknoir-coredns-custom 120; then pass "--undo: K3s re-created Addon teknoir-coredns-custom"; else fail "--undo: Addon not re-created"; fi
  assert_eq "--undo: coredns-custom owned by its Addon again" teknoir-coredns-custom "$(meta_of configmap coredns-custom kube-system | jq -r .owner)"
  set +e; out="$(t9_node migrate --site "${WORK}/t9/site.env" 2>&1)"; rc=$?; set -e
  assert_eq "migrate after --undo exits 0" 0 "${rc}"
  t9_assert_detached "after undo + migrate" "${base_snap}" "${base_others}"
  if [[ -n "$(find "${WORK}/t9/log" -type f 2>/dev/null)" ]]; then
    left="$(find "${WORK}/t9/log" -type f ! -perm 600 | wc -l)"
    assert_eq "every run log is mode 0600" 0 "${left}"
  else
    tl_warn "no run log under TEKNOIR_LOG_DIR=${WORK}/t9/log (hook not honoured?)"
  fi
}

t9_assert_detached() {
  local when="$1" base_snap="$2" base_others="$3" o res oname ns labelled=0 name noskip=0 stray
  assert_eq "${when}: Teknoir Addons left = teknoir-argo only (migrated in M7)" teknoir-argo "$(t9_teknoir_addons | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "${when}: K3s's own and other Addons untouched" "${base_others}" "$(t9_other_addons)"
  assert_eq "${when}: every fixture object kept its uid" "$(sed -E 's|/[0-9]+$||' <<<"${base_snap}")" "$(t9_uids)"
  for o in "${T9_INVENTORY[@]}"; do
    read -r res oname ns <<<"${o}"
    objset_labelled "${res}" "${oname}" "${ns}" && labelled=$((labelled + 1))
  done
  assert_eq "${when}: no detached object carries the K3s hash label" 0 "${labelled}"
  for name in 00-teknoir-namespaces 00-teknoir-istio-crds 05-teknoir-certmanager-crds teknoir-coredns-custom \
              teknoir-app-of-apps ${T9_ORPHANS} $(cut -d' ' -f1 <<<"${T9_SECRETS}") \
              $(while read -r f _ _; do legacy_name "${f}"; echo; done <<<"${T9_SECRETS}"); do
    [[ -f "${MAN}/${name}.yaml.skip" ]] || { noskip=$((noskip + 1)); tl_warn "no ${name}.yaml.skip"; }
  done
  assert_eq "${when}: every retired name has a .skip guard" 0 "${noskip}"
  stray="$(t9_files | grep -E '\.ya?ml$' | sed -E 's/\.ya?ml$//' | grep -E "${TEKNOIR_ADDON_RE}" | grep -vx -e teknoir-argo -e manifest-harbor-secret | tr '\n' ' ' || true)"
  assert_eq "${when}: no Teknoir *.yaml left in the manifests dir but teknoir-argo.yaml" "" "${stray}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  local -a tests=()
  while (( $# )); do
    case "$1" in
      --list) printf '%s\n' "${ALL_TESTS[@]}"; return 0 ;;
      --keep) KEEP=1 ;;
      --reuse) REUSE=1 ;;
      -h|--help) usage; return 0 ;;
      T[0-9]*) [[ " ${ALL_TESTS[*]} " == *" ${1^^} "* ]] || tl_die "unknown test $1 (see --list)"; tests+=("${1^^}") ;;
      *) tl_die "unknown argument $1 (see --help)" ;;
    esac
    shift
  done
  (( ${#tests[@]} )) || tests=("${ALL_TESTS[@]}")
  need docker k3d kubectl jq sha256sum base64
  mkdir -p "${WORK_BASE}"
  trap cleanup EXIT

  local t basic=()
  for t in "${tests[@]}"; do case "${t}" in T6|T9) ;; *) basic+=("${t}") ;; esac; done
  if (( ${#basic[@]} )); then
    use_cluster "${PREFIX}"
    for t in "${basic[@]}"; do "${t,,}"; done
    finish_cluster
  fi
  if [[ " ${tests[*]} " == *" T6 "* ]]; then
    # metrics-server stays: ArgoCD reports istio's HPAs Degraded without metrics;
    # servicelb too: the gateways' LoadBalancer Services are Progressing without it
    if t6_ready; then use_cluster "${PREFIX}-t6" sub traefik; t6; finish_cluster
    else tl_case T6 "ArgoCD adoption of the one-shot render"; skip_case "${T6_WHY}"; fi
  fi
  if [[ " ${tests[*]} " == *" T9 "* ]]; then
    if t9_ready; then use_cluster "${PREFIX}-t9" top; t9; finish_cluster
    else tl_case T9 "migration rehearsal on the legacy fixture"; skip_case "${T9_WHY}"; fi
  fi
  tl_summary
}

# Sourcing (unit tests) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
