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
           "--set certificate.enabled=false" \
           "--set-json istio-base.base.excludedCRDs=[]"
      # The istio CRDs are bootstrap-owned (00-teknoir-istio-crds.yaml). The
      # chart's GitOps default lists every CRD in istio-base.base.excludedCRDs
      # so the ArgoCD Application renders none (helm.skipCrds cannot drop them:
      # the base subchart renders CRDs from templates); the bootstrap render
      # clears that list to get them back.
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
  # read -a splits without pathname expansion, so values such as [] stay literal.
  local -a extra_args=()
  read -r -a extra_args <<<"${args}"
  helm template "${name}" "${dir}" \
    --namespace "$(chart_namespace "${name}")" \
    --include-crds \
    --kube-version "${KUBE_VERSION:-1.33.0}" \
    ${ca_args[@]+"${ca_args[@]}"} \
    ${extra_args[@]+"${extra_args[@]}"}
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
  # Writes a hidden temp file next to <remote-path> (K3s ignores dot-files and
  # non-.yaml/.tar names) and renames it into place, so the K3s deploy
  # controller never applies a half-written manifest (which would prune the
  # objects missing from it) and a secret never exists with a wider mode.
  local src="$1" dst="$2" mode="${3:-0644}" dir tmp
  dir="$(dirname "${dst}")"
  tmp="${dir}/.$(basename "${dst}").tmp"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] copy ${src} -> ${TEKNOIR_HOST}:${dst} (mode ${mode})"
    return 0
  fi
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
    "sudo mkdir -p '${dir}' && sudo sh -c 'umask 077 && cat > \"${tmp}\" && chmod ${mode} \"${tmp}\" && mv -f \"${tmp}\" \"${dst}\"'" \
    < "${src}"
}

remote_sha256() {
  # remote_sha256 <remote-path> — sha256 of a file on the node, empty when it
  # is absent or the node is unreachable. Read-only, so it runs in dry-run too.
  ssh_query "sudo sha256sum '$1' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true
}

ssh_sync_file() {
  # ssh_sync_file <local-file> <remote-path> [mode] — copy only when the node's
  # copy differs. Returns 0 when the node (would have) changed, 1 when not.
  local src="$1" dst="$2" mode="${3:-0644}"
  if [[ "$(remote_sha256 "${dst}")" == "$(sha256_file "${src}")" ]]; then
    return 1
  fi
  # Called in `if` context, where set -e is off: fail loudly, not "unchanged".
  ssh_sudo_write "${src}" "${dst}" "${mode}" || die "copying ${src} to ${TEKNOIR_HOST}:${dst} failed"
}

remote_kubectl() {
  # kubectl on the K3s node (k3s bundles kubectl; kubeconfig requires sudo)
  ssh_run "sudo k3s kubectl $*"
}

remote_kubectl_query() {
  ssh_query "sudo k3s kubectl $*"
}

# ---------------------------------------------------------------------------
# K3s auto-deploy manifests: exactly one owning file per object
# ---------------------------------------------------------------------------
# K3s turns every file in the manifests dir into an Addon that owns the objects
# it applies. Older tooling wrote the same objects under two names
# (bootstrap-airgap.sh: manifest-*.yaml, app-of-apps.yaml, 10-teknoir-argo.yaml;
# scripts/deploy-*.sh: teknoir-*.yaml), so a stale copy could re-apply over a
# fresh one (that is how a rotated Harbor robot token got reverted). Every
# script now deploys through k3s_deploy, which writes the canonical name only
# and retires the legacy duplicates once the canonical Addon owns the objects.
K3S_MANIFESTS_DIR="${K3S_DATA_DIR}/server/manifests"
K3S_RETIRED_DIR="${K3S_DATA_DIR}/server/manifests-retired"

k3s_canonical_name() {
  # k3s_canonical_name <file> — canonical manifests-dir basename for <file>
  local b
  b="$(basename "$1")"
  case "${b}" in
    app-of-apps.yaml) echo "teknoir-app-of-apps.yaml" ;;
    10-teknoir-argo.yaml) echo "teknoir-argo.yaml" ;;
    manifest-teknoir-*) echo "${b#manifest-}" ;;
    manifest-*) echo "teknoir-${b#manifest-}" ;;
    *) echo "${b}" ;;
  esac
}

k3s_legacy_names() {
  # k3s_legacy_names <canonical-basename> — older names of the same objects
  local c="$1"
  case "${c}" in
    teknoir-app-of-apps.yaml) echo "app-of-apps.yaml" ;;
    teknoir-argo.yaml) echo "10-teknoir-argo.yaml" ;;
    teknoir-*) echo "manifest-${c#teknoir-}"; echo "manifest-${c}" ;;
  esac
}

