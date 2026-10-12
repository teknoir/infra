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
@test "k3d: --list names T1-T6, T4N, T9 and T10" {
  run "${K3D}" --list
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | tr '\n' ' ')" = "T1 T2 T3 T4 T4N T5 T6 T9 T10 " ]
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

@test "vm.sh: the host INPUT drop for the bridge still lets replies to the host's own connections in (vm.sh ssh)" {
  # the host starts ssh/ping to the VM; the replies arrive on the bridge and hit INPUT -i tkvm0 -j DROP
  # unless an ESTABLISHED,RELATED accept sits in front of it (never NEW: the VM reaches no host service)
  grep -q 'INPUT 1 -i "${BR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "${VM}"
  refute_grep -q 'conntrack --ctstate [A-Z,]*NEW' "${VM}"
  grep -q 'INPUT -i "${BR}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do' "${VM}"
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

@test "lan-netns.sh hosts: a host named like the domain gets no 127.0.1.1 line (the dev host is teknoir.airgapped)" {
  printf 'TEKNOIR_ENV=x\nTEKNOIR_DOMAIN=%s\nNODE_IP=10.9.8.7\nTEKNOIR_HOSTNAMES="a"\n' "$(uname -n)" > "${BATS_TEST_TMPDIR}/s.env"
  LAN_SITE="${BATS_TEST_TMPDIR}/s.env" run "${NETNS}" hosts
  [ "${status}" -eq 0 ]
  refute_grep -n '^127\.0\.1\.1' <<<"${output}"
  grep -qE "^10\.9\.8\.7[[:space:]]+$(uname -n) a\.$(uname -n)\$" <<<"${output}"
}

@test "lan-netns.sh hosts: another host name keeps its 127.0.1.1 line" {
  printf 'TEKNOIR_ENV=x\nTEKNOIR_DOMAIN=not-%s.test\nNODE_IP=10.9.8.7\nTEKNOIR_HOSTNAMES="a"\n' "$(uname -n)" > "${BATS_TEST_TMPDIR}/s.env"
  LAN_SITE="${BATS_TEST_TMPDIR}/s.env" run "${NETNS}" hosts
  [ "${status}" -eq 0 ]
  grep -qE "^127\.0\.1\.1[[:space:]]+$(uname -n)\$" <<<"${output}"
}

@test "vm.sh ram-check: refuses a VM that does not fit, VM_SKIP_RAM_CHECK=1 overrides" {
  VM_MEM_MB=99999999 run "${VM}" ram-check
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"not enough free RAM"* ]]
  VM_MEM_MB=99999999 VM_SKIP_RAM_CHECK=1 run "${VM}" ram-check
  [ "${status}" -eq 0 ]
}

@test "vm.sh: the default VM memory is at least 10240 MiB" {
  grep -q 'MEM_MB="${VM_MEM_MB:-10240}"' "${VM}"
}

@test "lan-netns.sh hosts: follows the site file" {
  printf 'TEKNOIR_ENV=x\nTEKNOIR_DOMAIN=example.test\nNODE_IP=10.9.8.7\nTEKNOIR_HOSTNAMES="a b"\n' > "${BATS_TEST_TMPDIR}/s.env"
  LAN_SITE="${BATS_TEST_TMPDIR}/s.env" run "${NETNS}" hosts
  [ "${status}" -eq 0 ]
  grep -qE '^10\.9\.8\.7[[:space:]]+example\.test a\.example\.test b\.example\.test$' <<<"${output}"
}

@test "lan-netns.sh: never edits the host's /etc/hosts, adds no default route" {
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
@test "e2e.sh: --list names E1-E8, E10 and E11-E15 (E11-E14 after E1, E7 before E6, the VM-destroying E10/E15 last)" {
  run "${E2E}" --list
  [ "${status}" -eq 0 ]
  [ "$(echo "${output}" | tr '\n' ' ')" = "E1 E11 E12 E13 E14 E2 E3 E4 E5 E8 E7 E6 E10 E15 " ]
}

@test "e2e.sh: every listed scenario has a function that opens its own case" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local s
  for s in "${ALL[@]}" E0; do
    declare -f "${s,,}" | grep -q "tl_case ${s} " || { echo "${s,,}() does not open case ${s}"; return 1; }
  done
}

@test "e2e.sh: an unknown scenario is refused" {
  run "${E2E}" E99
  [ "${status}" -ne 0 ]
}

@test "e2e.sh: the VM-destroying scenarios need --allow-destroy" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  grep -q 'ALLOW_DESTROY=0' "${E2E}"
  for s in e1 e6 e10 e15; do
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
  # E1 runs admin-user --email --out; neither E1 nor kc-login uses the retired
  # platform-admin credential; E13 asks for it only to prove that it is refused
  grep -q 'tk "${dir}" admin-user --email "${ADMIN_EMAIL}" --out "${pw}"' "${E2E}"
  run bash -c "source '${E2E}'; declare -f e1"
  refute_grep -n 'platform-admin' <<<"${output}"
  refute_grep -n 'platform-admin' "${KCLOGIN}"
  run bash -c "source '${E2E}'; declare -f e13_checks"
  grep -q 'a platform-admin sign-in is refused' <<<"${output}"
}

@test "e2e.sh: the first admin becomes the GitOps Profile owner unless E2E_ADMIN_EMAIL, and is remembered" {
  run bash -c "
    E2E_WORK='${BATS_TEST_TMPDIR}/w'; source '${E2E}'
    mkdir -p \"\${STATE}\"; tl_log() { :; }
    adopt_owner Anders.Aslund@Teknoir.AI
    printf '%s|%s|%s|' \"\${ADMIN_EMAIL}\" \"\${ADMIN_USER}\" \"\$(cat \"\${STATE}/admin-email\")\"
    adopt_owner ''
    printf '%s|' \"\${ADMIN_USER}\"
    printf '%s' \"\$(user_name \"\${ADMIN_EMAIL}\")\""
  [ "${status}" -eq 0 ]
  [ "${output}" = "Anders.Aslund@Teknoir.AI|anders.aslund@teknoir.ai|Anders.Aslund@Teknoir.AI|anders.aslund@teknoir.ai|anders.aslund-at-teknoir.ai" ]
  # an explicit E2E_ADMIN_EMAIL is never replaced
  run bash -c "E2E_ADMIN_EMAIL=ops@example.com E2E_WORK='${BATS_TEST_TMPDIR}/w2'; source '${E2E}'; mkdir -p \"\${STATE}\"
    adopt_owner owner@example.com; printf '%s' \"\${ADMIN_USER}\"; [ ! -e \"\${STATE}/admin-email\" ]"
  [ "${status}" -eq 0 ]
  [ "${output}" = ops@example.com ]
}

@test "kc-login.sh: passwords reach curl only as @file, never as an argument" {
  refute_grep -nE 'password=\$|password-new=\$|password-confirm=\$' "${KCLOGIN}"
  grep -q 'password@' "${KCLOGIN}"
}

@test "e2e.sh: hdr_get and expired_cookies read a raw response header file" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local h="${BATS_TEST_TMPDIR}/h"
  printf '%s\r\n' 'HTTP/1.1 302 Found' 'location: https://teknoir.airgapped/oauth2/start?rd=https%3A%2F%2Fteknoir.airgapped%2F' \
    'Set-Cookie: _teknoir_oauth2_proxy=; Domain=teknoir.airgapped; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; Secure; HttpOnly' \
    'set-cookie: _teknoir_oauth2_proxy=; Path=/; Max-Age=0; Secure' \
    'Set-Cookie: _teknoir_oauth2_proxy_csrf=; Path=/; Max-Age=0' \
    'Set-Cookie: _teknoir_oauth2_proxy=abc; Path=/' 'X-Harbor-Csrf-Token: tok123' '' > "${h}"
  [ "$(hdr_get "${h}" Location)" = "https://teknoir.airgapped/oauth2/start?rd=https%3A%2F%2Fteknoir.airgapped%2F" ]
  [ "$(hdr_get "${h}" x-harbor-csrf-token)" = tok123 ]
  [ -z "$(hdr_get "${h}" www-authenticate)" ]
  [ "$(expired_cookies "${h}" _teknoir_oauth2_proxy)" = 2 ]
  [ "$(expired_cookies "${h}" other)" = 0 ]
  [ "$(expired_cookies /no/such/file x)" = 0 ]
}

