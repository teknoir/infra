#!/bin/sh
set -e

# Fetch and encode secrets directly without intermediate files
ADMIN_CREDENTIALS_B64=$(gcloud secrets versions access latest --secret="teknoir-admin-credentials" --project teknoir-mgmt | base64)
BACKEND_AUTH_B64=$(gcloud secrets versions access latest --secret="backend-auth-backstage-secrets" --project teknoir-mgmt | base64)
GITHUB_APP_B64=$(gcloud secrets versions access latest --secret="github-app-backstage-teknoir-credentials" --project teknoir-mgmt | base64)

# Fetch postgres credentials once and extract all values
POSTGRES_SECRET=$(gcloud secrets versions access latest --secret="teknoir-postgres-credentials" --project teknoir-mgmt)
DATA_SOURCE_USER_B64=$(echo "$POSTGRES_SECRET" | yq '.data.DATA_SOURCE_USER')
DATA_SOURCE_PASS_B64=$(echo "$POSTGRES_SECRET" | yq '.data.DATA_SOURCE_PASS')
POSTGRES_USER_B64=$(echo "$POSTGRES_SECRET" | yq '.data.POSTGRES_USER')
POSTGRES_PASSWORD_B64=$(echo "$POSTGRES_SECRET" | yq '.data.POSTGRES_PASSWORD')

# Create secrets manifest
cat <<EOF > manifest-backstage-secrets.yaml
apiVersion: v1
data:
  admin-credentials.json: |
    ${ADMIN_CREDENTIALS_B64}
  backend-auth-backstage-secrets.yaml: ${BACKEND_AUTH_B64}
  github-app-backstage-teknoir-credentials.yaml: |
    ${GITHUB_APP_B64}
kind: Secret
metadata:
  name: backstage-github-app-secret
  namespace: teknoir-system
type: Opaque
---
apiVersion: v1
data:
  DATA_SOURCE_PASS: ${DATA_SOURCE_PASS_B64}
  DATA_SOURCE_USER: ${DATA_SOURCE_USER_B64}
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD_B64}
  POSTGRES_USER: ${POSTGRES_USER_B64}
kind: Secret
metadata:
  name: backstage-postgres-secrets
  namespace: teknoir-system
type: Opaque
EOF