#!/usr/bin/env bash
# integration.sh PHASE - teknoir-airgap against a real OpenSSH server, run by
# run.sh inside the bash 3.2 "LAN host" container, one phase at a time (run.sh
# changes the node between phases).
#
# Environment: B (bundle directory), NODE_IP, FP (node host key fingerprint),
# PW (the node user's sudo password, test only), TRANSCRIPT.
# shellcheck disable=SC2016  # single-quoted scripts run in sh -c
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "${here}/lib.sh"
T=${B}/teknoir-airgap
KH=/root/.teknoir-airgap/teknoir-local/known_hosts
KC=${B}/tools/linux-amd64/kubectl

# with_tty DESCRIPTION EXPECTED-RC CMD...: run CMD under expect (a terminal),
# answering a sudo password prompt with $PW.
with_tty() {
  local desc=$1 want=$2
  shift 2
  LAST_OUT=$(PW=${PW} expect "${here}/tty.exp" "$@" 2>&1)
  LAST_RC=$?
  { printf '\n$ (tty) %s\n' "$*"; printf '%s\n' "${LAST_OUT}"; } >>"${TRANSCRIPT}"
  if [ "${LAST_RC}" -eq "${want}" ]; then ok "${desc} (exit ${LAST_RC})"; else bad "${desc}: exit ${LAST_RC}, expected ${want}"; show_last; fi
}

mode_of() { stat -c %a "$1" 2>/dev/null; }

case $1 in
first-use)
  section "first connection: host key confirmation, no sudo yet"
  expect_rc 1 "up without a terminal and without --host-key" "${T}" up
  expect_out "pass --host-key ${FP}" "names the fingerprint to confirm"
  check "nothing pinned yet" test ! -s "${KH}"
  expect_rc 1 "up with a wrong --host-key" "${T}" up --host-key SHA256:AAAAwrongwrongwrong
  expect_out "none of them has the fingerprint" "refuses the wrong fingerprint"
  expect_rc 1 "up with the right --host-key but no passwordless sudo and no terminal" "${T}" up --host-key "${FP}"
  expect_out "no passwordless sudo yet" "explains the sudo setup"
  check "the confirmed key is pinned" grep -q "^${NODE_IP} ssh-ed25519 " "${KH}"
  check "known_hosts is private" test "$(mode_of "${KH}")" = 600
  expect_rc 1 "up --dry-run does not set up sudo" "${T}" up --dry-run
  expect_out "run ./teknoir-airgap up once in a terminal" "dry run points at the one-time setup"
  ;;
before-up)
  section "a node that never ran up: the live migration order (M2 backup, M3 migrate) and the other runner commands"
  expect_rc 1 "migrate --dry-run before the sudo setup" "${T}" migrate --dry-run
  expect_out "a dry run does not set it up; run ./teknoir-airgap backup --out DIR once in a terminal first" "points at the M2 backup, not at up"
  with_tty "backup in a terminal: sudo setup, payload and site config, then the backup" 0 "${T}" backup --out /tmp/bk0
  expect_out "one-time setup: installing /etc/sudoers.d/teknoir-airgap" "sets up sudo"
  expect_out "sending 9 of 9 payload files" "sends the payload the runner lives in"
  check "the encrypted backup arrived" sh -c 'ls /tmp/bk0/teknoir-backup-teknoir-local-*.tar.age >/dev/null'
  expect_rc 0 "migrate --dry-run" "${T}" migrate --dry-run
  expect_out "fake migrate --site /var/lib/teknoir-airgap/site/teknoir-local.env --dry-run" "the runner reads the pushed site config"
  expect_rc 0 "migrate" "${T}" migrate
  mkdir -p /tmp/out0
  expect_rc 0 "credentials" "${T}" credentials keycloak-admin --out /tmp/out0/keycloak-admin.txt
  check "the credential file has the value" grep -qx 's3cr3t-keycloak-admin-value' /tmp/out0/keycloak-admin.txt
  expect_rc 0 "rotate" "${T}" rotate oauth2-proxy-cookie
  expect_rc 0 "admin-user" "${T}" admin-user --email first.admin@teknoir.ai --out /tmp/out0/admin.txt
  check "the temporary password is in the file" grep -qx 's3cr3t-temporary-password' /tmp/out0/admin.txt
  expect_rc 0 "status" "${T}" status
  expect_out "fake status --site /var/lib/teknoir-airgap/site/teknoir-local.env" "status runs teknoir-node with the site config"
  ;;
