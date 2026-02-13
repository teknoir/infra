#!/bin/sh
set -e

INFRA_MANIFEST=$(cat manifest-local.yaml)
ssh anders@rtx2000-pro-bw-se.teknoir bash -c "cat > /var/lib/rancher/k3s/server/manifests/teknoir-infra.yaml" <<< "${INFRA_MANIFEST}"
