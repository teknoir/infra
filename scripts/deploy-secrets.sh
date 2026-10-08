#!/usr/bin/env bash
# deploy-secrets.sh — install the generated secret manifests (.secrets/, from
# scripts/gen-*.sh) into the K3s auto-deploy dir of the air-gapped node.
#
# Each secret is K3s-owned through exactly one canonical file
# (teknoir-<name>.yaml, mode 600); legacy duplicates written by older tooling
# (manifest-*.yaml) are retired once the canonical file owns the objects.
# Idempotent: unchanged secrets are rewritten byte-identically and K3s does not
# re-apply them.
#
# The cert-manager-owned wildcard TLS secret is NOT deployed by default: it is
# a bootstrap placeholder that cert-manager replaces, and re-applying it would
# overwrite the issued certificate. --bootstrap-wildcard creates it only when
# it does not exist yet (fresh cluster), so even that is safe to re-run.
#
# The source is the operator's .secrets/. The bundle copy (bootstrap/secrets/)
# is only used by the first bootstrap, with --create-only: it may be older than
# .secrets/ (e.g. an admin-fallback ArgoCD repo secret), so it never replaces a
# Secret that already exists.
#
# --retire-legacy deploys nothing: it retires the legacy duplicates on the node
# whose canonical file is already there, checking ownership against that file
# on the node, so no local copy of the secret is needed and its content never
# leaves the node.
#
# Usage: scripts/deploy-secrets.sh [--only <manifest>]... [--bootstrap-wildcard]
#                                  [--create-only] [--secrets-dir DIR]
#                                  [--host user@host] [--ssh-key FILE] [--dry-run]
#        scripts/deploy-secrets.sh --retire-legacy [--only <manifest>]... [--dry-run]
set -euo pipefail

# shellcheck source=../airgap/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/airgap/lib.sh"

SECRETS_DIR="${REPO_ROOT}/.secrets"

# Read-only secrets that live in the K3s manifests dir.
SECRET_MANIFESTS=(
  manifest-harbor-secret.yaml
  manifest-keycloak-db-secret.yaml
  manifest-oauth2-proxy-secret.yaml
  manifest-oauth2-proxy-redis-secret.yaml
  manifest-argocd-keycloak-secret.yaml
  manifest-teknoir-ca-secret.yaml
  manifest-argocd-harbor-repo-secret.yaml
  manifest-teknoir-auth-ca-bundle-secret.yaml
  manifest-teknoir-system-ca-bundle-secret.yaml
)
WILDCARD_MANIFEST="manifest-wildcard-tls-secret.yaml"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --only NAME           deploy only this manifest (repeatable), e.g.
                        --only manifest-argocd-harbor-repo-secret.yaml
  --bootstrap-wildcard  also create ${WILDCARD_MANIFEST} if the secret
                        does not exist yet (cert-manager owns it afterwards)
  --create-only         skip manifests whose Secret already exists
                        (first bootstrap from the bundle's copies)
  --retire-legacy       deploy nothing; retire the legacy manifest-*.yaml files
                        on the node whose canonical teknoir-*.yaml is there and
                        owns every object (checked on the node)
  --secrets-dir DIR     where the manifest-*.yaml files are
                        (default: ${SECRETS_DIR})
  --host H              ssh target (default: ${TEKNOIR_HOST})
  --ssh-key FILE        ssh identity file (default: \$SSH_KEY, else auto-detected)
  --dry-run             print actions without mutating the node
  -h, --help            show this help
EOF
}

ONLY=()
BOOTSTRAP_WILDCARD=0
CREATE_ONLY=0
RETIRE_LEGACY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift ;;
    --bootstrap-wildcard) BOOTSTRAP_WILDCARD=1 ;;
    --create-only) CREATE_ONLY=1 ;;
    --retire-legacy) RETIRE_LEGACY=1 ;;
    --secrets-dir) SECRETS_DIR="$2"; shift ;;
    --host) TEKNOIR_HOST="$2"; shift ;;
    --ssh-key) SSH_KEY="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

require_cmd ssh
apply_ssh_key

