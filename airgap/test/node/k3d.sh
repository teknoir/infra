#!/usr/bin/env bash
# k3d.sh: the cluster phases of teknoir-node against a throwaway k3d cluster
# (rancher/k3s:v1.33.5-k3s1, the live version). The host phase is not run
# here (it needs a real node: VM e2e); the runner uses a sandbox host root
# and KUBECTL="kubectl --context k3d-<name>".
#
# Covers DESIGN I-05/I-07/I-10/I-12 tests:
#   T7  converge cluster-base,secrets,release twice: the second run reports 0
#       changes and every object keeps its resourceVersion; deleting only the
#       wildcard Secret re-creates only that one
#   T8  never print: no value of any Secret appears in any run log or output
#   CA  name constraints (permitted DNS <domain>, .<domain>); the wildcard
#       placeholder verifies against the CA
#   I-10 downgrade refused, --rollback accepted and recorded, the next plain
#       run with the rolled-back bundle keeps it; broken versions refused;
#       post fails naming an Application that is not Synced/Healthy, and
#       treats a stale status as not ready (compared with the old pin, a
#       running sync, another chart revision, or - after this run's pin - no
#       reconcile since); release requests a root refresh, and with a
#       stand-in ArgoCD answering it, release + post pass
#   I-07 credentials --out (0600) and to a pipe, a user name passes the leak
#       check; rotate oauth2-proxy-cookie changes only that key; rotate
#       keycloak-db --i-know against a postgres stand-in (new password works,
#       old one is refused, exit 0)
#   I-12 backup: none before the first release; without DB pods a backup
#       completes and warns (first install interrupted, DB restarting);
#       pg_dumpall of harbor and keycloak through kubectl exec, Secrets
#       export (0600), keep 3; age stream when AGE_BIN is set
#
# Usage: airgap/test/node/k3d.sh [-v] [--keep]
#   AGE_BIN=/path/to/age   also test `backup --recipient` (needs age-keygen next to it)
#   TEKNOIR_NODE_SRC=DIR   test another airgap/node tree
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TEKNOIR_NODE_SRC: another airgap/node tree to test instead of this checkout's.
SRC="$(cd "${TEKNOIR_NODE_SRC:-${HERE}/../../node}" && pwd)"
NAME="${K3D_NAME:-tknode}"
CTX="k3d-${NAME}"
IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:16-alpine}"
VERBOSE=0
KEEP=0
for a in "$@"; do
  case "${a}" in
    -v) VERBOSE=1 ;;
    --keep) KEEP=1 ;;
    *) echo "usage: $0 [-v] [--keep]" >&2; exit 2 ;;
  esac
done

T="$(mktemp -d)"
PASS=0
FAIL=0
cleanup() {
  if (( KEEP == 0 )); then
    k3d cluster delete "${NAME}" >/dev/null 2>&1 || true
  else
    echo "kept cluster ${CTX} and ${T}"
    return 0
  fi
  rm -rf "${T}"
}
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
nok() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else nok "${d}"; fi; }
k() { kubectl --context "${CTX}" "$@"; }
rv() { k -n "$1" get "$2" "$3" -o 'jsonpath={.metadata.resourceVersion}'; }

# ---------------------------------------------------------------------------
echo "# cluster ${CTX} (${IMAGE})"
k3d cluster delete "${NAME}" >/dev/null 2>&1 || true
k3d cluster create "${NAME}" --image "${IMAGE}" --no-lb --wait --timeout 180s \
  --kubeconfig-update-default --kubeconfig-switch-context=false \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' >/dev/null
k wait --for=condition=Ready node --all --timeout=120s >/dev/null
NODE_IP="$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"

# Minimal ArgoCD CRDs (schema-less, no status subresource: tests set .status).
for kind in Application AppProject; do
  plural="$(tr '[:upper:]' '[:lower:]' <<<"${kind}")s"
  cat <<EOF | k apply -f - >/dev/null
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: ${plural}.argoproj.io
spec:
  group: argoproj.io
  scope: Namespaced
  names: {kind: ${kind}, plural: ${plural}, singular: $(tr '[:upper:]' '[:lower:]' <<<"${kind}")}
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
done
k wait --for=condition=Established crd/applications.argoproj.io crd/appprojects.argoproj.io --timeout=60s >/dev/null

