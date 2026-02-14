#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="manifest-oauth2-proxy-redis-secret.yaml"
NAMESPACE="teknoir-system"
SECRET_NAME="oauth2-proxy-redis-secret"
REDIS_PASSWORD="${1:-}"

if [ -z "${REDIS_PASSWORD}" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to generate a redis password." >&2
    exit 1
  fi

  REDIS_PASSWORD="$(python3 - <<'PY'
import os,base64
print(base64.b64encode(os.urandom(24)).decode())
PY
)"
fi

cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  password: "${REDIS_PASSWORD}"
EOF

echo "Wrote manifest to ${MANIFEST_FILE}"
echo "redis password: ${REDIS_PASSWORD}"
