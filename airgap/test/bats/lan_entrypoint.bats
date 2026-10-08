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
