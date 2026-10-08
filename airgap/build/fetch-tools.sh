#!/usr/bin/env bash
# fetch-tools.sh — download the pinned tools, k3s and its installer into the
# version-keyed cache, verify each against the upstream checksum file AND the
# sha256 pinned in airgap/versions.env, and place them (I-03).
#
#   --stage DIR      populate a bundle tree:
#                      DIR/node/bin/{helm,crane,jq,age}      (NODE_OS-NODE_ARCH)
#                      DIR/node/k3s/{k3s,k3s-airgap-images-<arch>.tar.zst,
#                                    install.sh,sha256sum-<arch>.txt}
#                      DIR/tools/<os>-<arch>/kubectl         (LAN_KUBECTL_PLATFORMS)
#   --host-bin DIR   extract the build's own helm, crane, jq and yq for this
#                    build host into DIR (used by every build step)
#   --print-pins     print the PINNED_SHA256 block for versions.env (after a
#                    version bump); artifacts without an upstream checksum file
#                    are downloaded once and marked trust-on-first-use
#   --dry-run        with --stage: print the plan, download nothing
#
# Cache: ${TEKNOIR_AIRGAP_CACHE:-~/.cache/teknoir-airgap}/tools/<tool>-<version>-<os>-<arch>/.
# A cached file whose sha256 differs from its pin fails the build (it is never
# silently re-downloaded): delete that cache entry to re-fetch it.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-build.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-build.sh"

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=""
TARGET=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) MODE=stage; TARGET="${2:?--stage needs a directory}"; shift ;;
    --host-bin) MODE=host-bin; TARGET="${2:?--host-bin needs a directory}"; shift ;;
    --print-pins) MODE=print-pins ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "${MODE}" ]] || { usage; exit 2; }
require_cmd curl tar sha256sum awk

# ---------------------------------------------------------------------------
# Artifact catalogue. art_<tool> <os> <arch> sets:
#   A_KEY   pin / cache key (carries the version)
#   A_URL   download URL
#   A_SUMS  upstream checksum file URL ("" = none, pin only)
#   A_SUMFMT  gnu (<hex>  <name>) | bsd (SHA256 (<name>) = <hex>) | bare (<hex>)
#             | github (the release API's asset "digest", for releases that
#             publish no checksum file)
#   A_NAME  the artifact's name inside the checksum file
#   A_FILE  cache file name
#   A_MEMBER  tar member holding the binary ("" = the download is the binary)
# ---------------------------------------------------------------------------
art_helm() {
  A_KEY="helm-${HELM_VERSION}-$1-$2"
  A_FILE="helm-${HELM_VERSION}-$1-$2.tar.gz"
  A_URL="https://get.helm.sh/${A_FILE}"
  A_SUMS="${A_URL}.sha256sum" A_SUMFMT=gnu A_NAME="${A_FILE}"
  A_MEMBER="$1-$2/helm"
}

art_crane() {
  local os arch
  case "$1" in linux) os=Linux ;; darwin) os=Darwin ;; *) die "crane: unsupported os $1" ;; esac
  case "$2" in amd64) arch=x86_64 ;; arm64) arch=arm64 ;; *) die "crane: unsupported arch $2" ;; esac
  A_KEY="crane-${CRANE_VERSION}-$1-$2"
  A_FILE="go-containerregistry_${os}_${arch}.tar.gz"
  A_URL="https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/${A_FILE}"
  A_SUMS="https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/checksums.txt"
  A_SUMFMT=gnu A_NAME="${A_FILE}" A_MEMBER="crane"
}

art_jq() {
  local os="$1"
  [[ "${os}" == darwin ]] && os=macos
  A_KEY="jq-${JQ_VERSION}-$1-$2"
  A_FILE="jq-${os}-$2"
  A_URL="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${A_FILE}"
  A_SUMS="https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/sha256sum.txt"
  A_SUMFMT=gnu A_NAME="${A_FILE}" A_MEMBER=""
}

