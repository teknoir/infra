#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="teknoir-mgmt"
SERVICE_ACCOUNT="pull-secret-sa@teknoir-mgmt.iam.gserviceaccount.com"
NAMESPACE="teknoir-system"
SECRET_NAME="gcr-json-key"
MANIFEST_FILE="manifest-gcr-json-key-secret.yaml"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

key_file="${tmp_dir}/key.json"

echo "Creating service account key for ${SERVICE_ACCOUNT} in project ${PROJECT_ID}..."
gcloud iam service-accounts keys create "${key_file}" \
  --iam-account "${SERVICE_ACCOUNT}" \
  --project "${PROJECT_ID}"

# Create the docker config json
# We need to ensure the key is a single string for the password field
json_key_string=$(cat "${key_file}" | jq -Rs 'sub("\n$"; "")')
auth_string=$(echo -n "_json_key:$(cat "${key_file}")" | base64 | tr -d '\n')

REGISTRIES=(
  "gcr.io"
  "us.gcr.io"
  "eu.gcr.io"
  "asia.gcr.io"
  "us-central1-docker.pkg.dev"
  "us-docker.pkg.dev"
  "eu-docker.pkg.dev"
  "asia-docker.pkg.dev"
)

auths_json=""
for i in "${!REGISTRIES[@]}"; do
  registry="${REGISTRIES[$i]}"
  entry=$(cat <<EOF
    "${registry}": {
      "username": "_json_key",
      "password": ${json_key_string},
      "auth": "${auth_string}"
    }
EOF
)
  if [ $i -lt $((${#REGISTRIES[@]} - 1)) ]; then
    auths_json="${auths_json}${entry},"
  else
    auths_json="${auths_json}${entry}"
  fi
done

docker_config_json=$(cat <<EOF
{
  "auths": {
${auths_json}
  }
}
EOF
)

encoded_config="$(echo "${docker_config_json}" | base64 | tr -d '\n')"

cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${encoded_config}
EOF

echo "Wrote manifest to ${MANIFEST_FILE}."
