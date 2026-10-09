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

# ---------------------------------------------------------------------------
# doctor: the node's time and address (r5, TIME-T4), with stub ssh outputs
# ---------------------------------------------------------------------------
lan_world() {
  # lan_world [SITE LINE...] - a fake bundle (make-fake-bundle.sh) and a site
  # file "lantest" next to it with the extra lines, the node's host key pinned
  # in a private HOME, and the recording ssh stub answering the doctor: -G, the
  # master, `true`, sudo, the clock, the tool list, and the time-facts script
  # with ${BATS_TEST_TMPDIR}/facts
  setup_stubs
  local b
  b="$("${REPO_ROOT}/airgap/test/lan/make-fake-bundle.sh" --out "${BATS_TEST_TMPDIR}/b" --node-ip 10.0.0.1 --node teknoir@10.0.0.1)"
  LAN="${b}/teknoir-airgap"
  SITE="${BATS_TEST_TMPDIR}/lantest.env"
  { grep -v '^TIME_SOURCE=' "${b}/site/teknoir-local.env"; printf '%s\n' "$@"; } > "${SITE}"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.teknoir-airgap/lantest"
  echo "10.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubStubStubStubStubStubStubStubStubStubStub" \
    > "${HOME}/.teknoir-airgap/lantest/known_hosts"
  : > "${BATS_TEST_TMPDIR}/facts"
  stub_handler <<STUBS
stub_ssh() {
  local a last=""
  for a in "\$@"; do last="\${a}"; done
  case " \$* " in
    *" -G "*) printf 'user teknoir\nhostname 10.0.0.1\nport 22\n'; return 0 ;;
    *" -O "*) return 0 ;;
  esac
  case "\${last}" in
    *since_epoch*) cat '${BATS_TEST_TMPDIR}/facts' ;;
    *'date +%s'*) date +%s ;;
  esac
  return 0
}
STUBS
}

facts() {
  # facts KEY=VALUE... - what the node's time-facts script prints
  printf '%s\n' "$@" > "${BATS_TEST_TMPDIR}/facts"
}

ADDR_STATIC='ADDR=2: enp4s0    inet 10.0.0.1/24 brd 10.0.0.255 scope global enp4s0\       valid_lft forever preferred_lft forever'

@test "site keys: an invalid TIME_SOURCE, NODE_IP_DHCP_RESERVED or age recipient stops before ssh" {
  lan_world
  local bad
  for bad in 'TIME_SOURCE="a;b"' 'TIME_SOURCE="ntp..lan"' 'TIME_SOURCE="10.0.0.256"' 'NODE_IP_DHCP_RESERVED=maybe' \
             'BACKUP_AGE_RECIPIENTS="age1short"' 'BACKUP_AGE_RECIPIENTS="AGE1QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"'; do
    lan_world "${bad}"
    run bash "${LAN}" status --site "${SITE}"
    [ "${status}" -eq 1 ] || { echo "accepted: ${bad}"; return 1; }
    [[ "${output}" == *"invalid ${bad%%=*}"* ]] || { echo "${bad}: ${output}"; return 1; }
    [ -z "$(stub_calls ssh)" ] || { echo "${bad}: ssh was called"; return 1; }
  done
  lan_world 'TIME_SOURCE="ntp.lan 10.0.0.5"' NODE_IP_DHCP_RESERVED=yes \
    'BACKUP_AGE_RECIPIENTS="age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce"'
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=7F7F0101 " "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  refute_grep -q 'invalid' <<<"${output}"
  [[ "${output}" == *"Node teknoir@10.0.0.1:"* ]]
}
