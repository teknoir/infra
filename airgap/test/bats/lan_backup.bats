#!/usr/bin/env bats
# lan_backup.bats — `teknoir-airgap backup` with the site's
# BACKUP_AGE_RECIPIENTS (SEC-C8) and `rotate argocd-admin --out` (SEC-C9).
#
# The "node" is emulated without root and without containers: the recording
# ssh stub's handler runs the remote command line locally with
# /var/lib/teknoir-airgap rewritten to a sandbox directory and a sudo shim,
# and a small fake teknoir-node there plays the node runner (its own
# encryption is tested in airgap/test/node/run.sh). What is under test is the
# LAN side: no terminal is needed, it asks the node for --recipient-site,
# never for a passphrase export or a plaintext copy, checks the copy's sha256,
# writes 0600 and leaves the node's encrypted copy in place.

# shellcheck disable=SC2016,SC2030,SC2031,SC2154  # code strings for the inner shells; bats runs each test in a subshell; $stderr comes from run --separate-stderr

load test_helper

BID=teknoir-local-aoa0.0.4-20261008-itest000-gtest000

setup() {
  require_file "${LAN_BIN}"
  setup_stubs
  export HOME="${BATS_TEST_TMPDIR}/home"
  export NODE_STATE="${BATS_TEST_TMPDIR}/node-state"
  export SHIM="${BATS_TEST_TMPDIR}/shim"
  mkdir -p "${HOME}" "${SHIM}" "${NODE_STATE}"
  BUNDLE="$("${REPO_ROOT}/airgap/test/lan/make-fake-bundle.sh" --out "${BATS_TEST_TMPDIR}/b" \
    --node-ip 10.0.0.1 --node teknoir@10.0.0.1 2>/dev/null)"
  install -m 0755 "${LAN_BIN}" "${BUNDLE}/teknoir-airgap"
  # syntactically valid age recipients (no real keys)
  R1="age1$(printf 'q%.0s' {1..58})"
  R2="age1$(printf 'p%.0s' {1..58})"
  SITE="${BATS_TEST_TMPDIR}/teknoir-local.env"
  { cat "${BUNDLE}/site/teknoir-local.env"; printf 'BACKUP_AGE_RECIPIENTS="%s %s"\n' "${R1}" "${R2}"; } > "${SITE}"
  # the host key is pinned already; the node has this bundle's payload
  mkdir -p "${HOME}/.teknoir-airgap/teknoir-local" "${NODE_STATE}/bundles/${BID}/node/bin"
  echo "10.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeHostKeyForTestsOnly000000000000000000" \
    > "${HOME}/.teknoir-airgap/teknoir-local/known_hosts"
  sha256sum < "${BUNDLE}/node/SHA256SUMS" | cut -d' ' -f1 > "${NODE_STATE}/bundles/${BID}/payload.sha256"
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case $1 in -n) shift ;; -p) shift 2 ;; *) break ;; esac; done\nexec "$@"\n' > "${SHIM}/sudo"
  chmod +x "${SHIM}/sudo"
  # the fake node runner: canonical paths out, sandbox paths in (the ssh
  # handler rewrites every command line)
  cat > "${NODE_STATE}/bundles/${BID}/node/bin/teknoir-node" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${NODE_STATE}/runner.log"
cmd=$1; shift
site='' stream='' take=0 name='' mode=''
while [ $# -gt 0 ]; do
  case $1 in
    --site) site=$2; shift ;;
    --stream) stream=$2; shift ;;
    --name) name=$2; shift ;;
    --take) take=1 ;;
    --recipient-site|--export) mode=$1 ;;
  esac
  shift
done
case $cmd in
  backup) ;;
  credentials) [ -t 1 ] && exit 1; printf 'new-argocd-admin-value\n'; exit 0 ;;
  rotate) echo "fake rotate" >&2; exit 0 ;;
  *) exit 2 ;;
esac
if [ -n "${stream}" ]; then
  [ -t 1 ] && { echo "refusing a terminal" >&2; exit 1; }
  cat "${stream}"
  [ "${FAKE_CORRUPT:-0}" = 1 ] && echo corrupted
  exit 0
fi
[ "${mode}" = --recipient-site ] || { echo "fake runner: unexpected backup mode ${mode:-take}" >&2; exit 3; }
. "${site}"
[ -n "${BACKUP_AGE_RECIPIENTS:-}" ] || { echo "no recipients in ${site}" >&2; exit 4; }
ts=${name:-20261009T120000Z}
[ "${take}" = 1 ] && ts=20261009T130000Z
mkdir -p "${NODE_STATE}/exports"
{ echo "age-encryption.org/v1 (fake, ${BACKUP_AGE_RECIPIENTS})"; head -c 2048 /dev/urandom | base64; } > "${NODE_STATE}/exports/${ts}.tar.age"
chmod 600 "${NODE_STATE}/exports/${ts}.tar.age"
echo "fake: encrypted ${ts}" >&2
echo "/var/lib/teknoir-airgap/exports/${ts}.tar.age"
EOF
  chmod +x "${NODE_STATE}/bundles/${BID}/node/bin/teknoir-node"
  stub_handler <<'EOF'
stub_ssh() {
  local G=0 O=0 target="" cmd=""
  while [ $# -gt 0 ]; do
    case $1 in
      -G) G=1 ;;
      -O) O=1; shift ;;
      -o|-p|-i|-l|-F|-E|-c|-m|-S|-L|-R|-D|-W|-J|-b|-e) shift ;;
      -*) ;;
      *) if [ -z "${target}" ]; then target=$1; else cmd="${cmd:+${cmd} }$1"; fi ;;
    esac
    shift
  done
  if [ "${G}" = 1 ]; then printf 'user %s\nhostname %s\nport 22\n' "${target%@*}" "${target#*@}"; return 0; fi
  [ "${O}" = 1 ] && return 0
  [ -n "${cmd}" ] || return 0
  cmd="${cmd//\/var\/lib\/teknoir-airgap/${NODE_STATE}}"
  PATH="${SHIM}:${PATH}" sh -c "${cmd}"
}
EOF
}