@test "e2e.sh: image_check_ok accepts post's 0-missing line only; transcript_since cuts at a mark" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  image_check_ok "12:00:01 [teknoir-node] live image check: 61 pullable from Harbor, 0 only in containerd, 0 missing"
  image_check_ok "live image check: 80 pullable, 0 missing"
  run image_check_ok "live image check: 61 pullable from Harbor, 0 only in containerd, 10 missing"
  [ "${status}" -ne 0 ]
  run image_check_ok "live image check: skipped (no k3s binary on this host)"
  [ "${status}" -ne 0 ]
  TRANSCRIPT="${BATS_TEST_TMPDIR}/t.log"
  printf 'before\n' > "${TRANSCRIPT}"
  local m; m="$(transcript_mark)"
  printf 'after 1\nafter 2\n' >> "${TRANSCRIPT}"
  [ "$(transcript_since "${m}")" = "$(printf 'after 1\nafter 2')" ]
}

@test "e2e.sh: can_i passes '*' literally and leaves stdin alone (the matrix loop is not eaten by ssh)" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  # a vm_kc that, like ssh, reads all of stdin, and echoes its arguments
  vm_kc() { cat >/dev/null; printf '%s|' "$@" >> "${BATS_TEST_TMPDIR}/calls"; echo no; }
  local who want line got n=0
  local -a args
  while IFS='|' read -r who want line; do
    read -r -a args <<<"${line}"
    got="$(can_i "${who}" "${args[@]}")"
    [ "${got}" = no ]
    n=$((n + 1))
  done <<'EOF'
teknoir-system/user-controller|no|* *
teknoir-system/user-controller|no|create pods --subresource=exec -n teknoir-auth
teknoir-system/profile-controller|no|create clusterrolebindings
EOF
  [ "${n}" -eq 3 ]
  grep -qF 'auth|can-i|*|*|--as=system:serviceaccount:teknoir-system:user-controller|' "${BATS_TEST_TMPDIR}/calls"
  grep -qF 'auth|can-i|create|pods|--subresource=exec|-n|teknoir-auth|' "${BATS_TEST_TMPDIR}/calls"
}

@test "e2e.sh: every script sent to the VM as root parses (bash -n)" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  vm_root() { bash -n || echo SYNTAX-ERROR; }
  vmx() { :; }
  local f out
  for f in "kc_user_state teknoir platform-admin" kc_master_clients e15_master_clients "kc_pw_created a@b.c" \
           "argocd_session_vm /root/x" rtc_offset kc_admin_codes e10_save_prev_pw e10_prev_pw_code robot_argocd_state e10_secret_hashes; do
    out="$(${f} 2>&1 || true)"
    [[ "${out}" != *SYNTAX-ERROR* ]] || { echo "${f}: ${out}"; return 1; }
  done
}

@test "e2e.sh: lan_secret_patterns lists the LAN-side passwords and the test age identities" {
  run bash -c "
    LAN_HOME='${BATS_TEST_TMPDIR}/lan' VM_DIR='${BATS_TEST_TMPDIR}/vm'; source '${E2E}'
    mkdir -p \"\${LAN_HOME}/e2e\" \"\${AGE_ID_DIR}\"
    printf 'temporary-password-one\n' > \"\${LAN_HOME}/e2e/admin.pw\"
    printf 'changed-password-two' > \"\${LAN_HOME}/e2e/admin.new\"
    : > \"\${LAN_HOME}/e2e/empty.pw\"
    printf '# created: x\n# public key: age1x\nAGE-SECRET-KEY-1TESTONLY\n' > \"\${AGE_ID_DIR}/vmtest.key\"
    lan_secret_patterns | sort"
  [ "${status}" -eq 0 ]
  [ "${output}" = "$(printf 'AGE-SECRET-KEY-1TESTONLY\nchanged-password-two\ntemporary-password-one')" ]
}

@test "e2e.sh: bundle_profile_owner reads the GitOps Profile owner from the bundle's profile-controller chart" {
  command -v helm >/dev/null || skip "helm not installed"
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local c="${BATS_TEST_TMPDIR}/chart/profile-controller" b="${BATS_TEST_TMPDIR}/bundle"
  mkdir -p "${c}/templates" "${b}/node/charts"
  printf 'apiVersion: v2\nname: profile-controller\nversion: 0.0.84\n' > "${c}/Chart.yaml"
  printf 'config:\n  admin: Owner@Example.com\nprofiles:\n  - name: other\n    owner: someone@example.com\n  - name: teknoir-default\n' > "${c}/values.yaml"
  cat > "${c}/templates/profiles.yaml" <<'EOF'
{{- range .Values.profiles }}
---
apiVersion: teknoir.org/v1
kind: Profile
metadata:
  name: {{ .name }}
spec:
  owner:
    kind: User
    name: {{ .owner | default $.Values.config.admin | lower }}
{{- end }}
EOF
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\ndata:\n  name: y\n' > "${c}/templates/cm.yaml"
  helm package -d "${b}/node/charts" "${c}" >/dev/null
  [ "$(bundle_profile_owner "${b}")" = owner@example.com ]
  TEAMSPACE=other
  [ "$(bundle_profile_owner "${b}")" = someone@example.com ]
  [ -z "$(bundle_profile_owner "${BATS_TEST_TMPDIR}/nothing")" ]
}

@test "e2e.sh E11: a dry run on a healthy stand-in passes; each broken part fails exactly its check" {
  local world="${BATS_TEST_DIRNAME}/fixtures/e2e-world.bash" b
  for b in "" gitops-plugins appproject-cluster-kinds plugin-fail no-sidecar image-missing dns claim catalog-member; do
    run bash -c "
      E2E_WORK='${BATS_TEST_TMPDIR}/w' E2E_CATALOG_POLL=0; source '${E2E}'; WORLD_BREAK='${b}'; source '${world}'
      mkdir -p \"\${HTTP_DIR}\"; set_admin Owner@Example.com; TL_POLL=0; CATALOG_TIMEOUT=1
      tl_case E11 dry-run; e11_checks; echo \"FAILED=\${TL_NFAIL} PASSED=\${TL_NPASS}\""
    [ "${status}" -eq 0 ]
    if [[ -z "${b}" ]]; then
      [[ "${output}" == *"FAILED=0 PASSED="* ]] || { echo "healthy: ${output}"; return 1; }
      refute_grep -n 'world: unexpected' <<<"${output}"
    else
      [[ "${output}" == *"FAILED=1 PASSED="* ]] || { echo "${b}: ${output}"; return 1; }
    fi
  done
}

@test "e2e.sh: pull_failures counts permanent pull causes and pull events of pods that are not Ready, not recovered transients" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local d="${BATS_TEST_TMPDIR}"
  cat > "${d}/events.json" <<'JSON'
{"items":[
 {"involvedObject":{"name":"ok-pod"},"reason":"BackOff","message":"Back-off pulling image \"x:latest\""},
 {"involvedObject":{"name":"ok-pod"},"reason":"Failed","message":"Failed to pull image \"x:latest\": Head https://h/v2/x: dial tcp 10.0.0.1:443: connect: connection refused"},
 {"involvedObject":{"name":"gone-pod"},"reason":"BackOff","message":"Back-off pulling image \"y:latest\""},
 {"involvedObject":{"name":"stuck-pod"},"reason":"BackOff","message":"Back-off pulling image \"z:latest\""},
 {"involvedObject":{"name":"ok-pod"},"reason":"Failed","message":"Failed to pull image \"w:1\": rpc error: manifest unknown"},
 {"involvedObject":{"name":"ok-pod"},"reason":"Pulled","message":"Successfully pulled image"}
]}
JSON
  cat > "${d}/pods.json" <<'JSON'
{"items":[
 {"metadata":{"name":"ok-pod"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},
 {"metadata":{"name":"stuck-pod"},"status":{"phase":"Pending","conditions":[{"type":"Ready","status":"False"}]}}
]}
JSON
  vm_kc() { if [[ "$2" == events ]]; then cat "${d}/events.json"; else cat "${d}/pods.json"; fi; }
  # the recovered transients (ok-pod refused/backoff, gone-pod) are not counted; the
  # permanent cause (manifest unknown) and the pod that is still not Ready are
  [ "$(pull_failures -A)" = 2 ]
  # only the recovered transients left: nothing counts
  printf '{"items":[{"involvedObject":{"name":"ok-pod"},"reason":"BackOff","message":"Back-off pulling image x"},{"involvedObject":{"name":"gone-pod"},"reason":"BackOff","message":"Back-off pulling image y"}]}' > "${d}/events.json"
  [ "$(pull_failures -A)" = 0 ]
}

