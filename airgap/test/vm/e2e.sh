#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# e2e.sh — airgap end-to-end test in the KVM VM (docs/airgap/DESIGN.md test plan 3, I-16).
#
# The node is the VM tk-airgap (vm.sh, 10.77.0.10, teknoir.airgapped, bridge
# tkvm0, no egress); the LAN host is the network namespace tklan
# (lan-netns.sh). Every operator command runs in the namespace exactly as the
# runbook says (./teknoir-airgap ... from the extracted bundle), as the
# invoking user with HOME=$LAN_HOME. Harness reads on the node go over vm.sh
# ssh; Secret values are only ever compared ON the VM and never printed.
#
# Scenarios (default order; E7 runs before E6 because E6 wipes the node logs;
# E0 = resume `up` on the existing VM, a debug aid run only when named):
#   E1  fresh bootstrap on a just-created VM: up, all Applications
#       Synced/Healthy in 45 min, HTTPS to harbor/argocd/auth with the fetched
#       CA; the first admin from `admin-user --email --out` (0600 file), then
#       an oauth2-proxy login as that admin, setting the new password Keycloak
#       demands for the temporary one                        [--allow-destroy]
#   E2  idempotency: a second up reports 0 changes; pod UIDs, k3s start time,
#       Secret resourceVersions unchanged; Harbor receives 0 blob uploads
#   E3  no egress from the VM or the namespace (FORWARD DROP counters grow);
#       every running image is in containerd; no ErrImagePull
#   E4  update to bundle B changes only the bumped Applications and records B;
#       bundle A is refused, accepted with --rollback, and then kept
#   E5  interrupt up during payload sync, Harbor push and tarball import; each
#       re-run completes with no manual repair
#   E8  rotate oauth2-proxy-cookie: only that Secret changes, oauth2-proxy
#       rolls, login still works
#   E7  secrets hygiene: no Secret value in the LAN transcript or node logs;
#       no PRIVATE KEY in the bundle tar; ~/.docker, ~/.config/helm unchanged
#   E6  node rebuild: new host key -> up prints the ssh-keygen -R fix;
#       --forget-host-key completes; optional restore check  [--allow-destroy]
#   E10 migration rehearsal (OPERATE.md M3-M6): old-style install
#       (E2E_OLD_SETUP), migrate --dry-run, migrate (keycloak-admin carried
#       over: username + previous-password), up (the admin rotated to password;
#       realm teknoir; admin-user + oauth2-proxy login), migrate --argo (no
#       Teknoir K3s file or Addon left, argoproj CRDs protected, no old bundle
#       copy), migrate again (robot repo-creds Secret and robot$argocd gone,
#       app-of-apps still syncs), k3s restart (same inventory, Secrets keep
#       their resourceVersion). Nothing lost but E2E_E10_EXPECTED_GONE, old
#       secrets unchanged, CRDs Synced resources of their Applications (ArgoCD
#       3.5 writes no tracking-id on CRDs), Harbor stable    [--allow-destroy]
#
# Usage: airgap/test/vm/e2e.sh [--list] [--allow-destroy] [--stop-on-fail] [E...]
# Environment:
#   E2E_BUNDLE       bundle A: dist/teknoir-airgap-<id>.tar (+ .tar.sha256 next to it)
#   E2E_BUNDLE_B     bundle B for E4 (a trivial controller + app-of-apps bump)
#   E2E_E4_APPS      exactly the Applications B changes, e.g. "app-of-apps device-controller" (E4 needs it)
#   E2E_OLD_SETUP    E10: command (run on vpro, VM_IP exported) that installs the
#                    old (e9a3b7f) layout with dummy secrets on the fresh VM
#                    (airgap/test/vm/old-setup.sh)
#   E2E_E10_SECRETS  E10: ns/name of the Secrets that must stay unchanged
#   E2E_E10_EXPECTED_GONE  E10: Kind/ns/name of the objects the migration removes
#                    (default: the harbor-registry-htpasswd and argocd-harbor-repo Secrets)
#   E2E_E10_STABLE_SECONDS  E10: how long Harbor must roll no new core ReplicaSet (3600)
#   E2E_WORK         work dir (default ~/vmtest/e2e); LAN_HOME (default ~/vmtest/lanhome)
#   E2E_UP_FLAGS     extra flags for every teknoir-airgap call
#   E2E_ZERO_CHANGES_RE  regex that the E2 summary must match (default: "0 change|no change")
#   E2E_LOGIN_URL    oauth2-proxy protected URL (default https://<domain>/teknoir-system/grafana/)
#   E2E_ADMIN_EMAIL  E1: the first admin created with admin-user (default
#                    e2e-admin@example.com)
#   E2E_ADMIN_USER   Keycloak user for the login checks (default: E2E_ADMIN_EMAIL
#                    in lower case, the username user-controller gives the
#                    Keycloak user it creates for the User CR)
#   E2E_E6_RESTORE_CMD  E6: restore command run after the rebuild (OPERATE.md); unset = skip
# Nothing here touches vpro's /etc/hosts, its default route, or the live env.
set -euo pipefail
# iptables, ip and sysctl live in the sbin dirs, which not every shell has on PATH
PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
TL_NAME=e2e
TL_POLL=10
# shellcheck source=../lib/testlib.sh
source "${HERE}/../lib/testlib.sh"

VM="${HERE}/vm.sh"
NETNS="${HERE}/lan-netns.sh"
KCLOGIN="${HERE}/kc-login.sh"
E2E_WORK="${E2E_WORK:-${HOME}/vmtest/e2e}"
export LAN_HOME="${LAN_HOME:-${HOME}/vmtest/lanhome}"
export LAN_SITE="${E2E_SITE:-${REPO}/airgap/site/vmtest.env}"
SITE_FILE="${E2E_WORK}/site/vmtest.env"
TRANSCRIPT="${E2E_WORK}/transcript.log"
STATE="${E2E_WORK}/state"
ALL=(E1 E2 E3 E4 E5 E8 E7 E6 E10)
ALLOW_DESTROY=0 STOP_ON_FAIL=0
HARBOR_NS="${E2E_HARBOR_NS:-teknoir-system}"
HARBOR_REGISTRY="${E2E_HARBOR_REGISTRY:-harbor-registry}"
ADMIN_EMAIL="${E2E_ADMIN_EMAIL:-e2e-admin@example.com}"
ADMIN_USER="${E2E_ADMIN_USER:-$(printf '%s' "${ADMIN_EMAIL}" | tr '[:upper:]' '[:lower:]')}"
ZERO_RE="${E2E_ZERO_CHANGES_RE:-(^|[^0-9])0 change|no change|nothing changed}"
# shellcheck disable=SC1090
DOMAIN="$(. "${LAN_SITE}"; printf '%s' "${TEKNOIR_DOMAIN}")"
# shellcheck disable=SC1090
NODE_IP="$(. "${LAN_SITE}"; printf '%s' "${NODE_IP}")"
LOGIN_URL="${E2E_LOGIN_URL:-https://${DOMAIN}/teknoir-system/grafana/}"
AGENT_PID=""

