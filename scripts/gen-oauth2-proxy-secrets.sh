#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="manifest-oauth2-proxy-secret.yaml"
NAMESPACE="teknoir-system"
SECRET_NAME="oauth2-proxy-secret"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to generate a cookie secret." >&2
  exit 1
fi

cookie_secret="$(python3 - <<'PY'
import os,base64
print(base64.b64encode(os.urandom(32)).decode())
PY
)"

read -r -p "Enter Keycloak client secret: " client_secret
if [ -z "${client_secret}" ]; then
  echo "Client secret is required." >&2
  exit 1
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
  client-secret: "${client_secret}"
  cookie-secret: "${cookie_secret}"
EOF

echo "Wrote manifest to ${MANIFEST_FILE}"
echo "cookie secret: ${cookie_secret}"