# ---------------------------------------------------------------------------
# Payload + sandbox host root
# ---------------------------------------------------------------------------
ROOT="${T}/root"
BID="teknoir-local-aoa0.0.4-20261009-i1111111-g2222222"
PAYLOAD="${ROOT}/var/lib/teknoir-airgap/bundles/${BID}/node"
mkdir -p "${PAYLOAD}/site" "${PAYLOAD}/charts" "${ROOT}/run"
cp -r "${SRC}/bin" "${SRC}/lib" "${SRC}/templates" "${PAYLOAD}/"
if [[ -n "${AGE_BIN:-}" ]]; then
  cp "${AGE_BIN}" "${PAYLOAD}/bin/age"
fi
cat > "${PAYLOAD}/site/test.env" <<EOF
TEKNOIR_ENV=teknoir-local
TEKNOIR_DOMAIN=teknoir.airgapped
NODE_IP=${NODE_IP}
NODE=teknoir@${NODE_IP}
TEKNOIR_HOSTNAMES="harbor argocd auth keycloak grafana"
K3S_DATA_DIR=/opt/k3s
EOF
echo "app-of-apps 0.0.4" > "${PAYLOAD}/charts/pins.txt"
( cd "${PAYLOAD}" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort | xargs sha256sum ) > "${T}/sums"
mv "${T}/sums" "${PAYLOAD}/SHA256SUMS"

manifest() {
  # manifest <aoa> - the MANIFEST.yaml next to node/ (a new bundle identity)
  cat > "${PAYLOAD}/../MANIFEST.yaml" <<EOF
bundleId: teknoir-local-aoa$1-test
env: teknoir-local
domain: teknoir.airgapped
appOfAppsVersion: "$1"
infraCommit: 1111111
gitopsCommit: 2222222
files:
  node/SHA256SUMS: $(sha256sum "${PAYLOAD}/SHA256SUMS" | cut -d' ' -f1)
EOF
}
manifest 0.0.4

OUTS="${T}/outputs"
mkdir -p "${OUTS}"
tn() {
  # tn <args...> - run teknoir-node; stdout+stderr kept for the leak check.
  local n
  n="$(find "${OUTS}" -type f | wc -l)"
  RC=0
  env TEKNOIR_HOST_ROOT="${ROOT}" KUBECTL="kubectl --context ${CTX}" WAIT_INTERVAL=1 POST_POLL=1 \
    "${PAYLOAD}/bin/teknoir-node" "$@" > "${OUTS}/${n}.out" 2>&1 || RC=$?
  cp "${OUTS}/${n}.out" "${T}/out"
  (( VERBOSE )) && sed 's/^/    | /' "${T}/out"
  return 0
}
CLUSTER_PHASES="cluster-base,secrets,release"

# ---------------------------------------------------------------------------
echo "# I-12: no automatic backup before the first release"
tn converge --site test --only backup --dry-run
check "dry-run on a cluster without a release predicts no backup" \
  bash -c "[ ${RC} = 0 ] && grep -q 'no release deployed yet' '${T}/out' && ! grep -q 'would take a pre-change backup' '${T}/out'"
tn converge --site test --only backup
check "converge on a cluster without a release skips the backup" \
  bash -c "[ ${RC} = 0 ] && grep -q 'no release deployed yet' '${T}/out' && [ ! -d '${ROOT}/var/lib/teknoir-airgap/backups' ]"

# ---------------------------------------------------------------------------
echo "# T7: first converge of the cluster phases"
tn converge --site test --only "${CLUSTER_PHASES}"
check "first converge succeeds" [ "${RC}" == 0 ]
check "namespaces created" bash -c "kubectl --context ${CTX} get ns istio-system cert-manager teknoir-system teknoir-auth -o name >/dev/null"
check "teknoir-system starts with istio-injection=enabled" \
  [ "$(k get ns teknoir-system -o 'jsonpath={.metadata.labels.istio-injection}')" == enabled ]
check "coredns-custom carries NODE_IP for every name" \
  [ "$(k -n kube-system get cm coredns-custom -o 'jsonpath={.data.teknoir\.server}' | grep -c "${NODE_IP} ")" == 6 ]
