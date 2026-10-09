#!/usr/bin/env bash
# packages-test.sh: host_packages (TIME-T2, the offline install of the
# bundle's node packages) against the real apt and dpkg of Debian 13, in
# throwaway debian:trixie containers. Proves what the stub tests cannot: apt
# installs the pinned .debs with no network, also when apt's lists offer the
# same versions from a repository. That is the live teknoir-local node: its
# lists are from its install and contain chrony 4.6.1-3+deb13u2 and
# util-linux-extra 2.41.5-0+deb13u1, and with them in view apt plans the
# archive fetch from the repository, which --no-download refuses ("E: Unable
# to fetch some archives", exit 100). host_packages hides the lists from apt.
#
#   prepare (network, once):
#     - apt-get update; the pinned .debs and debs.lock (contract K8): from a
#       bundle's node/debs (APT_TEST_DEBS_DIR), else apt-get download, else
#       snapshot.debian.org by the sha1 pin; each checked against its sha256
#       pin;
#     - a repository that offers exactly the pinned .debs over http (a flat
#       repo on 127.0.0.1, served only while apt-get update reads it), so
#       apt's lists offer every pin also after Debian supersedes one;
#     - the pre-r5 node: systemd-timesyncd and the two packages' dependencies
#       installed, chrony and util-linux-extra not; apt keeps its lists
#       uncompressed and its binary caches, as on a node; docker commit.
#   then, with --network none, for each node state:
#     lists    apt's lists offer every pinned version from a repository (the
#              live node); control: apt's own offline simulate of the .debs
#              fails there, as it did on the live node
#     nolists  no lists and no binary caches (a fresh genericcloud image);
#              control: the same simulate passes
#   the real host_packages from airgap/node:
#     - dry-run: plans both packages and the removal of systemd-timesyncd,
#       no WARN, installs nothing, runs only the simulate;
#     - up: installs both at their pins, removes systemd-timesyncd, no WARN;
#       both apt-get calls hide the lists and the binary caches (the install
#       runs without --no-download: with it apt 3.0 fails on local .debs
#       with "Pathname to install is not absolute", after its removals);
#     - a second up: no apt-get call;
#     - apt's own lists are untouched; host_packages' empty lists dir goes
#       with the run's scratch dir.
#
# Usage: airgap/test/node/packages-test.sh
#   Needs docker and, for the prepare step, network (deb.debian.org,
#   snapshot.debian.org once Debian's pool drops a pin). The pins: NODE_DEBS,
#   PINNED_SHA256 and PINNED_DEB_SHA1 from airgap/versions.env when it has
#   them, else the r5 pins below. APT_TEST_DEBS_DIR=<a bundle's node/debs>
#   tests that bundle's debs.lock and .debs instead; APT_TEST_SNAPSHOT=1
#   takes them from snapshot.debian.org even while Debian serves them (tests
#   that fallback). TEKNOIR_NODE_SRC=<dir> tests another copy of airgap/node. Every container and the prepared image
#   are removed at exit. Exit 0 passed, 1 failed, 77 skipped (no docker, or
#   not an amd64 host).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP="$(cd "${HERE}/../.." && pwd)"
SRC="$(cd "${TEKNOIR_NODE_SRC:-${AIRGAP}/node}" && pwd)"
IMAGE="${PACKAGES_TEST_IMAGE:-docker.io/library/debian:trixie@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5}"
NAME="tk-packages-test-$$"
PREPARED="tk-packages-test:$$"

