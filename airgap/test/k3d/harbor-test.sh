#!/usr/bin/env bash
# harbor-test.sh — test of lib/harbor.sh (DESIGN I-09) against a real
# registry:2 (OCI side) and stubs/fake-harbor-api.py (Harbor REST subset), with
# a throwaway k3d cluster holding harbor-secret and the ArgoCD Secrets.
#
# Checks: projects created public and a private one made public; the
# immutability rule on teknoir only; charts pushed, skipped when equal or only
# re-packed, refused when different; images pushed from an OCI layout and a
# docker archive, skipped when present (also inside a multi-arch index),
# refused when a mirror tag moved unless --force-images; robot$argocd kept
# while an ArgoCD Secret uses it, deleted after; a second run changes nothing;
# dry-run makes no mutating call, and plans from the bundle alone before
# harbor-secret exists or while the cluster is unreachable; a refusal exits
# non-zero under a runner-style EXIT handler, with and without at_exit; the
# password never appears in any output and nothing is written to $HOME or
# left in $TMPDIR.
#
# Usage: airgap/test/k3d/harbor-test.sh [--keep]
# Needs docker, k3d, kubectl, jq, crane, helm, python3, and internet access
# (busybox/alpine/registry:2 from Docker Hub).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
CLUSTER="${CLUSTER:-tkn2-harbor}"
CTX="k3d-${CLUSTER}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
REG_PORT="${REG_PORT:-5055}"
API_PORT="${API_PORT:-5056}"
REG="localhost:${REG_PORT}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-harbor.XXXXXX")"
NODE="${WORK}/node"
mkdir -p "${NODE}/bin" "${NODE}/charts" "${NODE}/images" "${NODE}/bootstrap-images" "${WORK}/out" "${WORK}/home" "${WORK}/tmp" "${WORK}/src" \
  "${WORK}/k3s/server/manifests" "${WORK}/legacy-home"
for t in crane helm jq; do ln -s "$(command -v "${t}")" "${NODE}/bin/${t}"; done