check "node labelled teknoir.org/storage=true" \
  [ "$(k get nodes -o 'jsonpath={.items[0].metadata.labels.teknoir\.org/storage}')" == true ]
k -n cert-manager get secret teknoir-root-ca -o 'jsonpath={.data.tls\.crt}' | base64 -d > "${T}/ca.crt"
check "the CA is name-constrained to the domain" \
  bash -c "openssl x509 -in '${T}/ca.crt' -noout -text | grep -A3 'Name Constraints' | grep -q 'DNS:teknoir.airgapped' &&
           openssl x509 -in '${T}/ca.crt' -noout -text | grep -A3 'Name Constraints' | grep -q 'DNS:.teknoir.airgapped' &&
           openssl x509 -in '${T}/ca.crt' -noout -text | grep -q 'CA:TRUE, pathlen:0'"
k -n istio-system get secret teknoir-airgapped-wildcard-tls -o 'jsonpath={.data.tls\.crt}' | base64 -d > "${T}/wild.crt"
check "the wildcard placeholder verifies against the CA" bash -c "openssl verify -CAfile '${T}/ca.crt' '${T}/wild.crt' >/dev/null"
check "harbor-token-service is a TLS Secret" \
  [ "$(k -n teknoir-system get secret harbor-token-service -o 'jsonpath={.type}')" == kubernetes.io/tls ]