@test "e2e.sh: the bundle's app-of-apps version decides E1's baseline and E4's rollback leg" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local d="${BATS_TEST_TMPDIR}"
  mkdir -p "${d}/m4" "${d}/m5" "${d}/p10/node/charts" "${d}/none" "${d}/both/node/charts"
  printf 'bundleId: x\nappOfAppsVersion: 0.0.4\n' > "${d}/m4/MANIFEST.yaml"
  printf "appOfAppsVersion: '0.0.5' # r5\n" > "${d}/m5/MANIFEST.yaml"
  printf 'argo 0.0.4\napp-of-apps 0.0.10\n' > "${d}/p10/node/charts/pins.txt"
  printf 'appOfAppsVersion: "0.0.4"\n' > "${d}/both/MANIFEST.yaml"
  printf 'app-of-apps 0.0.5\n' > "${d}/both/node/charts/pins.txt"
  [ "$(bundle_aoa "${d}/m4")" = 0.0.4 ]
  [ "$(bundle_aoa "${d}/m5")" = 0.0.5 ]
  [ "$(bundle_aoa "${d}/p10")" = 0.0.10 ]
  [ "$(bundle_aoa "${d}/both")" = 0.0.4 ]   # MANIFEST.yaml wins, as load_bundle_info on the node
  [ -z "$(bundle_aoa "${d}/none")" ]
  run bundle_is_r5 "${d}/m4"
  [ "${status}" -eq 1 ]
  bundle_is_r5 "${d}/m5"
  bundle_is_r5 "${d}/p10"    # sort -V: 0.0.10 is after 0.0.5
  bundle_is_r5 "${d}/none"   # no version: strict
  # E1: auto follows the version; 0 and 1 override it
  e1_baseline "${d}/m4"
  run e1_baseline "${d}/m5"
  [ "${status}" -eq 1 ]
  E2E_E1_BASELINE=0
  run e1_baseline "${d}/m4"
  [ "${status}" -eq 1 ]
  E2E_E1_BASELINE=1
  e1_baseline "${d}/m5"
  unset E2E_E1_BASELINE
  # E4 after the refused A: r5 B -> pre-r5 A crosses r5 (the leg must be run or waived)
  [ "$(e4_rollback_mode "${d}/m4" "${d}/m5")" = gap ]
  [ "$(E2E_E4_ROLLBACK=1 e4_rollback_mode "${d}/m4" "${d}/m5")" = cross ]
  [ "$(E2E_E4_ROLLBACK=0 e4_rollback_mode "${d}/m4" "${d}/m5")" = off ]
  [ "$(e4_rollback_mode "${d}/m5" "${d}/p10")" = run ]
  [ "$(E2E_E4_ROLLBACK=1 e4_rollback_mode "${d}/m5" "${d}/p10")" = run ]
  [ "$(e4_rollback_mode "${d}/m4" "${d}/both")" = run ]   # both pre-r5
  R5_AOA=0.0.6
  run bundle_is_r5 "${d}/m5"
  [ "${status}" -eq 1 ]
  # a bad switch stops e2e.sh before it checks tools or touches anything
  # (E2E_WORK, LAN_HOME and VM_DIR point into the test dir all the same)
  local env=(E2E_WORK="${d}/w" LAN_HOME="${d}/lan" VM_DIR="${d}/vm")
  run env "${env[@]}" E2E_E4_ROLLBACK=yes "${E2E}" E4
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"E2E_E4_ROLLBACK must be auto, 0 or 1"* ]]
  run env "${env[@]}" E2E_E1_BASELINE=maybe "${E2E}" E1
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"E2E_E1_BASELINE must be auto, 0 or 1"* ]]
  [ ! -e "${d}/w" ] && [ ! -e "${d}/lan" ]
}

@test "e2e.sh E1: a pre-r5 bundle is a baseline (the r5-only checks warn); an r5 bundle on that platform fails them" {
  local fx="${BATS_TEST_DIRNAME}/fixtures/e2e-release.bash" c aoa rel base w
  for c in "0.0.4 r4 auto" "0.0.5 r4 auto" "0.0.4 r4 0" "0.0.5 r4 1" "0.0.5 r5 auto" "0.0.4 r5 auto"; do
    read -r aoa rel base <<<"${c}"
    w="${BATS_TEST_TMPDIR}/w-${aoa}-${rel}-${base}"
    run bash -c "
      W='${w}' E2E_WORK='${w}/work' LAN_HOME='${w}/lan' E2E_E1_BASELINE='${base}'
      source '${E2E}'; RELEASE='${rel}'; source '${fx}'
      make_bundle \"\${W}/A\" '${aoa}'; E2E_BUNDLE=\"\${W}/A\"
      e1; echo \"FAILED=\${TL_NFAIL} R5_SOFT=[\${R5_SOFT}]\"; cat \"\${W}/calls\""
    [ "${status}" -eq 0 ]
    refute_grep -n 'release: unexpected' <<<"${output}"
    [[ "${output}" == *"R5_SOFT=[]"* ]] || { echo "${c}: R5_SOFT not reset: ${output}"; return 1; }
    case "${c}" in
      "0.0.4 r4 auto"|"0.0.5 r4 1")
        # A's known gaps are reported as warnings, nothing fails
        [[ "${output}" == *"FAILED=0 "* ]] || { echo "${c}: ${output}"; return 1; }
        local m
        for m in "still carries status.set_initial_password" "the login may meet the Update Profile form" \
                 "Backstage signs" "admin-user restarted no backstage-api pod" \
                 "every platform Application's last operation Succeeded" "every monitoring admission webhook has a caBundle"; do
          grep -q "WARN:.*not asserted: .*${m}" <<<"${output}" || { echo "${c}: no warning for '${m}': ${output}"; return 1; }
        done
        # the baseline login answers the Update Profile form instead of failing on it
        grep -q "^lan ${REPO_ROOT}/airgap/test/vm/kc-login.sh " <<<"${output}"
        refute_grep -n -- '--forbid-profile-form' <<<"${output}" ;;
      "0.0.5 r4 auto"|"0.0.4 r4 0")
        # the same platform under an r5 bundle (or forced strict): each gap fails
        [[ "${output}" == *"FAILED=6 "* ]] || { echo "${c}: ${output}"; return 1; }
        for m in "User e2e-admin-at-example.com still carries status.set_initial_password" \
                 "oauth2-proxy login as e2e-admin@example.com" "Backstage identity not checked: no session" \
                 "admin-user restarted no backstage-api pod" "every platform Application's last operation Succeeded" \
                 "every monitoring admission webhook has a caBundle"; do
          grep -q "FAIL ${m}" <<<"${output}" || { echo "${c}: no FAIL for '${m}': ${output}"; return 1; }
        done
        refute_grep -n 'not asserted' <<<"${output}"
        grep -q -- "--forbid-profile-form" <<<"${output}" ;;
      *)
        # an r5 platform passes under either bundle
        [[ "${output}" == *"FAILED=0 "* ]] || { echo "${c}: ${output}"; return 1; }
        grep -q "ok   Backstage signs owner@example.com in as user:default/owner-at-example.com" <<<"${output}" ;;
    esac
  done
}

