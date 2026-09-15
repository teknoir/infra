#!/usr/bin/env bash
# make-bundle.sh — build the full air-gap bundle (connected side).
# Orchestrates collect-charts.sh, collect-images.sh and render-bootstrap.sh,
# copies the bootstrap secret manifests + pinned tools, embeds the air-gapped
# side's operational scripts (airgap/ runtime + scripts/ secret helpers), and
# writes bundle-manifest.yaml with a sha256 checksum for every file.
#
# Usage: airgap/make-bundle.sh [--dry-run] [--diff [OLD_MANIFEST]] [--bundle-dir DIR]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds the §4.3 bundle layout:
  $(bundle_dir)/
    bundle-manifest.yaml
    bootstrap/{images,manifests,secrets,k3s}/
    charts/  images/  tools/  k3s/
    airgap/  scripts/

Options:
  --dry-run              print planned actions, download/write nothing
  --diff [OLD_MANIFEST]  after building, compare against a previous
                         bundle-manifest.yaml and emit only changed artifacts
                         into <bundle>-diff/ (default OLD_MANIFEST: the
                         bundle's pre-existing bundle-manifest.yaml)
  --bundle-dir DIR       override bundle directory
  -h, --help             show this help
EOF
}

DIFF_MODE=0
OLD_MANIFEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --diff)
      DIFF_MODE=1
      if [[ $# -gt 1 && "${2:-}" != --* ]]; then
        OLD_MANIFEST="$2"; shift
      fi
      ;;
    --bundle-dir) BUNDLE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd helm curl tar
[[ "${DRY_RUN}" == "1" ]] || require_cmd crane

BUNDLE="$(bundle_dir)"
export BUNDLE_DIR="${BUNDLE}"

# Preserve the previous manifest for --diff before we overwrite it.
if [[ "${DIFF_MODE}" == "1" && -z "${OLD_MANIFEST}" && -f "${BUNDLE}/bundle-manifest.yaml" ]]; then
  OLD_MANIFEST="$(mktemp)"
  cp "${BUNDLE}/bundle-manifest.yaml" "${OLD_MANIFEST}"
fi

# ---------------------------------------------------------------------------
# 1-3. charts, images, bootstrap manifests
# ---------------------------------------------------------------------------
pass_args=()
if [[ "${DRY_RUN}" == "1" ]]; then
  pass_args+=(--dry-run)
fi

log "step 1/8: collecting charts"
"${AIRGAP_DIR}/collect-charts.sh" "${pass_args[@]}" --bundle-dir "${BUNDLE}"

log "step 2/8: collecting images"
"${AIRGAP_DIR}/collect-images.sh" "${pass_args[@]}" --bundle-dir "${BUNDLE}"

log "step 3/8: rendering bootstrap manifests"
"${AIRGAP_DIR}/render-bootstrap.sh" "${pass_args[@]}" --bundle-dir "${BUNDLE}"

# ---------------------------------------------------------------------------
# 4. bootstrap secret manifests (produced by scripts/gen-*.sh, gitignored)
# ---------------------------------------------------------------------------
log "step 4/8: copying secret manifests"
SECRET_MANIFESTS=(
  manifest-teknoir-ca-secret.yaml
  manifest-wildcard-tls-secret.yaml
  manifest-harbor-secret.yaml
  manifest-keycloak-db-secret.yaml
  manifest-oauth2-proxy-secret.yaml
  manifest-oauth2-proxy-redis-secret.yaml
  manifest-argocd-keycloak-secret.yaml
  manifest-argocd-harbor-repo-secret.yaml
  manifest-teknoir-auth-ca-bundle-secret.yaml
  manifest-teknoir-system-ca-bundle-secret.yaml
)
SECRETS_SRC="${REPO_ROOT}/.secrets"   # scripts/gen-*.sh write manifests here (gitignored)
SECRETS_OUT="${BUNDLE}/bootstrap/secrets"
run mkdir -p "${SECRETS_OUT}"
missing_secrets=0
for m in "${SECRET_MANIFESTS[@]}"; do
  if [[ -f "${SECRETS_SRC}/${m}" ]]; then
    run cp "${SECRETS_SRC}/${m}" "${SECRETS_OUT}/${m}"
  else
    warn "secret manifest missing (run the scripts/gen-*.sh generators): ${SECRETS_SRC}/${m}"
    missing_secrets=$((missing_secrets + 1))
  fi
done
if [[ "${missing_secrets}" -gt 0 ]]; then
  warn "${missing_secrets} secret manifest(s) missing — bundle is incomplete for first bootstrap"
fi

# ---------------------------------------------------------------------------
# 5. pinned tools (crane + helm for each TOOL_PLATFORM)
# ---------------------------------------------------------------------------
log "step 5/8: downloading pinned tools (crane ${CRANE_VERSION}, helm ${HELM_VERSION})"
TOOLS_OUT="${BUNDLE}/tools"

crane_url() {
  # crane_url <os> <arch>
  local os arch
  case "$1" in linux) os="Linux" ;; darwin) os="Darwin" ;; *) os="$1" ;; esac
  case "$2" in amd64) arch="x86_64" ;; *) arch="$2" ;; esac
  echo "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/go-containerregistry_${os}_${arch}.tar.gz"
}

