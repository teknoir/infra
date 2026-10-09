#!/usr/bin/env bats
# lan_entrypoint.bats — surface checks of the LAN entrypoint airgap/teknoir-airgap
# (I-11): the commands the design and the runbooks rely on exist; the r5 site
# keys are checked before any ssh; doctor's time and address checks (TIME-T4)
# against stub ssh outputs, on this bash and on docker bash:3.2.
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
ADDR_DHCP='ADDR=2: enp4s0    inet 10.0.0.1/24 metric 100 brd 10.0.0.255 scope global dynamic enp4s0\       valid_lft 83943sec preferred_lft 83943sec'

@test "doctor: an RTC 93 s behind FAILs, chrony absent WARNs, a static NODE_IP is ok" {
  require_fn "${LAN_BIN}" doctor_time
  lan_world
  facts NOW=1791528077 RTC=1791527984 CHRONY=absent "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  echo "${output}" | sed -n '/^Node /,$p'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  RTC -93 s from the system clock: a reboot would start the node 93 s off; up writes the RTC"* ]]
  [[ "${output}" == *"WARN  chrony is not installed on the node; up installs it from the bundle"* ]]
  [[ "${output}" == *"ok    NODE_IP 10.0.0.1 is configured on the node (static)"* ]]
  [[ "${output}" == *"ssh as teknoir works"* ]]
  [ -z "$(mutating_calls)" ]
}

@test "doctor: RTC offsets up to 5 s are ok, up to 30 s WARN" {
  require_fn "${LAN_BIN}" doctor_time
  lan_world
  facts NOW=1791528077 RTC=1791528080 CHRONY=active "REF=7F7F0101 " "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  [[ "${output}" == *"ok    RTC 3 s from the system clock"* ]]
  [[ "${output}" == *"ok    chrony is active on the node; reference: local clock (stratum 10, corrected by every up)"* ]]
  facts NOW=1791528077 RTC=1791528057 CHRONY=active "REF=4D414E55 " "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  [[ "${output}" == *"WARN  RTC -20 s from the system clock; up writes the RTC"* ]]
  [[ "${output}" == *"reference: LAN-time samples (manual)"* ]]
  refute_grep -q 'FAIL  RTC' <<<"${output}"
}

@test "doctor: a 'dynamic' NODE_IP WARNs unless NODE_IP_DHCP_RESERVED=yes" {
  require_fn "${LAN_BIN}" doctor_time
  lan_world
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=7F7F0101 " "${ADDR_DHCP}"
  run bash "${LAN}" doctor --site "${SITE}"
  [[ "${output}" == *"WARN  NODE_IP 10.0.0.1 is a DHCP lease (valid 83943 s); reserve it on the router (docs/HOST-SETUP.md), then set NODE_IP_DHCP_RESERVED=yes in the site config"* ]]
  lan_world NODE_IP_DHCP_RESERVED=yes
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=7F7F0101 " "${ADDR_DHCP}"
  run bash "${LAN}" doctor --site "${SITE}"
  [[ "${output}" == *"ok    NODE_IP 10.0.0.1 is a DHCP lease reserved on the router (NODE_IP_DHCP_RESERVED=yes)"* ]]
  refute_grep -q 'WARN  NODE_IP' <<<"${output}"
}

@test "doctor: NODE_IP missing on the node FAILs" {
  require_fn "${LAN_BIN}" doctor_time
  lan_world
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=7F7F0101 "
  run bash "${LAN}" doctor --site "${SITE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  NODE_IP 10.0.0.1 is not an address of the node"* ]]
}

@test "doctor: a TIME_SOURCE chrony does not use WARNs; a selected or combined one is ok" {
  require_fn "${LAN_BIN}" doctor_time
  lan_world 'TIME_SOURCE="ntp.lan 10.0.0.5"'
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=7F7F0101 " "SRC=+ 10.0.0.9" "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  [[ "${output}" == *"WARN  chrony uses none of TIME_SOURCE (ntp.lan 10.0.0.5)"* ]]
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=0A000005 10.0.0.5" "SRC=* 10.0.0.5" "SRC=+ ntp.lan" "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  [[ "${output}" == *"ok    chrony uses TIME_SOURCE ntp.lan 10.0.0.5"* ]]
  [[ "${output}" == *"reference: NTP source 10.0.0.5"* ]]
  refute_grep -q 'WARN  chrony uses none' <<<"${output}"
}

