#!/usr/bin/env bats
# harness.bats — self-tests of the test harness (I-16): the k3d suite, the VM
# scripts, the LAN namespace and the e2e driver. None of these tests starts a
# cluster or a VM, needs root, or touches the network.

load test_helper

K3D="${REPO_ROOT}/airgap/test/k3d/run.sh"
VM="${REPO_ROOT}/airgap/test/vm/vm.sh"
NETNS="${REPO_ROOT}/airgap/test/vm/lan-netns.sh"
E2E="${REPO_ROOT}/airgap/test/vm/e2e.sh"
KCLOGIN="${REPO_ROOT}/airgap/test/vm/kc-login.sh"

# The live teknoir-local Addons (read-only inventory, 2026-10-08).
LIVE_TEKNOIR_ADDONS="00-teknoir-istio-crds 00-teknoir-namespaces 05-teknoir-certmanager-crds 10-teknoir-argo
app-of-apps manifest-argocd-harbor-repo-secret manifest-argocd-keycloak-secret manifest-harbor-secret
manifest-keycloak-db-secret manifest-oauth2-proxy-redis-secret manifest-oauth2-proxy-secret
manifest-teknoir-auth-ca-bundle-secret manifest-teknoir-ca-secret manifest-teknoir-system-ca-bundle-secret
teknoir-app-of-apps teknoir-argo teknoir-argocd-harbor-repo-secret teknoir-argocd-keycloak-secret
teknoir-auth-ca-bundle-secret teknoir-ca-secret teknoir-coredns-custom teknoir-harbor-secret
teknoir-keycloak-db-secret teknoir-oauth2-proxy-redis-secret teknoir-oauth2-proxy-secret teknoir-system-ca-bundle-secret"
LIVE_K3S_ADDONS="aggregated-metrics-reader auth-delegator auth-reader ccm coredns local-storage metrics-apiservice
metrics-server-deployment metrics-server-service resource-reader rolebindings runtimes traefik"

# ---------------------------------------------------------------------------
# k3d suite
# ---------------------------------------------------------------------------
@test "k3d: --list names T1-T6, T4N and T9" {
  run "${K3D}" --list
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | tr '\n' ' ')" = "T1 T2 T3 T4 T4N T5 T6 T9 " ]
}

@test "k3d: an unknown test is refused" {
  run "${K3D}" T42
  [ "${status}" -ne 0 ]
}

@test "k3d: the Teknoir Addon allow-list matches every live Teknoir Addon and no K3s addon" {
  # shellcheck source=../k3d/run.sh
  source "${K3D}"
  local n
  for n in ${LIVE_TEKNOIR_ADDONS}; do
    [[ "${n}" =~ ${TEKNOIR_ADDON_RE} ]] || { echo "not matched: ${n}"; return 1; }
  done
  for n in ${LIVE_K3S_ADDONS} zz-k3d-sentinel t4 t4n; do
    if [[ "${n}" =~ ${TEKNOIR_ADDON_RE} ]]; then echo "wrongly matched: ${n}"; return 1; fi
  done
}

@test "k3d: gvk_resource maps Addon GVK strings to kubectl kind.version.group" {
  source "${K3D}"
  [ "$(gvk_resource '/v1, Kind=Secret')" = "Secret.v1." ]
  [ "$(gvk_resource 'apiextensions.k8s.io/v1, Kind=CustomResourceDefinition')" = "CustomResourceDefinition.v1.apiextensions.k8s.io" ]
  [ "$(gvk_resource 'networking.istio.io/v1beta1, Kind=VirtualService')" = "VirtualService.v1beta1.networking.istio.io" ]
}

@test "k3d: the T9 fixture reproduces the live canonical -> legacy secret file names" {
  source "${K3D}"
  local f legacy=""
  while read -r f _ _; do legacy+="$(legacy_name "${f}") "; done <<<"${T9_SECRETS}"
  for f in ${legacy}; do
    [[ " ${LIVE_TEKNOIR_ADDONS//$'\n'/ } " == *" ${f} "* ]] || { echo "not a live Addon: ${f}"; return 1; }
  done
  [ "$(wc -w <<<"${legacy}")" -eq 9 ]
}

