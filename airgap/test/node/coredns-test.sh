#!/usr/bin/env bash
# coredns-test.sh: the coredns-custom server block, rendered by the node
# runner's render_template, served by the CoreDNS version of the live k3s
# (rancher/mirrored-coredns-coredns 1.12.3, pinned by digest) in a throwaway
# container, and queried with dig. Proves what the unit test's golden cannot:
#   - the apex, the platform names and teamspace names such as
#     mqtt-teknoir-default.<domain> (any letter case) answer NODE_IP;
#   - AAAA answers NOERROR without records (NODATA), so musl and glibc
#     resolvers do not fail the lookup;
#   - deeper names (a search-path expansion such as github.com.<domain>) keep
#     the hosts plugin's answer (SERVFAIL), as before r5;
#   - CoreDNS logs no plugin error for any of these queries.
#
# Usage: airgap/test/node/coredns-test.sh    (needs docker and dig; one image
# pull on the first run; the container is stopped and removed afterwards)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${TEKNOIR_NODE_SRC:-${HERE}/../../node}" && pwd)"
IMAGE="${COREDNS_IMAGE:-docker.io/rancher/mirrored-coredns-coredns:1.12.3@sha256:1391544c978029fcddc65068f6ad67f396e55585b664ecccd7fefba029b9b706}"
PORT="${COREDNS_TEST_PORT:-15353}"
NAME="tk-coredns-test-$$"

for c in docker dig; do
  command -v "${c}" >/dev/null || { echo "SKIP: ${c} not installed"; exit 0; }
done

T="$(mktemp -d)"
cleanup() {
  docker stop "${NAME}" >/dev/null 2>&1 || true
  rm -rf -- "${T}"
}
trap cleanup EXIT
PASS=0 FAIL=0
check() { local d="$1"; shift; if "$@"; then PASS=$((PASS + 1)); echo "ok   ${d}"; else FAIL=$((FAIL + 1)); echo "FAIL ${d}"; fi; }

mkdir -p "${T}/custom"
NODE_ROOT="${SRC}" TEKNOIR_DOMAIN=teknoir.airgapped NODE_IP=192.168.5.181 \
  TEKNOIR_HOSTNAMES="harbor argocd auth keycloak grafana" bash -c '
    set -euo pipefail
    source "${NODE_ROOT}/lib/common.sh"
    render_template "${NODE_ROOT}/templates/coredns-custom.yaml.tmpl"' > "${T}/coredns-custom.yaml"
awk '/teknoir.server: \|/{f=1; next} f {sub(/^    /, ""); print}' "${T}/coredns-custom.yaml" > "${T}/custom/teknoir.server"
# the root block of k3s's Corefile, minus kubernetes and forward
printf '.:53 {\n    errors\n}\nimport /custom/*.server\n' > "${T}/custom/Corefile"
chmod -R a+rX "${T}/custom"

docker run --rm -d --name "${NAME}" -p "127.0.0.1:${PORT}:53/udp" -v "${T}/custom:/custom:ro" \
  "${IMAGE}" -conf /custom/Corefile >/dev/null
for _ in $(seq 1 20); do
  dig +time=1 +tries=1 @127.0.0.1 -p "${PORT}" teknoir.airgapped A >/dev/null 2>&1 && break
  sleep 0.5
done

q() {
  # q <name> <type> - "<rcode> <answers...>"
  dig +time=2 +tries=1 @127.0.0.1 -p "${PORT}" "$1" "$2" |
    awk '/status:/ { s = $6; sub(/,$/, "", s) } /^[^;]/ && $4 == T { a = a " " $NF } END { print s a }' T="$2"
}

for n in teknoir.airgapped harbor.teknoir.airgapped keycloak.teknoir.airgapped \
         mqtt-teknoir-default.teknoir.airgapped deadend-teknoir-default.teknoir.airgapped \
         emqx-dashboard-teknoir-default.teknoir.airgapped MQTT-Teknoir-Default.teknoir.airgapped; do
  check "${n} A -> NODE_IP" [ "$(q "${n}" A)" == "NOERROR 192.168.5.181" ]
done
for n in harbor.teknoir.airgapped mqtt-teknoir-default.teknoir.airgapped; do
  check "${n} AAAA -> NODATA" [ "$(q "${n}" AAAA)" == "NOERROR" ]
done
for n in github.com.teknoir.airgapped a.b.teknoir.airgapped; do
  check "${n} A (two labels below the domain) keeps SERVFAIL" [ "$(q "${n}" A)" == "SERVFAIL" ]
done
check "harbor.teknoir.airgapped MX (a hosts name) -> NODATA" [ "$(q harbor.teknoir.airgapped MX)" == "NOERROR" ]
logs="$(docker logs "${NAME}" 2>&1)"
check "CoreDNS loaded the block and logged no plugin error" \
  bash -c "grep -q 'teknoir.airgapped.:53' <<<\"\$1\" && ! grep -q 'ERROR' <<<\"\$1\"" _ "${logs}"

echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
