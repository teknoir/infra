#!/usr/bin/env bash
# offline.sh - teknoir-airgap tests that need no node, run under bash 3.2
# (docker.io/library/bash:3.2) by run.sh: help, verify (list and map
# MANIFEST formats, tampering), version, doctor with a stub ssh, and up/status
# with --local (this container plays the node; it is disposable and root).
#
# Usage (inside the container): offline.sh REPO LIST_BUNDLE MAP_BUNDLE
set -u
REPO=$1 B=$2 M=$3
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "${REPO}/airgap/test/lan/lib.sh"

echo "bash ${BASH_VERSION}"
T=${B}/teknoir-airgap

section "help and usage errors"
expect_rc 0 "help" "${T}" help
expect_out "Commands:" "help lists the commands"
expect_rc 0 "--help after a command" "${T}" up --help
expect_rc 0 "help from the repository (no MANIFEST.yaml needed)" "${REPO}/airgap/teknoir-airgap" help
expect_rc 2 "no command" "${T}"
expect_rc 2 "unknown command" "${T}" frobnicate
expect_out "unknown command 'frobnicate'" "names the unknown command"
expect_rc 2 "option the command does not take" "${T}" status --print
expect_rc 2 "unknown option" "${T}" up --bogus
expect_rc 2 "credentials without a name" "${T}" credentials --out /tmp/x
expect_rc 2 "admin-user with '+' in the address" "${T}" admin-user --email a+b@example.com --out /tmp/x

section "verify"
expect_rc 0 "verify, list-format MANIFEST" "${T}" verify
expect_out "bundle verified" "verify reports success"
expect_rc 0 "verify, map-format MANIFEST" "${M}/teknoir-airgap" verify
expect_rc 1 "verify from the repository fails clearly" "${REPO}/airgap/teknoir-airgap" verify
expect_out "no MANIFEST.yaml" "explains the missing MANIFEST.yaml"
ln -sf "${T}" /tmp/teknoir-airgap-link
cd / || exit 1
expect_rc 0 "verify through a symlink from another directory" /tmp/teknoir-airgap-link verify
cd - >/dev/null || exit 1
expect_rc 0 "version" "${T}" version
expect_out "appOfAppsVersion: *0.0.4" "version prints the app-of-apps version"

f=${B}/node/images/fake-image/blob2
cp "${f}" /tmp/blob2.orig
printf x >>"${f}"
expect_rc 1 "verify detects a modified file" "${T}" verify
expect_out "modified: node/images/fake-image/blob2" "names the modified file"
cp /tmp/blob2.orig "${f}"
mv "${B}/node/images/fake-image/blob1" /tmp/blob1.orig
expect_rc 1 "verify detects a missing file" "${T}" verify
expect_out "missing:  node/images/fake-image/blob1" "names the missing file"
mv /tmp/blob1.orig "${B}/node/images/fake-image/blob1"
touch "${B}/node/unlisted-file"
expect_rc 1 "verify detects an unlisted file" "${T}" verify
expect_out "node/unlisted-file" "names the unlisted file"
rm -f "${B}/node/unlisted-file"
ln -s teknoir-airgap "${B}/a-link"
expect_rc 1 "verify refuses a symlink" "${T}" verify
rm -f "${B}/a-link"
touch "${B}/.DS_Store" "${B}/docs/._OPERATE.md"
expect_rc 0 "verify ignores macOS Finder metadata" "${T}" verify
rm -f "${B}/.DS_Store" "${B}/docs/._OPERATE.md"
# node/SHA256SUMS that disagrees with MANIFEST.yaml (MANIFEST updated to match)
cp "${B}/node/SHA256SUMS" /tmp/sums.orig; cp "${B}/MANIFEST.yaml" /tmp/manifest.orig
sed -i '/blob2$/d' "${B}/node/SHA256SUMS"
new=$(sha256sum "${B}/node/SHA256SUMS" | cut -d' ' -f1)
awk -v h="${new}" 'p { sub(/sha256: .*/, "sha256: " h); p = 0 } /path: node\/SHA256SUMS$/ { p = 1 } { print }' /tmp/manifest.orig >"${B}/MANIFEST.yaml"
expect_rc 1 "verify detects node/SHA256SUMS disagreeing with MANIFEST.yaml" "${T}" verify
expect_out "does not agree" "explains the disagreement"
cp /tmp/sums.orig "${B}/node/SHA256SUMS"; cp /tmp/manifest.orig "${B}/MANIFEST.yaml"
expect_rc 0 "verify passes again after restoring" "${T}" verify

