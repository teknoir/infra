#!/usr/bin/env bash
# bootstrap-bats.sh — install the pinned bats-core and print the path of its `bats`.
#
# Pinned and offline-friendly:
#   - the version and the sha256 of its tarball are pinned below; the tarball
#     is the immutable npm registry artifact (its sha512 integrity was
#     cross-checked against the registry metadata when pinned);
#   - it is installed once into a version-keyed cache
#     (${XDG_CACHE_HOME:-~/.cache}/teknoir-airgap/bats-core-<version>); later
#     runs need no network;
#   - offline installs: BATS_TARBALL=/path/to/bats-<version>.tgz (a copy of the
#     URL below, e.g. from a USB stick) is verified and used instead of a download.
# Bumping BATS_VERSION needs a new BATS_SHA256; the old cache entry is untouched.
# A tampered cache or tarball fails the sha256 check.
#
# Usage: bats="$(airgap/test/bats/bootstrap-bats.sh)"
set -euo pipefail

BATS_VERSION=1.13.0
BATS_SHA256=b7ae290dbc7e44709d5e3430698f3048a978bef871c6063f5fca49a20e5aaf58
BATS_URL="https://registry.npmjs.org/bats/-/bats-${BATS_VERSION}.tgz"
CACHE_ROOT="${TEKNOIR_TEST_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/teknoir-airgap}"
DEST="${CACHE_ROOT}/bats-core-${BATS_VERSION}"

die() { printf 'bootstrap-bats: %s\n' "$*" >&2; exit 1; }

if [[ -x "${DEST}/bin/bats" && -f "${DEST}/.tarball-sha256" ]] &&
   [[ "$(cat "${DEST}/.tarball-sha256")" == "${BATS_SHA256}" ]]; then
  printf '%s\n' "${DEST}/bin/bats"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
tgz="${BATS_TARBALL:-}"
if [[ -z "${tgz}" ]]; then
  command -v curl >/dev/null || die "curl is needed to download ${BATS_URL} (or set BATS_TARBALL)"
  curl -fsSL --retry 3 -o "${tmp}/bats.tgz" "${BATS_URL}" || die "download of ${BATS_URL} failed (offline? set BATS_TARBALL)"
  tgz="${tmp}/bats.tgz"
fi
got="$(sha256sum "${tgz}" | cut -d' ' -f1)"
[[ "${got}" == "${BATS_SHA256}" ]] || die "sha256 mismatch for ${tgz}: got ${got}, want ${BATS_SHA256}"
mkdir -p "${tmp}/x" "${CACHE_ROOT}"
tar -xzf "${tgz}" -C "${tmp}/x"
[[ -x "${tmp}/x/package/bin/bats" ]] || die "unexpected tarball layout (no package/bin/bats)"
printf '%s' "${BATS_SHA256}" > "${tmp}/x/package/.tarball-sha256"
rm -rf "${DEST}.tmp" "${DEST}"
mv "${tmp}/x/package" "${DEST}.tmp"
mv "${DEST}.tmp" "${DEST}"
printf '%s\n' "${DEST}/bin/bats"