usage() { sed -n '3,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# plumbing
# ---------------------------------------------------------------------------
need() { local t; for t in "$@"; do command -v "${t}" >/dev/null 2>&1 || tl_die "missing tool: ${t}"; done; }

# vmx quotes every word with %q, so the VM runs exactly one simple command:
# shell syntax (redirections, pipes, ;) inside one argument is NOT interpreted
# there (harness.bats checks every call). Use vm_upload or vm_root for that.
vmx() { "${VM}" ssh "$(printf '%q ' "$@")"; }      # one command on the VM (as teknoir)
vm_kc() { vmx sudo k3s kubectl "$@"; }
vm_root() { "${VM}" ssh 'sudo bash -s'; }          # a root script on stdin
vm_upload() { "${VM}" ssh "umask 077; cat > $(printf '%q' "$1")"; }   # vm_upload <path> < file (0600, as teknoir)

added_lines() {
  # added_lines <before> <after> — the lines of <after> that are not in
  # <before> (new or changed). diff exits 1 when anything differs, which is
  # the expected case here, not an error (set -o pipefail).
  { diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") || (( $? == 1 )); } | sed -n 's/^> //p'
}

image_names() {
  # image_names <ref> — the names containerd (crictl repoTags/repoDigests)
  # lists for a pod image ref, one per line: the Docker reference
  # normalization (no '/' -> docker.io/library/; a first component without
  # '.' or ':' that is not localhost -> docker.io/; default tag latest), plus
  # name@digest for a ref with both a tag and a digest.
  local img="$1" first name dig
  if [[ "${img}" != */* ]]; then
    img="docker.io/library/${img}"
  else
    first="${img%%/*}"
    if [[ "${first}" != *.* && "${first}" != *:* && "${first}" != localhost ]]; then
      img="docker.io/${img}"
    elif [[ "${first}" == docker.io || "${first}" == index.docker.io ]] && [[ "${img#*/}" != */* ]]; then
      img="docker.io/library/${img#*/}"
    fi
  fi
  if [[ "${img}" == *@* ]]; then
    name="${img%@*}" dig="${img#*@}"
    printf '%s\n' "${img}"
    if [[ "${name##*/}" == *:* ]]; then printf '%s@%s\n%s\n' "${name%:*}" "${dig}" "${name}"; fi
  elif [[ "${img##*/}" == *:* ]]; then
    printf '%s\n' "${img}"
  else
    printf '%s:latest\n' "${img}"
  fi
}

lan() {
  # lan <dir> <cmd...> — run in the LAN netns, cwd <dir>; output to the terminal and transcript
  local dir="$1" rc
  shift
  printf '\n$ [lan %s] %s\n' "${dir}" "$*" >> "${TRANSCRIPT}"
  set +e
  # shellcheck disable=SC2016  # expanded by the inner bash
  "${NETNS}" exec -- bash -c 'cd "$1" && shift && exec "$@"' lan "${dir}" "$@" 2>&1 | tee -a "${TRANSCRIPT}"
  rc=${PIPESTATUS[0]}
  set -e
  return "${rc}"
}

vm_host_fp() {
  # the VM's ed25519 host-key fingerprint, read the way the runbook tells the
  # operator to (ssh-keygen -lf on the node console)
  vmx ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}'
}

host_pinned() { [[ -n "$(find "${LAN_HOME}/.teknoir-airgap" -name known_hosts -size +0c 2>/dev/null)" ]]; }

tk() {
  # tk <bundle-dir> <command> [args...] — the operator's ./teknoir-airgap,
  # ALWAYS with the vmtest site (without --site the bundle's own site file
  # would name the real teknoir-local node). While no host key is pinned,
  # the first-use confirmation is given with --host-key and the VM's
  # fingerprint (no terminal here). stdin is /dev/null.
  local dir="$1" cmd="$2" site="${SITE_FILE}"
  local -a hk=()
  shift 2
  # the bundle carries site/vmtest.env (same domain): use it as the runbook does
  if [[ -f "${dir}/site/vmtest.env" ]]; then
    site=site/vmtest.env
    cmp -s "${dir}/site/vmtest.env" "${SITE_FILE}" || tl_warn "the bundle's site/vmtest.env differs from ${LAN_SITE}"
  fi
  if ! host_pinned && [[ " $* " != *" --host-key "* ]]; then hk=(--host-key "$(vm_host_fp)"); fi
  # shellcheck disable=SC2086  # E2E_UP_FLAGS is a flag list
  lan "${dir}" ./teknoir-airgap "${cmd}" --site "${site}" ${hk[@]+"${hk[@]}"} ${E2E_UP_FLAGS:-} "$@" </dev/null
}

up_in() {
  # up_in <bundle-dir> [flags...] — the operator's `./teknoir-airgap up`
  local dir="$1"
  shift
  tk "${dir}" up "$@"
}

start_agent() {
  # The LAN user authenticates with the VM's key through a private agent
  # (the equivalent of the runbook's ssh-copy-id; ~/.ssh is not touched).
  [[ -n "${AGENT_PID}" || -n "${E2E_AGENT_SOCK:-}" ]] && return 0
  eval "$(ssh-agent -s)" >/dev/null
  AGENT_PID="${SSH_AGENT_PID}"
  export E2E_AGENT_SOCK="${SSH_AUTH_SOCK}"   # children (E5's __up) reuse this agent
  ssh-add -q "$("${VM}" key)" 2>/dev/null || tl_die "cannot add the VM key $("${VM}" key) to the agent (run vm.sh create)"
}

cleanup() {
  local rc=$?
  [[ -n "${AGENT_PID}" ]] && kill "${AGENT_PID}" 2>/dev/null
  return "${rc}"
}

prepare() {
  mkdir -p "${E2E_WORK}/bundles" "${E2E_WORK}/site" "${STATE}"
  install -d -m 0700 "${LAN_HOME}" "${LAN_HOME}/e2e"
  install -m 0644 "${LAN_SITE}" "${SITE_FILE}"
  touch "${TRANSCRIPT}"
  start_agent
  local avail
  avail="$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)"
  if ! "${VM}" status 2>&1 | grep -q 'running (pid' && (( avail < 11 )); then
    tl_warn "only ${avail} GiB available; the VM needs 10 GiB (stop other docker workloads)"
  fi
}

ensure_vm() {
  # ensure_vm — VM running, LAN namespace up
  "${VM}" start
  "${NETNS}" up
}

fresh_vm() {
  (( ALLOW_DESTROY )) || { fail "${TL_CASE} re-creates the VM: pass --allow-destroy"; return 1; }
  tl_log "re-creating the VM (destroy + start)"
  "${VM}" destroy
  "${VM}" start
  "${NETNS}" up
}

bundle_dir() {
  # bundle_dir <tar> — verify the .sha256 and extract once (in the netns, as
  # the operator would); prints the extracted bundle dir
  local tar="$1" top
  [[ -f "${tar}" && -f "${tar}.sha256" ]] || tl_die "bundle ${tar} or ${tar}.sha256 missing"
  top="$(tar -tf "${tar}" | head -1 | cut -d/ -f1)"
  if [[ ! -f "${E2E_WORK}/bundles/${top}.extracted" ]]; then
    lan "$(dirname "${tar}")" sha256sum -c "$(basename "${tar}").sha256" >&2 || tl_die "sha256 check of ${tar} failed"
    rm -rf "${E2E_WORK:?}/bundles/${top}"
    lan "${E2E_WORK}/bundles" tar -xf "${tar}" >&2 || tl_die "extracting ${tar} failed"
    touch "${E2E_WORK}/bundles/${top}.extracted"
  fi
  printf '%s/bundles/%s' "${E2E_WORK}" "${top}"
}

bundle_id() { basename "$1" | sed 's/^teknoir-airgap-//'; }

ca_file() { find "${LAN_HOME}/.teknoir-airgap" -name teknoir-root-ca.crt -print -quit 2>/dev/null; }

lan_https() {
  # lan_https <url> — HTTP status from the netns with the fetched CA
  lan "${E2E_WORK}" curl -sS -m 20 --cacert "$(ca_file)" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null | tail -c 3
}

apps_state() {
  vm_kc -n teknoir-system get applications.argoproj.io --no-headers \
    -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,TARGET:.spec.source.targetRevision,REV:.status.sync.revision
}
apps_healthy() {
  local s
  s="$(apps_state 2>/dev/null)" || return 1
  [[ -n "${s}" ]] && [[ -z "$(awk '$2 != "Synced" || $3 != "Healthy"' <<<"${s}")" ]]
}
wait_apps() {
  # wait_apps <timeout> — every Application Synced/Healthy; prints the table on failure
  if wait_until "$1" apps_healthy; then pass "every Application is Synced/Healthy"; return 0; fi
  fail "Applications not all Synced/Healthy within $1 s:"
  apps_state | awk '$2 != "Synced" || $3 != "Healthy"' >&2 || true
  return 1
}

snap_pods() {
  # pod UIDs, without Job pods (CronJobs create new ones by design)
  vm_kc get pods -A -o json | jq -r '.items[]
    | select([(.metadata.ownerReferences // [])[].kind] | index("Job") | not)
    | "\(.metadata.namespace)/\(.metadata.name) \(.metadata.uid)"' | sort
}
snap_secret_rvs() {
  vm_kc get secrets -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RV:.metadata.resourceVersion | sort
}
k3s_since() { vmx systemctl show k3s -p ActiveEnterTimestamp --value; }
release_state() {
  # "<bundleId> <mode>" of the release record (only the current fields: the
  # history and previous* fields would match either bundle)
  vm_kc -n teknoir-system get configmap teknoir-airgap-release -o jsonpath='{.data.bundleId} {.data.mode}'
}
app_revs() { apps_state | awk '{print $1, $4, $5}'; }

harbor_blob_puts_since() {
  local logs
  logs="$(vm_kc -n "${HARBOR_NS}" logs "deploy/${HARBOR_REGISTRY}" --since-time="$1" 2>/dev/null)" || { echo unknown; return 0; }
  grep -cE 'PUT /v2/[^ ]+/blobs/uploads/' <<<"${logs}" || true
}

dotdirs() {
  # dotdirs — fingerprint of the docker/helm config dirs on the LAN host and the node
  {
    for d in "${LAN_HOME}/.docker" "${LAN_HOME}/.config/helm"; do
      if [[ -d "${d}" ]]; then find "${d}" -type f -exec sha256sum {} + | sort; else echo "absent ${d}"; fi
    done
    vm_root <<'EOF'
for d in /root/.docker /root/.config/helm /home/teknoir/.docker /home/teknoir/.config/helm; do
  if [ -d "$d" ]; then find "$d" -type f -exec sha256sum {} + | sort; else echo "absent $d"; fi
done
EOF
  } 2>&1
}

admin_pw_current() {
  # the admin's password file in use: admin-user writes the temporary one to
  # admin.pw; after the forced change at the first login, kc-login.sh has put
  # the new one in admin.new
  if [[ -s "${LAN_HOME}/e2e/admin.new" ]]; then printf '%s' "${LAN_HOME}/e2e/admin.new"
  else printf '%s' "${LAN_HOME}/e2e/admin.pw"; fi
}

login_check() {
  # login_check <description> — scripted oauth2-proxy/Keycloak login from the netns
  if lan "${E2E_WORK}" "${KCLOGIN}" --cacert "$(ca_file)" --url "${LOGIN_URL}" --user "${ADMIN_USER}" \
       --password-file "$(admin_pw_current)" --new-password-file "${LAN_HOME}/e2e/admin.new"; then
    pass "$1"
  else
    fail "$1"
  fi
}

# ---------------------------------------------------------------------------
# E1
# ---------------------------------------------------------------------------
e1() {
  tl_case E1 "fresh bootstrap from the extracted tar in the LAN netns"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  fresh_vm || return 0
  rm -rf "${LAN_HOME:?}/.teknoir-airgap" "${LAN_HOME}/e2e"/admin.*
  local dir
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  dotdirs > "${STATE}/dotdirs.before"
  if up_in "${dir}"; then pass "teknoir-airgap up exits 0 on a fresh node"; else fail "teknoir-airgap up failed"; return 0; fi
  wait_apps 2700 || true
  if [[ -n "$(ca_file)" ]]; then pass "the CA certificate was fetched to ${LAN_HOME}/.teknoir-airgap/<site>/"; else fail "no teknoir-root-ca.crt under ${LAN_HOME}/.teknoir-airgap"; return 0; fi
  assert_eq "https://harbor.${DOMAIN}/api/v2.0/health with the CA" 200 "$(lan_https "https://harbor.${DOMAIN}/api/v2.0/health")"
  assert_eq "https://argocd.${DOMAIN} with the CA" 200 "$(lan_https "https://argocd.${DOMAIN}/")"
  assert_eq "Keycloak master realm discovery with the CA" 200 "$(lan_https "https://auth.${DOMAIN}/auth/realms/master/.well-known/openid-configuration")"
  assert_eq "Keycloak realm teknoir discovery with the CA (D2)" 200 "$(lan_https "https://auth.${DOMAIN}/auth/realms/teknoir/.well-known/openid-configuration")"
  # the first platform admin (DESIGN C.5): a superadmin User CR, its Keycloak
  # user (realm teknoir, group admin) and a temporary password in a 0600 file
  local pw="${LAN_HOME}/e2e/admin.pw" mode
  if tk "${dir}" admin-user --email "${ADMIN_EMAIL}" --out "${pw}"; then
    mode="$(stat -c %a "${pw}" 2>/dev/null || echo missing)"
    assert_eq "admin-user --out writes the temporary password to a 0600 file" 600 "${mode}"
  else
    fail "teknoir-airgap admin-user --email ${ADMIN_EMAIL} --out failed"; return 0
  fi
  [[ -s "${pw}" ]] || { fail "admin-user wrote no temporary password to ${pw}"; return 0; }
  login_check "oauth2-proxy login as ${ADMIN_USER} at ${LOGIN_URL} (the forced change of the temporary password handled)"
}

# ---------------------------------------------------------------------------
# E2
# ---------------------------------------------------------------------------
e0() {
  # E0 (debug aid, not in the default run): `up` on the EXISTING VM, which
  # resumes a failed converge; use it to iterate on a fix without re-creating
  # the VM, then confirm with a full E1.
  tl_case E0 "resume: up on the existing VM"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  local dir rc
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  set +e; up_in "${dir}"; rc=$?; set -e
  assert_eq "up exits 0" 0 "${rc}"
}

e2() {
  tl_case E2 "idempotency: a second up changes nothing"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  local dir pods secrets since t0 out rc puts
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  pods="$(snap_pods)" secrets="$(snap_secret_rvs)" since="$(k3s_since)"
  t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e; out="$(up_in "${dir}")"; rc=$?; set -e
  assert_eq "the second up exits 0" 0 "${rc}"
  if grep -qiE "${ZERO_RE}" <<<"${out}"; then pass "the converge summary reports 0 changes"
  else fail "the summary does not match /${ZERO_RE}/:"; tail -15 <<<"${out}" >&2; fi
  assert_eq "pod UIDs unchanged" "${pods}" "$(snap_pods)"
  assert_eq "k3s ActiveEnterTimestamp unchanged (no restart)" "${since}" "$(k3s_since)"
  assert_eq "Secret resourceVersions unchanged" "${secrets}" "$(snap_secret_rvs)"
  puts="$(harbor_blob_puts_since "${t0}")"
  assert_eq "Harbor received 0 blob uploads" 0 "${puts}"
}

# ---------------------------------------------------------------------------
# E3
# ---------------------------------------------------------------------------
forward_drops() {
  sudo iptables -L FORWARD -v -x -n | awk '$3 == "DROP" && ($6 == "tkvm0" || $7 == "tkvm0") {s += $1} END {print s + 0}'
}

e3() {
  tl_case E3 "no egress from the VM or the LAN namespace; all images local"
  ensure_vm
  local before after images bad
  before="$(forward_drops)"
  assert_not_cmd "VM: https://registry-1.docker.io/v2/ is unreachable" vmx curl -sS -m 5 -o /dev/null https://registry-1.docker.io/v2/
  assert_not_cmd "VM: github.com does not resolve" vmx getent hosts github.com
  # A host route via vpro makes the VM and the namespace actually send
  # packets towards the internet, so the FORWARD DROP counters must grow.
  vmx sudo ip route replace 1.1.1.1/32 via 10.77.0.1 >/dev/null
  assert_not_cmd "VM: https://1.1.1.1 via vpro is dropped" vmx curl -sS -m 5 -o /dev/null https://1.1.1.1/
  vmx sudo ip route del 1.1.1.1/32 >/dev/null || true
  "${NETNS}" exec --root ip route replace 1.1.1.1/32 via 10.77.0.1
  assert_not_cmd "netns: https://1.1.1.1 via vpro is dropped" lan "${E2E_WORK}" curl -sS -m 5 -o /dev/null https://1.1.1.1/
  "${NETNS}" exec --root ip route del 1.1.1.1/32 || true
  assert_not_cmd "netns: a public name does not resolve" lan "${E2E_WORK}" getent hosts github.com
  after="$(forward_drops)"
  if (( after > before )); then pass "vpro FORWARD DROP counters for tkvm0 grew (${before} -> ${after})"
  else fail "FORWARD DROP counters did not grow (${before} -> ${after})"; fi
  images="$(vmx sudo k3s crictl images -o json | jq -r '.images[] | (.repoTags[]?, .repoDigests[]?)' | sort -u)"
  bad="$(vm_kc get pods -A -o json | jq -r '.items[].spec | (.containers + (.initContainers // []))[].image' | sort -u |
         while read -r img; do
           grep -qxF -f <(image_names "${img}"; printf '%s\n' "${img}") <<<"${images}" || echo "${img}"
         done)"
  assert_eq "every pod image is present in containerd (imported, or pulled through the harbor.${DOMAIN} mirror)" "" "${bad}"
  assert_eq "no ErrImagePull/ImagePullBackOff events" 0 \
    "$(vm_kc get events -A --no-headers 2>/dev/null | grep -cE 'ErrImagePull|ImagePullBackOff' || true)"
  local mirrors
  mirrors="$(vmx sudo cat /etc/rancher/k3s/registries.yaml)"
  local r miss=""
  for r in docker.io ghcr.io gcr.io quay.io registry.k8s.io; do grep -q "${r}" <<<"${mirrors}" || miss+="${r} "; done
  assert_eq "registries.yaml mirrors every upstream registry to harbor.${DOMAIN}" "" "${miss}"
}

# ---------------------------------------------------------------------------
# E4
# ---------------------------------------------------------------------------
e4() {
  tl_case E4 "update to bundle B, refusal of A, rollback to A"
  [[ -n "${E2E_BUNDLE:-}" && -n "${E2E_BUNDLE_B:-}" ]] || { skip_case "E2E_BUNDLE and E2E_BUNDLE_B required"; return 0; }
  [[ -n "${E2E_E4_APPS:-}" ]] || { skip_case "E2E_E4_APPS required: the Applications bundle B changes, e.g. \"app-of-apps device-controller\""; return 0; }
  ensure_vm
  local a b ida idb before after changed want out rc
  a="$(bundle_dir "${E2E_BUNDLE}")" b="$(bundle_dir "${E2E_BUNDLE_B}")"
  ida="$(bundle_id "${a}")" idb="$(bundle_id "${b}")"
  want="$(tr ' ' '\n' <<<"${E2E_E4_APPS}" | grep . | sort -u | tr '\n' ' ')"
  wait_until 1800 apps_healthy || true
  before="$(app_revs)"
  if up_in "${b}"; then pass "up with bundle B exits 0"; else fail "up with bundle B failed"; return 0; fi
  wait_apps 1800 || true
  after="$(app_revs)"
  changed="$(added_lines "${before}" "${after}" | awk '{print $1}' | sort -u | tr '\n' ' ')"
  assert_eq "the Applications bundle B changed are exactly E2E_E4_APPS" "${want}" "${changed}"
  assert_eq "the release record is bundle B, mode update" "${idb} update" "$(release_state)"
  set +e; out="$(up_in "${a}")"; rc=$?; set -e
  if (( rc != 0 )) && grep -qi rollback <<<"${out}"; then pass "up with the older bundle A is refused (and mentions --rollback)"
  else fail "up with the older bundle A was not refused (rc=${rc})"; fi
  assert_eq "the refused run left the release record at B" "${idb} update" "$(release_state)"
  assert_eq "the refused run left every Application at B" "${after}" "$(app_revs)"
  if up_in "${a}" --rollback; then pass "up --rollback with A exits 0"; else fail "up --rollback with A failed"; return 0; fi
  wait_apps 1800 || true
  assert_eq "the release record is bundle A, mode rollback" "${ida} rollback" "$(release_state)"
  assert_eq "every Application is back at its revision before B" "${before}" "$(app_revs)"
  if up_in "${a}"; then pass "a plain up with A after the rollback exits 0"; else fail "plain up with A after the rollback failed"; fi
  wait_apps 900 || true
  assert_eq "a plain up with A keeps A in rollback mode (no roll-forward)" "${ida} rollback" "$(release_state)"
  assert_eq "a plain up with A leaves every Application at A" "${before}" "$(app_revs)"
}

# ---------------------------------------------------------------------------
# E5
# ---------------------------------------------------------------------------
e5_prep_sync() { vmx sudo rm -rf "/var/lib/teknoir-airgap/bundles/$1"; }
e5_prep_import() {
  local img="${E2E_E5_IMPORT_IMAGE:-docker.io/alpine/k8s:1.34.11}"
  vmx sudo k3s ctr -n k8s.io images rm "${img}" >/dev/null 2>&1 || true
}
e5_prep_push() {
  # delete one mirrored repository in Harbor (not in project teknoir), so up
  # has something to push; the admin password stays inside this VM script
  vm_root <<'EOF'
set -eu
k() { k3s kubectl "$@"; }
pw="$(k -n teknoir-system get secret harbor-secret -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"
dom="$(k -n kube-system get configmap coredns-custom -o yaml | grep -oE 'harbor\.[a-z0-9.-]+' | head -1)"
api="https://${dom}/api/v2.0"
cfg="$(mktemp)"; trap 'rm -f "$cfg"' EXIT
printf 'user = "admin:%s"\n' "$pw" > "$cfg"
proj="$(curl -sS -K "$cfg" "$api/projects?page_size=100" | python3 -c 'import json,sys; print(next(p["name"] for p in json.load(sys.stdin) if p["name"] != "teknoir"))')"
repo="$(curl -sS -K "$cfg" "$api/projects/$proj/repositories?page_size=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"].split("/",1)[1])')"
enc="$(printf '%s' "$repo" | sed 's|/|%252F|g')"
code="$(curl -sS -K "$cfg" -X DELETE -o /dev/null -w '%{http_code}' "$api/projects/$proj/repositories/$enc")"
echo "deleted Harbor repository $proj/$repo (HTTP $code)"
EOF
}

interrupt_up() {
  # interrupt_up <label> <regex> <bundle-dir> — run up, kill it once its
  # output matches <regex>, then re-run it to completion
  local label="$1" re="$2" dir="$3" out="${E2E_WORK}/e5-$1.log" pid waited=0
  : > "${out}"
  setsid "$0" __up "${dir}" > "${out}" 2>&1 &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null && ! grep -qiE "${re}" "${out}"; do
    sleep 1; waited=$((waited + 1))
    (( waited < ${E2E_E5_TIMEOUT:-1800} )) || break
  done
  if ! kill -0 "${pid}" 2>/dev/null; then
    fail "${label}: up finished before /${re}/ appeared; nothing was interrupted (see ${out})"
    wait "${pid}" || true
    return 0
  fi
  sleep "${E2E_E5_DELAY:-3}"
  sudo kill -TERM -- "-${pid}" 2>/dev/null || true
  vmx sudo pkill -TERM -f 'teknoir-node converge' >/dev/null 2>&1 || true
  wait "${pid}" || true
  pass "${label}: up interrupted after /${re}/ (${waited}s)"
  if up_in "${dir}"; then pass "${label}: the re-run completes with no manual repair"; else fail "${label}: the re-run failed"; fi
  wait_apps 1800 || true
}

e5() {
  tl_case E5 "interruptions during payload sync, Harbor push and tarball import"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  local dir id
  dir="$(bundle_dir "${E2E_BUNDLE}")" id="$(bundle_id "${dir}")"
  e5_prep_sync "${id}"
  interrupt_up "payload sync" "${E2E_E5_SYNC_RE:-sync|send|payload|transfer}" "${dir}"
  e5_prep_push
  interrupt_up "Harbor push" "${E2E_E5_PUSH_RE:-harbor.*(push|image)|pushing}" "${dir}"
  e5_prep_import
  interrupt_up "tarball import" "${E2E_E5_IMPORT_RE:-import}" "${dir}"
}

# ---------------------------------------------------------------------------
# E6
# ---------------------------------------------------------------------------
harbor_projects() { lan "${E2E_WORK}" curl -sS -m 20 --cacert "$(ca_file)" "https://harbor.${DOMAIN}/api/v2.0/projects?page_size=100" | jq -r '.[].name' 2>/dev/null | sort | tr '\n' ' '; }

e6() {
  tl_case E6 "node rebuild: host-key change is reported with its fix; --forget-host-key completes"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  (( ALLOW_DESTROY )) || { skip_case "re-creates the VM: pass --allow-destroy"; return 0; }
  local dir out rc projects=""
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  [[ -n "$(ca_file)" ]] && projects="$(harbor_projects || true)"
  fresh_vm || return 0
  set +e; out="$(up_in "${dir}")"; rc=$?; set -e
  if (( rc != 0 )); then pass "up refuses the changed host key"; else fail "up accepted a changed host key"; fi
  if grep -q 'ssh-keygen -R' <<<"${out}"; then pass "the message prints the ssh-keygen -R fix"; else fail "no 'ssh-keygen -R' in the output"; fi
  if grep -q -- '--forget-host-key' <<<"${out}"; then pass "the message mentions --forget-host-key"; else fail "no '--forget-host-key' in the output"; fi
  if up_in "${dir}" --forget-host-key --host-key "$(vm_host_fp)"; then pass "up --forget-host-key bootstraps the rebuilt node"; else fail "up --forget-host-key failed"; return 0; fi
  wait_apps 2700 || true
  if [[ -z "${E2E_E6_RESTORE_CMD:-}" ]]; then
    tl_warn "restore not exercised (E2E_E6_RESTORE_CMD unset; restore is the OPERATE.md procedure)"
    return 0
  fi
  if bash -c "${E2E_E6_RESTORE_CMD}"; then pass "restore command exits 0"; else fail "restore command failed"; return 0; fi
  wait_apps 1800 || true
  assert_eq "Harbor projects are back after the restore" "${projects}" "$(harbor_projects)"
  login_check "the pre-rebuild ${ADMIN_USER} password works again (Keycloak DB restored)"
}

# ---------------------------------------------------------------------------
# E7
# ---------------------------------------------------------------------------
e7() {
  tl_case E7 "secrets hygiene: no Secret value in the transcript or node logs; no private key in the tar"
  ensure_vm
  local res
  vm_upload /tmp/e2e-transcript.log < "${TRANSCRIPT}"
  # The scan runs on the VM: values are read and compared there, never printed.
  res="$(vm_root <<'EOF'
set -eu
T=/tmp/e2e-transcript.log
k() { k3s kubectl "$@"; }
files="$T $(ls /var/log/teknoir-airgap/*.log 2>/dev/null | tr '\n' ' ')"
checked=0 leaks=0
pat="$(mktemp)" val="$(mktemp)"; trap 'rm -f "$pat" "$val" "$T"' EXIT; chmod 600 "$pat" "$val"
for ns in $(k get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in teknoir-*|cert-manager|istio-system) ;; *) continue ;; esac
  for s in $(k -n "$ns" get secrets -o jsonpath='{range .items[?(@.type!="kubernetes.io/service-account-token")]}{.metadata.name}{"\n"}{end}'); do
    case "$s" in sh.helm.release.*) continue ;; esac
    # ArgoCD repository Secrets: url, type, name, ... are the repository's
    # address and settings (logged by design); only their credentials count
    stype="$(k -n "$ns" get secret "$s" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}')"
    for key in $(k -n "$ns" get secret "$s" -o json | python3 -c 'import json,sys; print("\n".join((json.load(sys.stdin).get("data") or {}).keys()))'); do
      case "$key" in *.crt|ca.pem|*_USER|*USERNAME|username|user|KEYCLOAK_REALM|KEYCLOAK_CLIENTID) continue ;; esac
      case "$stype:$key" in repository:url|repository:type|repository:name|repository:project|repository:enableOCI|repository:insecure|repo-creds:url|repo-creds:type|repo-creds:enableOCI) continue ;; esac
      # probes: the longest line of the value (PEM markers dropped) and the
      # base64 of the whole value (how `get secret -o yaml` would print it)
      k -n "$ns" get secret "$s" -o go-template="{{index .data \"$key\" | base64decode}}" > "$val"
      grep -v -- '-----' "$val" | awk 'length > max {max = length; l = $0} END {print l}' > "$pat"
      [ "$(wc -c < "$pat")" -gt 13 ] || continue
      { base64 -w0 < "$val"; echo; } >> "$pat"
      checked=$((checked + 1))
      # shellcheck disable=SC2086  # $files is a list
      n=$(cat $files 2>/dev/null | grep -acFf "$pat" || true)
      if [ "${n:-0}" -gt 0 ]; then echo "LEAK $ns/$s key=$key lines=$n"; leaks=$((leaks + 1)); fi
    done
  done
done
echo "checked=$checked leaks=$leaks"
EOF
)"
  printf '%s\n' "${res}" >&2
  if grep -q '^checked=[1-9]' <<<"${res}"; then pass "scanned $(sed -n 's/^checked=\([0-9]*\).*/\1/p' <<<"${res}") Secret values on the VM"
  else fail "no Secret values were scanned"; fi
  assert_eq "no Secret value appears in the LAN transcript or the node logs" 0 "$(sed -n 's/.*leaks=\([0-9]*\)$/\1/p' <<<"${res}")"
  # The build gate's own checks, repeated on the shipped bundle: no PEM private
  # key header in any plain file (the bare phrase is legitimate in binaries:
  # Go's crypto code), no "PRIVATE KEY" at all in the plain-text config.
  # Image blobs, bootstrap images and the k3s images are upstream content.
  local t d
  for t in "${E2E_BUNDLE:-}" "${E2E_BUNDLE_B:-}"; do
    [[ -n "${t}" ]] || continue
    d="$(bundle_dir "${t}")"
    assert_eq "no PEM private key header in a plain file of $(basename "${t}")" "" \
      "$(find "${d}" -type f ! -path '*/node/images/*/blobs/*' ! -path '*/node/bootstrap-images/*' ! -name 'k3s-airgap-images-*' -print0 \
         | xargs -0 -r grep -laE -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' | sed "s|^${d}/||" | tr '\n' ' ' || true)"
    assert_eq "no 'PRIVATE KEY' in the plain-text config of $(basename "${t}")" "" \
      "$(find "${d}/node/oneshot" "${d}/node/templates" "${d}/site" "${d}/node/site" "${d}/node/charts/pins.txt" "${d}/node/images/images.lock" -type f -print0 2>/dev/null \
         | xargs -0 -r grep -la 'PRIVATE KEY' | sed "s|^${d}/||" | tr '\n' ' ' || true)"
  done
  if [[ -f "${STATE}/dotdirs.before" ]]; then
    assert_eq "docker and helm config dirs (.docker, .config/helm) unchanged on the LAN host and the node" "$(cat "${STATE}/dotdirs.before")" "$(dotdirs)"
  else
    assert_eq "no docker or helm config dirs on the LAN host or the node" 0 "$(dotdirs | grep -vc '^absent ' || true)"
  fi
}

