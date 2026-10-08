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
# dry-run makes no mutating call; the password never appears in any output
# and nothing is written to $HOME or left in $TMPDIR.
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
mkdir -p "${NODE}/bin" "${NODE}/charts" "${NODE}/images" "${NODE}/bootstrap-images" "${WORK}/out" "${WORK}/home" "${WORK}/tmp" "${WORK}/src"
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
cleanup() {
  local rc=$?
  [[ -z "${API_PID}" ]] || kill "${API_PID}" 2>/dev/null || true
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
    KUBECTL="kubectl --context ${CTX}" KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}" KUBECACHEDIR="${WORK}/kcache" \
    NODE_ROOT="${NODE}" TEKNOIR_DOMAIN=teknoir.airgapped \
    HARBOR_API="http://127.0.0.1:${API_PORT}/api/v2.0" HARBOR_REGISTRY="${REG}" HARBOR_HELM_OPTS="--plain-http" \
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
if harbor phase_harbor > "${WORK}/out/run5.log" 2>&1; then bad "a different chart under the same version is refused"; else
  check "a different chart under the same version is refused" grep -q 'Harbor already holds a DIFFERENT chart under: demo 0.1.0' "${WORK}/out/run5.log"
fi

say "images: a moved mirror tag is refused unless --force-images"
th push "${NODE}/charts/demo-0.1.0.tgz" "oci://${REG}/teknoir" --plain-http >/dev/null 2>&1   # restore the chart
crane copy --platform linux/amd64 docker.io/library/alpine:3.20 "${REG}/dockerhub/library/busybox:1.36.1" 2>/dev/null
if harbor phase_harbor > "${WORK}/out/run6.log" 2>&1; then bad "a moved tag is refused"; else
  check "a moved tag is refused, naming it" grep -q "point at a different image: ${REG}/dockerhub/library/busybox:1.36.1" "${WORK}/out/run6.log"
fi
harbor phase_harbor --force-images > "${WORK}/out/run7.log" 2>&1 || { bad "--force-images exits 0"; cat "${WORK}/out/run7.log"; }
check "--force-images moves the tag to the bundle's image" bash -c "grep -q 'pushed image docker.io/library/busybox:1.36.1' '${WORK}/out/run7.log' && harbor_out=\$(cat '${WORK}/out/run7.log') && [[ \$(crane config '${REG}/dockerhub/library/busybox:1.36.1' | sha256sum | cut -d' ' -f1) == \$(jq -r .config.digest '${NODE}/images/busybox/blobs/sha256/'\$(jq -r '.manifests[0].digest' '${NODE}/images/busybox/index.json' | cut -d: -f2) | cut -d: -f2) ]]"

say "hygiene"
check "the admin password appears in no output" bash -c "! grep -rqF -- '${PW}' '${WORK}/out'"
check "nothing written to \$HOME (no ~/.docker, no ~/.config/helm)" test -z "$(find "${WORK}/home" -mindepth 1 -print -quit)"
check "no temp dir left behind" test -z "$(find "${WORK}/tmp" -mindepth 1 -print -quit)"

say "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
