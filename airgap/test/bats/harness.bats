#!/usr/bin/env bats
# harness.bats — self-tests of the test harness (I-16): the k3d suite, the VM
# scripts, the LAN namespace and the e2e driver. None of these tests starts a
# cluster or a VM, needs root, or touches the network.

# shellcheck disable=SC2016,SC2030,SC2031  # code strings for the inner shells; bats runs each test in a subshell

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
  # shellcheck source=../k3d/run.sh
  source "${K3D}"
  [ "$(gvk_resource '/v1, Kind=Secret')" = "Secret.v1." ]
  [ "$(gvk_resource 'apiextensions.k8s.io/v1, Kind=CustomResourceDefinition')" = "CustomResourceDefinition.v1.apiextensions.k8s.io" ]
  [ "$(gvk_resource 'networking.istio.io/v1beta1, Kind=VirtualService')" = "VirtualService.v1beta1.networking.istio.io" ]
}

@test "k3d: the T9 fixture reproduces the live canonical -> legacy secret file names" {
  # shellcheck source=../k3d/run.sh
  source "${K3D}"
  local f legacy=""
  while read -r f _ _; do legacy+="$(legacy_name "${f}") "; done <<<"${T9_SECRETS}"
  for f in ${legacy}; do
    [[ " ${LIVE_TEKNOIR_ADDONS//$'\n'/ } " == *" ${f} "* ]] || { echo "not a live Addon: ${f}"; return 1; }
  done
  [ "$(wc -w <<<"${legacy}")" -eq 9 ]
}

@test "k3d: the T9 fixture has the 14 istio, 6 cert-manager and 3 argoproj CRDs" {
  # shellcheck source=../k3d/run.sh
  source "${K3D}"
  [ "$(grep -c . <<<"${ISTIO_CRDS}")" -eq 14 ]
  [ "$(grep -c . <<<"${CERTMANAGER_CRDS}")" -eq 6 ]
  [ "$(grep -c . <<<"${ARGO_CRDS}")" -eq 3 ]
  grep -qx 'appprojects.argoproj.io AppProject' <<<"${ARGO_CRDS}"
}

@test "k3d: every kubectl call goes through kc with an explicit --context" {
  # kubectl in a command position (line start, after ; | & ( or $( ), other than kc() itself
  local hits
  hits="$(grep -nE '(^[[:space:]]*|[;|&(][[:space:]]*|\$\([[:space:]]*)kubectl[[:space:]]' "${K3D}" |
          grep -v 'kc() { kubectl --context "${CTX}"' || true)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
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
  local hits
  hits="$(grep -nE '/etc/hosts' "${VM}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
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
  refute_grep -n '192\.168\.' <<<"${output}"
  grep -qE '^127\.0\.0\.1[[:space:]]+localhost' <<<"${output}"
}

@test "lan-netns.sh hosts: follows the site file" {
  printf 'TEKNOIR_ENV=x\nTEKNOIR_DOMAIN=example.test\nNODE_IP=10.9.8.7\nTEKNOIR_HOSTNAMES="a b"\n' > "${BATS_TEST_TMPDIR}/s.env"
  LAN_SITE="${BATS_TEST_TMPDIR}/s.env" run "${NETNS}" hosts
  [ "${status}" -eq 0 ]
  grep -qE '^10\.9\.8\.7[[:space:]]+example\.test a\.example\.test b\.example\.test$' <<<"${output}"
}

@test "lan-netns.sh: never edits vpro's /etc/hosts, adds no default route" {
  refute_grep -nE '(>|tee|sed -i|install)[^#]* /etc/hosts' "${NETNS}"
  refute_grep -nE 'route add default|route replace default' "${NETNS}"
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
  # shellcheck source=../vm/e2e.sh
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
  [[ "${calls}" == *'lan "${dir}" ./teknoir-airgap "${cmd}" --site "${site}"'* ]]
  # ${site} is the bundle's site/vmtest.env or the repo copy, never empty
  grep -q 'local dir="$1" cmd="$2" site="${SITE_FILE}"' "${E2E}"
}

