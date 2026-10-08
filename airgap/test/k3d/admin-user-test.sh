#!/usr/bin/env bash
# admin-user-test.sh — k3d test of lib/admin.sh (`teknoir-node admin-user`).
#
# Stand-ins: a users.teknoir.org CRD (status subresource, like user-controller's),
# a bash loop playing user-controller (creates the Keycloak user, sets
# status.computed_status and status.set_initial_password), stubs/fake-keycloak.py
# for the Keycloak admin API, and a pause Deployment named backstage-api.
#
# Checks: the User CR name and spec; Keycloak group admin membership via the
# admin API with the keycloak-admin Secret; backstage-api restarted exactly
# once; the temporary password in a 0600 file and in no output; a second run
# changes nothing; dry-run changes nothing; unsupported emails refused.
#
# Usage: airgap/test/k3d/admin-user-test.sh [--keep]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
CLUSTER="${CLUSTER:-tkn2-admin}"
CTX="k3d-${CLUSTER}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
KC_PORT="${KC_PORT:-5057}"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-admin.XXXXXX")"
mkdir -p "${WORK}/node/bin" "${WORK}/out" "${WORK}/secret"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"

PASS=0
FAIL=0
FAILED=()
say()  { printf '\n=== %s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED+=("$*"); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
K() { kubectl --context "${CTX}" "$@"; }

KC_PID=""
UC_PID=""
cleanup() {
  local rc=$?
  [[ -z "${KC_PID}" ]] || kill "${KC_PID}" 2>/dev/null || true
  [[ -z "${UC_PID}" ]] || kill "${UC_PID}" 2>/dev/null || true
  if [[ "${KEEP}" == "1" ]]; then
    echo "kept: cluster ${CLUSTER}, work dir ${WORK}"
  else
    k3d cluster delete "${CLUSTER}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

admin_user() {
  env KUBECTL="kubectl --context ${CTX}" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped \
    ADMIN_KEYCLOAK_URL="http://127.0.0.1:${KC_PORT}" ADMIN_TIMEOUT=120 STUB_WAIT_INTERVAL=2 \
    "${REPO}/airgap/test/stubs/teknoir-node-stub" cmd_admin_user "$@"
}
kc_calls() { grep -cE "^$1 " "${WORK}/out/kc.log" || true; }

fake_user_controller() {
  # what user-controller does for a new User: Keycloak user + status
  local n email
  while sleep 2; do
    for n in $(kubectl --context "${CTX}" get users.teknoir.org -o json 2>/dev/null | jq -r '.items[] | select(.status.computed_status == null) | .metadata.name'); do
      email="$(kubectl --context "${CTX}" get users.teknoir.org "${n}" -o jsonpath='{.spec.email}')"
      curl -fsS -X POST "http://127.0.0.1:${KC_PORT}/test/user?username=${email/@/%40}" >/dev/null
      kubectl --context "${CTX}" patch users.teknoir.org "${n}" --subresource=status --type=merge \
        -p "{\"status\":{\"computed_status\":\"Enabled\",\"set_initial_password\":\"tmp-$(openssl rand -hex 8)\"}}" >/dev/null
    done
  done
}

say "k3d cluster ${CLUSTER}, fake Keycloak on :${KC_PORT}, fake user-controller"
k3d cluster create "${CLUSTER}" --image "${K3S_IMAGE}" --servers 1 --agents 0 --no-lb \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' --wait --timeout 180s >/dev/null
K create namespace teknoir-system >/dev/null
K create namespace teknoir-auth >/dev/null
( umask 077
  printf 'admin' > "${WORK}/secret/username"
  printf 'kcadm-%s' "$(openssl rand -hex 12)" > "${WORK}/secret/password" )
K -n teknoir-auth create secret generic keycloak-admin --from-file="${WORK}/secret/username" --from-file="${WORK}/secret/password" >/dev/null
: > "${WORK}/out/kc.log"
python3 -I "${REPO}/airgap/test/stubs/fake-keycloak.py" "${KC_PORT}" "${WORK}/secret/username" "${WORK}/secret/password" "${WORK}/out/kc.log" &
KC_PID=$!
K apply -f - >/dev/null <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: users.teknoir.org}
spec:
  group: teknoir.org
  names: {plural: users, singular: user, kind: User, listKind: UserList}
  scope: Cluster
  versions:
    - name: v1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
K wait --for=condition=Established crd/users.teknoir.org --timeout=60s >/dev/null
K -n teknoir-system create deployment backstage-api --image=registry.k8s.io/pause:3.10 >/dev/null
K -n teknoir-system rollout status deployment/backstage-api --timeout=120s >/dev/null
sleep 2   # the pod must start before the User exists, like a running Backstage
fake_user_controller &
UC_PID=$!

say "unsupported addresses are refused"
check "a '+' address is refused" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email 'a+b@teknoir.ai' --out '${WORK}/x' >/dev/null 2>&1"
check "--out is required" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email 'a@teknoir.ai' >/dev/null 2>&1"

say "dry-run"
DRY_RUN=1 admin_user --email Anders.Aslund@Teknoir.AI --out "${WORK}/pw.txt" > "${WORK}/out/dry.log" 2>&1 || bad "dry-run exits 0"
check "dry-run: no User, no Keycloak call, no file" bash -c "! kubectl --context ${CTX} get users.teknoir.org anders.aslund-at-teknoir.ai -o name 2>/dev/null && [[ ! -s '${WORK}/out/kc.log' && ! -e '${WORK}/pw.txt' ]]"

say "admin-user --email Anders.Aslund@Teknoir.AI"
restarts_before="$(K -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}')"
if admin_user --email Anders.Aslund@Teknoir.AI --display-name 'Anders Åslund' --out "${WORK}/pw.txt" > "${WORK}/out/run1.log" 2>&1; then
  ok "admin-user exits 0"
else
  bad "admin-user exits 0"; cat "${WORK}/out/run1.log"
fi
check "User CR named after the lowercased email (@ -> -at-)" K get users.teknoir.org anders.aslund-at-teknoir.ai -o name
check "User spec: superadmin, verified, enabled, plugins []" bash -c "kubectl --context ${CTX} get users.teknoir.org anders.aslund-at-teknoir.ai -o json | jq -e '.spec == {email: \"anders.aslund@teknoir.ai\", email_verified: true, enabled: true, claims_v0: {role: \"superadmin\"}, plugins: [], display_name: \"Anders Åslund\"}' >/dev/null"
check "Keycloak: the user is in group admin" bash -c "curl -fsS http://127.0.0.1:${KC_PORT}/test/state | jq -e '[.users[] | select(.username == \"anders.aslund@teknoir.ai\") | .id] as \$u | .members[\$u[0]] == [\"g-admin\"]' >/dev/null"
check "Keycloak: one membership PUT" test "$(kc_calls PUT)" == "1"
check "backstage-api restarted once" bash -c "[[ \$(kubectl --context ${CTX} -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}') == $((restarts_before + 1)) ]] && kubectl --context ${CTX} -n teknoir-system get deploy backstage-api -o jsonpath='{.spec.template.metadata.annotations}' | grep -q restartedAt"
check "password file has mode 0600" test "$(stat -c %a "${WORK}/pw.txt")" == "600"
check "password file holds status.set_initial_password" bash -c "[[ \$(cat '${WORK}/pw.txt') == \$(kubectl --context ${CTX} get users.teknoir.org anders.aslund-at-teknoir.ai -o jsonpath='{.status.set_initial_password}') ]]"
check "the temporary password is in no output" bash -c "! grep -qF -- \"\$(cat '${WORK}/pw.txt')\" '${WORK}/out/run1.log' '${WORK}/out/dry.log'"
check "the Keycloak admin password is in no output" bash -c "! grep -qF -- \"\$(cat '${WORK}/secret/password')\" '${WORK}/out/run1.log' '${WORK}/out/kc.log'"

say "second run: converged"
: > "${WORK}/out/kc.log"
gen_before="$(K -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}')"
admin_user --email anders.aslund@teknoir.ai --out "${WORK}/pw2.txt" > "${WORK}/out/run2.log" 2>&1 || { bad "second run exits 0"; cat "${WORK}/out/run2.log"; }
check "second run: 0 changes" grep -q 'summary: 0 change' "${WORK}/out/run2.log"
check "second run: no membership PUT" test "$(kc_calls PUT)" == "0"
check "second run: no second restart" test "$(K -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}')" == "${gen_before}"
check "second run: same password written again" cmp -s "${WORK}/pw.txt" "${WORK}/pw2.txt"

say "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