check "CA bundle copies hold only the CA certificate" \
  bash -c "for ns in teknoir-auth teknoir-system; do
             [ \"\$(kubectl --context ${CTX} -n \$ns get secret teknoir-root-ca-bundle -o 'jsonpath={.data}' | jq -r 'keys | join(\",\")')\" = ca.crt ] || exit 1
             kubectl --context ${CTX} -n \$ns get secret teknoir-root-ca-bundle -o 'jsonpath={.data.ca\\.crt}' | base64 -d | cmp -s - '${T}/ca.crt' || exit 1
           done"
check "argocd-tls-certs-cm trusts the CA for harbor.<domain>" \
  bash -c "kubectl --context ${CTX} -n teknoir-system get cm argocd-tls-certs-cm -o json | jq -j '.data[\"harbor.teknoir.airgapped\"]' | cmp -s - '${T}/ca.crt'"
check "root Application pins app-of-apps 0.0.4" \
  [ "$(k -n teknoir-system get applications.argoproj.io app-of-apps -o 'jsonpath={.spec.source.targetRevision}')" == 0.0.4 ]
check "release record written" \
  [ "$(k -n teknoir-system get cm teknoir-airgap-release -o 'jsonpath={.data.bundleId} {.data.mode}')" == "teknoir-local-aoa0.0.4-test install" ]
check "objects are owned by field manager teknoir-bootstrap" \
  bash -c "kubectl --context ${CTX} -n kube-system get cm coredns-custom --show-managed-fields -o json | jq -e '[.metadata.managedFields[].manager] | index(\"teknoir-bootstrap\")' >/dev/null"

OBJS=(
  "cert-manager secret teknoir-root-ca"
  "istio-system secret teknoir-airgapped-wildcard-tls"
  "teknoir-system secret harbor-token-service"
  "teknoir-auth secret teknoir-root-ca-bundle"
  "teknoir-system secret teknoir-root-ca-bundle"
  "teknoir-system configmap argocd-tls-certs-cm"
  "kube-system configmap coredns-custom"
  "teknoir-system applications.argoproj.io app-of-apps"
  "teknoir-system appprojects.argoproj.io default"
  "teknoir-system configmap teknoir-airgap-release"
)
snapshot() { local o; for o in "${OBJS[@]}"; do read -r a b c <<<"${o}"; printf '%s %s\n' "${o}" "$(rv "${a}" "${b}" "${c}")"; done; }
snapshot > "${T}/rv1"

echo "# T7: second converge is a no-op"
tn converge --site test --only "${CLUSTER_PHASES}"
check "second converge succeeds" [ "${RC}" == 0 ]
check "second converge reports 0 changes" grep -q 'summary: 0 changes' "${T}/out"
snapshot > "${T}/rv2"
check "every object keeps its resourceVersion" cmp -s "${T}/rv1" "${T}/rv2"

echo "# T7: deleting the wildcard Secret re-creates only it"
k -n istio-system delete secret teknoir-airgapped-wildcard-tls >/dev/null
tn converge --site test --only "${CLUSTER_PHASES}"
check "converge after the delete succeeds" [ "${RC}" == 0 ]
check "exactly one change" grep -q 'summary: 1 change(s)' "${T}/out"
snapshot > "${T}/rv3"
check "only the wildcard Secret changed" \
  [ "$(diff "${T}/rv2" "${T}/rv3" | grep -c '^>')" == 1 -a "$(diff "${T}/rv2" "${T}/rv3" | grep '^>' | grep -c wildcard)" == 1 ]

echo "# dry-run against a converged cluster"
tn converge --site test --only "${CLUSTER_PHASES}" --dry-run
check "dry-run on a converged cluster reports 0 would-changes" grep -q 'summary (dry-run): 0 change(s) would be made' "${T}/out"
k -n kube-system patch cm coredns-custom --type merge -p '{"data":{"teknoir.server":"drift"}}' >/dev/null
before="$(rv kube-system configmap coredns-custom)"
tn converge --site test --only cluster-base --dry-run
check "dry-run reports drift as a would-change" grep -q 'would change: server-side apply ConfigMap/coredns-custom' "${T}/out"
check "dry-run leaves the drift in place" [ "$(rv kube-system configmap coredns-custom)" == "${before}" ]
tn converge --site test --only cluster-base
check "converge repairs the drift" [ "$(k -n kube-system get cm coredns-custom -o 'jsonpath={.data.teknoir\.server}' | grep -c "${NODE_IP} ")" == 6 ]

# ---------------------------------------------------------------------------
echo "# I-10: downgrade guard and rollback"
manifest 0.0.3
tn converge --site test --only release
check "an older bundle is refused without --rollback" bash -c "[ ${RC} != 0 ] && grep -q 'refusing a downgrade' '${T}/out'"
check "the pin is unchanged after the refusal" \
  [ "$(k -n teknoir-system get applications.argoproj.io app-of-apps -o 'jsonpath={.spec.source.targetRevision}')" == 0.0.4 ]
tn converge --site test --only release --rollback --lan-user tester
check "--rollback is accepted" [ "${RC}" == 0 ]
check "the root Application is pinned to 0.0.3" \
  [ "$(k -n teknoir-system get applications.argoproj.io app-of-apps -o 'jsonpath={.spec.source.targetRevision}')" == 0.0.3 ]
check "the rollback is recorded with the operator" \
  bash -c "[ \"\$(kubectl --context ${CTX} -n teknoir-system get cm teknoir-airgap-release -o 'jsonpath={.data.mode}')\" = rollback ] &&
           kubectl --context ${CTX} -n teknoir-system get cm teknoir-airgap-release -o 'jsonpath={.data.history}' | head -1 | grep -q 'rollback teknoir-local-aoa0.0.3-test app-of-apps=0.0.3 by tester@lan'"
tn converge --site test --only release
check "the next plain run with the rolled-back bundle keeps it, 0 changes" \
  bash -c "[ ${RC} = 0 ] && grep -q 'summary: 0 changes' '${T}/out'"
manifest 0.0.2
tn converge --site test --only release --rollback
check "a broken version is refused even with --rollback" bash -c "[ ${RC} != 0 ] && grep -q 'must never be deployed' '${T}/out'"
manifest 0.0.4
tn converge --site test --only release
check "rolling forward to 0.0.4 again is an update" \
  [ "$(k -n teknoir-system get cm teknoir-airgap-release -o 'jsonpath={.data.mode} {.data.previousAppOfAppsVersion}')" == "update 0.0.3" ]

echo "# I-10: post"
root_status() {
  # root_status <compared rev> <synced rev> <operation phase> <reconciledAt> -
  # set the root's status as ArgoCD would (no controller runs here).
  local src
  src="$(k -n teknoir-system get applications.argoproj.io app-of-apps -o json | jq -c --arg r "$1" '.spec.source | .targetRevision = $r')"
  k -n teknoir-system patch applications.argoproj.io app-of-apps --type merge -p "$(jq -cn --argjson s "${src}" \
    --arg rev "$2" --arg op "$3" --arg at "$4" \
    '{status: {sync: {status: "Synced", revision: $rev, comparedTo: {source: $s}},
               health: {status: "Healthy"}, operationState: {phase: $op}, reconciledAt: $at}}')" >/dev/null
}
fake_argocd_refresh() {
  # Plays ArgoCD for the root: once the refresh annotation appears, reconcile
  # one second later (status for the current spec, reconciledAt now) and
  # consume the annotation.
  local src
  for _ in $(seq 1 120); do
    if [ -n "$(k -n teknoir-system get applications.argoproj.io app-of-apps -o 'jsonpath={.metadata.annotations.argocd\.argoproj\.io/refresh}')" ]; then
      sleep 1
      src="$(k -n teknoir-system get applications.argoproj.io app-of-apps -o json | jq -c '.spec.source')"
      k -n teknoir-system patch applications.argoproj.io app-of-apps --type merge -p "$(jq -cn --argjson s "${src}" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{metadata: {annotations: {"argocd.argoproj.io/refresh": null}},
          status: {reconciledAt: $now, sync: {status: "Synced", revision: $s.targetRevision, comparedTo: {source: $s}},
                   health: {status: "Healthy"}, operationState: {phase: "Succeeded"}}}')" >/dev/null
      return 0
    fi
    sleep 0.5
  done
  return 1
}
OLD_TS="2020-01-01T00:00:00Z"
root_status 0.0.3 0.0.3 Succeeded "${OLD_TS}"
tn converge --site test --only post --wait-timeout 3
check "a stale root status (compared with the old pin) is not ready" \
  bash -c "[ ${RC} != 0 ] && grep -qF 'not Synced/Healthy at this release: app-of-apps (status not computed for the current spec yet (compared: 0.0.3)' '${T}/out'"