helm_url() {
  echo "https://get.helm.sh/helm-${HELM_VERSION}-$1-$2.tar.gz"
}

for platform in "${TOOL_PLATFORMS[@]}"; do
  os="${platform%% *}"
  arch="${platform##* }"
  dest="${TOOLS_OUT}/${os}-${arch}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] download $(crane_url "${os}" "${arch}") -> ${dest}/crane"
    log "[dry-run] download $(helm_url "${os}" "${arch}") -> ${dest}/helm"
    continue
  fi
  mkdir -p "${dest}"
  if [[ ! -x "${dest}/crane" ]]; then
    log "downloading crane ${CRANE_VERSION} (${os}/${arch})"
    curl -fsSL "$(crane_url "${os}" "${arch}")" | tar -xz -C "${dest}" crane
    chmod +x "${dest}/crane"
  fi
  if [[ ! -x "${dest}/helm" ]]; then
    log "downloading helm ${HELM_VERSION} (${os}/${arch})"
    curl -fsSL "$(helm_url "${os}" "${arch}")" | tar -xz -C "${dest}" --strip-components=1 "${os}-${arch}/helm"
    chmod +x "${dest}/helm"
  fi
done

# ---------------------------------------------------------------------------
# 6. pinned K3s install artifacts (offline node install — docs/AIRGAP-HOST-SETUP.md)
# ---------------------------------------------------------------------------
log "step 6/8: downloading pinned K3s artifacts (${K3S_VERSION}, ${K3S_ARCH})"
K3S_OUT="${BUNDLE}/k3s"
K3S_RELEASE_BASE="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"
K3S_IMAGES_TAR="k3s-airgap-images-${K3S_ARCH}.tar.zst"
K3S_SHA_FILE="sha256sum-${K3S_ARCH}.txt"
# k3s binary asset name: "k3s" for amd64, "k3s-<arch>" for every other arch.
if [[ "${K3S_ARCH}" == "amd64" ]]; then K3S_BIN_ASSET="k3s"; else K3S_BIN_ASSET="k3s-${K3S_ARCH}"; fi

