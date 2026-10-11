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
#       CA; every platform Application's last operation Succeeded; the
#       monitoring admission webhooks have a caBundle; every digest-pinned
#       container runs that digest; post logs "live image check: N pullable
#       ... 0 missing"; /oauth2/start redirects to auth.<domain>. The first
#       admin (the owner of Profile teknoir-default unless E2E_ADMIN_EMAIL)
#       from `admin-user --email --out` (0600 file): the User keeps no
#       status.set_initial_password and the temporary-password Secret is gone;
#       an oauth2-proxy login as that admin sets the new password Keycloak
#       demands and never sees the Update Profile form; Backstage resolves the
#       session to user:default/<name> within 3 min of the User's creation;
#       backstage-api never restarted. A bundle older than r5 (app-of-apps <
#       E2E_R5_AOA: bundle A of the upgrade run) is a baseline: those r5-only
#       checks (operations, caBundle, digests, the handover, the profile form,
#       the Backstage identity, the restarts) only warn    [--allow-destroy]
#   E11 default teamspace teknoir-default (GitOps Profile): Profile, namespace,
#       RoleBindings, the owner claim, policies, Secrets, the AppProject
#       (Harbor only, no cluster kinds) and its 9 plugin Applications from
#       Harbor at PLUGIN_CHART_VERSION with RespectIgnoreDifferences, Synced/
#       Healthy in 20 min; plugin status Success; pods Ready with the sidecar,
#       images local; mqtt-teknoir-default.<domain> resolves to NODE_IP in a
#       pod; TLS on 8883 and 2222; Grafana and Prometheus of the teamspace
#       answer the owner; the Backstage catalog has the system and the user's
#       teamspace group
#   E12 node time: the bundled chrony and util-linux-extra at their pinned
#       versions, systemd-timesyncd gone, chrony active, hwclock present; the
#       node 20 s behind -> a plain up corrects it within 60 s, no package
#       change; 400 s behind (RTC too) -> up refuses with the --sync-clock
#       hint, up --sync-clock fixes clock and RTC; after a guest reboot the
#       clock is within 5 s; SNTP from the LAN host: stratum <= 11, offset
#       <= 2 s; doctor reports no FAIL for the node
#   E13 access and credentials: a non-admin realm user (its temporary-password
#       Secret deleted once it set its own password) gets 403 from the
#       teknoir-system Grafana, Prometheus and Alertmanager, no ArgoCD
#       Applications and 403 creating a Harbor project; the admin gets 200
#       and is Grafana Admin by e-mail; platform-admin cannot sign in;
#       controller RBAC (can-i matrix, no "forbidden" in their logs);
#       keycloak-admin without previous-password; the LAN backup without a tty
#       decrypts with each test age identity and verifies, one plaintext set
#       left on the node; rotate argocd-admin (initial Secret gone, old
#       password 401, new 200, SSO admin still role:admin); rotate keycloak-db
#       --i-know and the admin still signs in; Prometheus sends its alerts
#   E14 sign-in robustness: a garbage session cookie -> 302 /oauth2/start and
#       expired cookies; XHR -> 401 without Location; http -> 301 https; a
#       signed-in API call without a Backstage token gets Backstage's own
#       401/403; the logout chain (oauth2-proxy sign_out -> Keycloak logout
#       confirmation -> https://<domain>/ -> /oauth2/start -> login form)
#   E2  idempotency: a second up reports 0 changes; pod UIDs, k3s start time,
#       Secret resourceVersions unchanged (only user-controller's own deletion
#       of a temporary-password Secret is allowed); Harbor receives 0 blob uploads; the
#       teknoir-default Applications were not synced again and their Secrets
#       kept their resourceVersions; profile-controller did not restart
#   E3  no egress from the VM or the namespace (FORWARD DROP counters grow);
#       every running image is in containerd; no ErrImagePull
#   E4  update to bundle B changes only the bumped Applications and records B,
#       every platform operation Succeeded, admission caBundle set, digests
#       match, the admin still signs in (Keycloak data kept), Harbor healthy;
#       bundle A is refused, accepted with --rollback, and then kept. From an
#       r5 B to a pre-r5 A the rollback meets an open design gap (B's kept
#       Profile and Namespace, A's post): E2E_E4_ROLLBACK=1 runs it and asserts
#       each part; E2E_E4_ROLLBACK=0 waives it on purpose (noted in the
#       summary row); left at auto, E4 fails, because an unrehearsed rollback
#       is not green
#   E5  interrupt up during payload sync, Harbor push and tarball import; each
#       re-run completes with no manual repair
#   E8  rotate oauth2-proxy-cookie: only that Secret changes, oauth2-proxy
#       rolls, the pre-rotation cookie gets 302 /oauth2/start (not 403), login
#       still works
#   E7  secrets hygiene: no Secret value in the LAN transcript or node logs,
#       nor any value the LAN side holds (passwords from admin-user, kc-login
#       and credentials, the test age identities); no age identity on the
#       node; no PRIVATE KEY or age identity in the bundle tar; ~/.docker,
#       ~/.config/helm unchanged
#   E6  node rebuild: new host key -> up prints the ssh-keygen -R fix;
#       --forget-host-key completes; optional restore check  [--allow-destroy]
#   E10 migration rehearsal (OPERATE.md M3-M6): old-style install
#       (E2E_OLD_SETUP), migrate --dry-run, migrate (keycloak-admin carried
#       over: username + previous-password), up (the admin rotated to password;
#       realm teknoir; admin-user + oauth2-proxy login), migrate --argo (no
#       Teknoir K3s file or Addon left, argoproj CRDs protected, no old bundle
#       copy, no "no owner" warning), migrate again (robot repo-creds Secret
#       and robot$argocd gone, app-of-apps still syncs), k3s restart (same
#       inventory, Secrets keep their resourceVersion), an encrypted backup,
#       then migrate --finalize (manifests-retired gone, .skip guards kept).
#       Nothing lost but E2E_E10_EXPECTED_GONE, old secrets unchanged, CRDs
#       Synced resources of their Applications (ArgoCD 3.5 writes no
#       tracking-id on CRDs), Harbor stable                [--allow-destroy]
#   E15 live rehearsal: E10's old layout, migrate, up with bundle A (the admin
#       signs in once: legacy status.set_initial_password, no required
#       actions), migrate --argo and M6 as on the live node; then the live
#       state is injected: Profile teknoir-demo whose Applications point at
#       github.io, a stale Failed monitoring operation with retryCount 5,
#       empty admission caBundles, and realm master's legacy clients, which
#       the live node got by hand (old AIRGAP-BOOTSTRAP 8) and neither the old
#       layout nor A creates: teknoir (the oauth2-proxy client's secret, a
#       service account with master-realm manage-users), argocd, harbor; the
#       teknoir service account lists master's users (the severity); before
#       B all 3 exist and teknoir's secret gets a master token
#       (previous-password comes from the migration); then
#       up with bundle B: post passes, teknoir-demo moves to Harbor
#       (Synced/Healthy or a warning), monitoring syncs and gets its caBundle,
#       the legacy field is cleared without a password change,
#       previous-password and the master clients are gone (teknoir's secret
#       gets 401 on master), admin-user grants owner on teknoir-default and
#       teknoir-demo; then the E11, E13 and E14 checks      [--allow-destroy]
#
# Usage: airgap/test/vm/e2e.sh [--list] [--allow-destroy] [--stop-on-fail] [E...]
# Environment:
#   E2E_BUNDLE       bundle A: dist/teknoir-airgap-<id>.tar (+ .tar.sha256 next to it)
#   E2E_BUNDLE_B     bundle B for E4 and E15 (E15: the release under test)
#   E2E_E4_APPS      exactly the Applications B changes, e.g. "app-of-apps device-controller",
#                    or auto: app-of-apps and the Applications whose chart pin differs
#                    between A's and B's node/charts/pins.txt, plus the teknoir-default
#                    plugin Applications when B's profile-controller adds that Profile
#                    (E4 needs it)
#   E2E_E4_ROLLBACK  E4 after the refused A: auto (default) rolls back to A unless B
#                    is r5 and A predates it (then E4 fails and names the gap); 1
#                    always (r5 -> pre-r5: each part of the expected state asserted;
#                    the release run uses this); 0 never (a waiver, noted in the summary)
#   E2E_E1_BASELINE  E1: auto (default) treats a bundle older than r5 as a baseline
#                    (the r5-only checks warn); 1 always; 0 never (all strict)
#   E2E_R5_AOA       the first app-of-apps version of r5 (default 0.0.5), read from
#                    MANIFEST.yaml appOfAppsVersion or node/charts/pins.txt
#   E2E_OLD_SETUP    E10, E15: command (run on the rig host, VM_IP exported) that installs the
#                    old (e9a3b7f) layout with dummy secrets on the fresh VM
#                    (airgap/test/vm/old-setup.sh)
#   E2E_E10_SECRETS  E10: ns/name of the Secrets that must stay unchanged
#   E2E_E10_EXPECTED_GONE  E10: Kind/ns/name of the objects the migration removes
#                    (default: the harbor-registry-htpasswd and argocd-harbor-repo Secrets)
#   E2E_E10_STABLE_SECONDS  E10: how long Harbor must roll no new core ReplicaSet (3600)
#   E2E_E15_DEMO_PROFILE  E15: Profile manifest for teknoir-demo (default: owner
#                    = the admin, no spec.plugins: the controller's defaults)
#   E2E_WORK         work dir (default ~/vmtest/e2e); LAN_HOME (default ~/vmtest/lanhome)
#   E2E_UP_FLAGS     extra flags for every teknoir-airgap call
#   E2E_ZERO_CHANGES_RE  regex that the E2 summary must match (default: "0 change|no change")
#   E2E_LOGIN_URL    oauth2-proxy protected URL (default https://<domain>/teknoir-system/grafana/)
#   E2E_ADMIN_EMAIL  the first admin created with admin-user (default: the
#                    owner of Profile teknoir-default once it exists (E1, E10,
#                    E15; remembered in E2E_WORK/state/admin-email), else
#                    e2e-admin@example.com)
#   E2E_ADMIN_USER   Keycloak user for the login checks (default: E2E_ADMIN_EMAIL
#                    in lower case, the username user-controller gives the
#                    Keycloak user it creates for the User CR)
#   E2E_NONADMIN_EMAIL  E13: the non-admin realm user (default e2e-viewer@example.com)
#   E2E_TEAMSPACE    E11: the GitOps teamspace (default teknoir-default)
#   E2E_CREDENTIALS_NS  namespace of the temporary-password Secrets
#                    (default teknoir-user-credentials)
#   E2E_DNS_IMAGE    E11: image with nslookup for the in-pod lookup, present on
#                    the node (default docker.io/library/busybox:1.36.1)
#   E2E_CATALOG_TIMEOUT  E1, E11: seconds to wait for the Backstage catalog (300)
#   E2E_AGE          age binary for E13's decryption (default: age on PATH,
#                    else the bundle's node/bin/age); the identities are
#                    VM_DIR/age/*.key (vm.sh age-key)
#   E2E_E6_RESTORE_CMD  E6: restore command run after the rebuild (OPERATE.md); unset = skip
# Nothing here touches the rig host's /etc/hosts, its default route, or any live env.
# The rig host is the dev host (teknoir.airgapped): its own name is the platform
# domain, so everything that talks to the platform runs inside the tklan netns
# (lan-netns.sh exec), never on the host.
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
HTTP_DIR="${E2E_WORK}/http"
ALL=(E1 E11 E12 E13 E14 E2 E3 E4 E5 E8 E7 E6 E10 E15)
ALLOW_DESTROY=0 STOP_ON_FAIL=0
HARBOR_NS="${E2E_HARBOR_NS:-teknoir-system}"
HARBOR_REGISTRY="${E2E_HARBOR_REGISTRY:-harbor-registry}"
ADMIN_EMAIL="${E2E_ADMIN_EMAIL:-e2e-admin@example.com}"
ADMIN_USER="${E2E_ADMIN_USER:-$(printf '%s' "${ADMIN_EMAIL}" | tr '[:upper:]' '[:lower:]')}"
ADMIN_JAR="${LAN_HOME}/e2e/admin.jar"
NONADMIN_EMAIL="${E2E_NONADMIN_EMAIL:-e2e-viewer@example.com}"
NONADMIN_JAR="${LAN_HOME}/e2e/nonadmin.jar"
TEAMSPACE="${E2E_TEAMSPACE:-teknoir-default}"
CRED_NS="${E2E_CREDENTIALS_NS:-teknoir-user-credentials}"
CATALOG_TIMEOUT="${E2E_CATALOG_TIMEOUT:-300}"
# the profile-controller's default plugins (TS-C6): one Application each, <teamspace>-<plugin>
PLUGINS=(deadend emqx prometheus jwks fleet-metrics grafana mongodb historian observatory)
ROOT_APP="app-of-apps"
# the first app-of-apps version of release r5: an older bundle (E1's baseline
# in the upgrade run, E4's rollback target) predates the r5 assertions
R5_AOA="${E2E_R5_AOA:-0.0.5}"
# set while E1 checks a pre-r5 baseline bundle: the r5-only assertions warn
R5_SOFT=""
NODE_STATE_DIR=/var/lib/teknoir-airgap
AGE_ID_DIR="${VM_DIR:-${HOME}/vmtest}/age"
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
  install -d -m 0700 "${LAN_HOME}" "${LAN_HOME}/e2e" "${HTTP_DIR}"
  install -m 0644 "${LAN_SITE}" "${SITE_FILE}"
  touch "${TRANSCRIPT}"
  # the first admin chosen by an earlier E1/E10/E15 (the teknoir-default owner)
  if [[ -z "${E2E_ADMIN_EMAIL:-}" && -s "${STATE}/admin-email" ]]; then set_admin "$(head -n1 "${STATE}/admin-email")"; fi
  start_agent
  rig_preflight
}

rig_preflight() {
  # rig_preflight — fail early and clearly when the rig host cannot run the VM
  # (sudo without a password, KVM, no clash with the bridge subnet, RAM for
  # the VM unless it already runs: vm.sh ram-check, VM_MEM_MB + headroom)
  sudo -n true 2>/dev/null || tl_die "passwordless sudo is required (bridge, netns and firewall rules)"
  [[ -e /dev/kvm ]] || tl_die "/dev/kvm is missing: the VM needs KVM"
  local clash
  clash="$(ip -4 route show to match "${NODE_IP}" 2>/dev/null | awk '$0 !~ /dev tkvm0( |$)/ && $1 != "default"')"
  [[ -z "${clash}" ]] || tl_die "a host route other than tkvm0 covers the VM subnet (${NODE_IP}): ${clash}"
  if ! "${VM}" status 2>&1 | grep -q 'running (pid'; then "${VM}" ram-check || tl_die "not enough free RAM for the VM (see above)"; fi
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
  rm -f "${STATE}/node-rebooted"
  "${VM}" start
  "${NETNS}" up
}

