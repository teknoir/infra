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
      # imagePullPolicy=IfNotPresent is mandatory for the air gap: the gateway
      # pods run a placeholder container (image: auto) which the API server would
      # otherwise default to imagePullPolicy: Always (auto == :latest). Istio
      # captures that Always into the injected istio-proxy override, so the
      # gateways try to pull docker.io/istio/proxyv2 from Harbor on every start —
      # which is down/unreachable during bootstrap → ImagePullBackOff, even
      # though the image is already imported into containerd. Setting an explicit
      # policy on each gateway (local .imagePullPolicy) plus global (injected
      # sidecars everywhere) keeps the mesh fully offline.
      echo "--set global.domain=${TEKNOIR_DOMAIN}" \
           "--set global.imagePullPolicy=IfNotPresent" \
           "--set istio-ingressgateway.imagePullPolicy=IfNotPresent" \
           "--set istio-ingressgateway-public.imagePullPolicy=IfNotPresent" \
           "--set istio-egressgateway.imagePullPolicy=IfNotPresent" \
           "--set certificate.enabled=false"
      ;;
    harbor)
      # externalURL feeds Harbor core's EXT_ENDPOINT, which builds the registry
      # token realm advertised in /v2/'s Www-Authenticate header. Left empty it
      # emits a schemeless realm (harbor.host/service/token) that helm/oras
      # reject ("unsupported scheme"), so it must carry the https:// scheme.
      echo "--set domain=${TEKNOIR_DOMAIN} --set hostname=harbor.${TEKNOIR_DOMAIN}" \
           "--set harbor.externalURL=${HARBOR_URL}"
      ;;
    argo)
      echo "--set domain=${TEKNOIR_DOMAIN} --set argo-cd.global.domain=argocd.${TEKNOIR_DOMAIN}"
      ;;
    cert-manager)
      # The cert-manager CRDs are bootstrap-owned (rendered into
      # 05-teknoir-certmanager-crds.yaml). The chart's GitOps default is
      # cert-manager.crds.enabled=false, but the bootstrap render path must
      # force them back on so a fresh install gets the CRDs.
      echo "--set domain=${TEKNOIR_DOMAIN} --set global.domain=${TEKNOIR_DOMAIN}" \
           "--set cert-manager.crds.enabled=true"
      ;;
    auth|monitoring|app-of-apps|*-controller)
      echo "--set domain=${TEKNOIR_DOMAIN} --set global.domain=${TEKNOIR_DOMAIN}"
      ;;
    backstage)
      # Backstage templates key the public domain off config.domain (baseUrl,
      # jwks issuer/uri, VirtualService host) rather than domain/global.domain.
      echo "--set config.domain=${TEKNOIR_DOMAIN}"
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
  # ArgoCD needs the Teknoir Root CA in TWO independent trust paths, both injected
  # here at render time (teknoir-root-ca.crt is generated per-deployment and
  # gitignored, so it cannot be hardcoded in values.yaml):
  #   1. repo-server -> Harbor OCI login verifies Harbor's TLS with argocd-tls-certs-cm
  #      (configs.tls.certificates, keyed by the Harbor host). Missing it fails
  #      `helm registry login` with x509 unknown authority, leaving app-of-apps Unknown.
  #   2. argocd-server -> Keycloak OIDC discovery
  #      (https://auth.<domain>/.../.well-known/openid-configuration) verifies with
  #      the oidc.config `rootCA` field. It does NOT consult argocd-tls-certs-cm or
  #      the node OS trust for this call, so the CA is embedded into oidc.config,
  #      whose base lives in charts/argo/files/oidc.config.
  local ca_args=()
  local oidc_tmp=""
  if [[ "${name}" == "argo" ]]; then
    local oidc_base="${REPO_ROOT}/charts/argo/files/oidc.config"
    if [[ -f "${REPO_ROOT}/teknoir-root-ca.crt" ]]; then
      local ca_key="${HARBOR_HOST//./\\.}"
      ca_args=(--set-file "argo-cd.configs.tls.certificates.${ca_key}=${REPO_ROOT}/teknoir-root-ca.crt")
      oidc_tmp="$(mktemp)"
      {
        cat "${oidc_base}"
        echo "rootCA: |"
        sed 's/^/  /' "${REPO_ROOT}/teknoir-root-ca.crt"
      } > "${oidc_tmp}"
      ca_args+=(--set-file "argo-cd.configs.cm.oidc\.config=${oidc_tmp}")
    else
      warn "teknoir-root-ca.crt not found — ArgoCD OIDC will lack rootCA; Keycloak login may fail with x509 unknown authority"
      ca_args=(--set-file "argo-cd.configs.cm.oidc\.config=${oidc_base}")
    fi
  fi
  # shellcheck disable=SC2086
  helm template "${name}" "${dir}" \
    --namespace "$(chart_namespace "${name}")" \
    --include-crds \
    --kube-version "${KUBE_VERSION:-1.33.0}" \
    ${ca_args[@]+"${ca_args[@]}"} \
    ${args}
  local rc=$?
  [[ -n "${oidc_tmp}" ]] && rm -f "${oidc_tmp}"
  return $rc
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

# Optional SSH identity file. Set SSH_KEY (env or --ssh-key in the scripts that
# support it) to authenticate every ssh/rsync invocation with an explicit key,
# e.g. SSH_KEY=.secrets/teknoir.airgapped.id_rsa. Left empty, the default key
# .secrets/teknoir.airgapped.id_rsa is auto-detected (repo checkout or bundle
# run from the bundle root); otherwise ssh falls back to its own key
# resolution / agent. The node only accepts publickey auth, so without a
# usable key every ssh fails with "Permission denied (publickey)".
SSH_KEY="${SSH_KEY:-}"
if [[ -z "${SSH_KEY}" ]]; then
  for _candidate in \
    "${REPO_ROOT}/.secrets/teknoir.airgapped.id_rsa" \
    "${PWD}/.secrets/teknoir.airgapped.id_rsa"; do
    if [[ -f "${_candidate}" ]]; then
      SSH_KEY="${_candidate}"
      break
    fi
  done
  unset _candidate
fi

# Fold $SSH_KEY into SSH_OPTS (idempotent). Called at source time and again by
# scripts that accept --ssh-key after argument parsing.
apply_ssh_key() {
  if [[ -n "${SSH_KEY}" && " ${SSH_OPTS[*]} " != *" -i ${SSH_KEY} "* ]]; then
    [[ -f "${SSH_KEY}" ]] || die "ssh key not found: ${SSH_KEY}"
    SSH_OPTS+=(-i "${SSH_KEY}")
    export SSH_KEY  # propagate to delegated airgap scripts
  fi
}
apply_ssh_key

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