# ---------------------------------------------------------------------------
# E8
# ---------------------------------------------------------------------------
e8() {
  tl_case E8 "rotate oauth2-proxy-cookie: only that Secret changes; oauth2-proxy rolls; login works"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  local dir before after changed pods_before pods_after
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  before="$(snap_secret_rvs)"
  pods_before="$(vm_kc -n teknoir-auth get pods -l "${E2E_OAUTH2_PROXY_SELECTOR:-app=oauth2-proxy}" -o jsonpath='{.items[*].metadata.uid}')"
  if tk "${dir}" rotate oauth2-proxy-cookie; then pass "rotate oauth2-proxy-cookie exits 0"; else fail "rotate failed"; return 0; fi
  wait_apps 900 || true
  after="$(snap_secret_rvs)"
  changed="$(added_lines "${before}" "${after}" | awk '{print $1 "/" $2}' | sort -u | tr '\n' ' ')"
  assert_eq "only teknoir-auth/oauth2-proxy-secret changed" "teknoir-auth/oauth2-proxy-secret " "${changed}"
  pods_after="$(vm_kc -n teknoir-auth get pods -l "${E2E_OAUTH2_PROXY_SELECTOR:-app=oauth2-proxy}" -o jsonpath='{.items[*].metadata.uid}')"
  if [[ -n "${pods_after}" && "${pods_after}" != "${pods_before}" ]]; then pass "oauth2-proxy pods were replaced"; else fail "oauth2-proxy did not roll"; fi
  login_check "login still works after the cookie-secret rotation"
}