pull_failures() {
  # pull_failures [kubectl get events args] — the number of image-pull failure
  # events (ErrImagePull, ImagePullBackOff, Failed to pull, Back-off pulling)
  # and, one line later, the pods that are waiting in a pull error right now
  # are counted by pull_waiting. After a node reboot (E12 leaves the marker) the
  # pods with imagePullPolicy Always (the :latest teamspace images) resolve their
  # tag at harbor.<domain> while Harbor itself is still starting and get 503:
  # a pod with such a "Failed to pull image ... 503" event is a transient boot
  # race (retried by kubelet), not counted; pull_waiting must still be 0 once
  # the platform is Ready.
  local rebooted=false
  [[ -e "${STATE}/node-rebooted" ]] && rebooted=true
  vm_kc get events "$@" -o json 2>/dev/null | jq -r --argjson rebooted "${rebooted}" '
    def pull: (.message // "") | test("ErrImagePull|ImagePullBackOff|Failed to pull|Back-off pulling");
    def boot503: (.message // "") | test("Failed to pull image.*503 Service Unavailable");
    ([.items[] | select(pull and boot503) | .involvedObject.name] | unique) as $transient
    | [.items[] | select(pull) | select(($rebooted | not) or ((.involvedObject.name as $n | $transient | index($n)) | not))] | length' \
    || echo "?"
}

pull_waiting() {
  # pull_waiting [kubectl args] — pods with a container waiting in ErrImagePull/ImagePullBackOff now
  vm_kc get pods "$@" -o json 2>/dev/null | jq -r '
    [.items[] | select([((.status.containerStatuses // []) + (.status.initContainerStatuses // []))[]
        | (.state.waiting.reason // "") | select(. == "ErrImagePull" or . == "ImagePullBackOff")] | length > 0)] | length' \
    || echo "?"
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

bundle_aoa() {
  # bundle_aoa <bundle-dir> — the app-of-apps version the bundle installs:
  # MANIFEST.yaml appOfAppsVersion, else node/charts/pins.txt (as
  # load_bundle_info reads it on the node); empty when neither says
  local dir="$1" v=""
  if [[ -f "${dir}/MANIFEST.yaml" ]]; then
    v="$(awk '/^appOfAppsVersion:/ {
        sub(/^appOfAppsVersion:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }' \
      "${dir}/MANIFEST.yaml")"
  fi
  if [[ -z "${v}" && -f "${dir}/node/charts/pins.txt" ]]; then
    v="$(awk '$1 == "app-of-apps" {print $2; exit}' "${dir}/node/charts/pins.txt")"
  fi
  printf '%s' "${v}"
}
version_lt() {
  # version_lt <a> <b> — 0 when a sorts strictly before b (sort -V, as release.sh)
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}
bundle_is_r5() {
  # bundle_is_r5 <bundle-dir> — 0 when the bundle carries release r5
  # (app-of-apps >= R5_AOA). A bundle without a version counts as r5, so its
  # checks stay strict.
  local v
  v="$(bundle_aoa "$1")"
  [[ -z "${v}" ]] || ! version_lt "${v}" "${R5_AOA}"
}

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
platform_ready() {
  # every non-Job pod Ready and the ingress answers (a reboot leaves the
  # Applications' last Healthy status in place until ArgoCD looks again)
  local unready code
  unready="$(vm_kc get pods -A -o json 2>/dev/null | jq -r '[.items[]
      | select(.status.phase != "Succeeded" and .status.phase != "Failed")
      | select([(.metadata.ownerReferences // [])[].kind] | index("Job") | not)
      | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0)] | length' 2>/dev/null || echo ?)"
  [[ "${unready}" == 0 ]] || return 1
  code="$(lan_https "https://${DOMAIN}/teknoir-system/grafana/")"
  [[ "${code}" =~ ^(200|302|401|403)$ ]]
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
drop_cred_deletions() {
  # drop_cred_deletions <before> <after> — snap_secret_rvs <before> without
  # the CRED_NS Secrets that are gone in <after>: user-controller deletes a
  # temporary-password Secret on its own requeue once the user has set a
  # password (K1 case b), which is not a change `up` made. A Secret created
  # or changed in CRED_NS still differs.
  local now
  now="$(awk -v ns="${CRED_NS}" '$1 == ns { print $2 }' <<<"$2" | tr '\n' ' ')"
  awk -v ns="${CRED_NS}" -v now="${now}" '
    BEGIN { n = split(now, a, " "); for (i = 1; i <= n; i++) keep[a[i]] = 1 }
    !($1 == ns && !($2 in keep))' <<<"$1"
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

LOGIN_OK=0
login_check() {
  # login_check <description> [kc-login flags...] — a fresh scripted
  # oauth2-proxy/Keycloak login as the admin from the netns; the session stays
  # in ADMIN_JAR for later API calls. Sets LOGIN_OK; always returns 0.
  local desc="$1"
  shift
  rm -f "${ADMIN_JAR}"
  if lan "${E2E_WORK}" "${KCLOGIN}" --cacert "$(ca_file)" --url "${LOGIN_URL}" --user "${ADMIN_USER}" \
       --password-file "$(admin_pw_current)" --new-password-file "${LAN_HOME}/e2e/admin.new" \
       --cookie-jar "${ADMIN_JAR}" "$@"; then
    pass "${desc}"; LOGIN_OK=1
  else
    fail "${desc}"; LOGIN_OK=0
  fi
}

# ---------------------------------------------------------------------------
# the first admin and other users
# ---------------------------------------------------------------------------
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
user_name() { local e; e="$(lower "$1")"; printf '%s' "${e/@/-at-}"; }   # the User CR name admin-user gives an address
set_admin() { ADMIN_EMAIL="$1"; ADMIN_USER="${E2E_ADMIN_USER:-$(lower "$1")}"; }

reset_admin() {
  # a fresh VM: forget the remembered admin and its password files
  rm -f "${STATE}/admin-email" "${LAN_HOME}/e2e"/admin.* "${LAN_HOME}/e2e"/nonadmin.* "${LAN_HOME}/e2e"/*.pw
  [[ -n "${E2E_ADMIN_EMAIL:-}" ]] || set_admin e2e-admin@example.com
}

adopt_owner() {
  # adopt_owner <email> — make <email> the first admin (unless E2E_ADMIN_EMAIL
  # is set) and remember it for later runs (STATE/admin-email)
  [[ -z "${E2E_ADMIN_EMAIL:-}" && -n "$1" ]] || return 0
  set_admin "$1"
  printf '%s\n' "${ADMIN_EMAIL}" > "${STATE}/admin-email"
  tl_log "first admin: ${ADMIN_EMAIL}, the owner of Profile ${TEAMSPACE}"
}

profile_owner() { vm_kc get profiles.teknoir.org "$1" -o jsonpath='{.spec.owner.name}' 2>/dev/null || true; }

bundle_profile_owner() {
  # bundle_profile_owner <bundle-dir> — the owner of Profile TEAMSPACE as the
  # bundle's profile-controller chart renders it (before the Profile exists)
  local dir="$1" helm tgz
  helm="$(command -v helm || true)"
  [[ -n "${helm}" ]] || helm="${dir}/node/bin/helm"
  tgz="$(find "${dir}/node/charts" -maxdepth 1 -name 'profile-controller-*.tgz' -print -quit 2>/dev/null)"
  [[ -x "${helm}" && -n "${tgz}" ]] || return 0
  "${helm}" template e2e "${tgz}" -n teknoir-system 2>/dev/null | awk -v ts="${TEAMSPACE}" '
    function flush() { if (prof && mine && o != "") found = o; prof = 0; mine = 0; inowner = 0; o = "" }
    /^---/ { flush() }
    /^kind: Profile$/ { prof = 1 }
    /^  name: / && !inowner { v = $2; gsub(/"/, "", v); if (v == ts) mine = 1 }
    /^  owner:/ { inowner = 1; next }
    inowner && /^    name:/ { o = $2; inowner = 0 }
    END { flush(); gsub(/"/, "", found); print found }' || true
}

user_reconciled() { [[ -n "$(vm_kc get users.teknoir.org "$1" -o jsonpath='{.status.computed_status}' 2>/dev/null || true)" ]]; }
user_has_legacy_pw() {
  # true while the User carries status.set_initial_password (its value never leaves the VM)
  [[ "$(vm_kc get users.teknoir.org "$1" -o go-template='{{if .status}}{{if .status.set_initial_password}}yes{{end}}{{end}}' 2>/dev/null || true)" == yes ]]
}
user_claims() {
  # user_claims <user> — the User's claim_set as "<name>@<namespace>", space-separated, sorted
  vm_kc get users.teknoir.org "$1" -o jsonpath='{range .spec.claim_set[*]}{.name}@{.namespace}{"\n"}{end}' 2>/dev/null | sort | tr '\n' ' ' || true
}
k1_secret() {
  # k1_secret <user> — the name of the user's temporary-password Secret when it exists (K1)
  vm_kc -n "${CRED_NS}" get secret "user-initial-password-$1" --ignore-not-found -o name 2>/dev/null || true
}
k1_gone() {
  # k1_gone <user> — 0 when the API server answers and the user's K1 Secret is absent
  local v
  v="$(vm_kc -n "${CRED_NS}" get secret "user-initial-password-$1" --ignore-not-found -o name 2>/dev/null)" || return 1
  [[ -z "${v}" ]]
}

copy_initial_password() {
  # copy_initial_password <user> <file> — the temporary password user-controller
  # recorded (the K1 Secret, else the legacy status field) into <file>, 0600;
  # the value goes from the VM's kubectl straight into the file, never printed
  local u="$1" f="$2"
  local b64
  b64="$(vm_kc -n "${CRED_NS}" get secret "user-initial-password-${u}" -o jsonpath='{.data.password}' 2>/dev/null || true)"
  ( umask 077
    if [[ -n "${b64}" ]]; then
      base64 -d <<<"${b64}" > "${f}" 2>/dev/null || : > "${f}"
    else
      vm_kc get users.teknoir.org "${u}" -o go-template='{{if .status}}{{with .status.set_initial_password}}{{.}}{{end}}{{end}}' > "${f}" 2>/dev/null || : > "${f}"
    fi )
  b64=""
  [[ -s "${f}" ]]
}

pw_current() {
  # pw_current <prefix> — <prefix>.new after a forced password change, else <prefix>.pw
  if [[ -s "$1.new" ]]; then printf '%s' "$1.new"; else printf '%s' "$1.pw"; fi
}

kc_login() {
  # kc_login <jar> <url> <user> <password-prefix> [kc-login flags...] — a fresh
  # login from the netns (the jar is replaced); 0 when kc-login.sh reports ok
  local jar="$1" url="$2" user="$3" pre="$4"
  shift 4
  rm -f "${jar}"
  lan "${E2E_WORK}" "${KCLOGIN}" --cacert "$(ca_file)" --url "${url}" --user "${user}" \
    --password-file "$(pw_current "${pre}")" --new-password-file "${pre}.new" --cookie-jar "${jar}" "$@"
}

sso_login() {
  # sso_login <jar> <url> <session-cookie> — sign in to another client (ArgoCD,
  # Harbor) with the Keycloak SSO session in <jar>, no form
  lan "${E2E_WORK}" "${KCLOGIN}" --cacert "$(ca_file)" --cookie-jar "$1" --url "$2" --session-cookie "$3"
}

# ---------------------------------------------------------------------------
# HTTP from the LAN netns (bodies and headers go to private files, never to
# the terminal: they can carry cookies and tokens)
# ---------------------------------------------------------------------------
uri() { jq -rn --arg s "$1" '$s | @uri'; }

lan_curl() {
  # lan_curl <curl args...> — curl in the LAN netns with the fetched CA and
  # HTTP/1.1 (kc-login.sh fetch: the gateway resets HTTP/2 streams after
  # ext_authz's 302). Output goes to the transcript too: use -o/-D/-w.
  lan "${E2E_WORK}" curl -sS --http1.1 -m 30 --cacert "$(ca_file)" "$@"
}

http_req() {
  # http_req <header-file> <body-file> <curl args...> — one request, no
  # redirect followed; prints the HTTP status (000 when none)
  local h="$1" b="$2" out code
  shift 2
  ( umask 077; : > "${h}"; : > "${b}" )
  out="$(lan_curl -D "${h}" -o "${b}" -w '\n%{http_code}' "$@" 2>/dev/null || true)"
  code="$(tail -n1 <<<"${out}")"
  [[ "${code}" =~ ^[0-9]{3}$ ]] || code=000
  printf '%s' "${code}"
}

P_CODE="" P_LOC="" P_HDR="${HTTP_DIR}/probe.hdr" P_BODY="${HTTP_DIR}/probe.body"
probe() {
  # probe <curl args...> — one request without following redirects; sets
  # P_CODE, P_LOC (the Location header) and the files P_HDR / P_BODY
  P_CODE="$(http_req "${P_HDR}" "${P_BODY}" "$@")"
  P_LOC="$(hdr_get "${P_HDR}" location)"
}

app_status() {
  # app_status <jar> <url> — "<status> <final url>" of a GET following
  # redirects with the jar's session (the jar is updated)
  local out
  out="$(lan_curl -L --max-redirs 10 -b "$1" -c "$1" -o /dev/null -w '\n%{http_code} %{url_effective}' "$2" 2>/dev/null || true)"
  out="$(tail -n1 <<<"${out}")"
  [[ "${out}" =~ ^[0-9]{3}\  ]] || out="000 $2"
  printf '%s' "${out}"
}

hdr_get() {
  # hdr_get <header-file> <name> — the value of the last such header (CR
  # stripped), nothing when absent
  awk -v n="$(lower "$2")" '
    { sub(/\r$/, "") }
    { i = index($0, ":"); if (i > 1 && tolower(substr($0, 1, i - 1)) == n) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); last = v } }
    END { if (last != "") print last }' "$1" 2>/dev/null || true
}

expired_cookies() {
  # expired_cookies <header-file> <cookie> — how many Set-Cookie headers clear
  # <cookie>: an empty value with Max-Age=0 or an Expires in 1970
  awk -v c="$2" '
    { sub(/\r$/, "") }
    tolower($0) ~ /^set-cookie:/ {
      v = $0; sub(/^[^:]*:[ \t]*/, "", v); lv = tolower(v)
      if ((index(v, c "=;") == 1 || v == c "=") && (lv ~ /max-age=0/ || lv ~ /expires=[^;]*1970/)) n++
    }
    END { print n + 0 }' "$1" 2>/dev/null || echo 0
}

oauth2_cookie() {
  # the oauth2-proxy session cookie name (--cookie-name of its Deployment)
  vm_kc -n teknoir-auth get deployments -o json 2>/dev/null | jq -r '
    [.items[].spec.template.spec.containers[].args[]? | select(startswith("--cookie-name=")) | sub("^--cookie-name="; "")][0]
    // "_oauth2_proxy"' 2>/dev/null || echo _oauth2_proxy
}

bs_token() {
  # bs_token <jar> <auth-header-file> — Backstage's identity for the jar's
  # oauth2-proxy session (GET /api/auth/istioVerifiedJWT/refresh as an XHR):
  # prints the userEntityRef and writes "Authorization: Bearer <token>" to
  # <auth-header-file> (0600; the token is never printed). 1 without a 200.
  local body="${HTTP_DIR}/refresh.json" code ref
  code="$(http_req "${HTTP_DIR}/refresh.hdr" "${body}" -b "$1" -c "$1" -H 'X-Requested-With: XMLHttpRequest' \
            "https://${DOMAIN}/api/auth/istioVerifiedJWT/refresh")"
  ref=""
  if [[ "${code}" == 200 ]]; then
    ref="$(jq -r '.backstageIdentity.identity.userEntityRef // empty' "${body}" 2>/dev/null || true)"
    ( umask 077; jq -r '"Authorization: Bearer " + (.backstageIdentity.token // "")' "${body}" > "$2" 2>/dev/null || true )
  fi
  rm -f "${body}" "${HTTP_DIR}/refresh.hdr"
  [[ -n "${ref}" ]] || return 1
  printf '%s\n' "${ref}"
}

bs_entity() {
  # bs_entity <jar> <auth-header-file> <kind/namespace/name> <out-file> — HTTP
  # status of the Backstage catalog entity (its JSON in <out-file>)
  http_req "${HTTP_DIR}/entity.hdr" "$4" -b "$1" -c "$1" -H @"$2" "https://${DOMAIN}/api/catalog/entities/by-name/$3"
}

# ---------------------------------------------------------------------------
# reads on the VM (values stay there; only derived results are printed)
# ---------------------------------------------------------------------------
transcript_mark() { wc -c < "${TRANSCRIPT}" | tr -d ' '; }
transcript_since() { tail -c +"$(( $1 + 1 ))" "${TRANSCRIPT}"; }

node_teknoir() {
  # node_teknoir <bundle-dir> <command> [args...] — that bundle's teknoir-node
  # on the node as root with the node's copy of the site, for what the LAN
  # tool does not expose (migrate --finalize); output to the transcript
  local id rc
  id="$(bundle_id "$1")"
  shift
  printf '\n$ [node] teknoir-node %s\n' "$*" >> "${TRANSCRIPT}"
  set +e
  vmx sudo "${NODE_STATE_DIR}/bundles/${id}/node/bin/teknoir-node" "$1" --site "${NODE_STATE_DIR}/site/vmtest.env" "${@:2}" 2>&1 | tee -a "${TRANSCRIPT}"
  rc=${PIPESTATUS[0]}
  set -e
  return "${rc}"
}

kc_prelude() {
  # the head of a VM root script that talks to Keycloak's admin API as the
  # master admin of Secret teknoir-auth/keycloak-admin (credentials in files
  # and curl config, never argv or output): kc_login, kc_get /admin-path
  printf 'DOMAIN=%q NODE_IP=%q\n' "${DOMAIN}" "${NODE_IP}"
  cat <<'EOF'
set -eu
k() { k3s kubectl "$@"; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
chmod 700 "$d"
k -n teknoir-system get secret teknoir-root-ca-bundle -o go-template='{{index .data "ca.crt" | base64decode}}' > "$d/ca"
KC="https://auth.${DOMAIN}/auth"
kc_curl() { curl -sS -m 20 --cacert "$d/ca" --resolve "auth.${DOMAIN}:443:${NODE_IP}" "$@"; }
kc_login() {
  k -n teknoir-auth get secret keycloak-admin -o go-template='{{index .data "username" | base64decode}}' > "$d/u"
  k -n teknoir-auth get secret keycloak-admin -o go-template='{{index .data "password" | base64decode}}' > "$d/p"
  kc_curl -o "$d/tok.json" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
    --data-urlencode "username@$d/u" --data-urlencode "password@$d/p" "$KC/realms/master/protocol/openid-connect/token"
  rm -f "$d/p"
  python3 - "$d/tok.json" "$d/hdr" <<'PY'
import json, os, sys
t = json.load(open(sys.argv[1]))["access_token"]
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, ('header = "Authorization: Bearer %s"\n' % t).encode())
os.close(fd)
PY
  rm -f "$d/tok.json"
}
kc_get() { kc_curl -K "$d/hdr" "$KC/admin$1"; }
EOF
}
kc_vm() { { kc_prelude; cat; } | vm_root; }

kc_user_state() {
  # kc_user_state <realm> <username> — "enabled=<bool> actions=<n>" of a
  # Keycloak user, "absent" when there is none
  {
    printf 'R=%q U=%q\n' "$1" "$2"
    cat <<'EOF'
# vm-script: kc_user_state
kc_login
kc_get "/realms/$R/users?username=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$U")&exact=true" > "$d/users.json"
python3 - "$d/users.json" "$U" <<'PY'
import json, sys
us = [u for u in json.load(open(sys.argv[1])) if u.get("username", "").lower() == sys.argv[2].lower()]
print("absent" if not us else "enabled=%s actions=%d" % (str(us[0].get("enabled")).lower(), len(us[0].get("requiredActions") or [])))
PY
EOF
  } | kc_vm 2>/dev/null || echo unknown
}

kc_master_clients() {
  # "<clients> <code>": how many of the legacy clients teknoir, argocd and
  # harbor realm master still has, and the HTTP status of a
  # client_credentials grant on master with the teknoir client's secret
  # (Secret keycloak-client-secrets; 401 once the client is gone)
  kc_vm 2>/dev/null <<'EOF' || echo "unknown unknown"
# vm-script: kc_master_clients
kc_login
n=0
for c in teknoir argocd harbor; do
  kc_get "/realms/master/clients?clientId=$c" > "$d/c.json"
  n=$((n + $(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1]))))' "$d/c.json")))
done
k -n teknoir-auth get secret keycloak-client-secrets -o go-template='{{index .data "teknoir" | base64decode}}' > "$d/cs"
c="$(kc_curl -o /dev/null -w '%{http_code}' --data-urlencode grant_type=client_credentials --data-urlencode client_id=teknoir \
       --data-urlencode "client_secret@$d/cs" "$KC/realms/master/protocol/openid-connect/token" 2>/dev/null)" || c="${c:-000}"
echo "$n $c"
EOF
}

kc_pw_created() {
  # kc_pw_created <username> — created_date of the user's password credential
  # in realm teknoir, read with a read-only SQL session in keycloak-db-0
  {
    printf 'U=%q\n' "$1"
    cat <<'EOF'
# vm-script: kc_pw_created
k3s kubectl -n teknoir-auth exec -i keycloak-db-0 -c postgres -- \
  env PGOPTIONS='-c default_transaction_read_only=on' U="$U" \
  sh -c 'psql -U "$POSTGRES_USER" -d "${POSTGRES_DB:-keycloak}" -tAq -v ON_ERROR_STOP=1 -v u="$U" -f -' <<'SQL'
SELECT c.created_date FROM credential c
  JOIN user_entity u ON u.id = c.user_id JOIN realm r ON r.id = u.realm_id
 WHERE r.name = 'teknoir' AND lower(u.username) = lower(:'u') AND c.type = 'password';
SQL
EOF
  } | vm_root 2>/dev/null | tr -d ' \r' | grep -E '^[0-9]+$' | head -n1 || true
}

platform_ops_not_succeeded() {
  # platform Applications (ROOT_APP and the Applications it tracks, R2) whose
  # last operation did not succeed, as name=phase
  vm_kc -n teknoir-system get applications.argoproj.io -o json 2>/dev/null | jq -r --arg r "${ROOT_APP}" '
    .items[] | select(.metadata.name == $r or ((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") | startswith($r + ":")))
    | select((.status.operationState.phase // "none") != "Succeeded") | "\(.metadata.name)=\(.status.operationState.phase // "none")"' \
    | sort | tr '\n' ' ' || true
}

admission_ca() {
  # "<configurations> <webhooks without caBundle>" of the monitoring admission
  # webhook configurations (validating + mutating)
  { vm_kc get validatingwebhookconfigurations -o json; vm_kc get mutatingwebhookconfigurations -o json; } 2>/dev/null | jq -rs '
    [.[].items[] | select(.metadata.name | test("^monitoring.*admission$"))] as $c
    | "\($c | length) \([$c[] | .metadata.name as $n | .webhooks[]? | select((.clientConfig.caBundle // "") == "") | "\($n)/\(.name)"] | join(","))"' \
    2>/dev/null || echo "0 unknown"
}

digest_mismatches() {
  # containers whose spec image is pinned by digest but whose running imageID
  # is not that digest (running and completed pods)
  vm_kc get pods -A -o json 2>/dev/null | jq -r '
    .items[] | select(.status.phase == "Running" or .status.phase == "Succeeded") | . as $p
    | [(.status.containerStatuses // [])[], (.status.initContainerStatuses // [])[]] as $ss
    | [(.spec.containers // [])[], (.spec.initContainers // [])[]][] | select(.image | contains("@sha256:")) | . as $c
    | ($c.image | sub("^.*@"; "")) as $dig
    | ([$ss[] | select(.name == $c.name) | .imageID][0] // "") as $id
    | select($id | endswith($dig) | not)
    | "\($p.metadata.namespace)/\($p.metadata.name):\($c.name) imageID=\($id)"' | sort | tr '\n' ' ' || true
}

pod_states() {
  # pod_states <ns> <deployment> — "<uid> <restarts>" of the Deployment's pods
  local sel
  sel="$(vm_kc -n "$1" get deployment "$2" -o json 2>/dev/null | jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")' || true)"
  [[ -n "${sel}" ]] || { echo absent; return 0; }
  vm_kc -n "$1" get pods -l "${sel}" -o json 2>/dev/null | jq -r '
    .items[] | select(.metadata.deletionTimestamp == null)
    | "\(.metadata.uid) \([(.status.containerStatuses // [])[].restartCount] | add // 0)"' | sort || true
}

images_missing() {
  # images_missing [namespace] — pod images (all namespaces, or one) that
  # containerd does not have (imported, or pulled through the Harbor mirror)
  local images ns_args=(-A)
  [[ -z "${1:-}" ]] || ns_args=(-n "$1")
  images="$(vmx sudo k3s crictl images -o json | jq -r '.images[] | (.repoTags[]?, .repoDigests[]?)' | sort -u || true)"
  vm_kc get pods "${ns_args[@]}" -o json | jq -r '.items[].spec | (.containers + (.initContainers // []))[].image' | sort -u |
    while read -r img; do
      grep -qxF -f <(image_names "${img}"; printf '%s\n' "${img}") <<<"${images}" || echo "${img}"
    done
}

image_check_ok() {
  # image_check_ok <text> — post's line "live image check: N pullable ..., 0 missing"
  grep -qE 'live image check: [0-9]+ pullable.*(^|[^0-9])0 missing' <<<"$1"
}

can_i() {
  # can_i <namespace/serviceaccount> <kubectl auth can-i args...> — yes or no
  local sa="$1"
  shift
  vm_kc auth can-i "$@" --as="system:serviceaccount:${sa%%/*}:${sa#*/}" </dev/null 2>/dev/null | tail -n1 || true
}
controller_sa() {
  # controller_sa <deployment> — "teknoir-system/<its service account>"
  local sa
  sa="$(vm_kc -n teknoir-system get deployment "$1" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
  printf 'teknoir-system/%s' "${sa:-$1}"
}

skew_now() {
  # the node clock minus this host's, in seconds (3 decimals); the ssh round
  # trip is halved out
  local a n b
  a="$(date +%s.%N)"; n="$(vmx date +%s.%N 2>/dev/null || echo 0)"; b="$(date +%s.%N)"
  awk -v a="${a}" -v b="${b}" -v n="${n}" 'BEGIN { printf "%.3f\n", n - (a + b) / 2 }'
}
abs_le() { awk -v v="$1" -v m="$2" 'BEGIN { if (v < 0) v = -v; exit !(v <= m) }'; }
skew_within() { abs_le "$(skew_now)" "$1"; }
rtc_offset() {
  # the node's RTC minus its system clock, whole seconds ("none" without an RTC)
  vm_root 2>/dev/null <<'EOF' || echo none
f=/sys/class/rtc/rtc0/since_epoch
if [ -r "$f" ]; then echo $(( $(cat "$f") - $(date +%s) )); else echo none; fi
EOF
}
dpkg_state() {
  # every package with version and status, and the dpkg log length: equal
  # before and after an up that changed no package
  # shellcheck disable=SC2016  # dpkg-query's own ${...} fields, for the VM's sh
  vmx sudo sh -c 'dpkg-query -W -f "\${Package} \${Version} \${db:Status-Abbrev}\n" | sha256sum | cut -c1-16; wc -l < /var/log/dpkg.log' 2>/dev/null | tr '\n' ' ' || true
}

age_bin() {
  # age_bin <bundle-dir> — the age binary to decrypt with
  local a="${E2E_AGE:-$(command -v age || true)}"
  [[ -n "${a}" ]] || a="$1/node/bin/age"
  [[ -x "${a}" ]] && printf '%s' "${a}"
}

lan_secret_patterns() {
  # the secret values the LAN side holds, one per line, for E7: passwords from
  # admin-user, kc-login and credentials, and the test age identities
  local f
  # (a value file may lack its final newline: kc-login.sh writes none)
  for f in "${LAN_HOME}"/e2e/*.pw "${LAN_HOME}"/e2e/*.new; do
    [[ -s "${f}" ]] && printf '%s\n' "$(head -n1 "${f}")"
  done
  for f in "${AGE_ID_DIR}"/*.key; do
    [[ -s "${f}" ]] && grep -h '^AGE-SECRET-KEY-' "${f}"
  done
  return 0
}

# ---------------------------------------------------------------------------
# E1
# ---------------------------------------------------------------------------
url_host() { sed -E 's|^https?://([^/:?#]+).*|\1|' <<<"$1"; }

e1_baseline() {
  # e1_baseline <bundle-dir> — 0 when E1 installs a pre-r5 baseline (bundle A
  # of the upgrade run): E2E_E1_BASELINE=1, or auto (the default) and the
  # bundle's app-of-apps is older than R5_AOA. E2E_E1_BASELINE=0 keeps every
  # check strict.
  case "${E2E_E1_BASELINE:-auto}" in
    1) return 0 ;;
    0) return 1 ;;
    auto) ! bundle_is_r5 "$1" ;;
    *) tl_die "E2E_E1_BASELINE must be auto, 0 or 1 (got ${E2E_E1_BASELINE})" ;;
  esac
}

r5_eq() {
  # r5_eq <msg> <want> <got> — assert_eq for an assertion that only release r5
  # satisfies; on a pre-r5 baseline (R5_SOFT set) a mismatch is a warning
  if [[ -z "${R5_SOFT}" || "$2" == "$3" ]]; then assert_eq "$@"; return 0; fi
  tl_warn "${R5_SOFT}, not asserted: $1: want [$2] got [$3]"
}
r5_fail() {
  # r5_fail <msg> — fail, or on a pre-r5 baseline (R5_SOFT) a warning
  if [[ -z "${R5_SOFT}" ]]; then fail "$*"; else tl_warn "${R5_SOFT}, not asserted: $*"; fi
}

platform_checks() {
  # platform_checks <output of up> — release-level assertions shared by E1, E4
  # and E15 (after wait_apps). The operation, caBundle and digest checks are
  # r5's (HYG, K5): on E1's pre-r5 baseline they only warn.
  local out="$1" v
  if image_check_ok "${out}"; then pass "post: live image check reports N pullable, 0 missing"
  else fail "post did not report 'live image check: N pullable ..., 0 missing'"; fi
  r5_eq "every platform Application's last operation Succeeded" "" "$(platform_ops_not_succeeded)"
  v="$(admission_ca)"
  r5_eq "the monitoring admission webhook configurations exist (validating, mutating)" 2 "${v%% *}"
  r5_eq "every monitoring admission webhook has a caBundle" "" "${v#* }"
  r5_eq "every digest-pinned container runs that digest (imageID)" "" "$(digest_mismatches)"
}

oauth2_start_check() {
  probe "https://${DOMAIN}/oauth2/start?rd=%2F"
  if [[ "${P_CODE}" == 302 && "$(url_host "${P_LOC}")" == "auth.${DOMAIN}" ]]; then
    pass "/oauth2/start redirects to auth.${DOMAIN} (the /oauth2 route precedes the catch-all)"
  else
    fail "/oauth2/start: HTTP ${P_CODE} to ${P_LOC%%\?*}, want 302 to auth.${DOMAIN}"
  fi
}

backstage_identity_check() {
  # backstage_identity_check <user> — with the admin's session, Backstage
  # resolves the sign-in to user:default/<user> within 3 min of the User's
  # creation (PT1M user ingestion; admin-user waited for the catalog)
  local name="$1" created deadline ref="" hdr="${HTTP_DIR}/bs.auth"
  created="$(vm_kc get users.teknoir.org "${name}" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)"
  deadline=$(( $(date -d "${created:-now}" +%s 2>/dev/null || date +%s) + 180 ))
  while :; do
    ref="$(bs_token "${ADMIN_JAR}" "${hdr}" || true)"
    [[ "${ref}" == "user:default/${name}" ]] && break
    (( $(date +%s) < deadline )) || break
    sleep 10
  done
  rm -f "${hdr}"
  r5_eq "Backstage signs ${ADMIN_USER} in as user:default/${name} within 3 min of the User's creation" "user:default/${name}" "${ref}"
}

e1() {
  tl_case E1 "fresh bootstrap from the extracted tar in the LAN netns"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  fresh_vm || return 0
  rm -rf "${LAN_HOME:?}/.teknoir-airgap"
  reset_admin
  local dir aoa
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  aoa="$(bundle_aoa "${dir}")"
  R5_SOFT=""
  if e1_baseline "${dir}"; then
    # the upgrade run's bundle A (E1, then E4 to B): A predates r5, so the
    # r5-only assertions (the K1 handover, no Update Profile form, the
    # Backstage identity without a restart, operations, caBundle, digest pins)
    # only warn here; E4 asserts the release-level ones after the update to B
    if [[ "${E2E_E1_BASELINE:-auto}" == 1 ]]; then R5_SOFT="baseline (E2E_E1_BASELINE=1, app-of-apps ${aoa:-unknown})"
    else R5_SOFT="baseline app-of-apps ${aoa} < ${R5_AOA}"; fi
    tl_log "the bundle predates r5 (${R5_SOFT}; E2E_E1_BASELINE=${E2E_E1_BASELINE:-auto}): the r5-only checks warn"
  fi
  e1_body "${dir}"
  R5_SOFT=""
}

e1_body() {
  local dir="$1" mark out
  dotdirs > "${STATE}/dotdirs.before"
  mark="$(transcript_mark)"
  if up_in "${dir}"; then pass "teknoir-airgap up exits 0 on a fresh node"; else fail "teknoir-airgap up failed"; return 0; fi
  out="$(transcript_since "${mark}")"
  wait_apps 2700 || true
  if [[ -n "$(ca_file)" ]]; then pass "the CA certificate was fetched to ${LAN_HOME}/.teknoir-airgap/<site>/"; else fail "no teknoir-root-ca.crt under ${LAN_HOME}/.teknoir-airgap"; return 0; fi
  assert_eq "https://harbor.${DOMAIN}/api/v2.0/health with the CA" 200 "$(lan_https "https://harbor.${DOMAIN}/api/v2.0/health")"
  assert_eq "https://argocd.${DOMAIN} with the CA" 200 "$(lan_https "https://argocd.${DOMAIN}/")"
  assert_eq "Keycloak master realm discovery with the CA" 200 "$(lan_https "https://auth.${DOMAIN}/auth/realms/master/.well-known/openid-configuration")"
  assert_eq "Keycloak realm teknoir discovery with the CA (D2)" 200 "$(lan_https "https://auth.${DOMAIN}/auth/realms/teknoir/.well-known/openid-configuration")"
  platform_checks "${out}"
  oauth2_start_check
  # the first platform admin (DESIGN C.5): a superadmin User CR, its Keycloak
  # user (realm teknoir, group admin) and a temporary password in a 0600 file;
  # by default the owner of the GitOps Profile, so E11 can check its grants
  adopt_owner "$(profile_owner "${TEAMSPACE}")"
  local pw="${LAN_HOME}/e2e/admin.pw" mode name bs0 bs1
  name="$(user_name "${ADMIN_EMAIL}")"
  bs0="$(pod_states teknoir-system backstage-api)"
  if tk "${dir}" admin-user --email "${ADMIN_EMAIL}" --out "${pw}"; then
    mode="$(stat -c %a "${pw}" 2>/dev/null || echo missing)"
    assert_eq "admin-user --out writes the temporary password to a 0600 file" 600 "${mode}"
  else
    fail "teknoir-airgap admin-user --email ${ADMIN_EMAIL} --out failed"; return 0
  fi
  [[ -s "${pw}" ]] || { fail "admin-user wrote no temporary password to ${pw}"; return 0; }
  if user_has_legacy_pw "${name}"; then r5_fail "User ${name} still carries status.set_initial_password after admin-user"
  else pass "User ${name} carries no status.set_initial_password"; fi
  r5_eq "the temporary-password Secret ${CRED_NS}/user-initial-password-${name} is gone after the handover" "" "$(k1_secret "${name}")"
  # r5 drops VERIFY_PROFILE (K6): the login must not meet the Update Profile
  # form. A pre-r5 realm still shows it to a user without a last name, so the
  # baseline login answers it (kc-login.sh does unless --forbid-profile-form).
  local form=(--forbid-profile-form) how="no Update Profile form"
  if [[ -n "${R5_SOFT}" ]]; then
    form=() how="the Update Profile form answered (${R5_SOFT})"
    tl_warn "${R5_SOFT}, not asserted: the login may meet the Update Profile form (VERIFY_PROFILE)"
  fi
  login_check "oauth2-proxy login as ${ADMIN_USER} at ${LOGIN_URL} with the --out password (the forced change handled, ${how})" \
    "${form[@]}"
  if (( LOGIN_OK )); then backstage_identity_check "${name}"; else r5_fail "Backstage identity not checked: no session"; fi
  bs1="$(pod_states teknoir-system backstage-api)"
  r5_eq "admin-user restarted no backstage-api pod" "${bs0}" "${bs1}"
  r5_eq "backstage-api never restarted (restartCount 0 since its first start)" "" "$(awk '$2 != 0 || $1 == "absent"' <<<"${bs1}")"
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
  local dir pods secrets since t0 out rc puts ts_ops ts_secrets pc
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  pods="$(snap_pods)" secrets="$(snap_secret_rvs)" since="$(k3s_since)"
  ts_ops="$(teamspace_ops)" ts_secrets="$(teamspace_secret_rvs)" pc="$(pod_states teknoir-system profile-controller)"
  t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  set +e; out="$(up_in "${dir}")"; rc=$?; set -e
  assert_eq "the second up exits 0" 0 "${rc}"
  if grep -qiE "${ZERO_RE}" <<<"${out}"; then pass "the converge summary reports 0 changes"
  else fail "the summary does not match /${ZERO_RE}/:"; tail -15 <<<"${out}" >&2; fi
  assert_eq "pod UIDs unchanged" "${pods}" "$(snap_pods)"
  assert_eq "k3s ActiveEnterTimestamp unchanged (no restart)" "${since}" "$(k3s_since)"
  local secrets1 kept
  secrets1="$(snap_secret_rvs)"
  kept="$(drop_cred_deletions "${secrets}" "${secrets1}")"
  [[ "${kept}" == "${secrets}" ]] || tl_log "user-controller deleted temporary-password Secrets during the run (K1, not up's doing): $(added_lines "${kept}" "${secrets}" | awk '{print $2}' | tr '\n' ' ')"
  assert_eq "Secret resourceVersions unchanged (only user-controller's K1 deletions in ${CRED_NS} allowed)" "${kept}" "${secrets1}"
  puts="$(harbor_blob_puts_since "${t0}")"
  assert_eq "Harbor received 0 blob uploads" 0 "${puts}"
  if [[ -n "${ts_ops}" ]]; then
    assert_eq "the ${TEAMSPACE} Applications were not synced again (operationState.finishedAt)" "${ts_ops}" "$(teamspace_ops)"
  else
    fail "no ${TEAMSPACE}-* Application to compare"
  fi
  assert_eq "the ${TEAMSPACE} Secrets kept their resourceVersions (no credential regenerated)" "${ts_secrets}" "$(teamspace_secret_rvs)"
  assert_eq "profile-controller did not restart (pod UID, restartCount)" "${pc}" "$(pod_states teknoir-system profile-controller)"
}

teamspace_ops() {
  # "<app> <finishedAt>" of the teamspace's Applications
  vm_kc -n teknoir-system get applications.argoproj.io -o json 2>/dev/null | jq -r --arg p "${TEAMSPACE}-" '
    .items[] | select(.metadata.name | startswith($p)) | "\(.metadata.name) \(.status.operationState.finishedAt // "none")"' | sort || true
}
teamspace_secret_rvs() {
  vm_kc -n "${TEAMSPACE}" get secrets --no-headers -o custom-columns=NAME:.metadata.name,RV:.metadata.resourceVersion 2>/dev/null | sort || true
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
  local before after bad
  before="$(forward_drops)"
  assert_not_cmd "VM: https://registry-1.docker.io/v2/ is unreachable" vmx curl -sS -m 5 -o /dev/null https://registry-1.docker.io/v2/
  assert_not_cmd "VM: github.com does not resolve" vmx getent hosts github.com
  # A host route via the bridge address (the rig host) makes the VM and the namespace actually send
  # packets towards the internet, so the FORWARD DROP counters must grow.
  vmx sudo ip route replace 1.1.1.1/32 via 10.77.0.1 >/dev/null
  assert_not_cmd "VM: https://1.1.1.1 via the rig host is dropped" vmx curl -sS -m 5 -o /dev/null https://1.1.1.1/
  vmx sudo ip route del 1.1.1.1/32 >/dev/null || true
  "${NETNS}" exec --root ip route replace 1.1.1.1/32 via 10.77.0.1
  assert_not_cmd "netns: https://1.1.1.1 via the rig host is dropped" lan "${E2E_WORK}" curl -sS -m 5 -o /dev/null https://1.1.1.1/
  "${NETNS}" exec --root ip route del 1.1.1.1/32 || true
  assert_not_cmd "netns: a public name does not resolve" lan "${E2E_WORK}" getent hosts github.com
  after="$(forward_drops)"
  if (( after > before )); then pass "rig host FORWARD DROP counters for tkvm0 grew (${before} -> ${after})"
  else fail "FORWARD DROP counters did not grow (${before} -> ${after})"; fi
  bad="$(images_missing)"
  assert_eq "every pod image is present in containerd (imported, or pulled through the harbor.${DOMAIN} mirror)" "" "${bad}"
  assert_eq "no ErrImagePull/ImagePullBackOff events (boot-time Harbor 503s after E12's reboot aside)" 0 "$(pull_failures -A)"
  assert_eq "no pod is waiting in ErrImagePull/ImagePullBackOff" 0 "$(pull_waiting -A)"
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
  [[ -n "${E2E_E4_APPS:-}" ]] || { skip_case "E2E_E4_APPS required: the Applications bundle B changes (\"app-of-apps device-controller\", or auto)"; return 0; }
  ensure_vm
  local a b ida idb before after changed want out rc mark kept name
  a="$(bundle_dir "${E2E_BUNDLE}")" b="$(bundle_dir "${E2E_BUNDLE_B}")"
  ida="$(bundle_id "${a}")" idb="$(bundle_id "${b}")"
  wait_until 1800 apps_healthy || true
  before="$(app_revs)"
  if [[ "${E2E_E4_APPS}" == auto ]]; then
    want="$(e4_expected_apps "${a}" "${b}" "$(awk '{print $1}' <<<"${before}")")"
    tl_log "E2E_E4_APPS=auto: B should change ${want:-nothing}"
  else
    want="$(tr ' ' '\n' <<<"${E2E_E4_APPS}" | grep . | sort -u | tr '\n' ' ')"
  fi
  mark="$(transcript_mark)"
  if up_in "${b}"; then pass "up with bundle B exits 0"; else fail "up with bundle B failed"; return 0; fi
  out="$(transcript_since "${mark}")"
  wait_apps 1800 || true
  after="$(app_revs)"
  changed="$(added_lines "${before}" "${after}" | awk '{print $1}' | sort -u | tr '\n' ' ')"
  assert_eq "the Applications bundle B changed are exactly E2E_E4_APPS" "${want}" "${changed}"
  assert_eq "the release record is bundle B, mode update" "${idb} update" "$(release_state)"
  platform_checks "${out}"
  assert_eq "https://harbor.${DOMAIN}/api/v2.0/health after the update" 200 "$(lan_https "https://harbor.${DOMAIN}/api/v2.0/health")"
  # an admin made on a pre-r5 A kept the legacy status.set_initial_password
  # (E1 only warned); r5's user-controller clears it without a password change
  name="$(user_name "${ADMIN_EMAIL}")"
  if bundle_is_r5 "${b}" && user_reconciled "${name}"; then
    if wait_until 300 not_legacy "${name}"; then pass "after B: User ${name} carries no status.set_initial_password"
    else fail "after B: User ${name} still carries status.set_initial_password"; fi
  fi
  if [[ -s "$(admin_pw_current)" ]]; then
    login_check "the admin still signs in after the update (Keycloak database kept)"
  else
    tl_warn "no admin password file (run E1 first): the sign-in after the update is not checked"
  fi
  set +e; out="$(up_in "${a}")"; rc=$?; set -e
  if (( rc != 0 )) && grep -qi rollback <<<"${out}"; then pass "up with the older bundle A is refused (and mentions --rollback)"
  else fail "up with the older bundle A was not refused (rc=${rc})"; fi
  assert_eq "the refused run left the release record at B" "${idb} update" "$(release_state)"
  assert_eq "the refused run left every Application at B" "${after}" "$(app_revs)"
  case "$(e4_rollback_mode "${a}" "${b}")" in
    off)
      # an explicit waiver: the summary row says so
      tl_warn "E2E_E4_ROLLBACK=0: the rollback to A is waived, not rehearsed"
      TL_CASE_DESC+=" (rollback leg waived: E2E_E4_ROLLBACK=0)"
      return 0 ;;
    gap)
      # an untested rollback is not green: run it (1) or waive it on purpose (0)
      tl_warn "the rollback to A would cross r5: ${E4_ROLLBACK_GAP}"
      fail "the rollback from the r5 B to the pre-r5 A is not rehearsed: set E2E_E4_ROLLBACK=1 to run it (each part asserted) or E2E_E4_ROLLBACK=0 to waive it on purpose"
      return 0 ;;
    cross) e4_rollback_cross "${a}" "${ida}" "${before}"; return 0 ;;
  esac
  if up_in "${a}" --rollback; then pass "up --rollback with A exits 0"; else fail "up --rollback with A failed"; return 0; fi
  wait_apps 1800 || true
  assert_eq "the release record is bundle A, mode rollback" "${ida} rollback" "$(release_state)"
  # Applications B added and A does not render stay when their owner keeps
  # them (a GitOps Profile is Prune=false,Delete=false): reported, not compared
  kept="$(added_lines "$(awk '{print $1}' <<<"${before}")" "$(app_revs | awk '{print $1}')" | tr '\n' ' ')"
  [[ -z "${kept// /}" ]] || tl_log "Applications added by B and kept after the rollback: ${kept}"
  assert_eq "every Application is back at its revision before B" "${before}" "$(app_revs_known "${before}")"
  if up_in "${a}"; then pass "a plain up with A after the rollback exits 0"; else fail "plain up with A after the rollback failed"; fi
  wait_apps 900 || true
  assert_eq "a plain up with A keeps A in rollback mode (no roll-forward)" "${ida} rollback" "$(release_state)"
  assert_eq "a plain up with A leaves every Application at A" "${before}" "$(app_revs_known "${before}")"
}

# A rollback from r5 to a pre-r5 bundle meets state that A neither renders nor
# prunes. Until the rollback design settles it (WP-G-CTRL, WP-I-RELEASE,
# WP-I-BUNDLE), that leg fails E4 unless it is run (E2E_E4_ROLLBACK=1, each
# part asserted) or waived on purpose (E2E_E4_ROLLBACK=0).
E4_ROLLBACK_GAP="B (r5) adds the GitOps Profile ${TEAMSPACE} and the Namespace ${CRED_NS}, both Prune=false,Delete=false \
without IgnoreExtraneous, so after a rollback to a pre-r5 A the profile-controller and user-controller Applications stay \
OutOfSync (pruning skipped); A's profile-controller points the ${TEAMSPACE}-* Applications back at github.io (Unknown \
offline), and A's post waits for every Application to be Synced/Healthy. Open rollback-design gap."

e4_rollback_mode() {
  # e4_rollback_mode <dir A> <dir B> — what E4 does after the refused A:
  #   off    E2E_E4_ROLLBACK=0: waived (the summary row says so)
  #   gap    auto (the default) and B is r5 while A predates it: not run, and
  #          E4 fails (an untested rollback is not green)
  #   cross  E2E_E4_ROLLBACK=1 and that same r5 -> pre-r5 rollback: run, and
  #          assert the state the rollback design must reach
  #   run    otherwise: the plain rollback (A and B on the same side of r5)
  local crosses=0
  if bundle_is_r5 "$2" && ! bundle_is_r5 "$1"; then crosses=1; fi
  case "${E2E_E4_ROLLBACK:-auto}" in
    0) echo off ;;
    1) if (( crosses )); then echo cross; else echo run; fi ;;
    auto) if (( crosses )); then echo gap; else echo run; fi ;;
    *) tl_die "E2E_E4_ROLLBACK must be auto, 0 or 1 (got ${E2E_E4_ROLLBACK})" ;;
  esac
}

app_sync() {
  # app_sync <application> — "<sync>/<health>" ("absent" when it does not exist)
  local s
  s="$(vm_kc -n teknoir-system get applications.argoproj.io "$1" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  printf '%s' "${s:-absent}"
}
ts_apps_report() {
  # ts_apps_report <teamspace> — "<app>=<sync>/<health>@<repoURL>" of its Applications
  vm_kc -n teknoir-system get applications.argoproj.io -o json 2>/dev/null | jq -r --arg p "$1-" '
    .items[] | select(.metadata.name | startswith($p))
    | "\(.metadata.name)=\(.status.sync.status // "none")/\(.status.health.status // "none")@\(.spec.source.repoURL // "")"' \
    | sort | tr '\n' ' ' || true
}

e4_rollback_cross() {
  # e4_rollback_cross <dir A> <bundle id A> <app_revs before B> — the r5 ->
  # pre-r5 rollback (E2E_E4_ROLLBACK=1): every step is asserted and nothing
  # stops at the first failure, so the run names which part of the gap is open
  local a="$1" ida="$2" before="$3" rc app
  tl_log "rollback across r5 (E2E_E4_ROLLBACK=1); known gap: ${E4_ROLLBACK_GAP}"
  set +e; up_in "${a}" --rollback; rc=$?; set -e
  if (( rc == 0 )); then pass "up --rollback with the pre-r5 A exits 0"
  else fail "up --rollback with the pre-r5 A failed (rc=${rc}); the Application states follow"; fi
  if wait_until 1800 apps_healthy_except "${TEAMSPACE}-"; then pass "every Application but ${TEAMSPACE}-* is Synced/Healthy after the rollback"
  else fail "after the rollback, not Synced/Healthy: $(apps_unhealthy_except "${TEAMSPACE}-")"; fi
  for app in profile-controller user-controller; do
    assert_eq "${app} is Synced/Healthy after the rollback (its kept r5 object is ignored, not pending a prune)" \
      Synced/Healthy "$(app_sync "${app}")"
  done
  if vm_kc get profiles.teknoir.org "${TEAMSPACE}" -o name >/dev/null 2>&1; then pass "Profile ${TEAMSPACE} is kept (a rollback deletes no teamspace)"
  else fail "Profile ${TEAMSPACE} is gone after the rollback"; fi
  if vm_kc get namespace "${CRED_NS}" -o name >/dev/null 2>&1; then pass "Namespace ${CRED_NS} is kept (Prune=false,Delete=false)"
  else fail "Namespace ${CRED_NS} is gone after the rollback"; fi
  tl_log "the ${TEAMSPACE} Applications after the rollback: $(ts_apps_report "${TEAMSPACE}")"
  assert_eq "the release record is bundle A, mode rollback" "${ida} rollback" "$(release_state)"
  assert_eq "every Application is back at its revision before B" "${before}" "$(app_revs_known "${before}")"
  (( rc == 0 )) || return 0
  if up_in "${a}"; then pass "a plain up with A after the rollback exits 0"; else fail "plain up with A after the rollback failed"; fi
  assert_eq "a plain up with A keeps A in rollback mode (no roll-forward)" "${ida} rollback" "$(release_state)"
}

bundle_pins() {
  # bundle_pins <bundle-dir> — "<chart> <version>" lines of node/charts/pins.txt
  [[ -f "$1/node/charts/pins.txt" ]] && awk 'NF >= 2 && $1 !~ /^#/ {print $1, $2}' "$1/node/charts/pins.txt"
  return 0
}
e4_expected_apps() {
  # e4_expected_apps <dir A> <dir B> <Application names before B> — what B
  # should change (E2E_E4_APPS=auto): ROOT_APP and every existing Application
  # whose chart pin differs between A and B (an Application is named after its
  # chart), plus the plugin Applications of the GitOps Profile when B adds it
  local names="$3" p
  {
    awk -v root="${ROOT_APP}" -v names="$(tr '\n' ' ' <<<"${names}")" '
      BEGIN { n = split(names, x, " "); for (i = 1; i <= n; i++) known[x[i]] = 1 }
      FNR == NR { va[$1] = $2; next }
      ($1 == root || $1 in known) && va[$1] != $2 { print $1 }' <(bundle_pins "$1") <(bundle_pins "$2")
    if [[ -n "$(bundle_profile_owner "$2")" ]] && ! grep -q "^${TEAMSPACE}-" <<<"${names}"; then
      for p in "${PLUGINS[@]}"; do echo "${TEAMSPACE}-${p}"; done
    fi
  } | sort -u | tr '\n' ' '
}

app_revs_known() {
  # app_revs_known <earlier app_revs> — app_revs of the Applications listed in <earlier> only
  app_revs | awk -v names="$(awk '{print $1}' <<<"$1" | tr '\n' ' ')" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 } $1 in w'
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
  local res lanpat="${HTTP_DIR}/lan-secrets.pat" idpat="${HTTP_DIR}/age-ids.pat" n
  # values the LAN side holds: the passwords (the VM's own credentials) are
  # scanned on the VM like the Secrets; the test age identities never go to
  # the VM, so they are scanned here, and the node is searched for any age
  # identity by its format
  ( umask 077
    lan_secret_patterns | grep -v '^AGE-SECRET-KEY-' | awk 'length > 13' > "${lanpat}" || true
    lan_secret_patterns | grep '^AGE-SECRET-KEY-' > "${idpat}" || true )
  if [[ -s "${idpat}" ]]; then
    n="$(grep -acFf "${idpat}" "${TRANSCRIPT}" || true)"
    assert_eq "no test age identity in the LAN transcript" 0 "${n:-0}"
  fi
  rm -f "${idpat}"
  vm_upload /tmp/e2e-lan-secrets.pat < "${lanpat}"
  rm -f "${lanpat}"
  vm_upload /tmp/e2e-transcript.log < "${TRANSCRIPT}"
  # The scan runs on the VM: values are read and compared there, never printed.
  res="$(vm_root <<'EOF'
set -eu
T=/tmp/e2e-transcript.log L=/tmp/e2e-lan-secrets.pat
k() { k3s kubectl "$@"; }
files="$T $(ls /var/log/teknoir-airgap/*.log 2>/dev/null | tr '\n' ' ')"
checked=0 leaks=0
pat="$(mktemp)" val="$(mktemp)"; trap 'rm -f "$pat" "$val" "$T" "$L"' EXIT; chmod 600 "$pat" "$val"
for ns in $(k get ns -o jsonpath='{.items[*].metadata.name}'); do
  case "$ns" in teknoir-*|cert-manager|istio-system) ;; *) continue ;; esac
  for s in $(k -n "$ns" get secrets -o jsonpath='{range .items[?(@.type!="kubernetes.io/service-account-token")]}{.metadata.name}{"\n"}{end}'); do
    case "$s" in sh.helm.release.*) continue ;; esac
    # ArgoCD repository Secrets: url, type, name, ... are the repository's
    # address and settings (logged by design); only their credentials count
    stype="$(k -n "$ns" get secret "$s" -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}')"
    for key in $(k -n "$ns" get secret "$s" -o json | python3 -c 'import json,sys; print("\n".join((json.load(sys.stdin).get("data") or {}).keys()))'); do
      # *Mtime: ArgoCD's admin.passwordMtime is a timestamp (when the password changed), logged by design
      case "$key" in *.crt|ca.pem|*_USER|*USERNAME|username|user|KEYCLOAK_REALM|KEYCLOAK_CLIENTID|*Mtime) continue ;; esac
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
lan_checked=0 lan_leaks=0
if [ -s "$L" ]; then
  lan_checked=$(grep -c . "$L")
  # shellcheck disable=SC2086  # $files is a list
  lan_leaks=$(cat $files 2>/dev/null | grep -acFf "$L" || true)
fi
echo "lan_checked=$lan_checked lan_leaks=${lan_leaks:-0}"
age_ids=$(grep -rlsaE --exclude-dir=bundles 'AGE-SECRET-KEY-1[02-9ACDEFGHJKLMNPQRSTUVWXYZ]{58}' \
  /var/lib/teknoir-airgap /var/log/teknoir-airgap /root /home /etc 2>/dev/null | wc -l)
echo "age_ids=$age_ids"
EOF
)"
  printf '%s\n' "${res}" >&2
  if grep -q '^checked=[1-9]' <<<"${res}"; then pass "scanned $(sed -n 's/^checked=\([0-9]*\).*/\1/p' <<<"${res}") Secret values on the VM"
  else fail "no Secret values were scanned"; fi
  assert_eq "no Secret value appears in the LAN transcript or the node logs" 0 "$(sed -n 's/^checked=[0-9]* leaks=\([0-9]*\)$/\1/p' <<<"${res}")"
  tl_log "LAN-side values scanned: $(sed -n 's/^lan_checked=\([0-9]*\).*/\1/p' <<<"${res}") (admin-user, kc-login, credentials, non-admin passwords)"
  assert_eq "no value the LAN side holds (passwords from admin-user, kc-login, credentials) in the transcript or the node logs" 0 \
    "$(sed -n 's/^lan_checked=[0-9]* lan_leaks=\([0-9]*\)$/\1/p' <<<"${res}")"
  assert_eq "no age identity on the node (/var/lib/teknoir-airgap but bundles, logs, /root, /home, /etc)" 0 \
    "$(sed -n 's/^age_ids=\([0-9]*\)$/\1/p' <<<"${res}")"
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
    assert_eq "no age identity in a plain file of $(basename "${t}")" "" \
      "$(find "${d}" -type f ! -path '*/node/images/*/blobs/*' ! -path '*/node/bootstrap-images/*' ! -name 'k3s-airgap-images-*' -print0 \
         | xargs -0 -r grep -laE -- 'AGE-SECRET-KEY-1[02-9ACDEFGHJKLMNPQRSTUVWXYZ]{58}' | sed "s|^${d}/||" | tr '\n' ' ' || true)"
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
  local dir before after changed pods_before pods_after old_jar="${LAN_HOME}/e2e/pre-rotation.jar"
  dir="$(bundle_dir "${E2E_BUNDLE}")"
  # a session from before the rotation, to replay afterwards
  login_check "a session before the rotation"
  rm -f "${old_jar}"
  if (( LOGIN_OK )); then ( umask 077; cp "${ADMIN_JAR}" "${old_jar}" ); fi
  before="$(snap_secret_rvs)"
  pods_before="$(vm_kc -n teknoir-auth get pods -l "${E2E_OAUTH2_PROXY_SELECTOR:-app=oauth2-proxy}" -o jsonpath='{.items[*].metadata.uid}')"
  if tk "${dir}" rotate oauth2-proxy-cookie; then pass "rotate oauth2-proxy-cookie exits 0"; else fail "rotate failed"; return 0; fi
  wait_apps 900 || true
  after="$(snap_secret_rvs)"
  changed="$(added_lines "${before}" "${after}" | awk '{print $1 "/" $2}' | sort -u | tr '\n' ' ')"
  assert_eq "only teknoir-auth/oauth2-proxy-secret changed" "teknoir-auth/oauth2-proxy-secret " "${changed}"
  pods_after="$(vm_kc -n teknoir-auth get pods -l "${E2E_OAUTH2_PROXY_SELECTOR:-app=oauth2-proxy}" -o jsonpath='{.items[*].metadata.uid}')"
  if [[ -n "${pods_after}" && "${pods_after}" != "${pods_before}" ]]; then pass "oauth2-proxy pods were replaced"; else fail "oauth2-proxy did not roll"; fi
  if [[ -s "${old_jar}" ]]; then
    # the old cookie no longer decrypts: ext_authz denies, and the gateway
    # turns the denial into a login redirect instead of a bare 403 (SIGN-C2)
    probe -b "${old_jar}" "https://${DOMAIN}/"
    if [[ "${P_CODE}" == 302 && "${P_LOC}" == *"/oauth2/start"* ]]; then pass "the pre-rotation cookie gets 302 to /oauth2/start (not 403)"
    else fail "the pre-rotation cookie got HTTP ${P_CODE} to ${P_LOC%%\?*}, want 302 to /oauth2/start"; fi
    rm -f "${old_jar}" "${P_HDR}" "${P_BODY}"
  else
    fail "no pre-rotation session to replay"
  fi
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

skip_guards() { vmx sudo ls /opt/k3s/server/manifests | grep -E '\.skip$' | tr '\n' ' ' || true; }
retired_exists() { vmx sudo test -e /opt/k3s/server/manifests-retired; }

e10_finalize() {
  # e10_finalize <bundle-dir> — a backup on the node (with the site's age
  # recipients it leaves an encrypted export newer than the migration), then
  # `teknoir-node migrate --finalize`: the retired K3s files are gone, the
  # .skip guards stay
  local dir="$1" skips0
  skips0="$(skip_guards)"
  if retired_exists; then pass "manifests-retired exists before the finalize"; else fail "no manifests-retired to finalize"; fi
  if node_teknoir "${dir}" backup >/dev/null; then pass "a node backup (encrypted export) before the finalize"
  else fail "the node backup before the finalize failed"; fi
  if node_teknoir "${dir}" migrate --finalize; then pass "migrate --finalize exits 0"; else fail "migrate --finalize failed"; return 0; fi
  if retired_exists; then fail "manifests-retired still exists after the finalize"; else pass "manifests-retired is gone"; fi
  assert_eq "the .skip guards are untouched by the finalize" "${skips0}" "$(skip_guards)"
}

e10() {
  tl_case E10 "migration rehearsal: old layout -> migrate -> up -> migrate --argo -> migrate (M6) -> k3s restart"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  [[ -n "${E2E_OLD_SETUP:-}" ]] || { skip_case "E2E_OLD_SETUP (old-tooling install command) not set"; return 0; }
  (( ALLOW_DESTROY )) || { skip_case "re-creates the VM: pass --allow-destroy"; return 0; }
  fresh_vm || return 0
  rm -rf "${LAN_HOME:?}/.teknoir-airgap"
  reset_admin
  if VM_IP="${NODE_IP}" bash -c "${E2E_OLD_SETUP}"; then pass "old-style install completed"; else fail "E2E_OLD_SETUP failed"; return 0; fi
  local dir inv0 hashes0 inv1 inv2 rvs1 gone lost unexpected g codes t0 st skips pw="${LAN_HOME}/e2e/admin.pw" mode mark
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
  adopt_owner "$(profile_owner "${TEAMSPACE}")"
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
  mark="$(transcript_mark)"
  if tk "${dir}" migrate --argo; then pass "migrate --argo exits 0"; else fail "migrate --argo failed"; return 0; fi
  # the untracked check counts Synced status.resources (CRDs) and the
  # converge-owned objects as owned (HYG-C6)
  assert_eq "migrate --argo warns about no object without an owner" "" \
    "$(transcript_since "${mark}" | grep -i 'no owner' | tr '\n' ' ' || true)"
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

  # --- finalize: an encrypted export newer than the migration, then the retired files go
  e10_finalize "${dir}"

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
# E11
# ---------------------------------------------------------------------------
ts_apps_unhealthy() {
  # ts_apps_unhealthy [teamspace] — its plugin Applications that are missing
  # or not Synced/Healthy
  local ts="${1:-${TEAMSPACE}}" st p out=""
  st="$(vm_kc -n teknoir-system get applications.argoproj.io --no-headers \
          -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status 2>/dev/null || true)"
  for p in "${PLUGINS[@]}"; do
    awk -v n="${ts}-${p}" '$1 == n && $2 == "Synced" && $3 == "Healthy" { ok = 1 } END { exit !ok }' <<<"${st}" || out+="${ts}-${p} "
  done
  printf '%s' "${out}"
}
ts_apps_healthy() { [[ -z "$(ts_apps_unhealthy "$@")" ]]; }
rolebinding_exists() { vm_kc -n "$1" get rolebinding "$2" -o name >/dev/null 2>&1; }
rolebinding_ref() {
  # rolebinding_ref <ns> <name> — "<roleRef kind>/<name> <kind>/<subject>,..." (subjects in lower case)
  vm_kc -n "$1" get rolebinding "$2" -o json 2>/dev/null | jq -r '
    "\(.roleRef.kind)/\(.roleRef.name) " + ([.subjects[]? | "\(.kind)/\(.name | ascii_downcase)"] | join(","))' || true
}

e11() {
  tl_case E11 "default teamspace ${TEAMSPACE}: Profile, namespace, grants, plugins from Harbor, DNS, TLS, Backstage"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  [[ -n "$(ca_file)" ]] || { fail "no CA certificate under ${LAN_HOME}/.teknoir-airgap (run E1 first)"; return 0; }
  e11_checks
}

e11_checks() {
  local ts="${TEAMSPACE}" email name v a b c d x repo ver p bad out hdr="${HTTP_DIR}/bs.auth" deadline ok
  email="$(lower "${ADMIN_EMAIL}")" name="$(user_name "${ADMIN_EMAIL}")"

  # 1. the GitOps Profile (K3)
  # spec.plugins: the controller fills in and owns the live list (managed fields),
  # so the GitOps declaration is "ArgoCD's field manager owns no f:plugins"
  v="$(vm_kc get profiles.teknoir.org "${ts}" --show-managed-fields -o json 2>/dev/null | jq -r '[
        ((.metadata.annotations["argocd.argoproj.io/sync-options"] // "") | gsub("\\s"; "") | split(",")
          | (any(.[]; . == "Prune=false") and any(.[]; . == "Delete=false"))),
        ((.metadata.annotations["argocd.argoproj.io/tracking-id"] // "") != ""),
        ((.spec.owner.name // "-") | ascii_downcase),
        ([.metadata.managedFields[]? | select(.manager == "argocd-controller") | .fieldsV1["f:spec"]["f:plugins"]? // empty] | length)] | map(tostring) | join(" ")' 2>/dev/null || true)"
  [[ -n "${v}" ]] || { fail "Profile ${ts} does not exist"; return 0; }
  read -r a b c d <<<"${v}"
  assert_eq "Profile ${ts} carries sync-options Prune=false,Delete=false" true "${a}"
  assert_eq "Profile ${ts} is declared in GitOps (ArgoCD tracking-id)" true "${b}"
  assert_eq "Profile ${ts} is owned by the first admin" "${email}" "${c}"
  assert_eq "Profile ${ts} declares no spec.plugins in GitOps (the controller's defaults apply)" 0 "${d}"

  # 2. its namespace
  v="$(vm_kc get namespace "${ts}" -o json 2>/dev/null | jq -r --arg ts "${ts}" '[
        (.metadata.labels["istio-injection"] // "-"),
        ((.metadata.annotations.owner // "-") | ascii_downcase),
        ([(.metadata.ownerReferences // [])[] | select(.kind == "Profile" and .name == $ts)] | length)] | map(tostring) | join(" ")' || true)"
  read -r a b c <<<"${v}"
  assert_eq "namespace ${ts}: label istio-injection=enabled" enabled "${a}"
  assert_eq "namespace ${ts}: annotation owner is the admin" "${email}" "${b}"
  assert_eq "namespace ${ts}: ownerReference to Profile ${ts}" 1 "${c}"

  # 3. grants: the Profile's namespaceAdmin, then admin-user's owner claim
  v="$(rolebinding_ref "${ts}" namespaceAdmin)"
  assert_eq "RoleBinding ${ts}/namespaceAdmin binds ClusterRole teknoir-admin" "ClusterRole/teknoir-admin" "${v%% *}"
  if [[ ",${v#* }," == *",User/${email},"* ]]; then pass "RoleBinding ${ts}/namespaceAdmin has subject User ${email}"
  else fail "RoleBinding ${ts}/namespaceAdmin subjects [${v#* }] lack User ${email}"; fi
  if [[ " $(user_claims "${name}") " == *" owner@${ts} "* ]]; then pass "User ${name} holds claim owner@${ts} (admin-user)"
  else fail "User ${name} lacks claim owner@${ts}: [$(user_claims "${name}")]"; fi
  if wait_until 300 rolebinding_exists "${ts}" "user-${name}-teknoir-role-binding"; then
    v="$(rolebinding_ref "${ts}" "user-${name}-teknoir-role-binding")"
    assert_eq "RoleBinding ${ts}/user-${name}-teknoir-role-binding (user-controller) binds teknoir-admin" "ClusterRole/teknoir-admin" "${v%% *}"
  else
    fail "user-controller created no RoleBinding ${ts}/user-${name}-teknoir-role-binding within 300 s"
  fi

  # 4. what the controller puts into the namespace (Secrets by name only)
  for x in authorizationpolicies.security.istio.io/ns-owner-access-istio authorizationpolicies.security.istio.io/whitelist-namespaces \
           secret/domain-wildcard-tls configmap/org-config configmap/user-alerting-rules; do
    if vm_kc -n "${ts}" get "${x}" -o name >/dev/null 2>&1; then pass "${ts}: ${x%%.*} ${x#*/} exists"
    else fail "${ts}: ${x%%.*} ${x#*/} is missing"; fi
  done

  # 5. the AppProject and the 9 plugin Applications, from Harbor (K2)
  repo="$(vm_kc -n teknoir-system get configmap profile-controller-config -o jsonpath='{.data.PLUGIN_CHART_REPO}' 2>/dev/null || true)"
  ver="$(vm_kc -n teknoir-system get configmap profile-controller-config -o jsonpath='{.data.PLUGIN_CHART_VERSION}' 2>/dev/null || true)"
  assert_eq "profile-controller-config: PLUGIN_CHART_REPO is Harbor's project teknoir" "harbor.${DOMAIN}/teknoir" "${repo}"
  if [[ -n "${ver}" ]]; then pass "profile-controller-config: PLUGIN_CHART_VERSION ${ver}"; else fail "profile-controller-config has no PLUGIN_CHART_VERSION"; fi
  v="$(vm_kc -n teknoir-system get appprojects.argoproj.io "${ts}" -o json 2>/dev/null | jq -r '
        "\((.spec.sourceRepos // []) | join(",")) \((.spec.clusterResourceWhitelist // []) | length)"' || true)"
  assert_eq "AppProject teknoir-system/${ts}: sourceRepos harbor.${DOMAIN}/teknoir only, no cluster-scoped kinds" "harbor.${DOMAIN}/teknoir 0" "${v}"
  for p in "${PLUGINS[@]}"; do
    v="$(vm_kc -n teknoir-system get applications.argoproj.io "${ts}-${p}" -o json 2>/dev/null | jq -r '[
          (.spec.source.repoURL // "-"), (.spec.source.targetRevision // "-"), (.spec.project // "-"),
          ((.spec.syncPolicy.syncOptions // []) | any(.[]; . == "RespectIgnoreDifferences=true") | tostring)] | join(" ")' || true)"
    assert_eq "Application ${ts}-${p}: chart from Harbor at ${ver:-?}, project ${ts}, RespectIgnoreDifferences=true" \
      "harbor.${DOMAIN}/teknoir ${ver} ${ts} true" "${v}"
  done
  if wait_until 1200 ts_apps_healthy "${ts}"; then pass "the 9 ${ts} plugin Applications are Synced/Healthy"
  else fail "${ts} plugin Applications not Synced/Healthy within 20 min: $(ts_apps_unhealthy "${ts}")"; fi

  # 6. the controller applied every enabled plugin (EMQX: its MQTT user exists)
  bad="$(vm_kc get profiles.teknoir.org "${ts}" -o json 2>/dev/null | jq -r '
        (.status.appliedconfig.plugins // {}) | to_entries[] | select(.value.appliedConfig.settings.enabled == true)
        | select((.value.applyStatus.status // "") != "Success") | "\(.key)=\(.value.applyStatus.status // "none")"' | tr '\n' ' ' || true)"
  assert_eq "Profile ${ts}: every enabled plugin applied with status Success" "" "${bad}"

  # 7. pods Ready with the Istio sidecar, images local, no pull errors
  bad="$(vm_kc -n "${ts}" get pods -o json 2>/dev/null | jq -r '
        .items[] | select(.status.phase != "Succeeded")
        | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0
                 or ([(.spec.containers // [])[].name, (.spec.initContainers // [])[].name] | index("istio-proxy") | not))
        | .metadata.name' | tr '\n' ' ' || true)"
  assert_eq "every ${ts} pod is Ready and has the istio-proxy sidecar" "" "${bad}"
  if [[ -n "$(vm_kc -n "${ts}" get pods -o name 2>/dev/null || true)" ]]; then pass "${ts} has pods"; else fail "${ts} has no pods"; fi
  assert_eq "every ${ts} image is in containerd" "" "$(images_missing "${ts}" | tr '\n' ' ')"
  assert_eq "no ErrImagePull/ImagePullBackOff events in ${ts} (boot-time Harbor 503s after E12's reboot aside)" 0 "$(pull_failures -n "${ts}")"
  assert_eq "no ${ts} pod is waiting in ErrImagePull/ImagePullBackOff" 0 "$(pull_waiting -n "${ts}")"

  # 8. names, TLS and the teamspace's web apps
  out="$(vm_kc -n default run "e2e-dns-$(date +%s)" --image="${E2E_DNS_IMAGE:-docker.io/library/busybox:1.36.1}" \
           --image-pull-policy=IfNotPresent --restart=Never --rm -i --quiet --command -- nslookup "mqtt-${ts}.${DOMAIN}" 2>&1 || true)"
  if grep -qE "^Address:?[[:space:]]+${NODE_IP//./\\.}\$" <<<"${out}"; then pass "in a pod, mqtt-${ts}.${DOMAIN} resolves to NODE_IP ${NODE_IP} (CoreDNS)"
  else fail "in a pod, mqtt-${ts}.${DOMAIN} does not resolve to ${NODE_IP}: $(tr '\n' ' ' <<<"${out}" | cut -c1-200)"; fi
  for x in "8883 mqtt-${ts}" "2222 deadend-${ts}"; do
    out="$(lan "${E2E_WORK}" openssl s_client -connect "${NODE_IP}:${x%% *}" -servername "${x#* }.${DOMAIN}" -CAfile "$(ca_file)" \
             -verify_return_error -brief </dev/null 2>&1 || true)"
    if grep -q 'Verification: OK' <<<"${out}"; then pass "TLS handshake with ${x#* }.${DOMAIN} on ${NODE_IP}:${x%% *}, verified with the platform CA"
    else fail "no verified TLS handshake with ${x#* }.${DOMAIN} on ${NODE_IP}:${x%% *}"; fi
  done
  login_check "the admin signs in for the ${ts} web apps and the catalog"
  for x in grafana prometheus; do
    v="$(app_status "${ADMIN_JAR}" "https://${DOMAIN}/${ts}/${x}/")"
    if [[ "${v%% *}" == 200 && "$(url_host "${v#* }")" == "${DOMAIN}" ]]; then pass "https://${DOMAIN}/${ts}/${x}/ answers the owner with 200"
    else fail "https://${DOMAIN}/${ts}/${x}/: HTTP ${v%% *} at ${v#* }"; fi
  done

  # 9. the Backstage catalog (PT1M user and profile ingestion: poll, no refresh call)
  deadline=$(( SECONDS + CATALOG_TIMEOUT )) ok=0
  while (( SECONDS < deadline )); do
    if bs_token "${ADMIN_JAR}" "${hdr}" >/dev/null \
       && [[ "$(bs_entity "${ADMIN_JAR}" "${hdr}" "system/${ts}/${ts}" "${HTTP_DIR}/entity.json")" == 200 ]] \
       && [[ "$(bs_entity "${ADMIN_JAR}" "${hdr}" "user/${ts}/${name}" "${HTTP_DIR}/entity.json")" == 200 ]] \
       && jq -e --arg g "group:${ts}/${ts}" '(.spec.memberOf // []) | index($g)' "${HTTP_DIR}/entity.json" >/dev/null 2>&1; then
      ok=1; break
    fi
    sleep "${E2E_CATALOG_POLL:-15}"
  done
  rm -f "${hdr}" "${HTTP_DIR}/entity.json" "${HTTP_DIR}/entity.hdr"
  if (( ok )); then pass "Backstage has system ${ts}/${ts}, and user ${ts}/${name} is a member of group:${ts}/${ts}"
  else fail "Backstage has no system ${ts}/${ts} or user ${ts}/${name} in group:${ts}/${ts} within ${CATALOG_TIMEOUT} s"; fi
}

# ---------------------------------------------------------------------------
# E12
# ---------------------------------------------------------------------------
e12() {
  tl_case E12 "node time: bundled chrony, skew correction, --sync-clock, RTC, reboot, SNTP, doctor"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  local dir lock want got st s0 s1 out rc rtc boot0 boot1 sntp stratum offset v
  local -a pkgs=()
  dir="$(bundle_dir "${E2E_BUNDLE}")"

  # the bundled packages (TIME-T1/T2)
  lock="${dir}/node/debs/debs.lock"
  if [[ -s "${lock}" ]]; then
    want="$(awk 'NF >= 2 { print $1, $2 }' "${lock}" | sort)"
    read -r -a pkgs <<<"$(awk '{ print $1 }' <<<"${want}" | tr '\n' ' ')"
    # shellcheck disable=SC2016  # dpkg-query's own ${...} fields
    got="$(vmx dpkg-query -W -f '${Package} ${Version}\n' "${pkgs[@]}" 2>/dev/null | sort || true)"
    assert_eq "the bundled packages are installed at their pinned versions (node/debs/debs.lock)" "${want}" "${got}"
  else
    fail "the bundle has no node/debs/debs.lock"
  fi
  # shellcheck disable=SC2016
  st="$(vmx dpkg-query -W -f '${db:Status-Abbrev}' systemd-timesyncd 2>/dev/null || true)"
  if [[ "${st}" == ii* ]]; then fail "systemd-timesyncd is still installed (${st})"; else pass "systemd-timesyncd is gone (dpkg: ${st:-unknown package})"; fi
  assert_eq "chrony is active" active "$(vmx systemctl is-active chrony 2>/dev/null || true)"
  if [[ -n "$(vmx sudo sh -c 'command -v hwclock' 2>/dev/null || true)" ]]; then pass "hwclock is installed"; else fail "hwclock is not installed on the node"; fi

  # 20 s behind: a plain up corrects it (TIME-T3), and installs nothing again
  s0="$(dpkg_state)"
  vmx sudo date -u -s "@$(( $(date +%s) - 20 ))" >/dev/null 2>&1 || true
  tl_log "node clock set 20 s back: skew $(skew_now) s"
  if up_in "${dir}"; then pass "up with the node 20 s behind exits 0"; else fail "up with the node 20 s behind failed"; fi
  if wait_until 60 skew_within 2; then pass "the node clock is within 2 s of the LAN host within 60 s of up ($(skew_now) s)"
  else fail "the node clock is $(skew_now) s off 60 s after up (want within 2 s)"; fi
  s1="$(dpkg_state)"
  assert_eq "a second up changed no package (dpkg status and log)" "${s0}" "${s1}"

  # 400 s behind, the RTC too (a node that booted with a bad RTC)
  vmx sudo date -u -s "@$(( $(date +%s) - 400 ))" >/dev/null 2>&1 || true
  vmx sudo hwclock --systohc --utc >/dev/null 2>&1 || true
  tl_log "node clock and RTC set 400 s back: skew $(skew_now) s, RTC offset $(rtc_offset) s"
  set +e; out="$(up_in "${dir}")"; rc=$?; set -e
  if (( rc == 1 )) && grep -q -- '--sync-clock' <<<"${out}"; then pass "up with the node 400 s behind exits 1 with the --sync-clock hint"
  else fail "up with the node 400 s behind: exit ${rc}, want 1 with the --sync-clock hint"; fi
  if up_in "${dir}" --sync-clock; then pass "up --sync-clock exits 0"; else fail "up --sync-clock failed"; fi
  if wait_until 60 skew_within 2; then pass "the node clock is within 2 s after up --sync-clock ($(skew_now) s)"
  else fail "the node clock is $(skew_now) s off after up --sync-clock"; fi
  rtc="$(rtc_offset)"
  if [[ "${rtc}" =~ ^-?[0-9]+$ ]] && abs_le "${rtc}" 2; then pass "|RTC - system| <= 2 s after up --sync-clock (${rtc} s)"
  else fail "RTC offset ${rtc} s after up --sync-clock (want within 2 s)"; fi

  # a reboot: the clock comes back from the RTC that up wrote (a guest reboot
  # keeps QEMU and its RTC; a QEMU restart would reset the RTC to the rig host's clock)
  boot0="$(vmx cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  mkdir -p "${STATE}"; : > "${STATE}/node-rebooted"
  vmx sudo systemctl reboot >/dev/null 2>&1 || true
  sleep 20
  "${VM}" start >/dev/null 2>&1 || true
  boot1="$(vmx cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
  if [[ -n "${boot1}" && "${boot1}" != "${boot0}" ]]; then pass "the node rebooted (new boot id)"; else fail "the node did not reboot"; fi
  if skew_within 5; then pass "after the reboot the node clock is within 5 s of the LAN host ($(skew_now) s)"
  else fail "after the reboot the node clock is $(skew_now) s off (want within 5 s)"; fi
  wait_until 600 vm_kc get --raw /readyz >/dev/null 2>&1 || fail "API not ready after the reboot"
  wait_apps 1800 || true
  wait_until 1500 platform_ready || fail "the platform is not Ready (all pods, ingress) 1500 s after the reboot"

  # the node serves time to the LAN (chrony allow + local stratum 10)
  sntp="$(lan "${E2E_WORK}" python3 -I "${HERE}/sntp-query.py" "${NODE_IP}" 2>&1 | grep '^stratum=' | tail -n1 || true)"
  stratum="$(sed -n 's/^stratum=\([0-9]*\).*/\1/p' <<<"${sntp}")"
  offset="$(sed -n 's/.* offset=\([-0-9.]*\).*/\1/p' <<<"${sntp}")"
  if [[ -n "${stratum}" ]] && (( stratum <= 11 )) && abs_le "${offset:-99}" 2; then pass "SNTP from the LAN host to ${NODE_IP}:123: ${sntp}"
  else fail "SNTP from the LAN host to ${NODE_IP}:123: [${sntp:-no answer}] (want stratum <= 11, |offset| <= 2 s)"; fi

  # doctor: the node's checks (RTC, chrony, time source, lease) report no FAIL;
  # the LAN host's own checks run in the netns, whose OS does not trust the
  # platform CA by design (reported, not asserted)
  out="$(tk "${dir}" doctor 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)"
  v="$(sed -n '/^Node /,$p' <<<"${out}" | grep -E '^[[:space:]]*FAIL' || true)"
  assert_eq "doctor reports no FAIL for the node" "" "${v}"
  v="$(sed -n '1,/^Node /p' <<<"${out}" | grep -E '^[[:space:]]*FAIL' | tr '\n' ' ' || true)"
  [[ -z "${v}" ]] || tl_warn "doctor FAIL lines for the LAN netns (not asserted): ${v}"
}

# ---------------------------------------------------------------------------
# E13
# ---------------------------------------------------------------------------
NA_OK=0
nonadmin_setup() {
  # nonadmin_setup — the non-admin realm user: a User CR (role viewer, not in
  # Keycloak group admin), its temporary password copied to nonadmin.pw, a
  # first login (forced password change) with the session in NONADMIN_JAR,
  # then the K1 cleanup: the Secret goes once the user has set their own
  # password. Sets NA_OK.
  local name pre="${LAN_HOME}/e2e/nonadmin" email
  NA_OK=0
  email="$(lower "${NONADMIN_EMAIL}")" name="$(user_name "${NONADMIN_EMAIL}")"
  if ! vm_kc get users.teknoir.org "${name}" -o name >/dev/null 2>&1; then
    rm -f "${pre}.pw" "${pre}.new"
    if jq -n --arg n "${name}" --arg e "${email}" '{apiVersion: "teknoir.org/v1", kind: "User", metadata: {name: $n},
         spec: {email: $e, email_verified: true, enabled: true, display_name: "E2E Viewer", claims_v0: {role: "viewer"}, plugins: []}}' \
         | vm_kc create -f - >/dev/null; then
      pass "created the non-admin User ${name} (role viewer, not in Keycloak group admin)"
    else
      fail "cannot create the non-admin User ${name}"; return 0
    fi
  fi
  wait_until 300 user_reconciled "${name}" || { fail "user-controller did not create ${email} in Keycloak within 300 s"; return 0; }
  if [[ ! -s "$(pw_current "${pre}")" ]]; then
    wait_until 60 copy_initial_password "${name}" "${pre}.pw" \
      || { fail "no temporary password recorded for ${name} (Secret ${CRED_NS}/user-initial-password-${name})"; return 0; }
  fi
  if kc_login "${NONADMIN_JAR}" "https://${DOMAIN}/" "${email}" "${pre}" --forbid-profile-form; then
    pass "the non-admin realm user signs in (forced password change, no Update Profile form)"; NA_OK=1
  else
    fail "the non-admin realm user cannot sign in"; return 0
  fi
  # K1 (SEC-C1 case b): with UPDATE_PASSWORD gone, the next reconcile deletes
  # the temporary-password Secret. user-controller requeues such a User only
  # hourly, so a changed annotation starts that reconcile now (the controller
  # watches Users without a predicate). This also keeps the deletion out of
  # E2's no-change window.
  vm_kc annotate users.teknoir.org "${name}" "e2e.teknoir.org/poke=$(date +%s)" --overwrite >/dev/null 2>&1 \
    || tl_warn "cannot annotate User ${name}: waiting for user-controller's own requeue"
  if wait_until 300 k1_gone "${name}"; then
    pass "the non-admin's temporary-password Secret ${CRED_NS}/user-initial-password-${name} is deleted once the user set their own password"
  else
    fail "Secret ${CRED_NS}/user-initial-password-${name} still exists 300 s after the user set their own password"
  fi
}

argocd_login_url() { printf 'https://argocd.%s/auth/login?return_url=%s' "${DOMAIN}" "$(uri "https://argocd.${DOMAIN}/applications")"; }

argocd_apps_count() {
  # argocd_apps_count <jar> — "<status> <number of Applications ArgoCD lists>"
  local code n
  code="$(http_req "${HTTP_DIR}/argo.hdr" "${HTTP_DIR}/argo.json" -b "$1" -c "$1" "https://argocd.${DOMAIN}/api/v1/applications")"
  n="$(jq -r '(.items // []) | length' "${HTTP_DIR}/argo.json" 2>/dev/null || echo "?")"
  rm -f "${HTTP_DIR}/argo.hdr" "${HTTP_DIR}/argo.json"
  printf '%s %s' "${code}" "${n}"
}

argocd_session_vm() {
  # argocd_session_vm <root-only file on the VM> — HTTP status of POST
  # /api/v1/session as admin with that password (read and sent on the VM)
  {
    printf 'DOMAIN=%q NODE_IP=%q F=%q\n' "${DOMAIN}" "${NODE_IP}" "$1"
    cat <<'EOF'
# vm-script: argocd_session_vm
set -eu
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
chmod 700 "$d"
k3s kubectl -n teknoir-system get secret teknoir-root-ca-bundle -o go-template='{{index .data "ca.crt" | base64decode}}' > "$d/ca"
python3 - "$F" "$d/body" <<'PY'
import json, os, sys
p = open(sys.argv[1]).read().rstrip("\n")
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps({"username": "admin", "password": p}).encode())
os.close(fd)
PY
curl -sS -o /dev/null -w '%{http_code}' -m 20 --cacert "$d/ca" --resolve "argocd.${DOMAIN}:443:${NODE_IP}" \
  -H 'Content-Type: application/json' --data-binary @"$d/body" "https://argocd.${DOMAIN}/api/v1/session" || echo 000
EOF
  } | vm_root 2>/dev/null | tail -c 3
}

e13() {
  tl_case E13 "access and credentials: non-admin, admin, platform-admin, controller RBAC, backup, rotations"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  [[ -n "$(ca_file)" ]] || { fail "no CA certificate under ${LAN_HOME}/.teknoir-airgap (run E1 first)"; return 0; }
  e13_checks "$(bundle_dir "${E2E_BUNDLE}")"
}

e13_checks() {
  local dir="$1" t0 start u url v code n who want line proj csrf pa="${LAN_HOME}/e2e/platform-admin" out waited
  local -a args=()
  t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)" start="${SECONDS}"
  login_check "the admin signs in"
  nonadmin_setup

  # Grafana, Prometheus and Alertmanager of teknoir-system: group admin only (SEC-C5)
  for u in grafana prometheus alertmanager; do
    url="https://${DOMAIN}/teknoir-system/${u}/"
    if (( NA_OK )); then
      v="$(app_status "${NONADMIN_JAR}" "${url}")"
      if [[ "${v%% *}" == 403 && "$(url_host "${v#* }")" == "${DOMAIN}" ]]; then pass "non-admin: ${url} is forbidden (403)"
      else fail "non-admin: ${url}: HTTP ${v%% *} at ${v#* }, want 403"; fi
    fi
    if (( LOGIN_OK )); then
      v="$(app_status "${ADMIN_JAR}" "${url}")"
      if [[ "${v%% *}" == 200 && "$(url_host "${v#* }")" == "${DOMAIN}" ]]; then pass "admin: ${url} answers 200"
      else fail "admin: ${url}: HTTP ${v%% *} at ${v#* }, want 200"; fi
    fi
  done
  if (( LOGIN_OK )); then
    code="$(http_req "${HTTP_DIR}/g.hdr" "${HTTP_DIR}/g.json" -b "${ADMIN_JAR}" -c "${ADMIN_JAR}" "https://${DOMAIN}/teknoir-system/grafana/api/user")"
    v="$(jq -r '"\(.login // "-") \(.email // "-")"' "${HTTP_DIR}/g.json" 2>/dev/null || echo "- -")"
    assert_eq "Grafana /api/user: the admin is known by e-mail through the JWT (not anonymous)" "200 ${ADMIN_USER} ${ADMIN_USER}" "${code} $(lower "${v}")"
    code="$(http_req "${HTTP_DIR}/g.hdr" "${HTTP_DIR}/g.json" -b "${ADMIN_JAR}" -c "${ADMIN_JAR}" "https://${DOMAIN}/teknoir-system/grafana/api/user/orgs")"
    v="$(jq -r '[.[]? | .role] | join(",")' "${HTTP_DIR}/g.json" 2>/dev/null || true)"
    if [[ "${code}" == 200 && ",${v}," == *",Admin,"* ]]; then pass "Grafana: the admin's org role is Admin"; else fail "Grafana org roles of the admin: HTTP ${code} [${v}], want Admin"; fi
    rm -f "${HTTP_DIR}/g.hdr" "${HTTP_DIR}/g.json"
  fi

  # ArgoCD: no default role for non-admins; group admin is role:admin
  if (( NA_OK )); then
    if sso_login "${NONADMIN_JAR}" "$(argocd_login_url)" argocd.token; then
      assert_eq "non-admin: ArgoCD /api/v1/applications lists no Application" "200 0" "$(argocd_apps_count "${NONADMIN_JAR}")"
    else
      fail "non-admin: ArgoCD SSO sign-in failed"
    fi
  fi
  proj="$(vm_kc -n teknoir-system get applications.argoproj.io "${ROOT_APP}" -o jsonpath='{.spec.project}' 2>/dev/null || true)"
  if (( LOGIN_OK )) && sso_login "${ADMIN_JAR}" "$(argocd_login_url)" argocd.token; then
    v="$(argocd_apps_count "${ADMIN_JAR}")"
    if [[ "${v%% *}" == 200 && "${v#* }" =~ ^[1-9][0-9]*$ ]]; then pass "admin: ArgoCD lists ${v#* } Applications"; else fail "admin: ArgoCD Applications: ${v}"; fi
  else
    fail "admin: ArgoCD SSO sign-in failed"
  fi

  # Harbor: project creation is admin-only
  if (( NA_OK )); then
    if sso_login "${NONADMIN_JAR}" "https://harbor.${DOMAIN}/c/oidc/login?redirect_url=%2Fharbor%2Fprojects" sid; then
      code="$(http_req "${HTTP_DIR}/h.hdr" "${HTTP_DIR}/h.json" -b "${NONADMIN_JAR}" -c "${NONADMIN_JAR}" "https://harbor.${DOMAIN}/api/v2.0/users/current")"
      v="$(jq -r '.username // "-"' "${HTTP_DIR}/h.json" 2>/dev/null || echo -)"
      assert_eq "non-admin: Harbor knows the OIDC user (GET /api/v2.0/users/current)" "200 $(lower "${NONADMIN_EMAIL}")" "${code} $(lower "${v}")"
      csrf="$(hdr_get "${HTTP_DIR}/h.hdr" x-harbor-csrf-token)"
      ( umask 077
        printf 'X-Harbor-CSRF-Token: %s\n' "${csrf}" > "${HTTP_DIR}/csrf.hdr"
        printf '{"project_name":"e2e-nonadmin-probe","metadata":{"public":"false"}}' > "${HTTP_DIR}/project.json" )
      code="$(http_req "${HTTP_DIR}/h.hdr" "${HTTP_DIR}/h.json" -b "${NONADMIN_JAR}" -c "${NONADMIN_JAR}" -H @"${HTTP_DIR}/csrf.hdr" \
                -H 'Content-Type: application/json' --data-binary @"${HTTP_DIR}/project.json" "https://harbor.${DOMAIN}/api/v2.0/projects")"
      v="$(jq -r '[.errors[]?.message] | join(";")' "${HTTP_DIR}/h.json" 2>/dev/null || true)"
      if [[ "${code}" == 403 && "$(lower "${v}")" != *csrf* ]]; then pass "non-admin: Harbor refuses POST /api/v2.0/projects (403, project_creation_restriction adminonly)"
      else fail "non-admin: Harbor POST /api/v2.0/projects: HTTP ${code} [${v}], want 403 (not a CSRF failure)"; fi
      rm -f "${HTTP_DIR}/h.hdr" "${HTTP_DIR}/h.json" "${HTTP_DIR}/csrf.hdr" "${HTTP_DIR}/project.json"
    else
      fail "non-admin: Harbor OIDC sign-in failed"
    fi
  fi

  # the retired platform-admin login (D1): disabled in the realm import
  v="$(kc_user_state teknoir platform-admin)"
  assert_eq "Keycloak user platform-admin (realm teknoir) is disabled" false "$(sed -n 's/^enabled=\([a-z]*\).*/\1/p' <<<"${v}")"
  rm -f "${pa}.pw" "${pa}.new"
  if tk "${dir}" credentials platform-admin --out "${pa}.pw" >/dev/null 2>&1 && [[ -s "${pa}.pw" ]]; then
    set +e; out="$(kc_login "${HTTP_DIR}/platform-admin.jar" "${LOGIN_URL}" platform-admin "${pa}" 2>&1)"; v=$?; set -e
    if (( v != 0 )) && grep -qi 'disabled' <<<"${out}"; then pass "a platform-admin sign-in is refused (account disabled)"
    else fail "a platform-admin sign-in was not refused as disabled (exit ${v})"; fi
    rm -f "${HTTP_DIR}/platform-admin.jar"
  else
    tl_warn "credentials platform-admin gave no password: only the Keycloak state of platform-admin is checked"
  fi

  # controller RBAC (SEC-C6/C7): the can-i matrix of tests/rbac-k3d.sh
  local uc pc
  uc="$(controller_sa user-controller)" pc="$(controller_sa profile-controller)"
  while IFS='|' read -r who want line; do
    [[ -n "${who}" ]] || continue
    read -r -a args <<<"${line}"
    assert_eq "auth can-i ${line} as ${who#*/}" "${want}" "$(can_i "${who}" "${args[@]}")"
  done <<EOF
${uc}|no|* *
${uc}|yes|create rolebindings --all-namespaces
${uc}|yes|bind clusterroles/teknoir-admin
${uc}|no|bind clusterroles/cluster-admin
${uc}|no|bind clusterroles/admin
${uc}|no|get secrets -n teknoir-auth
${uc}|no|create clusterrolebindings
${uc}|no|create pods --subresource=exec -n teknoir-auth
${pc}|no|* *
${pc}|yes|create rolebindings -n ${TEAMSPACE}
${pc}|no|create clusterrolebindings
${pc}|no|bind clusterroles/cluster-admin
${pc}|no|create pods --subresource=exec -n ${TEAMSPACE}
EOF
  for u in user-controller profile-controller; do
    n="$(vm_kc -n teknoir-system logs "deployment/${u}" --tail=-1 2>/dev/null | grep -ci 'forbidden' || true)"
    assert_eq "no 'forbidden' in the ${u} log" 0 "${n:-0}"
  done

  # post removed the migration's previous-password (SEC-C10)
  assert_eq "Secret keycloak-admin has no previous-password (username and password only)" "password username" "$(secret_keys teknoir-auth keycloak-admin)"

  e13_backup "${dir}"
  e13_argocd_admin "${dir}" "${proj}"

  # D8 rehearsal: a new Keycloak database password, then sign-ins still work
  if tk "${dir}" rotate keycloak-db --i-know; then pass "rotate keycloak-db --i-know exits 0"; else fail "rotate keycloak-db --i-know failed"; fi
  if wait_until 900 apps_healthy_except teknoir-demo-; then pass "every Application (but teknoir-demo-*) is Synced/Healthy after the rotation"
  else fail "Applications not Synced/Healthy after rotate keycloak-db: $(apps_unhealthy_except teknoir-demo-)"; fi
  login_check "the admin signs in after rotate keycloak-db"

  # Prometheus reaches Alertmanager (alertmanager-allow-prometheus)
  waited=$(( SECONDS - start ))
  if (( waited < 300 )); then tl_log "waiting $(( 300 - waited )) s to cover 5 min of Prometheus logs"; sleep $(( 300 - waited )); fi
  n="$(vm_kc -n teknoir-system logs -l app.kubernetes.io/name=prometheus -c prometheus --since-time="${t0}" --tail=-1 2>/dev/null \
        | grep -c 'Error sending alert' || true)"
  assert_eq "Prometheus logged no 'Error sending alerts' since ${t0} (5 min or more)" 0 "${n:-0}"
}

e13_backup() {
  # the LAN backup without a terminal: encrypted to the site's recipients,
  # each test identity decrypts it, sha256sum -c passes, one plaintext set left
  local dir="$1" outdir="${LAN_HOME}/e2e/backup" site ids age f idf list tmp sums n
  site="${SITE_FILE}"
  [[ -f "${dir}/site/vmtest.env" ]] && site="${dir}/site/vmtest.env"
  if ids="$("${VM}" age-key --check "${site}" 2>"${HTTP_DIR}/age-key.err")"; then
    pass "the site's BACKUP_AGE_RECIPIENTS are the test identities in ${AGE_ID_DIR}"
  else
    fail "test age identities: $(tail -n1 "${HTTP_DIR}/age-key.err" | sed 's/\x1b\[[0-9;]*m//g')"; return 0
  fi
  age="$(age_bin "${dir}")" || { fail "no age binary (E2E_AGE, PATH or ${dir}/node/bin/age)"; return 0; }
  rm -rf "${outdir}"
  if tk "${dir}" backup --out "${outdir}"; then pass "backup --out without a terminal (recipients from the site)"
  else fail "backup --out without a terminal failed"; return 0; fi
  f="$(find "${outdir}" -maxdepth 1 -type f -name '*.tar.age' 2>/dev/null | sort | tail -n1)"
  [[ -n "${f}" ]] || { fail "no *.tar.age in ${outdir}"; return 0; }
  assert_eq "the LAN backup file is mode 0600" 600 "$(stat -c %a "${f}")"
  while read -r _ idf; do
    [[ -f "${idf}" ]] || continue
    list="$("${age}" -d -i "${idf}" "${f}" </dev/null 2>/dev/null | tar -t 2>/dev/null || true)"
    if grep -qE '(^|/)BACKUP\.info$' <<<"${list}" && grep -qE '(^|/)SHA256SUMS$' <<<"${list}"; then
      pass "$(basename "${idf}") decrypts the backup (BACKUP.info and SHA256SUMS listed)"
    else
      fail "$(basename "${idf}") does not decrypt the backup to a listing with BACKUP.info and SHA256SUMS"
    fi
  done <<<"${ids}"
  tmp="$(mktemp -d "${E2E_WORK}/backup-check.XXXXXX")"
  chmod 700 "${tmp}"
  idf="$(awk 'NR == 1 { print $2 }' <<<"${ids}")"
  if "${age}" -d -i "${idf}" "${f}" 2>/dev/null | tar -C "${tmp}" -x 2>/dev/null; then
    sums="$(find "${tmp}" -name SHA256SUMS -printf '%h\n' | head -n1)"
    if [[ -n "${sums}" ]] && ( cd "${sums}" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ); then pass "sha256sum -c of the decrypted backup passes"
    else fail "sha256sum -c of the decrypted backup fails"; fi
  else
    fail "decrypting and extracting the backup failed"
  fi
  rm -rf "${tmp}"
  n="$(vmx sudo find "${NODE_STATE_DIR}/backups" -mindepth 1 -maxdepth 1 -type d -name '2*Z' 2>/dev/null | grep -c . || true)"
  assert_eq "one plaintext backup set is left on the node" 1 "${n:-0}"
}

e13_argocd_admin() {
  # rotate argocd-admin (SEC-C9): the initial Secret goes, the old password
  # stops working, the new one (credentials argocd-admin) works, and the SSO
  # admin keeps role:admin
  local dir="$1" proj="$2" saved code pw="${LAN_HOME}/e2e/argocd-admin.pw" body="${HTTP_DIR}/session.json"
  saved="$(vm_root 2>/dev/null <<'EOF' || echo unknown
# vm-script: argocd_old_password
set -eu
f=/root/e2e-argocd-old.pw
rm -f "$f"
if k3s kubectl -n teknoir-system get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  ( umask 077; k3s kubectl -n teknoir-system get secret argocd-initial-admin-secret -o go-template='{{index .data "password" | base64decode}}' > "$f" )
  echo saved
else
  echo absent
fi
EOF
)"
  if tk "${dir}" rotate argocd-admin; then pass "rotate argocd-admin exits 0"; else fail "rotate argocd-admin failed"; return 0; fi
  assert_eq "argocd-initial-admin-secret is gone after the rotation" "" \
    "$(vm_kc -n teknoir-system get secret argocd-initial-admin-secret --ignore-not-found -o name 2>/dev/null || true)"
  if [[ "${saved}" == saved ]]; then
    assert_eq "the old ArgoCD admin password is refused (POST /api/v1/session)" 401 "$(argocd_session_vm /root/e2e-argocd-old.pw)"
  else
    tl_warn "argocd-initial-admin-secret was gone before the rotation (${saved}): the old password is not checked"
  fi
  vmx sudo rm -f /root/e2e-argocd-old.pw >/dev/null 2>&1 || true
  rm -f "${pw}"
  if tk "${dir}" credentials argocd-admin --out "${pw}" && [[ -s "${pw}" ]]; then
    assert_eq "credentials argocd-admin --out writes a 0600 file" 600 "$(stat -c %a "${pw}" 2>/dev/null || echo missing)"
    ( umask 077; jq -n --rawfile p "${pw}" '{username: "admin", password: ($p | rtrimstr("\n"))}' > "${body}" )
    code="$(http_req "${HTTP_DIR}/session.hdr" "${HTTP_DIR}/session.out" -H 'Content-Type: application/json' \
              --data-binary @"${body}" "https://argocd.${DOMAIN}/api/v1/session")"
    rm -f "${body}" "${HTTP_DIR}/session.hdr" "${HTTP_DIR}/session.out"
    assert_eq "the rotated ArgoCD admin password signs in (POST /api/v1/session)" 200 "${code}"
  else
    fail "credentials argocd-admin --out failed"
  fi
  if (( LOGIN_OK )) && sso_login "${ADMIN_JAR}" "$(argocd_login_url)" argocd.token; then
    code="$(http_req "${HTTP_DIR}/cani.hdr" "${HTTP_DIR}/cani.json" -b "${ADMIN_JAR}" -c "${ADMIN_JAR}" \
              "https://argocd.${DOMAIN}/api/v1/account/can-i/applications/sync/${proj:-default}/${ROOT_APP}")"
    assert_eq "the SSO admin may still sync ${ROOT_APP} (role:admin)" "200 yes" "${code} $(jq -r '.value // "-"' "${HTTP_DIR}/cani.json" 2>/dev/null || echo -)"
    rm -f "${HTTP_DIR}/cani.hdr" "${HTTP_DIR}/cani.json"
  else
    fail "the SSO admin cannot sign in to ArgoCD after the rotation"
  fi
}

# ---------------------------------------------------------------------------
# E14
# ---------------------------------------------------------------------------
e14() {
  tl_case E14 "sign-in robustness: garbage cookie, XHR 401, http->https, upstream 401/403 passthrough, logout chain"
  [[ -n "${E2E_BUNDLE:-}" ]] || { skip_case "E2E_BUNDLE not set"; return 0; }
  ensure_vm
  [[ -n "$(ca_file)" ]] || { fail "no CA certificate under ${LAN_HOME}/.teknoir-airgap (run E1 first)"; return 0; }
  e14_checks
}

http_to_https_check() {
  # plain HTTP is a bare redirect to https: ext_authz and the Lua run on :443 only
  probe "http://${DOMAIN}/"
  if [[ "${P_CODE}" == 301 && "${P_LOC}" == "https://${DOMAIN}"* && "${P_LOC}" != *oauth2* ]]; then pass "http://${DOMAIN}/ gets 301 to https, not to the login"
  else fail "http://${DOMAIN}/: HTTP ${P_CODE} to ${P_LOC:-nowhere}, want 301 to https://${DOMAIN} (no oauth2)"; fi
}

e14_checks() {
  local cookie n
  cookie="$(oauth2_cookie)"
  probe -H "Cookie: ${cookie}=garbage" "https://${DOMAIN}/"
  if [[ "${P_CODE}" == 302 && "${P_LOC}" == "https://${DOMAIN}/oauth2/start?rd="* ]]; then pass "a garbage session cookie gets 302 to /oauth2/start"
  else fail "a garbage session cookie got HTTP ${P_CODE} to ${P_LOC%%\?*}, want 302 to https://${DOMAIN}/oauth2/start"; fi
  n="$(expired_cookies "${P_HDR}" "${cookie}")"
  if (( n >= 2 )); then pass "the redirect clears ${cookie} (${n} expiring Set-Cookie headers)"
  else fail "the redirect has ${n} expiring Set-Cookie headers for ${cookie}, want 2"; fi
  probe -H "Cookie: ${cookie}=garbage" -H 'Sec-Fetch-Mode: cors' "https://${DOMAIN}/api/catalog/entities"
  assert_eq "a fetch (Sec-Fetch-Mode: cors) without a valid session gets 401 without Location" "401 -" "${P_CODE} ${P_LOC:--}"
  probe -H 'X-Requested-With: XMLHttpRequest' "https://${DOMAIN}/"
  assert_eq "an XHR (X-Requested-With) without a session gets 401 without Location" "401 -" "${P_CODE} ${P_LOC:--}"
  http_to_https_check
  login_check "a fresh admin session for the passthrough and logout checks"
  if (( LOGIN_OK )); then
    probe -b "${ADMIN_JAR}" -c "${ADMIN_JAR}" "https://${DOMAIN}/api/catalog/entities"
    if [[ "${P_CODE}" =~ ^40[13]$ && "${P_LOC}" != *"/oauth2/"* ]]; then pass "signed in, /api/catalog/entities without a Backstage token gets Backstage's own ${P_CODE} (no login loop)"
    else fail "signed in, /api/catalog/entities without a Backstage token: HTTP ${P_CODE} to ${P_LOC:-nowhere}, want 401/403 without a login redirect"; fi
    if lan "${E2E_WORK}" "${KCLOGIN}" --logout --cacert "$(ca_file)" --url "https://${DOMAIN}/" --cookie-jar "${ADMIN_JAR}"; then
      pass "logout: sign_out -> Keycloak confirmation -> https://${DOMAIN}/ -> /oauth2/start -> login form"
    else
      fail "the logout chain failed (see the kc-login lines above)"
    fi
  fi
  rm -f "${P_HDR}" "${P_BODY}"
}

# ---------------------------------------------------------------------------
# E15
# ---------------------------------------------------------------------------
apps_unhealthy_except() {
  # apps_unhealthy_except <name prefix> — Applications not Synced/Healthy,
  # leaving out those whose name starts with <prefix>
  apps_state 2>/dev/null | awk -v p="$1" '($2 != "Synced" || $3 != "Healthy") && index($1, p) != 1 { print $1 "=" $2 "/" $3 }' | tr '\n' ' ' || true
}
apps_healthy_except() { [[ -z "$(apps_unhealthy_except "$1")" ]]; }
demo_apps() { vm_kc -n teknoir-system get applications.argoproj.io -o name 2>/dev/null | grep -c '/teknoir-demo-' || true; }
demo_apps_exist() { (( $(demo_apps) >= ${#PLUGINS[@]} )); }
demo_repos() {
  vm_kc -n teknoir-system get applications.argoproj.io -o json 2>/dev/null | jq -r '
    [.items[] | select(.metadata.name | startswith("teknoir-demo-")) | .spec.source.repoURL] | unique | join(" ")' || true
}
not_legacy() { ! user_has_legacy_pw "$1"; }
demo_on_harbor() { [[ "$(demo_repos)" == "harbor.${DOMAIN}/teknoir" ]]; }
master_clients_gone() { [[ "$(kc_master_clients)" == "0 401" ]]; }

e15_master_clients() {
  # e15_master_clients — realm master's legacy clients as the live node has
  # them (made by hand per the old AIRGAP-BOOTSTRAP 8; neither old-setup.sh nor
  # bundle A creates them), through the master admin API:
  #   teknoir  confidential, the secret of realm teknoir's teknoir client
  #            (keycloak-client-secrets/teknoir, also the oauth2-proxy
  #            client secret), a service account holding master-realm
  #            manage-users, query-users and view-users
  #   argocd   confidential, keycloak-client-secrets/argocd
  #   harbor   confidential, service account and direct grants, a secret of
  #            its own
  # Then the severity: teknoir's client_credentials token lists realm
  # master's users. Prints "seed <client> <status>", "grant <status> <roles>"
  # and "sa-users <status>"; secrets and tokens stay in a 0700 dir on the VM.
  kc_vm 2>/dev/null <<'EOF' || true
# vm-script: e15_master_clients
kc_login
for c in teknoir argocd; do
  k -n teknoir-auth get secret keycloak-client-secrets -o go-template="{{index .data \"$c\" | base64decode}}" > "${d:?}/s_$c"
done
( umask 077; head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 > "${d:?}/s_harbor" )
python3 - "$d" "$DOMAIN" <<'PY'
import json, os, sys
d, dom = sys.argv[1], sys.argv[2]
extra = {
    "teknoir": {"serviceAccountsEnabled": True, "redirectUris": ["https://%s/oauth2/callback" % dom]},
    "argocd": {"redirectUris": ["https://argocd.%s/auth/callback" % dom]},
    "harbor": {"serviceAccountsEnabled": True, "directAccessGrantsEnabled": True,
               "redirectUris": ["https://harbor.%s/c/oidc/callback" % dom]},
}
for c, x in extra.items():
    body = {"clientId": c, "enabled": True, "publicClient": False, "standardFlowEnabled": True,
            "secret": open(os.path.join(d, "s_" + c)).read()}
    body.update(x)
    fd = os.open(os.path.join(d, c + ".json"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.write(fd, json.dumps(body).encode())
    os.close(fd)
PY
rm -f "${d:?}/s_argocd" "${d:?}/s_harbor"
for c in teknoir argocd harbor; do
  code="$(kc_curl -K "$d/hdr" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
            --data-binary @"$d/$c.json" "$KC/admin/realms/master/clients")" || code=000
  rm -f "${d:?}/${c:?}.json"
  echo "seed $c $code"
done
first_id() {
  python3 -c 'import json, sys
v = json.load(open(sys.argv[1]))
v = v[0] if isinstance(v, list) and v else v
print(v.get("id", "") if isinstance(v, dict) else "")' "$1" 2>/dev/null || true
}
kc_get "/realms/master/clients?clientId=teknoir" > "$d/c.json"; cid="$(first_id "$d/c.json")"
kc_get "/realms/master/clients?clientId=master-realm" > "$d/c.json"; mr="$(first_id "$d/c.json")"
code=000 n=0
if [ -n "$cid" ] && [ -n "$mr" ]; then
  kc_get "/realms/master/clients/$cid/service-account-user" > "$d/c.json"; sa="$(first_id "$d/c.json")"
  kc_get "/realms/master/clients/$mr/roles" > "$d/roles.json"
  n="$(python3 - "$d/roles.json" "$d/grant.json" <<'PY'
import json, sys
want = {"manage-users", "query-users", "view-users"}
roles = [r for r in json.load(open(sys.argv[1])) if r.get("name") in want]
open(sys.argv[2], "w").write(json.dumps(roles))
print(len(roles))
PY
)" || n=0
  if [ -n "$sa" ]; then
    code="$(kc_curl -K "$d/hdr" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
              --data-binary @"$d/grant.json" "$KC/admin/realms/master/users/$sa/role-mappings/clients/$mr")" || code=000
  fi
fi
echo "grant $code $n"
code="$(kc_curl -o "$d/sa.json" -w '%{http_code}' --data-urlencode grant_type=client_credentials --data-urlencode client_id=teknoir \
          --data-urlencode "client_secret@$d/s_teknoir" "$KC/realms/master/protocol/openid-connect/token")" || code=000
rm -f "${d:?}/s_teknoir"
u=000
if [ "$code" = 200 ]; then
  python3 - "$d/sa.json" "$d/sahdr" <<'PY'
import json, os, sys
t = json.load(open(sys.argv[1]))["access_token"]
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, ('header = "Authorization: Bearer %s"\n' % t).encode())
os.close(fd)
PY
  u="$(kc_curl -K "$d/sahdr" -o /dev/null -w '%{http_code}' "$KC/admin/realms/master/users?max=1")" || u=000
fi
rm -f "${d:?}/sa.json" "${d:?}/sahdr"
echo "sa-users $u"
EOF
}

e15_inject() {
  # the live teknoir-local state that A left and B must converge
  local rev now patch kind cfg n ops bad="" out
  if [[ -n "${E2E_E15_DEMO_PROFILE:-}" ]]; then
    if vm_kc apply -f - < "${E2E_E15_DEMO_PROFILE}" >/dev/null; then pass "Profile teknoir-demo from ${E2E_E15_DEMO_PROFILE}"; else fail "cannot apply ${E2E_E15_DEMO_PROFILE}"; fi
  elif jq -n --arg o "$(lower "${ADMIN_EMAIL}")" \
         '{apiVersion: "teknoir.org/v1", kind: "Profile", metadata: {name: "teknoir-demo"}, spec: {owner: {kind: "User", name: $o}}}' \
       | vm_kc create -f - >/dev/null; then
    pass "Profile teknoir-demo created as Backstage did (owner ${ADMIN_EMAIL}, not in GitOps)"
  else
    fail "cannot create Profile teknoir-demo"
  fi
  if wait_until 600 demo_apps_exist; then pass "A's profile-controller created the teknoir-demo Applications ($(demo_repos))"
  else fail "only $(demo_apps) teknoir-demo Applications after 600 s"; fi
  rev="$(vm_kc -n teknoir-system get applications.argoproj.io monitoring -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  patch="$(jq -cn --arg r "${rev}" --arg t "${now}" '{status: {operationState: {
      phase: "Failed", message: "one or more objects failed to apply, reason: e2e injected the live teknoir-local state",
      retryCount: 5, startedAt: $t, finishedAt: $t,
      operation: {sync: {revision: $r}, retry: {limit: 5}, initiatedBy: {automated: true}},
      syncResult: {revision: $r}}}}')"
  if vm_kc -n teknoir-system patch applications.argoproj.io monitoring --type=merge -p "${patch}" >/dev/null; then
    pass "monitoring carries a stale Failed operation for its current revision (retryCount 5)"
  else
    fail "cannot inject the Failed monitoring operation"
  fi
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    for cfg in $(vm_kc get "${kind}" -o name 2>/dev/null | grep -E '/monitoring.*admission$' || true); do
      n="$(vm_kc get "${cfg}" -o json 2>/dev/null | jq '.webhooks | length' || echo 0)"
      ops="$(jq -cn --argjson n "${n:-0}" '[range(0; $n) | {op: "add", path: "/webhooks/\(.)/clientConfig/caBundle", value: ""}]')"
      vm_kc patch "${cfg}" --type=json -p "${ops}" >/dev/null 2>&1 || bad+="${cfg%%.*}/${cfg##*/} "
    done
  done
  n="$(admission_ca)"
  if [[ -z "${bad}" && -n "${n#* }" ]]; then pass "the monitoring admission webhooks have an empty caBundle (${n#* })"
  else fail "could not empty the admission caBundles (patch refused: ${bad:-none}; configurations and empty webhooks: ${n})"; fi
  out="$(e15_master_clients)"
  assert_eq "realm master gets the legacy clients teknoir, argocd and harbor, as the live node has them" \
    "teknoir=201 argocd=201 harbor=201" "$(awk '$1 == "seed" { printf "%s%s=%s", s, $2, $3; s = " " }' <<<"${out}")"
  assert_eq "the teknoir client's service account holds master-realm manage-users, query-users and view-users" \
    "204 3" "$(awk '$1 == "grant" { print $2, $3 }' <<<"${out}")"
  assert_eq "the severity: teknoir's client_credentials token (the oauth2-proxy secret) lists realm master's users" \
    200 "$(awk '$1 == "sa-users" { print $2 }' <<<"${out}")"
}

e15() {
  tl_case E15 "live rehearsal: old layout -> migrate -> up A -> the live state -> up B"
  [[ -n "${E2E_BUNDLE:-}" && -n "${E2E_BUNDLE_B:-}" ]] || { skip_case "E2E_BUNDLE (A) and E2E_BUNDLE_B (B) required"; return 0; }
  [[ -n "${E2E_OLD_SETUP:-}" ]] || { skip_case "E2E_OLD_SETUP (old-tooling install command) not set"; return 0; }
  (( ALLOW_DESTROY )) || { skip_case "re-creates the VM: pass --allow-destroy"; return 0; }
  local a b owner pw="${LAN_HOME}/e2e/admin.pw" rerun="${LAN_HOME}/e2e/admin-rerun.pw" name mark out v created0 created1 claims
  a="$(bundle_dir "${E2E_BUNDLE}")" b="$(bundle_dir "${E2E_BUNDLE_B}")"
  fresh_vm || return 0
  rm -rf "${LAN_HOME:?}/.teknoir-airgap"
  reset_admin
  # as on the live node, the admin is the owner B's GitOps Profile names
  owner="$(bundle_profile_owner "${b}")"
  if [[ -n "${owner}" ]]; then adopt_owner "${owner}"; else tl_warn "cannot read the ${TEAMSPACE} owner from bundle B; the admin is ${ADMIN_EMAIL}"; fi
  name="$(user_name "${ADMIN_EMAIL}")"

  # --- 1. the live history with bundle A ------------------------------------------
  if VM_IP="${NODE_IP}" bash -c "${E2E_OLD_SETUP}"; then pass "old-style install completed"; else fail "E2E_OLD_SETUP failed"; return 0; fi
  if tk "${a}" migrate; then pass "migrate (A) exits 0"; else fail "migrate (A) failed"; return 0; fi
  if up_in "${a}" --force-images; then pass "up --force-images with bundle A exits 0"; else fail "up with bundle A failed"; return 0; fi
  wait_apps 2700 || true
  if tk "${a}" admin-user --email "${ADMIN_EMAIL}" --out "${pw}" && [[ -s "${pw}" ]]; then pass "admin-user (A) wrote the temporary password"
  else fail "admin-user (A) failed"; return 0; fi
  login_check "the admin signs in once on A (forced password change)"
  (( LOGIN_OK )) || return 0
  if tk "${a}" migrate --argo; then pass "migrate --argo (A) exits 0"; else fail "migrate --argo (A) failed"; fi
  if tk "${a}" migrate; then pass "migrate again (A, M6) exits 0"; else fail "migrate (A, M6) failed"; fi

  # --- 2. the live state -------------------------------------------------------------
  e15_inject
  if user_has_legacy_pw "${name}"; then pass "before B: User ${name} carries the legacy status.set_initial_password"
  else fail "before B: User ${name} carries no legacy status.set_initial_password"; fi
  assert_eq "before B: Keycloak user ${ADMIN_USER} is enabled with no required action" "enabled=true actions=0" "$(kc_user_state teknoir "${ADMIN_USER}")"
  created0="$(kc_pw_created "${ADMIN_USER}")"
  if [[ -n "${created0}" ]]; then pass "before B: the password credential's created_date is read (read-only SQL)"; else fail "cannot read the password credential's created_date"; fi
  assert_eq "before B: Secret keycloak-admin still has previous-password" "password previous-password username" "$(secret_keys teknoir-auth keycloak-admin)"
  # all three, and teknoir's shared secret gets a master token: so the
  # deletion after B is not met by an empty realm
  assert_eq "before B: realm master has the 3 legacy clients, and teknoir's secret gets a token there (client_credentials)" \
    "3 200" "$(kc_master_clients)"

  # --- 3. up with B ---------------------------------------------------------------------
  mark="$(transcript_mark)"
  if up_in "${b}"; then pass "up with bundle B exits 0 (post passes)"; else fail "up with bundle B failed"; return 0; fi
  out="$(transcript_since "${mark}")"
  if wait_until 2700 apps_healthy_except teknoir-demo-; then pass "every Application but teknoir-demo-* is Synced/Healthy"
  else fail "Applications not Synced/Healthy: $(apps_unhealthy_except teknoir-demo-)"; fi
  platform_checks "${out}"

  # --- 4. what B converged ----------------------------------------------------------------
  wait_until 600 demo_on_harbor || true
  assert_eq "every teknoir-demo Application points at Harbor" "harbor.${DOMAIN}/teknoir" "$(demo_repos)"
  if wait_until 1200 ts_apps_healthy teknoir-demo; then pass "the teknoir-demo Applications are Synced/Healthy"
  else tl_warn "teknoir-demo Applications not Synced/Healthy (a Backstage-made teamspace: warning only): $(ts_apps_unhealthy teknoir-demo)"; fi
  assert_eq "monitoring's operation Succeeded" Succeeded \
    "$(vm_kc -n teknoir-system get applications.argoproj.io monitoring -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  if wait_until 300 not_legacy "${name}"; then pass "user-controller cleared the legacy status.set_initial_password"
  else fail "User ${name} still carries status.set_initial_password"; fi
  assert_eq "no temporary-password Secret for ${name} (the user had no pending UPDATE_PASSWORD)" "" "$(k1_secret "${name}")"
  created1="$(kc_pw_created "${ADMIN_USER}")"
  assert_eq "the admin's Keycloak password was not changed (credential created_date)" "${created0}" "${created1}"
  assert_eq "Keycloak user ${ADMIN_USER} still has no required action" "enabled=true actions=0" "$(kc_user_state teknoir "${ADMIN_USER}")"
  assert_eq "post removed previous-password from Secret keycloak-admin" "password username" "$(secret_keys teknoir-auth keycloak-admin)"
  if wait_until 600 master_clients_gone; then pass "the master-realm legacy clients are deleted; the old teknoir secret gets 401 on master"
  else fail "master-realm legacy clients after B: $(kc_master_clients) (want 0 clients, HTTP 401)"; fi
  rm -f "${rerun}"
  if tk "${b}" admin-user --email "${ADMIN_EMAIL}" --out "${rerun}"; then pass "admin-user (B) re-run exits 0"; else fail "admin-user (B) re-run failed"; fi
  if [[ -e "${rerun}" ]]; then fail "admin-user (B) wrote ${rerun} although the password was handed out before"; else pass "admin-user (B) wrote no password file (already handed out)"; fi
  claims="$(user_claims "${name}")"
  for v in "owner@${TEAMSPACE}" owner@teknoir-demo; do
    if [[ " ${claims} " == *" ${v} "* ]]; then pass "admin-user granted ${v}"; else fail "User ${name} lacks ${v}: [${claims}]"; fi
  done
  login_check "the admin still signs in with the password set on A" --forbid-profile-form

  # --- 5. then the release checks on the migrated node --------------------------------------
  e11_checks
  e13_checks "${b}"
  e14_checks
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
  [[ "${E2E_E1_BASELINE:-auto}" =~ ^(auto|0|1)$ ]] || tl_die "E2E_E1_BASELINE must be auto, 0 or 1"
  [[ "${E2E_E4_ROLLBACK:-auto}" =~ ^(auto|0|1)$ ]] || tl_die "E2E_E4_ROLLBACK must be auto, 0 or 1"
  need sudo ip curl jq tar sha256sum ssh ssh-agent ssh-add setsid iptables stat python3 openssl awk
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