@test "e2e.sh E4: E2E_E4_APPS=auto from the pins; an unrehearsed r5 -> pre-r5 rollback fails unless waived; E2E_E4_ROLLBACK=1 asserts it part by part" {
  local fx="${BATS_TEST_DIRNAME}/fixtures/e2e-release.bash" c rb mode w
  for c in "auto gap" "0 gap" "1 gap" "1 fixed"; do
    read -r rb mode <<<"${c}"
    w="${BATS_TEST_TMPDIR}/w-${rb}-${mode}"
    run bash -c "
      W='${w}' E2E_WORK='${w}/work' LAN_HOME='${w}/lan' E2E_E4_ROLLBACK='${rb}' E2E_E4_APPS=auto
      source '${E2E}'; RELEASE=r5 ROLLBACK='${mode}'; source '${fx}'
      make_bundle \"\${W}/A\" 0.0.4 argo 0.0.3 auth 0.0.8 istio 0.0.3 profile-controller 0.0.83 user-controller 0.0.84
      make_bundle \"\${W}/B\" 0.0.5 argo 0.0.4 auth 0.0.9 istio 0.0.3 profile-controller 0.0.84 user-controller 0.0.85 profile-plugin-emqx 0.0.99
      printf 'app-of-apps 0.0.4 0.0.4\nauth 0.0.8 0.0.8\nistio 0.0.3 0.0.3\nprofile-controller 0.0.83 0.0.83\nuser-controller 0.0.84 0.0.84\n' > \"\${W}/revs.A\"
      { sed -e 's/^app-of-apps .*/app-of-apps 0.0.5 0.0.5/' -e 's/^auth .*/auth 0.0.9 0.0.9/' \
            -e 's/^profile-controller .*/profile-controller 0.0.84 0.0.84/' -e 's/^user-controller .*/user-controller 0.0.85 0.0.85/' \"\${W}/revs.A\"
        for p in \"\${PLUGINS[@]}\"; do echo \"teknoir-default-\${p} 0.0.99 0.0.99\"; done; } > \"\${W}/revs.B\"
      cp \"\${W}/revs.A\" \"\${W}/revs\"; echo 'A install' > \"\${W}/record\"; touch \"\${W}/legacy\"
      E2E_BUNDLE=\"\${W}/A\" E2E_BUNDLE_B=\"\${W}/B\"
      e4; echo \"FAILED=\${TL_NFAIL} DESC=[\${TL_CASE_DESC}]\"; cat \"\${W}/calls\""
    [ "${status}" -eq 0 ]
    refute_grep -n 'release: unexpected' <<<"${output}"
    # B: exactly the bumped Applications (argo has none, istio kept its pin) and B's teamspace
    grep -q "ok   the Applications bundle B changed are exactly E2E_E4_APPS" <<<"${output}" || { echo "${c}: ${output}"; return 1; }
    grep -q "B should change app-of-apps auth profile-controller teknoir-default-deadend .*teknoir-default-observatory .*user-controller" <<<"${output}"
    grep -q "ok   after B: User e2e-admin-at-example.com carries no status.set_initial_password" <<<"${output}"
    grep -q "ok   up with the older bundle A is refused" <<<"${output}"
    case "${c}" in
      "auto gap")
        # not green: the rollback leg is neither run nor waived
        [[ "${output}" == *"FAILED=1 DESC=[update to bundle B, refusal of A, rollback to A]"* ]] || { echo "${c}: ${output}"; return 1; }
        grep -q "FAIL the rollback from the r5 B to the pre-r5 A is not rehearsed: set E2E_E4_ROLLBACK=1 .* or E2E_E4_ROLLBACK=0 to waive it on purpose" <<<"${output}"
        grep -q "WARN:.*the rollback to A would cross r5: .*IgnoreExtraneous" <<<"${output}"
        refute_grep -n -- '--rollback$' <<<"${output}" ;;
      "0 gap")
        # a waiver on purpose: green, and the summary row says so
        [[ "${output}" == *"FAILED=0 DESC=[update to bundle B, refusal of A, rollback to A (rollback leg waived: E2E_E4_ROLLBACK=0)]"* ]] \
          || { echo "${c}: ${output}"; return 1; }
        grep -q "WARN:.*E2E_E4_ROLLBACK=0: the rollback to A is waived" <<<"${output}"
        refute_grep -n -- '--rollback$' <<<"${output}" ;;
      "1 gap")
        # today's design: each open part fails by name, nothing stops at the first
        [[ "${output}" == *"FAILED=5 "* ]] || { echo "${c}: ${output}"; return 1; }
        local m
        for m in "up --rollback with the pre-r5 A failed" "after the rollback, not Synced/Healthy: profile-controller=OutOfSync/Healthy" \
                 "profile-controller is Synced/Healthy after the rollback" "user-controller is Synced/Healthy after the rollback" \
                 "the release record is bundle A, mode rollback"; do
          grep -q "FAIL ${m}" <<<"${output}" || { echo "${c}: no FAIL for '${m}': ${output}"; return 1; }
        done
        grep -q "ok   Profile teknoir-default is kept" <<<"${output}"
        grep -q "ok   Namespace teknoir-user-credentials is kept" <<<"${output}"
        grep -q "ok   every Application is back at its revision before B" <<<"${output}"
        grep -q "the teknoir-default Applications after the rollback: teknoir-default-emqx=Unknown/Healthy@https://teknoir.github.io" <<<"${output}" ;;
      "1 fixed")
        # once the rollback design is settled, the same run passes
        [[ "${output}" == *"FAILED=0 "* ]] || { echo "${c}: ${output}"; return 1; }
        grep -q -- "--rollback$" <<<"${output}"
        grep -q "ok   a plain up with A keeps A in rollback mode" <<<"${output}" ;;
    esac
  done
}

@test "e2e.sh: the cluster reads of E1, E2, E4 and E15 select what they should (fixture JSON)" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  vm_kc() {
    case "$*" in
      "-n teknoir-system get applications.argoproj.io -o json") cat <<'EOF'
{"items": [
 {"metadata": {"name": "app-of-apps"}, "status": {"operationState": {"phase": "Succeeded"}}},
 {"metadata": {"name": "monitoring", "annotations": {"argocd.argoproj.io/tracking-id": "app-of-apps:argoproj.io/Application:teknoir-system/monitoring"}},
  "status": {"operationState": {"phase": "Failed", "finishedAt": "2026-10-09T04:00:00Z"}}},
 {"metadata": {"name": "auth", "annotations": {"argocd.argoproj.io/tracking-id": "app-of-apps:argoproj.io/Application:teknoir-system/auth"}}, "status": {}},
 {"metadata": {"name": "teknoir-default-emqx"}, "spec": {"source": {"repoURL": "harbor.teknoir.airgapped/teknoir"}},
  "status": {"operationState": {"phase": "Running", "finishedAt": "2026-10-09T05:00:00Z"}}},
 {"metadata": {"name": "teknoir-demo-emqx"}, "spec": {"source": {"repoURL": "https://teknoir.github.io/profile-plugins-helm"}}},
 {"metadata": {"name": "teknoir-demo-jwks"}, "spec": {"source": {"repoURL": "harbor.teknoir.airgapped/teknoir"}}}]}
EOF
        ;;
      "get validatingwebhookconfigurations -o json")
        echo '{"items": [{"metadata": {"name": "monitoring-admission"}, "webhooks": [{"name": "prometheusrulemutate.monitoring.coreos.com", "clientConfig": {"caBundle": "LS0t"}}]},
                         {"metadata": {"name": "istio-validator"}, "webhooks": [{"name": "x", "clientConfig": {}}]}]}' ;;
      "get mutatingwebhookconfigurations -o json")
        echo '{"items": [{"metadata": {"name": "monitoring-admission"}, "webhooks": [{"name": "a.monitoring.coreos.com", "clientConfig": {"caBundle": ""}}]}]}' ;;
      "get pods -A -o json") cat <<'EOF'
{"items": [
 {"metadata": {"namespace": "teknoir-auth", "name": "keycloak-0"}, "status": {"phase": "Running",
   "containerStatuses": [{"name": "keycloak", "imageID": "ghcr.io/teknoir/keycloak-theme@sha256:ab39"}],
   "initContainerStatuses": [{"name": "admin-check", "imageID": "docker.io/alpine/k8s@sha256:ffff"}]},
  "spec": {"containers": [{"name": "keycloak", "image": "ghcr.io/teknoir/keycloak-theme:sha-29d2ed6a@sha256:ab39"}],
           "initContainers": [{"name": "admin-check", "image": "docker.io/alpine/k8s:1.34.11"}]}},
 {"metadata": {"namespace": "teknoir-auth", "name": "keycloak-db-0"}, "status": {"phase": "Running",
   "containerStatuses": [{"name": "postgres", "imageID": "docker.io/library/postgres@sha256:index0"}]},
  "spec": {"containers": [{"name": "postgres", "image": "docker.io/library/postgres:16.15@sha256:75ad"}]}},
 {"metadata": {"namespace": "x", "name": "pending"}, "status": {"phase": "Pending"},
  "spec": {"containers": [{"name": "c", "image": "y@sha256:1"}]}}]}
