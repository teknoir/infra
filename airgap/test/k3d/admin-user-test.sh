#!/usr/bin/env bash
# admin-user-test.sh — k3d test of lib/admin.sh (`teknoir-node admin-user`).
#
# Stand-ins:
#   - CRDs users.teknoir.org (status subresource, like user-controller's) and
#     profiles.teknoir.org;
#   - a bash loop playing the controllers:
#       user-controller, for a new User: the Keycloak user (fake Keycloak), a
#         temporary password, then status.computed_status. The password goes
#         into Secret <ns>/user-initial-password-<name> (mode "secret": the r5
#         contract K1, <ns> from the user-controller-config ConfigMap) or into
#         status.set_initial_password (mode "legacy": the older controller);
#       user-controller, for an owner claim on a Profile: RoleBinding
#         <ns>/user-<name>-teknoir-role-binding;
#       profile-controller: a namespace per Profile, annotated owner=<owner>;
#       Backstage's user provider: a final_entities row user:default/<name>
#         whose spec.memberOf has group:<ns>/owner and group:<ns>/<ns> per
#         owner claim (only group:default/superadmin for a user listed in
#         no-groups; no row for one listed in no-catalog). A row changes only
#         once the User has looked the same for CATALOG_LAG seconds, so the
#         catalog trails every claim change, like the real provider's schedule;
#   - stubs/fake-keycloak.py for the Keycloak admin API (group, reset-password);
#   - a postgres StatefulSet backstage-postgres (container postgres, the
#     catalog table final_entities) and a pause Deployment backstage-api;
#   - kwrap, a kubectl wrapper that interferes once (WRAP_MODE): it replaces
#     the Secret or the legacy status value right after admin-user read it, or
#     changes the User right before admin-user patches it.
# Every temporary password the stand-ins hand out is also kept in a 0600 side
# file, so the test compares it with admin-user's --out file unseen.
#
# Checks: the User CR name and spec; Keycloak group admin; the password handed
# over once (file 0600 equal to the recorded value, then the Secret is gone or
# the status field removed; a second run warns and writes nothing; a non-empty
# --out is never overwritten); --reset-password (one temporary=true call, the
# file 0600, a refused reset removes the file, a superseded Secret or legacy
# value is deleted afterwards); resume with an --out that already holds the
# recorded value; a Secret or legacy value replaced between read and delete
# survives (uid/resourceVersion preconditions, the legacy sha256 guard); owner
# claims on the user's own teamspaces only, existing claims kept, claim_set
# absent (a null is pruned to that), a conflicting change retried,
# idempotent, dry-run read-only, --teamspace checks; the catalog wait covers
# the new owner claims of an existing User (memberOf), no backstage-api
# restart, a timeout fails with the hint; no password in any output.
#
# Usage: airgap/test/k3d/admin-user-test.sh [--keep]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
CLUSTER="${CLUSTER:-tkn2-admin}"
CTX="k3d-${CLUSTER}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}"
# the backstage chart's pin (gitops backstage 0.0.84, HYG-C8)
PG_IMAGE="${PG_IMAGE:-docker.io/library/postgres:17.11-alpine@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3}"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
KC_PORT="${KC_PORT:-5057}"
CATALOG_LAG="${CATALOG_LAG:-10}"
CRED_NS=tk-user-creds   # deliberately not the default: admin-user must read it from the ConfigMap
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-admin.XXXXXX")"
chmod 700 "${WORK}"
mkdir -p "${WORK}/node/bin" "${WORK}/out" "${WORK}/secret" "${WORK}/rec" "${WORK}/files" "${WORK}/cat" "${WORK}/wrap"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"
printf 'secret\n' > "${WORK}/uc-mode"
: > "${WORK}/no-catalog"
: > "${WORK}/no-groups"
: > "${WORK}/out/catalog.log"

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
  # WRAP_MODE=<mode> WRAP_NAME=<name> admin_user ...: kubectl through kwrap
  local kubectl="kubectl --context ${CTX}"
  [[ -z "${WRAP_MODE:-}" ]] || kubectl="${WORK}/kwrap"
  env KUBECTL="${kubectl}" NODE_ROOT="${WORK}/node" TEKNOIR_DOMAIN=teknoir.airgapped \
    ADMIN_KEYCLOAK_URL="http://127.0.0.1:${KC_PORT}" ADMIN_TIMEOUT=120 STUB_WAIT_INTERVAL=2 \
    ADMIN_CATALOG_TIMEOUT="${ADMIN_CATALOG_TIMEOUT:-120}" \
    WRAP_CTX="${CTX}" WRAP_NS="${CRED_NS}" WRAP_DIR="${WORK}/wrap" WRAP_REC="${WORK}/rec" \
    "${REPO}/airgap/test/stubs/teknoir-node-stub" cmd_admin_user "$@"
}
kc_calls() { grep -cE "^$1" "${WORK}/out/kc.log" || true; }
kc_state() { curl -fsS "http://127.0.0.1:${KC_PORT}/test/state"; }
kc_uid() { kc_state | jq -r --arg u "$1" '[.users[] | select(.username == $u) | .id][0] // empty'; }
user_json() { K get users.teknoir.org "$1" -o json | jq 'del(.status.set_initial_password)'; }
has_legacy() { [[ "$(K get users.teknoir.org "$1" -o json | jq '.status | has("set_initial_password")')" == "true" ]]; }
no_legacy() { ! has_legacy "$1"; }
unchanged_and_on_record() { [[ "$(fstate "$1")" == "$2" ]] && has_legacy "$3"; }
fstate() { [[ -e "$1" ]] && printf '%s %s' "$(sha256sum < "$1" | cut -c1-64)" "$(stat -c %Y "$1")"; }
same_file() { cmp -s "$1" "$2"; }
wait_until() { local n="$1"; shift; while ! "$@"; do (( n-- > 0 )) || return 1; sleep 1; done; }
has_k1() { [[ -n "$(K -n "${CRED_NS}" get secret "user-initial-password-$1" --ignore-not-found -o name)" ]]; }
no_k1() { ! has_k1 "$1"; }
k1_holds() {
  # k1_holds <name> <file> — the Secret's password plus a newline equals <file> (unseen)
  { K -n "${CRED_NS}" get secret "user-initial-password-$1" -o jsonpath='{.data.password}' | base64 -d; echo; } | cmp -s - "$2"
}
legacy_holds() { K get users.teknoir.org "$1" -o json | jq -r '.status.set_initial_password // empty' | cmp -s - "$2"; }
cat_memberof() {
  # cat_memberof <name> — spec.memberOf of user:default/<name> in the catalog (JSON), empty when not listed
  K -n teknoir-system exec -i backstage-postgres-0 -c postgres -- psql -X -q -U backstage -d backstage_plugin_catalog -tA \
    <<<"select final_entity::jsonb -> 'spec' -> 'memberOf' from final_entities where entity_ref = 'user:default/$1'" | tr -d '[:space:]'
}
cat_listed() { [[ -n "$(cat_memberof "$1")" ]]; }
cat_member() { cat_memberof "$1" | jq -e --arg g "$2" 'any(.[]; . == $g)' >/dev/null 2>&1; }
cat_listed_not_member() { cat_listed "$1" && ! cat_member "$1" "$2"; }
new_user() {
  # new_user <name> <email> — an existing User for admin-user to complete (no claims)
  K apply -f - >/dev/null <<EOF
apiVersion: teknoir.org/v1
kind: User
metadata: {name: $1}
spec: {email: $2, email_verified: true, enabled: true, claims_v0: {role: superadmin}, plugins: []}
EOF
}
new_profile() {
  # new_profile <name> <owner>
  K apply -f - >/dev/null <<EOF
apiVersion: teknoir.org/v1
kind: Profile
metadata: {name: $1}
spec: {owner: {kind: User, name: $2}}
EOF
}
no_secret_in() {
  # no_secret_in <file...> — none of the recorded or reset passwords (and not
  # the Keycloak admin password) appears in the files; grep reads them from a pipe
  local f
  f="$(mktemp "${WORK}/needles.XXXXXX")"
  cat "${WORK}"/rec/* "${WORK}/secret/password" > "${f}" 2>/dev/null || true
  printf '\n' >> "${f}"
  if grep -h -v '^$' "${f}" | grep -qF -f - "$@"; then rm -f "${f}"; return 1; fi
  rm -f "${f}"
}

uc_new_user() {
  # user-controller for a new User: Keycloak user, temporary password, status
  local n="$1" email uid pw mode
  email="$(K get users.teknoir.org "${n}" -o jsonpath='{.spec.email}')"
  curl -fsS -X POST "http://127.0.0.1:${KC_PORT}/test/user?username=${email/@/%40}" >/dev/null
  pw="tmp-$(openssl rand -hex 12)"
  ( umask 077; printf '%s\n' "${pw}" > "${WORK}/rec/${n}" )
  mode="$(cat "${WORK}/uc-mode")"
  if [[ "${mode}" == secret ]]; then
    uid="$(K get users.teknoir.org "${n}" -o jsonpath='{.metadata.uid}')"
    K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: user-initial-password-${n}
  namespace: ${CRED_NS}
  labels: {teknoir.org/user: "${n}", teknoir.org/purpose: initial-password}
  annotations: {teknoir.org/expires-at: "$(date -u -d '+72 hours' +%Y-%m-%dT%H:%M:%SZ)"}
  ownerReferences: [{apiVersion: teknoir.org/v1, kind: User, name: "${n}", uid: "${uid}"}]
type: Opaque
stringData: {password: "${pw}"}
EOF
    K patch users.teknoir.org "${n}" --subresource=status --type=merge -p '{"status":{"computed_status":"Enabled"}}' >/dev/null
  else
    K patch users.teknoir.org "${n}" --subresource=status --type=merge \
      -p "{\"status\":{\"computed_status\":\"Enabled\",\"set_initial_password\":\"${pw}\"}}" >/dev/null
  fi
  pw=""
}

fake_user_provider() {
  # Backstage's user provider: one final_entities row per reconciled User,
  # written only once the User has looked the same for CATALOG_LAG seconds
  local n want now
  now="$(date +%s)"
  while read -r n want; do
    [[ -n "${n}" ]] || continue
    grep -qx "${n}" "${WORK}/no-catalog" && continue
    grep -qx "${n}" "${WORK}/no-groups" && want='["group:default/superadmin"]'
    [[ "$(cat "${WORK}/cat/${n}.have" 2>/dev/null)" != "${want}" ]] || continue
    if [[ "$(cat "${WORK}/cat/${n}.want" 2>/dev/null)" != "${want}" ]]; then
      printf '%s' "${want}" > "${WORK}/cat/${n}.want"
      printf '%s' "${now}" > "${WORK}/cat/${n}.since"
      continue
    fi
    (( now - $(cat "${WORK}/cat/${n}.since") >= CATALOG_LAG )) || continue
    if K -n teknoir-system exec -i backstage-postgres-0 -c postgres -- \
        psql -X -q -v ON_ERROR_STOP=1 -U backstage -d backstage_plugin_catalog >/dev/null 2>&1 <<SQL
begin;
delete from final_entities where entity_ref = 'user:default/${n}';
insert into final_entities (entity_ref, final_entity) values ('user:default/${n}', '{"spec":{"memberOf":${want}}}');
commit;
SQL
    then
      printf '%s' "${want}" > "${WORK}/cat/${n}.have"
      printf '%s user:default/%s %s\n' "$(date +%s)" "${n}" "${want}" >> "${WORK}/out/catalog.log"
    fi
  done < <(K get users.teknoir.org -o json 2>/dev/null | jq -r '.items[] | select(.status.computed_status != null)
      | (["group:default/superadmin"] + [(.spec.claim_set // [])[] | select(.name == "owner") | "group:\(.namespace)/owner", "group:\(.namespace)/\(.namespace)"]) as $m
      | "\(.metadata.name) \($m | tojson)"')
}

fake_controllers() {
  set +e
  local n ns p owner
  while sleep 2; do
    # profile-controller: the teamspace namespace, annotated with the Profile's owner
    while read -r p owner; do
      [[ -n "${p}" ]] || continue
      if ! K get namespace "${p}" >/dev/null 2>&1; then
        K create namespace "${p}" >/dev/null 2>&1 && K annotate namespace "${p}" "owner=${owner}" >/dev/null 2>&1
      fi
    done < <(K get profiles.teknoir.org -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.name) \(.spec.owner.name)"')
    # user-controller: new Users
    for n in $(K get users.teknoir.org -o json 2>/dev/null | jq -r '.items[] | select(.status.computed_status == null) | .metadata.name'); do
      uc_new_user "${n}"
    done
    # user-controller K8S plugin: a RoleBinding per owner claim on a teamspace
    while read -r n ns; do
      [[ -n "${n}" ]] || continue
      K -n "${ns}" get rolebinding "user-${n}-teknoir-role-binding" >/dev/null 2>&1 \
        || K -n "${ns}" create rolebinding "user-${n}-teknoir-role-binding" --clusterrole=view --user="${n}" >/dev/null 2>&1
    done < <(K get users.teknoir.org -o json 2>/dev/null \
      | jq -r '.items[] | .metadata.name as $n | (.spec.claim_set // [])[] | select(.name == "owner") | "\($n) \(.namespace)"')
    fake_user_provider
  done
}

# kwrap: kubectl for admin-user, with one interference per WRAP_MODE (fired
# once: WRAP_DIR/fired-<mode>) on the User or Secret of WRAP_NAME
cat > "${WORK}/kwrap" <<'WRAP'
#!/usr/bin/env bash
#   secret-swap  right after admin-user read Secret user-initial-password-<name>:
#                a new password in it (same uid, new resourceVersion)
#   legacy-swap  right after admin-user first read the User as JSON: a new
#                status.set_initial_password
#   claims-bump  right before the owner-claim patch: another change to the User
#   status-bump  right before the status patch: another change to the User
# A new value goes only to WRAP_REC/<name>.new (0600), never to argv or output.
set -uo pipefail
real=(kubectl --context "${WRAP_CTX}")
fire() { mkdir "${WRAP_DIR}/fired-${WRAP_MODE}" 2>/dev/null; }
bump() { "${real[@]}" annotate --overwrite users.teknoir.org "${WRAP_NAME}" "test.teknoir.org/bump=$(date +%s%N)" >/dev/null; }
newpw() { ( umask 077; printf 'tmp-new-%s\n' "$(openssl rand -hex 12)" > "${WRAP_REC}/${WRAP_NAME}.new" ); }
case "${WRAP_MODE}: $* " in
  "secret-swap:"*" get secret user-initial-password-${WRAP_NAME} "*)
    if fire; then
      out="$("${real[@]}" "$@")"; rc=$?
      newpw
      "${real[@]}" -n "${WRAP_NS}" get secret "user-initial-password-${WRAP_NAME}" -o json \
        | jq --rawfile p "${WRAP_REC}/${WRAP_NAME}.new" '.data.password = ($p | rtrimstr("\n") | @base64)' \
        | "${real[@]}" replace -f - >/dev/null
      printf '%s\n' "${out}"
      exit "${rc}"
    fi ;;
  "legacy-swap:"*" get users.teknoir.org ${WRAP_NAME} -o json "*)
    if fire; then
      out="$("${real[@]}" "$@")"; rc=$?
      newpw
      ( umask 077; jq -n --rawfile p "${WRAP_REC}/${WRAP_NAME}.new" '{status: {set_initial_password: ($p | rtrimstr("\n"))}}' > "${WRAP_DIR}/patch.json" )
      "${real[@]}" patch users.teknoir.org "${WRAP_NAME}" --subresource=status --type=merge --patch-file "${WRAP_DIR}/patch.json" >/dev/null
      rm -f "${WRAP_DIR}/patch.json"
      printf '%s\n' "${out}"
      exit "${rc}"
    fi ;;
  "claims-bump:"*" patch users.teknoir.org ${WRAP_NAME} --type=json "*) fire && bump ;;
  "status-bump:"*" patch users.teknoir.org ${WRAP_NAME} --subresource=status "*) fire && bump ;;
esac
exec "${real[@]}" "$@"
WRAP
chmod 700 "${WORK}/kwrap"

say "k3d cluster ${CLUSTER}, fake Keycloak on :${KC_PORT}, fake controllers, catalog postgres"
k3d cluster create "${CLUSTER}" --image "${K3S_IMAGE}" --servers 1 --agents 0 --no-lb \
  --k3s-arg '--disable=traefik@server:0' --k3s-arg '--disable=metrics-server@server:0' --wait --timeout 180s >/dev/null
for ns in teknoir-system teknoir-auth "${CRED_NS}"; do K create namespace "${ns}" >/dev/null; done
K -n teknoir-system create configmap user-controller-config --from-literal=USER_CREDENTIALS_NAMESPACE="${CRED_NS}" >/dev/null
( umask 077
  printf 'admin' > "${WORK}/secret/username"
  printf 'kcadm-%s' "$(openssl rand -hex 12)" > "${WORK}/secret/password"
  printf 'pg-%s' "$(openssl rand -hex 12)" > "${WORK}/secret/POSTGRES_PASSWORD" )
K -n teknoir-auth create secret generic keycloak-admin --from-file="${WORK}/secret/username" --from-file="${WORK}/secret/password" >/dev/null
K -n teknoir-system create secret generic backstage-postgres-secrets --from-file="${WORK}/secret/POSTGRES_PASSWORD" >/dev/null
: > "${WORK}/out/kc.log"
python3 -I "${REPO}/airgap/test/stubs/fake-keycloak.py" "${KC_PORT}" "${WORK}/secret/username" "${WORK}/secret/password" \
  "${WORK}/out/kc.log" "${WORK}/rec" &
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
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: profiles.teknoir.org}
spec:
  group: teknoir.org
  names: {plural: profiles, singular: profile, kind: Profile, listKind: ProfileList}
  scope: Cluster
  versions:
    - name: v1
      served: true
      storage: true
      subresources: {status: {}}
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
K wait --for=condition=Established crd/users.teknoir.org crd/profiles.teknoir.org --timeout=60s >/dev/null
K apply -f - >/dev/null <<'EOF'
apiVersion: teknoir.org/v1
kind: Profile
metadata: {name: teknoir-default}
spec: {owner: {kind: User, name: anders.aslund@teknoir.ai}}
---
apiVersion: teknoir.org/v1
kind: Profile
metadata: {name: team-b}
spec: {owner: {kind: User, name: Second.Admin@Teknoir.AI}}
---
apiVersion: teknoir.org/v1
kind: Profile
metadata: {name: foreign}
spec: {owner: {kind: User, name: someone@example.com}}
EOF
K apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: catalog-init, namespace: teknoir-system}
data:
  init.sql: |
    CREATE DATABASE backstage_plugin_catalog;
    \\connect backstage_plugin_catalog
    CREATE TABLE final_entities (entity_ref text NOT NULL, final_entity text);
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: backstage-postgres, namespace: teknoir-system, labels: {app: backstage-postgres}}
spec:
  serviceName: backstage-postgres
  replicas: 1
  selector: {matchLabels: {app: backstage-postgres}}
  template:
    metadata: {labels: {app: backstage-postgres}}
    spec:
      containers:
        - name: postgres
          image: ${PG_IMAGE}
          imagePullPolicy: IfNotPresent
          env:
            - {name: POSTGRES_USER, value: backstage}
            - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: backstage-postgres-secrets, key: POSTGRES_PASSWORD}}}
            - {name: POSTGRES_INITDB_ARGS, value: --auth-host=scram-sha-256}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          readinessProbe:
            exec: {command: [psql, -U, backstage, -d, backstage_plugin_catalog, -c, "select 1 from final_entities limit 1"]}
            periodSeconds: 2
          volumeMounts:
            - {name: init, mountPath: /docker-entrypoint-initdb.d}
            - {name: data, mountPath: /var/lib/postgresql/data}
      volumes:
        - {name: init, configMap: {name: catalog-init}}
        - {name: data, emptyDir: {}}
EOF
K -n teknoir-system create deployment backstage-api --image="${PAUSE_IMAGE}" >/dev/null
K -n teknoir-system rollout status deployment/backstage-api --timeout=180s >/dev/null
K -n teknoir-system rollout status statefulset/backstage-postgres --timeout=300s >/dev/null
fake_controllers &
UC_PID=$!
gen0="$(K -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}')"

A=anders.aslund-at-teknoir.ai
B=second.admin-at-teknoir.ai
C=late.user-at-teknoir.ai

say "refusals before any change"
check "a '+' address is refused" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email 'a+b@teknoir.ai' --out '${WORK}/files/x' >/dev/null 2>&1"
check "--out is required" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email 'a@teknoir.ai' >/dev/null 2>&1"
check "an invalid --teamspace is refused" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email 'a@teknoir.ai' --out '${WORK}/files/x' --teamspace 'Bad_Name' >/dev/null 2>&1"
printf 'keep me\n' > "${WORK}/files/busy.txt"
busy0="$(fstate "${WORK}/files/busy.txt")"
check "--reset-password with a non-empty --out is refused before anything" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email 'a@teknoir.ai' --reset-password --out '${WORK}/files/busy.txt' >/dev/null 2>&1"
check "  ... no User, no Keycloak call, the file untouched" bash -c "[[ -z \$(kubectl --context ${CTX} get users.teknoir.org -o name) && ! -s '${WORK}/out/kc.log' && '$(fstate "${WORK}/files/busy.txt")' == '${busy0}' ]]"

say "dry-run"
DRY_RUN=1 admin_user --email Anders.Aslund@Teknoir.AI --out "${WORK}/files/pwA.txt" > "${WORK}/out/dry.log" 2>&1 || bad "dry-run exits 0"
check "dry-run: no User, no Keycloak call, no file" bash -c "! kubectl --context ${CTX} get users.teknoir.org ${A} -o name 2>/dev/null && [[ ! -s '${WORK}/out/kc.log' && ! -e '${WORK}/files/pwA.txt' ]]"

say "admin-user --email Anders.Aslund@Teknoir.AI (user-controller r5: the temporary password in a Secret)"
if admin_user --email Anders.Aslund@Teknoir.AI --display-name 'Anders Åslund' --out "${WORK}/files/pwA.txt" > "${WORK}/out/runA1.log" 2>&1; then
  ok "admin-user exits 0"
else
  bad "admin-user exits 0"; cat "${WORK}/out/runA1.log"
fi
check "User CR named after the lowercased email (@ -> -at-)" K get users.teknoir.org "${A}" -o name
check "User spec: superadmin, verified, enabled, plugins [], claim owner@teknoir-default only" bash -c "kubectl --context ${CTX} get users.teknoir.org ${A} -o json | jq -e '.spec == {email: \"anders.aslund@teknoir.ai\", email_verified: true, enabled: true, claims_v0: {role: \"superadmin\"}, plugins: [], display_name: \"Anders Åslund\", claim_set: [{name: \"owner\", namespace: \"teknoir-default\"}]}' >/dev/null"
check "Keycloak: the user is in group admin" bash -c "curl -fsS http://127.0.0.1:${KC_PORT}/test/state | jq -e '[.users[] | select(.username == \"anders.aslund@teknoir.ai\") | .id] as \$u | .members[\$u[0]] == [\"g-admin\"]' >/dev/null"
check "Keycloak: one membership PUT, no reset" bash -c "[[ \$(grep -cE '^PUT .*/groups/' '${WORK}/out/kc.log') == 1 && \$(grep -c 'reset-password' '${WORK}/out/kc.log') == 0 ]]"
check "password file has mode 0600" test "$(stat -c %a "${WORK}/files/pwA.txt")" == "600"
check "password file holds the value user-controller recorded" same_file "${WORK}/files/pwA.txt" "${WORK}/rec/${A}"
check "the Secret is gone after the handover" bash -c "[[ -z \$(kubectl --context ${CTX} -n ${CRED_NS} get secret user-initial-password-${A} --ignore-not-found -o name) ]]"
check "the User has no status.set_initial_password" no_legacy "${A}"
check "RoleBinding teknoir-default/user-${A}-teknoir-role-binding exists" K -n teknoir-default get rolebinding "user-${A}-teknoir-role-binding" -o name
check "no RoleBinding for ${A} in the other teamspaces" bash -c "[[ -z \$(kubectl --context ${CTX} -n foreign get rolebinding user-${A}-teknoir-role-binding --ignore-not-found -o name)\$(kubectl --context ${CTX} -n team-b get rolebinding user-${A}-teknoir-role-binding --ignore-not-found -o name) ]]"
check "it waited for the catalog, which lists user:default/${A}" bash -c "grep -q 'waiting up to .* Backstage catalog lists user:default/${A}' '${WORK}/out/runA1.log' && grep -q 'the Backstage catalog lists user:default/${A}' '${WORK}/out/runA1.log'"
check "backstage-api is not restarted" bash -c "[[ \$(kubectl --context ${CTX} -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}') == ${gen0} ]] && ! kubectl --context ${CTX} -n teknoir-system get deploy backstage-api -o jsonpath='{.spec.template.metadata.annotations}' | grep -q restartedAt"
check "no password in the output" no_secret_in "${WORK}/out/runA1.log" "${WORK}/out/dry.log" "${WORK}/out/kc.log"

say "second run with the same --out: nothing on record any more"
: > "${WORK}/out/kc.log"
pwA0="$(fstate "${WORK}/files/pwA.txt")"
sleep 1
admin_user --email anders.aslund@teknoir.ai --out "${WORK}/files/pwA.txt" > "${WORK}/out/runA2.log" 2>&1 || { bad "second run exits 0"; cat "${WORK}/out/runA2.log"; }
check "second run: 0 changes" grep -q 'summary: 0 changes' "${WORK}/out/runA2.log"
check "second run: warns that no temporary password is on record" grep -q 'no temporary password of anders.aslund@teknoir.ai is on record' "${WORK}/out/runA2.log"
check "second run: the file is not rewritten" test "$(fstate "${WORK}/files/pwA.txt")" == "${pwA0}"
check "second run: no Keycloak PUT" test "$(kc_calls PUT)" == "0"

say "--teamspace"
admin_user --email anders.aslund@teknoir.ai --out "${WORK}/files/unused.txt" --teamspace teknoir-default > "${WORK}/out/ts1.log" 2>&1 || bad "--teamspace teknoir-default exits 0"
check "--teamspace of an owned teamspace: 0 changes, no file" bash -c "grep -q 'summary: 0 changes' '${WORK}/out/ts1.log' && [[ ! -e '${WORK}/files/unused.txt' ]]"
check "--teamspace of a missing Profile fails" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' TEKNOIR_DOMAIN=teknoir.airgapped ADMIN_KEYCLOAK_URL=http://127.0.0.1:${KC_PORT} '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email anders.aslund@teknoir.ai --out '${WORK}/files/unused.txt' --teamspace nosuch > '${WORK}/out/ts2.log' 2>&1 && grep -q 'there is no Profile nosuch' '${WORK}/out/ts2.log'"
check "--teamspace of someone else's Profile fails, the User is untouched" bash -c "rv=\$(kubectl --context ${CTX} get users.teknoir.org ${A} -o jsonpath='{.metadata.resourceVersion}'); ! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' TEKNOIR_DOMAIN=teknoir.airgapped ADMIN_KEYCLOAK_URL=http://127.0.0.1:${KC_PORT} '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email anders.aslund@teknoir.ai --out '${WORK}/files/unused.txt' --teamspace foreign > '${WORK}/out/ts3.log' 2>&1 && grep -q 'owned by' '${WORK}/out/ts3.log' && [[ \$(kubectl --context ${CTX} get users.teknoir.org ${A} -o jsonpath='{.metadata.resourceVersion}') == \"\${rv}\" ]]"

say "--reset-password"
uidA="$(kc_uid anders.aslund@teknoir.ai)"
: > "${WORK}/out/kc.log"
if admin_user --email anders.aslund@teknoir.ai --reset-password --out "${WORK}/files/resetA.txt" > "${WORK}/out/reset1.log" 2>&1; then
  ok "--reset-password exits 0"
else
  bad "--reset-password exits 0"; cat "${WORK}/out/reset1.log"
fi
check "exactly one reset-password call, temporary=true" bash -c "[[ \$(grep -c 'reset-password' '${WORK}/out/kc.log') == 1 ]] && curl -fsS http://127.0.0.1:${KC_PORT}/test/state | jq -e --arg u '${uidA}' '[.resets[] | select(.user == \$u)] == [{user: \$u, type: \"password\", temporary: true, length: 20}]' >/dev/null"
check "the reset file has mode 0600" test "$(stat -c %a "${WORK}/files/resetA.txt")" == "600"
check "the reset file holds the password Keycloak got" same_file "${WORK}/files/resetA.txt" "${WORK}/rec/reset-${uidA}.txt"
check "no password in the output" no_secret_in "${WORK}/out/reset1.log" "${WORK}/out/kc.log"
curl -fsS -X POST "http://127.0.0.1:${KC_PORT}/test/fail-reset?code=500" >/dev/null
check "a refused reset fails and removes its --out file" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' TEKNOIR_DOMAIN=teknoir.airgapped ADMIN_KEYCLOAK_URL=http://127.0.0.1:${KC_PORT} '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email anders.aslund@teknoir.ai --reset-password --out '${WORK}/files/resetfail.txt' > '${WORK}/out/reset2.log' 2>&1 && grep -q 'HTTP 500' '${WORK}/out/reset2.log' && [[ ! -e '${WORK}/files/resetfail.txt' ]]"
check "  ... and Keycloak recorded no second reset" bash -c "curl -fsS http://127.0.0.1:${KC_PORT}/test/state | jq -e '.resets | length == 1' >/dev/null"
check "  ... the first reset value is still the one in the file" same_file "${WORK}/files/resetA.txt" "${WORK}/rec/reset-${uidA}.txt"

say "an existing User (older user-controller: the password in status.set_initial_password)"
printf 'legacy\n' > "${WORK}/uc-mode"
K apply -f - >/dev/null <<'EOF'
apiVersion: teknoir.org/v1
kind: User
metadata: {name: second.admin-at-teknoir.ai}
spec:
  email: second.admin@teknoir.ai
  email_verified: true
  enabled: true
  claims_v0: {role: superadmin}
  plugins: []
  claim_set: [{name: viewer, namespace: foreign}]
EOF
for _ in $(seq 1 30); do has_legacy "${B}" && break; sleep 1; done
check "the stand-in recorded a legacy status value" has_legacy "${B}"
check "the catalog lists ${B} before admin-user runs, without group:team-b/team-b" wait_until 60 cat_listed_not_member "${B}" group:team-b/team-b
busy0="$(fstate "${WORK}/files/busy.txt")"
check "a non-empty --out is refused while a password is on record" bash -c "! env KUBECTL='kubectl --context ${CTX}' NODE_ROOT='${WORK}/node' TEKNOIR_DOMAIN=teknoir.airgapped ADMIN_KEYCLOAK_URL=http://127.0.0.1:${KC_PORT} STUB_WAIT_INTERVAL=2 '${REPO}/airgap/test/stubs/teknoir-node-stub' cmd_admin_user --email second.admin@teknoir.ai --out '${WORK}/files/busy.txt' > '${WORK}/out/busy.log' 2>&1 && grep -q 'never overwrites' '${WORK}/out/busy.log'"
check "  ... the file is untouched and the value still on record" unchanged_and_on_record "${WORK}/files/busy.txt" "${busy0}" "${B}"
# an older user-controller has no credentials namespace: admin-user must read that as "no Secret"
if ADMIN_CREDENTIALS_NS=teknoir-user-credentials admin_user --email second.admin@teknoir.ai --out "${WORK}/files/pwB.txt" > "${WORK}/out/runB1.log" 2>&1; then
  ok "admin-user (legacy, no credentials namespace) exits 0"
else
  bad "admin-user (legacy, no credentials namespace) exits 0"; cat "${WORK}/out/runB1.log"
fi
check "the file holds the legacy value, mode 0600" bash -c "cmp -s '${WORK}/files/pwB.txt' '${WORK}/rec/${B}' && [[ \$(stat -c %a '${WORK}/files/pwB.txt') == 600 ]]"
check "it waited until the catalog lists ${B} as a member of group:team-b/team-b" grep -q "waiting up to .* catalog lists user:default/${B} as a member of group:team-b/team-b" "${WORK}/out/runB1.log"
check "  ... and when it returned, the catalog's memberOf has group:team-b/team-b" cat_member "${B}" group:team-b/team-b
check "  ... the stand-in provider wrote ${B}'s row without and then with the group" bash -c "grep ' user:default/${B} ' '${WORK}/out/catalog.log' | grep -v -q 'group:team-b/team-b' && grep ' user:default/${B} ' '${WORK}/out/catalog.log' | tail -n 1 | grep -q 'group:team-b/team-b'"
check "status.set_initial_password is removed" no_legacy "${B}"
check "claim_set keeps viewer@foreign and gains exactly owner@team-b" bash -c "kubectl --context ${CTX} get users.teknoir.org ${B} -o json | jq -e '.spec.claim_set == [{name: \"viewer\", namespace: \"foreign\"}, {name: \"owner\", namespace: \"team-b\"}]' >/dev/null"
check "RoleBinding team-b/user-${B}-teknoir-role-binding exists" K -n team-b get rolebinding "user-${B}-teknoir-role-binding" -o name
check "the foreign Profile is untouched (no owner claim on foreign or teknoir-default)" bash -c "kubectl --context ${CTX} get users.teknoir.org ${B} -o json | jq -e '[.spec.claim_set[] | select(.name == \"owner\" and (.namespace == \"foreign\" or .namespace == \"teknoir-default\"))] == []' >/dev/null"
rvB="$(K get users.teknoir.org "${B}" -o jsonpath='{.metadata.resourceVersion}')"
pwB0="$(fstate "${WORK}/files/pwB.txt")"
admin_user --email second.admin@teknoir.ai --out "${WORK}/files/pwB.txt" > "${WORK}/out/runB2.log" 2>&1 || { bad "second run (legacy) exits 0"; cat "${WORK}/out/runB2.log"; }
check "second run (legacy): 0 changes, a warning, no rewrite, User unchanged" bash -c "grep -q 'summary: 0 changes' '${WORK}/out/runB2.log' && grep -q 'is on record' '${WORK}/out/runB2.log' && [[ '$(fstate "${WORK}/files/pwB.txt")' == '${pwB0}' && \$(kubectl --context ${CTX} get users.teknoir.org ${B} -o jsonpath='{.metadata.resourceVersion}') == '${rvB}' ]]"

say "dry-run on an existing User that lacks its owner claim"
K patch users.teknoir.org "${B}" --type=json -p '[{"op":"remove","path":"/spec/claim_set/1"}]' >/dev/null
rvB="$(K get users.teknoir.org "${B}" -o jsonpath='{.metadata.resourceVersion}')"
DRY_RUN=1 admin_user --email second.admin@teknoir.ai --out "${WORK}/files/pwB3.txt" > "${WORK}/out/dryB.log" 2>&1 || bad "dry-run (existing User) exits 0"
check "dry-run: says it would add owner@team-b, changes nothing" bash -c "grep -q 'would add to User ${B}: claim owner@team-b' '${WORK}/out/dryB.log' && [[ \$(kubectl --context ${CTX} get users.teknoir.org ${B} -o jsonpath='{.metadata.resourceVersion}') == '${rvB}' && ! -e '${WORK}/files/pwB3.txt' ]]"
admin_user --email second.admin@teknoir.ai --out "${WORK}/files/pwB3.txt" > "${WORK}/out/runB3.log" 2>&1 || { bad "re-run after the claim was removed exits 0"; cat "${WORK}/out/runB3.log"; }
check "the re-run adds owner@team-b back, once" bash -c "kubectl --context ${CTX} get users.teknoir.org ${B} -o json | jq -e '.spec.claim_set == [{name: \"viewer\", namespace: \"foreign\"}, {name: \"owner\", namespace: \"team-b\"}]' >/dev/null && grep -q 'summary: 1 change' '${WORK}/out/runB3.log'"

say "resume: --out already holds exactly the recorded value"
printf 'secret\n' > "${WORK}/uc-mode"
E=resume.user-at-teknoir.ai
new_user "${E}" resume.user@teknoir.ai
check "the stand-in recorded a Secret for ${E}" wait_until 30 has_k1 "${E}"
( umask 077; cp "${WORK}/rec/${E}" "${WORK}/files/pwE.txt" )
pwE0="$(fstate "${WORK}/files/pwE.txt")"
sleep 1
if admin_user --email resume.user@teknoir.ai --out "${WORK}/files/pwE.txt" > "${WORK}/out/runE.log" 2>&1; then
  ok "resume exits 0"
else
  bad "resume exits 0"; cat "${WORK}/out/runE.log"
fi
check "  ... it says the file already holds the password" grep -q "pwE.txt already holds the temporary password of resume.user@teknoir.ai" "${WORK}/out/runE.log"
check "  ... the Secret is gone afterwards" no_k1 "${E}"
check "  ... the file is not rewritten" test "$(fstate "${WORK}/files/pwE.txt")" == "${pwE0}"

say "--reset-password while a temporary password is still on record"
F=reset.secret-at-teknoir.ai
new_user "${F}" reset.secret@teknoir.ai
check "the stand-in recorded a Secret for ${F}" wait_until 30 has_k1 "${F}"
uidF="$(kc_uid reset.secret@teknoir.ai)"
if admin_user --email reset.secret@teknoir.ai --reset-password --out "${WORK}/files/resetF.txt" > "${WORK}/out/resetF.log" 2>&1; then
  ok "--reset-password (Secret on record) exits 0"
else
  bad "--reset-password (Secret on record) exits 0"; cat "${WORK}/out/resetF.log"
fi
check "  ... the file (0600) holds the password Keycloak got" bash -c "cmp -s '${WORK}/files/resetF.txt' '${WORK}/rec/reset-${uidF}.txt' && [[ \$(stat -c %a '${WORK}/files/resetF.txt') == 600 ]]"
check "  ... the superseded Secret is deleted" bash -c "grep -q 'deleted the superseded Secret ${CRED_NS}/user-initial-password-${F}' '${WORK}/out/resetF.log' && ! kubectl --context ${CTX} -n ${CRED_NS} get secret user-initial-password-${F} -o name 2>/dev/null"
printf 'legacy\n' > "${WORK}/uc-mode"
G=reset.legacy-at-teknoir.ai
new_user "${G}" reset.legacy@teknoir.ai
check "the stand-in recorded a legacy value for ${G}" wait_until 30 has_legacy "${G}"
uidG="$(kc_uid reset.legacy@teknoir.ai)"
if admin_user --email reset.legacy@teknoir.ai --reset-password --out "${WORK}/files/resetG.txt" > "${WORK}/out/resetG.log" 2>&1; then
  ok "--reset-password (legacy value on record) exits 0"
else
  bad "--reset-password (legacy value on record) exits 0"; cat "${WORK}/out/resetG.log"
fi
check "  ... the file holds the password Keycloak got" same_file "${WORK}/files/resetG.txt" "${WORK}/rec/reset-${uidG}.txt"
check "  ... the superseded status.set_initial_password is removed" bash -c "grep -q 'removed the superseded status.set_initial_password of User ${G}' '${WORK}/out/resetG.log' && ! kubectl --context ${CTX} get users.teknoir.org ${G} -o json | jq -e '.status | has(\"set_initial_password\")' >/dev/null"

say "a Secret replaced between the read and the delete survives (uid/resourceVersion preconditions)"
printf 'secret\n' > "${WORK}/uc-mode"
H=swap.secret-at-teknoir.ai
new_user "${H}" swap.secret@teknoir.ai
check "the stand-in recorded a Secret for ${H}" wait_until 30 has_k1 "${H}"
if WRAP_MODE=secret-swap WRAP_NAME="${H}" admin_user --email swap.secret@teknoir.ai --out "${WORK}/files/pwH.txt" > "${WORK}/out/runH1.log" 2>&1; then
  bad "admin-user fails when the Secret changed after it was read"
else
  ok "admin-user fails when the Secret changed after it was read"
fi
check "  ... the interference fired" test -d "${WORK}/wrap/fired-secret-swap"
check "  ... it says the Secret changed since it was read" grep -q "changed since it was read" "${WORK}/out/runH1.log"
check "  ... the replaced Secret still exists with its new value" k1_holds "${H}" "${WORK}/rec/${H}.new"
admin_user --email swap.secret@teknoir.ai --out "${WORK}/files/pwH2.txt" > "${WORK}/out/runH2.log" 2>&1 || { bad "the re-run with a new --out exits 0"; cat "${WORK}/out/runH2.log"; }
check "  ... a re-run with a new --out hands over the new value and deletes the Secret" bash -c "cmp -s '${WORK}/files/pwH2.txt' '${WORK}/rec/${H}.new' && ! kubectl --context ${CTX} -n ${CRED_NS} get secret user-initial-password-${H} -o name 2>/dev/null"

say "a legacy value replaced during the handover is kept (sha256 guard); a conflicting status change is retried"
printf 'legacy\n' > "${WORK}/uc-mode"
I=swap.legacy-at-teknoir.ai
new_user "${I}" swap.legacy@teknoir.ai
check "the stand-in recorded a legacy value for ${I}" wait_until 30 has_legacy "${I}"
if WRAP_MODE=legacy-swap WRAP_NAME="${I}" admin_user --email swap.legacy@teknoir.ai --out "${WORK}/files/pwI.txt" > "${WORK}/out/runI1.log" 2>&1; then
  bad "admin-user fails when the legacy value changed during the handover"
else
  ok "admin-user fails when the legacy value changed during the handover"
fi
check "  ... the interference fired" test -d "${WORK}/wrap/fired-legacy-swap"
check "  ... it says the value changed during the handover" grep -q "status.set_initial_password of User ${I} changed during the handover" "${WORK}/out/runI1.log"
check "  ... the new value is still on record" legacy_holds "${I}" "${WORK}/rec/${I}.new"
if WRAP_MODE=status-bump WRAP_NAME="${I}" admin_user --email swap.legacy@teknoir.ai --out "${WORK}/files/pwI2.txt" > "${WORK}/out/runI2.log" 2>&1; then
  ok "a re-run, with a conflicting change to the User before the status patch, exits 0"
else
  bad "a re-run, with a conflicting change to the User before the status patch, exits 0"; cat "${WORK}/out/runI2.log"
fi
check "  ... the interference fired and the status patch was retried" bash -c "[[ -d '${WORK}/wrap/fired-status-bump' ]] && grep -q 'User ${I} changed meanwhile; reading it again' '${WORK}/out/runI2.log'"
check "  ... the file holds the new value and the field is removed" bash -c "cmp -s '${WORK}/files/pwI2.txt' '${WORK}/rec/${I}.new' && ! kubectl --context ${CTX} get users.teknoir.org ${I} -o json | jq -e '.status | has(\"set_initial_password\")' >/dev/null"

say "owner claims: claim_set null, and a conflicting change to the User before the patch"
printf 'secret\n' > "${WORK}/uc-mode"
KN=null.claims-at-teknoir.ai
new_profile team-k null.claims@teknoir.ai
K apply -f - >/dev/null <<EOF
apiVersion: teknoir.org/v1
kind: User
metadata: {name: ${KN}}
spec: {email: null.claims@teknoir.ai, email_verified: true, enabled: true, claims_v0: {role: superadmin}, plugins: [], claim_set: null}
EOF
# the API server prunes a null (as with user-controller's CRD, where claim_set
# is a non-nullable array); to admin-user's jq an absent claim_set and a null
# one are the same value, so this is the null path as well
check "claim_set: null in the manifest is stored as no claim_set" bash -c "kubectl --context ${CTX} get users.teknoir.org ${KN} -o json | jq -e '.spec | has(\"claim_set\") | not' >/dev/null"
if WRAP_MODE=claims-bump WRAP_NAME="${KN}" admin_user --email null.claims@teknoir.ai --out "${WORK}/files/pwK.txt" > "${WORK}/out/runK.log" 2>&1; then
  ok "admin-user exits 0"
else
  bad "admin-user exits 0"; cat "${WORK}/out/runK.log"
fi
check "  ... the interference fired and the claim patch was retried" bash -c "[[ -d '${WORK}/wrap/fired-claims-bump' ]] && grep -q 'User ${KN} changed meanwhile; reading it again' '${WORK}/out/runK.log'"
check "  ... claim_set is exactly [owner@team-k], added once" bash -c "kubectl --context ${CTX} get users.teknoir.org ${KN} -o json | jq -e '.spec.claim_set == [{name: \"owner\", namespace: \"team-k\"}]' >/dev/null && [[ \$(grep -c 'changed: User ${KN}: claim owner@team-k' '${WORK}/out/runK.log') == 1 ]]"
check "  ... the catalog's memberOf has group:team-k/team-k when it returned" cat_member "${KN}" group:team-k/team-k

say "the catalog lists the user but never with its teamspace"
L=no.group-at-teknoir.ai
new_profile team-l no.group@teknoir.ai
printf '%s\n' "${L}" >> "${WORK}/no-groups"
new_user "${L}" no.group@teknoir.ai
check "the catalog lists ${L} (without its teamspace)" wait_until 60 cat_listed "${L}"
if ADMIN_CATALOG_TIMEOUT=6 admin_user --email no.group@teknoir.ai --out "${WORK}/files/pwL.txt" > "${WORK}/out/runL.log" 2>&1; then
  bad "a missing teamspace group times out non-zero"
else
  ok "a missing teamspace group times out non-zero"
fi
check "  ... the timeout names the group, memberOf and the ClaimSet" bash -c "grep -q 'timed out after 6s waiting until the Backstage catalog lists user:default/${L} as a member of group:team-l/team-l' '${WORK}/out/runL.log' && grep -q 'memberOf lacks' '${WORK}/out/runL.log' && grep -q 'ClaimSet owner' '${WORK}/out/runL.log'"
check "  ... the password was handed over before (equal)" same_file "${WORK}/files/pwL.txt" "${WORK}/rec/${L}"

say "the catalog does not list the user in time"
printf 'secret\n' > "${WORK}/uc-mode"
printf '%s\n' "${C}" >> "${WORK}/no-catalog"
if ADMIN_CATALOG_TIMEOUT=5 admin_user --email late.user@teknoir.ai --out "${WORK}/files/pwC.txt" > "${WORK}/out/runC.log" 2>&1; then
  bad "a catalog timeout exits non-zero"
else
  ok "a catalog timeout exits non-zero"
fi
check "the timeout names the provider schedule and its log" bash -c "grep -q 'timed out after 5s' '${WORK}/out/runC.log' && grep -q 'does not list user:default/${C}' '${WORK}/out/runC.log' && grep -q 'catalog.providers.k8s.users' '${WORK}/out/runC.log' && grep -q 'user-provider' '${WORK}/out/runC.log'"
check "the password was still handed over before (0600, equal)" bash -c "cmp -s '${WORK}/files/pwC.txt' '${WORK}/rec/${C}' && [[ \$(stat -c %a '${WORK}/files/pwC.txt') == 600 ]]"
check "a user owning no teamspace gets no claim" bash -c "grep -q 'owns no teamspace' '${WORK}/out/runC.log' && kubectl --context ${CTX} get users.teknoir.org ${C} -o json | jq -e '.spec | has(\"claim_set\") | not' >/dev/null"
check "backstage-api was never restarted" test "$(K -n teknoir-system get deploy backstage-api -o jsonpath='{.metadata.generation}')" == "${gen0}"

say "no secret value in any output"
check "no password (temporary, reset, Keycloak admin) in any log" no_secret_in "${WORK}"/out/*.log

say "result: ${PASS} passed, ${FAIL} failed"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED[@]}"
  exit 1
fi