site-refresh-credentials)
  section "a stale site config on the node is replaced (credentials)"
  expect_rc 0 "credentials after the node's site config changed" "${T}" credentials keycloak-admin --out /tmp/out0/keycloak-admin.txt
  ;;
site-refresh-status)
  section "a stale site config on the node is replaced (status)"
  expect_rc 0 "status after the node's site config changed" "${T}" status
  ;;
sudo-setup)
  section "first up in a terminal: one sudo password, then the full run"
  with_tty "up in a terminal installs sudoers and converges" 0 "${T}" up
  expect_out "installed /etc/sudoers.d/teknoir-airgap" "reports the sudoers setup"
  expect_out "sending 9 of 9 payload files" "sends the whole payload"
  expect_out "fake converge --site /var/lib/teknoir-airgap/site/teknoir-local.env --lan-time [0-9]* --lan-user root" "runs the converge with site, LAN time and operator"
  expect_out "saved the platform CA certificate" "saves the CA certificate"
  expect_out "wrote /root/.kube/config with context teknoir-local" "writes the kubeconfig"
  check "CA certificate cached" grep -q 'BEGIN CERTIFICATE' /root/.teknoir-airgap/teknoir-local/teknoir-root-ca.crt
  check "kubeconfig is private" test "$(mode_of /root/.kube/config)" = 600
  check "kubeconfig points at NODE_IP" grep -q "server: https://${NODE_IP}:6443" /root/.kube/config
  check "the LAN log exists and is private" sh -c 'f=$(ls -1 /root/.teknoir-airgap/teknoir-local/logs/*-up.log | tail -n 1); test "$(stat -c %a "$f")" = 600'
  ;;
idempotent)
  section "second up: nothing to send, nothing to change"
  expect_rc 0 "second up (no terminal needed now)" "${T}" up
  expect_out "already has this bundle's payload (9 files)" "sends nothing"
  expect_out "context teknoir-local in /root/.kube/config is up to date" "kubeconfig unchanged"
  expect_no_out "installed /etc/sudoers.d" "no second sudo setup"
  ;;
resend)
  section "damaged payload on the node"
  expect_rc 0 "up after run.sh damaged a payload file and added a stray one" "${T}" up
  expect_out "sending 1 of 9 payload files" "sends only the damaged file"
  expect_out "removed unlisted payload file stray-file" "removes the stray file"
  ;;
kubeconfig)
  section "kubeconfig replaces stale entries"
  KUBECONFIG=/root/.kube/config "${KC}" config set-cluster teknoir-local --server=https://10.9.9.9:6443 >/dev/null
  KUBECONFIG=/root/.kube/config "${KC}" config set-credentials teknoir-local --token=stale-token >/dev/null
  KUBECONFIG=/root/.kube/config "${KC}" config set-cluster other --server=https://other.example:6443 >/dev/null
  KUBECONFIG=/root/.kube/config "${KC}" config set-credentials other --token=other-token >/dev/null
  KUBECONFIG=/root/.kube/config "${KC}" config set-context other --cluster=other --user=other >/dev/null
  KUBECONFIG=/root/.kube/config "${KC}" config use-context other >/dev/null
  expect_rc 0 "kubeconfig" "${T}" kubeconfig
  expect_out "replaced context teknoir-local in /root/.kube/config" "reports the replacement"
  check "teknoir-local server is NODE_IP again" test "$(KUBECONFIG=/root/.kube/config "${KC}" config view -o 'jsonpath={.clusters[?(@.name=="teknoir-local")].cluster.server}')" = "https://${NODE_IP}:6443"
  check "the stale token is gone (replaced, not merged)" test -z "$(KUBECONFIG=/root/.kube/config "${KC}" config view -o 'jsonpath={.users[?(@.name=="teknoir-local")].user.token}')"
  check "the other context is kept" test "$(KUBECONFIG=/root/.kube/config "${KC}" config get-contexts -o name | grep -c '^other$')" = 1
  check "current-context is unchanged" test "$(KUBECONFIG=/root/.kube/config "${KC}" config current-context)" = other
  check "a private backup of the previous file exists" test "$(mode_of /root/.kube/config.teknoir-airgap.bak)" = 600
  expect_rc 0 "kubeconfig --context NAME --kubeconfig FILE" "${T}" kubeconfig --context lab --kubeconfig /tmp/kc-lab
  check "standalone file has context lab" grep -q 'current-context: lab' /tmp/kc-lab
  ;;