root_status 0.0.4 0.0.4 Running "${OLD_TS}"
tn converge --site test --only post --wait-timeout 3
check "a running sync operation is not ready" bash -c "[ ${RC} != 0 ] && grep -qF 'app-of-apps (sync operation Running' '${T}/out'"
root_status 0.0.4 0.0.3 Succeeded "${OLD_TS}"
tn converge --site test --only post --wait-timeout 3
check "a chart revision other than the pin is not ready" \
  bash -c "[ ${RC} != 0 ] && grep -qF 'app-of-apps (synced revision 0.0.3, pinned 0.0.4' '${T}/out'"
root_status 0.0.4 0.0.4 Succeeded "${OLD_TS}"
tn converge --site test --only post --wait-timeout 5
check "post passes when every Application is Synced/Healthy at its current spec" [ "${RC}" == 0 ]
k -n teknoir-system annotate applications.argoproj.io app-of-apps argocd.argoproj.io/refresh- >/dev/null
tn converge --site test --only release,post --wait-timeout 4
check "release asks ArgoCD to refresh the root" \
  [ "$(k -n teknoir-system get applications.argoproj.io app-of-apps -o 'jsonpath={.metadata.annotations.argocd\.argoproj\.io/refresh}')" == normal ]
check "after this run's pin, a root not reconciled since is not ready" \
  bash -c "[ ${RC} != 0 ] && grep -qF 'app-of-apps (not reconciled since this run pinned it)' '${T}/out'"
k -n teknoir-system annotate applications.argoproj.io app-of-apps argocd.argoproj.io/refresh- >/dev/null
fake_argocd_refresh &
FAKE_PID=$!
tn converge --site test --only release,post --wait-timeout 60
FAKE_RC=0
wait "${FAKE_PID}" || FAKE_RC=$?
check "release + post pass once ArgoCD has reconciled the root after the pin" \
  bash -c "[ ${RC} = 0 ] && [ ${FAKE_RC} = 0 ] && grep -q 'every Application is Synced/Healthy at its current spec' '${T}/out'"
cat <<'APP' | k apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: broken, namespace: teknoir-system}
spec: {project: default}
status:
  sync: {status: OutOfSync}
  health: {status: Degraded}
  operationState: {phase: Failed, message: "one or more objects failed to apply"}
