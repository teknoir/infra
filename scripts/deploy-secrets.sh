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
# Usage: scripts/deploy-secrets.sh [--only <manifest>]... [--bootstrap-wildcard]
#                                  [--create-only] [--secrets-dir DIR]
#                                  [--host user@host] [--ssh-key FILE] [--dry-run]
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift ;;
    --bootstrap-wildcard) BOOTSTRAP_WILDCARD=1 ;;
    --create-only) CREATE_ONLY=1 ;;
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