secrets)
  section "credentials and admin-user write files only"
  mkdir -p /tmp/out
  expect_rc 0 "credentials platform-admin --out FILE" "${T}" credentials platform-admin --out /tmp/out/platform-admin.txt
  check "the credential file has the value" grep -qx 's3cr3t-platform-admin-value' /tmp/out/platform-admin.txt
  check "the credential file is 0600" test "$(mode_of /tmp/out/platform-admin.txt)" = 600
  expect_no_out "s3cr3t" "the value is not printed"
  expect_rc 2 "credentials without --out" "${T}" credentials platform-admin
  expect_rc 2 "credentials --out - (stdout)" "${T}" credentials platform-admin --out -
  expect_rc 1 "credentials into the bundle directory" "${T}" credentials platform-admin --out "${B}/secret.txt"
  expect_out "refusing to write into the bundle directory" "refuses the bundle directory"
  expect_rc 1 "credentials to a terminal device" "${T}" credentials platform-admin --out /dev/null
  expect_rc 0 "admin-user --email (mixed case) --out" "${T}" admin-user --email Anders.Aslund@Teknoir.AI --out /tmp/out/admin.txt
  expect_out "admin user anders.aslund@teknoir.ai is set up" "uses the address in lower case"
  expect_out "creating User anders.aslund-at-teknoir.ai" "the runner's log reaches the operator"
  check "the temporary password is in the file" grep -qx 's3cr3t-temporary-password' /tmp/out/admin.txt
  check "the admin file is 0600" test "$(mode_of /tmp/out/admin.txt)" = 600
  expect_no_out "s3cr3t" "the temporary password is not printed"
  expect_rc 2 "admin-user with '_' in the address (the node refuses it)" "${T}" admin-user --email a_b@teknoir.ai --out /tmp/out/x.txt
  expect_rc 1 "admin-user that fails on the node" "${T}" admin-user --email fail@teknoir.ai --out /tmp/out/fail.txt
  expect_out "teknoir-node admin-user failed on the node" "reports the failure"
  check "no --out file after a failure" test ! -e /tmp/out/fail.txt
  check "no temporary file left next to --out" sh -c '! ls -A /tmp/out | grep -q "^\.teknoir-airgap\."'
  expect_rc 0 "admin-user for a user without a temporary password" "${T}" admin-user --email existing@teknoir.ai --out /tmp/out/existing.txt
  expect_out "recorded no temporary password" "says that no password was written"
  check "no --out file without a password" test ! -e /tmp/out/existing.txt
  ;;
passthrough)
  section "rotate, migrate and up flags reach teknoir-node"
  expect_rc 0 "rotate NAME --i-know" "${T}" rotate oauth2-proxy-cookie --i-know
  expect_rc 0 "migrate --dry-run" "${T}" migrate --dry-run
  expect_rc 0 "migrate --undo NAME" "${T}" migrate --undo teknoir-coredns-custom
  expect_rc 0 "migrate" "${T}" migrate
  expect_rc 2 "migrate --dry-run --undo" "${T}" migrate --dry-run --undo x
  expect_rc 0 "migrate --argo --dry-run" "${T}" migrate --argo --dry-run
  expect_rc 0 "migrate --argo" "${T}" migrate --argo
  expect_rc 2 "migrate --argo --undo" "${T}" migrate --argo --undo x
  ( umask 077; printf 'kc-admin-s3cr3t' >/tmp/kcpw )
  expect_rc 0 "migrate --keycloak-admin-password-file (0600)" "${T}" migrate --keycloak-admin-password-file /tmp/kcpw
  expect_out "stdin=15$" "the password reaches teknoir-node on stdin"
  expect_no_out "kc-admin-s3cr3t" "the password is never shown"
  expect_rc 2 "--keycloak-admin-password-file with --argo" "${T}" migrate --argo --keycloak-admin-password-file /tmp/kcpw
  chmod 644 /tmp/kcpw
  expect_rc 1 "--keycloak-admin-password-file readable by others" "${T}" migrate --keycloak-admin-password-file /tmp/kcpw
  expect_out "chmod 600" "says how to fix the mode"
  rm -f /tmp/kcpw
  expect_rc 0 "up with every converge flag" "${T}" up --dry-run --rollback --sync-clock --reapply istio --force-images -- --extra-flag
  expect_out "dry run complete" "dry run says nothing changed"
  ;;
