#!/usr/bin/env bash
# run.sh - tests of the LAN entrypoint airgap/teknoir-airgap (DESIGN I-11) and
# its docs (I-15). Runs on a Linux host with docker; touches no cluster.
#
#   1. shellcheck -x -s bash on teknoir-airgap and these tests
#   2. doc lint: every ./teknoir-airgap command and flag in the docs exists
#   3. offline tests in docker.io/library/bash:3.2 (the macOS /bin/bash):
#      help, verify (tampering, unlisted files), version, doctor and status
#      with a stub ssh, up --local
#   4. integration: a Debian 13 "node" container with sshd and sudo (password
#      required) and a bash 3.2 "LAN host" container on an internal docker
#      network: host-key pinning, one-time sudo setup in a terminal,
#      every runner command on a node that never ran up (the live migration
#      order: backup, migrate), site config refresh, content-addressed
#      payload sync, kubeconfig replacement, credentials,
#      backup, trust, doctor, host key change, never-print check, up --local
#
# Usage: airgap/test/lan/run.sh [--no-integration] [--keep]
# shellcheck disable=SC2016  # single-quoted scripts run in the containers
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "${here}/../../.." && pwd)
integration=1 keep=0
for a in "$@"; do
  case ${a} in
    --no-integration) integration=0 ;;
    --keep) keep=1 ;;
    *) echo "usage: $0 [--no-integration] [--keep]" >&2; exit 2 ;;
  esac
done

work=$(mktemp -d "${TMPDIR:-/tmp}/teknoir-airgap-lantest.XXXXXX")
net=tkag-lantest-$$
node=tkag-lantest-node-$$
lan=tkag-lantest-lan-$$
subnet=172.31.250
node_ip=${subnet}.10
failures=0

cleanup() {
  if [ "${keep}" = 1 ]; then
    echo "kept: ${work}, containers ${node} ${lan}, network ${net}"
    return
  fi
  docker rm -f "${node}" "${lan}" >/dev/null 2>&1 || true
  docker network rm "${net}" >/dev/null 2>&1 || true
  # files created by root inside the containers
  docker run --rm -v "${work}:/w" docker.io/library/bash:3.2 sh -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
  rmdir "${work}" 2>/dev/null || true
}
trap cleanup EXIT

step() { printf '\n######## %s\n' "$*"; }
tally() {   # tally LOGFILE: add the FAIL lines of a test log to the failures
  local n
  n=$(grep -c '^FAIL ' "$1" || true)
  failures=$((failures + n))
}