art_yq() {
  A_KEY="yq-${YQ_VERSION}-$1-$2"
  A_FILE="yq_$1_$2"
  A_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${A_FILE}"
  A_SUMS="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/checksums-bsd"
  A_SUMFMT=bsd A_NAME="${A_FILE}" A_MEMBER=""
}

art_age() {
  A_KEY="age-${AGE_VERSION}-$1-$2"
  A_FILE="age-${AGE_VERSION}-$1-$2.tar.gz"
  A_URL="https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/${A_FILE}"
  # age publishes no checksum file; GitHub records a sha256 digest per asset
  A_SUMS="https://api.github.com/repos/FiloSottile/age/releases/tags/${AGE_VERSION}"
  A_SUMFMT=github A_NAME="${A_FILE}" A_MEMBER="age/age"
}

art_kubectl() {
  A_KEY="kubectl-${KUBECTL_VERSION}-$1-$2"
  A_FILE="kubectl"
  A_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/$1/$2/kubectl"
  A_SUMS="${A_URL}.sha256" A_SUMFMT=bare A_NAME="kubectl" A_MEMBER=""
}

# k3s release assets for NODE_ARCH. art_k3s <asset> where asset is one of
# bin | images | sums | install
art_k3s() {
  local base
  base="https://github.com/k3s-io/k3s/releases/download/$(k3s_url_version)"
  local sums_name="sha256sum-${NODE_ARCH}.txt" bin_asset="k3s"
  [[ "${NODE_ARCH}" == amd64 ]] || bin_asset="k3s-${NODE_ARCH}"
  A_MEMBER=""
  case "$1" in
    bin)
      A_KEY="k3s-${K3S_VERSION}-${bin_asset}" A_FILE="${bin_asset}" A_URL="${base}/${bin_asset}"
      A_SUMS="${base}/${sums_name}" A_SUMFMT=gnu A_NAME="${bin_asset}" ;;
    images)
      A_FILE="k3s-airgap-images-${NODE_ARCH}.tar.zst"
      A_KEY="k3s-${K3S_VERSION}-${A_FILE}" A_URL="${base}/${A_FILE}"
      A_SUMS="${base}/${sums_name}" A_SUMFMT=gnu A_NAME="${A_FILE}" ;;
    sums)
      # the checksum file itself: pinned, so a swapped release file is caught
      A_KEY="k3s-${K3S_VERSION}-${sums_name}" A_FILE="${sums_name}" A_URL="${base}/${sums_name}"
      A_SUMS="" A_SUMFMT="" A_NAME="" ;;
    install)
      # pinned to the release tag, never the unversioned get.k3s.io
      A_KEY="k3s-${K3S_VERSION}-install.sh" A_FILE="install.sh"
      A_URL="https://raw.githubusercontent.com/k3s-io/k3s/$(k3s_url_version)/install.sh"
      A_SUMS="" A_SUMFMT="" A_NAME="" ;;
    *) die "art_k3s: unknown asset $1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Download + verify
# ---------------------------------------------------------------------------
upstream_sha() {
  # upstream_sha — the artifact's sha256 according to its upstream checksum
  # file (A_SUMS/A_SUMFMT/A_NAME); empty when there is none
  local sums
  [[ -n "${A_SUMS}" ]] || return 0
  sums="$(curl -fsSL --retry 3 "${A_SUMS}")" || die "cannot download the checksum file ${A_SUMS}"
  case "${A_SUMFMT}" in
    gnu)  awk -v n="${A_NAME}" '{f=$2; sub(/^\*/, "", f)} f == n {print $1; exit}' <<<"${sums}" ;;
    bsd)  awk -v n="SHA256 (${A_NAME}) =" 'index($0, n) == 1 {print $NF; exit}' <<<"${sums}" ;;
    bare) awk 'NR == 1 {print $1}' <<<"${sums}" ;;
    github)
      # pretty-printed release JSON: the asset's "name" precedes its "digest"
      awk -v n="\"name\": \"${A_NAME}\"," '
        index($0, n) { hit = 1 }
        hit && /"digest": "sha256:[0-9a-f]+"/ { gsub(/.*sha256:|".*/, ""); print; exit }
        /"browser_download_url"/ { hit = 0 }
      ' <<<"${sums}" ;;
    *) die "unknown checksum format ${A_SUMFMT}" ;;
  esac
}

