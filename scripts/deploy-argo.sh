#!/bin/sh
set -e

TEKNOIR_HOST="${TEKNOIR_HOST:-teknoir@teknoir.airgapped}"

# SSH identity: use $SSH_KEY if set, else auto-detect the node key in .secrets/
# (the node only accepts publickey auth).
SSH_KEY="${SSH_KEY:-}"
if [ -z "${SSH_KEY}" ] && [ -f ".secrets/teknoir.airgapped.id_rsa" ]; then
  SSH_KEY=".secrets/teknoir.airgapped.id_rsa"
fi

# ArgoCD's repo-server verifies Harbor's TLS itself (helm registry login) using
# argocd-tls-certs-cm, not the node's containerd/OS trust. Inject the Teknoir
# Root CA (keyed by the Harbor host) so OCI login to harbor.teknoir.airgapped
# succeeds; without it the repo-server fails with "x509: certificate signed by
# unknown authority" and app-of-apps stays Unknown.
CA_CRT_FILE="${CA_CRT_FILE:-teknoir-root-ca.crt}"
HARBOR_HOST="${HARBOR_HOST:-harbor.teknoir.airgapped}"
CA_KEY=$(echo "${HARBOR_HOST}" | sed 's/\./\\./g')

if [ -f "${CA_CRT_FILE}" ]; then
  helm template --namespace teknoir-system --values charts/argo/values.yaml \
    --set-file "argo-cd.configs.tls.certificates.${CA_KEY}=${CA_CRT_FILE}" \
    argo charts/argo --debug > teknoir-argo.yaml
else
  echo "WARNING: ${CA_CRT_FILE} not found — ArgoCD will not trust Harbor's CA;" \
       "repo-server OCI login may fail with x509 unknown authority." >&2
  helm template --namespace teknoir-system --values charts/argo/values.yaml argo charts/argo --debug > teknoir-argo.yaml
fi

ssh ${SSH_KEY:+-i "${SSH_KEY}"} "${TEKNOIR_HOST}" \
  "sudo tee /opt/k3s/server/manifests/teknoir-argo.yaml >/dev/null" \
  < teknoir-argo.yaml
