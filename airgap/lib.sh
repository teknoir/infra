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

# Chart pins, one "name version" each:
#   app-of-apps    APP_OF_APPS_VERSION (versions.env)
#   GitOps charts  every chart the pinned app-of-apps deploys, at the version
#                  it deploys — GitOps owns those versions, infra does not
#                  repeat them. Built from the gitops working tree, except
#                  RELEASED_CHARTS (already in Harbor, never rebuilt).
#   INFRA_CHARTS   built from this repo's charts/ (versions.env)
# load_chart_pins resolves them once per run. collect-charts.sh renders the
# working tree's app-of-apps and records the result in <bundle>/charts/pins.txt,
# which later steps and the air-gapped side (push-to-harbor.sh) read: no helm
# render, no PyYAML there.
CHART_PINS=""
APP_OF_APPS_APPS=""

pins_file() {
  echo "$(bundle_dir)/charts/pins.txt"
}

render_app_of_apps() {
  # render_app_of_apps <chart-source> — print "<application> <chart|-> <targetRevision|-> <repoURL|->"
  # for every Application the app-of-apps chart renders (python3 + PyYAML)
  helm_template_chart app-of-apps "$1" | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Application":
        continue
    spec = d.get("spec") or {}
    for s in spec.get("sources") or [spec.get("source") or {}]:
        print(d["metadata"]["name"], s.get("chart") or "-", s.get("targetRevision") or "-", s.get("repoURL") or "-")
'
}

PINS_FROM_WORKTREE="${PINS_FROM_WORKTREE:-0}"

load_chart_pins() {
  # load_chart_pins — resolve the chart pins into CHART_PINS, once. Scripts
  # call it after parsing their arguments (BUNDLE_DIR selects the bundle) and
  # before any pin lookup, so a failure stops the script; inside $(...) or
  # <(...) it could not. Source of the pins:
  #   <bundle>/charts/pins.txt if it pins APP_OF_APPS_VERSION, else the
  #   rendered app-of-apps from chart_source (bundle .tgz first);
  #   with PINS_FROM_WORKTREE=1 always the gitops working tree's app-of-apps,
  #   which must carry APP_OF_APPS_VERSION (collect-charts.sh builds from the
  #   tree, so a bundle left from an earlier build must not decide).
  local src dup entry
  [[ -n "${CHART_PINS}" ]] && return 0
  [[ -n "${APP_OF_APPS_VERSION:-}" ]] || die "APP_OF_APPS_VERSION is not set (versions.env)"
  if [[ "${PINS_FROM_WORKTREE}" != "1" && -f "$(pins_file)" ]] \
     && [[ "$(head -1 "$(pins_file)")" == "app-of-apps ${APP_OF_APPS_VERSION}" ]]; then
    CHART_PINS="$(cat "$(pins_file)")"
    return 0
  fi
  if [[ "${PINS_FROM_WORKTREE}" == "1" ]]; then
    src="${GITOPS_REPO_DIR}/charts/app-of-apps"
    [[ "$(chart_dir_version "${src}")" == "${APP_OF_APPS_VERSION}" ]] \
      || die "${src}/Chart.yaml has version $(chart_dir_version "${src}"), versions.env pins app-of-apps ${APP_OF_APPS_VERSION}"
  else
    src="$(chart_source app-of-apps "${APP_OF_APPS_VERSION}")" \
      || die "no pins for app-of-apps ${APP_OF_APPS_VERSION}: no $(pins_file) (written by collect-charts.sh / make-bundle.sh), and neither its .tgz nor ${GITOPS_REPO_DIR}/charts/app-of-apps at that version"
  fi
  APP_OF_APPS_APPS="$(render_app_of_apps "${src}")" \
    || die "cannot render app-of-apps ${APP_OF_APPS_VERSION} from ${src} (needs helm and python3 with PyYAML)"
  dup="$(awk '$2 != "-" {print $2, $3}' <<<"${APP_OF_APPS_APPS}" | sort -u | awk '{n[$1]++} END {for (c in n) if (n[c] > 1) print c}')"
  [[ -z "${dup}" ]] || die "app-of-apps ${APP_OF_APPS_VERSION} deploys more than one version of: ${dup}"
  CHART_PINS="$(
    echo "app-of-apps ${APP_OF_APPS_VERSION}"
    awk '$2 != "-" && !seen[$2]++ {print $2, $3}' <<<"${APP_OF_APPS_APPS}"
    for entry in "${INFRA_CHARTS[@]}"; do echo "${entry}"; done
  )"
}

