#!/usr/bin/env bash
# collect-charts.sh — vendor dependencies and package every GitOps chart plus
# the infra argo chart into <bundle>/charts/ (connected side).
#
# Usage: airgap/collect-charts.sh [--dry-run] [--bundle-dir DIR]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Packages all GitOps charts + infra charts/argo (with vendored dependencies)
into \$BUNDLE_DIR/charts/.

Options:
  --dry-run          print what would be done, change nothing
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

BUNDLE="$(bundle_dir)"
CHARTS_OUT="${BUNDLE}/charts"

[[ -d "${GITOPS_REPO_DIR}/charts" ]] \
  || die "GitOps repo not found at ${GITOPS_REPO_DIR} (set GITOPS_REPO_DIR)"

run mkdir -p "${CHARTS_OUT}"

failures=0
while read -r name version dir; do
  tgz="${CHARTS_OUT}/${name}-${version}.tgz"
  if [[ ! -d "${dir}" ]]; then
    warn "chart directory missing, skipping: ${dir}"
    failures=$((failures + 1))
    continue
  fi

  actual_version="$(awk '/^version:/{print $2; exit}' "${dir}/Chart.yaml")"
  if [[ "${actual_version}" != "${version}" ]]; then
    warn "${name}: Chart.yaml version ${actual_version} != pinned ${version} (versions.env)"
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] helm dependency build ${dir} && helm package ${dir} -> ${tgz}"
    continue
  fi

  log "packaging ${name}-${version} from ${dir}"
  helm_dep_build "${dir}"
  helm package "${dir}" --destination "${CHARTS_OUT}" >/dev/null

  [[ -f "${CHARTS_OUT}/${name}-${actual_version}.tgz" ]] \
    || die "helm package did not produce ${name}-${actual_version}.tgz"
done < <(all_charts)

if [[ "${failures}" -gt 0 ]]; then
  die "${failures} chart(s) could not be collected"
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  log "dry-run complete (no charts packaged)"
else
  log "charts packaged into ${CHARTS_OUT}:"
  ls -1 "${CHARTS_OUT}" >&2
fi
