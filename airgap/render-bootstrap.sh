#!/usr/bin/env bash
# render-bootstrap.sh — render the bootstrap-tier static manifests (connected side):
#   <bundle>/bootstrap/manifests/00-teknoir-istio.yaml   (gitops charts/istio)
#   <bundle>/bootstrap/manifests/10-teknoir-argo.yaml    (infra charts/argo)
#   <bundle>/bootstrap/manifests/20-teknoir-harbor.yaml  (gitops charts/harbor)
#   <bundle>/bootstrap/manifests/app-of-apps.yaml        (copy of teknoir-local-app-of-apps.yaml)
#   <bundle>/bootstrap/k3s/registries.yaml               (K3s registry mirrors -> Harbor)
#   <bundle>/bootstrap/k3s/coredns-custom.yaml           (in-cluster *.teknoir.airgapped resolution)
#   <bundle>/bootstrap/k3s/teknoir-root-ca.crt           (copied from repo root)
#
# The istio/harbor renders are labeled `app.kubernetes.io/instance: <app>` so the
# corresponding ArgoCD Applications adopt them without recreation.
#
# Usage: airgap/render-bootstrap.sh [--dry-run] [--node-ip IP] [--bundle-dir DIR]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --node-ip IP       node IP for coredns-custom.yaml (default: NODE_IP from
                     versions.env [${NODE_IP:-unset}]; if empty, the __NODE_IP__
                     placeholder is left in place and substituted later by
                     bootstrap-airgap.sh)
  --dry-run          print what would be rendered, write nothing
  --bundle-dir DIR   override bundle directory (default: $(bundle_dir))
  -h, --help         show this help
EOF
}

NODE_IP="${NODE_IP:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-ip) NODE_IP="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --bundle-dir) BUNDLE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd helm

BUNDLE="$(bundle_dir)"
MANIFESTS_OUT="${BUNDLE}/bootstrap/manifests"
K3S_OUT="${BUNDLE}/bootstrap/k3s"

# ---------------------------------------------------------------------------
# ArgoCD adoption label injection (python3+PyYAML preferred, yq fallback)
# ---------------------------------------------------------------------------
LABEL_PY='
import sys
import yaml

instance = sys.argv[1]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d is not None]
for doc in docs:
    meta = doc.setdefault("metadata", {})
    labels = meta.get("labels") or {}
    labels["app.kubernetes.io/instance"] = instance
    meta["labels"] = labels
yaml.safe_dump_all(docs, sys.stdout, default_flow_style=False, sort_keys=False)
'

label_instance() {
  # stdin: rendered manifests; $1: instance name; stdout: labeled manifests
  local instance="$1"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "${LABEL_PY}" "${instance}"
  elif command -v yq >/dev/null 2>&1; then
    yq eval ".metadata.labels.\"app.kubernetes.io/instance\" = \"${instance}\"" -
  else
    warn "neither python3+PyYAML nor yq available — skipping adoption labels for '${instance}'"
    cat
  fi
}

