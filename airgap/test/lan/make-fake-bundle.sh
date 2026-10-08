#!/usr/bin/env bash
# make-fake-bundle.sh - build a small bundle directory with the real
# teknoir-airgap entrypoint and fake node programs, for the LAN tests.
#
# Usage: make-fake-bundle.sh --out DIR --node-ip IP --node USER@HOST
#                            [--domain D] [--format list|map|build] [--kubectl FILE] [--docs DIR]
# Prints the bundle directory (DIR/teknoir-airgap-<bundleId>).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../../.." && pwd)
out='' node_ip='' node='' format=list kubectl='' docs=${repo}/docs/airgap
# a domain no resolver knows (vpro resolves teknoir.airgapped)
domain=teknoir.lantest
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=$2; shift ;;
    --node-ip) node_ip=$2; shift ;;
    --node) node=$2; shift ;;
    --domain) domain=$2; shift ;;
    --format) format=$2; shift ;;
    --kubectl) kubectl=$2; shift ;;
    --docs) docs=$2; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "${out}" ] || [ -z "${node_ip}" ] || [ -z "${node}" ]; then
  echo "--out, --node-ip and --node are required" >&2
  exit 2
fi

id=teknoir-local-aoa0.0.4-20261008-itest000-gtest000
b=${out}/teknoir-airgap-${id}
rm -rf "${b}"
mkdir -p "${b}"/{site,docs,node/bin,node/lib,node/site,node/images/fake-image,node/charts}

install -m 0755 "${repo}/airgap/teknoir-airgap" "${b}/teknoir-airgap"
cat >"${b}/site/teknoir-local.env" <<EOF
# test site
TEKNOIR_ENV=teknoir-local
TEKNOIR_DOMAIN=${domain}
NODE_IP=${node_ip}
NODE=${node}
TEKNOIR_HOSTNAMES="harbor argocd auth keycloak grafana"
TIME_SOURCE=
K3S_DATA_DIR=/opt/k3s
EOF
cp "${b}/site/teknoir-local.env" "${b}/node/site/teknoir-local.env"
for f in "${docs}"/*.md; do [ -f "${f}" ] && cp "${f}" "${b}/docs/"; done
if [ -n "${kubectl}" ]; then
  mkdir -p "${b}/tools/linux-amd64"
  install -m 0755 "${kubectl}" "${b}/tools/linux-amd64/kubectl"
fi
install -m 0755 "${here}/fake/teknoir-node" "${b}/node/bin/teknoir-node"
install -m 0755 "${here}/fake/age" "${b}/node/bin/age"
printf '# fake common.sh\n' >"${b}/node/lib/common.sh"
printf 'app-of-apps 0.0.4\n' >"${b}/node/charts/pins.txt"
head -c 1048576 /dev/urandom >"${b}/node/images/fake-image/blob1"
head -c 524288 /dev/urandom >"${b}/node/images/fake-image/blob2"
printf 'docker.io/library/fake:1@sha256:%064d fake-image\n' 0 >"${b}/node/images/images.lock"

(cd "${b}/node" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum >"${out}/SHA256SUMS.tmp")
mv "${out}/SHA256SUMS.tmp" "${b}/node/SHA256SUMS"

{
  if [ "${format}" = build ]; then
    # the shape airgap/build/make-bundle.sh writes: header, nested sections, quoted image keys
    echo "# Teknoir airgap bundle manifest. Written by airgap/build/make-bundle.sh;"
    echo "# teknoir-airgap verifies every file below before it contacts the node."
    echo "apiVersion: teknoir.org/v1"
    echo "kind: AirgapBundleManifest"
  fi
  echo "bundleId: ${id}"
  echo "env: teknoir-local"
  echo "domain: ${domain}"
  echo 'createdAt: "2026-10-08T12:00:00Z"'
  echo "infraCommit: test000"
  echo "gitopsCommit: test000"
  echo "dirty: false"
  echo "appOfAppsVersion: 0.0.4"
  echo "k3sVersion: v1.33.5+k3s1"
  if [ "${format}" = build ]; then
    echo "brokenAppOfApps: [0.0.1, 0.0.2]"
    echo "platforms: [linux/amd64]"
    echo "tools:"
    echo "  helm: v4.2.4"
    echo "  yq: v4.47.1 # build only"
    echo "charts:"
    echo "  app-of-apps: 0.0.4"
    echo "oneshot:"
    echo "  - tier: istio"
    echo "    chart: istio"
    echo "    renderSha256: $(printf '%064d' 7)"
    echo "images:"
    echo "  \"docker.io/library/fake:1\":"
    echo "    digest: sha256:$(printf '%064d' 0)"
    echo "    slug: fake-image"
  else
    echo "images:"
    echo "  docker.io/library/fake:1: sha256:$(printf '%064d' 0)"
  fi
  echo "files:"
  (cd "${b}" && find . -type f ! -name MANIFEST.yaml | sed 's|^\./||' | LC_ALL=C sort) | while IFS= read -r p; do
    h=$(sha256sum "${b}/${p}" | cut -d' ' -f1)
    if [ "${format}" = list ]; then
      printf '  - path: %s\n    sha256: %s\n' "${p}" "${h}"
    else
      printf '  %s: %s\n' "${p}" "${h}"
    fi
  done
} >"${b}/MANIFEST.yaml"
echo "${b}"