APP
tn converge --site test --only post --wait-timeout 3
check "post fails and names the failing Application" \
  bash -c "[ ${RC} != 0 ] && grep -qF 'not Synced/Healthy at this release: broken (OutOfSync/Degraded' '${T}/out' && grep -qF 'broken: OutOfSync/Degraded | Failed one or more objects failed to apply' '${T}/out'"
k -n teknoir-system delete applications.argoproj.io broken >/dev/null

echo "# status"
tn status --site test
check "status is read-only and reports release, certificates and Applications" \
  bash -c "[ ${RC} = 0 ] && grep -q 'release:   app-of-apps 0.0.4' '${T}/out' && grep -q 'cert:      cert-manager/teknoir-root-ca' '${T}/out' && grep -q '^APPLICATION' '${T}/out'"

# ---------------------------------------------------------------------------
echo "# I-07: credentials and rotate"
k -n teknoir-system create secret generic harbor-secret \
  --from-literal=HARBOR_ADMIN_PASSWORD="$(openssl rand -hex 16)" --from-literal=secretKey="$(openssl rand -hex 8)" >/dev/null
k -n teknoir-auth create secret generic oauth2-proxy-secret \
  --from-literal=client-secret="$(openssl rand -hex 16)" --from-literal=cookie-secret="$(openssl rand -hex 16)" >/dev/null
tn credentials harbor-admin --site test --out "${T}/harbor-admin.txt"
want="$(k -n teknoir-system get secret harbor-secret -o 'jsonpath={.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"
check "credentials --out writes the value" [ "$(cat "${T}/harbor-admin.txt")" == "${want}" ]
check "credentials --out file is 0600" [ "$(stat -c %a "${T}/harbor-admin.txt")" == 600 ]
got="$(env TEKNOIR_HOST_ROOT="${ROOT}" KUBECTL="kubectl --context ${CTX}" "${PAYLOAD}/bin/teknoir-node" credentials harbor-admin --site test 2>"${OUTS}/cred.err" | cat)"
check "credentials to a pipe writes the value to stdout only" \
  bash -c "[ '${got}' = '${want}' ] && ! grep -qF '${want}' '${OUTS}/cred.err'"
client_before="$(k -n teknoir-auth get secret oauth2-proxy-secret -o 'jsonpath={.data.client-secret}')"
cookie_before="$(k -n teknoir-auth get secret oauth2-proxy-secret -o 'jsonpath={.data.cookie-secret}')"
tn rotate oauth2-proxy-cookie --site test
check "rotate oauth2-proxy-cookie succeeds" [ "${RC}" == 0 ]
check "the cookie secret changed" [ "$(k -n teknoir-auth get secret oauth2-proxy-secret -o 'jsonpath={.data.cookie-secret}')" != "${cookie_before}" ]
check "the new cookie secret decodes to 32 bytes (base64url)" \
  [ "$(k -n teknoir-auth get secret oauth2-proxy-secret -o 'jsonpath={.data.cookie-secret}' | base64 -d | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c)" == 32 ]
check "the client secret did not change" [ "$(k -n teknoir-auth get secret oauth2-proxy-secret -o 'jsonpath={.data.client-secret}')" == "${client_before}" ]
tn rotate keycloak-db --site test
check "rotate keycloak-db is refused without --i-know" bash -c "[ ${RC} != 0 ] && grep -q 'i-know' '${T}/out'"

# ---------------------------------------------------------------------------
echo "# I-12: backup without database pods (first install interrupted, DB restarting)"
tn converge --site test --only backup --backup
B="$(find "${ROOT}/var/lib/teknoir-airgap/backups" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | tail -1)"
check "converge --backup without DB pods completes" bash -c "[ ${RC} = 0 ] && grep -q 'backup complete' '${T}/out'"
check "both missing databases are warned about" [ "$(grep -c 'WARN: backup: no running pod' "${T}/out")" == 2 ]
check "BACKUP.info lists no database, and no dump file exists" \
  bash -c "grep -qx 'databases=' '${B}/BACKUP.info' && [ -z \"\$(ls -A '${B}/db')\" ]"