status)
  section "status"
  expect_rc 0 "status" "${T}" status
  expect_out "clock:    skew [0-9]* s" "status reports the clock skew"
  expect_out "app-of-apps   Synced" "status lists the Applications"
  expect_out "fake status --site /var/lib/teknoir-airgap/site/teknoir-local.env --lan-time" "status runs teknoir-node status"
  ;;
trust)
  section "trust and doctor"
  expect_rc 1 "doctor before trust" "${T}" doctor
  expect_out "FAIL  teknoir.lantest does not resolve" "doctor sees the missing names"
  expect_rc 0 "trust --print" "${T}" trust --print
  expect_out "# BEGIN teknoir-airgap teknoir-local" "prints the hosts block"
  expect_out "^${NODE_IP} teknoir.lantest harbor.teknoir.lantest argocd.teknoir.lantest" "the block maps the names to NODE_IP"
  expect_out "update-ca-certificates" "prints the Debian/Ubuntu commands"
  expect_out "security add-trusted-cert" "prints the macOS commands"
  check "trust --print changed nothing" sh -c '! grep -q "teknoir-airgap teknoir-local" /etc/hosts'
  expect_rc 0 "trust" "${T}" trust
  check "/etc/hosts has the block" grep -q "^${NODE_IP} teknoir.lantest harbor.teknoir.lantest" /etc/hosts
  check "the CA is in the system store" test -f /usr/local/share/ca-certificates/teknoir-airgap-teknoir-local.crt
  expect_rc 0 "trust again" "${T}" trust
  expect_out "already has the teknoir-local block" "hosts block unchanged"
  expect_out "already has the platform CA" "CA unchanged"
  check "only one block in /etc/hosts" test "$(grep -c '^# BEGIN teknoir-airgap teknoir-local$' /etc/hosts)" = 1
  expect_rc 1 "doctor after trust (the test node lacks some converge tools)" "${T}" doctor
  expect_out "ok    harbor.teknoir.lantest -> ${NODE_IP}" "names resolve"
  expect_out "ok    the OS trusts the platform CA" "CA trusted"
  expect_out "ssh as teknoir works and the host key matches" "ssh ok"
  expect_out "ok    passwordless sudo works" "sudo ok"
  expect_out "ok    NODE_IP ${NODE_IP} is configured on the node" "NODE_IP is the node's"
  expect_out "missing on the node:" "reports missing node tools"
  ;;
backup)
  section "backup"
  expect_rc 1 "backup without a terminal" "${T}" backup --out /tmp/bk
  with_tty "backup --out DIR in a terminal" 0 "${T}" backup --out /tmp/bk
  f=$(find /tmp/bk -name 'teknoir-backup-teknoir-local-*.tar.age' | tail -n 1)
  check "the encrypted backup exists" test -n "${f}"
  check "the backup file is 0600" test "$(mode_of "${f}")" = 600
  check "the backup carries the age header" grep -q '^age-encryption.org/v1' "${f}"
  check "the backup holds the node's backup directory" sh -c "tail -n +2 '${f}' | tar -tf - | grep -q '/dump.sql$'"
  expect_no_out "s3cr3t" "backup content is not printed"
  ;;
hostkey-changed)
  section "node reinstalled: host key changed"
  expect_rc 1 "up after the host key changed" "${T}" up
  expect_out "host key mismatch" "names the problem"
  expect_out "ssh-keygen -R '${NODE_IP}' -f '${KH}'" "prints the exact ssh-keygen -R command"
  expect_out "./teknoir-airgap up --forget-host-key" "prints the --forget-host-key fix"
  with_tty "up --forget-host-key in a terminal, confirming the new key with yes" 0 "${T}" up --forget-host-key
  expect_out "presents this ssh-ed25519 host key" "shows the key type"
  expect_out "${FP}" "shows the new fingerprint"
  expect_out "forgot the pinned host key" "forgets the old key"
  check "only the new key is pinned" test "$(grep -c "^${NODE_IP} " "${KH}")" = 1
  expect_rc 0 "up again with the new key, no prompt" "${T}" up
  ;;
*)
  echo "unknown phase $1" >&2
  exit 2
  ;;
esac
summary
