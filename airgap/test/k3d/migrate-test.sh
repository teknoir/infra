#!/usr/bin/env bash
# migrate-test.sh — k3d proof of the K3s detach recipe (lib/migrate.sh, DESIGN
# I-13, tests T2/T4/T9) on the live K3s version.
#
# Reproduces the live teknoir-local layout in the manifests dir of a throwaway
# k3d cluster (bind-mounted from a temp dir, so the script edits it like the
# node does): 00-teknoir-* namespace/CRD files, 9 canonical teknoir-*-secret
# files plus their 8 legacy manifest-*-secret duplicates (dummy random values
# generated per run), teknoir-coredns-custom, teknoir-app-of-apps,
# teknoir-argo, and the 3 orphan Addons (10-teknoir-argo, app-of-apps,
# manifest-argocd-harbor-repo-secret) whose files are gone. Then it runs
# migrate --dry-run, migrate, k3s restarts, a re-dropped old file, a rotation,
# --undo, and asserts that no object is lost or re-created (UIDs), that Secret
# data is untouched, that no Teknoir Addon remains except teknoir-argo (M7),
# and that K3s's own addons are untouched. The safety net: an object of a
# later name re-created, or a Secret deleted, while migrate runs stops it.
#
# Usage: airgap/test/k3d/migrate-test.sh [--keep]
#   --keep   leave the cluster and temp dir for inspection
# Needs: docker, k3d, kubectl, jq, openssl, sha1sum/sha256sum. ~600 MB RAM.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
FIX="${HERE}/fixtures/legacy-k3s"
CLUSTER="${CLUSTER:-tkn2-migrate}"
CTX="k3d-${CLUSTER}"
SERVER="k3d-${CLUSTER}-server-0"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-migrate.XXXXXX")"
DATA="${WORK}/k3s"
MAN="${DATA}/server/manifests"
RETIRED_ROOT="${DATA}/server/manifests-retired"
mkdir -p "${MAN}" "${WORK}/home" "${WORK}/node/bin" "${WORK}/out"
chmod 0755 "${WORK}"
ln -s "$(command -v crane 2>/dev/null || echo /bin/false)" "${WORK}/node/bin/crane"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"

