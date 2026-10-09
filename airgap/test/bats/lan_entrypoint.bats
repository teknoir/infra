#!/usr/bin/env bats
# lan_entrypoint.bats — surface checks of the LAN entrypoint airgap/teknoir-airgap
# (I-11): the commands the design and the runbooks rely on exist.
#
# Its behaviour (bash 3.2 in docker, MANIFEST verify, host-key pinning,
# content-addressed sync, kubeconfig replacement, sudo setup, never-print)
# is tested by airgap/test/lan/run.sh against a real sshd in containers; the
# VM e2e (airgap/test/vm/e2e.sh) runs it from the LAN namespace.

# shellcheck disable=SC2016,SC2030,SC2031  # code strings for the inner shells; bats runs each test in a subshell

load test_helper

setup() {
  require_file "${LAN_BIN}"
}

@test "help lists every command of the operator flow" {
  run bash "${LAN_BIN}" help
  [ "${status}" -eq 0 ]
  for c in up status kubeconfig trust credentials admin-user backup rotate doctor migrate; do
    grep -qE "^[[:space:]]+${c}( |$)" <<<"${output}" || { echo "missing command: ${c}"; return 1; }
  done
}

@test "help documents the flags the runbooks use" {
  run bash "${LAN_BIN}" help
  [ "${status}" -eq 0 ]
  for f in --site --node --rollback --forget-host-key --host-key --out --email --local --dry-run; do
    [[ "${output}" == *"${f}"* ]] || { echo "missing flag: ${f}"; return 1; }
  done
}

@test "every command and flag the VM e2e passes to teknoir-airgap is in its help" {
  local e2e="${REPO_ROOT}/airgap/test/vm/e2e.sh" cmds flags c f
  run bash "${LAN_BIN}" help
  [ "${status}" -eq 0 ]
  # tk "${dir}" <command> [flags], up_in "${dir}" [flags]; tk() adds --site and --host-key
  cmds="$(grep -oE 'tk "\$\{dir\}" [a-z][a-z-]*' "${e2e}" | awk '{print $3}' | sort -u)"
  flags="$(grep -E '(^|[[:space:];(])(tk|up_in) "\$\{' "${e2e}" | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
  [ -n "${cmds}" ] && [ -n "${flags}" ]
  for c in ${cmds}; do
    grep -qE "^[[:space:]]+${c}( |$)" <<<"${output}" || { echo "e2e uses a command the help does not list: ${c}"; return 1; }
  done
  for f in ${flags} --site --host-key; do
    [[ "${output}" == *"${f}"* ]] || { echo "e2e uses a flag the help does not document: ${f}"; return 1; }
  done
}

@test "an unknown command fails without touching the network" {
  setup_stubs
  run bash "${LAN_BIN}" no-such-command
  [ "${status}" -ne 0 ]
  [ -z "$(stub_calls ssh)" ]
}

@test "runs under /bin/bash 3.2 (docker bash:3.2): help" {
  command -v docker >/dev/null || skip "docker not available"
  docker image inspect bash:3.2 >/dev/null 2>&1 || [ -n "${CI:-}" ] || skip "image bash:3.2 not present (CI pulls it)"
  run docker run --rm -v "${LAN_BIN}:/b/teknoir-airgap:ro" bash:3.2 bash /b/teknoir-airgap help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *up* ]]
}

# --- admin-user: the flags reach teknoir-node; --out is never overwritten ---
# lan_sandbox: a minimal extracted bundle (the LAN tool, MANIFEST.yaml, a
# site, an empty node payload already "on the node") and a stub sudo, so
# `--local` runs without root: the stub runs the node side with
# /var/lib/teknoir-airgap mapped to a sandbox directory (arguments in, stdout
# out). The fake runner records its arguments and plays teknoir-node
# admin-user: it writes a password to --out (none@: nothing on record; late@:
# fails after the handover, like a catalog timeout).
lan_sandbox() {
  B="${BATS_TEST_TMPDIR}/bundle"
  SB="${BATS_TEST_TMPDIR}/node-state"
  OUT="${BATS_TEST_TMPDIR}/out"
  local runner="${SB}/bundles/t-test-1/node/bin/teknoir-node" sbin="${BATS_TEST_TMPDIR}/sbin"
  mkdir -p "${B}/site" "${B}/node" "$(dirname "${runner}")" "${OUT}" "${BATS_TEST_TMPDIR}/home" "${sbin}"
  cp "${LAN_BIN}" "${B}/teknoir-airgap"
  printf 'bundleId: t-test-1\nenv: t\ndomain: example.test\n' > "${B}/MANIFEST.yaml"
  printf 'TEKNOIR_ENV=t\nTEKNOIR_DOMAIN=example.test\nNODE_IP=10.0.0.1\nNODE=tk@10.0.0.1\n' > "${B}/site/t.env"
  : > "${B}/node/SHA256SUMS"
  sha256sum < "${B}/node/SHA256SUMS" | cut -c1-64 > "${SB}/bundles/t-test-1/payload.sha256"
  cat > "${runner}" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${SANDBOX}/runner.log"
[ "$1" = admin-user ] || exit 0
shift
out='' email='' reset=0
while [ $# -gt 0 ]; do
  case $1 in --out) out=$2; shift ;; --email) email=$2; shift ;; --reset-password) reset=1 ;; esac
  shift