PASS=0
FAIL=0
FAILED=()
say()  { printf '\n=== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
K() { kubectl --context "${CTX}" "$@"; }

API_PID=""
ARGO_PID=""
cleanup() {
  local rc=$?
  [[ -z "${API_PID}" ]] || kill "${API_PID}" 2>/dev/null || true
  [[ -z "${ARGO_PID}" ]] || kill "${ARGO_PID}" 2>/dev/null || true
  if [[ "${KEEP}" == "1" ]]; then
    echo "kept: cluster ${CLUSTER}, registry container tkn2-registry, work dir ${WORK}"
  else
    docker rm -f tkn2-registry >/dev/null 2>&1 || true
    k3d cluster delete "${CLUSTER}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

harbor() {
  # run phase_harbor (or another function) like the node would, with an empty
  # HOME and a private TMPDIR so leftovers are visible
  env -i PATH="${PATH}" HOME="${WORK}/home" TMPDIR="${WORK}/tmp" \
    ${TEKNOIR_COMMON:+TEKNOIR_COMMON="${TEKNOIR_COMMON}"} STUB_NO_AT_EXIT="${STUB_NO_AT_EXIT:-0}" \
    KUBECTL="${KCTL:-kubectl --context ${CTX}}" KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}" KUBECACHEDIR="${WORK}/kcache" \
    NODE_ROOT="${NODE}" TEKNOIR_DOMAIN=teknoir.airgapped \
    HARBOR_API="http://127.0.0.1:${API_PORT}/api/v2.0" HARBOR_REGISTRY="${REG}" HARBOR_HELM_OPTS="--plain-http" \
    HARBOR_HOST="${REG}" K3S_DATA_DIR="${WORK}/k3s" MIGRATE_LEGACY_HOME="${WORK}/legacy-home" MIGRATE_ARGOCD_TIMEOUT=60 \
    HARBOR_HEALTH_TIMEOUT=30 STUB_WAIT_INTERVAL=1 DRY_RUN="${DRY_RUN:-0}" \
    "${REPO}/airgap/test/stubs/teknoir-node-stub" "$@"
}
th() {
  # the test's own helm calls, kept out of the operator's ~/.config/helm and ~/.cache/helm
  HELM_CONFIG_HOME="${WORK}/th/config" HELM_CACHE_HOME="${WORK}/th/cache" HELM_DATA_HOME="${WORK}/th/data" helm "$@"
}
api_calls() { grep -cE "^($1) /api" "${WORK}/out/api.log" || true; }
state() { curl -fsS "http://127.0.0.1:${API_PORT}/test/state"; }

# --- environment ----------------------------------------------------------------
say "registry:2 on ${REG}, fake Harbor API on :${API_PORT}, k3d cluster ${CLUSTER}"
docker run -d --name tkn2-registry -p "127.0.0.1:${REG_PORT}:5000" registry:2 >/dev/null
PW="pw-$(openssl rand -hex 12)"
( umask 077 && printf '%s' "${PW}" > "${WORK}/pw" )
: > "${WORK}/out/api.log"
python3 -I "${REPO}/airgap/test/stubs/fake-harbor-api.py" "${API_PORT}" "${WORK}/pw" "${WORK}/out/api.log" &
API_PID=$!
k3d cluster create "${CLUSTER}" --image "${K3S_IMAGE}" --servers 1 --agents 0 --no-lb \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' --wait --timeout 180s >/dev/null
K create namespace teknoir-system >/dev/null
K -n teknoir-system create secret generic harbor-secret --from-file=HARBOR_ADMIN_PASSWORD="${WORK}/pw" >/dev/null
K -n teknoir-system create secret generic argocd-harbor-repo \
  --from-literal=type=helm --from-literal=url=harbor.teknoir.airgapped/teknoir \
  --from-literal=username="robot\$argocd" --from-literal=password=dummy >/dev/null
K -n teknoir-system label secret argocd-harbor-repo argocd.argoproj.io/secret-type=repo-creds >/dev/null
curl -fsS -X POST "http://127.0.0.1:${API_PORT}/test/robot?name=argocd" >/dev/null

# --- bundle content ------------------------------------------------------------------
say "bundle: one chart, one OCI layout, one docker archive"
th create "${WORK}/src/demo" >/dev/null
sed -i 's/^version:.*/version: 0.1.0/' "${WORK}/src/demo/Chart.yaml"
th package "${WORK}/src/demo" -d "${NODE}/charts" >/dev/null
echo "demo 0.1.0" > "${NODE}/charts/pins.txt"
crane pull --format=oci --platform linux/amd64 docker.io/library/busybox:1.36.1 "${NODE}/images/busybox"
BUSYBOX_DIGEST="$(crane digest docker.io/library/busybox:1.36.1)"
echo "docker.io/library/busybox:1.36.1@${BUSYBOX_DIGEST} busybox" > "${NODE}/images/images.lock"
crane pull --platform linux/amd64 docker.io/library/alpine:3.20 "${NODE}/bootstrap-images/alpine_3.20.tar"
echo "  RepoTags of the archive: $(tar -xOf "${NODE}/bootstrap-images/alpine_3.20.tar" manifest.json | jq -c '.[0].RepoTags')"

# --- runs -------------------------------------------------------------------------------
say "dry-run before the one-shot tiers ran (no harbor-secret), and with the cluster unreachable"
K -n teknoir-system delete secret harbor-secret >/dev/null
DRY_RUN=1 harbor phase_harbor > "${WORK}/out/dry-nosecret.log" 2>&1 || { bad "dry-run without harbor-secret exits 0"; cat "${WORK}/out/dry-nosecret.log"; }
check "dry-run without harbor-secret: the plan from the bundle, no Harbor API call" bash -c "
  grep -q 'Harbor is not installed yet (no Secret teknoir-system/harbor-secret): would create the public projects teknoir dockerhub ghcr gcr quay k8s (tag immutability on teknoir), push 1 chart(s) and 2 image(s)' '${WORK}/out/dry-nosecret.log' &&
  ! grep -qE '^[A-Z]+ /api' '${WORK}/out/api.log'"
UNREACHABLE="kubectl --context ${CTX} --server=https://127.0.0.1:9 --request-timeout=5s"
KCTL="${UNREACHABLE}" DRY_RUN=1 harbor phase_harbor > "${WORK}/out/dry-nocluster.log" 2>&1 || { bad "dry-run without a reachable cluster exits 0"; cat "${WORK}/out/dry-nocluster.log"; }
check "dry-run without a reachable cluster: the plan from the bundle" grep -q 'the cluster is not reachable: would create the public projects' "${WORK}/out/dry-nocluster.log"
if KCTL="${UNREACHABLE}" harbor phase_harbor > "${WORK}/out/nocluster.log" 2>&1; then bad "a real run without a reachable cluster fails"; else
  check "a real run without a reachable cluster fails" grep -q 'harbor: the Kubernetes API is not reachable' "${WORK}/out/nocluster.log"
fi
K -n teknoir-system create secret generic harbor-secret --from-file=HARBOR_ADMIN_PASSWORD="${WORK}/pw" >/dev/null

say "dry-run before anything exists"
DRY_RUN=1 harbor phase_harbor > "${WORK}/out/dry0.log" 2>&1 || { bad "dry-run exits 0"; cat "${WORK}/out/dry0.log"; }
check "dry-run: no mutating API call" test "$(api_calls 'POST|PUT|DELETE')" == "0"
check "dry-run: plans 6 projects, the chart and 2 images" bash -c "[[ \$(grep -c 'would create Harbor project' '${WORK}/out/dry0.log') == 6 ]] && grep -q 'would push chart demo 0.1.0' '${WORK}/out/dry0.log' && [[ \$(grep -c 'would push docker.io' '${WORK}/out/dry0.log') == 2 ]]"
check "dry-run: nothing pushed" bash -c "! crane digest '${REG}/dockerhub/library/busybox:1.36.1' >/dev/null 2>&1"

say "first run"
if harbor phase_harbor > "${WORK}/out/run1.log" 2>&1; then ok "phase_harbor exits 0"; else bad "phase_harbor exits 0"; cat "${WORK}/out/run1.log"; fi
check "6 projects, all public" bash -c "[[ \$(curl -fsS http://127.0.0.1:${API_PORT}/test/state | jq '[.projects[] | select(.metadata.public == \"true\")] | length') == 6 ]]"
check "immutability rule on teknoir only" bash -c "[[ \$(curl -fsS http://127.0.0.1:${API_PORT}/test/state | jq -c '[.projects[] | select(.name == \"teknoir\") | .project_id | tostring] as \$t | [.rules | to_entries[] | select(.value | length > 0) | .key] == \$t') == true ]]"
check "chart pushed with the bundle's content digest" bash -c "[[ \$(crane manifest '${REG}/teknoir/demo:0.1.0' | jq -r '.layers[0].digest') == sha256:\$(sha256sum '${NODE}/charts/demo-0.1.0.tgz' | cut -d' ' -f1) ]]"
check "OCI layout image pushed to the dockerhub mirror" bash -c "[[ \$(crane config '${REG}/dockerhub/library/busybox:1.36.1' | sha256sum | cut -d' ' -f1) == \$(jq -r .config.digest '${NODE}/images/busybox/blobs/sha256/'\$(jq -r '.manifests[0].digest' '${NODE}/images/busybox/index.json' | cut -d: -f2) | cut -d: -f2) ]]"
check "docker archive image pushed under its normalized RepoTag" crane digest "${REG}/dockerhub/library/alpine:3.20"
check "robot\$argocd kept while ArgoCD uses it" bash -c "[[ \$(curl -fsS http://127.0.0.1:${API_PORT}/test/state | jq '.robots | length') == 1 ]] && grep -q 'robot\$argocd kept' '${WORK}/out/run1.log'"

say "second run: nothing to do"
: > "${WORK}/out/api.log"
harbor phase_harbor > "${WORK}/out/run2.log" 2>&1 || { bad "second run exits 0"; cat "${WORK}/out/run2.log"; }
check "second run: 0 changes" grep -q 'summary: 0 change' "${WORK}/out/run2.log"
check "second run: no mutating API call" test "$(api_calls 'POST|PUT|DELETE')" == "0"

say "the live env: teknoir private, robot retired, old multi-arch mirror tags"
curl -fsS -X POST "http://127.0.0.1:${API_PORT}/test/project-public?name=teknoir&public=false" >/dev/null
K -n teknoir-system delete secret argocd-harbor-repo >/dev/null
crane copy docker.io/library/busybox:1.36.1 "${REG}/dockerhub/library/busybox:1.36.1" 2>/dev/null
harbor phase_harbor > "${WORK}/out/run3.log" 2>&1 || { bad "third run exits 0"; cat "${WORK}/out/run3.log"; }
check "teknoir made public again" grep -q 'Harbor project teknoir made public' "${WORK}/out/run3.log"
check "robot\$argocd deleted once unused" bash -c "[[ \$(curl -fsS http://127.0.0.1:${API_PORT}/test/state | jq '.robots | length') == 0 ]]"
check "a multi-arch index holding the same amd64 image counts as present" bash -c "grep -q 'images: 2 in the bundle, 2 already in Harbor, 0 to push' '${WORK}/out/run3.log' && [[ \$(crane manifest '${REG}/dockerhub/library/busybox:1.36.1' | jq -r .mediaType) == *index* ]]"

say "charts: re-packed identical content is kept; different content is refused"
touch "${WORK}/src/demo/values.yaml"; sleep 1
th package "${WORK}/src/demo" -d "${WORK}/src" >/dev/null
th push "${WORK}/src/demo-0.1.0.tgz" "oci://${REG}/teknoir" --plain-http >/dev/null 2>&1
check "the re-packed chart differs in bytes" bash -c "! cmp -s '${WORK}/src/demo-0.1.0.tgz' '${NODE}/charts/demo-0.1.0.tgz'"
harbor phase_harbor > "${WORK}/out/run4.log" 2>&1 || { bad "run with a re-packed chart exits 0"; cat "${WORK}/out/run4.log"; }
check "same files, packed differently: kept" grep -q "chart demo 0.1.0: Harbor's copy has the same files" "${WORK}/out/run4.log"
echo "# changed" >> "${WORK}/src/demo/values.yaml"
th package "${WORK}/src/demo" -d "${WORK}/src" >/dev/null
th push "${WORK}/src/demo-0.1.0.tgz" "oci://${REG}/teknoir" --plain-http >/dev/null 2>&1
# the stub driver exits like the runner (EXIT handler, at_exit list): a
# refusal must leave it non-zero, also when harbor.sh chains onto the trap
if harbor phase_harbor > "${WORK}/out/run5.log" 2>&1; then bad "a different chart under the same version is refused (exit != 0)"; else
  check "a different chart under the same version is refused (exit != 0)" grep -q 'Harbor already holds a DIFFERENT chart under: demo 0.1.0' "${WORK}/out/run5.log"
fi
if STUB_NO_AT_EXIT=1 harbor phase_harbor > "${WORK}/out/run5b.log" 2>&1; then bad "without at_exit too, the refusal exits != 0"; else
  check "without at_exit too, the refusal exits != 0 and the handler reports it" bash -c "grep -q 'Harbor already holds a DIFFERENT chart' '${WORK}/out/run5b.log' && grep -q 'phase_harbor failed (exit 1)' '${WORK}/out/run5b.log'"
fi

say "images: a moved mirror tag is refused unless --force-images"
th push "${NODE}/charts/demo-0.1.0.tgz" "oci://${REG}/teknoir" --plain-http >/dev/null 2>&1   # restore the chart
crane copy --platform linux/amd64 docker.io/library/alpine:3.20 "${REG}/dockerhub/library/busybox:1.36.1" 2>/dev/null
if harbor phase_harbor > "${WORK}/out/run6.log" 2>&1; then bad "a moved tag is refused"; else
  check "a moved tag is refused, naming it" grep -q "point at a different image: ${REG}/dockerhub/library/busybox:1.36.1" "${WORK}/out/run6.log"
fi
harbor phase_harbor --force-images > "${WORK}/out/run7.log" 2>&1 || { bad "--force-images exits 0"; cat "${WORK}/out/run7.log"; }
check "--force-images moves the tag to the bundle's image" bash -c "grep -q 'pushed image docker.io/library/busybox:1.36.1' '${WORK}/out/run7.log' && harbor_out=\$(cat '${WORK}/out/run7.log') && [[ \$(crane config '${REG}/dockerhub/library/busybox:1.36.1' | sha256sum | cut -d' ' -f1) == \$(jq -r .config.digest '${NODE}/images/busybox/blobs/sha256/'\$(jq -r '.manifests[0].digest' '${NODE}/images/busybox/index.json' | cut -d: -f2) | cut -d: -f2) ]]"

say "migrate, M6: retire the robot repo-creds Secret only once ArgoCD reads the public project"
fake_argocd() {
  # answers a hard refresh of app-of-apps like ArgoCD: a comparison error while
  # ${WORK}/argocd-fail exists, Synced otherwise
  local now st
  while sleep 1; do
    [[ -n "$(kubectl --context "${CTX}" -n teknoir-system get applications.argoproj.io app-of-apps -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}' 2>/dev/null)" ]] || continue
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -e "${WORK}/argocd-fail" ]]; then
      st="{\"reconciledAt\":\"${now}\",\"sync\":{\"status\":\"Unknown\"},\"conditions\":[{\"type\":\"ComparisonError\",\"message\":\"401 unauthorized\"}]}"
    else
      st="{\"reconciledAt\":\"${now}\",\"sync\":{\"status\":\"Synced\"},\"conditions\":[]}"
    fi
    kubectl --context "${CTX}" -n teknoir-system patch applications.argoproj.io app-of-apps --type=merge \
      -p "{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":null}},\"status\":${st}}" >/dev/null 2>&1 || true
  done
}
K apply -f - >/dev/null <<'YAML'
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
YAML
K wait --for=condition=Established crd/applications.argoproj.io --timeout=60s >/dev/null
printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: {name: app-of-apps, namespace: teknoir-system}\nspec: {source: {repoURL: %s/teknoir, chart: app-of-apps, targetRevision: 0.0.4}}\n' "${REG}" | K apply -f - >/dev/null
th create "${WORK}/src/app-of-apps" >/dev/null
sed -i 's/^version:.*/version: 0.0.4/' "${WORK}/src/app-of-apps/Chart.yaml"
th package "${WORK}/src/app-of-apps" -d "${WORK}/src" >/dev/null
th push "${WORK}/src/app-of-apps-0.0.4.tgz" "oci://${REG}/teknoir" --plain-http >/dev/null 2>&1
K -n teknoir-system create secret generic argocd-harbor-repo \
  --from-literal=type=helm --from-literal=url=harbor.teknoir.airgapped/teknoir \
  --from-literal=username="robot\$argocd" --from-literal=password="robot-$(openssl rand -hex 8)" >/dev/null
