#!/usr/bin/env bash
# fetch-deb-test.sh — unit test (no network) of airgap/build/fetch-tools.sh's
# node packages (TIME-T1): art_deb, the snapshot.debian.org fallback of
# fetch_artifact, and stage_debs (node/debs + debs.lock, contract K8).
#
#   1. the pool answers: one download, no fallback, the file is the pin;
#   2. the pool has dropped the file (404): the snapshot URL (by sha1) is
#      used, and its sha256 is still checked against the pin;
#   3. the snapshot returns other bytes: the build fails and caches nothing;
#   4. stage_debs writes node/debs/<file> (0644) and one lock line per file;
#      --dry-run plans both URLs and writes nothing.
#
# curl is a stub on PATH that serves files from a fixture directory; the
# cache is a temp dir. Usage: airgap/test/unit/fetch-deb-test.sh
# shellcheck disable=SC2016  # the scenario scripts expand in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-fetchdeb.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/srv" "${WORK}/cache"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# fixture packages (bytes only: the fetch never looks inside)
printf 'fake chrony package\n' > "${WORK}/srv/pkg-a.deb"
printf 'fake util-linux-extra package\n' > "${WORK}/srv/pkg-b.deb"
printf 'something else\n' > "${WORK}/srv/other.deb"
sha256() { sha256sum "$1" | cut -d' ' -f1; }
sha1() { sha1sum "$1" | cut -d' ' -f1; }
A256="$(sha256 "${WORK}/srv/pkg-a.deb")" A1="$(sha1 "${WORK}/srv/pkg-a.deb")"
B256="$(sha256 "${WORK}/srv/pkg-b.deb")" B1="$(sha1 "${WORK}/srv/pkg-b.deb")"

# stub curl: "-o FILE URL"; URLs are looked up in ${WORK}/srv/routes
# ("<url> <file>"), anything else is a 404 (curl -f: exit 22)
cat > "${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --retry) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
printf '%s\n' "${url}" >> "${STUB_CURL_LOG}"
file="$(awk -v u="${url}" '$1 == u {print $2; exit}' "${STUB_ROUTES}")"
if [[ -z "${file}" ]]; then echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; fi
if [[ -n "${out}" ]]; then cp "${file}" "${out}"; else cat "${file}"; fi
EOF
chmod +x "${WORK}/bin/curl"
export STUB_CURL_LOG="${WORK}/curl.log" STUB_ROUTES="${WORK}/srv/routes"

POOL_A="https://deb.debian.org/debian/pool/main/f/fake-a/fake-a_1.0-1_amd64.deb"
POOL_B="https://deb.debian.org/debian-security/pool/updates/main/f/fake/fake-b_3.0-1_amd64.deb"
SNAP_A="https://snapshot.debian.org/file/${A1}"
SNAP_B="https://snapshot.debian.org/file/${B1}"

# run <script> — source fetch-tools.sh with the fixture pins, then run <script>
run() {
  : > "${STUB_CURL_LOG}"
  env PATH="${WORK}/bin:${PATH}" TEKNOIR_AIRGAP_CACHE="${WORK}/cache" A256="${A256}" A1="${A1}" B256="${B256}" B1="${B1}" \
    STUB_CURL_LOG="${STUB_CURL_LOG}" STUB_ROUTES="${STUB_ROUTES}" FT="${REPO}/airgap/build/fetch-tools.sh" \
    bash -c '
      source "${FT}"
      NODE_DEBS="fake-a=1.0-1 fake-b=2:3.0-1"
      NODE_DEB_POOL=([fake-a]=debian/pool/main/f/fake-a [fake-b]=debian-security/pool/updates/main/f/fake)
      PINNED_SHA256["deb-fake-a-1.0-1-amd64"]="${A256}"
      PINNED_SHA256["deb-fake-b-2:3.0-1-amd64"]="${B256}"
      PINNED_DEB_SHA1["deb-fake-a-1.0-1-amd64"]="${A1}"
      PINNED_DEB_SHA1["deb-fake-b-2:3.0-1-amd64"]="${B1}"
      '"$1" > "${WORK}/out" 2>&1
}

echo "# 1. the pool answers"
printf '%s %s\n' "${POOL_A}" "${WORK}/srv/pkg-a.deb" > "${STUB_ROUTES}"
rc=0; run 'art_deb fake-a 1.0-1; p="$(fetch_artifact)"; echo "path=${p}"; sha256sum "${p}"' || rc=$?
check "exit 0" "${rc}" "0"
check "one download, from the pool" "$(cat "${STUB_CURL_LOG}")" "${POOL_A}"
check "cached under the version-keyed key" "$(grep -c "path=${WORK}/cache/tools/deb-fake-a-1.0-1-amd64/fake-a_1.0-1_amd64.deb" "${WORK}/out")" "1"
check "the cached file is the pin" "$(grep -c "^${A256} " "${WORK}/out")" "1"
rc=0; run 'art_deb fake-a 1.0-1; fetch_artifact >/dev/null' || rc=$?
check "a cached file is not downloaded again" "${rc} $(wc -l < "${STUB_CURL_LOG}")" "0 0"

