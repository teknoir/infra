#!/usr/bin/env bash
# render-bootstrap.sh — render the bootstrap-tier static manifests (connected side):
#   <bundle>/bootstrap/manifests/00-teknoir-namespaces.yaml       (istio-system, teknoir-system, cert-manager, teknoir-auth)
#   <bundle>/bootstrap/manifests/00-teknoir-istio-crds.yaml       (istio CRDs, untracked)
#   <bundle>/bootstrap/manifests/05-teknoir-certmanager-crds.yaml (cert-manager CRDs, untracked)
#   <bundle>/bootstrap/manifests/10-teknoir-argo.yaml             (infra charts/argo)
#   <bundle>/bootstrap/apply/harbor.yaml                          (gitops charts/harbor, one-shot apply -> adopted by ArgoCD)
#   <bundle>/bootstrap/manifests/app-of-apps.yaml                 (copy of teknoir-local-app-of-apps.yaml)
#   <bundle>/bootstrap/apply/istio.yaml                           (istio resources, one-shot apply -> adopted by ArgoCD)
#   <bundle>/bootstrap/k3s/registries.yaml                        (K3s registry mirrors -> Harbor)
#   <bundle>/bootstrap/k3s/coredns-custom.yaml                    (in-cluster *.teknoir.airgapped resolution)
#   <bundle>/bootstrap/k3s/teknoir-root-ca.crt                    (copied from repo root)
#
# Adopted resources (istio, harbor) carry an `argocd.argoproj.io/tracking-id`
# annotation (ArgoCD v3 annotation tracking) plus the informational
# `app.kubernetes.io/instance` label, so the corresponding ArgoCD Applications
# adopt them in-sync without recreation. CustomResourceDefinition and Namespace
# resources are never tracked: the renderer adds neither the tracking-id
# annotation nor the instance label to them, so no ArgoCD app can prune them;
# they are split into their own untracked manifests.
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
APPLY_OUT="${BUNDLE}/bootstrap/apply"
K3S_OUT="${BUNDLE}/bootstrap/k3s"

# ---------------------------------------------------------------------------
# ArgoCD adoption tracking (python3+PyYAML required)
# ---------------------------------------------------------------------------
# `track_instance` writes an `argocd.argoproj.io/tracking-id` annotation in
# ArgoCD v3 annotation-tracking format:
#   <app>:<group>/<kind>:<namespace>/<name>
# - core group (apiVersion: v1) -> empty group, e.g. `istio:/Service:istio-system/istiod`
# - non-core -> full group, e.g. `harbor:apps/Deployment:teknoir-system/harbor-core`
# - cluster-scoped (no metadata.namespace) -> destination namespace, e.g.
#   `istio:rbac.authorization.k8s.io/ClusterRole:istio-system/<name>`
# CustomResourceDefinition and Namespace are never tracked (dropped entirely),
# and the informational `app.kubernetes.io/instance` label is kept on the rest.
TRACK_PY='
import sys
import yaml

app = sys.argv[1]
dest_ns = sys.argv[2]
out = []
for doc in yaml.safe_load_all(sys.stdin):
    if doc is None:
        continue
    if not isinstance(doc, dict):
        out.append(doc)
        continue
    kind = doc.get("kind")
    if kind in ("CustomResourceDefinition", "Namespace"):
        continue
    meta = doc.setdefault("metadata", {})
    name = meta.get("name")
    if not name:
        out.append(doc)
        continue
    api_version = doc.get("apiVersion", "")
    group = api_version.split("/", 1)[0] if "/" in api_version else ""
    namespace = meta.get("namespace") or dest_ns
    labels = meta.get("labels") or {}
    labels["app.kubernetes.io/instance"] = app
    meta["labels"] = labels
    annotations = meta.get("annotations") or {}
    annotations["argocd.argoproj.io/tracking-id"] = "%s:%s/%s:%s/%s" % (app, group, kind, namespace, name)
    meta["annotations"] = annotations
    out.append(doc)
yaml.safe_dump_all(out, sys.stdout, default_flow_style=False, sort_keys=False)
'

FILTER_CRD_PY='
import sys
import yaml

out = []
for doc in yaml.safe_load_all(sys.stdin):
    if doc is None:
        continue
    if isinstance(doc, dict) and doc.get("kind") == "CustomResourceDefinition":
        out.append(doc)
yaml.safe_dump_all(out, sys.stdout, default_flow_style=False, sort_keys=False)
'

track_instance() {
  # stdin: rendered manifests; $1: app name; stdout: tracked manifests
  # (CustomResourceDefinition and Namespace docs are dropped).
  local app="$1" ns
  ns="$(chart_namespace "${app}")"
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "${TRACK_PY}" "${app}" "${ns}"
  else
    die "python3 with PyYAML is required to compute ArgoCD tracking-ids (missing)"
  fi
}