# ---------------------------------------------------------------------------
# E10
# ---------------------------------------------------------------------------
E10_SECRETS="${E2E_E10_SECRETS:-teknoir-system/harbor-secret teknoir-auth/keycloak-db-secret teknoir-auth/oauth2-proxy-secret teknoir-auth/oauth2-proxy-redis-secret teknoir-system/argocd-oidc-secret cert-manager/teknoir-root-ca teknoir-auth/teknoir-root-ca-bundle teknoir-system/teknoir-root-ca-bundle}"
# Objects the migration removes on purpose, as Kind/namespace/name: harbor
# 0.0.9 no longer renders the registry htpasswd Secret (its Job writes
# harbor-registry-auth instead), and M6 deletes the robot's repo-creds Secret.
# Every other object of the baseline must survive; these must be gone.
E10_EXPECTED_GONE="${E2E_E10_EXPECTED_GONE:-Secret/teknoir-system/harbor-registry-htpasswd Secret/teknoir-system/argocd-harbor-repo}"
# Teknoir K3s file and Addon names (lib/migrate.sh MIGRATE_ALLOW_RE)
E10_TEKNOIR_RE='^(teknoir-.+|00-teknoir-.+|05-teknoir-.+|10-teknoir-.+|manifest-.+-secret|app-of-apps)$'