# Verify a downloaded asset against the release's own sha256sum-<arch>.txt.
k3s_verify_sha() {
  # k3s_verify_sha <asset-name-in-sha-file> <local-file>
  local want got
  want="$(awk -v a="$1" '$2 == a {print $1}' "${K3S_OUT}/${K3S_SHA_FILE}")"
  [[ -n "${want}" ]] || die "no sha256 entry for $1 in ${K3S_SHA_FILE}"
  got="$(sha256_file "$2")"
  [[ "${want}" == "${got}" ]] || die "sha256 mismatch for $2 (want ${want}, got ${got})"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] download ${K3S_RELEASE_BASE}/${K3S_BIN_ASSET} -> ${K3S_OUT}/k3s"
  log "[dry-run] download ${K3S_RELEASE_BASE}/${K3S_IMAGES_TAR} -> ${K3S_OUT}/${K3S_IMAGES_TAR}"
  log "[dry-run] download ${K3S_RELEASE_BASE}/${K3S_SHA_FILE} -> ${K3S_OUT}/${K3S_SHA_FILE}"
  log "[dry-run] download https://get.k3s.io -> ${K3S_OUT}/install.sh"
else
  mkdir -p "${K3S_OUT}"
  if [[ ! -f "${K3S_OUT}/${K3S_SHA_FILE}" ]]; then
    log "downloading ${K3S_SHA_FILE}"
    curl -fsSL "${K3S_RELEASE_BASE}/${K3S_SHA_FILE}" -o "${K3S_OUT}/${K3S_SHA_FILE}"
  fi
  if [[ ! -x "${K3S_OUT}/k3s" ]]; then
    log "downloading k3s binary ${K3S_VERSION} (${K3S_ARCH})"
    curl -fsSL "${K3S_RELEASE_BASE}/${K3S_BIN_ASSET}" -o "${K3S_OUT}/k3s"
    chmod +x "${K3S_OUT}/k3s"
  fi
  if [[ ! -f "${K3S_OUT}/${K3S_IMAGES_TAR}" ]]; then
    log "downloading k3s airgap images (${K3S_IMAGES_TAR})"
    curl -fsSL "${K3S_RELEASE_BASE}/${K3S_IMAGES_TAR}" -o "${K3S_OUT}/${K3S_IMAGES_TAR}"
  fi
  if [[ ! -x "${K3S_OUT}/install.sh" ]]; then
    log "downloading k3s install.sh from get.k3s.io"
    curl -fsSL "https://get.k3s.io" -o "${K3S_OUT}/install.sh"
    chmod +x "${K3S_OUT}/install.sh"
  fi
  log "verifying k3s artifacts against ${K3S_SHA_FILE}"
  k3s_verify_sha "${K3S_BIN_ASSET}" "${K3S_OUT}/k3s"
  k3s_verify_sha "${K3S_IMAGES_TAR}" "${K3S_OUT}/${K3S_IMAGES_TAR}"
fi

# ---------------------------------------------------------------------------
# 7. operational scripts (air-gapped side)
#    Embed the scripts the air-gapped side runs so the bundle is self-contained
#    once copied to the node (docs/AIRGAP-HOST-SETUP.md §8.1 / upload-bundle.sh).
#    Only runtime + secret helpers travel; build-only steps that need internet
#    (make/collect/render/verify) are intentionally excluded.
# ---------------------------------------------------------------------------
log "step 7/8: copying operational scripts"

# airgap/ runtime tooling (+ shared lib.sh / versions.env) run against the node.
AIRGAP_RUNTIME_SCRIPTS=(
  lib.sh
  versions.env
  bootstrap-airgap.sh
  push-to-harbor.sh
  deploy-app-of-apps.sh
  update-airgap.sh
  upload-bundle.sh
  install-k3s.sh
  extract-kubeconfig.sh
)
AIRGAP_SCRIPTS_OUT="${BUNDLE}/airgap"
run mkdir -p "${AIRGAP_SCRIPTS_OUT}"
for f in "${AIRGAP_RUNTIME_SCRIPTS[@]}"; do
  if [[ -f "${AIRGAP_DIR}/${f}" ]]; then
    run cp "${AIRGAP_DIR}/${f}" "${AIRGAP_SCRIPTS_OUT}/${f}"
  else
    warn "airgap script missing (not copied into bundle): ${AIRGAP_DIR}/${f}"
  fi
done

