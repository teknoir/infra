#!/usr/bin/env bash
# image-cache-test.sh — collect-images.sh must never ship a corrupt cached
# image and must heal its cache in the same run (finding: image cache
# integrity on reuse). Needs network (registry HEAD/manifest requests and up
# to three pulls of docker.io/alpine/k8s:1.34.11, about 320 MB each) and GNU
# tar; bash >= 4.4.
#
# It runs collect-images.sh with --images-limit 1 against an ISOLATED cache
# (TEKNOIR_AIRGAP_CACHE in a temp dir, seeded from the default cache when that
# already holds the archive), so it never touches the real cache. Images: the
# bootstrap archive docker.io/alpine/k8s:1.34.11 (first of the bootstrap list)
# and the OCI layout docker.io/library/busybox:1.36.1 (first regular image).
#
#   R1 baseline; R2 re-run reuses the cache (no pull)
#   R3 one byte flipped inside a layer member of the cached archive
#   R4 one byte flipped inside a blob of the cached OCI layout
#   R5 a wrong digest in the archive's <entry>.digest
#   R6 no <entry>.digest (an entry from an older build): adopted, no pull
# After each: rc 0, images.lock unchanged, the staged copies verify, and the
# corrupt entries were named and pulled again.
#
# Usage: airgap/test/build/image-cache-test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$(cd "${HERE}/../../build" && pwd)"
DEFAULT_CACHE="${XDG_CACHE_HOME:-${HOME}/.cache}/teknoir-airgap"

T="$(mktemp -d)"
trap 'rm -rf -- "${T}"' EXIT
export TEKNOIR_AIRGAP_CACHE="${T}/cache"
mkdir -p "${TEKNOIR_AIRGAP_CACHE}/images/docker" "${T}/work/renders" "${T}/stage/node/oneshot"

# build tools from the default (shared, verified) tool cache
TEKNOIR_AIRGAP_CACHE="${DEFAULT_CACHE}" "${BUILD}/fetch-tools.sh" --host-bin "${T}/work/bin" >/dev/null 2>&1
PATH="${T}/work/bin:${PATH}"

BOOT_REF="docker.io/alpine/k8s:1.34.11"
OCI_REF="docker.io/library/busybox:1.36.1"
BOOT_SLUG="docker.io_alpine_k8s_1.34.11"
OCI_SLUG="docker.io_library_busybox_1.36.1"
# seed: saves one 320 MB pull when the default cache has the archive
for f in "${DEFAULT_CACHE}/images/docker/"*"-${BOOT_SLUG}.tar"; do
  [[ -f "${f}" ]] && cp "${f}" "${TEKNOIR_AIRGAP_CACHE}/images/docker/"
done
echo t > "${T}/stage/node/oneshot/TIERS"
echo 'kind: ConfigMap' > "${T}/stage/node/oneshot/t.yaml"
printf 'kind: Pod\nspec:\n  containers:\n    - image: %s\n' "${OCI_REF}" > "${T}/work/renders/a.yaml"

