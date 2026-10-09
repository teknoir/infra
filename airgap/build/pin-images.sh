#!/usr/bin/env bash
# pin-images.sh — print or verify G-09 image pins (r5 contract K5):
#
#   <repo>:<immutable tag>@sha256:<linux/amd64 manifest digest>
#
# for the gitops chart values. The immutable tag is the CI's sha-<hex>, its
# <branch>-YYYYMMDD-HHMMSS build tag, or a semantic version; the digest is the
# linux/amd64 manifest (crane digest --platform linux/amd64), never the
# multi-platform index, whose digest changes with every build's provenance
# attestation while the amd64 manifest does not.
#
#   airgap/build/pin-images.sh ghcr.io/teknoir/user-controller:sha-0930b615 ...
#       one pinned reference per argument
#   airgap/build/pin-images.sh --verify ghcr.io/teknoir/user-controller:sha-0930b615@sha256:59ba...
#       each pinned reference: the tag still resolves to that linux/amd64
#       manifest, and the digest is an image manifest of that platform
#
# Uses the pinned crane of the bundle build (airgap/versions.env). Exit 0 when
# every argument resolved (or verified), 1 otherwise.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-build.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-build.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

VERIFY=0
refs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) VERIFY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) refs+=("$1") ;;
  esac
  shift
done
(( ${#refs[@]} > 0 )) || { usage; exit 2; }

PLATFORM="linux/amd64"
TMPW="$(mktemp -d)"
trap 'rm -rf -- "${TMPW}"' EXIT
use_build_tools "${TMPW}/work"

rc=0
for ref in "${refs[@]}"; do
  base="${ref%%@*}"
  tag="$(image_tag "${base}")"
  repo="$(image_repo "${base}")"
  if [[ -z "${tag}" || ! "${tag}" =~ ${IMMUTABLE_TAG_RE} ]]; then
    warn "${ref}: tag '${tag:-none}' is not immutable (sha-<hex>, <branch>-YYYYMMDD-HHMMSS or semver); use the sha- tag CI pushed for that commit"
    rc=1
    continue
  fi
  if ! d="$(crane digest --platform "${PLATFORM}" "${repo}:${tag}" 2>/dev/null)"; then
    warn "${ref}: cannot resolve ${repo}:${tag} for ${PLATFORM}"
    rc=1
    continue
  fi
  if (( VERIFY )); then
    want="${ref##*@}"
    if [[ "${ref}" != *@sha256:* ]]; then
      warn "${ref}: no digest to verify"
      rc=1
    elif [[ "${want}" != "${d}" ]]; then
      warn "${ref}: ${repo}:${tag} is ${d} for ${PLATFORM} now (moved, or an index digest was pinned)"
      rc=1
    elif ! m="$(crane manifest "${repo}@${want}" 2>/dev/null)" || jq -e '.manifests' <<<"${m}" >/dev/null 2>&1; then
      warn "${ref}: ${want} is not a single-platform image manifest"
      rc=1
    else
      echo "ok ${ref}"
    fi
  else
    echo "${repo}:${tag}@${d}"
  fi
done
exit "${rc}"
