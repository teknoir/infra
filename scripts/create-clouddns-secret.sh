#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="teknoir"
SERVICE_ACCOUNT="teknoir-admin@teknoir.iam.gserviceaccount.com"
NAMESPACE="cert-manager"
SECRET_NAME="clouddns-dns01"
KEY_NAME="key.json"
MANIFEST_FILE="manifest-clouddns-secret.yaml"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

key_file="${tmp_dir}/${KEY_NAME}"

echo "Creating service account key for ${SERVICE_ACCOUNT} in project ${PROJECT_ID}..."
gcloud iam service-accounts keys create "${key_file}" \
  --iam-account "${SERVICE_ACCOUNT}" \
  --project "${PROJECT_ID}"

encoded_key="$(base64 < "${key_file}" | tr -d '\n')"

cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
data:
  ${KEY_NAME}: ${encoded_key}
EOF

echo "Wrote manifest to ${MANIFEST_FILE}."
