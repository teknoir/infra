#!/usr/bin/env bash
set -euo pipefail

# gen-argocd-harbor-repo-secret.sh
# Generates the ArgoCD repo-creds secret for the in-cluster Harbor OCI Helm
# registry from the robot credential in airgap/.secrets/robot-argocd.env, or
# $ROBOT_ENV_FILE (kept in sync with Harbor by airgap/push-to-harbor.sh, which
# passes its --robot-env file here). Falls back to the Harbor admin credential
# only for the first bootstrap, before the robot exists.
# Deterministic: re-running with the same credential rewrites identical content.

# A relative $ROBOT_ENV_FILE is relative to the caller's directory.
if [ -n "${ROBOT_ENV_FILE:-}" ]; then
  case "${ROBOT_ENV_FILE}" in
    /*) ;;
    *) ROBOT_ENV_FILE="${PWD}/${ROBOT_ENV_FILE}" ;;
  esac
fi

# Paths are relative to the repo root, wherever the script is called from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077

SECRETS_DIR=".secrets"
MANIFEST_FILE="${SECRETS_DIR}/manifest-argocd-harbor-repo-secret.yaml"
NAMESPACE="teknoir-system"
SECRET_NAME="argocd-harbor-repo"
HARBOR_URL="harbor.teknoir.airgapped/teknoir"

ROBOT_ENV_FILE="${ROBOT_ENV_FILE:-airgap/.secrets/robot-argocd.env}"
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
  printf '%bWARNING: %s not found. Falling back to the Harbor admin credential.%b\n' "${YELLOW}" "${ROBOT_ENV_FILE}" "${NC}" >&2
  printf '%bWARNING: Robot account credentials are preferred; run airgap/push-to-harbor.sh and re-run this script.%b\n' "${YELLOW}" "${NC}" >&2
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

PREV_SUM=""
if [ -f "${MANIFEST_FILE}" ]; then
  PREV_SUM="$(sha256sum < "${MANIFEST_FILE}")"
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

chmod 600 "${MANIFEST_FILE}"
echo "Wrote ${MANIFEST_FILE} (repo ${HARBOR_URL}, user ${USERNAME})"

if [ "${PREV_SUM}" = "$(sha256sum < "${MANIFEST_FILE}")" ]; then
  echo "Unchanged from the previous manifest."
else
  printf '%bThe ArgoCD repo secret changed — deploy it: scripts/deploy-secrets.sh%b\n' "${YELLOW}" "${NC}" >&2
fi
