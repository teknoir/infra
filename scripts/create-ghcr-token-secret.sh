#!/usr/bin/env bash
set -euo pipefail

GITHUB_USER="tekn0ir"
REGISTRY="ghcr.io"
SECRET_NAME="ghcr-token"
MANIFEST_FILE="manifest-ghcr-token-secret.yaml"

# Get PAT from environment or prompt
if [ -z "${GITHUB_PAT:-}" ]; then
  echo "GITHUB_PAT not set."
  read -rsp "Enter GitHub Personal Access Token (read:packages scope): " GITHUB_PAT
  echo
fi

if [ -z "${GITHUB_PAT}" ]; then
  echo "Error: No PAT provided." >&2
  exit 1
fi

# Build docker config json
auth_string=$(echo -n "${GITHUB_USER}:${GITHUB_PAT}" | base64 | tr -d '\n')

docker_config_json=$(cat <<EOF
{
  "auths": {
    "${REGISTRY}": {
      "username": "${GITHUB_USER}",
      "password": "${GITHUB_PAT}",
      "auth": "${auth_string}"
    }
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
  namespace: teknoir-auth
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${encoded_config}

---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: teknoir-system
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${encoded_config}
EOF

echo "Wrote manifest to ${MANIFEST_FILE}."
