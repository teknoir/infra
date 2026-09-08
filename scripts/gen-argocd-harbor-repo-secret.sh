#!/usr/bin/env bash
set -euo pipefail

# gen-argocd-harbor-repo-secret.sh
# Generates the ArgoCD repo-creds secret for the in-cluster Harbor OCI Helm
# registry. Prefers the robot account credentials written by
# airgap/push-to-harbor.sh; falls back to the Harbor admin credential.

SECRETS_DIR=".secrets"
MANIFEST_FILE="${SECRETS_DIR}/manifest-argocd-harbor-repo-secret.yaml"
NAMESPACE="teknoir-system"
SECRET_NAME="argocd-harbor-repo"
HARBOR_URL="harbor.teknoir.airgapped/teknoir"

ROBOT_ENV_FILE="airgap/.secrets/robot-argocd.env"
HARBOR_SECRET_MANIFEST="${SECRETS_DIR}/manifest-harbor-secret.yaml"

mkdir -p "${SECRETS_DIR}"

# Colors
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ -f "${ROBOT_ENV_FILE}" ]; then
  # shellcheck source=/dev/null
  . "${ROBOT_ENV_FILE}"
  if [ -z "${HARBOR_ROBOT_USER:-}" ] || [ -z "${HARBOR_ROBOT_TOKEN:-}" ]; then
    echo "Error: ${ROBOT_ENV_FILE} exists but does not set HARBOR_ROBOT_USER/HARBOR_ROBOT_TOKEN." >&2
    exit 1
  fi
  USERNAME="${HARBOR_ROBOT_USER}"
  PASSWORD="${HARBOR_ROBOT_TOKEN}"
  echo "Using robot account credentials from ${ROBOT_ENV_FILE}"
else
  printf "${YELLOW}WARNING: %s not found. Falling back to the Harbor admin credential.${NC}\n" "${ROBOT_ENV_FILE}" >&2
  printf "${YELLOW}WARNING: Robot account credentials are preferred; run airgap/push-to-harbor.sh and re-run this script.${NC}\n" >&2
  USERNAME="admin"
  if [ -n "${HARBOR_ADMIN_PASSWORD:-}" ]; then
    PASSWORD="${HARBOR_ADMIN_PASSWORD}"
    echo "Using Harbor admin password from HARBOR_ADMIN_PASSWORD environment variable"
  elif [ -f "${HARBOR_SECRET_MANIFEST}" ]; then
    PASSWORD=$(sed -n 's/^ *HARBOR_ADMIN_PASSWORD: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${HARBOR_SECRET_MANIFEST}" | head -n 1)
    if [ -z "${PASSWORD}" ]; then
      echo "Error: Could not parse HARBOR_ADMIN_PASSWORD from ${HARBOR_SECRET_MANIFEST}." >&2
      exit 1
    fi
    echo "Using Harbor admin password parsed from ${HARBOR_SECRET_MANIFEST}"
  else
    echo "Error: No credentials available. Set HARBOR_ADMIN_PASSWORD or generate ${HARBOR_SECRET_MANIFEST} (scripts/gen-harbor-secrets.sh)." >&2
    exit 1
  fi
fi

cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: helm
  url: ${HARBOR_URL}
  enableOCI: "true"
  username: "${USERNAME}"
  password: "${PASSWORD}"
EOF

echo "Wrote manifest to ${MANIFEST_FILE}"
echo "Repo URL: ${HARBOR_URL}"
echo "Username: ${USERNAME}"
echo ""
echo "Next steps:"
echo "  - Deploy the secret with: scripts/deploy-secrets.sh"
