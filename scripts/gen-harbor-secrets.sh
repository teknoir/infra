#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="manifest-harbor-secret.yaml"
NAMESPACE="teknoir-system"
SECRET_NAME="harbor-secret"

# Random string generator function
gen_rand() {
  local len="${1:-24}"
  python3 - <<PY
import os,base64
print(base64.b64encode(os.urandom($len)).decode()[:$len])
PY
}

admin_password=$(gen_rand 12)
secret_key=$(gen_rand 16)
core_secret=$(gen_rand 16)
xsrf_key=$(gen_rand 32)
jobservice_secret=$(gen_rand 16)
registry_secret=$(gen_rand 16)
# database_password and redis_password if we ever need them for external or if chart supports them for internal
database_password=$(gen_rand 24)
redis_password=$(gen_rand 24)

cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  HARBOR_ADMIN_PASSWORD: "${admin_password}"
  secretKey: "${secret_key}"
  secret: "${core_secret}"
  CSRF_KEY: "${xsrf_key}"
  JOBSERVICE_SECRET: "${jobservice_secret}"
  REGISTRY_HTTP_SECRET: "${registry_secret}"
  database-password: "${database_password}"
  redis-password: "${redis_password}"
EOF

echo "Wrote manifest to ${MANIFEST_FILE}"
echo "Harbor Admin Password: ${admin_password}"
echo "Secret Key: ${secret_key}"
