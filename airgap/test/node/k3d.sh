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
#       post fails naming an Application that is not Synced/Healthy
#   I-07 credentials --out (0600) and to a pipe; rotate oauth2-proxy-cookie
#       changes only that key
#   I-12 backup: pg_dumpall of harbor and keycloak through kubectl exec,
#       Secrets export (0600), keep 3; age stream when AGE_BIN is set
#
# Usage: airgap/test/node/k3d.sh [-v] [--keep]
#   AGE_BIN=/path/to/age   also test `backup --recipient` (needs age-keygen next to it)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/../../node" && pwd)"
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
k -n teknoir-system patch applications.argoproj.io app-of-apps --type merge \
  -p '{"status":{"sync":{"status":"Synced","revision":"0.0.4"},"health":{"status":"Healthy"}}}' >/dev/null
tn converge --site test --only post --wait-timeout 5
check "post passes when every Application is Synced/Healthy" [ "${RC}" == 0 ]
cat <<'EOF' | k apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: broken, namespace: teknoir-system}
spec: {project: default}
status:
  sync: {status: OutOfSync}
  health: {status: Degraded}
  operationState: {phase: Failed, message: "one or more objects failed to apply"}
EOF
tn converge --site test --only post --wait-timeout 3
check "post fails and names the failing Application" \
  bash -c "[ ${RC} != 0 ] && grep -q 'not Synced/Healthy: broken' '${T}/out' && grep -q 'broken: Failed one or more objects failed to apply' '${T}/out'"
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
echo "# T8: never print"
# Every value of every Secret in the Teknoir namespaces (private keys line by
# line; public certificates are not secret).
k get secret -A -o json | jq -r '
  .items[] | select(.metadata.namespace | test("^(cert-manager|istio-system|teknoir-system|teknoir-auth)$")) |
  .data // {} | to_entries[] | select(.key != "tls.crt" and .key != "ca.crt") | .value' \
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
