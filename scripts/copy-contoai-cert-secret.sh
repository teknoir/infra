#!/usr/bin/env bash
#
# Copy the *.contoai.site wildcard TLS secret from the contoai cluster to the
# r415 cluster.
#
# Why: r415 is the single public edge (UDM Pro forwards 443 -> r415) and it
# terminates TLS for contoai.site, but r415 has no DNS-01 credentials for the
# contoai.site zone (Loopia lives on the contoai cluster). The certificate is
# therefore issued/renewed by cert-manager on contoai and mirrored here.
#
# Adapted from scripts/copy-cert-secret.sh, but cross-cluster and driven by
# kubectl contexts:
#   contoai  -> source (issued by cert-manager, namespace istio-gateway)
#   r415     -> target (consumed via SDS by the ingress gateway, namespace istio-system)
#
# Renewal is manual: cert-manager rotates the secret on contoai, so re-run this
# script (or schedule it as a CronJob) when the certificate renews.
#
# Usage:
#   ./copy-contoai-cert-secret.sh            # copy
#   DRY_RUN=true ./copy-contoai-cert-secret.sh
#
# Overrides:
#   SOURCE_CONTEXT (contoai), SOURCE_NAMESPACE (istio-gateway), SOURCE_SECRET (contoai-site-wildcard-tls)
#   TARGET_CONTEXT (r415),    TARGET_NAMESPACE (istio-system),  TARGET_SECRET (contoai-site-wildcard-tls)

set -euo pipefail

SOURCE_CONTEXT="${SOURCE_CONTEXT:-contoai}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-istio-gateway}"
SOURCE_SECRET="${SOURCE_SECRET:-contoai-site-wildcard-tls}"

TARGET_CONTEXT="${TARGET_CONTEXT:-r415}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-istio-system}"
TARGET_SECRET="${TARGET_SECRET:-contoai-site-wildcard-tls}"

DRY_RUN="${DRY_RUN:-false}"

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl not found." >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq not found (brew install yq)." >&2; exit 1; }

echo "Source: ${SOURCE_CONTEXT}/${SOURCE_NAMESPACE}/${SOURCE_SECRET}"
echo "Target: ${TARGET_CONTEXT}/${TARGET_NAMESPACE}/${TARGET_SECRET}"

for ctx in "$SOURCE_CONTEXT" "$TARGET_CONTEXT"; do
  if ! kubectl config get-contexts "$ctx" >/dev/null 2>&1; then
    echo "ERROR: kubectl context not found: ${ctx}" >&2
    exit 1
  fi
done

kubectl --context "$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" get secret "$SOURCE_SECRET" >/dev/null
kubectl --context "$TARGET_CONTEXT" get namespace "$TARGET_NAMESPACE" >/dev/null

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT

# Strip cluster-assigned metadata and cert-manager ownership so the copy is a
# plain, inert TLS secret on the target cluster.
kubectl --context "$SOURCE_CONTEXT" -n "$SOURCE_NAMESPACE" get secret "$SOURCE_SECRET" -o yaml \
  | yq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
            .metadata.ownerReferences, .metadata.managedFields, .metadata.generation,
            .metadata.selfLink, .metadata.annotations, .metadata.labels,
            .metadata.namespace, .status)
        | .metadata.name = "'"$TARGET_SECRET"'"' \
  > "$manifest"

if [ "$DRY_RUN" = "true" ]; then
  echo "--- DRY RUN: manifest that would be applied ---"
  cat "$manifest"
  exit 0
fi

kubectl --context "$TARGET_CONTEXT" -n "$TARGET_NAMESPACE" apply -f "$manifest"

echo
echo "Copied ${SOURCE_CONTEXT}/${SOURCE_NAMESPACE}/${SOURCE_SECRET} -> ${TARGET_CONTEXT}/${TARGET_NAMESPACE}/${TARGET_SECRET}"

if command -v openssl >/dev/null 2>&1; then
  echo "Target certificate:"
  kubectl --context "$TARGET_CONTEXT" -n "$TARGET_NAMESPACE" get secret "$TARGET_SECRET" \
    -o jsonpath='{.data.tls\.crt}' | openssl base64 -d -A \
    | openssl x509 -noout -subject -issuer -dates 2>/dev/null || true
fi