if [[ ${#ONLY[@]} -gt 0 ]]; then
  for m in "${ONLY[@]}"; do
    [[ " ${SECRET_MANIFESTS[*]} " == *" ${m} "* ]] || die "--only ${m}: not a known secret manifest"
  done
  SECRET_MANIFESTS=("${ONLY[@]}")
fi

if [[ "${RETIRE_LEGACY}" == "1" ]]; then
  [[ "${CREATE_ONLY}" == "0" && "${BOOTSTRAP_WILDCARD}" == "0" ]] \
    || die "--retire-legacy deploys nothing; it cannot be combined with --create-only or --bootstrap-wildcard"
  node_has() {
    # node_has <basename> — 0 present, 1 absent; dies when the node cannot be read
    local rc=0
    ssh_query "sudo test -e '${K3S_MANIFESTS_DIR}/$1'" 2>/dev/null || rc=$?
    case "${rc}" in
      0|1) return "${rc}" ;;
      *) die "cannot check ${K3S_MANIFESTS_DIR}/$1 on ${TEKNOIR_HOST}" ;;
    esac
  }
  kept=0
  for manifest in "${SECRET_MANIFESTS[@]}"; do
    canonical="$(k3s_canonical_name "${manifest}")"
    for legacy in $(k3s_legacy_names "${canonical}"); do
      node_has "${legacy}" || continue
      if ! node_has "${canonical}"; then
        warn "${legacy}: no ${canonical} on the node, kept (deploy it first: scripts/deploy-secrets.sh --only ${manifest})"
        kept=$((kept + 1))
        continue
      fi
      if [[ "${DRY_RUN}" == "1" ]]; then
        # Read-only preview of k3s_retire_legacy's ownership check.
        owners="$(k3s_owners "node:${K3S_MANIFESTS_DIR}/${canonical}")" || owners=""
        foreign="$(awk -v a="${canonical%.yaml}" '$2 != a' <<<"${owners}")"
        if [[ -z "${owners}" ]]; then
          log "[dry-run] ${legacy}: none of ${canonical}'s objects found, would be kept"
        elif [[ -n "${foreign}" ]]; then
          log "[dry-run] would re-apply ${canonical} (it does not own: $(awk '{print $1}' <<<"${foreign}" | tr '\n' ' '))and retire ${legacy}"
        else
          log "[dry-run] would retire ${legacy} (${canonical%.yaml} owns all its objects)"
        fi
        continue
      fi
      k3s_retire_legacy "${legacy}" "${canonical}"
    done
  done
  (( kept == 0 )) || warn "${kept} legacy secret manifest(s) kept"
  log "deploy-secrets --retire-legacy complete"
  exit 0
fi

in_cluster() {
  # in_cluster <manifest> — print the objects of <manifest> that already exist.
  # A failed query aborts: counting it as "absent" could overwrite live data.
  local out
  if ! out="$(ssh_query "sudo k3s kubectl get --ignore-not-found -o name -f -" < "$1")"; then
    [[ "${DRY_RUN}" == "1" ]] || die "cannot check whether the objects in $(basename "$1") exist"
    out=""  # dry-run against an unreachable node: report what would be created
  fi
  printf '%s' "${out}"
}

missing=0
for manifest in "${SECRET_MANIFESTS[@]}"; do
  if [[ -f "${SECRETS_DIR}/${manifest}" ]]; then
    if [[ "${CREATE_ONLY}" == "1" ]]; then
      # Plain assignment, so a die() inside the substitution stops the script.
      existing="$(in_cluster "${SECRETS_DIR}/${manifest}")"
      if [[ -n "${existing}" ]]; then
        log "${manifest}: already in the cluster, not replaced (--create-only; update with scripts/deploy-secrets.sh)"
        continue
      fi
    fi
    log "deploying ${manifest} -> ${K3S_MANIFESTS_DIR}/$(k3s_canonical_name "${manifest}")"
    k3s_deploy "${SECRETS_DIR}/${manifest}" 0600
  else
    warn "missing ${SECRETS_DIR}/${manifest} — skipped (generate it with scripts/gen-*.sh)"
    missing=$((missing + 1))
  fi
done

if [[ "${BOOTSTRAP_WILDCARD}" == "1" ]]; then
  [[ -f "${SECRETS_DIR}/${WILDCARD_MANIFEST}" ]] || die "missing ${SECRETS_DIR}/${WILDCARD_MANIFEST}"
  # Always create-only: once it exists, cert-manager owns the content.
  existing="$(in_cluster "${SECRETS_DIR}/${WILDCARD_MANIFEST}")"
  if [[ -n "${existing}" ]]; then
    log "wildcard TLS secret present (${existing}); cert-manager owns it, placeholder not re-applied"
  else
    log "creating the wildcard TLS placeholder from ${WILDCARD_MANIFEST} (cert-manager takes it over)"
    remote_kubectl apply -f - < "${SECRETS_DIR}/${WILDCARD_MANIFEST}"
  fi
fi

(( missing == 0 )) || warn "${missing} secret manifest(s) missing"
log "deploy-secrets complete"