section "doctor with a stub ssh (this container plays the node)"
PATH=${REPO}/airgap/test/lan/stub:${PATH}
export PATH
expect_rc 1 "doctor fails while the names do not resolve" "${T}" doctor
expect_out "every file matches MANIFEST.yaml" "doctor verifies the bundle"
expect_out "FAIL  teknoir.lantest does not resolve" "doctor reports name resolution"
expect_out "no host key pinned" "doctor reports the missing host key pin"
expect_rc 1 "first connection without a terminal and without --host-key" "${T}" status
expect_out "pass --host-key SHA256:stubfingerprint" "suggests --host-key with the offered fingerprint"
expect_rc 1 "--host-key that does not match" "${T}" status --host-key SHA256:wrong
expect_out "none of them has the fingerprint" "explains the fingerprint mismatch"
expect_rc 0 "status pins the confirmed key and reports" "${T}" status --host-key SHA256:stubfingerprint0000000000000000000000000000
expect_out "pinned the host key" "status pinned the key"
expect_out "k3s is not installed" "status falls back to the built-in checks"
check "known_hosts has the pinned key" grep -q '^10.0.0.1 ' /root/.teknoir-airgap/teknoir-local/known_hosts
printf '10.0.0.1 teknoir.lantest harbor.teknoir.lantest argocd.teknoir.lantest auth.teknoir.lantest keycloak.teknoir.lantest grafana.teknoir.lantest\n' >>/etc/hosts
expect_rc 1 "doctor after names resolve (the container lacks node tools)" "${T}" doctor
expect_out "ok    harbor.teknoir.lantest -> 10.0.0.1" "doctor resolves the names"
expect_out "ssh as teknoir works" "doctor checks ssh"
expect_out "passwordless sudo works" "doctor checks sudo"
expect_out "clock skew [01] s" "doctor checks the clock"
expect_out "missing on the node:" "doctor lists the node tools that are missing"

section "up --local (payload sync and runner, busybox tools)"
PD=/var/lib/teknoir-airgap/bundles/teknoir-local-aoa0.0.4-20261008-itest000-gtest000/node
expect_rc 0 "up --local, first run" "${T}" up --local
expect_out "sending 9 of 9 payload files" "first run sends every payload file"
expect_out "fake converge --site /var/lib/teknoir-airgap/site/teknoir-local.env --lan-time" "the runner gets --site and --lan-time"
expect_out "--lan-user root" "the runner gets --lan-user"
check "payload unpacked with its modes" test -x "${PD}/bin/teknoir-node"
check "site config copied to the node" cmp -s "${B}/site/teknoir-local.env" /var/lib/teknoir-airgap/site/teknoir-local.env
expect_rc 0 "up --local, second run" "${T}" up --local
expect_out "already has this bundle's payload (9 files)" "second run sends nothing"
printf x >>"${PD}/images/fake-image/blob1"
touch "${PD}/stray-file"
expect_rc 0 "up --local after damaging one payload file" "${T}" up --local
expect_out "sending 1 of 9 payload files" "only the damaged file is sent again"
expect_out "removed unlisted payload file stray-file" "unlisted payload files are removed"
check "the stray file is gone" test ! -e "${PD}/stray-file"
expect_rc 0 "up --local --dry-run passes --dry-run" "${T}" up --local --dry-run
expect_out "fake converge .*--dry-run" "the runner sees --dry-run"
expect_rc 0 "status --local uses the runner" "${T}" status --local
expect_out "fake status --site" "status calls teknoir-node status"
expect_rc 2 "kubeconfig refuses --local" "${T}" kubeconfig --local

summary