command -v docker >/dev/null || { echo "SKIP: docker not installed"; exit 77; }
[[ "$(uname -m)" == x86_64 ]] || { echo "SKIP: the pinned .debs are amd64 (this host is $(uname -m))"; exit 77; }
# shellcheck disable=SC2317 # called by the EXIT trap
cleanup() {
  docker rm -f "${NAME}-prep" "${NAME}-lists" "${NAME}-nolists" >/dev/null 2>&1 || true
  docker rmi -f "${PREPARED}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The pins, "<pkg> <version> <sha256> <sha1>" per line
PINS="$(bash -c '
  source "$1" >/dev/null 2>&1 || exit 0
  [[ -n "${NODE_DEBS:-}" ]] || exit 0
  for pv in ${NODE_DEBS}; do
    p="${pv%%=*}" v="${pv#*=}" k="deb-${pv%%=*}-${pv#*=}-amd64"
    printf "%s %s %s %s\n" "${p}" "${v}" "${PINNED_SHA256[${k}]:--}" "${PINNED_DEB_SHA1[${k}]:--}"
  done' _ "${AIRGAP}/versions.env")"
if [[ -z "${PINS}" ]]; then
  PINS="chrony 4.6.1-3+deb13u2 3b3fb6b13818c288ea0121038dc3220da869c6dc5d1e5c4d5f7b13647f3ff7e7 1fc863918041705faa04c509d4659087b953cc69
util-linux-extra 2.41.5-0+deb13u1 b5d0492ee97c7f3f79178973f2518af631669d5ad84ff7e539ec6bfe6f0bd700 74b818883fa5e3cc5967372e0f396c0b86911129"
fi
given=()
if [[ -n "${APT_TEST_DEBS_DIR:-}" ]]; then
  [[ -f "${APT_TEST_DEBS_DIR}/debs.lock" ]] || { echo "FAIL: ${APT_TEST_DEBS_DIR}/debs.lock not found"; exit 1; }
  given=(-v "$(cd "${APT_TEST_DEBS_DIR}" && pwd):/given:ro")
fi

echo "# prepare: the pre-r5 node in ${IMAGE%@*} (network)"
# shellcheck disable=SC2016 # the script runs inside the container
if ! docker run -i --name "${NAME}-prep" "${given[@]}" -e PINS="${PINS}" -e SNAPSHOT="${APT_TEST_SNAPSHOT:-0}" \
    "${IMAGE}" bash -s <<'PREP'; then
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# a node keeps apt's lists uncompressed and its binary caches; the image's
# docker tweaks would hide both
rm -f /etc/apt/apt.conf.d/docker-clean /etc/apt/apt.conf.d/docker-gzip-indexes
# no service starts in the container (chrony's postinst would start chronyd)
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
apt-get update -qq
install -d -o _apt /stage/debs
cd /stage/debs
if [[ -f /given/debs.lock ]]; then
  cp /given/debs.lock .
  while read -r _ _ _ _ f; do cp "/given/${f}" .; done < debs.lock
else
  : > debs.lock
  while read -r p v s h; do
    [[ "${s}" =~ ^[0-9a-f]{64}$ ]] || { echo "no sha256 pin for ${p} ${v}"; exit 1; }
    f="${p}_${v#*:}_amd64.deb"
    if [[ "${SNAPSHOT}" != 1 ]] && apt-get download -qq "${p}=${v}" 2>/dev/null; then
      # apt names a file with an epoch <pkg>_<epoch>%3a<version>; the bundle drops it
      for d in "${p}"_*_amd64.deb; do [[ "${d}" == "${f}" ]] || mv "${d}" "${f}"; done
    elif [[ "${h}" =~ ^[0-9a-f]{40}$ ]]; then
      # Debian's indexes no longer carry the pin: the content-addressed copy
      echo "# ${p} ${v}: from snapshot.debian.org"
      /usr/lib/apt/apt-helper download-file "http://snapshot.debian.org/file/${h}" "/stage/debs/${f}" "SHA256:${s}"
    else
      echo "cannot download ${p} ${v} (no sha1 pin for snapshot.debian.org)"
      exit 1
    fi
    printf '%s %s amd64 %s %s\n' "${p}" "${v}" "${s}" "${f}" >> debs.lock
  done <<<"${PINS}"
fi
chown -R root:root /stage/debs
while read -r p v _ s f; do
  printf '%s  %s\n' "${s}" "${f}" | sha256sum -c --quiet || { echo "${f} does not match its pin"; exit 1; }
  echo "# ${p} ${v}: ${f}"
done < debs.lock

# the pre-r5 node: the packages' dependencies, systemd-timesyncd, neither package
apt-get install -y -qq --no-install-recommends ./*.deb >/dev/null
apt-get install -y -qq --no-install-recommends systemd-timesyncd >/dev/null
# shellcheck disable=SC2046
apt-get purge -y -qq $(awk '{print $1}' debs.lock) >/dev/null

# a repository that offers exactly the pins over http (the live node's lists
# offer them from deb.debian.org; Debian may supersede a pin later)
apt-get install -y -qq --no-install-recommends apt-utils busybox >/dev/null
mkdir /pins
cp ./*.deb /pins/
( cd /pins && apt-ftparchive packages . > Packages && apt-ftparchive release . > Release )
busybox httpd -f -p 127.0.0.1:8765 -h /pins &
httpd=$!
echo 'deb [trusted=yes] http://127.0.0.1:8765/ ./' > /etc/apt/sources.list.d/pins.list
sleep 1
apt-get update -qq
kill "${httpd}"
apt-get purge -y -qq apt-utils busybox >/dev/null
rm -rf /pins
apt-get clean
dpkg-query -W -f '${db:Status-Status}\n' systemd-timesyncd | grep -qx installed
PREP
  echo "FAIL: prepare (network? a pin neither Debian nor snapshot.debian.org serves: set APT_TEST_DEBS_DIR)"
  exit 1
fi
docker commit "${NAME}-prep" "${PREPARED}" >/dev/null
docker rm "${NAME}-prep" >/dev/null

rc=0
for variant in lists nolists; do
  echo
  echo "# ${variant}: host_packages offline (--network none)"
  # shellcheck disable=SC2016 # the script runs inside the container
  docker run --rm -i --network none --name "${NAME}-${variant}" -v "${SRC}:/src:ro" -e VARIANT="${variant}" \
      "${PREPARED}" bash -s <<'INNER' || rc=1
set -uo pipefail
PASS=0 FAIL=0
check() {
  local d="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   ${d}"; return 0; fi
  FAIL=$((FAIL + 1)); echo "FAIL ${d}"; return 1
}
show() { sed 's/^/#   /' "$1"; }
inst() { dpkg-query -W -f '${db:Status-Status} ${Version}' "$1" 2>/dev/null | sed -n 's/^installed //p'; }
LOCK=/stage/debs/debs.lock
WANT="$(awk '{printf "%s%s %s", s, $1, $2; s = ", "}' "${LOCK}")"
DEBS=()
while read -r _ _ _ _ f; do DEBS+=("/stage/debs/${f}"); done < "${LOCK}"
none_installed() { local p; for p in $(awk '{print $1}' "${LOCK}"); do [[ -z "$(inst "${p}")" ]] || return 1; done; }
all_at_pins() { local p v; while read -r p v _; do [[ "$(inst "${p}")" == "${v}" ]] || return 1; done < "${LOCK}"; }
no_warn() { ! grep -q 'WARN' "$1"; }
lists_sum() { find /var/lib/apt/lists -type f -printf '%P %s %T@\n' | sort | sha256sum; }

if [[ "${VARIANT}" == nolists ]]; then
  rm -rf /var/lib/apt/lists/*
  rm -f /var/cache/apt/*.bin
  check "precondition: no apt lists" bash -c '[ -z "$(find /var/lib/apt/lists -type f)" ]'
else
  check "precondition: apt's lists offer every pinned version from a repository (as on the live node)" \
    bash -c 'while read -r p v _; do apt-cache madison "${p}" | grep -qF " | ${v} | http" || exit 1; done < '"${LOCK}"
  check "precondition: apt's binary cache is there" test -f /var/cache/apt/pkgcache.bin
fi
check "precondition: systemd-timesyncd is installed" \
  bash -c '[ "$(dpkg-query -W -f "\${db:Status-Status}" systemd-timesyncd)" = installed ]'
check "precondition: none of the bundle's packages is installed" none_installed
# control: apt's offline simulate of the .debs with the node's lists in view
LC_ALL=C apt-get install -s --no-download --no-install-recommends "${DEBS[@]}" > /tmp/control.log 2>&1
crc=$?
if [[ "${VARIANT}" == lists ]]; then
  check "control: with these lists in view apt's offline simulate fails (exit 100, Unable to fetch some archives), as on the live node" \
    bash -c "[ ${crc} = 100 ] && grep -q '^E: Unable to fetch some archives' /tmp/control.log" || show /tmp/control.log
else
  check "control: without lists apt's offline simulate passes" [ "${crc}" = 0 ] || show /tmp/control.log
fi
BEFORE_LISTS="$(lists_sum)"

# the node runner's libraries, as teknoir-node sources them, with the
# bundle's node/debs next to them
cp -a /src/lib /stage/lib
export NODE_ROOT=/stage
# shellcheck source=/dev/null
source /stage/lib/common.sh
# shellcheck source=/dev/null
source /stage/lib/host.sh
# every apt-get call is recorded, then runs the real apt-get
mkdir -p /shim
printf '#!/bin/sh\nprintf "apt-get %%s\\n" "$*" >> /tmp/apt-calls\nexec /usr/bin/apt-get "$@"\n' > /shim/apt-get
chmod 0755 /shim/apt-get
export PATH="/shim:${PATH}"
# the options that hide the node's lists and binary caches from apt
HIDE=' -o Dir::State::Lists=/dev/shm/teknoir-node.[A-Za-z0-9]*/apt-lists -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= '

: > /tmp/apt-calls
DRY_RUN=1
host_packages > /tmp/dry.log 2>&1
DRY_RUN=0
check "dry-run: no WARN" no_warn /tmp/dry.log || show /tmp/dry.log
check "dry-run: plans ${WANT} and the removal of systemd-timesyncd" \
  grep -qF "would change: install ${WANT} from the bundle (removes systemd-timesyncd)" /tmp/dry.log
check "dry-run: the only apt-get call is the offline simulate, with the lists and caches hidden" \
  bash -c '[ "$(grep -c . /tmp/apt-calls)" = 1 ] && grep -q "^apt-get install -s --no-download${1}" /tmp/apt-calls' _ "${HIDE}"
check "dry-run: installs nothing" none_installed
wd="${WORK_DIR}"
check "the scratch dir is on tmpfs and holds the empty lists dir" \
  bash -c '[[ "$1" == /dev/shm/teknoir-node.* ]] && [ -d "$1/apt-lists/partial" ] && [ -z "$(find "$1/apt-lists" -mindepth 1 ! -path "$1/apt-lists/partial")" ]' _ "${wd}"

: > /tmp/apt-calls
host_packages > /tmp/up1.log 2>&1
check "up: no WARN" no_warn /tmp/up1.log || show /tmp/up1.log
check "up: records the install and the removal" \
  grep -qF "changed: installed ${WANT} from the bundle (removed systemd-timesyncd)" /tmp/up1.log
check "up: ${WANT} installed at the pins" all_at_pins
check "up: systemd-timesyncd is removed" \
  bash -c '[ "$(dpkg-query -W -f "\${db:Status-Status}" systemd-timesyncd 2>/dev/null)" != installed ]'
check "up: chronyc and hwclock are there" bash -c 'command -v chronyc >/dev/null && command -v hwclock >/dev/null'

check "up: two apt-get calls, the offline simulate and the install, both with the lists and caches hidden" \
  bash -c '[ "$(grep -c . /tmp/apt-calls)" = 2 ] && sed -n 1p /tmp/apt-calls | grep -q "^apt-get install -s --no-download$1" && sed -n 2p /tmp/apt-calls | grep -q "^apt-get install -y$1"' _ "${HIDE}"
check "up: dpkg is consistent (dpkg --audit is empty)" bash -c '[ -z "$(dpkg --audit)" ]'

: > /tmp/apt-calls
host_packages > /tmp/up2.log 2>&1
check "second up: no apt-get call" test ! -s /tmp/apt-calls
check "second up: says the packages are installed" grep -qF "the bundle's node packages are installed (${WANT})" /tmp/up2.log
check "second up: no WARN" no_warn /tmp/up2.log

check "apt's own lists are untouched" [ "$(lists_sum)" = "${BEFORE_LISTS}" ]
run_at_exit
check "the run's scratch dir (with host_packages' lists dir) is removed at exit" [ ! -e "${wd}" ]
echo
echo "${VARIANT}: passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
INNER
done
echo
if (( rc == 0 )); then echo "packages-test: all passed"; else echo "packages-test: FAILED"; fi
exit "${rc}"