# scripts/ secret generators + deployers (initial secrets on the connected
# workstation; re-run on the LAN laptop for the §6/§8 rotations). bootstrap_*.sh
# are gitignored, machine-generated helpers and are never bundled.
SCRIPTS_OUT="${BUNDLE}/scripts"
run mkdir -p "${SCRIPTS_OUT}"
shopt -s nullglob
repo_scripts=("${REPO_ROOT}/scripts/"*.sh)
shopt -u nullglob
for f in "${repo_scripts[@]}"; do
  base="$(basename "${f}")"
  case "${base}" in bootstrap_*.sh) continue ;; esac
  run cp "${f}" "${SCRIPTS_OUT}/${base}"
done

# Keep the copied entry points executable (cp usually preserves the +x bit;
# this is a belt-and-braces safety net, skipped in dry-run).
if [[ "${DRY_RUN}" != "1" ]]; then
  chmod +x "${AIRGAP_SCRIPTS_OUT}/"*.sh "${SCRIPTS_OUT}/"*.sh 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 8. bundle-manifest.yaml (+ optional --diff)
# ---------------------------------------------------------------------------
log "step 8/8: writing bundle-manifest.yaml"
MANIFEST="${BUNDLE}/bundle-manifest.yaml"

if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] would checksum every file under ${BUNDLE} into ${MANIFEST}"
  if [[ "${DIFF_MODE}" == "1" ]]; then
    log "[dry-run] would diff against ${OLD_MANIFEST:-<previous bundle-manifest.yaml>}"
  fi
  log "dry-run complete"
  exit 0
fi

tmp_manifest="$(mktemp)"
{
  echo "apiVersion: teknoir.org/v1"
  echo "kind: AirgapBundleManifest"
  echo "bundleVersion: \"${BUNDLE_VERSION}\""
  echo "domain: \"${TEKNOIR_DOMAIN}\""
  echo "createdAt: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "files:"
} > "${tmp_manifest}"

(cd "${BUNDLE}" && find . -type f ! -name bundle-manifest.yaml | sed 's|^\./||' | LC_ALL=C sort) \
  | while read -r rel; do
      sha="$(sha256_file "${BUNDLE}/${rel}")"
      printf '  - path: %s\n    sha256: %s\n' "${rel}" "${sha}" >> "${tmp_manifest}"
    done

mv "${tmp_manifest}" "${MANIFEST}"
log "bundle manifest written: ${MANIFEST}"

if [[ "${DIFF_MODE}" == "1" ]]; then
  if [[ -z "${OLD_MANIFEST}" || ! -f "${OLD_MANIFEST}" ]]; then
    warn "--diff requested but no previous bundle-manifest.yaml found — skipping diff"
    exit 0
  fi
  DIFF_OUT="${BUNDLE}-diff"
  rm -rf "${DIFF_OUT}"
  mkdir -p "${DIFF_OUT}"

  # flatten "path/sha256" pairs from a manifest
  manifest_pairs() {
    awk '/^  - path: /{p=$3} /^    sha256: /{print p, $2}' "$1"
  }

  changed=0
  while read -r rel sha; do
    old_sha="$(manifest_pairs "${OLD_MANIFEST}" | awk -v p="${rel}" '$1==p{print $2}')"
    if [[ "${old_sha}" != "${sha}" ]]; then
      mkdir -p "${DIFF_OUT}/$(dirname "${rel}")"
      cp -R "${BUNDLE}/${rel}" "${DIFF_OUT}/${rel}"
      changed=$((changed + 1))
      log "diff: ${rel} ($([[ -n "${old_sha}" ]] && echo changed || echo new))"
    fi
  done < <(manifest_pairs "${MANIFEST}")

  cp "${MANIFEST}" "${DIFF_OUT}/bundle-manifest.yaml"
  if [[ "${changed}" -eq 0 ]]; then
    log "diff: no changed artifacts (empty delta)"
    rm -rf "${DIFF_OUT}"
  else
    log "diff bundle with ${changed} changed artifact(s): ${DIFF_OUT}"
  fi
fi

log "bundle complete: ${BUNDLE}"
