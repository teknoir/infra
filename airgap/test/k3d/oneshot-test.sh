#!/usr/bin/env bash
# oneshot-test.sh — k3d test of lib/oneshot.sh (DESIGN I-08, part of T6/T7).
#
# A small fake bundle (node/oneshot/TIERS + renders) exercises: CRDs applied
# and Established before their custom resources; server-side apply as field
# manager argocd-controller; namespaces defaulted like ArgoCD; Sync hook Job
# run, waited for and removed; PostSync hook and unserved kinds left alone; a
# tier still owned by a K3s file skipped; the tier skipped once its ArgoCD
# Application exists; --reapply as break-glass; no change on a re-run;
# dry-run read-only; a failed Job stops the phase and is re-created next run.
#
# Usage: airgap/test/k3d/oneshot-test.sh [--keep]
# Needs docker, k3d, kubectl, jq and internet access for the pause/busybox images.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
CLUSTER="${CLUSTER:-tkn2-oneshot}"
CTX="k3d-${CLUSTER}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-oneshot.XXXXXX")"
NODE="${WORK}/node"
mkdir -p "${NODE}/oneshot" "${NODE}/bin" "${WORK}/k3s/server/manifests" "${WORK}/out"
ln -s "$(command -v jq)" "${NODE}/bin/jq"