@test "site keys: an invalid TIME_SOURCE, NODE_IP_DHCP_RESERVED or age recipient stops before ssh" {
  lan_world
  local bad
  for bad in 'TIME_SOURCE="a;b"' 'TIME_SOURCE="ntp..lan"' 'TIME_SOURCE="10.0.0.256"' 'NODE_IP_DHCP_RESERVED=maybe'; do
    lan_world "${bad}"
    run bash "${LAN}" status --site "${SITE}"
    [ "${status}" -eq 1 ] || { echo "accepted: ${bad}"; return 1; }
    [[ "${output}" == *"invalid ${bad%%=*}"* ]] || { echo "${bad}: ${output}"; return 1; }
    [ -z "$(stub_calls ssh)" ] || { echo "${bad}: ssh was called"; return 1; }
  done
  # an age recipient that is not a public key is named by at most its first
  # 8 characters (site_age_recipients_check)
  lan_world 'BACKUP_AGE_RECIPIENTS="age1shortxyz0123456789"'
  run bash "${LAN}" status --site "${SITE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"BACKUP_AGE_RECIPIENTS entry 'age1shor...' is not an age public key"* ]]
  refute_grep -qF 'age1shortx' <<<"${output}"
  [ -z "$(stub_calls ssh)" ]
  lan_world 'BACKUP_AGE_RECIPIENTS="AGE1QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"'
  run bash "${LAN}" status --site "${SITE}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"BACKUP_AGE_RECIPIENTS entry 'AGE1QPZR...' is not an age public key"* ]]
  refute_grep -qF 'AGE1QPZRY' <<<"${output}"
  [ -z "$(stub_calls ssh)" ]
  lan_world 'TIME_SOURCE="ntp.lan 10.0.0.5"' NODE_IP_DHCP_RESERVED=yes \
    'BACKUP_AGE_RECIPIENTS="age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce"'
  facts NOW=1791528077 RTC=1791528077 CHRONY=active "REF=7F7F0101 " "${ADDR_STATIC}"
  run bash "${LAN}" doctor --site "${SITE}"
  refute_grep -q 'invalid' <<<"${output}"
  [[ "${output}" == *"Node teknoir@10.0.0.1:"* ]]
}

@test "site keys: an age PRIVATE key in BACKUP_AGE_RECIPIENTS stops before ssh and is never printed" {
  # a dummy in the key format (AGE-SECRET-KEY-1 + 58 upper-case bech32
  # characters), built here so no key-shaped literal is in the repository
  local sk lower
  sk="AGE-SECRET-""KEY-1QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7LQPZRY9X8GF2TVDW0S3JN54KHCE"
  [ "${#sk}" -eq 74 ]
  lower="$(tr '[:upper:]' '[:lower:]' <<<"${sk}")"
  for line in "BACKUP_AGE_RECIPIENTS=\"${sk}\"" \
              "BACKUP_AGE_RECIPIENTS=\"age1qpzry9x8gf2tvdw0s3jn54khce6mua7lqpzry9x8gf2tvdw0s3jn54khce ${sk}\"" \
              "BACKUP_AGE_RECIPIENTS=\"${lower}\""; do
    lan_world "${line}"
    run bash "${LAN}" status --site "${SITE}"
    [ "${status}" -eq 1 ] || { echo "accepted: ${line:0:40}"; return 1; }
    [[ "${output}" == *"BACKUP_AGE_RECIPIENTS holds an age PRIVATE key (AGE-SECRET-KEY-...): remove it now (only public keys, age1..., belong there) and treat that identity as exposed"* ]] \
      || { echo "${output}"; return 1; }
    refute_grep -qiF "${sk:15:8}" <<<"${output}"
    refute_grep -rqiF "${sk:15:8}" "${HOME}/.teknoir-airgap"
    [ -z "$(stub_calls ssh)" ]
  done
}

@test "doctor's time checks run under /bin/bash 3.2 (docker bash:3.2)" {
  require_fn "${LAN_BIN}" doctor_time
  command -v docker >/dev/null || skip "docker not available"
  docker image inspect bash:3.2 >/dev/null 2>&1 || [ -n "${CI:-}" ] || skip "image bash:3.2 not present (CI pulls it)"
  lan_world NODE_IP_DHCP_RESERVED=no
  facts NOW=1791528077 RTC=1791527984 CHRONY=active "REF=7F7F0101 " "${ADDR_DHCP}"
  # the same paths inside the container, as this user (bats removes the
  # files); the recording stubs first, then the LAN tests' ssh-keygen and
  # ssh-keyscan stand-ins (the image has no OpenSSH)
  run docker run --rm --user "$(id -u):$(id -g)" \
    -v "${REPO_ROOT}:${REPO_ROOT}:ro" -v "${BATS_TEST_TMPDIR}:${BATS_TEST_TMPDIR}" \
    -e HOME -e STUB_LOG -e STUB_HANDLER \
    -e PATH="${STUB_BIN}:${REPO_ROOT}/airgap/test/lan/stub:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash:3.2 bash "${LAN}" doctor --site "${SITE}"
  echo "${output}" | sed -n '/^Node /,$p'
  [[ "${output}" == *"FAIL  RTC -93 s from the system clock"* ]]
  [[ "${output}" == *"ok    chrony is active on the node; reference: local clock"* ]]
  [[ "${output}" == *"WARN  NODE_IP 10.0.0.1 is a DHCP lease (valid 83943 s)"* ]]
}