done
case $email in none@*) echo "WARN: no temporary password of $email is on record" >&2; exit 0 ;; esac
v=s3cr3t-temporary-password
[ "$reset" = 1 ] && v=s3cr3t-reset-password
printf '%s\n' "$v" > "$out"
case $email in late@*) echo "ERROR: timed out waiting until the Backstage catalog lists the user" >&2; exit 1 ;; esac
exit 0
EOF
  cat > "${sbin}/sudo" <<'EOF'
#!/bin/sh
# stub sudo: drop sudo's options; run the rest with the node state dir mapped
while [ $# -gt 0 ]; do case $1 in -n) shift ;; -p) shift 2 ;; *) break ;; esac; done
n=$#
while [ "$n" -gt 0 ]; do
  a=$(printf '%s' "$1" | sed "s|/var/lib/teknoir-airgap|${SANDBOX}|g")
  shift
  set -- "$@" "$a"
  n=$((n - 1))
done
o=$(mktemp)
rc=0
"$@" > "$o" || rc=$?
sed "s|${SANDBOX}|/var/lib/teknoir-airgap|g" "$o"
rm -f "$o"
exit "$rc"
EOF
  chmod +x "${runner}" "${sbin}/sudo"
  export SANDBOX="${SB}" HOME="${BATS_TEST_TMPDIR}/home" PATH="${sbin}:${PATH}"
}

@test "help documents the admin-user flags --teamspace and --reset-password" {
  run bash "${LAN_BIN}" help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--teamspace NAME"* ]]
  [[ "${output}" == *"--reset-password"* ]]
}

@test "admin-user --reset-password without --out is a usage error that contacts no node" {
  setup_stubs
  run bash "${LAN_BIN}" admin-user --email a@example.com --reset-password
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"--reset-password needs --out FILE"* ]]
  [ -z "$(stub_calls ssh)" ]
}

@test "admin-user passes --reset-password and --teamspace to teknoir-node and saves the new password (0600)" {
  setup_stubs
  lan_sandbox
  run bash "${B}/teknoir-airgap" admin-user --local --email Reset.Me@Example.com --teamspace teknoir-default \
    --reset-password --out "${OUT}/reset.txt"
  [ "${status}" -eq 0 ]
  # the runner sees the node paths (here mapped into the sandbox)
  local call
  call="$(cat "${SB}/runner.log")"
  [[ "${call}" == "admin-user --email reset.me@example.com --out ${SB}/tmp/admin-user."* ]]
  [[ "${call}" == *" --site ${SB}/site/t.env --teamspace teknoir-default --reset-password" ]]
  [ "$(cat "${OUT}/reset.txt")" = s3cr3t-reset-password ]
  [ "$(stat -c %a "${OUT}/reset.txt")" = 600 ]
  [[ "${output}" == *"the new temporary password of reset.me@example.com is in ${OUT}/reset.txt"* ]]
  refute_grep -r s3cr3t "${HOME}/.teknoir-airgap" <<<""
  [[ "${output}" != *s3cr3t* ]]
  # the node's copy is gone, and nothing is left next to --out
  [ -z "$(find "${SB}/tmp" -type f)" ]
  [ "$(find "${OUT}" -type f | wc -l)" -eq 1 ]
  [ -z "$(stub_calls ssh)" ]
}

@test "admin-user never overwrites a non-empty --out and does not run teknoir-node" {
  lan_sandbox
  printf 'keep me\n' > "${OUT}/busy.txt"
  run bash "${B}/teknoir-airgap" admin-user --local --email a@example.com --out "${OUT}/busy.txt"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"never overwrites a file"* ]]
  [ "$(cat "${OUT}/busy.txt")" = "keep me" ]
  [ ! -e "${SB}/runner.log" ]
}

@test "admin-user with nothing on record writes no --out file" {
  lan_sandbox
  run bash "${B}/teknoir-airgap" admin-user --local --email none@example.com --out "${OUT}/none.txt"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"recorded no temporary password"* ]]
  [[ "${output}" == *"--reset-password --out NEW-FILE"* ]]
  [ ! -e "${OUT}/none.txt" ]
  [ -z "$(find "${OUT}" -type f)" ]
}

@test "admin-user keeps the password when teknoir-node fails after the handover" {
  lan_sandbox
  run bash "${B}/teknoir-airgap" admin-user --local --email late@example.com --out "${OUT}/late.txt"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"after it handed out the temporary password, which is in ${OUT}/late.txt"* ]]
  [ "$(cat "${OUT}/late.txt")" = s3cr3t-temporary-password ]
  [ "$(stat -c %a "${OUT}/late.txt")" = 600 ]
  [ -z "$(find "${SB}/tmp" -type f)" ]
}