manifest 0.0.5
sleep 1
tn converge --site test --only backup
check "an update (other bundle) without DB pods still takes its pre-change backup" \
  bash -c "[ ${RC} = 0 ] && grep -q 'backup (pre-change to teknoir-local-aoa0.0.5-test)' '${T}/out' && grep -q 'backup complete' '${T}/out'"
manifest 0.0.4

echo "# I-12: backup"
pg_pod() {
  # pg_pod <ns> <name> <container> <labels-json> <user>
  cat <<EOF | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: $2, namespace: $1, labels: $4}
spec:
  containers:
    - name: $3
      image: ${PG_IMAGE}
      env:
        - {name: POSTGRES_USER, value: $5}
        - {name: POSTGRES_PASSWORD, value: unused-test-only}
EOF
}
pg_pod teknoir-system harbor-database-0 database '{"app": "harbor", "component": "database"}' postgres
pg_pod teknoir-auth keycloak-db-0 postgres '{"app": "keycloak-db"}' keycloak
k -n teknoir-system wait --for=condition=Ready pod/harbor-database-0 --timeout=240s >/dev/null
k -n teknoir-auth wait --for=condition=Ready pod/keycloak-db-0 --timeout=240s >/dev/null
for _ in $(seq 1 30); do
  k -n teknoir-auth exec keycloak-db-0 -c postgres -- pg_isready -q >/dev/null 2>&1 \
    && k -n teknoir-system exec harbor-database-0 -c database -- pg_isready -q >/dev/null 2>&1 && break
  sleep 2
done
k -n teknoir-auth exec keycloak-db-0 -c postgres -- psql -U keycloak -c 'CREATE TABLE realm_marker (id int);' >/dev/null
tn converge --site test --only backup
check "converge skips the pre-change backup for the deployed bundle" grep -q 'already deployed: no pre-change backup' "${T}/out"
tn converge --site test --only backup --backup
check "converge --backup takes one" bash -c "[ ${RC} = 0 ] && grep -q 'backup complete' '${T}/out'"
B="$(find "${ROOT}/var/lib/teknoir-airgap/backups" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | sort | tail -1)"
check "backup dir is 0700" [ "$(stat -c %a "${B}")" == 700 ]
check "harbor dump through kubectl exec" bash -c "gzip -dc '${B}/db/harbor.sql.gz' | grep -q 'PostgreSQL database cluster dump'"
check "keycloak dump holds the keycloak tables" bash -c "gzip -dc '${B}/db/keycloak.sql.gz' | grep -q 'CREATE TABLE public.realm_marker'"
check "Secrets export holds the CA and harbor-secret, mode 0600" \
  bash -c "jq -e '[.items[].metadata.name] | (index(\"teknoir-root-ca\") != null and index(\"harbor-secret\") != null)' '${B}/secrets/bootstrap-secrets.json' >/dev/null &&
           [ \$(stat -c %a '${B}/secrets/bootstrap-secrets.json') = 600 ]"
check "backup SHA256SUMS verifies" bash -c "cd '${B}' && sha256sum --quiet -c SHA256SUMS"
for _ in 1 2 3; do sleep 1; tn backup --site test; done
check "only the last 3 backups are kept" \
  [ "$(find "${ROOT}/var/lib/teknoir-airgap/backups" -mindepth 1 -maxdepth 1 -type d -name '2*Z' | wc -l)" == 3 ]
if [[ -n "${AGE_BIN:-}" && -x "$(dirname "${AGE_BIN}")/age-keygen" ]]; then
  "$(dirname "${AGE_BIN}")/age-keygen" -o "${T}/age.key" 2>/dev/null
  recip="$(grep -o 'age1[0-9a-z]*' "${T}/age.key" | head -1)"
  env TEKNOIR_HOST_ROOT="${ROOT}" KUBECTL="kubectl --context ${CTX}" "${PAYLOAD}/bin/teknoir-node" backup --site test --recipient "${recip}" \
    > "${T}/backup.age" 2> "${OUTS}/backup-age.err" || true
  check "the age stream has no plaintext" bash -c "! grep -q 'PRIVATE KEY' '${T}/backup.age' && ! grep -qa 'harbor-secret' '${T}/backup.age'"
  check "the age stream decrypts to the latest backup" \
    bash -c "'${AGE_BIN}' -d -i '${T}/age.key' '${T}/backup.age' | tar -tf - | grep -q 'secrets/bootstrap-secrets.json'"