filter_crds() {
  # stdin: rendered manifests; stdout: only CustomResourceDefinition docs (unmodified)
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    python3 -c "${FILTER_CRD_PY}"
  elif command -v yq >/dev/null 2>&1; then
    yq eval 'select(.kind == "CustomResourceDefinition")' -
  else
    die "python3+PyYAML or yq is required to extract CRDs (missing)"
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
  # render_chart_manifest <chart-name> <chart-dir> <out-file> [tracking-app]
  local name="$1" dir="$2" out="$3" app="${4:-}"
  [[ -d "${dir}" ]] || die "chart directory not found: ${dir}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] helm template ${name} ${dir} -> ${out}${app:+ (track app.kubernetes.io/instance=${app} + argocd.argoproj.io/tracking-id)}"
    return 0
  fi
  log "rendering ${name} -> ${out}"
  helm_dep_build "${dir}"
  if [[ -n "${app}" ]]; then
    helm_template_chart "${name}" "${dir}" | track_instance "${app}" >> "${out}"
  else
    helm_template_chart "${name}" "${dir}" >> "${out}"
  fi
}

# Render a chart once and split it into an untracked CRD file and a tracked
# resources file. Used for istio: CRDs stay K3s-owned (untracked), while the
# remaining resources (no CustomResourceDefinition, no Namespace) are one-shot
# applied and later adopted by the ArgoCD `istio` Application.
render_split_chart() {
  # render_split_chart <chart-name> <chart-dir> <crds-out> <resources-out> <tracking-app>
  local name="$1" dir="$2" crds_out="$3" resources_out="$4" app="$5" tmp
  [[ -d "${dir}" ]] || die "chart directory not found: ${dir}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] helm template ${name} ${dir} -> split ${crds_out} (CRDs, untracked) + ${resources_out} (tracked)"
    return 0
  fi
  log "rendering ${name} -> ${crds_out} + ${resources_out}"
  helm_dep_build "${dir}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/${name}-render.XXXXXX")"
  helm_template_chart "${name}" "${dir}" > "${tmp}"
  filter_crds < "${tmp}" > "${crds_out}"
  track_instance "${app}" < "${tmp}" > "${resources_out}"
  rm -f "${tmp}"
}

# Render only the CRDs of a chart (untracked, K3s-owned).
render_crds_only() {
  # render_crds_only <chart-name> <chart-dir> <crds-out>
  local name="$1" dir="$2" crds_out="$3" tmp
  [[ -d "${dir}" ]] || die "chart directory not found: ${dir}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] helm template ${name} ${dir} --include-crds -> CRDs only (${crds_out})"
    return 0
  fi
  log "rendering ${name} CRDs -> ${crds_out}"
  helm_dep_build "${dir}"
  tmp="$(mktemp "${TMPDIR:-/tmp}/${name}-render.XXXXXX")"
  helm_template_chart "${name}" "${dir}" > "${tmp}"
  filter_crds < "${tmp}" > "${crds_out}"
  rm -f "${tmp}"
}

# ---------------------------------------------------------------------------
# Ordered bootstrap manifests
# ---------------------------------------------------------------------------
run mkdir -p "${MANIFESTS_OUT}" "${APPLY_OUT}" "${K3S_OUT}"

NAMESPACES_OUT="${MANIFESTS_OUT}/00-teknoir-namespaces.yaml"
ISTIO_CRDS_OUT="${MANIFESTS_OUT}/00-teknoir-istio-crds.yaml"
CERTMANAGER_CRDS_OUT="${MANIFESTS_OUT}/05-teknoir-certmanager-crds.yaml"
ARGO_OUT="${MANIFESTS_OUT}/10-teknoir-argo.yaml"
HARBOR_OUT="${APPLY_OUT}/harbor.yaml"
ISTIO_APPLY_OUT="${APPLY_OUT}/istio.yaml"

if [[ "${DRY_RUN}" != "1" ]]; then
  # namespaces first (istio-injection on teknoir-system so harbor gets sidecars);
  # deliberately NOT tracked: no ArgoCD app may prune them.
  { namespace_doc "istio-system"
    namespace_doc "teknoir-system" "istio-injection: enabled"
    namespace_doc "cert-manager"
    namespace_doc "teknoir-auth"; } > "${NAMESPACES_OUT}"
  : > "${ISTIO_CRDS_OUT}"
  : > "${CERTMANAGER_CRDS_OUT}"
  : > "${ARGO_OUT}"
  : > "${HARBOR_OUT}"
  : > "${ISTIO_APPLY_OUT}"