is_released_chart() {
  local name
  for name in ${RELEASED_CHARTS[@]+"${RELEASED_CHARTS[@]}"}; do
    [[ "${name}" == "$1" ]] && return 0
  done
  return 1
}

infra_chart_version() {
  # infra_chart_version <name> — the INFRA_CHARTS version of <name>, empty if none
  local entry
  for entry in "${INFRA_CHARTS[@]}"; do
    [[ "${entry%% *}" == "$1" ]] && { echo "${entry##* }"; return 0; }
  done
  return 0
}

pinned_charts() {
  # print "name version" for every pinned chart (see load_chart_pins)
  load_chart_pins
  printf '%s\n' "${CHART_PINS}"
}

built_charts() {
  # print "name version dir" for every chart collect-charts.sh packages
  local name version
  load_chart_pins
  while read -r name version; do
    if [[ -n "$(infra_chart_version "${name}")" ]]; then
      echo "${name} ${version} ${REPO_ROOT}/charts/${name}"
    elif ! is_released_chart "${name}"; then
      echo "${name} ${version} ${GITOPS_REPO_DIR}/charts/${name}"
    fi
  done <<<"${CHART_PINS}"
}

released_charts() {
  # print "name version" for every released (not rebuilt) chart
  local name version
  load_chart_pins
  while read -r name version; do
    if is_released_chart "${name}"; then echo "${name} ${version}"; fi
  done <<<"${CHART_PINS}"
}

pinned_version() {
  # pinned_version <name> — the pinned version of <name>, empty if not pinned.
  # app-of-apps and the infra charts come straight from versions.env.
  # (no early exit: under pipefail the writer's SIGPIPE would fail the caller)
  if [[ "$1" == "app-of-apps" ]]; then
    echo "${APP_OF_APPS_VERSION}"
  elif [[ -n "$(infra_chart_version "$1")" ]]; then
    infra_chart_version "$1"
  else
    pinned_charts | awk -v n="$1" '$1 == n && !f {print $2; f = 1}'
  fi
}

chart_dir_version() {
  # chart_dir_version <dir> — the version in <dir>/Chart.yaml, empty if none
  awk '/^version:/{print $2; exit}' "$1/Chart.yaml" 2>/dev/null || true
}

chart_source() {
  # chart_source <name> <version> — what to render for a pin: the bundle's
  # <name>-<version>.tgz (exactly what is pushed to Harbor), else the working
  # tree dir whose Chart.yaml carries <version>. Non-zero when neither exists
  # (a released chart whose .tgz is not in the bundle).
  local name="$1" version="$2" dir
  if [[ -f "$(bundle_dir)/charts/${name}-${version}.tgz" ]]; then
    echo "$(bundle_dir)/charts/${name}-${version}.tgz"
    return 0
  fi
  for dir in "${GITOPS_REPO_DIR}/charts/${name}" "${REPO_ROOT}/charts/${name}"; do
    if [[ "$(chart_dir_version "${dir}")" == "${version}" ]]; then
      echo "${dir}"
      return 0
    fi
  done
  return 1
}

