#!/usr/bin/env bash
set -euo pipefail

# Target namespaces to copy the secret to
NAMESPACES=("teknoir-demo" "avangard-production" "boxer-property" "prime-communications")

# Configuration
SOURCE_NS="istio-system"
SECRET_NAME="teknoir-cloud-wildcard-tls"
NEW_SECRET_NAME="teknoir-cloud-wildcard-tls-copied"
MANIFEST_FILE="tmp/tls-routing-gateway/manifests.yaml"

# Check for required tools
for tool in kubectl yq; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: Required tool '$tool' not found." >&2
        exit 1
    fi
done

# Check if kubectl neat plugin is available
NEAT_PLUGIN=$(kubectl neat version 2>/dev/null && echo "neat" || echo "")

# TODO: create a tempfile and store secret
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

echo "Fetching secret $SECRET_NAME from $SOURCE_NS..."
# Fetch the secret, clean it up, rename it, and remove the namespace so it can be applied elsewhere
if [ -n "$NEAT_PLUGIN" ]; then
    kubectl -n "$SOURCE_NS" get secret "$SECRET_NAME" -o yaml | kubectl neat | yq ".metadata.name = \"$NEW_SECRET_NAME\" | del(.metadata.namespace)" > "$TEMP_FILE"
else
    kubectl -n "$SOURCE_NS" get secret "$SECRET_NAME" -o yaml | yq ".metadata.name = \"$NEW_SECRET_NAME\" | del(.metadata.namespace, .metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.annotations[\"kubectl.kubernetes.io/last-applied-configuration\"])" > "$TEMP_FILE"
fi

# Append the secret to the manifest file
mkdir -p "$(dirname "$MANIFEST_FILE")"
echo "---" >> "$MANIFEST_FILE"
cat "$TEMP_FILE" >> "$MANIFEST_FILE"

# TODO: Copy secrets to the array of namespaces (teknoir-demo, avangard-production, boxer-property)
for NS in "${NAMESPACES[@]}"; do
    echo "Copying secret to namespace: $NS"
    # Ensure namespace exists
    kubectl get namespace "$NS" &>/dev/null || kubectl create namespace "$NS"
    # Apply the secret
    kubectl apply -f "$TEMP_FILE" -n "$NS"
done

# TODO: delete tempfile (Handled by trap on EXIT)
echo "Secret successfully copied to namespaces: ${NAMESPACES[*]}"