@test "k3d: the T9 fixture has the 14 istio, 6 cert-manager and 3 argoproj CRDs" {
  source "${K3D}"
  [ "$(grep -c . <<<"${ISTIO_CRDS}")" -eq 14 ]
  [ "$(grep -c . <<<"${CERTMANAGER_CRDS}")" -eq 6 ]
  [ "$(grep -c . <<<"${ARGO_CRDS}")" -eq 3 ]
  grep -qx 'appprojects.argoproj.io AppProject' <<<"${ARGO_CRDS}"
}

@test "k3d: every kubectl call goes through kc with an explicit --context" {
  # kubectl in a command position (line start, after ; | & ( or $( ), other than kc() itself
  ! grep -nE '(^[[:space:]]*|[;|&(][[:space:]]*|\$\([[:space:]]*)kubectl[[:space:]]' "${K3D}" | grep -v 'kc() { kubectl --context "${CTX}"'
}

# ---------------------------------------------------------------------------
# VM scripts (D13)
# ---------------------------------------------------------------------------
@test "vm.sh: the VM uses teknoir.airgapped at 10.77.0.10 by default" {
  grep -q 'DOMAIN="${VM_DOMAIN:-teknoir.airgapped}"' "${VM}"
  grep -q 'VM_IP="${VM_IP:-10.77.0.10}"' "${VM}"
}

@test "vm.sh: no hosts-up/hosts-down and no write to /etc/hosts" {
  run "${VM}" hosts-up
  [ "${status}" -ne 0 ]
  ! grep -nE '/etc/hosts' "${VM}" | grep -vE '^[0-9]+:\s*#'
}

@test "vm.sh: VM state lives in VM_DIR, not in the repo" {
  VM_DIR="${BATS_TEST_TMPDIR}/vmdir" run "${VM}" key
  [ "${status}" -eq 0 ]
  [ "${output}" = "${BATS_TEST_TMPDIR}/vmdir/id_ed25519" ]
}

@test "lan-netns.sh hosts: apex and every site hostname map to NODE_IP" {
  run "${NETNS}" hosts
  [ "${status}" -eq 0 ]
  line="$(grep -E '^10\.77\.0\.10[[:space:]]' <<<"${output}")"
  for n in teknoir.airgapped harbor.teknoir.airgapped argocd.teknoir.airgapped auth.teknoir.airgapped \
           keycloak.teknoir.airgapped grafana.teknoir.airgapped; do
    [[ " ${line//$'\t'/ } " == *" ${n} "* ]] || { echo "missing ${n}"; return 1; }
  done
  ! grep -q '192\.168\.' <<<"${output}"
  grep -qE '^127\.0\.0\.1[[:space:]]+localhost' <<<"${output}"
}

@test "lan-netns.sh hosts: follows the site file" {
  printf 'TEKNOIR_ENV=x\nTEKNOIR_DOMAIN=example.test\nNODE_IP=10.9.8.7\nTEKNOIR_HOSTNAMES="a b"\n' > "${BATS_TEST_TMPDIR}/s.env"
  LAN_SITE="${BATS_TEST_TMPDIR}/s.env" run "${NETNS}" hosts
  [ "${status}" -eq 0 ]
  grep -qE '^10\.9\.8\.7[[:space:]]+example\.test a\.example\.test b\.example\.test$' <<<"${output}"
}

@test "lan-netns.sh: never edits vpro's /etc/hosts, adds no default route" {
  ! grep -nE '(>|tee|sed -i|install)[^#]* /etc/hosts' "${NETNS}"
  ! grep -nE 'route add default|route replace default' "${NETNS}"
  grep -q 'ETC="/etc/netns/${NS}"' "${NETNS}"
}

@test "lan-netns.sh: unknown commands are refused" {
  run "${NETNS}" frobnicate
  [ "${status}" -ne 0 ]
}

@test "airgap/site/vmtest.env: the VM site (D13)" {
  run bash -c "set -u; . '${VMTEST_SITE}'; printf '%s|%s|%s|%s|%s|%s' \"\${TEKNOIR_ENV}\" \"\${TEKNOIR_DOMAIN}\" \"\${NODE_IP}\" \"\${NODE}\" \"\${TEKNOIR_HOSTNAMES}\" \"\${K3S_DATA_DIR}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "teknoir-local|teknoir.airgapped|10.77.0.10|teknoir@10.77.0.10|harbor argocd auth keycloak grafana|/opt/k3s" ]
}