require_gitops_branch() {
  # Refuse to build from a GitOps checkout on another branch (e.g. staging).
  local branch
  [[ "${GITOPS_ALLOW_ANY_BRANCH:-0}" == "1" ]] && return 0
  branch="$(git -C "${GITOPS_REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    || die "${GITOPS_REPO_DIR} is not a git checkout (set GITOPS_REPO_DIR)"
  [[ "${branch}" == "${GITOPS_BRANCH}" ]] \
    || die "${GITOPS_REPO_DIR} is on branch '${branch}', not '${GITOPS_BRANCH}' — set GITOPS_REPO_DIR to a ${GITOPS_BRANCH} checkout (or GITOPS_ALLOW_ANY_BRANCH=1)"
}

check_app_of_apps_pins() {
  # check_app_of_apps_pins — fail unless the root manifest
  # (teknoir-local-app-of-apps.yaml) pins APP_OF_APPS_VERSION, every chart the
  # pinned app-of-apps deploys comes from Harbor's chart project, every
  # RELEASED_CHARTS entry is one of them, and the pins in use (e.g. a bundle's
  # pins.txt) are exactly what that app-of-apps deploys.
  local version="${APP_OF_APPS_VERSION}" src root_rev app chart rev repo name rendered bad=0
  load_chart_pins
  root_rev="$(awk '/^[[:space:]]*targetRevision:/{print $2; exit}' "${REPO_ROOT}/teknoir-local-app-of-apps.yaml" 2>/dev/null || true)"
  if [[ "${root_rev}" != "${version}" ]]; then
    warn "teknoir-local-app-of-apps.yaml pins app-of-apps ${root_rev:-<none>}, versions.env ${version}"
    bad=1
  fi
  if [[ -z "${APP_OF_APPS_APPS}" ]]; then
    # pins came from pins.txt: render what will be shipped and compare
    src="$(chart_source app-of-apps "${version}")" || die "no source for app-of-apps ${version}"
    APP_OF_APPS_APPS="$(render_app_of_apps "${src}")" || die "cannot render app-of-apps ${version}"
    rendered="$(echo "app-of-apps ${version}"
                awk '$2 != "-" && !seen[$2]++ {print $2, $3}' <<<"${APP_OF_APPS_APPS}"
                for name in "${INFRA_CHARTS[@]}"; do echo "${name}"; done)"
    if [[ "${rendered}" != "${CHART_PINS}" ]]; then
      warn "$(pins_file) differs from what app-of-apps ${version} deploys (re-run collect-charts.sh)"
      bad=1
    fi
  fi
  while read -r app chart rev repo; do
    [[ -n "${app}" ]] || continue
    if [[ "${chart}" == "-" ]]; then
      warn "app-of-apps ${version}: Application ${app} has no chart source (not checked)"
      continue
    fi
    if [[ "${repo#oci://}" != "${HARBOR_HOST}/${HARBOR_CHART_PROJECT}" ]]; then
      warn "app-of-apps ${version}: Application ${app} pulls ${chart} ${rev} from ${repo}, not ${HARBOR_HOST}/${HARBOR_CHART_PROJECT}"
      bad=1
    fi
  done <<<"${APP_OF_APPS_APPS}"
  for name in ${RELEASED_CHARTS[@]+"${RELEASED_CHARTS[@]}"}; do
    if ! awk -v c="${name}" '$2 == c {f=1} END {exit !f}' <<<"${APP_OF_APPS_APPS}"; then
      warn "RELEASED_CHARTS lists ${name}, which app-of-apps ${version} does not deploy"
      bad=1
    fi
  done
  (( bad == 0 )) || die "the chart pins do not match app-of-apps ${version} (see above)"
  log "app-of-apps ${version} deploys $(grep -c . <<<"${APP_OF_APPS_APPS}") Applications: $(awk '$2 != "-" {print $2 "@" $3}' <<<"${APP_OF_APPS_APPS}" | sort -u | tr '\n' ' ')"
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

# Ensure a chart dir's dependencies are vendored (charts/*.tgz present).
# Falls back to `helm dependency update` when the lock file is missing/stale.
helm_dep_build() {
  local dir="$1"
  [[ -d "${dir}" ]] || return 0   # packaged .tgz: dependencies are inside
  grep -q '^dependencies:' "${dir}/Chart.yaml" 2>/dev/null || return 0
  # Already vendored at the declared versions: nothing to fetch (works offline).
  if helm dependency list "${dir}" 2>/dev/null \
       | awk 'NR > 1 && NF {n++; if ($NF != "ok") bad = 1} END {exit (bad || !n)}'; then
    return 0
  fi
  (cd "${dir}" && { helm dependency build >/dev/null 2>&1 || helm dependency update >/dev/null; })
}

# ---------------------------------------------------------------------------
# Image references (collect-images.sh, verify-offline.sh)
# ---------------------------------------------------------------------------
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
  # read rendered manifests on stdin, print normalized image refs from
  #   image: REF          containers / initContainers
  #   - --<flag>=REF      container args whose flag names an image, e.g. the
  #                       prometheus-operator's --prometheus-config-reloader=
  #                       and --thanos-default-base-image= (the operator
  #                       starts those images itself; they are in no image: field)
  sed -n -E \
    -e 's/^[[:space:]]*-?[[:space:]]*"?image"?:[[:space:]]*//p' \
    -e 's/^[[:space:]]*-[[:space:]]*"?--[A-Za-z0-9-]*(image|reloader)[A-Za-z0-9-]*=([^"[:space:]]+)"?[[:space:]]*$/\2/p' \
    | tr -d '"'"'" \
    | while read -r ref; do normalize_image "${ref}"; done
}

