#!/bin/sh
set -e

MANIFEST_PATH=manifest-local.yaml

ssh anders@rtx2000-pro-bw-se.teknoir \
  "sudo tee /var/lib/rancher/k3s/server/manifests/teknoir-infra.yaml >/dev/null" \
  < "${MANIFEST_PATH}"
