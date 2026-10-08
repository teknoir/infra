#!/usr/bin/env bash
# collect-images.sh — pull every image the bundle needs, single-platform and
# digest-locked (I-02):
#
#   bootstrap tier  everything the one-shot tiers render (<stage>/node/oneshot)
#                   plus BOOTSTRAP_EXTRA_IMAGES -> <stage>/node/bootstrap-images/<slug>.tar
#                   (single-platform docker archives: the node imports them into
#                   containerd before Harbor exists, and pushes them to Harbor)
#   all others      every image of every rendered Application (<work>/renders)
#                   plus airgap/images-extra.txt -> <stage>/node/images/<slug>/
#                   (one OCI layout per image with exactly one manifest)
#   lock            <stage>/node/images/images.lock: "<ref>@sha256:<digest> <slug>"
#                   for EVERY image, sorted. <digest> is what the node pushes and
#                   Harbor then serves: the upstream linux/amd64 manifest for an
#                   OCI layout, `crane digest --tarball` for a docker archive.
#                   <slug> is images/<slug>/ or bootstrap-images/<slug>.tar.
#
# Each image is stored once. Every tag is resolved to its digest on every build
# (mutable tags are never trusted); the content is cached by digest in
# ${TEKNOIR_AIRGAP_CACHE:-~/.cache/teknoir-airgap}/images/ and pulled into a
# .tmp path that is validated (one manifest, platform, blob checksums, config
# digest) before it is renamed into place, so an interrupted pull never leaves
# a partial entry.
#
# --images-limit N (or IMAGES_LIMIT=N): TEST ONLY. Pull only the first N
# images of each list. The bundle is then marked incomplete (make-bundle.sh
# adds "-incomplete" to the bundle id and the completeness gate only warns).
#
# Usage: collect-images.sh --stage DIR --work DIR [--images-limit N]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-build.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-build.sh"

usage() { sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

STAGE="" WORK="" LIMIT="${IMAGES_LIMIT:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="${2:?}"; shift ;;
    --work) WORK="${2:?}"; shift ;;
    --images-limit) LIMIT="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "${STAGE}" && -n "${WORK}" ]] || { usage; exit 2; }
[[ -z "${LIMIT}" || "${LIMIT}" =~ ^[0-9]+$ ]] || die "--images-limit must be a number"
[[ -d "${WORK}/renders" ]] || die "${WORK}/renders is missing (run collect-charts.sh first)"
[[ -f "${STAGE}/node/oneshot/TIERS" ]] || die "${STAGE}/node/oneshot is missing (run render-oneshot.sh first)"
use_build_tools "${WORK}"