extra_images() {
  # images-extra.txt entries (comments / blank lines stripped), normalized
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${AIRGAP_DIR}/images-extra.txt" \
    | while read -r ref; do normalize_image "${ref}"; done
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
  # k3s_owners <manifest> — print "<kind>/<name> <owning-addon>" for every
  # object in <manifest> that exists in the cluster. <manifest> is a local
  # file, or node:<path> for a file on the node, which is read there (a
  # secret's content never leaves the node). Objects that are gone (e.g. a
  # finished Job removed by its TTL) are skipped: removing an Addon can not
  # garbage-collect what does not exist. Read from stdin (`-f -`), kubectl
  # always yields a List, also for a single object (`-f <file>` does not).
  local jsonpath
  jsonpath="'{range .items[*]}{.kind}/{.metadata.name} {.metadata.annotations.objectset\\.rio\\.cattle\\.io/owner-name}{\"\\n\"}{end}'"
  # shellcheck disable=SC2029  # client-side expansion is intended
  if [[ "$1" == node:* ]]; then
    ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
      "sudo cat '${1#node:}' | sudo k3s kubectl get --ignore-not-found -f - -o jsonpath=${jsonpath}"
  else
    ssh "${SSH_OPTS[@]}" "${TEKNOIR_HOST}" \
      "sudo k3s kubectl get --ignore-not-found -f - -o jsonpath=${jsonpath}" < "$1"
  fi
}