k3s_wait_applied() {
  # k3s_wait_applied <addon> <sha256> [timeout-seconds] — wait until the K3s
  # deploy controller has applied the file content with checksum <sha256>.
  local addon="$1" sum="$2" timeout="${3:-300}" deadline current
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    current="$(remote_kubectl_query "-n kube-system get addons.k3s.cattle.io ${addon} -o jsonpath='{.spec.checksum}'" 2>/dev/null || true)"
    [[ "${current}" == "${sum}" ]] && return 0
    (( $(date +%s) > deadline )) && die "K3s did not apply ${addon} within ${timeout}s (see: kubectl -n kube-system describe addon ${addon})"
    sleep 5
  done
}

k3s_owners() {
  # k3s_owners <local-manifest> — print "<kind>/<name> <owning-addon>" for every
  # object in <local-manifest> that exists in the cluster. Objects that are gone
  # (e.g. a finished Job removed by its TTL) are skipped: removing an Addon can
  # not garbage-collect what does not exist. `-f -` always yields a List.
  ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
    "sudo k3s kubectl get --ignore-not-found -f - -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.annotations.objectset\\.rio\\.cattle\\.io/owner-name}{\"\\n\"}{end}'" \
    < "$1"
}

k3s_retire_legacy() {
  # k3s_retire_legacy <legacy-basename> <canonical-basename> <local-manifest>
  # Moves a legacy duplicate out of the manifests dir, but only after every
  # object in <local-manifest> is owned by the canonical Addon, so removing the
  # legacy Addon can never garbage-collect live objects. Idempotent.
  local legacy="$1" canonical="$2" src="$3" addon owners foreign
  addon="${canonical%.yaml}"
  ssh_query "sudo test -e '${K3S_MANIFESTS_DIR}/${legacy}'" 2>/dev/null || return 0
  owners="$(k3s_owners "${src}")" || die "cannot read owners of the objects in ${src}; keeping ${legacy}"
  [[ -n "${owners}" ]] || die "no objects from ${src} found in the cluster; keeping ${legacy}"
  foreign="$(awk -v a="${addon}" '$2 != a' <<<"${owners}")"
  if [[ -n "${foreign}" ]]; then
    # Owned by the legacy Addon (it was applied last): clear the canonical
    # Addon's checksum so K3s re-applies the canonical file and takes ownership.
    log "re-applying ${canonical} to take over $(wc -l <<<"${foreign}" | tr -d ' ') object(s) owned by: $(awk '{print ($2 == "" ? "<none>" : $2)}' <<<"${foreign}" | sort -u | tr '\n' ' ')"
    remote_kubectl "-n kube-system patch addons.k3s.cattle.io ${addon} --type merge -p '{\"spec\":{\"checksum\":\"\"}}'" >/dev/null
    k3s_wait_applied "${addon}" "$(sha256_file "${src}")"
    owners="$(k3s_owners "${src}")" || die "cannot read owners of the objects in ${src}; keeping ${legacy}"
    foreign="$(awk -v a="${addon}" '$2 != a' <<<"${owners}")"
    [[ -z "${foreign}" ]] || die "objects still not owned by ${addon}, keeping ${legacy}: ${foreign}"
  fi
  log "retiring legacy manifest ${legacy} (superseded by ${canonical})"
  ssh_run "sudo install -d -m 700 '${K3S_RETIRED_DIR}' && sudo mv '${K3S_MANIFESTS_DIR}/${legacy}' '${K3S_RETIRED_DIR}/${legacy}.$(date +%Y%m%d%H%M%S)'"
}

k3s_deploy() {
  # k3s_deploy <local-manifest> [mode] — install <local-manifest> into the K3s
  # manifests dir under its canonical name, wait until K3s applied it, then
  # retire legacy duplicates. Re-running with unchanged content is a no-op
  # (K3s skips a file whose checksum it already applied; the rewrite also
  # re-asserts the file mode).
  local src="$1" mode="${2:-0644}" name legacy rc
  [[ -f "${src}" ]] || die "missing ${src}"
  name="$(k3s_canonical_name "${src}")"
  ssh_sudo_write "${src}" "${K3S_MANIFESTS_DIR}/${name}" "${mode}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] wait until K3s applied Addon ${name%.yaml}"
    for legacy in $(k3s_legacy_names "${name}"); do
      rc=0
      ssh_query "sudo test -e '${K3S_MANIFESTS_DIR}/${legacy}'" 2>/dev/null || rc=$?
      case "${rc}" in
        0) log "[dry-run] would retire legacy manifest ${legacy} once ${name%.yaml} owns its objects" ;;
        1) ;;
        *) log "[dry-run] node unreachable: would retire legacy manifest ${legacy} if present" ;;
      esac
    done
    return 0
  fi
  k3s_wait_applied "${name%.yaml}" "$(sha256_file "${src}")"
  for legacy in $(k3s_legacy_names "${name}"); do
    k3s_retire_legacy "${legacy}" "${name}" "${src}"
  done
}