N=0 FAILED=0
ok()     { N=$((N + 1)); printf 'ok %d - %s\n' "${N}" "$1"; }
not_ok() { N=$((N + 1)); FAILED=$((FAILED + 1)); printf 'not ok %d - %s\n' "${N}" "$1"; }
check()  { if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1"; printf '#   want: %s\n#   got:  %s\n' "$3" "$2"; fi; }
logged() { if grep -qF -- "$2" "${T}/run.log"; then ok "$1"; else not_ok "$1"; printf '#   not in the log: %s\n' "$2"; fi; }
not_logged() { if ! grep -qF -- "$2" "${T}/run.log"; then ok "$1"; else not_ok "$1"; printf '#   in the log: %s\n' "$2"; fi; }

collect() {
  local rc=0
  "${BUILD}/collect-images.sh" --stage "${T}/stage" --work "${T}/work" --images-limit 1 > "${T}/run.log" 2>&1 || rc=$?
  echo "${rc}"
}
lock() { cat "${T}/stage/node/images/images.lock"; }
flip_byte() {
  # flip_byte <file> <offset>
  local b
  b="$(od -An -tu1 -j "$2" -N1 "$1" | tr -d ' ')"
  # shellcheck disable=SC2059  # the format is the octal escape of one byte
  printf "$(printf '\\%03o' $(( (b + 1) % 256 )))" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}
staged_ok() {
  # the shipped copies: archive digest and every OCI blob's sha256 equal their names
  local d bad
  d="$(crane digest --tarball "${T}/stage/node/bootstrap-images/${BOOT_SLUG}.tar")"
  check "$1: the staged archive is the locked image" "${d}" "${BOOT_DIGEST}"
  bad="$(cd "${T}/stage/node/images/${OCI_SLUG}/blobs/sha256" && for b in *; do [[ "$(sha256sum "${b}" | cut -c1-64)" == "${b}" ]] || echo "${b}"; done)"
  check "$1: every staged OCI blob verifies" "${bad}" ""
}
archive() { ls "${TEKNOIR_AIRGAP_CACHE}/images/docker/"*"-${BOOT_SLUG}.tar"; }

# R1
check "R1 baseline build" "$(collect)" "0"
BASE_LOCK="$(lock)"
BOOT_DIGEST="$(awk -v s="${BOOT_SLUG}" '$2 == s {sub(/^.*@/, "", $1); print $1}' <<<"${BASE_LOCK}")"
check "R1 images.lock holds both images" "$(wc -l <<<"${BASE_LOCK}")" "2"
check "R1 the archive's first-pull digest is recorded" "$(cat "$(archive).digest")" "${BOOT_DIGEST}"
staged_ok R1

# R2
check "R2 re-run" "$(collect)" "0"
not_logged "R2 reuses the cache (no pull)" "[build] pull "
check "R2 images.lock unchanged" "$(lock)" "${BASE_LOCK}"

# R3: the reviewer's case, one byte inside the largest layer member
a="$(archive)"
layer="$(tar -tvf "${a}" | sort -k3 -n | tail -1 | awk '{print $NF}')"
block="$(tar -tvRf "${a}" | grep -F " ${layer}" | sed -E 's/^block ([0-9]+):.*/\1/')"
flip_byte "${a}" $(( (block + 1) * 512 + 4096 ))
corrupt_sha="$(sha256sum "${a}" | cut -c1-64)"
check "R3 a layer byte flipped in the cached archive" "$(collect)" "0"
logged "R3 names the corrupt cache entry" "cache entry ${a} (${BOOT_REF}) is corrupt"
logged "R3 pulls it again" "pull ${BOOT_REF}"
check "R3 images.lock unchanged" "$(lock)" "${BASE_LOCK}"
if [[ "$(sha256sum "$(archive)" | cut -c1-64)" != "${corrupt_sha}" ]]; then ok "R3 the cache entry was replaced"; else not_ok "R3 the cache entry was replaced"; fi
staged_ok R3

# R4: one byte inside the largest OCI blob of the cached layout
pd="$(jq -r --arg s "${OCI_SLUG}" 'select(.slug == $s) | .platformDigest' "${T}/work/images.jsonl")"
o="${TEKNOIR_AIRGAP_CACHE}/images/oci/${pd#sha256:}"
blob="$(find "${o}/blobs/sha256" -type f -printf '%s %p\n' | sort -n | tail -1 | cut -d' ' -f2)"
flip_byte "${blob}" 100
check "R4 a blob byte flipped in the cached OCI layout" "$(collect)" "0"
logged "R4 names the corrupt cache entry" "cache entry ${o} (${OCI_REF}) is corrupt"
logged "R4 pulls it again" "pull ${OCI_REF}"
check "R4 images.lock unchanged" "$(lock)" "${BASE_LOCK}"
staged_ok R4

# R5: the recorded digest disagrees with the archive
echo "sha256:$(printf '0%.0s' {1..64})" > "$(archive).digest"
check "R5 a wrong recorded digest" "$(collect)" "0"
logged "R5 reports the digest mismatch" "the first pull recorded sha256:0000"
logged "R5 pulls it again" "pull ${BOOT_REF}"
check "R5 the recorded digest is the image's again" "$(cat "$(archive).digest")" "${BOOT_DIGEST}"
check "R5 images.lock unchanged" "$(lock)" "${BASE_LOCK}"

# R6: an entry from a build before digests were recorded
rm -f "$(archive).digest"
check "R6 no recorded digest" "$(collect)" "0"
not_logged "R6 adopts the verified entry (no pull)" "[build] pull "
check "R6 records the digest" "$(cat "$(archive).digest")" "${BOOT_DIGEST}"
check "R6 images.lock unchanged" "$(lock)" "${BASE_LOCK}"

echo "1..${N}"
if (( FAILED > 0 )); then
  echo "# ${FAILED} of ${N} checks failed (last log: see above)"
  sed 's/^/#   /' "${T}/run.log"
  exit 1
fi
echo "# all ${N} checks passed"