k3s_retire_legacy() {
  # k3s_retire_legacy <legacy-basename> <canonical-basename> [<local-manifest>]
  # Moves a legacy duplicate out of the manifests dir, but only after every
  # object of the canonical manifest is owned by the canonical Addon, so
  # removing the legacy Addon can never garbage-collect live objects. The
  # objects are read from <local-manifest> (what k3s_deploy just wrote), else
  # from the canonical file already on the node. Idempotent.
  local legacy="$1" canonical="$2" src="${3:-node:${K3S_MANIFESTS_DIR}/$2}" addon owners foreign sum
  addon="${canonical%.yaml}"
  ssh_query "sudo test -e '${K3S_MANIFESTS_DIR}/${legacy}'" 2>/dev/null || return 0
  owners="$(k3s_owners "${src}")" || die "cannot read owners of the objects in ${src}; keeping ${legacy}"
  [[ -n "${owners}" ]] || die "no objects from ${src} found in the cluster; keeping ${legacy}"
  foreign="$(awk -v a="${addon}" '$2 != a' <<<"${owners}")"
  if [[ -n "${foreign}" ]]; then
    # Owned by the legacy Addon (it was applied last): clear the canonical
    # Addon's checksum so K3s re-applies the canonical file and takes ownership.
    log "re-applying ${canonical} to take over $(wc -l <<<"${foreign}" | tr -d ' ') object(s) owned by: $(awk '{print ($2 == "" ? "<none>" : $2)}' <<<"${foreign}" | sort -u | tr '\n' ' ')"
    if [[ "${src}" == node:* ]]; then
      sum="$(remote_sha256 "${src#node:}")"
      [[ -n "${sum}" ]] || die "cannot checksum ${src}; keeping ${legacy}"
    else
      sum="$(sha256_file "${src}")"
    fi
    remote_kubectl "-n kube-system patch addons.k3s.cattle.io ${addon} --type merge -p '{\"spec\":{\"checksum\":\"\"}}'" >/dev/null
    k3s_wait_applied "${addon}" "${sum}"
    owners="$(k3s_owners "${src}")" || die "cannot read owners of the objects in ${src}; keeping ${legacy}"
    foreign="$(awk -v a="${addon}" '$2 != a' <<<"${owners}")"
    [[ -z "${foreign}" ]] || die "objects still not owned by ${addon}, keeping ${legacy}: ${foreign}"
  fi
  log "retiring legacy manifest ${legacy} (superseded by ${canonical})"
  ssh_run "sudo install -d -m 700 '${K3S_RETIRED_DIR}' && sudo mv '${K3S_MANIFESTS_DIR}/${legacy}' '${K3S_RETIRED_DIR}/${legacy}.$(date +%Y%m%d%H%M%S)'"
}

# First istio chart version that renders no CRDs (0.0.1 renders all 14).
ISTIO_CRD_FREE_SINCE="0.0.2"

version_ge() {
  # version_ge <a> <b> — true when the dotted numeric version <a> >= <b>;
  # false when either is not numeric (e.g. a git branch as targetRevision)
  local -a a b
  local i x y
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ && "$2" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for (( i = 0; i < ${#a[@]} || i < ${#b[@]}; i++ )); do
    x=$(( 10#${a[i]:-0} )); y=$(( 10#${b[i]:-0} ))
    (( x > y )) && return 0
    (( x < y )) && return 1
  done
  return 0
}

argocd_crd_gate() {
  # argocd_crd_gate — run before deploying teknoir-argo.yaml. That ArgoCD
  # manages CRDs, so it must never take over, and later prune, the
  # bootstrap-owned istio / cert-manager CRDs (deleting a CRD deletes every
  # VirtualService, Gateway, AuthorizationPolicy, ... of that kind):
  #   1. only during the CRD hand-over, i.e. while the live argocd-cm still
  #      excludes CRDs (an ArgoCD from older tooling): the ArgoCD Application
  #      istio, if it exists, must target and have last synced a CRD-free
  #      istio (>= ISTIO_CRD_FREE_SINCE; 0.0.1 renders all 14 CRDs, which
  #      ArgoCD would adopt once it stops excluding them) — roll out the
  #      app-of-apps first (update-airgap.sh). Before ArgoCD exists, and after
  #      the hand-over, ArgoCD cannot hold an older istio sync with CRDs, so
  #      the check is skipped (it would otherwise tie every later istio bump
  #      to the update order);
  #   2. always: every live istio / cert-manager CRD carries
  #      argocd.argoproj.io/sync-options: Prune=false,Delete=false (the K3s
  #      CRD files from render-bootstrap.sh) — so a wrong order stays harmless.
  # Sets ARGOCD_CRD_HANDOVER=1 when this deploy ends the CRD exclusion, for
  # argocd_crd_handover_resync. Read-only. Dry-run reports instead of failing.
  # SKIP_CRD_GATE=1 skips the checks, not that detection.
  # Usage: argocd_crd_gate crds-live|crds-just-deployed — the latter when the
  # caller deployed the CRD files right before (in dry-run that deploy did not
  # happen, so check 2 is skipped).
  local excl state target synced status unprotected problems=()
  ARGOCD_CRD_HANDOVER=0
  if ! excl="$(remote_kubectl_query "-n teknoir-system get configmap argocd-cm --ignore-not-found -o jsonpath='{.data.resource\\.exclusions}'")"; then
    problems+=("cannot read the live argocd-cm")
  elif grep -q 'CustomResourceDefinition' <<<"${excl}"; then
    ARGOCD_CRD_HANDOVER=1
  fi
  if [[ "${SKIP_CRD_GATE:-0}" == "1" ]]; then
    warn "CRD gate skipped (--skip-crd-gate)"
    return 0
  fi
  if [[ "${ARGOCD_CRD_HANDOVER}" == "1" ]]; then
    # Use the live comparison (.status.sync), not .status.history: going from
    # istio 0.0.1 to 0.0.2 only drops CRDs that are still excluded, so ArgoCD
    # reports Synced at 0.0.2 without running a sync and writes no history.
    if ! state="$(remote_kubectl_query "-n teknoir-system get applications.argoproj.io istio --ignore-not-found -o jsonpath='{.spec.source.targetRevision} {.status.sync.revision} {.status.sync.status}'")"; then
      problems+=("cannot read the ArgoCD Application istio")
    else
      read -r target synced status <<<"${state}" || true
      if [[ -n "${target:-}" ]] && ! { version_ge "${target}" "${ISTIO_CRD_FREE_SINCE}" \
                                        && version_ge "${synced:-}" "${ISTIO_CRD_FREE_SINCE}" \
                                        && [[ "${status:-}" == "Synced" ]]; }; then
        problems+=("CRD hand-over: the istio Application targets istio ${target} and is ${status:-unknown} at ${synced:-nothing}, but must be Synced at istio >= ${ISTIO_CRD_FREE_SINCE} (no CRDs) first: run airgap/update-airgap.sh and wait until istio is Synced")
      fi
    fi
  fi
  if [[ "${1:-}" == "crds-just-deployed" && "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] CRD gate: the CRD files deployed above add Prune=false,Delete=false"
  else
    unprotected="$(remote_kubectl_query "get crd -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{.metadata.annotations.argocd\\.argoproj\\.io/sync-options}{\"\\n\"}{end}'" \
      | awk '$1 ~ /(istio\.io|cert-manager\.io)$/ && $2 != "Prune=false,Delete=false" {print $1}')" \
      || problems+=("cannot read the CRDs")
    if [[ -n "${unprotected}" ]]; then
      problems+=("CRDs without Prune=false,Delete=false: $(tr '\n' ' ' <<<"${unprotected}")— deploy the CRD files first (airgap/bootstrap-airgap.sh --update)")
    fi
  fi
  if (( ${#problems[@]} == 0 )); then
    if [[ "${ARGOCD_CRD_HANDOVER}" == "1" ]]; then
      log "CRD gate passed (CRD hand-over: istio ${synced:-not deployed}; bootstrap CRDs prune-protected)"
    else
      log "CRD gate passed (no CRD hand-over pending; bootstrap CRDs prune-protected)"
    fi
    return 0
  fi
  local p
  for p in "${problems[@]}"; do
    if [[ "${DRY_RUN}" == "1" ]]; then warn "[dry-run] CRD gate would refuse: ${p}"; else warn "CRD gate: ${p}"; fi
  done
  [[ "${DRY_RUN}" == "1" ]] || die "refusing to deploy ArgoCD without the CRD exclusion (override: --skip-crd-gate)"
}

argocd_failed_autosyncs() {
  # argocd_failed_autosyncs — print "<application> <sync-operation-patch>" for
  # every Application with automated sync whose last operation failed on its
  # current targetRevision (and none is running). The patch re-runs that sync
  # with the Application's own prune / syncOptions. Read-only.
  remote_kubectl_query "-n teknoir-system get applications.argoproj.io -o json" | python3 -c '
import json, sys
for a in json.load(sys.stdin).get("items") or []:
    spec = a.get("spec") or {}
    policy = spec.get("syncPolicy") or {}
    auto, src = policy.get("automated"), spec.get("source")
    if auto is None or auto.get("enabled") is False or not src or spec.get("sources") or a.get("operation"):
        continue
    op = (a.get("status") or {}).get("operationState") or {}
    rev = src.get("targetRevision") or ""
    if op.get("phase") not in ("Failed", "Error") or ((op.get("operation") or {}).get("sync") or {}).get("revision") != rev:
        continue
    print(a["metadata"]["name"], json.dumps({"operation": {
        "initiatedBy": {"username": "airgap-crd-handover"},
        "sync": {"revision": rev, "prune": bool(auto.get("prune")), "syncOptions": policy.get("syncOptions") or []},
        "retry": {"limit": 5, "backoff": {"duration": "30s", "factor": 2, "maxDuration": "5m"}}}}, separators=(",", ":")))
'
}

argocd_crd_handover_resync() {
  # argocd_crd_handover_resync — run once K3s has applied teknoir-argo.yaml
  # (k3s_deploy). If that deploy ended the CRD exclusion
  # (ARGOCD_CRD_HANDOVER=1, from argocd_crd_gate), re-run the automated syncs
  # the exclusion made fail: a chart that ships CRDs together with resources
  # of those kinds (monitoring, user-controller) cannot sync while CRDs are
  # excluded ("failed to discover server resources"), and ArgoCD never retries
  # a failed automated sync of the same revision by itself. Each one is
  # re-run once (argocd_failed_autosyncs). Outside the hand-over a no-op, so
  # re-running is safe.
  local excl sts candidates name patch
  [[ "${ARGOCD_CRD_HANDOVER:-0}" == "1" ]] || return 0
  if [[ "${DRY_RUN}" == "1" ]]; then
    candidates="$(argocd_failed_autosyncs)" || candidates=""
    log "[dry-run] CRD hand-over: once the application controller runs without the CRD exclusion, would re-sync: $(awk '{print $1}' <<<"${candidates}" | tr '\n' ' ')"
    return 0
  fi
  excl="$(remote_kubectl_query "-n teknoir-system get configmap argocd-cm -o jsonpath='{.data.resource\\.exclusions}'")" \
    || die "cannot read the live argocd-cm"
  if grep -q 'CustomResourceDefinition' <<<"${excl}"; then
    warn "CRD hand-over: argocd-cm still excludes CRDs after the deploy; nothing re-synced"
    return 0
  fi
  # argocd-cm feeds a checksum annotation, so the controller restarts; an
  # operation the old pod picked up would fail on the old exclusion again.
  sts="$(remote_kubectl_query "-n teknoir-system get statefulset -l app.kubernetes.io/name=argocd-application-controller -o name")"
  [[ -n "${sts}" ]] || die "ArgoCD application controller StatefulSet not found"
  remote_kubectl "-n teknoir-system rollout status ${sts} --timeout=300s" >/dev/null \
    || die "the ArgoCD application controller did not roll out with the new argocd-cm"
  candidates="$(argocd_failed_autosyncs)" \
    || die "cannot list the ArgoCD Applications; re-sync the failed ones by hand (docs/AIRGAP-UPDATE.md §2.4)"
  if [[ -z "${candidates}" ]]; then
    log "CRD hand-over: no failed automated sync to re-run"
    return 0
  fi
  while read -r name patch; do
    [[ "${patch}" != *"'"* ]] || die "unexpected quote in the sync operation for ${name}"
    log "CRD hand-over: re-syncing ${name} (its automated sync failed while CRDs were excluded)"
    remote_kubectl "-n teknoir-system patch applications.argoproj.io ${name} --type merge -p '${patch}'" >/dev/null
  done <<<"${candidates}"
  log "CRD hand-over: follow with: sudo k3s kubectl -n teknoir-system get applications"
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