PASS=0
FAIL=0
FAILED=()
say()  { printf '\n=== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }

K() { kubectl --context "${CTX}" "$@"; }

node_fn() {
  env KUBECTL="kubectl --context ${CTX}" K3S_DATA_DIR="${DATA}" TEKNOIR_DOMAIN=teknoir.airgapped \
    NODE=teknoir@10.77.0.10 MIGRATE_LEGACY_HOME="${WORK}/home" NODE_ROOT="${WORK}/node" \
    STUB_WAIT_INTERVAL=3 "${REPO}/airgap/test/stubs/teknoir-node-stub" "$@"
}

cleanup() {
  local rc=$?
  if [[ "${KEEP}" == "1" ]]; then
    echo "kept: cluster ${CLUSTER} (context ${CTX}), work dir ${WORK}"
  else
    # K3s writes its own files into the bind-mounted dir as root
    docker exec "${SERVER}" sh -c 'rm -rf /var/lib/rancher/k3s/server/manifests/* /var/lib/rancher/k3s/server/manifests/.[!.]*' >/dev/null 2>&1 || true
    k3d cluster delete "${CLUSTER}" >/dev/null 2>&1 || true
    rm -rf "${WORK}" 2>/dev/null || echo "note: could not remove ${WORK} completely" >&2
  fi
  exit "${rc}"
}
trap cleanup EXIT

wait_until() {
  # wait_until <description> <timeout-s> <cmd...>
  local desc="$1" timeout="$2" deadline
  shift 2
  deadline=$(( $(date +%s) + timeout ))
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
      echo "timed out waiting for ${desc}" >&2
      return 1
    fi
    sleep 3
  done
}

put() {
  # put <src> <dst-basename> — atomic write into the manifests dir (K3s ignores .tmp)
  cp "$1" "${MAN}/.$2.tmp" && mv -f "${MAN}/.$2.tmp" "${MAN}/$2"
}

addon_applied() {
  # addon_applied <name> — K3s applied the current content of <name>.yaml
  [[ "$(K -n kube-system get addons.k3s.cattle.io "$1" --ignore-not-found -o jsonpath='{.spec.checksum}')" \
     == "$(sha256sum "${MAN}/$1.yaml" | awk '{print $1}')" ]]
}

all_applied() {
  local f
  for f in "${MAN}"/*.yaml; do
    case "$(basename "${f}")" in ccm.yaml|coredns.yaml|local-storage.yaml|rolebindings.yaml|runtimes.yaml|traefik.yaml) continue ;; esac
    addon_applied "$(basename "${f}" .yaml)" || return 1
  done
}

restart_k3s() {
  docker restart "${SERVER}" >/dev/null
  sleep 5
  wait_until "API server after restart" 180 K get --raw /readyz
  wait_until "node Ready" 120 K wait --for=condition=Ready node --all --timeout=5s
  # the deploy controller scans every 15 s; two full scans after start
  sleep 40
}

gen_secret() {
  # gen_secret <ns> <name> <type> <keys> <label> — a Secret manifest with random values
  local ns="$1" name="$2" type="$3" keys="$4" label="$5" k
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n' "${name}" "${ns}"
  if [[ "${label}" != "-" ]]; then
    printf '  labels:\n    %s: "%s"\n' "${label%%=*}" "${label#*=}"
  fi
  printf 'type: %s\nstringData:\n' "${type}"
  for k in ${keys//,/ }; do
    printf '  %s: "%s"\n' "${k}" "dummy-$(openssl rand -hex 12)"
  done
}

TEKNOIR_RE='^(teknoir-.+|00-teknoir-.+|05-teknoir-.+|10-teknoir-.+|manifest-.+-secret|app-of-apps)$'

teknoir_addons() {
  K -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -E "${TEKNOIR_RE}" | sort | tr '\n' ' ' | sed 's/ $//'
}
other_addons() {
  K -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -vE "${TEKNOIR_RE}" | sort
}

snapshot() {
  # identity of every object that matters: kind ns name uid (one per line)
  {
    K get namespaces -o jsonpath='{range .items[*]}Namespace - {.metadata.name} {.metadata.uid}{"\n"}{end}'
    K get crd -o jsonpath='{range .items[*]}CRD - {.metadata.name} {.metadata.uid}{"\n"}{end}'
    local r
    for r in secrets configmaps applications.argoproj.io appprojects.argoproj.io gateways.networking.istio.io \
             virtualservices.networking.istio.io certificates.cert-manager.io; do
      K get "${r}" -A -o jsonpath="{range .items[*]}${r} {.metadata.namespace} {.metadata.name} {.metadata.uid}{\"\\n\"}{end}"
    done
    K get clusterissuers.cert-manager.io -o jsonpath='{range .items[*]}ClusterIssuer - {.metadata.name} {.metadata.uid}{"\n"}{end}'
  } | sort
}

secret_hashes() {
  # sha256 of each fixture Secret's data (the values themselves are never printed)
  local canon legacy ns name rest
  while IFS=$'\t' read -r canon legacy ns name rest; do
    [[ "${canon}" == \#* || -z "${canon}" ]] && continue
    printf '%s/%s %s\n' "${ns}" "${name}" "$(K -n "${ns}" get secret "${name}" -o json | jq -cS .data | sha256sum | cut -c1-16)"
  done < "${FIX}/secrets.tsv"
}

labelled_teknoir_objects() {
  # objects still carrying a K3s owner label from a Teknoir file other than teknoir-argo
  local r
  for r in namespaces crd secrets configmaps applications.argoproj.io appprojects.argoproj.io; do
    K get "${r}" -A -l objectset.rio.cattle.io/hash \
      -o jsonpath='{range .items[*]}{.kind} {.metadata.namespace}/{.metadata.name} {.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}{"\n"}{end}'
  done | awk -v re="${TEKNOIR_RE}" '$3 ~ re && $3 != "teknoir-argo"'
}

baseline_kept() {
  # every baseline object still exists with the same UID
  local missing
  missing="$(comm -23 "${WORK}/out/baseline.txt" <(snapshot))"
  if [[ -n "${missing}" ]]; then
    echo "missing or re-created:" >&2
    echo "${missing}" >&2
    return 1
  fi
}

# ----------------------------------------------------------------------------
say "k3d cluster ${CLUSTER} (${K3S_IMAGE}), manifests dir bind-mounted from ${MAN}"
k3d cluster create "${CLUSTER}" --image "${K3S_IMAGE}" --servers 1 --agents 0 --no-lb \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' \
  --volume "${MAN}:/var/lib/rancher/k3s/server/manifests@server:0" \
  --wait --timeout 180s >/dev/null
wait_until "node Ready" 120 K wait --for=condition=Ready node --all --timeout=5s

say "legacy layout, stage 1: old names (00-*, 05-*, 10-teknoir-argo, manifest-*-secret, app-of-apps)"
put "${FIX}/00-teknoir-namespaces.yaml" 00-teknoir-namespaces.yaml
put "${FIX}/00-teknoir-istio-crds.yaml" 00-teknoir-istio-crds.yaml
put "${FIX}/05-teknoir-certmanager-crds.yaml" 05-teknoir-certmanager-crds.yaml
put "${FIX}/teknoir-argo.yaml" 10-teknoir-argo.yaml
while IFS=$'\t' read -r canon legacy ns name type keys label; do
  [[ "${canon}" == \#* || -z "${canon}" ]] && continue
  gen_secret "${ns}" "${name}" "${type}" "${keys}" "${label}" > "${WORK}/out/${canon}.yaml"
  put "${WORK}/out/${canon}.yaml" "${legacy}.yaml"
done < "${FIX}/secrets.tsv"
put "${FIX}/teknoir-app-of-apps.yaml" app-of-apps.yaml
wait_until "stage 1 applied" 240 all_applied

say "stage 2: canonical names take the objects over (as deploy-secrets.sh / k3s_deploy did)"
put "${FIX}/teknoir-argo.yaml" teknoir-argo.yaml
while IFS=$'\t' read -r canon legacy rest; do
  [[ "${canon}" == \#* || -z "${canon}" ]] && continue
  put "${WORK}/out/${canon}.yaml" "${canon}.yaml"
done < "${FIX}/secrets.tsv"
put "${FIX}/teknoir-app-of-apps.yaml" teknoir-app-of-apps.yaml
put "${FIX}/teknoir-coredns-custom.yaml" teknoir-coredns-custom.yaml
wait_until "stage 2 applied" 240 all_applied

say "stage 3: orphan Addons (files gone, Addons left) and objects the files do not own"
rm -f "${MAN}/10-teknoir-argo.yaml" "${MAN}/app-of-apps.yaml" "${MAN}/manifest-argocd-harbor-repo-secret.yaml"
K apply -f - >/dev/null <<'EOF'
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: teknoir-gateway, namespace: istio-system}
spec: {selector: {istio: ingressgateway}}
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: keycloak, namespace: teknoir-auth}
spec: {hosts: [auth.teknoir.airgapped]}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: teknoir-wildcard, namespace: istio-system}
spec: {secretName: teknoir-airgapped-wildcard-tls}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: teknoir-ca}
spec: {ca: {secretName: teknoir-root-ca}}
EOF
mkdir -p "${WORK}/home/teknoir-airgap-bundle-0.1.0/bootstrap/secrets"
echo "placeholder" > "${WORK}/home/teknoir-airgap-bundle-0.1.0/bootstrap/secrets/manifest-teknoir-ca-secret.yaml"

say "T2 (hazard, documented): shrinking a K3s file deletes the dropped object, Prune=false or not"
cat > "${WORK}/out/zz.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: hazard-1, namespace: default, annotations: {argocd.argoproj.io/sync-options: "Prune=false,Delete=false"}}
data: {k: v}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: hazard-2, namespace: default, annotations: {argocd.argoproj.io/sync-options: "Prune=false,Delete=false"}}
data: {k: v}
EOF
put "${WORK}/out/zz.yaml" zz-hazard-demo.yaml
wait_until "zz-hazard-demo applied" 120 addon_applied zz-hazard-demo
head -4 "${WORK}/out/zz.yaml" > "${WORK}/out/zz1.yaml"
put "${WORK}/out/zz1.yaml" zz-hazard-demo.yaml
wait_until "zz-hazard-demo re-applied" 120 addon_applied zz-hazard-demo
sleep 3
check "T2: K3s deleted hazard-2 when it left the file (Prune=false ignored)" \
  bash -c "! kubectl --context ${CTX} -n default get configmap hazard-2 -o name 2>/dev/null"

say "k3s restart: every file is re-applied in name order, as on the live node"
restart_k3s
check "pre-state: the 3 orphan Addons exist" bash -c "
  for a in 10-teknoir-argo app-of-apps manifest-argocd-harbor-repo-secret; do
    kubectl --context ${CTX} -n kube-system get addons.k3s.cattle.io \$a -o name >/dev/null || exit 1
    [[ ! -e '${MAN}'/\$a.yaml ]] || exit 1
  done"
check "pre-state: Secrets are owned by the canonical teknoir-*-secret Addons" bash -c "
  [[ \$(kubectl --context ${CTX} -n teknoir-system get secret harbor-secret -o jsonpath='{.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}') == teknoir-harbor-secret ]]"
check "pre-state: 25 Teknoir Addons + teknoir-argo" bash -c "[[ \$(kubectl --context ${CTX} -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -cE '${TEKNOIR_RE}') == 26 ]]"

snapshot > "${WORK}/out/baseline.txt"
secret_hashes > "${WORK}/out/secrets-baseline.txt"
other_addons > "${WORK}/out/other-addons.txt"
find "${MAN}" -mindepth 1 -maxdepth 1 -printf "%f\n" | sort > "${WORK}/out/files-before.txt"
K get secrets,configmaps,namespaces,crd -A -l objectset.rio.cattle.io/hash -o name | sort > "${WORK}/out/labels-before.txt"
echo "  baseline: $(grep -c . "${WORK}/out/baseline.txt") objects, $(grep -c . "${WORK}/out/secrets-baseline.txt") fixture Secrets, $(grep -c . "${WORK}/out/other-addons.txt") K3s/other Addons"

say "migrate --dry-run: read-only"
node_fn cmd_migrate --dry-run > "${WORK}/out/dry-run.log" 2>&1 || { cat "${WORK}/out/dry-run.log"; bad "migrate --dry-run exits 0"; }
check "dry-run plans exactly 25 names" bash -c "[[ \$(grep -c '\[dry-run\] [^ ]*: would' '${WORK}/out/dry-run.log') == 25 ]]"
check "dry-run plans the 3 orphans first" bash -c "grep '\[dry-run\] [^ ]*: would' '${WORK}/out/dry-run.log' | head -3 | grep -c -E ' (10-teknoir-argo|app-of-apps|manifest-argocd-harbor-repo-secret): ' | grep -qx 3"
check "dry-run never plans teknoir-argo (M7)" bash -c "! grep -q '\] teknoir-argo: would' '${WORK}/out/dry-run.log'"
check "dry-run changed no file" diff -q "${WORK}/out/files-before.txt" <(find "${MAN}" -mindepth 1 -maxdepth 1 -printf "%f\n" | sort)
check "dry-run changed no Addon" diff -q <(echo "26") <(K -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -cE "${TEKNOIR_RE}")
check "dry-run changed no label" diff -q "${WORK}/out/labels-before.txt" <(K get secrets,configmaps,namespaces,crd -A -l objectset.rio.cattle.io/hash -o name | sort)
check "dry-run kept the old bundle copy" test -d "${WORK}/home/teknoir-airgap-bundle-0.1.0"

say "migrate"
if node_fn cmd_migrate > "${WORK}/out/migrate.log" 2>&1; then ok "migrate exits 0"; else bad "migrate exits 0"; cat "${WORK}/out/migrate.log"; fi
assert_detached() {
  local when="$1"
  check "${when}: only teknoir-argo is left as a Teknoir Addon" test "$(teknoir_addons)" == "teknoir-argo"
  check "${when}: K3s's own Addons untouched" diff -q "${WORK}/out/other-addons.txt" <(other_addons)
  check "${when}: every baseline object exists with the same UID" baseline_kept
  check "${when}: Secret data unchanged" diff -q "${WORK}/out/secrets-baseline.txt" <(secret_hashes)
  check "${when}: no object carries a Teknoir K3s label (except teknoir-argo's)" test -z "$(labelled_teknoir_objects)"
  check "${when}: teknoir-argo still owns argocd-cm" bash -c "[[ \$(kubectl --context ${CTX} -n teknoir-system get cm argocd-cm -o jsonpath='{.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}') == teknoir-argo ]]"
  check "${when}: no Teknoir *.yaml left in the manifests dir except teknoir-argo.yaml" \
    bash -c "[[ \$(ls '${MAN}' | grep -E '\.yaml$' | sed 's/\.yaml$//' | grep -E '${TEKNOIR_RE}' | tr '\n' ' ') == 'teknoir-argo ' ]]"
}
assert_detached "after migrate"
check "a .skip guard exists for every detached name (25)" bash -c "[[ \$(ls '${MAN}' | grep -c '\.yaml\.skip$') == 25 ]]"
check "22 files retired unmodified (orphans have none)" bash -c "[[ \$(find '${RETIRED_ROOT}' -type f | wc -l) == 22 ]] && cmp -s '${WORK}/out/teknoir-harbor-secret.yaml' \$(find '${RETIRED_ROOT}' -name teknoir-harbor-secret.yaml)"
check "the old bundle copy was removed" test ! -e "${WORK}/home/teknoir-airgap-bundle-0.1.0"
check "robot repo-creds kept (no credential-less repository yet)" bash -c "kubectl --context ${CTX} -n teknoir-system get secret argocd-harbor-repo -o name >/dev/null && grep -q 'robot: not yet' '${WORK}/out/migrate.log'"
check "no secret value in the migrate output" bash -c "! grep -q 'dummy-' '${WORK}/out/migrate.log' '${WORK}/out/dry-run.log'"

say "migrate again: idempotent"
node_fn cmd_migrate > "${WORK}/out/migrate2.log" 2>&1 || bad "second migrate exits 0"
check "second migrate: nothing left, 0 changes" bash -c "grep -q 'no Teknoir K3s files or Addons left' '${WORK}/out/migrate2.log' && grep -q 'summary: 0 change' '${WORK}/out/migrate2.log'"

K get secrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.resourceVersion}{"\n"}{end}' \
  | grep -E '^(teknoir-system|teknoir-auth|cert-manager)/' | sort > "${WORK}/out/secret-rv.txt"

say "k3s restart after migrate (the M5 test)"
restart_k3s
assert_detached "after restart"
check "after restart: Secret resourceVersions unchanged (nothing re-applied)" diff -q "${WORK}/out/secret-rv.txt" \
  <(K get secrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.resourceVersion}{"\n"}{end}' | grep -E '^(teknoir-system|teknoir-auth|cert-manager)/' | sort)

say "an old bundle drops teknoir-harbor-secret.yaml next to its .skip; an operator rotates a Secret"
gen_secret teknoir-system harbor-secret Opaque "HARBOR_ADMIN_PASSWORD,secretKey" - > "${WORK}/out/stale.yaml"
put "${WORK}/out/stale.yaml" teknoir-harbor-secret.yaml
K -n teknoir-auth patch secret oauth2-proxy-secret --type=merge -p "{\"stringData\":{\"cookie-secret\":\"rotated-$(openssl rand -hex 8)\"}}" >/dev/null
rotated="$(K -n teknoir-auth get secret oauth2-proxy-secret -o json | jq -cS .data | sha256sum | cut -c1-16)"
sleep 35
restart_k3s
check "the dropped file is ignored: no Addon teknoir-harbor-secret" bash -c "! kubectl --context ${CTX} -n kube-system get addons.k3s.cattle.io teknoir-harbor-secret -o name 2>/dev/null"
check "the dropped file is ignored: harbor-secret data unchanged" bash -c "[[ \"\$(grep '^teknoir-system/harbor-secret ' '${WORK}/out/secrets-baseline.txt')\" == \"teknoir-system/harbor-secret \$(kubectl --context ${CTX} -n teknoir-system get secret harbor-secret -o json | jq -cS .data | sha256sum | cut -c1-16)\" ]]"
check "a rotation survives the restart (T5 inverse)" bash -c "[[ \$(kubectl --context ${CTX} -n teknoir-auth get secret oauth2-proxy-secret -o json | jq -cS .data | sha256sum | cut -c1-16) == '${rotated}' ]]"
check "every baseline object still exists with the same UID" baseline_kept
secret_hashes > "${WORK}/out/secrets-baseline.txt"   # the rotation is the new expected state
node_fn cmd_migrate > "${WORK}/out/migrate3.log" 2>&1 || bad "third migrate exits 0"
check "migrate retires the dropped file (no objects touched)" bash -c "[[ ! -e '${MAN}/teknoir-harbor-secret.yaml' ]] && grep -q 'teknoir-harbor-secret: detaching (0 object' '${WORK}/out/migrate3.log'"

say "migrate --undo teknoir-coredns-custom: K3s re-adopts; then detach again"
uid_before="$(K -n kube-system get cm coredns-custom -o jsonpath='{.metadata.uid}')"
node_fn cmd_migrate --undo teknoir-coredns-custom > "${WORK}/out/undo.log" 2>&1 || { bad "undo exits 0"; cat "${WORK}/out/undo.log"; }
check "undo: Addon teknoir-coredns-custom is back and owns coredns-custom" bash -c "[[ \$(kubectl --context ${CTX} -n kube-system get cm coredns-custom -o jsonpath='{.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}') == teknoir-coredns-custom ]]"
check "undo: same object (UID)" bash -c "[[ \$(kubectl --context ${CTX} -n kube-system get cm coredns-custom -o jsonpath='{.metadata.uid}') == '${uid_before}' ]]"
check "undo: the .skip guard is gone" test ! -e "${MAN}/teknoir-coredns-custom.yaml.skip"
node_fn cmd_migrate > "${WORK}/out/migrate4.log" 2>&1 || bad "migrate after undo exits 0"
assert_detached "after undo + migrate"

say "a second --undo of the same file is applied too (K3s remembers the mtimes it has seen)"
node_fn cmd_migrate --undo teknoir-coredns-custom > "${WORK}/out/undo-again.log" 2>&1 || { bad "second undo exits 0"; cat "${WORK}/out/undo-again.log"; }
check "second undo: K3s re-adopts coredns-custom" bash -c "[[ \$(kubectl --context ${CTX} -n kube-system get cm coredns-custom -o jsonpath='{.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}') == teknoir-coredns-custom ]]"
node_fn cmd_migrate > "${WORK}/out/migrate4b.log" 2>&1 || bad "migrate after the second undo exits 0"
check "detached again: only teknoir-argo is left" test "$(teknoir_addons)" == "teknoir-argo"

say "safety net: the baseline covers every object of the run, and the counts"
# put two names back under K3s; while migrate detaches the first, a stand-in
# for a faulty step re-creates an object of the second
node_fn cmd_migrate --undo teknoir-oauth2-proxy-redis-secret --undo teknoir-coredns-custom > "${WORK}/out/undo2.log" 2>&1 \
  || { bad "undo of two names exits 0"; cat "${WORK}/out/undo2.log"; }
recreate_when() {
  # recreate_when <file> <ns> <configmap> — once <file> exists, delete and re-create the ConfigMap (same content, new UID)
  local i json
  for (( i = 0; i < 600; i++ )); do
    if [[ -e "$1" ]]; then
      json="$(kubectl --context "${CTX}" -n "$2" get cm "$3" -o json | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields)')"
      kubectl --context "${CTX}" -n "$2" delete cm "$3" --wait=true >/dev/null
      kubectl --context "${CTX}" create -f - >/dev/null <<<"${json}"
      return 0
    fi
    sleep 0.1
  done
}
recreate_when "${MAN}/teknoir-oauth2-proxy-redis-secret.yaml.skip" kube-system coredns-custom &
watcher=$!
if node_fn cmd_migrate > "${WORK}/out/net1.log" 2>&1; then
  bad "a re-created object of a later name stops migrate"
else
  # normally caught right after the first name; if the stand-in is slow, the
  # check after teknoir-coredns-custom catches it (its own per-name check cannot)
  check "a re-created object of a later name stops migrate, naming it" \
    grep -qE 'ConfigMap.v1. kube-system/coredns-custom (re-created \(new UID\)|LOST);.*stopping' "${WORK}/out/net1.log"
fi
wait "${watcher}" || true
node_fn cmd_migrate > "${WORK}/out/net2.log" 2>&1 || { bad "migrate after the stop exits 0 (new baseline)"; cat "${WORK}/out/net2.log"; }
snapshot > "${WORK}/out/baseline.txt"   # coredns-custom's new UID is the expected state now
check "after the re-run only teknoir-argo is left" test "$(teknoir_addons)" == "teknoir-argo"
node_fn cmd_migrate --undo teknoir-keycloak-db-secret > "${WORK}/out/undo3.log" 2>&1 || { bad "undo exits 0"; cat "${WORK}/out/undo3.log"; }
K -n teknoir-system create secret generic tkn2-canary --from-literal=k=v >/dev/null
( for (( i = 0; i < 600; i++ )); do
    if [[ -e "${MAN}/teknoir-keycloak-db-secret.yaml.skip" ]]; then
      kubectl --context "${CTX}" -n teknoir-system delete secret tkn2-canary --wait=true >/dev/null; exit 0
    fi
    sleep 0.1
  done ) &
watcher=$!
if node_fn cmd_migrate > "${WORK}/out/net3.log" 2>&1; then
  bad "a Secret deleted during migrate (no Addon owns it) stops migrate"
else
  check "a Secret deleted during migrate (no Addon owns it) stops migrate, naming the count" \
    grep -qE 'object counts changed after teknoir-keycloak-db-secret: secrets/teknoir-system ([0-9]+) -> ' "${WORK}/out/net3.log"
fi
wait "${watcher}" || true
check "the baseline is logged as names and counts, never UIDs" bash -c "
  grep -q 'migrate: baseline: .* object(s) of .* Addon(s)' '${WORK}/out/net1.log' && grep -qE 'baseline counts: .*crds=[0-9]+ .*namespaces=[0-9]+ .*secrets/teknoir-system=[0-9]+' '${WORK}/out/net1.log' &&
  ! grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' '${WORK}/out/net1.log' '${WORK}/out/net3.log'"
check "the safety-net runs printed no secret value" bash -c "! grep -q 'dummy-' '${WORK}/out/net1.log' '${WORK}/out/net2.log' '${WORK}/out/net3.log'"

say "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  echo "logs: ${WORK}/out (use --keep to keep them)"
  exit 1
fi