EOF
        ;;
      "-n teknoir-system get deployment backstage-api -o json") echo '{"spec": {"selector": {"matchLabels": {"app": "backstage-api"}}}}' ;;
      "-n teknoir-system get pods -l app=backstage-api -o json")
        echo '{"items": [{"metadata": {"uid": "u1"}, "status": {"containerStatuses": [{"restartCount": 0}, {"restartCount": 2}]}},
                         {"metadata": {"uid": "u0", "deletionTimestamp": "x"}, "status": {}}]}' ;;
      "-n teknoir-system get deployment nothing -o json") return 1 ;;
      "-n teknoir-auth get deployments -o json")
        echo '{"items": [{"spec": {"template": {"spec": {"containers": [{"args": ["--provider=keycloak-oidc", "--cookie-name=_teknoir_oauth2_proxy"]}]}}}}]}' ;;
      "-n teknoir-system get applications.argoproj.io --no-headers -o custom-columns="*)
        printf 'app-of-apps Synced Healthy 0.0.5 x\nteknoir-demo-emqx Unknown Unknown 0.0.99 y\nauth OutOfSync Healthy 0.0.9 z\n' ;;
      *) echo "unexpected: $*" >&2; return 1 ;;
    esac
  }
  [ "$(platform_ops_not_succeeded)" = "auth=none monitoring=Failed " ]
  [ "$(admission_ca)" = "2 monitoring-admission/a.monitoring.coreos.com" ]
  [ "$(digest_mismatches)" = "teknoir-auth/keycloak-db-0:postgres imageID=docker.io/library/postgres@sha256:index0 " ]
  [ "$(pod_states teknoir-system backstage-api)" = "u1 2" ]
  [ "$(pod_states teknoir-system nothing)" = absent ]
  [ "$(oauth2_cookie)" = _teknoir_oauth2_proxy ]
  [ "$(apps_unhealthy_except teknoir-demo-)" = "auth=OutOfSync/Healthy " ]
  [ "$(TEAMSPACE=teknoir-default teamspace_ops)" = "teknoir-default-emqx 2026-10-09T05:00:00Z" ]
  [ "$(demo_repos)" = "harbor.teknoir.airgapped/teknoir https://teknoir.github.io/profile-plugins-helm" ]
}

