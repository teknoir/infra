#!/usr/bin/env bash

# gen-argocd-keycloak-secrets.sh
# Prompts for the Argo CD Keycloak client secret and generates a Kubernetes Secret manifest.

set -e

# Define the output file
OUTPUT_FILE="manifest-argocd-keycloak-secret.yaml"
NAMESPACE="teknoir-system"

echo "=========================================================="
echo " Generating Argo CD OIDC Secret Manifest"
echo "=========================================================="

# Prompt for the Keycloak Client Secret
read -s -p "Enter the Keycloak client secret for Argo CD: " CLIENT_SECRET
echo ""

if [ -z "$CLIENT_SECRET" ]; then
  echo "Error: Client secret cannot be empty."
  exit 1
fi

# Base64 encode the secret
ENCODED_SECRET=$(echo -n "$CLIENT_SECRET" | base64 | tr -d '\n')

# Generate the Kubernetes Secret manifest
cat <<EOF > "$OUTPUT_FILE"
apiVersion: v1
kind: Secret
metadata:
  name: argocd-oidc-secret
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: argocd
type: Opaque
data:
  oidc.auth.clientSecret: ${ENCODED_SECRET}
EOF

echo "Successfully generated: ${OUTPUT_FILE}"
echo ""
echo "You can now apply this secret to your cluster using:"
echo "kubectl apply -f ${OUTPUT_FILE}"