#!/usr/bin/env bash
set -euo pipefail

# Colors for better readability
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Teknoir Backstage Secrets – K8s Manifest Generator         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "This script will create a Kubernetes Secret manifest on the remote"
echo -e "k3s host. The secret will be deployed to the ${GREEN}teknoir-system${NC} namespace"
echo -e "and provides the following environment variables to the Backstage deployment:"
echo ""
echo -e "  • ${YELLOW}KEYCLOAK_REALM${NC}         – The Keycloak realm name"
echo -e "  • ${YELLOW}KEYCLOAK_CLIENTID${NC}      – The Keycloak client ID"
echo -e "  • ${YELLOW}KEYCLOAK_CLIENTSECRET${NC}  – The Keycloak client secret"
echo ""
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
echo ""

# --- Collect values ---

read -rp "$(echo -e "${GREEN}Enter KEYCLOAK_REALM: ${NC}")" KEYCLOAK_REALM
if [[ -z "$KEYCLOAK_REALM" ]]; then
  echo -e "${RED}Error: KEYCLOAK_REALM cannot be empty.${NC}" >&2
  exit 1
fi

read -rp "$(echo -e "${GREEN}Enter KEYCLOAK_CLIENTID: ${NC}")" KEYCLOAK_CLIENTID
if [[ -z "$KEYCLOAK_CLIENTID" ]]; then
  echo -e "${RED}Error: KEYCLOAK_CLIENTID cannot be empty.${NC}" >&2
  exit 1
fi

read -rsp "$(echo -e "${GREEN}Enter KEYCLOAK_CLIENTSECRET (input hidden): ${NC}")" KEYCLOAK_CLIENTSECRET
echo "" # newline after hidden input
if [[ -z "$KEYCLOAK_CLIENTSECRET" ]]; then
  echo -e "${RED}Error: KEYCLOAK_CLIENTSECRET cannot be empty.${NC}" >&2
  exit 1
fi

# --- Base64-encode the values ---

B64_REALM=$(echo -n "$KEYCLOAK_REALM" | base64)
B64_CLIENTID=$(echo -n "$KEYCLOAK_CLIENTID" | base64)
B64_CLIENTSECRET=$(echo -n "$KEYCLOAK_CLIENTSECRET" | base64)

# --- Show summary ---

echo ""
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Review the values before deploying:${NC}"
echo ""
echo -e "  KEYCLOAK_REALM ........... ${GREEN}${KEYCLOAK_REALM}${NC}"
echo -e "  KEYCLOAK_CLIENTID ........ ${GREEN}${KEYCLOAK_CLIENTID}${NC}"
echo -e "  KEYCLOAK_CLIENTSECRET .... ${GREEN}(hidden)${NC}"
echo ""
echo -e "  Remote host: ${CYAN}anders@r415${NC}"
echo -e "  Manifest path: ${CYAN}/opt/k3s/server/manifests/teknoir-backstage-keycloak-secrets.yaml${NC}"
echo ""

read -rp "$(echo -e "${YELLOW}Proceed? [y/N]: ${NC}")" CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "${RED}Aborted.${NC}"
  exit 0
fi

# --- Deploy the manifest ---

echo ""
echo -e "${CYAN}Deploying secret manifest to remote host...${NC}"

cat <<EOF | ssh anders@r415 "sudo tee /opt/k3s/server/manifests/teknoir-backstage-keycloak-secrets.yaml >/dev/null"
apiVersion: v1
kind: Secret
metadata:
  name: backstage-keycloak-secrets
  namespace: teknoir-system
type: Opaque
data:
  KEYCLOAK_REALM: ${B64_REALM}
  KEYCLOAK_CLIENTID: ${B64_CLIENTID}
  KEYCLOAK_CLIENTSECRET: ${B64_CLIENTSECRET}
EOF

echo ""
echo -e "${GREEN}✔ Secret manifest deployed successfully!${NC}"
echo -e "  k3s will automatically apply it from the manifests directory."
echo ""