else
  echo "skip backup --recipient (set AGE_BIN)"
fi

# ---------------------------------------------------------------------------
echo "# I-07: rotate keycloak-db --i-know against the postgres stand-in"
# The stand-in's password is the pod's POSTGRES_PASSWORD; the Secret holds the
# same user name as the platform-secrets literal ("keycloak").
k -n teknoir-auth create secret generic keycloak-db-secret \
  --from-literal=username=keycloak --from-literal=password=unused-test-only >/dev/null
db_login() {
  # db_login - read a password on stdin and log in over TCP to the pod IP
  # (scram-sha-256; the loopback rules of the image are trust).
  # shellcheck disable=SC2016 # expanded by the pod's shell
  k -n teknoir-auth exec -i keycloak-db-0 -c postgres -- \
    sh -c 'PGPASSWORD="$(cat)" psql -h "$(hostname -i)" -U keycloak -d postgres -tAc "select 1"' 2>/dev/null
}
check "the stand-in accepts the old password over TCP" [ "$(printf 'unused-test-only' | db_login)" == 1 ]
tn rotate keycloak-db --site test --i-know
check "rotate keycloak-db --i-know succeeds (no leak-check exit 70)" \
  bash -c "[ ${RC} = 0 ] && ! grep -q 'leak check' '${T}/out' && grep -q 'replaced teknoir-auth/keycloak-db-secret password' '${T}/out'"
newpw="$(k -n teknoir-auth get secret keycloak-db-secret -o 'jsonpath={.data.password}' | base64 -d)"
check "the Secret holds a new 32-character password" bash -c "[ \${#1} = 32 ] && [ \"\$1\" != unused-test-only ]" _ "${newpw}"
check "the database accepts the new password" [ "$(printf '%s' "${newpw}" | db_login)" == 1 ]
check "the database refuses the old password" [ "$(printf 'unused-test-only' | db_login || true)" != 1 ]
check "the user name is unchanged" \
  [ "$(k -n teknoir-auth get secret keycloak-db-secret -o 'jsonpath={.data.username}' | base64 -d)" == keycloak ]
newpw=""
k -n teknoir-auth create secret generic keycloak-admin \
  --from-literal=username=keycloak --from-literal=password="$(openssl rand -hex 16)" >/dev/null
tn credentials keycloak-admin-username --site test --out "${T}/kc-user.txt"
check "credentials of a user name (a word in every log line) pass the leak check" \
  bash -c "[ ${RC} = 0 ] && [ \"\$(cat '${T}/kc-user.txt')\" = keycloak ]"

# ---------------------------------------------------------------------------
echo "# T8: never print"
# Every value of every Secret in the Teknoir namespaces (private keys line by
# line; public certificates and user names are not secret: a user name such
# as "keycloak" is part of ordinary log lines).
k get secret -A -o json | jq -r '
  .items[] | select(.metadata.namespace | test("^(cert-manager|istio-system|teknoir-system|teknoir-auth)$")) |
  .data // {} | to_entries[] | select(.key != "tls.crt" and .key != "ca.crt" and .key != "username") | .value' \
  | while read -r v; do printf '%s' "${v}" | base64 -d; printf '\n'; done \
  | grep -vE '^-----(BEGIN|END)' | awk 'length($0) >= 8' | sort -u > "${T}/values"
nvalues="$(wc -l < "${T}/values")"
LOGS="${ROOT}/var/log/teknoir-airgap"
hits="$(cat "${OUTS}"/* "${LOGS}"/* | grep -cF -f "${T}/values" || true)"
check "no Secret value (${nvalues} checked) in $(find "${OUTS}" "${LOGS}" -type f | wc -l) outputs and logs" [ "${hits}" == 0 ]
check "no private key in any output or log" bash -c "! cat '${OUTS}'/* '${LOGS}'/* | grep -q 'PRIVATE KEY'"
check "every run log is 0600" [ "$(find "${LOGS}" -type f -printf '%m\n' | sort -u)" == 600 ]

echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