fetch_artifact() {
  # fetch_artifact — ensure the verified artifact described by A_* is in the
  # cache; prints its cache path
  local pin dir path tmp up got
  pin="${PINNED_SHA256[${A_KEY}]:-}"
  [[ -n "${pin}" ]] || die "no sha256 pin for ${A_KEY} in airgap/versions.env (run: airgap/build/fetch-tools.sh --print-pins)"
  dir="${CACHE_DIR}/tools/${A_KEY}"
  path="${dir}/${A_FILE}"
  if [[ -f "${path}" ]]; then
    got="$(sha256_file "${path}")"
    [[ "${got}" == "${pin}" ]] \
      || die "cached ${path} has sha256 ${got}, but versions.env pins ${pin} — the cache entry was modified; delete ${dir} to re-download"
    echo "${path}"
    return 0
  fi
  mkdir -p "${dir}"
  up="$(upstream_sha)"
  if [[ -n "${A_SUMS}" && -z "${up}" ]]; then
    die "${A_NAME} is not listed in ${A_SUMS}"
  fi
  if [[ -n "${up}" && "${up}" != "${pin}" ]]; then
    die "${A_KEY}: upstream checksum ${up} differs from the pin ${pin} in versions.env"
  fi
  tmp="$(mktemp "${dir}/.download.XXXXXX")"
  log "downloading ${A_URL}"
  if ! curl -fsSL --retry 3 -o "${tmp}" "${A_URL}"; then
    rm -f "${tmp}"
    die "download failed: ${A_URL}"
  fi
  got="$(sha256_file "${tmp}")"
  if [[ "${got}" != "${pin}" ]]; then
    rm -f "${tmp}"
    die "${A_KEY}: downloaded sha256 ${got} differs from the pin ${pin}"
  fi
  mv -f "${tmp}" "${path}"
  echo "${path}"
}

install_binary() {
  # install_binary <dest-file> — the verified artifact (A_*) as an executable
  local dest="$1" src tmpd
  src="$(fetch_artifact)"
  mkdir -p "$(dirname "${dest}")"
  if [[ -z "${A_MEMBER}" ]]; then
    cp "${src}" "${dest}.tmp"
  else
    tmpd="$(mktemp -d)"
    tar -xzf "${src}" -C "${tmpd}" "${A_MEMBER}" || { rm -rf "${tmpd}"; die "${src} has no member ${A_MEMBER}"; }
    mv -f "${tmpd}/${A_MEMBER}" "${dest}.tmp"
    rm -rf "${tmpd}"
  fi
  chmod 0755 "${dest}.tmp"
  mv -f "${dest}.tmp" "${dest}"
}

install_file() {
  # install_file <dest-file> <mode> — the verified artifact (A_*) copied as is
  local dest="$1" mode="$2" src
  src="$(fetch_artifact)"
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}.tmp"
  chmod "${mode}" "${dest}.tmp"
  mv -f "${dest}.tmp" "${dest}"
}