step "shellcheck"
if shellcheck -x -s bash "${repo}/airgap/teknoir-airgap" "${here}"/*.sh "${here}"/stub/* "${here}"/fake/*; then
  echo "shellcheck: clean"
else
  failures=$((failures + 1))
fi

step "doc lint"
"${here}/doc-lint.sh" || failures=$((failures + 1))

step "offline tests under bash 3.2"
mkdir -p "${work}/list" "${work}/map" "${work}/build"
b_list=$("${here}/make-fake-bundle.sh" --out "${work}/list" --node-ip 10.0.0.1 --node teknoir@10.0.0.1)
b_map=$("${here}/make-fake-bundle.sh" --out "${work}/map" --node-ip 10.0.0.1 --node teknoir@10.0.0.1 --format map)
b_build=$("${here}/make-fake-bundle.sh" --out "${work}/build" --node-ip 10.0.0.1 --node teknoir@10.0.0.1 --format build)
docker run --rm -v "${repo}:/src:ro" -v "${work}:/work" docker.io/library/bash:3.2 \
  bash /src/airgap/test/lan/offline.sh /src "/work/list/$(basename "${b_list}")" "/work/map/$(basename "${b_map}")" "/work/build/$(basename "${b_build}")" \
  | tee "${work}/offline.log" | grep -v '^PASS ' || true
tally "${work}/offline.log"

if [ "${integration}" = 1 ]; then
  step "integration: real sshd node and bash 3.2 LAN host"
  docker build -q -t tkag-lantest-node -f "${here}/node.Dockerfile" "${here}" >/dev/null
  docker build -q -t tkag-lantest-lan -f "${here}/lan.Dockerfile" "${here}" >/dev/null
  mkdir -p "${work}/int" "${work}/keys"
  b=$("${here}/make-fake-bundle.sh" --out "${work}/int" --node-ip "${node_ip}" --node "teknoir@${node_ip}" --kubectl "$(command -v kubectl)")
  bb=/bundle
  ssh-keygen -q -t ed25519 -N '' -C lantest -f "${work}/keys/id_ed25519"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj '/CN=Teknoir LAN test CA' \
    -keyout "${work}/keys/ca.key" -out "${work}/keys/ca.crt" 2>/dev/null
  ca_b64=$(base64 -w0 "${work}/keys/ca.crt")
  key_b64=$(printf 's3cr3t-client-key' | base64 -w0)
  cat >"${work}/keys/k3s.yaml" <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${ca_b64}
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: default
  user:
    client-certificate-data: $(printf 'fake-client-cert' | base64 -w0)
    client-key-data: ${key_b64}
EOF
  docker network create --internal --subnet "${subnet}.0/24" "${net}" >/dev/null
  docker run -d --name "${node}" --hostname teknoir --network "${net}" --ip "${node_ip}" \
    -v "${b}:${bb}:ro" tkag-lantest-node >/dev/null
  docker run -d --name "${lan}" --network "${net}" --ip "${subnet}.20" \
    -v "${b}:${bb}:ro" -v "${repo}:/src:ro" -v "${work}:/work" tkag-lantest-lan sleep 3600 >/dev/null
  docker cp "${work}/keys/id_ed25519.pub" "${node}:/home/teknoir/.ssh/authorized_keys"
  docker exec "${node}" sh -c 'chown teknoir:teknoir /home/teknoir/.ssh/authorized_keys && chmod 600 /home/teknoir/.ssh/authorized_keys'
  docker cp "${work}/keys/ca.crt" "${node}:/etc/fake-k3s/ca.crt"
  docker cp "${work}/keys/k3s.yaml" "${node}:/etc/rancher/k3s/k3s.yaml"
  docker exec "${node}" chmod 600 /etc/rancher/k3s/k3s.yaml
  docker exec "${lan}" mkdir -p /root/.ssh
  docker cp "${work}/keys/id_ed25519" "${lan}:/root/.ssh/id_ed25519"
  docker exec "${lan}" chmod 600 /root/.ssh/id_ed25519
  fp() { docker exec "${node}" ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{ print $2 }'; }
  for _ in 1 2 3 4 5 6 7 8 9 10; do docker exec "${node}" test -f /etc/ssh/ssh_host_ed25519_key.pub && break; sleep 1; done
  FP=$(fp)

  phase() {
    docker exec -e B="${bb}" -e NODE_IP="${node_ip}" -e FP="${FP}" -e PW=teknoir-test-pw \
      -e TRANSCRIPT=/work/transcript.log "${lan}" bash /src/airgap/test/lan/integration.sh "$1" \
      | tee "${work}/phase-$1.log" | grep -v '^PASS ' || true
    tally "${work}/phase-$1.log"
  }
  node_check() {   # node_check DESCRIPTION CMD...: a check on the node container
    if docker exec "${node}" sh -c "$2"; then echo "PASS $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
  }
  pd=/var/lib/teknoir-airgap/bundles/$(basename "${b}" | sed 's/^teknoir-airgap-//')/node

  site=/var/lib/teknoir-airgap/site/teknoir-local.env

  phase first-use
  # The live migration runs backup and migrate before the first up
  # (docs/OPERATE.md section 14): every runner command must work on a node
  # without a site config, payload or sudoers file.
  phase before-up
  node_check "backup set up sudo before any up" 'test -f /etc/sudoers.d/teknoir-airgap'
  node_check "the site config on the node is the bundle's" "cmp -s ${bb}/site/teknoir-local.env ${site}"
  node_check "no converge ran" '! grep -q " converge " /var/log/teknoir-airgap-fake-runner.log'
  node_check "backup, migrate, credentials, rotate and status ran with the site config" \
    "for c in 'backup --export --take' 'migrate --site ${site} --dry-run' 'credentials keycloak-admin --site ${site}' 'rotate oauth2-proxy-cookie --site ${site}' 'admin-user --email first.admin@teknoir.ai --out ' 'status --site ${site}'; do grep -q \"uid=0 \$c\" /var/log/teknoir-airgap-fake-runner.log || exit 1; done"
  docker exec "${node}" sh -c "echo 'NODE_IP=10.9.9.9  # stale' >>${site}"
  phase site-refresh-credentials
  node_check "credentials replaced the stale site config" "cmp -s ${bb}/site/teknoir-local.env ${site}"
  docker exec "${node}" sh -c "echo 'NODE_IP=10.9.9.9  # stale' >>${site}"
  phase site-refresh-status
  node_check "status replaced the stale site config" "cmp -s ${bb}/site/teknoir-local.env ${site}"
  # back to a node that never saw teknoir-airgap (the pinned host key stays)
  docker exec "${node}" sh -c 'rm -rf /var/lib/teknoir-airgap /etc/sudoers.d/teknoir-airgap && : >/var/log/teknoir-airgap-fake-runner.log'

  phase sudo-setup
  node_check "sudoers file installed, mode 0440, NOPASSWD for teknoir" \
    'test "$(stat -c %a /etc/sudoers.d/teknoir-airgap)" = 440 && grep -qx "teknoir ALL=(root) NOPASSWD: ALL" /etc/sudoers.d/teknoir-airgap'
  node_check "payload is owned by root" "test \"\$(stat -c %u ${pd}/bin/teknoir-node)\" = 0"
  node_check "MANIFEST.yaml is next to the payload, where teknoir-node reads it" "cmp -s ${bb}/MANIFEST.yaml ${pd%/node}/MANIFEST.yaml"
  node_check "the runner ran as root with the converge arguments" \
    'grep -q "uid=0 converge --site /var/lib/teknoir-airgap/site/teknoir-local.env --lan-time [0-9]* --lan-user root$" /var/log/teknoir-airgap-fake-runner.log'
  phase idempotent
  docker exec "${node}" sh -c "printf x >>${pd}/images/fake-image/blob2 && touch ${pd}/stray-file"
  phase resend
  phase kubeconfig
  phase secrets
  phase passthrough
  node_check "rotate passes --i-know" 'grep -q "rotate oauth2-proxy-cookie --site /var/lib/teknoir-airgap/site/teknoir-local.env --i-know$" /var/log/teknoir-airgap-fake-runner.log'
  node_check "migrate passes --dry-run" 'grep -q "migrate --site /var/lib/teknoir-airgap/site/teknoir-local.env --dry-run$" /var/log/teknoir-airgap-fake-runner.log'
  node_check "migrate passes --undo NAME" 'grep -q "migrate --site /var/lib/teknoir-airgap/site/teknoir-local.env --undo teknoir-coredns-custom$" /var/log/teknoir-airgap-fake-runner.log'
  node_check "migrate passes --argo and --argo --dry-run" 'grep -q "migrate --site /var/lib/teknoir-airgap/site/teknoir-local.env --argo$" /var/log/teknoir-airgap-fake-runner.log && grep -q "migrate --site /var/lib/teknoir-airgap/site/teknoir-local.env --argo --dry-run$" /var/log/teknoir-airgap-fake-runner.log'
  node_check "migrate passes --keycloak-admin-password-stdin, and the password is not in the runner log" 'grep -q "migrate --site /var/lib/teknoir-airgap/site/teknoir-local.env --keycloak-admin-password-stdin$" /var/log/teknoir-airgap-fake-runner.log && ! grep -q kc-admin-s3cr3t /var/log/teknoir-airgap-fake-runner.log'
  node_check "up passes every converge flag in order" \
    'grep -q "converge --site /var/lib/teknoir-airgap/site/teknoir-local.env --lan-time [0-9]* --lan-user root --rollback --sync-clock --reapply istio --force-images --dry-run --extra-flag$" /var/log/teknoir-airgap-fake-runner.log'
  node_check "admin-user passes --email in lower case, --out in the private tmp dir, --site" \
    'grep -q "admin-user --email anders.aslund@teknoir.ai --out /var/lib/teknoir-airgap/tmp/admin-user\.[A-Za-z0-9]* --site /var/lib/teknoir-airgap/site/teknoir-local.env$" /var/log/teknoir-airgap-fake-runner.log'
  node_check "the node's tmp dir is root-only and empty after admin-user (also after a failure)" \
    'test "$(stat -c %U:%a /var/lib/teknoir-airgap/tmp)" = root:700 && test -z "$(ls -A /var/lib/teknoir-airgap/tmp)"'
  node_check "the state dir keeps mode 0755" 'test "$(stat -c %a /var/lib/teknoir-airgap)" = 755'
  phase status
  phase trust
  phase backup
  node_check "the encrypted export was removed from the node" 'test -z "$(ls -A /var/lib/teknoir-airgap/exports 2>/dev/null)"'

  step "node reinstall: new host key"
  docker exec "${node}" sh -c 'rm -f /etc/ssh/ssh_host_*'
  docker restart "${node}" >/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do docker exec "${node}" test -f /etc/ssh/ssh_host_ed25519_key.pub && break; sleep 1; done
  old=${FP}
  FP=$(fp)
  if [ "${FP}" != "${old}" ]; then echo "PASS the node has a new host key"; else echo "FAIL the host key did not change"; failures=$((failures + 1)); fi
  phase hostkey-changed

  step "up --local on the node (Debian bash and GNU tools)"
  if docker exec "${node}" bash "${bb}/teknoir-airgap" up --local >"${work}/local.log" 2>&1 \
     && grep -q "already has this bundle's payload" "${work}/local.log" && grep -q "fake converge" "${work}/local.log"; then
    echo "PASS up --local on the node"
  else
    echo "FAIL up --local on the node"; sed 's/^/    | /' "${work}/local.log" | tail -n 20; failures=$((failures + 1))
  fi

  step "never print a secret"
  for s in s3cr3t "${key_b64}" teknoir-test-pw; do
    n=$(grep -c -- "${s}" "${work}/transcript.log" || true)
    if [ "${n}" = 0 ]; then echo "PASS the LAN transcript never contains '${s}'"; else echo "FAIL the LAN transcript contains '${s}' ${n} times"; failures=$((failures + 1)); fi
  done
  n=$(docker exec "${lan}" sh -c 'cat /root/.teknoir-airgap/teknoir-local/logs/*.log' | grep -c 's3cr3t' || true)
  if [ "${n}" = 0 ]; then echo "PASS the LAN logs never contain a secret"; else echo "FAIL the LAN logs contain a secret ${n} times"; failures=$((failures + 1)); fi
fi

printf '\n######## total failures: %d\n' "${failures}"
[ "${failures}" -eq 0 ]
