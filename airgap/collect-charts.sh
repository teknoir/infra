#!/usr/bin/env bash
# collect-charts.sh — package the pinned charts into <bundle>/charts/
# (connected side): every GITOPS_CHARTS entry from the gitops working tree and
# the infra argo chart, with vendored dependencies.
#
# Guards, all fatal:
#   * GITOPS_REPO_DIR must be on GITOPS_BRANCH (teknoir-local), so a staging
#     checkout can never be packaged for the air gap
#   * each Chart.yaml must carry exactly the pinned version
#   * versions.env must pin exactly what the pinned app-of-apps deploys
# RELEASED_CHARTS are never rebuilt (see versions.env). Bundle .tgz files of
# versions that are no longer pinned are removed, so push-to-harbor.sh only
# ever sees pinned versions.
#
# Usage: airgap/collect-charts.sh [--dry-run] [--bundle-dir DIR]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Packages the pinned GitOps charts + infra charts/argo (with vendored
dependencies) into \$BUNDLE_DIR/charts/.

Options:
  --dry-run          print what would be done, change nothing
  --bundle-dir DIR   override bundle directory (default: $(bundle_dir))
  -h, --help         show this help

Environment:
  GITOPS_REPO_DIR           gitops checkout (default: ${GITOPS_REPO_DIR})
  GITOPS_ALLOW_ANY_BRANCH=1 package from a branch other than ${GITOPS_BRANCH}
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

require_cmd helm git python3

BUNDLE="$(bundle_dir)"
CHARTS_OUT="${BUNDLE}/charts"

[[ -d "${GITOPS_REPO_DIR}/charts" ]] \
  || die "GitOps repo not found at ${GITOPS_REPO_DIR} (set GITOPS_REPO_DIR)"
require_gitops_branch

run mkdir -p "${CHARTS_OUT}"

# --- built charts: exact pinned version from the working tree -------------------
while read -r name version dir; do
  tgz="${CHARTS_OUT}/${name}-${version}.tgz"
  [[ -d "${dir}" ]] || die "chart directory missing: ${dir}"

  actual_version="$(chart_dir_version "${dir}")"
  [[ "${actual_version}" == "${version}" ]] \
    || die "${name}: ${dir}/Chart.yaml has version ${actual_version:-<none>}, versions.env pins ${version} — bump the pin or check out the matching revision"
  if [[ -n "$(git -C "${dir}" status --porcelain -- . 2>/dev/null)" ]]; then
    warn "${name}: uncommitted changes in ${dir} are packaged into ${name}-${version}"
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] helm dependency build ${dir} && helm package ${dir} -> ${tgz}"
    continue
  fi

  log "packaging ${name}-${version} from ${dir}"
  helm_dep_build "${dir}"
  helm package "${dir}" --destination "${CHARTS_OUT}" >/dev/null
  [[ -f "${tgz}" ]] || die "helm package did not produce ${tgz}"
done < <(built_charts)

# --- released charts: never rebuilt ---------------------------------------------
while read -r name version; do
  if [[ -f "${CHARTS_OUT}/${name}-${version}.tgz" ]]; then
    log "released ${name}-${version}: shipping ${CHARTS_OUT}/${name}-${version}.tgz as is"
  else
    log "released ${name}-${version}: not rebuilt; must already be in Harbor (no .tgz in the bundle, so no first bootstrap from it)"
  fi
done < <(released_charts)

# --- drop .tgz files of versions that are no longer pinned ------------------------
shopt -s nullglob
for tgz in "${CHARTS_OUT}/"*.tgz; do
  base="$(basename "${tgz}" .tgz)"
  if ! pinned_charts | awk -v b="${base}" '$1 "-" $2 == b {f=1} END {exit !f}'; then
    log "removing unpinned ${base}.tgz from the bundle"
    run rm -f "${tgz}"
  fi
done
shopt -u nullglob

# --- versions.env must match what app-of-apps deploys -----------------------------
check_app_of_apps_pins

if [[ "${DRY_RUN}" == "1" ]]; then
  log "dry-run complete (no charts packaged)"
else
  log "charts packaged into ${CHARTS_OUT}:"
  ls -1 "${CHARTS_OUT}" >&2
fi