@test "e2e.sh E12: a dry run (stub node) passes; a refused 400 s up without the hint fails" {
  local b="${BATS_TEST_TMPDIR}/bundle" mode
  mkdir -p "${b}/node/debs"
  printf 'chrony 4.6.1-3+deb13u2 amd64 3b3f chrony_4.6.1-3+deb13u2_amd64.deb\nutil-linux-extra 2.41.5-0+deb13u1 amd64 b5d0 util-linux-extra_2.41.5-0+deb13u1_amd64.deb\n' > "${b}/node/debs/debs.lock"
  for mode in good nohint; do
    run bash -c "
      E2E_WORK='${BATS_TEST_TMPDIR}/w-${mode}' E2E_BUNDLE=x; source '${E2E}'; TL_POLL=0; MODE='${mode}'; W='${BATS_TEST_TMPDIR}/w-${mode}'
      mkdir -p \"\${W}\"; echo 1 > \"\${W}/boot\"; : > \"\${W}/ups\"
      bundle_dir() { echo '${b}'; }
      ensure_vm() { :; }; wait_apps() { pass 'apps'; }
      VM=\"\${W}/vm.sh\"; printf '#!/bin/sh\nexit 0\n' > \"\${VM}\"; chmod +x \"\${VM}\"
      vmx() {
        case \"\$*\" in
          'dpkg-query -W -f \${Package} \${Version}\n chrony util-linux-extra') printf 'util-linux-extra 2.41.5-0+deb13u1\nchrony 4.6.1-3+deb13u2\n' ;;
          'dpkg-query -W -f \${db:Status-Abbrev} systemd-timesyncd') printf 'rc ' ;;
          'systemctl is-active chrony') echo active ;;
          'sudo sh -c command -v hwclock') echo /usr/sbin/hwclock ;;
          'sudo sh -c '*dpkg.log*) echo 'abcd 10' ;;
          'date +%s.%N') date +%s.%N ;;
          'cat /proc/sys/kernel/random/boot_id') cat \"\${W}/boot\" ;;
          'sudo systemctl reboot') echo 2 > \"\${W}/boot\" ;;
          'sudo date -u -s '*|'sudo hwclock --systohc --utc') : ;;
          *) echo \"unexpected vmx \$*\" >&2; return 1 ;;
        esac
      }
      vm_kc() { [ \"\$*\" = 'get --raw /readyz' ]; }
      vm_root() { cat >/dev/null; echo 1; }
      up_in() {
        echo \"\$*\" >> \"\${W}/ups\"
        case \"\$*\" in
          *--sync-clock*) return 0 ;;
          *) if [ \"\$(grep -c . \"\${W}/ups\")\" -eq 2 ]; then
               if [ \"\${MODE}\" = good ]; then echo 'clock skew 400 s: run up --sync-clock'; else echo 'clock skew 400 s'; fi
               return 1
             fi ;;
        esac
      }
      lan() { echo 'stratum=10 offset=0.012 delay=0.001 refid=127.127.1.1 leap=0'; }
      tk() { printf 'This computer:\n  \033[31mFAIL\033[0m  the OS does not trust the platform CA yet\nNode teknoir@10.77.0.10:\n  ok    clock skew 0 s\n'; }
      tl_case E12 dry-run; e12; echo \"FAILED=\${TL_NFAIL} PASSED=\${TL_NPASS}\""
    [ "${status}" -eq 0 ]
    if [[ "${mode}" == good ]]; then
      [[ "${output}" == *"FAILED=0 PASSED="* ]] || { echo "${output}"; return 1; }
      [[ "${output}" == *"doctor FAIL lines for the LAN netns (not asserted)"* ]]
    else
      [[ "${output}" == *"FAILED=1 PASSED="* && "${output}" == *"want 1 with the --sync-clock hint"* ]] || { echo "${output}"; return 1; }
    fi
  done
}

@test "e2e.sh E13: the LAN backup check decrypts with each identity and verifies SHA256SUMS (stub age)" {
  run bash -c "
    W='${BATS_TEST_TMPDIR}/w'; E2E_WORK=\"\${W}\" LAN_HOME=\"\${W}/lan\"; source '${E2E}'
    mkdir -p \"\${HTTP_DIR}\" \"\${LAN_HOME}/e2e\" \"\${W}/ids\"; : > \"\${W}/ids/a.key\"; : > \"\${W}/ids/b.key\"
    VM=\"\${W}/vm.sh\"
    printf '#!/bin/sh\necho age1aaa %s/ids/a.key\necho age1bbb %s/ids/b.key\n' \"\${W}\" \"\${W}\" > \"\${VM}\"; chmod +x \"\${VM}\"
    # stub age: -d -i ID FILE prints FILE (the stand-in backup is a plain tar)
    printf '#!/bin/sh\nexec cat \"\$4\"\n' > \"\${W}/age\"; chmod +x \"\${W}/age\"; E2E_AGE=\"\${W}/age\"
    tk() {
      local out=\"\$4\" s=\"\${W}/set/20261009T120000Z\"
      mkdir -p \"\${s}/db\" \"\${out}\"; echo info > \"\${s}/BACKUP.info\"; echo dump > \"\${s}/db/keycloak.sql.gz\"
      ( cd \"\${s}\" && sha256sum BACKUP.info db/keycloak.sql.gz > SHA256SUMS )
      [ \"\${BREAK:-}\" != sums ] || echo tampered >> \"\${s}/BACKUP.info\"
      ( umask 077; tar -C \"\${W}/set\" -cf \"\${out}/teknoir-backup-vmtest-20261009T120000Z.tar.age\" 20261009T120000Z )
    }
    vmx() { echo /var/lib/teknoir-airgap/backups/20261009T120000Z; }
    tl_case E13 backup; e13_backup /nonexistent-bundle; echo \"FAILED=\${TL_NFAIL} PASSED=\${TL_NPASS}\"
    BREAK=sums; tl_case E13b broken; e13_backup /nonexistent-bundle; echo \"FAILED=\${TL_NFAIL}\""
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"a.key decrypts the backup"*"b.key decrypts the backup"*"sha256sum -c of the decrypted backup passes"* ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"FAILED=0 PASSED=7"* ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"sha256sum -c of the decrypted backup fails"*"FAILED=1" ]] || { echo "${output}"; return 1; }
}

live_world() {
  # live_world <mode> <row>... — dry runs of fixtures/e2e-live-world.bash
  # (world_dry_run <mode>), one per row "<break>|<failures>|<fragment>[;...]":
  # the run with that WORLD_BREAK ("" = healthy) has exactly <failures> failed
  # assertions, a FAIL line for each fragment, and no unexpected call
  local mode="$1" row b n frags f out
  local -a breaks=() fl=()
  shift
  for row in "$@"; do breaks+=("'${row%%|*}'"); done
  run bash -c "
    W='${BATS_TEST_TMPDIR}/w' E2E_WORK='${BATS_TEST_TMPDIR}/w/work' LAN_HOME='${BATS_TEST_TMPDIR}/w/lan' VM_DIR='${BATS_TEST_TMPDIR}/w/vm'
    source '${E2E}'; source '${BATS_TEST_DIRNAME}/fixtures/e2e-live-world.bash'
    world_dry_run ${mode} ${breaks[*]}"
  [ "${status}" -eq 0 ] || { echo "${output}"; return 1; }
  for row in "$@"; do
    IFS='|' read -r b n frags <<<"${row}"
    out="${BATS_TEST_TMPDIR}/w/out.${b:-none}"
    if ! grep -q "^${b:-none} FAILED=${n} " <<<"${output}"; then
      echo "${b:-healthy}: want ${n} failed: $(grep "^${b:-none} FAILED=" <<<"${output}")"; grep -h 'FAIL' "${out}"; return 1
    fi
    if grep -q '^world: ' "${out}"; then echo "${b:-healthy}:"; grep '^world: ' "${out}"; return 1; fi
    IFS=';' read -r -a fl <<<"${frags}"
    for f in ${fl[@]+"${fl[@]}"}; do
      grep -qF -- "FAIL ${f}" "${out}" || { echo "${b:-healthy}: no 'FAIL ${f}'"; cat "${out}"; return 1; }
    done
  done
}

@test "e2e.sh E13: a dry run on the live world passes; each broken part fails exactly its check" {
  live_world e13 \
    "|0|" \
    "nonadmin-k1-kept|1|Secret teknoir-user-credentials/user-initial-password-e2e-viewer-at-example.com still exists 300 s after" \
    "nonadmin-grafana|1|non-admin: https://teknoir.airgapped/teknoir-system/grafana/: HTTP 200" \
    "admin-alertmanager|1|admin: https://teknoir.airgapped/teknoir-system/alertmanager/: HTTP 403" \
    "grafana-anonymous|1|Grafana /api/user: the admin is known by e-mail" \
    "grafana-viewer|1|Grafana org roles of the admin: HTTP 200 [Viewer]" \
    "argocd-nonadmin-apps|1|non-admin: ArgoCD /api/v1/applications lists no Application: want [200 0] got [200 2]" \
    "argocd-admin-empty|1|admin: ArgoCD Applications: 200 0" \
    "harbor-user|1|non-admin: Harbor knows the OIDC user" \
    "harbor-csrf|1|non-admin: Harbor POST /api/v2.0/projects: HTTP 403 [CSRF token invalid]" \
    "harbor-create|1|non-admin: Harbor POST /api/v2.0/projects: HTTP 201" \
    "pa-enabled|1|Keycloak user platform-admin (realm teknoir) is disabled" \
    "pa-login|1|a platform-admin sign-in was not refused as disabled" \
    "uc-star|1|auth can-i * * as user-controller" \
    "pc-exec|1|auth can-i create pods --subresource=exec -n teknoir-default as profile-controller" \
    "uc-forbidden|1|no 'forbidden' in the user-controller log" \
    "prev-kept|1|Secret keycloak-admin has no previous-password" \
    "backup-tampered|1|sha256sum -c of the decrypted backup fails" \
    "backup-plaintext|1|one plaintext backup set is left on the node" \
    "argocd-rotate|1|rotate argocd-admin failed" \
    "argocd-initial-kept|1|argocd-initial-admin-secret is gone after the rotation" \
    "argocd-old-accepted|1|the old ArgoCD admin password is refused" \
    "argocd-creds-mode|1|credentials argocd-admin --out writes a 0600 file" \
    "argocd-new-refused|1|the rotated ArgoCD admin password signs in" \
    "argocd-sso-no-sync|1|the SSO admin may still sync app-of-apps" \
    "kcdb-rotate|1|rotate keycloak-db --i-know failed" \
    "kcdb-apps|1|Applications not Synced/Healthy after rotate keycloak-db: auth=OutOfSync/Healthy" \
    "kcdb-login|1|the admin signs in after rotate keycloak-db" \
    "alert-errors|1|Prometheus logged no 'Error sending alerts'"
  local w="${BATS_TEST_TMPDIR}/w"
  # the healthy run: every assertion of E13 ran, the K1 cleanup was started by
  # a reconcile poke on the non-admin, and nothing touched the node but reads,
  # that poke and the rotations
  grep -qx 'none FAILED=0 PASSED=51' <<<"${output}"
  grep -qx 'vm_kc annotate users.teknoir.org e2e-viewer-at-example.com e2e.teknoir.org/poke=[0-9]* --overwrite' "${w}/calls.none"
  grep -q 'ok   the non-admin.s temporary-password Secret .* is deleted once the user set their own password' "${w}/out.none"
  refute_grep -E '^vm_kc (-n [^ ]+ )?(apply|delete|patch|replace|label)( |$)' "${w}/calls.none"
  [ "$(grep -c '^vm_root ' "${w}/calls.none")" -eq 3 ]   # platform-admin state, the old ArgoCD password, the session check
}

@test "e2e.sh E15: e15_inject on the live world injects the live state; each refused part fails exactly its check" {
  live_world inject \
    "|0|" \
    "demo-create|2|cannot create Profile teknoir-demo;only 0 teknoir-demo Applications after 600 s" \
    "demo-apps|1|only 0 teknoir-demo Applications after 600 s" \
    "monitoring-patch|1|cannot inject the Failed monitoring operation" \
    "webhook-patch|1|could not empty the admission caBundles (patch refused: validatingwebhookconfiguration/monitoring-kube-prometheus-admission mutatingwebhookconfiguration/monitoring-kube-prometheus-admission" \
    "master-seed|1|realm master gets the legacy clients teknoir, argocd and harbor, as the live node has them: want [teknoir=201 argocd=201 harbor=201] got [teknoir=201 argocd=201 harbor=409]" \
    "master-grant|1|the teknoir client's service account holds master-realm manage-users, query-users and view-users: want [204 3] got [403 3]" \
    "master-sa|1|the severity: teknoir's client_credentials token (the oauth2-proxy secret) lists realm master's users: want [200] got [403]"
  local w="${BATS_TEST_TMPDIR}/w"
  grep -qx 'none FAILED=0 PASSED=7' <<<"${output}"
  # the world accepts only the live shapes: the Failed operation of the current
  # revision (merge patch) and an empty caBundle per webhook (JSON patch), the
  # Profile owned by the admin; the master clients through the admin API script
  grep -q '^vm_kc -n teknoir-system patch applications.argoproj.io monitoring --type=merge -p ' "${w}/calls.none"
  [ "$(grep -c '^vm_kc patch [a-z]*webhookconfiguration.admissionregistration.k8s.io/monitoring-kube-prometheus-admission --type=json' "${w}/calls.none")" -eq 2 ]
  refute_grep 'istio-validator' "${w}/calls.none"
  grep -qx 'vm_root e15_master_clients' "${w}/calls.none"
}

@test "e2e.sh E15: the whole rehearsal on the live world, in order; every before/after check fails on its own break" {
  live_world e15 \
    "|0|" \
    "master-lie|1|before B: realm master has the 3 legacy clients, and teknoir's secret gets a token there (client_credentials): want [3 200] got [0 401]" \
    "a-no-legacy|1|before B: User owner-at-example.com carries no legacy status.set_initial_password" \
    "a-no-prev|1|before B: Secret keycloak-admin still has previous-password" \
    "a-required-action|1|before B: Keycloak user owner@example.com is enabled with no required action" \
    "a-no-created|1|cannot read the password credential's created_date" \
    "b-up|1|up with bundle B failed" \
    "b-apps-unhealthy|1|Applications not Synced/Healthy: auth=OutOfSync/Healthy" \
    "b-no-image-line|1|post did not report 'live image check: N pullable ..., 0 missing'" \
    "b-monitoring-failed|2|every platform Application's last operation Succeeded: want [] got [monitoring=Failed ];monitoring's operation Succeeded: want [Succeeded] got [Failed]" \
    "b-cabundle-empty|1|every monitoring admission webhook has a caBundle" \
    "b-digest|1|every digest-pinned container runs that digest (imageID)" \
    "b-demo-github|1|every teknoir-demo Application points at Harbor" \
    "b-legacy-kept|1|User owner-at-example.com still carries status.set_initial_password" \
    "b-k1-created|1|no temporary-password Secret for owner-at-example.com" \
    "b-pw-changed|1|the admin's Keycloak password was not changed (credential created_date): want [1760000000000] got [1760000099000]" \
    "b-required-action|1|Keycloak user owner@example.com still has no required action" \
    "b-prev-kept|1|post removed previous-password from Secret keycloak-admin" \
    "b-master-kept|1|master-realm legacy clients after B: 3 200 (want 0 clients, HTTP 401)" \
    "b-rerun-fails|3|admin-user (B) re-run failed;User owner-at-example.com lacks owner@teknoir-default;User owner-at-example.com lacks owner@teknoir-demo" \
    "b-rerun-writes|1|admin-user (B) wrote" \
    "b-no-demo-claim|1|User owner-at-example.com lacks owner@teknoir-demo: [owner@teknoir-default ]" \
    "b-login|1|the admin still signs in with the password set on A"
  local w="${BATS_TEST_TMPDIR}/w" want
  grep -qx 'none FAILED=0 PASSED=41' <<<"${output}"
  # the order: the live history on A, the injected state and the before
  # checks, B, the after checks, then E11, E13 (with B) and E14
  want="old-setup
tk A migrate
tk A up --force-images
tk A admin-user --email owner@example.com --out ${BATS_TEST_TMPDIR}/w/lan/e2e/admin.pw
kc-login owner@example.com
tk A migrate --argo
tk A migrate
vm_kc create -f -
vm_root e15_master_clients
vm_root kc_user_state
vm_root kc_pw_created
vm_root kc_master_clients
tk B up
vm_root kc_pw_created
vm_root kc_user_state
vm_root kc_master_clients
tk B admin-user --email owner@example.com --out ${BATS_TEST_TMPDIR}/w/lan/e2e/admin-rerun.pw
kc-login owner@example.com
e11_checks
e13_checks B
e14_checks"
  [ "$(grep -E '^(old-setup|tk |kc-login |vm_root |vm_kc create |e1[134]_checks)' "${w}/calls.none")" = "${want}" ] \
    || { diff <(echo "${want}") <(grep -E '^(old-setup|tk |kc-login |vm_root |vm_kc create |e1[134]_checks)' "${w}/calls.none"); return 1; }
  # a failed up with B stops before any check of B's state
  refute_grep -E '^(e1[134]_checks|tk B admin-user)' "${w}/calls.b-up"
}

@test "e2e.sh E2: Secret resourceVersions may lose only user-controller's K1 deletions in the credentials namespace" {
  # shellcheck source=../vm/e2e.sh
  source "${E2E}"
  local before after
  before="$(printf '%s\n' 'teknoir-auth keycloak-admin 10' 'teknoir-user-credentials user-initial-password-a 11' \
            'teknoir-user-credentials user-initial-password-b 12' 'teknoir-default emqx 13')"
  # user-controller deleted a's Secret: allowed
  after="$(printf '%s\n' 'teknoir-auth keycloak-admin 10' 'teknoir-user-credentials user-initial-password-b 12' 'teknoir-default emqx 13')"
  [ "$(drop_cred_deletions "${before}" "${after}")" = "${after}" ]
  # a deletion elsewhere, a changed K1 Secret or a new one still differ
  after="$(printf '%s\n' 'teknoir-auth keycloak-admin 10' 'teknoir-user-credentials user-initial-password-a 11' 'teknoir-user-credentials user-initial-password-b 12')"
  [ "$(drop_cred_deletions "${before}" "${after}")" = "${before}" ]
  after="$(printf '%s\n' 'teknoir-auth keycloak-admin 10' 'teknoir-user-credentials user-initial-password-a 99' \
           'teknoir-user-credentials user-initial-password-b 12' 'teknoir-default emqx 13')"
  [ "$(drop_cred_deletions "${before}" "${after}")" = "${before}" ]
  after="$(printf '%s\n' "${before}" 'teknoir-user-credentials user-initial-password-c 14')"
  [ "$(drop_cred_deletions "${before}" "${after}")" != "${after}" ]
  # no Secret in that namespace at all, before or after
  [ "$(drop_cred_deletions 'a b 1' 'a b 1')" = 'a b 1' ]
  [ -z "$(drop_cred_deletions 'teknoir-user-credentials x 1' '')" ]
}

@test "sntp-query.py: stratum and offset from an NTP server; no answer is exit 1" {
  local srv="${BATS_TEST_TMPDIR}/ntp.py" port pid
  cat > "${srv}" <<'EOF'
import socket, struct, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0))
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    data, addr = s.recvfrom(512)
    now = time.time() - 1.5
    sec, frac = int(now) + 2208988800, int((now - int(now)) * 2**32)
    req = struct.unpack("!B B b b I I 4s 8I", data[:48])
    s.sendto(struct.pack("!B B b b I I 4s 8I", 0x24, 10, 0, -20, 0, 0, b"\x7f\x7f\x01\x01",
                         sec, frac, req[13], req[14], sec, frac, sec, frac), addr)
EOF
  python3 -I "${srv}" "${BATS_TEST_TMPDIR}/port" & pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${BATS_TEST_TMPDIR}/port" ] && break; sleep 0.2; done
  port="$(cat "${BATS_TEST_TMPDIR}/port")"
  run python3 -I "${REPO_ROOT}/airgap/test/vm/sntp-query.py" 127.0.0.1 --port "${port}"
  kill "${pid}"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ ^stratum=10\ offset=-1\.[45][0-9]{2}\ delay=[0-9.]+\ refid=127\.127\.1\.1\ leap=0$ ]]
  run python3 -I "${REPO_ROOT}/airgap/test/vm/sntp-query.py" 127.0.0.1 --port "${port}" --timeout 0.3 --tries 1
  [ "${status}" -eq 1 ]
}