e10_inventory() {
  # every object of the kinds the migration touches, by name (no values),
  # one "Kind namespace name" (or kind/name) per line, sorted for comm
  {
    vm_kc get crd,ns -o name
    vm_kc get secrets,configmaps,virtualservices,gateways,destinationrules,authorizationpolicies,peerauthentications,certificates,clusterissuers,applications,appprojects \
      -A --no-headers -o custom-columns=K:.kind,NS:.metadata.namespace,N:.metadata.name 2>/dev/null
  } | awk '{$1 = $1; print}' | LC_ALL=C sort
}

e10_secret_hashes() {
  # sha256 of each listed Secret's data, computed on the VM (values never leave it)
  {
    printf 'refs="%s"\n' "${E10_SECRETS}"
    cat <<'EOF'
for ref in $refs; do
  h="$(k3s kubectl -n "${ref%%/*}" get secret "${ref#*/}" -o jsonpath='{.data}' 2>/dev/null | sha256sum | cut -c1-16)"
  echo "$ref $h"
done
EOF
  } | vm_root
}

e10_secret_rvs() {
  local ref
  for ref in ${E10_SECRETS}; do
    printf '%s %s\n' "${ref}" "$(vm_kc -n "${ref%%/*}" get secret "${ref#*/}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo absent)"
  done
}

