#!/bin/sh
set -e

TEKNOIR_HOST="${TEKNOIR_HOST:-teknoir@teknoir.airgapped}"

# SSH identity: use $SSH_KEY if set, else auto-detect the node key in .secrets/
# (the node only accepts publickey auth).
SSH_KEY="${SSH_KEY:-}"
if [ -z "${SSH_KEY}" ] && [ -f ".secrets/teknoir.airgapped.id_rsa" ]; then
  SSH_KEY=".secrets/teknoir.airgapped.id_rsa"
fi

# ArgoCD needs the Teknoir Root CA in TWO independent trust paths, both injected
# at render time (teknoir-root-ca.crt is generated per-deployment and gitignored,
# so it cannot be hardcoded in values.yaml):
#   1. repo-server -> Harbor OCI login (helm registry login) verifies Harbor's
#      TLS with argocd-tls-certs-cm (configs.tls.certificates, keyed by the Harbor
#      host), NOT the node's containerd/OS trust. Missing it fails OCI login with
#      "x509: certificate signed by unknown authority" and app-of-apps stays Unknown.
#   2. argocd-server -> Keycloak OIDC discovery
#      (https://auth.teknoir.airgapped/.../.well-known/openid-configuration)
#      verifies with the oidc.config `rootCA` field. It does NOT consult
#      argocd-tls-certs-cm or the OS trust for this call, so the CA is embedded
#      into oidc.config (base: charts/argo/files/oidc.config).
CA_CRT_FILE="${CA_CRT_FILE:-teknoir-root-ca.crt}"
HARBOR_HOST="${HARBOR_HOST:-harbor.teknoir.airgapped}"
CA_KEY=$(echo "${HARBOR_HOST}" | sed 's/\./\\./g')
OIDC_BASE="charts/argo/files/oidc.config"

if [ -f "${CA_CRT_FILE}" ]; then
  # Build oidc.config with the CA embedded as `rootCA` (indented under the block
  # scalar) so argocd-server trusts Keycloak during OIDC discovery.
  OIDC_CONFIG_FILE="$(mktemp)"
  {
    cat "${OIDC_BASE}"
    echo "rootCA: |"
    sed 's/^/  /' "${CA_CRT_FILE}"
  } > "${OIDC_CONFIG_FILE}"
  helm template --namespace teknoir-system --values charts/argo/values.yaml \
    --set-file "argo-cd.configs.tls.certificates.${CA_KEY}=${CA_CRT_FILE}" \
    --set-file "argo-cd.configs.cm.oidc\.config=${OIDC_CONFIG_FILE}" \
    argo charts/argo --debug > teknoir-argo.yaml
  rm -f "${OIDC_CONFIG_FILE}"
else
  echo "WARNING: ${CA_CRT_FILE} not found — ArgoCD will not trust Harbor's or" \
       "Keycloak's CA; repo-server OCI login and Keycloak SSO login may fail" \
       "with x509 unknown authority." >&2
  helm template --namespace teknoir-system --values charts/argo/values.yaml \
    --set-file "argo-cd.configs.cm.oidc\.config=${OIDC_BASE}" \
    argo charts/argo --debug > teknoir-argo.yaml
fi

ssh ${SSH_KEY:+-i "${SSH_KEY}"} "${TEKNOIR_HOST}" \
  "sudo tee /opt/k3s/server/manifests/teknoir-argo.yaml >/dev/null" \
  < teknoir-argo.yaml