echo "# 2. the pool dropped the file: snapshot.debian.org by sha1"
printf '%s %s\n' "${SNAP_B}" "${WORK}/srv/pkg-b.deb" > "${STUB_ROUTES}"
rc=0; run 'art_deb fake-b 2:3.0-1; p="$(fetch_artifact)"; sha256sum "${p}"' || rc=$?
check "exit 0" "${rc}" "0"
check "the pool first, then the snapshot" "$(tr '\n' ' ' < "${STUB_CURL_LOG}")" "${POOL_B} ${SNAP_B} "
check "the fallback file is the pin, named without the epoch" "$(grep -c "^${B256}  .*/deb-fake-b-2:3.0-1-amd64/fake-b_3.0-1_amd64.deb$" "${WORK}/out")" "1"
check "the fallback is announced" "$(grep -c "download failed: ${POOL_B}; trying ${SNAP_B}" "${WORK}/out")" "1"

echo "# 3. the snapshot serves other bytes"
rm -rf "${WORK}/cache/tools/deb-fake-a-1.0-1-amd64"
printf '%s %s\n' "${SNAP_A}" "${WORK}/srv/other.deb" > "${STUB_ROUTES}"
rc=0; run 'art_deb fake-a 1.0-1; fetch_artifact' || rc=$?
check "the build fails" "${rc}" "1"
check "it names the sha1 mismatch" "$(grep -c "returned a file with sha1 $(sha1 "${WORK}/srv/other.deb")" "${WORK}/out")" "1"
check "nothing is cached" "$(find "${WORK}/cache/tools/deb-fake-a-1.0-1-amd64" -type f | wc -l)" "0"
# the right sha1 with the wrong sha256 pin: the pin still decides
printf '%s %s\n' "${SNAP_A}" "${WORK}/srv/pkg-a.deb" > "${STUB_ROUTES}"
rc=0; run 'PINNED_SHA256["deb-fake-a-1.0-1-amd64"]="$(printf "%064d" 1)"; art_deb fake-a 1.0-1; fetch_artifact' || rc=$?
check "a fallback file that is not the sha256 pin fails" "${rc} $(grep -c "downloaded sha256 ${A256} differs from the pin" "${WORK}/out")" "1 1"
check "nothing is cached" "$(find "${WORK}/cache/tools/deb-fake-a-1.0-1-amd64" -type f | wc -l)" "0"
: > "${STUB_ROUTES}"
rc=0; run 'art_deb fake-a 1.0-1; fetch_artifact' || rc=$?
check "pool and snapshot both 404: fails naming both" "${rc} $(grep -c "download failed: ${POOL_A} and ${SNAP_A}" "${WORK}/out")" "1 1"

echo "# 4. stage_debs"
printf '%s %s\n%s %s\n' "${POOL_A}" "${WORK}/srv/pkg-a.deb" "${SNAP_B}" "${WORK}/srv/pkg-b.deb" > "${STUB_ROUTES}"
S="${WORK}/stage"
rc=0; run "DRY_RUN=1; stage_debs '${S}'" || rc=$?
check "--dry-run: exit 0, nothing downloaded or written" "${rc} $(wc -l < "${STUB_CURL_LOG}") $(find "${S}" 2>/dev/null | wc -l)" "0 0 0"
check "--dry-run: plans both packages with pin and fallback" \
  "$(grep -c "\[dry-run\] https://deb.debian.org/.* -> node/debs/fake-[ab]_[0-9.-]*_amd64.deb (pin [0-9a-f]\{64\}, fallback https://snapshot.debian.org/file/[0-9a-f]\{40\})" "${WORK}/out")" "2"
rc=0; run "DRY_RUN=0; stage_debs '${S}'" || rc=$?
check "stage: exit 0" "${rc}" "0"
check "stage: debs.lock (K8)" "$(cat "${S}/node/debs/debs.lock" 2>/dev/null)" \
  "fake-a 1.0-1 amd64 ${A256} fake-a_1.0-1_amd64.deb"$'\n'"fake-b 2:3.0-1 amd64 ${B256} fake-b_3.0-1_amd64.deb"
check "stage: files 0644" "$(stat -c %a "${S}/node/debs/fake-a_1.0-1_amd64.deb" "${S}/node/debs/fake-b_3.0-1_amd64.deb" "${S}/node/debs/debs.lock" 2>/dev/null | tr '\n' ' ')" "644 644 644 "
check "stage: no temp files left" "$(find "${S}/node/debs" -name '*.tmp' | wc -l)" "0"
rc=0; run "NODE_DEBS='bad entry'; DRY_RUN=1; stage_debs '${S}'" || rc=$?
check "stage: a malformed NODE_DEBS entry fails" "${rc} $(grep -c "is not <package>=<version>" "${WORK}/out")" "1 1"

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