K -n teknoir-system label secret argocd-harbor-repo argocd.argoproj.io/secret-type=repo-creds >/dev/null
repo_creds_hash="$(K -n teknoir-system get secret argocd-harbor-repo -o json | jq -cS .data | sha256sum)"
curl -fsS -X POST "http://127.0.0.1:${API_PORT}/test/robot?name=argocd" >/dev/null
fake_argocd &
ARGO_PID=$!

harbor cmd_migrate > "${WORK}/out/m1.log" 2>&1 || { bad "migrate exits 0 (nothing ready)"; cat "${WORK}/out/m1.log"; }
check "no credential-less repository yet: robot kept, Secret kept" bash -c "grep -q 'robot: not yet: no credential-less ArgoCD repository Secret' '${WORK}/out/m1.log' && kubectl --context ${CTX} -n teknoir-system get secret argocd-harbor-repo -o name >/dev/null"

K -n teknoir-system create secret generic harbor-teknoir-oci --from-literal=type=helm --from-literal=enableOCI=true \
  --from-literal=url="oci://${REG}/teknoir" >/dev/null
K -n teknoir-system label secret harbor-teknoir-oci argocd.argoproj.io/secret-type=repository >/dev/null
touch "${WORK}/argocd-fail"
if harbor cmd_migrate > "${WORK}/out/m2.log" 2>&1; then bad "ArgoCD failing without the robot stops migrate"; else
  check "ArgoCD failing without the robot: Secret put back, migrate stops" grep -q 'the Secret was put back' "${WORK}/out/m2.log"