@test "vm.sh age-key: two 0600 test identities in VM_DIR/age, made once; --check compares the site's recipients" {
  local bin="${BATS_TEST_TMPDIR}/bin" vmdir="${BATS_TEST_TMPDIR}/vm" a b
  mkdir -p "${bin}"
  # a stand-in age-keygen: -o FILE writes a key whose recipient is derived from a counter; -y FILE prints it
  cat > "${bin}/age-keygen" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -o) n=$(( $(cat "${STUB_COUNTER}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB_COUNTER}"
      printf '# public key: age1%058d\nAGE-SECRET-KEY-1STUB%d\n' "${n}" "${n}" > "$2" ;;
  -y) sed -n 's/^# public key: //p' "$2" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "${bin}/age-keygen"
  export STUB_COUNTER="${BATS_TEST_TMPDIR}/counter"
  VM_DIR="${vmdir}" AGE_KEYGEN="${bin}/age-keygen" run --separate-stderr "${VM}" age-key
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  # shellcheck disable=SC2154  # set by run --separate-stderr
  [[ "${stderr}" == *"created test age identity ${vmdir}/age/vmtest.key"* ]]
  [[ "${lines[0]}" == "age1$(printf '%058d' 1) ${vmdir}/age/vmtest.key" ]]
  [[ "${lines[1]}" == "age1$(printf '%058d' 2) ${vmdir}/age/vmtest-recovery.key" ]]
  [ "$(stat -c %a "${vmdir}/age")" = 700 ]
  [ "$(stat -c %a "${vmdir}/age/vmtest.key")" = 600 ]
  [ "$(stat -c %a "${vmdir}/age/vmtest-recovery.key")" = 600 ]
  # a second run makes no new key
  VM_DIR="${vmdir}" AGE_KEYGEN="${bin}/age-keygen" run "${VM}" age-key
  [ "${status}" -eq 0 ]
  [ "$(cat "${STUB_COUNTER}")" = 2 ]
  a="age1$(printf '%058d' 1)" b="age1$(printf '%058d' 2)"
  printf 'TEKNOIR_DOMAIN=x\nBACKUP_AGE_RECIPIENTS="%s %s"\n' "${b}" "${a}" > "${BATS_TEST_TMPDIR}/ok.env"
  VM_DIR="${vmdir}" AGE_KEYGEN="${bin}/age-keygen" run "${VM}" age-key --check "${BATS_TEST_TMPDIR}/ok.env"
  [ "${status}" -eq 0 ]
  printf 'TEKNOIR_DOMAIN=x\nBACKUP_AGE_RECIPIENTS="%s"\n' "${a}" > "${BATS_TEST_TMPDIR}/bad.env"
  VM_DIR="${vmdir}" AGE_KEYGEN="${bin}/age-keygen" run "${VM}" age-key --check "${BATS_TEST_TMPDIR}/bad.env"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"BACKUP_AGE_RECIPIENTS are not the recipients"* ]]
  # never prints an identity
  refute_grep -n 'AGE-SECRET-KEY' <<<"${output}"
  # without age-keygen: a clear error
  VM_DIR="${vmdir}" AGE_KEYGEN="${BATS_TEST_TMPDIR}/none" run "${VM}" age-key
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"age-keygen not found"* ]]
}

