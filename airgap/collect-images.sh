#!/usr/bin/env bash
# collect-images.sh — extract every container image referenced by the charts,
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

# --- image reference normalization -------------------------------------------
normalize_image() {
  # canonicalize: add docker.io[/library] for registry-less refs, strip quotes;
  # drop template/garbage refs (e.g. istiod's injection-template ConfigMap
  # contains literal `image: {{ ... }}` and `image: auto` lines)
  local ref="$1" first
  ref="${ref%\"}"; ref="${ref#\"}"
  ref="${ref%\'}"; ref="${ref#\'}"
  [[ -n "${ref}" ]] || return 0
  case "${ref}" in
    *['{}$`, ']*) return 0 ;;   # helm/go-template leftovers or lists
    auto|*/auto) return 0 ;;    # istio sidecar "auto" placeholder
  esac
  first="${ref%%/*}"
  if [[ "${ref}" != */* ]]; then
    ref="docker.io/library/${ref}"
  elif [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
    ref="docker.io/${ref}"
  fi
  # docker.io official images live under library/ (containerd normalizes them
  # before the registries.yaml rewrite, so the mirror path must match)
  if [[ "${ref}" == docker.io/* ]]; then
    local rest="${ref#docker.io/}"
    if [[ "${rest}" != */* ]]; then
      ref="docker.io/library/${rest}"
    fi
  fi
  # require an explicit tag or digest — rendered charts always pin images;
  # bare names are noise from embedded config blobs (istiod values, etc.)
  if [[ "${ref##*/}" != *[:@]* ]]; then
    return 0
  fi
  echo "${ref}"
}

extract_images() {
  # read rendered manifests on stdin, print normalized image refs
  sed -n -E 's/^[[:space:]]*-?[[:space:]]*"?image"?:[[:space:]]*//p' \
    | tr -d '"'"'" \
    | while read -r ref; do normalize_image "${ref}"; done
}

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

while read -r name version dir; do
  if [[ ! -d "${dir}" ]]; then
    warn "chart directory missing, skipping: ${dir}"
    continue
  fi
  log "templating ${name}-${version} for image extraction"
  helm_dep_build "${dir}" || { warn "dependency build failed for ${name}"; continue; }
  if ! rendered="$(helm_template_chart "${name}" "${dir}" 2>"${tmpdir}/err")"; then
    warn "helm template failed for ${name}: $(head -1 "${tmpdir}/err")"
    continue
  fi
  images="$(printf '%s\n' "${rendered}" | extract_images)"
  printf '%s\n' "${images}" >> "${all_list}"
  if is_bootstrap_chart "${name}"; then
    printf '%s\n' "${images}" >> "${bootstrap_list}"
  fi
done < <(all_charts)

# extras (comments / blank lines stripped)
sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${AIRGAP_DIR}/images-extra.txt" \
  | while read -r ref; do normalize_image "${ref}"; done >> "${all_list}"

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
