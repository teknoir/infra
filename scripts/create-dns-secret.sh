#!/usr/bin/env bash
set -euo pipefail

# Replace this with your actual API token
API_TOKEN="your-dns-provider-api-token"
NAMESPACE="cert-manager"
SECRET_NAME="dns-provider-credentials"
MANIFEST_FILE="manifest-dns-secret.yaml"

# Base64 encode the token
ENCODED_TOKEN=$(echo -n "$API_TOKEN" | base64 | tr -d '\n')

cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  api-token: ${ENCODED_TOKEN}
EOF

echo "Wrote manifest to ${MANIFEST_FILE}."