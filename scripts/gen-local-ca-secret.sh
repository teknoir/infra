#!/usr/bin/env bash
set -euo pipefail

# gen-local-ca-secret.sh
# Generates the Teknoir Local Root CA (10y) and a pre-issued wildcard server
# certificate (1y) for the Istio gateway, and writes both as Kubernetes Secret
# manifests. Idempotent: an existing CA key/cert under .secrets/ca/ is reused;
# only the wildcard cert is re-issued.

DOMAIN="teknoir.airgapped"
CA_CN="Teknoir Local Root CA"
CA_DAYS=3650
WILDCARD_DAYS=365

# Working dir for key material (gitignored)
CA_DIR=".secrets/ca"
CA_KEY_FILE="${CA_DIR}/teknoir-root-ca.key"
CA_CRT_FILE="${CA_DIR}/teknoir-root-ca.crt"
WILDCARD_KEY_FILE="${CA_DIR}/wildcard.${DOMAIN}.key"
WILDCARD_CSR_FILE="${CA_DIR}/wildcard.${DOMAIN}.csr"
WILDCARD_CRT_FILE="${CA_DIR}/wildcard.${DOMAIN}.crt"

# Outputs
# Secret manifests live under .secrets/ (gitignored); the public CA cert stays
# at the repo root (bundled and distributed to nodes/browsers).
SECRETS_DIR=".secrets"
CA_MANIFEST_FILE="${SECRETS_DIR}/manifest-teknoir-ca-secret.yaml"
WILDCARD_MANIFEST_FILE="${SECRETS_DIR}/manifest-wildcard-tls-secret.yaml"
CA_CRT_OUT="teknoir-root-ca.crt"

CA_SECRET_NAME="teknoir-root-ca"
CA_NAMESPACE="cert-manager"
WILDCARD_SECRET_NAME="teknoir-local-wildcard-tls"
WILDCARD_NAMESPACE="istio-system"

b64() {
  base64 < "$1" | tr -d '\n'
}

mkdir -p "${CA_DIR}" "${SECRETS_DIR}"

# Root CA (reused if already present)
if [ -f "${CA_KEY_FILE}" ] && [ -f "${CA_CRT_FILE}" ]; then
  echo "Reusing existing CA key/cert in ${CA_DIR}"
else
  echo "Generating new Root CA (${CA_CN}, ${CA_DAYS} days)"
  openssl genrsa -out "${CA_KEY_FILE}" 4096
  openssl req -x509 -new -sha256 \
    -key "${CA_KEY_FILE}" \
    -out "${CA_CRT_FILE}" \
    -days "${CA_DAYS}" \
    -subj "/CN=${CA_CN}" \
    -config <(cat <<CONF
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no
[req_dn]
CN = ${CA_CN}
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CONF
)
fi

# Wildcard server certificate (always re-issued from the CA)
echo "Issuing wildcard certificate *.${DOMAIN} (${WILDCARD_DAYS} days)"
openssl genrsa -out "${WILDCARD_KEY_FILE}" 2048
openssl req -new -sha256 \
  -key "${WILDCARD_KEY_FILE}" \
  -out "${WILDCARD_CSR_FILE}" \
  -subj "/CN=*.${DOMAIN}"
openssl x509 -req -sha256 \
  -in "${WILDCARD_CSR_FILE}" \
  -CA "${CA_CRT_FILE}" \
  -CAkey "${CA_KEY_FILE}" \
  -CAcreateserial \
  -out "${WILDCARD_CRT_FILE}" \
  -days "${WILDCARD_DAYS}" \
  -extfile <(cat <<CONF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:*.${DOMAIN},DNS:${DOMAIN}
CONF
)

CA_CRT_B64=$(b64 "${CA_CRT_FILE}")
CA_KEY_B64=$(b64 "${CA_KEY_FILE}")
WILDCARD_CRT_B64=$(b64 "${WILDCARD_CRT_FILE}")
WILDCARD_KEY_B64=$(b64 "${WILDCARD_KEY_FILE}")

cat > "${CA_MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${CA_SECRET_NAME}
  namespace: ${CA_NAMESPACE}
type: kubernetes.io/tls
data:
  tls.crt: ${CA_CRT_B64}
  tls.key: ${CA_KEY_B64}
  ca.crt: ${CA_CRT_B64}
EOF

cat > "${WILDCARD_MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${WILDCARD_SECRET_NAME}
  namespace: ${WILDCARD_NAMESPACE}
type: kubernetes.io/tls
data:
  tls.crt: ${WILDCARD_CRT_B64}
  tls.key: ${WILDCARD_KEY_B64}
  ca.crt: ${CA_CRT_B64}
EOF

cp "${CA_CRT_FILE}" "${CA_CRT_OUT}"

echo "Wrote manifest to ${CA_MANIFEST_FILE}"
echo "Wrote manifest to ${WILDCARD_MANIFEST_FILE}"
echo "Wrote CA certificate to ${CA_CRT_OUT}"
echo ""
echo "Next steps:"
echo "  - Deploy both secrets with: scripts/deploy-secrets.sh"
echo "  - Distribute ${CA_CRT_OUT} to the K3s node (registries.yaml ca_file) and to operator laptops/browsers"