e10_gone_lines() {
  # the expected-gone objects in e10_inventory's line format
  tr ' ' '\n' <<<"${E10_EXPECTED_GONE}" | grep . | tr '/' ' ' | LC_ALL=C sort
}

teknoir_addons() {
  vm_kc -n kube-system get addons.k3s.cattle.io -o name | sed 's|.*/||' | grep -E "${E10_TEKNOIR_RE}" | tr '\n' ' ' || true
}

teknoir_k3s_files() {
  # Teknoir files K3s would apply (the .skip guards do not count)
  vmx sudo ls /opt/k3s/server/manifests | grep -E '\.(ya?ml|json)$' | sed -E 's/\.(ya?ml|json)$//' |
    grep -E "${E10_TEKNOIR_RE}" | tr '\n' ' ' || true
}

secret_keys() {
  # secret_keys <ns> <name> — the Secret's key names (no values), space-separated; empty when absent
  # shellcheck disable=SC2016  # a go-template, not shell
  vm_kc -n "$1" get secret "$2" --ignore-not-found -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' | sed 's/ $//'
}

kc_admin_codes() {
  # "<password> <previous-password>": HTTP status of a master-realm token
  # request as the admin of Secret teknoir-auth/keycloak-admin with each
  # password key (none: key absent). Runs on the VM: the values go from
  # kubectl to private files and to curl as @file, never to argv or output.
  {
    printf 'DOMAIN=%q NODE_IP=%q\n' "${DOMAIN}" "${NODE_IP}"
    cat <<'EOF'
set -eu
k() { k3s kubectl "$@"; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
chmod 700 "$d"
k -n teknoir-system get secret teknoir-root-ca-bundle -o go-template='{{index .data "ca.crt" | base64decode}}' > "$d/ca"
k -n teknoir-auth get secret keycloak-admin -o go-template='{{index .data "username" | base64decode}}' > "$d/u"
out=""
for key in password previous-password; do
  if k -n teknoir-auth get secret keycloak-admin -o go-template="{{with index .data \"$key\"}}{{. | base64decode}}{{end}}" > "$d/p" && [ -s "$d/p" ]; then
    c="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 --cacert "$d/ca" --resolve "auth.${DOMAIN}:443:${NODE_IP}" \
      --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
      --data-urlencode "username@$d/u" --data-urlencode "password@$d/p" \
      "https://auth.${DOMAIN}/auth/realms/master/protocol/openid-connect/token" 2>/dev/null)" || c="${c:-000}"
  else
    c=none
  fi
  out="${out}${out:+ }${c}"
done
echo "${out}"
EOF
  } | vm_root
}
kc_admin_rotated() { [[ "$(kc_admin_codes 2>/dev/null)" == "200 401" ]]; }