PASS=0
FAIL=0
FAILED=()
say()  { printf '\n=== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
K() { kubectl --context "${CTX}" "$@"; }
node_fn() {
  env KUBECTL="kubectl --context ${CTX}" NODE_ROOT="${NODE}" K3S_DATA_DIR="${WORK}/k3s" \
    TEKNOIR_DOMAIN=teknoir.airgapped ONESHOT_TIMEOUT=300 STUB_WAIT_INTERVAL=2 \
    "${REPO}/airgap/test/stubs/teknoir-node-stub" "$@"
}
cleanup() {
  local rc=$?
  if [[ "${KEEP}" == "1" ]]; then
    echo "kept: cluster ${CLUSTER}, work dir ${WORK}"
  else
    k3d cluster delete "${CLUSTER}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

# --- fake bundle -------------------------------------------------------------
cat > "${NODE}/oneshot/TIERS" <<'EOF'
# tier [namespace for objects without one]
platform-secrets
istio
argo
EOF
cat > "${NODE}/oneshot/platform-secrets.yaml" <<'EOF'
---
# Source: platform-secrets/templates/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-secrets
  namespace: teknoir-system
---
# no namespace in the render: ArgoCD puts it in the destination namespace
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-secrets-spec
data:
  spec: "keycloak-admin"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-pre-install
  namespace: teknoir-system
  annotations:
    helm.sh/hook: pre-install
data: {k: v}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: platform-secrets-ensure
  namespace: teknoir-system
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        sidecar.istio.io/inject: "false"
    spec:
      restartPolicy: Never
      serviceAccountName: platform-secrets
      containers:
        - name: ensure
          image: docker.io/library/busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "echo ensured"]
---
apiVersion: batch/v1
kind: Job
metadata:
  name: oidc-config
  namespace: teknoir-system
  annotations:
    argocd.argoproj.io/hook: PostSync
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: c
          image: docker.io/library/busybox:1.36
          command: ["sh", "-c", "exit 1"]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: not-served-yet
  namespace: teknoir-system
spec: {}
EOF
cat > "${NODE}/oneshot/istio-crds.yaml" <<'EOF'
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: gateways.networking.istio.io
  annotations:
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
spec:
  group: networking.istio.io
  names: {plural: gateways, singular: gateway, kind: Gateway, listKind: GatewayList}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
cat > "${NODE}/oneshot/istio.yaml" <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
  labels:
    istio-injection: disabled
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istiod
spec:
  replicas: 1
  selector:
    matchLabels: {app: istiod}
  template:
    metadata:
      labels: {app: istiod}
    spec:
      containers:
        - name: discovery
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: teknoir-gateway
spec:
  selector: {istio: ingressgateway}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: istiod-demo
rules: []
EOF
cat > "${NODE}/oneshot/argo.yaml" <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: teknoir-system
data: {}
EOF
# teknoir-argo is still a K3s file on the live node until DESIGN M7
echo "# legacy" > "${WORK}/k3s/server/manifests/teknoir-argo.yaml"

# --- cluster ------------------------------------------------------------------
say "k3d cluster ${CLUSTER} (${K3S_IMAGE})"
k3d cluster create "${CLUSTER}" --image "${K3S_IMAGE}" --servers 1 --agents 0 --no-lb \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' \
  --wait --timeout 180s >/dev/null
K wait --for=condition=Ready node --all --timeout=120s >/dev/null
K create namespace teknoir-system >/dev/null   # cluster-base creates the namespaces

say "first converge of the one-shot phase"
if node_fn phase_oneshot > "${WORK}/out/run1.log" 2>&1; then ok "phase_oneshot exits 0"; else bad "phase_oneshot exits 0"; cat "${WORK}/out/run1.log"; fi
check "CRD gateways.networking.istio.io Established" K wait --for=condition=Established crd/gateways.networking.istio.io --timeout=5s
check "the Gateway (needs the CRD) exists, defaulted into istio-system" K -n istio-system get gateways.networking.istio.io teknoir-gateway -o name
check "istiod defaulted into istio-system and rolled out" K -n istio-system rollout status deployment/istiod --timeout=5s
check "istiod is managed by argocd-controller (Apply)" bash -c "kubectl --context ${CTX} -n istio-system get deploy istiod --show-managed-fields -o json | jq -e '[.metadata.managedFields[] | select(.manager == \"argocd-controller\" and .operation == \"Apply\")] | length == 1' >/dev/null"
check "the ClusterRole kept no namespace" K get clusterrole istiod-demo -o name
check "namespace-less ConfigMap went to teknoir-system" K -n teknoir-system get cm platform-secrets-spec -o name
check "the Helm pre-install hook (PreSync) was applied" K -n teknoir-system get cm helm-pre-install -o name
check "the Sync hook Job ran and was removed after success" bash -c "grep -q 'Job teknoir-system/platform-secrets-ensure complete' '${WORK}/out/run1.log' && ! kubectl --context ${CTX} -n teknoir-system get job platform-secrets-ensure -o name 2>/dev/null"
check "the PostSync hook Job was left to ArgoCD" bash -c "! kubectl --context ${CTX} -n teknoir-system get job oidc-config -o name 2>/dev/null && grep -q 'left to ArgoCD (hook): Job teknoir-system/oidc-config (PostSync)' '${WORK}/out/run1.log'"
check "the unserved ServiceMonitor was skipped with a warning" grep -q 'left to ArgoCD, their kinds are not served yet.*not-served-yet' "${WORK}/out/run1.log"
check "tier argo skipped: the K3s file still owns it" bash -c "grep -q 'tier argo: skipped, the K3s file' '${WORK}/out/run1.log' && ! kubectl --context ${CTX} -n teknoir-system get cm argocd-cm -o name 2>/dev/null"

say "second converge: istio unchanged; platform-secrets (no Application yet) runs its Job again"
node_fn phase_oneshot > "${WORK}/out/run2.log" 2>&1 || bad "second run exits 0"
check "istio: nothing applied (CRDs and objects)" bash -c "grep -q 'istio CRDs: the live objects equal the render: nothing applied' '${WORK}/out/run2.log' && grep -q 'istio: the live objects equal the render: nothing applied' '${WORK}/out/run2.log'"
check "istio: no change recorded" bash -c "! grep -q 'changed: applied istio' '${WORK}/out/run2.log'"

say "ArgoCD Applications exist: the tiers are skipped"
K apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: applications.argoproj.io}
spec:
  group: argoproj.io
  names: {plural: applications, singular: application, kind: Application, listKind: ApplicationList}
  scope: Namespaced
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
K wait --for=condition=Established crd/applications.argoproj.io --timeout=60s >/dev/null
for a in platform-secrets istio; do
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: {name: %s, namespace: teknoir-system}\nspec: {}\n' "${a}" | K apply -f - >/dev/null
done
node_fn phase_oneshot > "${WORK}/out/run3.log" 2>&1 || bad "third run exits 0"
check "adopted tiers skipped, 0 changes" bash -c "grep -q 'tier platform-secrets: Application teknoir-system/platform-secrets exists' '${WORK}/out/run3.log' && grep -q 'tier istio: Application teknoir-system/istio exists' '${WORK}/out/run3.log' && grep -q 'summary: 0 change' '${WORK}/out/run3.log'"