namespace_doc() {
  # namespace_doc <name> [key: value label]
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
EOF
  if [[ $# -gt 1 ]]; then
    echo "  labels:"
    echo "    $2"
  fi
  echo "---"
}

render_chart_manifest() {
  # render_chart_manifest <chart-name> <chart-dir> <out-file> [instance-label]
  local name="$1" dir="$2" out="$3" instance="${4:-}"
  [[ -d "${dir}" ]] || die "chart directory not found: ${dir}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] helm template ${name} ${dir} -> ${out}${instance:+ (label app.kubernetes.io/instance=${instance})}"
    return 0
  fi
  log "rendering ${name} -> ${out}"
  helm_dep_build "${dir}"
  if [[ -n "${instance}" ]]; then
    helm_template_chart "${name}" "${dir}" | label_instance "${instance}" >> "${out}"
  else
    helm_template_chart "${name}" "${dir}" >> "${out}"
  fi
}

# ---------------------------------------------------------------------------
# Ordered bootstrap manifests
# ---------------------------------------------------------------------------
run mkdir -p "${MANIFESTS_OUT}" "${K3S_OUT}"

ISTIO_OUT="${MANIFESTS_OUT}/00-teknoir-istio.yaml"
ARGO_OUT="${MANIFESTS_OUT}/10-teknoir-argo.yaml"
HARBOR_OUT="${MANIFESTS_OUT}/20-teknoir-harbor.yaml"

if [[ "${DRY_RUN}" != "1" ]]; then
  # namespaces first (istio-injection on teknoir-system so harbor gets sidecars);
  # deliberately NOT instance-labeled: no ArgoCD app may prune them.
  { namespace_doc "istio-system"
    namespace_doc "teknoir-system" "istio-injection: enabled"; } > "${ISTIO_OUT}"
  : > "${ARGO_OUT}"
  : > "${HARBOR_OUT}"
fi

render_chart_manifest "istio"  "${GITOPS_REPO_DIR}/charts/istio"  "${ISTIO_OUT}"  "istio"
render_chart_manifest "argo"   "${REPO_ROOT}/charts/argo"         "${ARGO_OUT}"
render_chart_manifest "harbor" "${GITOPS_REPO_DIR}/charts/harbor" "${HARBOR_OUT}" "harbor"

# ---------------------------------------------------------------------------
# app-of-apps.yaml
# ---------------------------------------------------------------------------
APP_OF_APPS_SRC="${REPO_ROOT}/teknoir-local-app-of-apps.yaml"
if [[ ! -f "${APP_OF_APPS_SRC}" ]]; then
  warn "teknoir-local-app-of-apps.yaml not found, falling back to teknoir-cloud-app-of-apps.yaml"
  APP_OF_APPS_SRC="${REPO_ROOT}/teknoir-cloud-app-of-apps.yaml"
fi
if [[ -f "${APP_OF_APPS_SRC}" ]]; then
  run cp "${APP_OF_APPS_SRC}" "${MANIFESTS_OUT}/app-of-apps.yaml"
else
  warn "no app-of-apps manifest found in ${REPO_ROOT} — bundle will lack app-of-apps.yaml"
fi

# ---------------------------------------------------------------------------
# K3s side-config: registries.yaml, coredns-custom.yaml, CA
# ---------------------------------------------------------------------------
write_registries_yaml() {
  local out="$1" entry upstream project
  {
    echo "mirrors:"
    for entry in "${MIRRORED_REGISTRIES[@]}"; do
      upstream="${entry%% *}"
      project="${entry##* }"
      cat <<EOF
  ${upstream}:
    endpoint:
      - "${HARBOR_URL}"
    rewrite:
      "^(.*)\$": "${project}/\$1"
EOF
    done
    cat <<EOF
configs:
  "${HARBOR_HOST}":
    tls:
      ca_file: /etc/rancher/k3s/teknoir-root-ca.crt
EOF
  } > "${out}"
}

write_coredns_custom() {
  local out="$1" ip="${NODE_IP:-__NODE_IP__}" host
  {
    cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  teknoir.server: |
    ${TEKNOIR_DOMAIN}:53 {
        errors
        hosts {
EOF
    for host in "${TEKNOIR_HOSTNAMES[@]}"; do
      echo "            ${ip} ${host}"
    done
    cat <<'EOF'
        }
    }
EOF
  } > "${out}"
}

if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] would write ${K3S_OUT}/registries.yaml (mirrors -> ${HARBOR_URL})"
  log "[dry-run] would write ${K3S_OUT}/coredns-custom.yaml (node ip: ${NODE_IP:-__NODE_IP__})"
  log "[dry-run] would copy ${REPO_ROOT}/teknoir-root-ca.crt -> ${K3S_OUT}/"
else
  write_registries_yaml "${K3S_OUT}/registries.yaml"
  write_coredns_custom "${K3S_OUT}/coredns-custom.yaml"
  if [[ -f "${REPO_ROOT}/teknoir-root-ca.crt" ]]; then
    cp "${REPO_ROOT}/teknoir-root-ca.crt" "${K3S_OUT}/teknoir-root-ca.crt"
  else
    warn "teknoir-root-ca.crt not found at repo root — run scripts/gen-local-ca-secret.sh first"
  fi
fi

# ---------------------------------------------------------------------------
# Validation (best effort — client-side, no cluster required)
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" != "1" ]]; then
  if command -v kubectl >/dev/null 2>&1; then
    for f in "${ISTIO_OUT}" "${ARGO_OUT}" "${HARBOR_OUT}" "${K3S_OUT}/coredns-custom.yaml"; do
      [[ -f "${f}" ]] || continue
      if kubectl apply --dry-run=client --validate=false -f "${f}" >/dev/null 2>&1; then
        log "kubectl dry-run OK: $(basename "${f}")"
      else
        warn "kubectl dry-run failed for $(basename "${f}") (missing CRDs/cluster is expected offline)"
      fi
    done
  else
    warn "kubectl not available — skipping client-side validation"
  fi
  log "bootstrap manifests rendered into ${MANIFESTS_OUT}"
fi