lan() { bash "${BUNDLE}/teknoir-airgap" "$@" --site "${SITE}" </dev/null; }

@test "backup with BACKUP_AGE_RECIPIENTS needs no terminal and never asks for a passphrase or plaintext" {
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out"
  [ "${status}" -eq 0 ] || { echo "${stderr}"; return 1; }
  local f="${BATS_TEST_TMPDIR}/out/teknoir-backup-teknoir-local-20261009T130000Z.tar.age"
  [ -f "${f}" ]
  [ "$(stat -c %a "${f}")" = 600 ]
  cmp -s "${f}" "${NODE_STATE}/exports/20261009T130000Z.tar.age"
  grep -qx -- "backup --recipient-site --take --site ${NODE_STATE}/site/teknoir-local.env" "${NODE_STATE}/runner.log"
  grep -qx -- "backup --stream ${NODE_STATE}/exports/20261009T130000Z.tar.age --keep --site ${NODE_STATE}/site/teknoir-local.env" "${NODE_STATE}/runner.log"
  refute_grep -e '--export' "${NODE_STATE}/runner.log"
  # the node keeps its encrypted copy; the site config with the recipients reached it
  [ -f "${NODE_STATE}/exports/20261009T130000Z.tar.age" ]
  grep -q "BACKUP_AGE_RECIPIENTS=\"${R1} ${R2}\"" "${NODE_STATE}/site/teknoir-local.env"
  [[ "${stderr}" == *"2 age recipient(s)"* && "${stderr}" == *"age -d -i KEYFILE"* ]]
  [ -z "$(find "${BATS_TEST_TMPDIR}/out" -name '*.partial')" ]
  [ -z "${output}" ]
}

@test "backup --name copies an existing node backup, encrypted to the recipients" {
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out" --name 20261009T051050Z
  [ "${status}" -eq 0 ] || { echo "${stderr}"; return 1; }
  [ -f "${BATS_TEST_TMPDIR}/out/teknoir-backup-teknoir-local-20261009T051050Z.tar.age" ]
  grep -qx -- "backup --recipient-site --name 20261009T051050Z --site ${NODE_STATE}/site/teknoir-local.env" "${NODE_STATE}/runner.log"
  refute_grep -e '--take' "${NODE_STATE}/runner.log"
}

@test "a copy whose sha256 differs from the node's is refused and leaves no file" {
  export FAKE_CORRUPT=1
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"does not match the node's copy"* ]]
  [ -z "$(find "${BATS_TEST_TMPDIR}/out" -type f)" ]
  [ -f "${NODE_STATE}/exports/20261009T130000Z.tar.age" ]
}

@test "backup without recipients still needs a terminal (passphrase); nothing reaches the node" {
  cp "${BUNDLE}/site/teknoir-local.env" "${SITE}"
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"run it in a terminal"* ]]
  [ -z "$(stub_calls ssh)" ]
}

@test "an invalid or private BACKUP_AGE_RECIPIENTS entry is refused before ssh" {
  printf 'BACKUP_AGE_RECIPIENTS="%s age1short"\n' "${R1}" >> "${SITE}"
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"is not an age public key"* ]]
  [ -z "$(stub_calls ssh)" ]
  local priv
  priv="AGE-SECRET-KEY-""1$(printf 'Q%.0s' {1..58})"   # assembled: no key-shaped literal in the repo
  printf 'BACKUP_AGE_RECIPIENTS="%s"\n' "${priv}" >> "${SITE}"
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out"
  [ "${status}" -eq 1 ]
  [[ "${stderr}" == *"PRIVATE key"* && "${stderr}" != *"${priv}"* ]]
}

@test "backup --name must be a backup timestamp" {
  run --separate-stderr lan backup --out "${BATS_TEST_TMPDIR}/out" --name latest
  [ "${status}" -eq 2 ]
  [ -z "$(stub_calls ssh)" ]
}

@test "rotate argocd-admin --out writes the new password from credentials argocd-admin, 0600" {
  run --separate-stderr lan rotate argocd-admin --out "${BATS_TEST_TMPDIR}/argocd.txt"
  [ "${status}" -eq 0 ] || { echo "${stderr}"; return 1; }
  [ "$(cat "${BATS_TEST_TMPDIR}/argocd.txt")" = new-argocd-admin-value ]
  [ "$(stat -c %a "${BATS_TEST_TMPDIR}/argocd.txt")" = 600 ]
  grep -qx -- "rotate argocd-admin --site ${NODE_STATE}/site/teknoir-local.env" "${NODE_STATE}/runner.log"
  grep -qx -- "credentials argocd-admin --site ${NODE_STATE}/site/teknoir-local.env" "${NODE_STATE}/runner.log"
  [[ "${output}${stderr}" != *new-argocd-admin-value* ]]
}

@test "rotate --out is only for argocd-admin" {
  run --separate-stderr lan rotate oauth2-proxy-cookie --out "${BATS_TEST_TMPDIR}/x.txt"
  [ "${status}" -eq 2 ]
  [ -z "$(stub_calls ssh)" ]
}

@test "help documents backup --name and rotate --out" {
  run bash "${LAN_BIN}" help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--name TS"* && "${output}" == *"BACKUP_AGE_RECIPIENTS"* && "${output}" == *"argocd-admin"* ]]
}