say "break-glass --reapply istio restores a drifted object; dry-run changes nothing"
K -n istio-system scale deployment/istiod --replicas=2 >/dev/null
DRY_RUN=1 node_fn phase_oneshot --reapply istio > "${WORK}/out/dry.log" 2>&1 || bad "dry-run exits 0"
check "dry-run: would apply, drift still there" bash -c "grep -q 'would server-side apply istio' '${WORK}/out/dry.log' && [[ \$(kubectl --context ${CTX} -n istio-system get deploy istiod -o jsonpath='{.spec.replicas}') == 2 ]]"
node_fn phase_oneshot --reapply istio > "${WORK}/out/reapply.log" 2>&1 || bad "--reapply exits 0"
check "--reapply warns and re-applies" bash -c "grep -q 'break-glass' '${WORK}/out/reapply.log' && grep -q 'changed: applied istio' '${WORK}/out/reapply.log'"
check "--reapply took spec.replicas back (force-conflicts)" bash -c "[[ \$(kubectl --context ${CTX} -n istio-system get deploy istiod -o jsonpath='{.spec.replicas}') == 1 ]]"
check "--reapply argo is refused while the K3s file owns it" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${NODE}' K3S_DATA_DIR='${WORK}/k3s' '${REPO}/airgap/test/stubs/teknoir-node-stub' phase_oneshot --reapply argo >/dev/null 2>&1"
check "--reapply of an unknown tier is refused" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${NODE}' K3S_DATA_DIR='${WORK}/k3s' '${REPO}/airgap/test/stubs/teknoir-node-stub' phase_oneshot --reapply nosuch >/dev/null 2>&1"

say "a failing Job stops the phase; the next run re-creates it"
mkdir -p "${WORK}/node2/oneshot" "${WORK}/node2/bin"
ln -s "$(command -v jq)" "${WORK}/node2/bin/jq"
echo "failing" > "${WORK}/node2/oneshot/TIERS"
cat > "${WORK}/node2/oneshot/failing.yaml" <<'EOF'
apiVersion: batch/v1
kind: Job
metadata: {name: always-fails, namespace: teknoir-system}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - {name: c, image: docker.io/library/busybox:1.36, imagePullPolicy: IfNotPresent, command: ["sh", "-c", "exit 3"]}
EOF
if env KUBECTL="kubectl --context ${CTX}" NODE_ROOT="${WORK}/node2" K3S_DATA_DIR="${WORK}/k3s" ONESHOT_TIMEOUT=120 STUB_WAIT_INTERVAL=2 \
     "${REPO}/airgap/test/stubs/teknoir-node-stub" phase_oneshot > "${WORK}/out/fail1.log" 2>&1; then
  bad "a failed Job makes the phase fail"
else
  check "a failed Job makes the phase fail, naming the Job" grep -q 'Job teknoir-system/always-fails Failed' "${WORK}/out/fail1.log"
fi
env KUBECTL="kubectl --context ${CTX}" NODE_ROOT="${WORK}/node2" K3S_DATA_DIR="${WORK}/k3s" ONESHOT_TIMEOUT=120 STUB_WAIT_INTERVAL=2 \
  "${REPO}/airgap/test/stubs/teknoir-node-stub" phase_oneshot > "${WORK}/out/fail2.log" 2>&1 || true
check "the re-run re-creates the failed Job" grep -q 'Job teknoir-system/always-fails failed earlier; re-creating it' "${WORK}/out/fail2.log"

say "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
