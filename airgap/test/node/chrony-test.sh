#!/usr/bin/env bash
# chrony-test.sh: the node runner's chrony code against the real chronyd of
# Debian 13 (the bundle's chrony 4.6.1), in a throwaway debian:trixie
# container. chronyd runs with -x: it computes every correction but never sets
# a clock, so the test host's clock is never touched. Proves what the stub
# tests cannot:
#   - host_chrony's drop-in (allow, local stratum 10, manual, maxdrift 100) is
#     accepted by chronyd, with Debian's chrony.conf (confdir);
#   - clock_manual_guard parses chronyc's real `-c manual list` output;
#   - two LAN-time samples seconds apart, the second 1 s off, teach chrony no
#     clock rate (before the fix: thousands of ppm) because the guard drops
#     the first sample;
#   - a sample old enough for a rate fit (CLOCK_RATE_MIN_AGE lowered to 3 s
#     here) is kept, and maxdrift caps the fit at 100 ppm.
#
# Usage: airgap/test/node/chrony-test.sh   (needs docker and network: apt
# installs chrony and iproute2 in the container; the container is removed)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${TEKNOIR_NODE_SRC:-${HERE}/../../node}" && pwd)"
IMAGE="${CHRONY_TEST_IMAGE:-docker.io/library/debian:trixie@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5}"
NAME="tk-chrony-test-$$"

command -v docker >/dev/null || { echo "SKIP: docker not installed"; exit 0; }
trap 'docker rm -f "${NAME}" >/dev/null 2>&1 || true' EXIT

# shellcheck disable=SC2016 # the script runs inside the container
docker run --rm -i --name "${NAME}" -v "${SRC}:/node:ro" "${IMAGE}" bash -s <<'INNER'
set -uo pipefail
PASS=0 FAIL=0
check() { local d="$1"; shift; if "$@"; then PASS=$((PASS + 1)); echo "ok   ${d}"; else FAIL=$((FAIL + 1)); echo "FAIL ${d}"; fi; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends chrony iproute2 >/dev/null 2>&1 \
  || { echo "FAIL apt-get install chrony iproute2 (network?)"; exit 1; }
echo "# $(chronyd --version | head -1)"
install -d -o _chrony -g _chrony -m 0750 /run/chrony
install -d -o _chrony -g _chrony /var/lib/chrony

# the node runner's libraries, as teknoir-node sources them
export NODE_ROOT=/node
# shellcheck source=/dev/null
source /node/lib/common.sh
# shellcheck source=/dev/null
source /node/lib/host.sh
CHRONYC=chronyc
NODE_IP="$(ip -o -4 addr show scope global | awk '{split($4, a, "/"); print a[1]; exit}')"
TIME_SOURCE=""

# host_chrony writes the drop-in (systemctl is absent here: its start is a
# WARN, chronyd is started below)
host_chrony > /tmp/host_chrony.log 2>&1
check "host_chrony wrote the drop-in" grep -qx 'maxdrift 100' /etc/chrony/conf.d/teknoir-airgap.conf
# Debian's chrony.conf without its pool and DHCP sources (no egress here);
# confdir reads the drop-in
grep -vE '^[[:space:]]*(pool|server|sourcedir)[[:space:]]' /etc/chrony/chrony.conf > /tmp/chrony.conf
check "Debian's chrony.conf reads conf.d" grep -q '^confdir /etc/chrony/conf.d' /tmp/chrony.conf
chronyd -p -f /tmp/chrony.conf > /tmp/parsed.conf 2>&1
check "chronyd parses the drop-in: manual, local stratum 10, maxdrift 100, allow <net>" \
  bash -c 'grep -qx manual /tmp/parsed.conf && grep -q "^local stratum 10" /tmp/parsed.conf && grep -qx "maxdrift 100" /tmp/parsed.conf && grep -q "^allow [0-9.]*/[0-9]*$" /tmp/parsed.conf'
chronyd -x -f /tmp/chrony.conf -l /tmp/chronyd.log
for _ in 1 2 3 4 5 6 7 8 9 10; do chronyc -n tracking >/dev/null 2>&1 && break; sleep 0.5; done

freq() { chronyc -n tracking | awk -F': *' '/^Frequency/ { split($2, a, " "); print (a[2] == "fast" ? "" : "-") a[1] }'; }

# sample 1: chrony has none yet, nothing to drop
clock_settime "$(date +%s)" > /tmp/s1.log 2>&1
check "sample 1 is accepted, no manual reset" bash -c '! grep -q "dropped its manual samples" /tmp/s1.log && [ "$(chronyc -c manual list | grep -c .)" = 1 ]'
check "the guard reads chronyc's manual list (one sample, its time in UTC)" \
  bash -c 'chronyc -c manual list | grep -Eq "^0,[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},"'
sleep 5
# sample 2, 5 s later and 1 s off (the whole-second error of --lan-time)
clock_settime "$(( $(date +%s) + 1 ))" > /tmp/s2.log 2>&1
check "sample 2 (5 s later): the guard drops sample 1 first" grep -q 'dropped its manual samples (the newest is [0-9]s old, under 43200s)' /tmp/s2.log
f="$(freq)"
check "and chrony learns no clock rate from them (Frequency ${f} ppm)" bash -c "awk -v f='${f}' 'BEGIN { exit !(f == 0) }'"
check "chronyd made no frequency change" bash -c '! grep -q "Making a frequency change" /tmp/chronyd.log'
sleep 5
# sample 3 with the minimum age lowered to 3 s: kept, so chrony fits a rate
# across 5 s with a 1 s error (about 200000 ppm) and maxdrift caps it
CLOCK_RATE_MIN_AGE=3 clock_settime "$(( $(date +%s) + 2 ))" > /tmp/s3.log 2>&1
check "sample 3 (minimum age 3 s): kept, the rate may be refined" grep -q 'its newest LAN-time sample is [0-9]s old' /tmp/s3.log
f="$(freq)"
check "the fit is capped by maxdrift: |Frequency| <= 100 ppm (got ${f})" bash -c "awk -v f='${f}' 'BEGIN { if (f < 0) f = -f; exit !(f > 0 && f <= 100.001) }'"
check "chronyd reports the cap" grep -q 'exceeds allowed maximum' /tmp/chronyd.log
echo "# chronyd log:"; sed 's/^/#   /' /tmp/chronyd.log | grep -iE 'frequency|slew|step|maximum' || true
echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
INNER