plan() {
  log "[dry-run] ${A_URL} -> $1 (pin ${PINNED_SHA256[${A_KEY}]:-MISSING}${A_SUMS:+, upstream ${A_SUMS##*/}})"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
NODE_TOOLS=(helm crane jq age)
HOST_TOOLS=(helm crane jq yq)

stage() {
  local out="$1" t plat a
  for t in "${NODE_TOOLS[@]}"; do
    "art_${t}" "${NODE_OS}" "${NODE_ARCH}"
    if (( DRY_RUN )); then plan "node/bin/${t}"; else install_binary "${out}/node/bin/${t}"; fi
  done
  for a in bin images sums install; do
    art_k3s "${a}"
    local dest="${out}/node/k3s/${A_FILE}" mode=0644
    [[ "${a}" == bin ]] && dest="${out}/node/k3s/k3s"
    [[ "${a}" == bin || "${a}" == install ]] && mode=0755
    if (( DRY_RUN )); then plan "${dest#"${out}"/}"; else install_file "${dest}" "${mode}"; fi
  done
  if (( ! DRY_RUN )); then
    # cross-check the bundled k3s files against the (pinned) release checksum file
    local sums="${out}/node/k3s/sha256sum-${NODE_ARCH}.txt" bin_asset=k3s
    [[ "${NODE_ARCH}" == amd64 ]] || bin_asset="k3s-${NODE_ARCH}"
    [[ "$(awk -v n="${bin_asset}" '$2 == n {print $1}' "${sums}")" == "$(sha256_file "${out}/node/k3s/k3s")" ]] \
      || die "node/k3s/k3s does not match ${sums##*/}"
    [[ "$(awk -v n="k3s-airgap-images-${NODE_ARCH}.tar.zst" '$2 == n {print $1}' "${sums}")" \
        == "$(sha256_file "${out}/node/k3s/k3s-airgap-images-${NODE_ARCH}.tar.zst")" ]] \
      || die "node/k3s/k3s-airgap-images-${NODE_ARCH}.tar.zst does not match ${sums##*/}"
  fi
  for plat in ${LAN_KUBECTL_PLATFORMS}; do
    art_kubectl "${plat%-*}" "${plat#*-}"
    if (( DRY_RUN )); then plan "tools/${plat}/kubectl"; else install_binary "${out}/tools/${plat}/kubectl"; fi
  done
  (( DRY_RUN )) || log "tools: node/bin (${NODE_TOOLS[*]}), node/k3s (${K3S_VERSION}), tools/{${LAN_KUBECTL_PLATFORMS// /,}}/kubectl"
}

host_bin() {
  local out="$1" plat t
  plat="$(host_platform)"
  rm -f "${out}/.complete"
  for t in "${HOST_TOOLS[@]}"; do
    "art_${t}" "${plat%-*}" "${plat#*-}"
    install_binary "${out}/${t}"
  done
  : > "${out}/.complete"
}

emit_pin() {
  # emit_pin — one PINNED_SHA256 line for the artifact described by A_*
  local sha tmp
  if [[ -n "${A_SUMS}" ]]; then
    sha="$(upstream_sha)"
    [[ -n "${sha}" ]] || die "${A_NAME} is not listed in ${A_SUMS}"
    printf '  [%s]=%s\n' "${A_KEY}" "${sha}"
  else
    tmp="$(mktemp)"
    curl -fsSL --retry 3 -o "${tmp}" "${A_URL}" || { rm -f "${tmp}"; die "download failed: ${A_URL}"; }
    printf '  [%s]=%s  # no upstream checksum file: trust on first use, review before committing\n' \
      "${A_KEY}" "$(sha256_file "${tmp}")"
    rm -f "${tmp}"
  fi
}

print_pins() {
  local t pair plat a
  local -a pairs=()
  local -A seen=()
  for t in "${NODE_TOOLS[@]}"; do pairs+=("${t} ${NODE_OS}-${NODE_ARCH}"); done
  for t in "${HOST_TOOLS[@]}"; do pairs+=("${t} $(host_platform)"); done
  for plat in ${LAN_KUBECTL_PLATFORMS}; do pairs+=("kubectl ${plat}"); done
  echo "declare -gA PINNED_SHA256=("
  for pair in "${pairs[@]}"; do
    t="${pair%% *}" plat="${pair#* }"
    "art_${t}" "${plat%-*}" "${plat#*-}"
    [[ -z "${seen[${A_KEY}]:-}" ]] || continue
    seen[${A_KEY}]=1
    emit_pin
  done
  for a in bin images sums install; do
    art_k3s "${a}"
    emit_pin
  done
  echo ")"
}

case "${MODE}" in
  stage) stage "${TARGET}" ;;
  host-bin) host_bin "${TARGET}" ;;
  print-pins) print_pins ;;
esac