@test "airgap/site/vmtest.env: two test age recipients, public keys only" {
  run bash -c "set -u; . '${VMTEST_SITE}'; printf '%s\n' \${BACKUP_AGE_RECIPIENTS}"
  [ "${status}" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" =~ ^age1[0-9a-z]{58}$ && "${lines[1]}" =~ ^age1[0-9a-z]{58}$ ]]
  [ "${lines[0]}" != "${lines[1]}" ]
  refute_grep -n 'AGE-SECRET-KEY' "${VMTEST_SITE}"
}

@test "kc-login.sh: session cookies from a curl jar (the _csrf cookie is not a session; split cookies are)" {
  # shellcheck source=../vm/kc-login.sh
  source "${KCLOGIN}"
  local j="${BATS_TEST_TMPDIR}/jar"
  printf '# Netscape HTTP Cookie File\n\n#HttpOnly_.teknoir.airgapped\tTRUE\t/\tTRUE\t0\t_teknoir_oauth2_proxy_csrf\tabc\n' > "${j}"
  run has_session_cookie "${j}"
  [ "${status}" -ne 0 ]
  printf '#HttpOnly_.teknoir.airgapped\tTRUE\t/\tTRUE\t0\t_teknoir_oauth2_proxy_0\tpart\n' >> "${j}"
  has_session_cookie "${j}"
  run has_session_cookie "${j}" argocd.token
  [ "${status}" -ne 0 ]
  printf 'argocd.teknoir.airgapped\tFALSE\t/\tTRUE\t0\targocd.token\ttok\n' >> "${j}"
  has_session_cookie "${j}" argocd.token
  printf 'harbor.teknoir.airgapped\tFALSE\t/\tTRUE\t0\tsid\t\n' >> "${j}"
  run has_session_cookie "${j}" sid
  [ "${status}" -ne 0 ]
  [ "$(jar_cookies "${j}" | awk '{print $2}' | tr '\n' ' ')" = "_teknoir_oauth2_proxy_csrf _teknoir_oauth2_proxy_0 argocd.token " ]
}

@test "kc-login.sh: options (--logout needs a jar; a jar allows an SSO-only login; --accept-status)" {
  local ca="${BATS_TEST_TMPDIR}/ca.crt"
  : > "${ca}"
  run "${KCLOGIN}" --cacert "${ca}" --url https://x.example/ --logout
  [ "${status}" -eq 2 ]
  run "${KCLOGIN}" --cacert "${ca}" --url https://x.example/ --user u
  [ "${status}" -eq 2 ]
  run "${KCLOGIN}" --cacert "${ca}" --url https://x.example/ --cookie-jar "${BATS_TEST_TMPDIR}/j" --user u
  [ "${status}" -eq 2 ]
  run "${KCLOGIN}" --cacert "${ca}" --url https://x.example/ --accept-status 4xx --user u --password-file "${ca}"
  [ "${status}" -eq 2 ]
  run "${KCLOGIN}" --cacert "${ca}" --url https://x.example/ --frobnicate
  [ "${status}" -eq 2 ]
  # shellcheck source=../vm/kc-login.sh
  source "${KCLOGIN}"
  ACCEPT=""; status_accepted 200; status_accepted 302
  run status_accepted 403
  [ "${status}" -ne 0 ]
  ACCEPT="200,403"; status_accepted 403
  run status_accepted 401
  [ "${status}" -ne 0 ]
  [ "$(urlenc 'https://auth.x/a?b=c&d=e f')" = "https%3A%2F%2Fauth.x%2Fa%3Fb%3Dc%26d%3De%20f" ]
}

@test "kc-login.sh: abs_url resolves a path action against the page's origin; browsers' Accept: text/html" {
  # shellcheck source=../vm/kc-login.sh
  source "${KCLOGIN}"
  [ "$(abs_url 'https://auth.x.y/auth/realms/t/protocol/openid-connect/logout?client_id=a' /auth/realms/t/logout-confirm)" = "https://auth.x.y/auth/realms/t/logout-confirm" ]
  [ "$(abs_url 'https://auth.x.y/p' 'https://auth.x.y/q?a=b')" = "https://auth.x.y/q?a=b" ]
  [[ "${ACCEPT_HTML}" == "Accept: text/html"* ]]
}

@test "kc-login.sh: the logout confirmation form and Keycloak's feedback text" {
  # shellcheck source=../vm/kc-login.sh
  source "${KCLOGIN}"
  page="${BATS_TEST_TMPDIR}/page.html"
  cat > "${page}" <<'EOF'
<div id="kc-logout-confirm" class="content-area"><p class="instruction">Do you want to log out?</p>
<form class="form-actions" action="https://auth.teknoir.airgapped/auth/realms/teknoir/protocol/openid-connect/logout/logout-confirm" method="POST">
<input type="hidden" name="session_code" value="sc-123">
<input tabindex="4" class="pf-c-button" name="confirmLogout" id="kc-logout" type="submit" value="Logout"/></form></div>
EOF
  [ "$(form_action_matching logout-confirm)" = "https://auth.teknoir.airgapped/auth/realms/teknoir/protocol/openid-connect/logout/logout-confirm" ]
  [ "$(input_value session_code)" = sc-123 ]
  [ "$(input_value confirmLogout)" = Logout ]
  printf '<span id="input-error" class="pf-v5-c-helper-text__item-text" aria-live="polite">\n Account is disabled, contact your administrator.</span>\n' > "${page}"
  [ "$(feedback_text)" = "Account is disabled, contact your administrator." ]
  printf '<div class="alert"><span class="kc-feedback-text">Invalid username or password.</span></div>' > "${page}"
  [ "$(feedback_text)" = "Invalid username or password." ]
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