fi

render_split_chart "istio"        "${GITOPS_REPO_DIR}/charts/istio"         "${ISTIO_CRDS_OUT}" "${ISTIO_APPLY_OUT}" "istio"
render_crds_only   "cert-manager" "${GITOPS_REPO_DIR}/charts/cert-manager"  "${CERTMANAGER_CRDS_OUT}"
render_chart_manifest "argo"      "${REPO_ROOT}/charts/argo"                "${ARGO_OUT}"
render_chart_manifest "harbor"    "${GITOPS_REPO_DIR}/charts/harbor"        "${HARBOR_OUT}" "harbor"

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
    for f in "${NAMESPACES_OUT}" "${ISTIO_CRDS_OUT}" "${CERTMANAGER_CRDS_OUT}" \
             "${ARGO_OUT}" "${HARBOR_OUT}" "${ISTIO_APPLY_OUT}" "${K3S_OUT}/coredns-custom.yaml"; do
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

  # --- adoption/ownership assertions (best effort) ------------------------
  validation_ok=1

  # Adopted resources carry the ArgoCD v3 tracking-id for the right app.
  if ! grep -q 'argocd.argoproj.io/tracking-id: istio:' "${ISTIO_APPLY_OUT}"; then
    warn "no istio tracking-id found in $(basename "${ISTIO_APPLY_OUT}")"
    validation_ok=0
  fi
  if ! grep -q 'argocd.argoproj.io/tracking-id: harbor:' "${HARBOR_OUT}"; then
    warn "no harbor tracking-id found in $(basename "${HARBOR_OUT}")"
    validation_ok=0
  fi
  # Core-group resources must render an empty group component (e.g. istio:/Service:...).
  if ! grep -qE 'argocd.argoproj.io/tracking-id: istio:/[A-Za-z]+:istio-system/' "${ISTIO_APPLY_OUT}"; then
    warn "no core-group (empty) istio tracking-id found (expected e.g. istio:/Service:istio-system/...)"
    validation_ok=0
  fi

  # Adopted resources must exclude CRDs and Namespaces (they are split out).
  for f in "${ISTIO_APPLY_OUT}" "${HARBOR_OUT}"; do
    if grep -qE '^kind: (CustomResourceDefinition|Namespace)$' "${f}"; then
      warn "$(basename "${f}") must not contain CustomResourceDefinition or Namespace"
      validation_ok=0
    fi
  done

  # CRD/Namespace manifests must never be tracked.
  for f in "${NAMESPACES_OUT}" "${ISTIO_CRDS_OUT}" "${CERTMANAGER_CRDS_OUT}"; do
    if grep -q 'argocd.argoproj.io/tracking-id:' "${f}"; then
      warn "tracking-id must not appear on CRD/Namespace manifest: $(basename "${f}")"
      validation_ok=0
    fi
  done

  # Bootstrap-owned CRD manifests must be non-empty: a fresh install needs the
  # istio + cert-manager CRDs present before their ArgoCD apps reconcile.
  certmanager_crd_count="$(grep -cE '^kind: CustomResourceDefinition$' "${CERTMANAGER_CRDS_OUT}" || true)"
  if [[ "${certmanager_crd_count:-0}" -eq 0 ]]; then
    warn "cert-manager CRD manifest is empty: $(basename "${CERTMANAGER_CRDS_OUT}")"
    validation_ok=0
  else
    log "cert-manager CRD manifest: ${certmanager_crd_count} CustomResourceDefinition(s)"
  fi
  istio_crd_count="$(grep -cE '^kind: CustomResourceDefinition$' "${ISTIO_CRDS_OUT}" || true)"
  if [[ "${istio_crd_count:-0}" -eq 0 ]]; then
    warn "istio CRD manifest is empty: $(basename "${ISTIO_CRDS_OUT}")"
    validation_ok=0
  else
    log "istio CRD manifest: ${istio_crd_count} CustomResourceDefinition(s)"
  fi

  # The bootstrap render must contain no Certificate (cert-manager owns it).
  for f in "${ISTIO_APPLY_OUT}" "${HARBOR_OUT}"; do
    if grep -qE '^kind: Certificate$' "${f}"; then
      warn "bootstrap render must not contain Certificate: $(basename "${f}")"
      validation_ok=0
    fi
  done

  if [[ "${validation_ok}" == "1" ]]; then
    log "validation OK: tracking-ids present, CRDs/namespaces untracked, no Certificate in bootstrap render"
  else
    warn "validation failed — review the warnings above"
  fi
  log "bootstrap manifests rendered into ${MANIFESTS_OUT} (one-shot resources in ${APPLY_OUT})"
fi