fi
check "the restored Secret has the same data" bash -c "[[ \$(kubectl --context ${CTX} -n teknoir-system get secret argocd-harbor-repo -o json | jq -cS .data | sha256sum) == '${repo_creds_hash}' ]]"
check "robot kept while the Secret is back" bash -c "[[ \$(curl -fsS http://127.0.0.1:${API_PORT}/test/state | jq '.robots | length') == 1 ]]"

rm -f "${WORK}/argocd-fail"
harbor cmd_migrate > "${WORK}/out/m3.log" 2>&1 || { bad "migrate exits 0 (ready)"; cat "${WORK}/out/m3.log"; }
check "ArgoCD reads anonymously: repo-creds Secret deleted" bash -c "! kubectl --context ${CTX} -n teknoir-system get secret argocd-harbor-repo -o name 2>/dev/null && grep -q 'deleted the robot repo-creds Secret' '${WORK}/out/m3.log'"
check "then robot\$argocd deleted" bash -c "[[ \$(curl -fsS http://127.0.0.1:${API_PORT}/test/state | jq '.robots | length') == 0 ]] && grep -q 'deleted the Harbor robot account' '${WORK}/out/m3.log'"
harbor cmd_migrate > "${WORK}/out/m4.log" 2>&1 || bad "migrate re-run exits 0"
check "migrate re-run: 0 changes" grep -q 'summary: 0 change' "${WORK}/out/m4.log"
check "no robot password in any migrate output" bash -c "! grep -q 'robot-[0-9a-f]\{16\}' '${WORK}/out/m1.log' '${WORK}/out/m2.log' '${WORK}/out/m3.log' '${WORK}/out/m4.log'"

say "hygiene"
check "the admin password appears in no output" bash -c "! grep -rqF -- '${PW}' '${WORK}/out'"
check "nothing written to \$HOME (no ~/.docker, no ~/.config/helm)" test -z "$(find "${WORK}/home" -mindepth 1 -print -quit)"
check "no temp dir left behind" test -z "$(find "${WORK}/tmp" -mindepth 1 -print -quit)"

say "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