# ---------------------------------------------------------------------------
# e2e driver
# ---------------------------------------------------------------------------
@test "e2e.sh: --list names E1-E8 and E10 (E7 before E6, which wipes the node logs)" {
  run "${E2E}" --list
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | tr '\n' ' ')" = "E1 E2 E3 E4 E5 E8 E7 E6 E10 " ]
}

@test "e2e.sh: an unknown scenario is refused" {
  run "${E2E}" E99
  [ "${status}" -ne 0 ]
}

@test "e2e.sh: the VM-destroying scenarios need --allow-destroy" {
  source "${E2E}"
  grep -q 'ALLOW_DESTROY=0' "${E2E}"
  for s in e1 e6 e10; do
    declare -f "${s}" | grep -qE 'fresh_vm|ALLOW_DESTROY' || { echo "${s} does not guard"; return 1; }
  done
}

@test "e2e.sh: teknoir-airgap runs only through tk(): in the netns, always with the vmtest --site" {
  # without --site the bundle's own site file would name the real teknoir-local node
  local calls
  calls="$(grep -nE '^[^#]*[^`]\./teknoir-airgap ' "${E2E}" | grep -v '^\S*:[[:space:]]*#' || true)"
  [ "$(grep -c . <<<"${calls}")" -eq 1 ]
  [[ "${calls}" == *'lan "${dir}" ./teknoir-airgap "${cmd}" --site "${SITE_FILE}"'* ]]
}

# ---------------------------------------------------------------------------
# kc-login.sh
# ---------------------------------------------------------------------------
@test "kc-login.sh: required arguments" {
  run "${KCLOGIN}" --url https://x.example/
  [ "${status}" -eq 2 ]
}

@test "kc-login.sh: parses the Keycloak login and required-action forms" {
  source "${KCLOGIN}"
  page="${BATS_TEST_TMPDIR}/page.html"
  cat > "${page}" <<'EOF'
<html><body>
<form id="kc-form-login" onsubmit="login.disabled = true; return true;"
      action="https://auth.teknoir.airgapped/realms/teknoir/login-actions/authenticate?session_code=abc&amp;execution=e1&amp;client_id=teknoir&amp;tab_id=t9" method="post">
  <input tabindex="1" id="username" name="username" value="" type="text">
</form>
<form id="kc-update-profile-form" class="x" action="https://auth.teknoir.airgapped/realms/teknoir/login-actions/required-action?execution=UPDATE_PROFILE&amp;client_id=teknoir" method="post">
  <input type="text" id="email" name="email" value="admin@example.invalid">
</form>
</body></html>
EOF
  [ "$(form_action kc-form-login)" = "https://auth.teknoir.airgapped/realms/teknoir/login-actions/authenticate?session_code=abc&execution=e1&client_id=teknoir&tab_id=t9" ]
  [ "$(form_action kc-update-profile-form)" = "https://auth.teknoir.airgapped/realms/teknoir/login-actions/required-action?execution=UPDATE_PROFILE&client_id=teknoir" ]
  [ -z "$(form_action kc-passwd-update-form)" ]
  [ "$(input_value email)" = "admin@example.invalid" ]
}

@test "kc-login.sh: passwords reach curl only as @file, never as an argument" {
  ! grep -nE 'password=\$|password-new=\$|password-confirm=\$' "${KCLOGIN}"
  grep -q 'password@' "${KCLOGIN}"
}

# ---------------------------------------------------------------------------
# testlib
# ---------------------------------------------------------------------------
@test "testlib: the summary fails when one assertion failed, passes otherwise" {
  run bash -c "source '${REPO_ROOT}/airgap/test/lib/testlib.sh'; tl_case A one; pass ok; tl_case B two; skip_case why; tl_summary"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 passed, 0 failed, 1 skipped"* ]]
  run bash -c "source '${REPO_ROOT}/airgap/test/lib/testlib.sh'; tl_case A one; pass ok; assert_eq x 1 2; tl_summary"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"0 passed, 1 failed"* ]]
}