vm_args_with_shell() {
  # vm_args_with_shell <code> — print every line of <code> on which a vmx or
  # vm_kc call has a quoted argument holding shell syntax (< > | ; & or $( in
  # single quotes). vmx %q-quotes each word, so the VM gets such an argument
  # as one literal word: `vmx 'cat > f'` runs a command named "cat > f" (exit
  # 127). Words after the call's end (an unquoted | ; & < > or ")") are not
  # its arguments; ${...} and $(...) in double quotes expand locally; the
  # script of `vmx [sudo] sh|bash -c '...'` is meant for that shell.
  local line rest i c q word
  while IFS= read -r line; do
    [[ "${line}" =~ (^|[[:space:]\;\&\|\(])(vmx|vm_kc)[[:space:]](.*)$ ]] || continue
    rest="${BASH_REMATCH[3]}" q="" word=""
    [[ "${rest}" =~ ^[[:space:]]*(sudo[[:space:]]+)?(ba)?sh[[:space:]]+-c[[:space:]] ]] && continue
    for (( i = 0; i < ${#rest}; i++ )); do
      c="${rest:i:1}"
      if [[ -n "${q}" ]]; then
        if [[ "${c}" != "${q}" ]]; then word+="${c}"; continue; fi
        if [[ "${q}" == '"' ]]; then
          word="$(sed -E 's/\$\{[^}]*\}//g; s/\$\([^)]*\)//g' <<<"${word}")"
          [[ "${word}" =~ [\<\>\|\;\&] ]] && { printf '%s\n' "${line}"; break; }
        else
          [[ "${word}" =~ [\<\>\|\;\&\`]|\$\( ]] && { printf '%s\n' "${line}"; break; }
        fi
        q="" word=""
      else
        case "${c}" in
          "'"|'"') q="${c}" ;;
          '|'|';'|'&'|'<'|'>'|')') break ;;
        esac
      fi
    done
  done <<<"$1"
}

@test "e2e.sh: no vmx/vm_kc argument hides shell syntax (vmx %q-quotes every word)" {
  # self-check of the detector: planted bad calls are found, valid ones are not
  local planted
  planted="$(cat <<'EOF'
vmx 'cat > /tmp/e2e-transcript.log' < "${TRANSCRIPT}"
x="$(vmx "sudo ls /x | wc -l")"
vmx 'echo $(id)'
vmx sudo sh -c 'echo $(id) > /tmp/id'
vm_kc get pods -A -o json | jq -r '.items[] | .metadata.name'
vmx sudo rm -rf "/var/lib/teknoir-airgap/bundles/$1" > /dev/null 2>&1 || true
vmx sudo pkill -TERM -f 'teknoir-node converge' > /dev/null 2>&1 || true
vmx sudo k3s ctr -n k8s.io images rm "${img}" "$(printf '%s|%s' a b)"
EOF
)"
  [ "$(vm_args_with_shell "${planted}" | wc -l)" -eq 3 ]
  # every call in e2e.sh, as bash parsed it (declare -f: no comments)
  local hits
  hits="$(vm_args_with_shell "$(bash -c "source '${E2E}' && declare -f")")"
  [ -z "${hits}" ] || { echo "${hits}"; return 1; }
}

@test "e2e.sh: vm_upload writes its stdin to the VM path (0600), where vmx with a redirection fails" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  # vm.sh ssh <command string> -> the VM's login shell runs the string
  VM="${BATS_TEST_TMPDIR}/vm.sh"
  printf '#!/usr/bin/env bash\n[ "$1" = ssh ] || exit 9\ncd "%s" && exec bash -c "$2"\n' "${BATS_TEST_TMPDIR}" > "${VM}"
  chmod +x "${VM}"
  printf 'line one\nline two\n' > "${BATS_TEST_TMPDIR}/src"
  mkdir -p "${BATS_TEST_TMPDIR}/up"
  vm_upload "${BATS_TEST_TMPDIR}/up/t r.log" < "${BATS_TEST_TMPDIR}/src"
  cmp "${BATS_TEST_TMPDIR}/src" "${BATS_TEST_TMPDIR}/up/t r.log"
  [ "$(stat -c %a "${BATS_TEST_TMPDIR}/up/t r.log")" = 600 ]
  # the pre-fix E7 call: the VM gets the single word 'cat > /tmp/...'
  run -127 vmx 'cat > out.log' < "${BATS_TEST_TMPDIR}/src"
  [ "${status}" -eq 127 ]
  [ ! -e "${BATS_TEST_TMPDIR}/out.log" ]
}

@test "e2e.sh: added_lines (E4, E8) returns the changed lines under set -euo pipefail" {
  # diff exits 1 when the lines differ, the expected case; it must not abort
  run bash -c "set -euo pipefail; source '${E2E}'
    c=\"\$(added_lines \"\$(printf 'a 1\nb 2\nc 3')\" \"\$(printf 'a 1\nb 5\nc 3\nd 1')\" | awk '{print \$1}' | tr '\n' ' ')\"
    echo \"changed=[\${c}]\"
    s=\"\$(added_lines x x)\"
    echo \"same=[\${s}]\""
  [ "${status}" -eq 0 ]
  [ "${lines[0]}" = "changed=[b d ]" ]
  [ "${lines[1]}" = "same=[]" ]
}

@test "e2e.sh: image_names (E3) matches pod image refs the way containerd lists them" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local ref want got
  while IFS='|' read -r ref want; do
    got="$(image_names "${ref}" | tr '\n' ' ' | sed 's/ $//')"
    [ "${got}" = "${want}" ] || { echo "${ref}: got '${got}', want '${want}'"; return 1; }
  done <<'EOF'
busybox:latest|docker.io/library/busybox:latest
busybox|docker.io/library/busybox:latest
rancher/mirrored-pause:3.6|docker.io/rancher/mirrored-pause:3.6
docker.io/busybox:1.36|docker.io/library/busybox:1.36
docker.io/alpine/k8s:1.34.11|docker.io/alpine/k8s:1.34.11
quay.io/kiwigrid/k8s-sidecar:2.5.4|quay.io/kiwigrid/k8s-sidecar:2.5.4
harbor.teknoir.airgapped/teknoir/x:1|harbor.teknoir.airgapped/teknoir/x:1
ghcr.io/teknoir/backstage|ghcr.io/teknoir/backstage:latest
localhost/foo|localhost/foo:latest
registry:5000/foo|registry:5000/foo:latest
ghcr.io/teknoir/backstage@sha256:abc|ghcr.io/teknoir/backstage@sha256:abc
busybox:1.36@sha256:abc|docker.io/library/busybox:1.36@sha256:abc docker.io/library/busybox@sha256:abc docker.io/library/busybox:1.36
EOF
}

# ---------------------------------------------------------------------------
# kc-login.sh
# ---------------------------------------------------------------------------
@test "kc-login.sh: required arguments" {
  run "${KCLOGIN}" --url https://x.example/
  [ "${status}" -eq 2 ]
}

@test "kc-login.sh: parses the Keycloak login and required-action forms" {
  # shellcheck source=../vm/kc-login.sh
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

@test "kc-login.sh: Update Profile uses the form's e-mail, else an address-shaped --user" {
  # shellcheck source=../vm/kc-login.sh
  source "${KCLOGIN}"
  page="${BATS_TEST_TMPDIR}/page.html"
  printf '<form id="kc-update-profile-form" action="x"><input type="text" id="email" name="email" value=""></form>\n' > "${page}"
  LOGIN_USER=e2e-admin@example.com
  [ "$(profile_email)" = e2e-admin@example.com ]
  LOGIN_USER=someone
  [ "$(profile_email)" = someone@example.invalid ]
  printf '<form id="kc-update-profile-form" action="x"><input type="text" id="email" name="email" value="kept@example.org"></form>\n' > "${page}"
  [ "$(profile_email)" = kept@example.org ]
}

@test "e2e.sh: the first admin comes from admin-user; the login user is its address in lower case" {
  run bash -c "E2E_ADMIN_EMAIL=Ops.Admin@Example.COM; source '${E2E}'; printf '%s|%s' \"\${ADMIN_EMAIL}\" \"\${ADMIN_USER}\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "Ops.Admin@Example.COM|ops.admin@example.com" ]
  run bash -c "source '${E2E}'; printf '%s' \"\${ADMIN_USER}\""
  [ "${output}" = e2e-admin@example.com ]
  # E1 runs admin-user --email --out; nothing asks for the retired platform-admin credential
  grep -q 'tk "${dir}" admin-user --email "${ADMIN_EMAIL}" --out "${pw}"' "${E2E}"
  refute_grep -n 'platform-admin' "${E2E}" "${KCLOGIN}"
}

@test "kc-login.sh: passwords reach curl only as @file, never as an argument" {
  refute_grep -nE 'password=\$|password-new=\$|password-confirm=\$' "${KCLOGIN}"
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