robot_argocd_state() {
  # "<http status> <number of robot$argocd accounts>" from the Harbor API as
  # the Harbor admin; runs on the VM (the password reaches curl in a config
  # file, never argv or output)
  {
    printf 'DOMAIN=%q NODE_IP=%q\n' "${DOMAIN}" "${NODE_IP}"
    cat <<'EOF'
set -eu
k() { k3s kubectl "$@"; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
chmod 700 "$d"
k -n teknoir-system get secret teknoir-root-ca-bundle -o go-template='{{index .data "ca.crt" | base64decode}}' > "$d/ca"
k -n teknoir-system get secret harbor-secret -o go-template='{{index .data "HARBOR_ADMIN_PASSWORD" | base64decode}}' > "$d/p"
python3 - "$d/p" "$d/cfg" <<'PY'
import sys
p = open(sys.argv[1]).read().replace("\\", "\\\\").replace('"', '\\"')
with open(sys.argv[2], "w") as f:
    f.write('user = "admin:%s"\n' % p)
PY
c="$(curl -sS -o "$d/out" -w '%{http_code}' -m 20 --cacert "$d/ca" --resolve "harbor.${DOMAIN}:443:${NODE_IP}" -K "$d/cfg" \
  "https://harbor.${DOMAIN}/api/v2.0/robots?q=name%3Dargocd&page_size=100" 2>/dev/null)" || c="${c:-000}"
n="$(python3 -c 'import json, sys; print(sum(1 for r in (json.load(open(sys.argv[1])) or []) if r.get("name") in ("robot$argocd", "argocd")))' "$d/out" 2>/dev/null || echo unknown)"
echo "${c} ${n}"
EOF
  } | vm_root
}

aoa_compared_since() {
  # aoa_compared_since <UTC timestamp> — app-of-apps was compared after it
  # (no pending refresh), is Synced and has no *Error condition
  local s rec err sync ref
  s="$(vm_kc -n teknoir-system get applications.argoproj.io app-of-apps -o json | jq -r '
      [(.status.reconciledAt // ""),
       ([(.status.conditions // [])[] | select(.type | test("Error$")) | .type] | join(",")),
       (.status.sync.status // ""),
       (.metadata.annotations["argocd.argoproj.io/refresh"] // "")] | join("|")')" || return 1
  IFS='|' read -r rec err sync ref <<<"${s}"
  [[ -z "${ref}" && -n "${rec}" && ! "${rec}" < "$1" && -z "${err}" && "${sync}" == Synced ]]
}

old_bundle_copies() {
  vm_root <<'EOF'
for d in /home/teknoir/teknoir-airgap-bundle-*; do [ -e "$d" ] && echo "$d"; done
true
EOF
}

argoproj_crds_unprotected() {
  # argoproj.io CRDs without Prune=false and Delete=false ("none found" when there are none)
  vm_kc get crd -o json | jq -r '
      [.items[] | select(.spec.group == "argoproj.io")] as $c
      | if ($c | length) == 0 then "none found"
        else [$c[] | select(((.metadata.annotations["argocd.argoproj.io/sync-options"] // "") | split(",") | map(gsub("\\s"; ""))) as $o
                            | ($o | index("Prune=false")) == null or ($o | index("Delete=false")) == null)
                   | .metadata.name] | join(" ") end'
}

e10() {
  tl_case E10 "migration rehearsal: old layout -> migrate -> up -> migrate --argo -> migrate (M6) -> k3s restart"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  [[ -n "${E2E_OLD_SETUP:-}" ]] || { skip_case "E2E_OLD_SETUP (old-tooling install command) not set"; return 0; }
  (( ALLOW_DESTROY )) || { skip_case "re-creates the VM: pass --allow-destroy"; return 0; }
  fresh_vm || return 0
  rm -rf "${LAN_HOME:?}/.teknoir-airgap" "${LAN_HOME}/e2e"/admin.*
  if VM_IP="${NODE_IP}" bash -c "${E2E_OLD_SETUP}"; then pass "old-style install completed"; else fail "E2E_OLD_SETUP failed"; return 0; fi
  local dir inv0 hashes0 inv1 inv2 rvs1 gone lost unexpected g codes t0 st skips pw="${LAN_HOME}/e2e/admin.pw" mode
  dir="$(bundle_dir "${E2E_BUNDLE}")"

  # --- baseline and M3 -------------------------------------------------------
  inv0="$(e10_inventory)" hashes0="$(e10_secret_hashes)"
  assert_eq "the old layout has no Secret teknoir-auth/keycloak-admin yet" "" "$(secret_keys teknoir-auth keycloak-admin)"
  if tk "${dir}" migrate --dry-run; then pass "migrate --dry-run exits 0"; else fail "migrate --dry-run failed"; fi
  assert_eq "migrate --dry-run changed nothing" "${inv0}" "$(e10_inventory)"
  if tk "${dir}" migrate; then pass "migrate exits 0"; else fail "migrate failed"; return 0; fi
  assert_eq "migrate created Secret keycloak-admin with exactly username and previous-password" \
    "previous-password username" "$(secret_keys teknoir-auth keycloak-admin)"
  assert_eq "after migrate no Teknoir Addon is left but teknoir-argo" "teknoir-argo " "$(teknoir_addons)"
  assert_eq "after migrate no Teknoir K3s file is left but teknoir-argo" "teknoir-argo " "$(teknoir_k3s_files)"

  # --- M4: up, the Keycloak admin rotation, realm teknoir, the first admin ------
  # --force-images as in OPERATE M4: the old tooling mirrored mutable tags
  # (postgres:17-alpine) that have moved upstream since
  if up_in "${dir}" --force-images; then pass "up --force-images after migrate exits 0"; else fail "up after migrate failed"; return 0; fi
  wait_apps 2700 || true
  assert_eq "up added password to Secret keycloak-admin" "password previous-password username" "$(secret_keys teknoir-auth keycloak-admin)"
  wait_until 900 kc_admin_rotated || true
  codes="$(kc_admin_codes)"
  assert_eq "the master admin logs in with keycloak-admin password" 200 "${codes%% *}"
  assert_eq "the master admin no longer logs in with previous-password (rotated)" 401 "${codes##* }"
  assert_eq "Keycloak realm teknoir discovery with the CA" 200 "$(lan_https "https://auth.${DOMAIN}/auth/realms/teknoir/.well-known/openid-configuration")"
  if tk "${dir}" admin-user --email "${ADMIN_EMAIL}" --out "${pw}"; then
    mode="$(stat -c %a "${pw}" 2>/dev/null || echo missing)"
    assert_eq "admin-user --out writes the temporary password to a 0600 file" 600 "${mode}"
  else
    fail "teknoir-airgap admin-user --email ${ADMIN_EMAIL} --out failed"
  fi
  if [[ -s "${pw}" ]]; then
    login_check "oauth2-proxy login as ${ADMIN_USER} at ${LOGIN_URL} on the migrated node"
  else
    fail "admin-user wrote no temporary password to ${pw}"
  fi

  # --- M4b: migrate --argo ------------------------------------------------------
  if tk "${dir}" migrate --argo --dry-run; then pass "migrate --argo --dry-run exits 0"; else fail "migrate --argo --dry-run failed"; fi
  if tk "${dir}" migrate --argo; then pass "migrate --argo exits 0"; else fail "migrate --argo failed"; return 0; fi
  assert_eq "no Teknoir Addon is left" "" "$(teknoir_addons)"
  assert_eq "no Teknoir K3s file is left in /opt/k3s/server/manifests" "" "$(teknoir_k3s_files)"
  skips="$(vmx sudo ls /opt/k3s/server/manifests | grep -E '^teknoir-(argo|app-of-apps)\.yaml\.skip$' | tr '\n' ' ' || true)"
  assert_eq "the .skip guards of teknoir-app-of-apps and teknoir-argo are in place" "teknoir-app-of-apps.yaml.skip teknoir-argo.yaml.skip " "${skips}"
  assert_eq "every argoproj.io CRD carries Prune=false,Delete=false" "" "$(argoproj_crds_unprotected)"
  assert_eq "no ~teknoir/teknoir-airgap-bundle-* copy is left on the node" "" "$(old_bundle_copies)"

  # --- M6: migrate again retires the robot ----------------------------------------
  assert_eq "robot\$argocd exists in Harbor before M6 (HTTP status, count)" "200 1" "$(robot_argocd_state)"
  if tk "${dir}" migrate; then pass "the second migrate (M6) exits 0"; else fail "the second migrate (M6) failed"; fi
  assert_eq "Secret teknoir-system/argocd-harbor-repo is gone" "" \
    "$(vm_kc -n teknoir-system get secret argocd-harbor-repo --ignore-not-found -o name)"
  t0="$(vmx date -u +%Y-%m-%dT%H:%M:%SZ)"
  vm_kc -n teknoir-system annotate applications.argoproj.io app-of-apps argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  if wait_until 300 aoa_compared_since "${t0}"; then pass "app-of-apps still syncs after a hard refresh without the robot credential"
  else fail "app-of-apps is not Synced without errors after a hard refresh"; fi
  assert_eq "robot\$argocd is gone from Harbor (HTTP status, count)" "200 0" "$(robot_argocd_state)"

  # --- M5: k3s restart --------------------------------------------------------------
  wait_apps 1800 || true
  inv1="$(e10_inventory)" rvs1="$(e10_secret_rvs)"
  vmx sudo systemctl restart k3s
  wait_until 300 vm_kc get --raw /readyz >/dev/null 2>&1 || fail "API not ready after the k3s restart"
  sleep 60
  wait_apps 1800 || true
  inv2="$(e10_inventory)"
  assert_eq "the k3s restart changed no object (inventory diff)" "" \
    "$(diff <(printf '%s\n' "${inv1}") <(printf '%s\n' "${inv2}") | sed -n 's/^\([<>]\) /\1/p' | tr '\n' ' ' || true)"
  assert_eq "no Teknoir Addon re-appeared after the restart" "" "$(teknoir_addons)"
  assert_eq "no Teknoir K3s file re-appeared after the restart" "" "$(teknoir_k3s_files)"
  assert_eq "the platform Secrets kept their resourceVersion over the restart" "${rvs1}" "$(e10_secret_rvs)"

  # --- whole run: nothing lost but the expected, Secrets adopted, CRDs, Harbor -----
  gone="$(e10_gone_lines)"
  lost="$(LC_ALL=C comm -23 <(printf '%s\n' "${inv0}") <(printf '%s\n' "${inv2}"))"
  unexpected="$(LC_ALL=C comm -23 <(printf '%s\n' "${lost}" | grep .) <(printf '%s\n' "${gone}") | tr '\n' ';' || true)"
  assert_eq "no object lost but the expected ones (${E10_EXPECTED_GONE})" "" "${unexpected}"
  while IFS= read -r g; do
    [[ -n "${g}" ]] || continue
    if grep -qxF -- "${g}" <<<"${inv0}"; then pass "expected-gone ${g// //} existed before the migration"
    else fail "expected-gone ${g// //} was not in the baseline"; fi
    if grep -qxF -- "${g}" <<<"${inv2}"; then fail "expected-gone ${g// //} still exists"
    else pass "expected-gone ${g// //} is gone"; fi
  done <<<"${gone}"
  assert_eq "the existing platform Secrets are unchanged (adopted by name and key)" "${hashes0}" "$(e10_secret_hashes)"
  # ArgoCD 3.5 writes no tracking-id on CRDs: a CRD is adopted when its
  # Application lists it as a Synced resource (k3d T6)
  local app crd rs0 rs1
  for app in istio:gateways.networking.istio.io cert-manager:certificates.cert-manager.io; do
    crd="${app#*:}" app="${app%%:*}"
    st="$(vm_kc -n teknoir-system get applications.argoproj.io "${app}" -o json |
          jq -r --arg n "${crd}" '.status.resources[]? | select(.kind == "CustomResourceDefinition" and .name == $n) | .status')"
    assert_eq "CRD ${crd} is a Synced resource of Application ${app}" Synced "${st}"
  done
  rs0="$(vm_kc -n "${HARBOR_NS}" get rs -l component=core -o name | sort)"
  tl_log "watching harbor-core ReplicaSets for ${E2E_E10_STABLE_SECONDS:-3600}s"
  sleep "${E2E_E10_STABLE_SECONDS:-3600}"
  rs1="$(vm_kc -n "${HARBOR_NS}" get rs -l component=core -o name | sort)"
  assert_eq "no new harbor-core ReplicaSet (Harbor render is stable)" "${rs0}" "${rs1}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == __up ]]; then
    # internal: one `up` for interrupt_up (run under setsid)
    shift; start_agent; up_in "$@"; return
  fi
  local -a run=()
  while (( $# )); do
    case "$1" in
      --list) printf '%s\n' "${ALL[@]}"; return 0 ;;
      --allow-destroy) ALLOW_DESTROY=1 ;;
      --stop-on-fail) STOP_ON_FAIL=1 ;;
      -h|--help) usage; return 0 ;;
      E[0-9]*) [[ " ${ALL[*]} E0 " == *" ${1^^} "* ]] || tl_die "unknown scenario $1 (see --list)"; run+=("${1^^}") ;;
      *) tl_die "unknown argument $1 (see --help)" ;;
    esac
    shift
  done
  (( ${#run[@]} )) || run=("${ALL[@]}")
  need sudo ip curl jq tar sha256sum ssh ssh-agent ssh-add setsid iptables stat
  trap cleanup EXIT
  prepare
  local s
  for s in "${run[@]}"; do
    "${s,,}"
    if (( STOP_ON_FAIL && TL_CASE_FAILED )); then tl_warn "stopping after the failed ${s}"; break; fi
  done
  tl_summary | tee "${E2E_WORK}/summary.txt"
}

# Sourcing (unit tests) defines the functions without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
