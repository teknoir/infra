#!/usr/bin/env bash
# collect-images.sh — extract every container image referenced by the pinned
# charts (image: fields and image-valued container args, lib.sh:extract_images),
# merge with images-extra.txt, and pull them (connected side):
#   * all images        -> <bundle>/images/<name>/ as OCI layouts (digest-dedup)
#   * bootstrap images  -> <bundle>/bootstrap/images/<name>.tar as
#                          containerd-importable tarballs (istio, argo, harbor, pause)
#
# Usage: airgap/collect-images.sh [--dry-run] [--bundle-dir DIR]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --dry-run          only print the resolved image lists, pull nothing
  --bundle-dir DIR   override bundle directory (default: $(bundle_dir))
  -h, --help         show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --bundle-dir) BUNDLE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd helm
[[ "${DRY_RUN}" == "1" ]] || require_cmd crane

BUNDLE="$(bundle_dir)"
IMAGES_OUT="${BUNDLE}/images"
BOOTSTRAP_IMAGES_OUT="${BUNDLE}/bootstrap/images"

# --- collect image lists -------------------------------------------------------
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
all_list="${tmpdir}/all.txt"
bootstrap_list="${tmpdir}/bootstrap.txt"
: > "${all_list}"
: > "${bootstrap_list}"

is_bootstrap_chart() {
  local b
  for b in "${BOOTSTRAP_CHARTS[@]}"; do
    [[ "$1" == "${b}" ]] && return 0
  done
  return 1
}

# Pinned versions only (bundle .tgz, else the working tree at that version).
while read -r name version; do
  if ! dir="$(chart_source "${name}" "${version}")"; then
    warn "no source for released ${name}-${version}: its images are not collected (they must already be in Harbor)"
    continue
  fi
  log "templating ${name}-${version} for image extraction"
  helm_dep_build "${dir}" || die "dependency build failed for ${name}"
  if ! rendered="$(helm_template_chart "${name}" "${dir}" 2>"${tmpdir}/err")"; then
    die "helm template failed for ${name}: $(head -1 "${tmpdir}/err")"
  fi
  images="$(printf '%s\n' "${rendered}" | extract_images)"
  printf '%s\n' "${images}" >> "${all_list}"
  if is_bootstrap_chart "${name}"; then
    printf '%s\n' "${images}" >> "${bootstrap_list}"
  fi
done < <(pinned_charts)

# images the rendered charts do not reveal (images-extra.txt)
extra_images >> "${all_list}"

# bootstrap tier always includes the sidecar proxy and the pause image
{
  normalize_image "${ISTIO_PROXYV2_IMAGE}"
  normalize_image "${PAUSE_IMAGE}"
} >> "${bootstrap_list}"

sort -u -o "${all_list}" <(sed '/^$/d' "${all_list}")
sort -u -o "${bootstrap_list}" <(sed '/^$/d' "${bootstrap_list}")

log "resolved $(wc -l < "${all_list}" | tr -d ' ') unique images ($(wc -l < "${bootstrap_list}" | tr -d ' ') bootstrap-tier)"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "# --- all images (OCI layouts -> ${IMAGES_OUT}) ---"
  cat "${all_list}"
  echo "# --- bootstrap images (tarballs -> ${BOOTSTRAP_IMAGES_OUT}) ---"
  cat "${bootstrap_list}"
  exit 0
fi

# --- pull: OCI layouts (all images) --------------------------------------------
mkdir -p "${IMAGES_OUT}" "${BOOTSTRAP_IMAGES_OUT}"
index_file="${IMAGES_OUT}/images.txt"
: > "${index_file}"

while read -r ref; do
  name="$(sanitize_ref "${ref}")"
  layout="${IMAGES_OUT}/${name}"
  echo "${ref} ${name}" >> "${index_file}"
  if [[ -f "${layout}/index.json" ]]; then
    log "oci layout exists, skipping pull: ${ref}"
    continue
  fi
  log "crane pull (oci) ${ref}"
  crane pull --format=oci "${ref}" "${layout}"
done < "${all_list}"

# Digest-level dedup across layouts: hardlink identical blobs (same sha256 name).
log "deduplicating blobs across OCI layouts (hardlinks)"
declare -A seen_blob
while read -r blob; do
  digest="$(basename "${blob}")"
  if [[ -n "${seen_blob[${digest}]:-}" ]]; then
    if [[ ! "${blob}" -ef "${seen_blob[${digest}]}" ]]; then
      ln -f "${seen_blob[${digest}]}" "${blob}"
    fi
  else
    seen_blob["${digest}"]="${blob}"
  fi
done < <(find "${IMAGES_OUT}" -type f -path '*/blobs/sha256/*')

# --- pull: containerd tarballs (bootstrap tier) ---------------------------------
while read -r ref; do
  tarball="${BOOTSTRAP_IMAGES_OUT}/$(sanitize_ref "${ref}").tar"
  if [[ -f "${tarball}" ]]; then
    log "tarball exists, skipping pull: ${ref}"
    continue
  fi
  log "crane pull (tarball) ${ref}"
  crane pull --format=tarball "${ref}" "${tarball}"
done < "${bootstrap_list}"

log "images written to ${IMAGES_OUT} (index: ${index_file})"
log "bootstrap tarballs written to ${BOOTSTRAP_IMAGES_OUT}"