read -r -a PLATFORMS <<<"${IMAGE_PLATFORMS}"
(( ${#PLATFORMS[@]} == 1 )) || die "IMAGE_PLATFORMS='${IMAGE_PLATFORMS}': exactly one platform is supported for now"
PLATFORM="${PLATFORMS[0]}"
P_OS="${PLATFORM%%/*}"
P_ARCH="${PLATFORM#*/}"
P_ARCH="${P_ARCH%%/*}"
P_VARIANT=""
[[ "${PLATFORM}" == */*/* ]] && P_VARIANT="${PLATFORM##*/}"

IMG_CACHE="${CACHE_DIR}/images"
OCI_OUT="${STAGE}/node/images"
DOCKER_OUT="${STAGE}/node/bootstrap-images"
mkdir -p "${IMG_CACHE}/oci" "${IMG_CACHE}/docker" "${OCI_OUT}" "${DOCKER_OUT}"
# a fresh store on every run: nothing from an earlier build survives
find "${OCI_OUT}" "${DOCKER_OUT}" -mindepth 1 -delete

# --- image lists -----------------------------------------------------------------
step "image lists"
{
  cat "${STAGE}/node/oneshot/"*.yaml | extract_images
  # shellcheck disable=SC2086  # a whitespace-separated list
  printf '%s\n' ${BOOTSTRAP_EXTRA_IMAGES} | while read -r r; do normalize_image "${r}"; done
} | sed '/^$/d' | LC_ALL=C sort -u > "${WORK}/images.bootstrap"
{
  cat "${WORK}/renders/"*.yaml | extract_images
  image_list_file "${AIRGAP_DIR}/images-extra.txt"
} | sed '/^$/d' | LC_ALL=C sort -u > "${WORK}/images.rendered"
LC_ALL=C sort -u "${WORK}/images.bootstrap" "${WORK}/images.rendered" > "${WORK}/images.required"
LC_ALL=C comm -23 "${WORK}/images.required" "${WORK}/images.bootstrap" > "${WORK}/images.regular"
log "$(wc -l < "${WORK}/images.required") images: $(wc -l < "${WORK}/images.bootstrap") bootstrap tier, $(wc -l < "${WORK}/images.regular") others"

# Bootstrap images are imported by name, so they need a tag
while read -r ref; do
  [[ -n "$(image_tag "${ref}")" ]] || die "bootstrap image ${ref} has no tag: containerd imports archives by tag name"
done < "${WORK}/images.bootstrap"

# Teknoir images on mutable tags (D8: warn for now; G-09 turns this into an error)
while read -r ref; do
  if is_teknoir_image "${ref}" && ! is_immutable_tag "${ref}"; then
    warn "mutable Teknoir image tag (D8, pinned by digest in images.lock only): ${ref}"
  fi
done < "${WORK}/images.required"

INCOMPLETE=0
if [[ -n "${LIMIT}" ]]; then
  warn "TEST ONLY: --images-limit ${LIMIT}: pulling only the first ${LIMIT} images of each list; the bundle is INCOMPLETE"
  head -n "${LIMIT}" "${WORK}/images.bootstrap" > "${WORK}/images.bootstrap.pull"
  head -n "${LIMIT}" "${WORK}/images.regular" > "${WORK}/images.regular.pull"
  INCOMPLETE=1
else
  cp "${WORK}/images.bootstrap" "${WORK}/images.bootstrap.pull"
  cp "${WORK}/images.regular" "${WORK}/images.regular.pull"
fi
echo "${INCOMPLETE}" > "${WORK}/images.incomplete"

# --- resolve ------------------------------------------------------------------------
resolve() {
  # resolve <ref> — sets R_INDEX (top-level digest; the index for multi-arch
  # images) and R_PLATFORM (the manifest digest for PLATFORM)
  local ref="$1" raw top mt
  raw="$(crane manifest "${ref}")" || die "cannot resolve ${ref} (crane manifest failed)"
  top="sha256:$(printf '%s' "${raw}" | sha256_stdin)"
  mt="$(jq -r '.mediaType // (if .manifests then "index" else "manifest" end)' <<<"${raw}")"
  R_INDEX="${top}"
  case "${mt}" in
    *index*|*manifest.list*)
      R_PLATFORM="$(jq -r --arg os "${P_OS}" --arg arch "${P_ARCH}" --arg v "${P_VARIANT}" '
        [.manifests[] | select(.platform.os == $os and .platform.architecture == $arch
                               and ($v == "" or .platform.variant == $v))][0].digest // ""' <<<"${raw}")"
      [[ -n "${R_PLATFORM}" ]] || die "${ref} has no ${PLATFORM} image (index ${top})"
      ;;
    *)
      R_PLATFORM="${top}"
      ;;
  esac
}

config_of() {
  # config_of <repo@digest> — the config digest of a single-platform manifest
  crane manifest "$1" | jq -r '.config.digest'
}

check_platform_config() {
  # check_platform_config <config.json> <what>
  local os arch
  os="$(jq -r '.os // ""' "$1")"
  arch="$(jq -r '.architecture // ""' "$1")"
  [[ "${os}" == "${P_OS}" && "${arch}" == "${P_ARCH}" ]] \
    || die "$2 is ${os}/${arch}, not ${PLATFORM}"
}

# --- OCI layouts ----------------------------------------------------------------------
validate_oci_layout() {
  # validate_oci_layout <dir> <digest> <deep:0|1> — exactly one manifest with
  # that digest, PLATFORM config, every referenced blob present (deep: and
  # every blob's sha256 equals its name)
  local dir="$1" digest="$2" deep="$3" m b blob size want
  [[ -f "${dir}/oci-layout" && -f "${dir}/index.json" ]] || return 1
  [[ "$(jq '.manifests | length' "${dir}/index.json")" == 1 ]] || return 1
  [[ "$(jq -r '.manifests[0].digest' "${dir}/index.json")" == "${digest}" ]] || return 1
  m="${dir}/blobs/sha256/${digest#sha256:}"
  [[ -f "${m}" && "$(sha256_file "${m}")" == "${digest#sha256:}" ]] || return 1
  jq -e '.layers and .config' "${m}" >/dev/null || return 1
  while read -r b size; do
    blob="${dir}/blobs/sha256/${b#sha256:}"
    [[ -f "${blob}" ]] || return 1
    [[ "$(stat -c %s "${blob}")" == "${size}" ]] || return 1
    if (( deep )); then
      want="${b#sha256:}"
      [[ "$(sha256_file "${blob}")" == "${want}" ]] || return 1
    fi
  done < <(jq -r '.config.digest + " " + (.config.size|tostring), (.layers[] | .digest + " " + (.size|tostring))' "${m}")
  check_platform_config "${dir}/blobs/sha256/$(jq -r '.config.digest | sub("^sha256:"; "")' "${m}")" "${digest}"
}

pull_oci() {
  # pull_oci <ref> <slug> — OCI layout of PLATFORM into the cache (by digest), then the stage
  local ref="$1" slug="$2" repo cached tmp
  repo="$(image_repo "${ref}")"
  cached="${IMG_CACHE}/oci/${R_PLATFORM#sha256:}"
  if [[ -d "${cached}" ]] && ! validate_oci_layout "${cached}" "${R_PLATFORM}" 0; then
    warn "cache entry ${cached} is invalid; pulling again"
    rm_build_dir "${cached}"
  fi
  if [[ ! -d "${cached}" ]]; then
    tmp="${cached}.tmp.$$"
    [[ ! -e "${tmp}" ]] || rm_build_dir "${tmp}"
    log "pull ${ref} (${PLATFORM} ${R_PLATFORM:7:12})"
    crane pull --format oci "${repo}@${R_PLATFORM}" "${tmp}" || { rm_build_dir "${tmp}"; die "crane pull failed: ${ref}"; }
    validate_oci_layout "${tmp}" "${R_PLATFORM}" 1 || { rm_build_dir "${tmp}"; die "pulled layout of ${ref} failed validation"; }
    mv -T "${tmp}" "${cached}"
  fi
  cp -a --reflink=auto "${cached}" "${OCI_OUT}/${slug}.tmp"
  mv -T "${OCI_OUT}/${slug}.tmp" "${OCI_OUT}/${slug}"
  L_DIGEST="${R_PLATFORM}"
  L_SIZE="$(du -sb "${OCI_OUT}/${slug}" | cut -f1)"
}

# --- docker archives --------------------------------------------------------------------
validate_docker_archive() {
  # validate_docker_archive <tar> <ref> <config-digest> — sets L_DIGEST
  local tar="$1" ref="$2" cfg="$3" tmpd
  tar -tf "${tar}" >/dev/null 2>&1 || return 1
  tmpd="$(mktemp -d)"
  tar -xf "${tar}" -C "${tmpd}" manifest.json 2>/dev/null || { rm -rf "${tmpd}"; return 1; }
  if [[ "$(jq 'length' "${tmpd}/manifest.json")" != 1 \
        || "$(jq -r '.[0].RepoTags | join(",")' "${tmpd}/manifest.json")" != "${ref}" \
        || "$(jq -r '.[0].Config' "${tmpd}/manifest.json")" != "${cfg}" ]]; then
    rm -rf "${tmpd}"
    return 1
  fi
  tar -xf "${tar}" -C "${tmpd}" "${cfg}" 2>/dev/null || { rm -rf "${tmpd}"; return 1; }
  check_platform_config "${tmpd}/${cfg}" "${ref}"
  rm -rf "${tmpd}"
  L_DIGEST="$(crane digest --tarball "${tar}")" || return 1
}

pull_docker() {
  # pull_docker <ref> <slug> — single-platform docker archive tagged <ref>
  local ref="$1" slug="$2" repo cfg cached tmp
  repo="$(image_repo "${ref}")"
  cfg="$(config_of "${repo}@${R_PLATFORM}")" || die "cannot read the config of ${ref}"
  cached="${IMG_CACHE}/docker/${R_PLATFORM#sha256:}-${slug}.tar"
  if [[ -f "${cached}" ]] && ! validate_docker_archive "${cached}" "${ref}" "${cfg}"; then
    warn "cache entry ${cached} is invalid; pulling again"
    rm -f "${cached}"
  fi
  if [[ ! -f "${cached}" ]]; then
    tmp="${cached}.tmp.$$"
    rm -f "${tmp}"
    log "pull ${ref} (${PLATFORM} archive ${R_PLATFORM:7:12})"
    # by tag, so the archive carries the tag containerd imports it under; the
    # config digest check below proves it is the image resolved above
    crane pull --platform "${PLATFORM}" --format tarball "${ref}" "${tmp}" || { rm -f "${tmp}"; die "crane pull failed: ${ref}"; }
    validate_docker_archive "${tmp}" "${ref}" "${cfg}" \
      || { rm -f "${tmp}"; die "pulled archive of ${ref} failed validation (did the tag move during the build?)"; }
    mv -f "${tmp}" "${cached}"
  fi
  cp --reflink=auto "${cached}" "${DOCKER_OUT}/${slug}.tar.tmp"
  mv -f "${DOCKER_OUT}/${slug}.tar.tmp" "${DOCKER_OUT}/${slug}.tar"
  L_SIZE="$(stat -c %s "${DOCKER_OUT}/${slug}.tar")"
}

# --- pull ----------------------------------------------------------------------------------
step "pulling images (${PLATFORM})"
: > "${WORK}/images.jsonl"
pull_list() {
  # pull_list <list> <oci|docker-archive> <bootstrap:true|false>
  local list="$1" format="$2" bootstrap="$3" ref slug
  while read -r ref; do
    [[ -n "${ref}" ]] || continue
    slug="$(image_slug "${ref}")"
    resolve "${ref}"
    L_DIGEST="" L_SIZE=0
    if [[ "${format}" == oci ]]; then pull_oci "${ref}" "${slug}"; else pull_docker "${ref}" "${slug}"; fi
    jq -cn --arg ref "${ref}" --arg slug "${slug}" --arg format "${format}" --argjson bootstrap "${bootstrap}" \
       --arg digest "${L_DIGEST}" --arg platformDigest "${R_PLATFORM}" --arg indexDigest "${R_INDEX}" \
       --argjson size "${L_SIZE}" \
       '{ref: $ref, slug: $slug, format: $format, bootstrap: $bootstrap, digest: $digest,
         platformDigest: $platformDigest, indexDigest: $indexDigest, size: $size}' >> "${WORK}/images.jsonl"
  done < "${list}"
}
pull_list "${WORK}/images.bootstrap.pull" docker-archive true
pull_list "${WORK}/images.regular.pull" oci false

# --- lock --------------------------------------------------------------------------------------
jq -r '.ref + "@" + .digest + " " + .slug' "${WORK}/images.jsonl" | LC_ALL=C sort > "${OCI_OUT}/images.lock"
# slugs must be unique across both stores
[[ -z "$(jq -r .slug "${WORK}/images.jsonl" | sort | uniq -d)" ]] || die "two images map to the same slug"
log "images.lock: $(wc -l < "${OCI_OUT}/images.lock") images, $(du -sh "${OCI_OUT}" | cut -f1) OCI layouts, $(du -sh "${DOCKER_OUT}" | cut -f1) bootstrap archives"
