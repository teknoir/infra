#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="manifest-keycloak-db-secret.yaml"
NAMESPACE="teknoir-auth"
SECRET_NAME="keycloak-db-secret"
DB_USERNAME="${1:-keycloak}"
DB_PASSWORD="${2:-}"

if [ -z "${DB_PASSWORD}" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to generate a database password." >&2
    exit 1
  fi

  DB_PASSWORD="$(python3 - <<'PY'
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
  username: "${DB_USERNAME}"
  password: "${DB_PASSWORD}"
EOF

echo "Wrote manifest to ${MANIFEST_FILE}"
echo "db username: ${DB_USERNAME}"
echo "db password: ${DB_PASSWORD}"
