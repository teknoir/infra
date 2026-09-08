#!/usr/bin/env bash
# Shared helpers for the airgap tooling. Sourced by every airgap/*.sh script.
# shellcheck shell=bash

# Guard against double-sourcing
if [[ -n "${AIRGAP_LIB_SOURCED:-}" ]]; then
  return 0
fi
AIRGAP_LIB_SOURCED=1

AIRGAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${AIRGAP_DIR}/.." && pwd)"
export AIRGAP_DIR REPO_ROOT

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m[airgap]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[airgap] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[airgap] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

# ---------------------------------------------------------------------------
# Dry-run support: every mutating action goes through run() / run_ssh() / run_scp()
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Versions / configuration
# ---------------------------------------------------------------------------
# shellcheck source=versions.env
source "${AIRGAP_DIR}/versions.env"

bundle_dir() {
  echo "${BUNDLE_DIR:-${REPO_ROOT}/bundle/teknoir-airgap-bundle-${BUNDLE_VERSION}}"
}

# Print "name version dir" for every chart that ships in the bundle
# (all GitOps charts + the infra argo chart).
all_charts() {
  local entry name version
  for entry in "${GITOPS_CHARTS[@]}"; do
    name="${entry%% *}"
    version="${entry##* }"
    echo "${name} ${version} ${GITOPS_REPO_DIR}/charts/${name}"
  done
  for entry in "${INFRA_CHARTS[@]}"; do
    name="${entry%% *}"
    version="${entry##* }"
    echo "${name} ${version} ${REPO_ROOT}/charts/${name}"
  done
}

# Namespace a chart is installed into (bootstrap + gitops conventions).
chart_namespace() {
  case "$1" in
    istio) echo "istio-system" ;;
    *)     echo "teknoir-system" ;;
  esac
}

# Extra `helm template` args forcing teknoir.airgapped rendering regardless of the
# checked-out values.yaml state.
chart_template_args() {
  case "$1" in
    istio)
      echo "--set global.domain=${TEKNOIR_DOMAIN}"
      ;;
    harbor)
      echo "--set domain=${TEKNOIR_DOMAIN} --set hostname=harbor.${TEKNOIR_DOMAIN}"
      ;;
    argo)
      echo "--set domain=${TEKNOIR_DOMAIN} --set argo-cd.global.domain=argocd.${TEKNOIR_DOMAIN}"
      ;;
    auth|monitoring|app-of-apps|cert-manager|*-controller)
      echo "--set domain=${TEKNOIR_DOMAIN} --set global.domain=${TEKNOIR_DOMAIN}"
      ;;
    *)
      echo ""
      ;;
  esac
}

# helm_template_chart <name> <dir> — render a chart with teknoir.airgapped values.
helm_template_chart() {
  local name="$1" dir="$2" args
  args="$(chart_template_args "${name}")"
  # shellcheck disable=SC2086
  helm template "${name}" "${dir}" \
    --namespace "$(chart_namespace "${name}")" \
    --include-crds \
    --kube-version "${KUBE_VERSION:-1.33.0}" \
    ${args}
}

# Ensure a chart's dependencies are vendored (charts/*.tgz present).
# Falls back to `helm dependency update` when the lock file is missing/stale.
helm_dep_build() {
  local dir="$1"
  if grep -q '^dependencies:' "${dir}/Chart.yaml" 2>/dev/null; then
    (cd "${dir}" && { helm dependency build >/dev/null 2>&1 || helm dependency update >/dev/null; })
  fi
}

# Sanitize an image reference into a filesystem-friendly name
sanitize_ref() {
  echo "$1" | sed -e 's|/|_|g' -e 's|:|_|g' -e 's|@|_|g'
}

# sha256 of a file, portable across macOS (shasum) and Linux (sha256sum)
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
# SSH helpers (LAN side). Honor DRY_RUN.
# ---------------------------------------------------------------------------
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

ssh_run() {
  # ssh_run <remote command...>
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] ssh ${TEKNOIR_HOST} -- $*"
  else
    # shellcheck disable=SC2029  # client-side expansion is intended
    ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" "$@"
  fi
}

ssh_query() {
  # Read-only query over ssh; runs even in dry-run mode (never mutates).
  # shellcheck disable=SC2029  # client-side expansion is intended
  ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" "$@"
}

ssh_sudo_write() {
  # ssh_sudo_write <local-file> <remote-path> [mode]
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] copy ${src} -> ${TEKNOIR_HOST}:${dst} (mode ${mode})"
    return 0
  fi
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
    "sudo mkdir -p '$(dirname "${dst}")' && sudo tee '${dst}' >/dev/null && sudo chmod ${mode} '${dst}'" \
    < "${src}"
}

remote_kubectl() {
  # kubectl on the K3s node (k3s bundles kubectl; kubeconfig requires sudo)
  ssh_run "sudo k3s kubectl $*"
}

remote_kubectl_query() {
  ssh_query "sudo k3s kubectl $*"
}
