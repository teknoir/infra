#!/usr/bin/env bash
# Test of scripts/gen-stunner-auth-secret.sh against a THROWAWAY local kube-apiserver + etcd (the
# envtest binaries). It never touches a real cluster: the apiserver listens on 127.0.0.1, the
# kubeconfig is a temp file and the script runs with KUBECONFIG pointing at it.
#   scripts/tests/gen-stunner-auth-secret-test.sh
# Needs envtest 1.30.0 (ENVTEST_DIR, default ~/.local/share/kubebuilder-envtest/k8s/1.30.0-linux-amd64).
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "${HERE}/.." && pwd)/gen-stunner-auth-secret.sh"
ENVTEST_DIR="${ENVTEST_DIR:-$HOME/.local/share/kubebuilder-envtest/k8s/1.30.0-linux-amd64}"
for b in etcd kube-apiserver kubectl; do
  [[ -x "${ENVTEST_DIR}/${b}" ]] || { echo "SKIP: ${ENVTEST_DIR}/${b} not found (setup-envtest use 1.30.0)"; exit 0; }
done
command -v openssl >/dev/null || { echo "missing tool: openssl" >&2; exit 1; }

TMP=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]:-}"; do wait "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT
free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
ETCD_PORT=$(free_port); ETCD_PEER=$(free_port); API_PORT=$(free_port)

fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

openssl genrsa -out "${TMP}/sa.key" 2048 2>/dev/null
openssl rsa -in "${TMP}/sa.key" -pubout -out "${TMP}/sa.pub" 2>/dev/null
echo "testtoken,admin,uid-admin,\"system:masters\"" >"${TMP}/tokens.csv"
"${ENVTEST_DIR}/etcd" --data-dir "${TMP}/etcd" --listen-client-urls "http://127.0.0.1:${ETCD_PORT}" \
  --advertise-client-urls "http://127.0.0.1:${ETCD_PORT}" --listen-peer-urls "http://127.0.0.1:${ETCD_PEER}" >"${TMP}/etcd.log" 2>&1 &
PIDS+=($!)
"${ENVTEST_DIR}/kube-apiserver" --etcd-servers "http://127.0.0.1:${ETCD_PORT}" --secure-port "${API_PORT}" \
  --bind-address 127.0.0.1 --cert-dir "${TMP}/certs" --token-auth-file "${TMP}/tokens.csv" \
  --authorization-mode=AlwaysAllow --service-cluster-ip-range 10.0.0.0/24 --service-account-issuer https://localhost \
  --service-account-key-file "${TMP}/sa.pub" --service-account-signing-key-file "${TMP}/sa.key" \
  --disable-admission-plugins ServiceAccount >"${TMP}/apiserver.log" 2>&1 &
PIDS+=($!)

export KUBECONFIG="${TMP}/kubeconfig"
K="${ENVTEST_DIR}/kubectl"
"$K" config set-cluster local --server "https://127.0.0.1:${API_PORT}" --insecure-skip-tls-verify=true >/dev/null
"$K" config set-credentials admin --token testtoken >/dev/null
"$K" config set-context test-stage --cluster local --user admin >/dev/null
"$K" config set-context test-prod-eks --cluster local --user admin >/dev/null
"$K" config use-context test-stage >/dev/null
# Put the envtest kubectl first so the script uses it (it is a plain kubectl binary).
export PATH="${ENVTEST_DIR}:${PATH}"
for _ in $(seq 1 60); do "$K" --context test-stage get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
"$K" --context test-stage get --raw /readyz >/dev/null 2>&1 || { echo "apiserver did not come up"; tail -20 "${TMP}/apiserver.log"; exit 1; }

kc() { "$K" --context test-stage "$@"; }
run() { "$SCRIPT" "$@" >"${TMP}/out" 2>&1; }

# --- argument handling: no cluster is reached
if "$SCRIPT" >"${TMP}/out" 2>&1; then bad "ran without --context"; else
  grep -q -- '--context is required' "${TMP}/out" && ok "refuses to run without --context (never uses the current context)" || bad "wrong message without --context"; fi
if [[ -n $(kc get ns stunner-system --ignore-not-found -o name) ]]; then bad "namespace created by a refused run"; else ok "a refused run changed nothing"; fi
if run --context test-prod-eks; then bad "ran against a production-looking context"; else
  grep -q 'looks like production' "${TMP}/out" && ok "refuses a production-looking context without --allow-production" || bad "wrong message for production context"; fi
if run --context nonexistent-context; then bad "ran against an unknown context"; else ok "an unknown context is an error (not read as 'absent')"; fi
if [[ -n $(kc get ns stunner-system --ignore-not-found -o name) ]]; then bad "namespace created by an unknown-context run"; fi

# --- dry run
run --context test-stage --dry-run && grep -q 'dry-run: would create namespace' "${TMP}/out" && ok "dry-run says what it would do" || bad "dry-run"
[[ -z $(kc get ns stunner-system --ignore-not-found -o name) ]] && ok "dry-run creates nothing" || bad "dry-run created the namespace"

# --- first run
run --context test-stage && ok "first run succeeds" || { cat "${TMP}/out"; bad "first run failed"; }
[[ $(kc get ns stunner-system -o jsonpath='{.metadata.labels.istio-injection}') == disabled ]] && ok "namespace created with istio-injection=disabled" || bad "namespace label"
[[ $(kc -n stunner-system get secret stunner-auth-secret -o go-template='{{index .data "type" | base64decode}}') == ephemeral ]] && ok "type=ephemeral" || bad "type key"
value=$(kc -n stunner-system get secret stunner-auth-secret -o go-template='{{index .data "secret" | base64decode}}')
[[ ${#value} -eq 64 ]] && [[ $(printf '%s' "$value" | base64 -d | wc -c) -eq 48 ]] && ok "secret is 48 random bytes in base64" || bad "secret shape (${#value} chars)"
[[ $(kc -n stunner-system get secret stunner-auth-secret -o jsonpath='{.type}') == Opaque ]] && ok "Secret type Opaque" || bad "Secret type"
[[ $(kc -n stunner-system get secret stunner-auth-secret -o jsonpath='{.data}' | python3 -I -c 'import json,sys; print(sorted(json.load(sys.stdin)))') == "['secret', 'type']" ]] && ok "exactly the keys type and secret" || bad "keys"
if grep -qF "$value" "${TMP}/out"; then bad "the secret value was printed"; else ok "the secret value is not printed (stdout and stderr)"; fi
if grep -qF "$(printf '%s' "$value" | base64 -w0)" "${TMP}/out"; then bad "the base64 of the secret was printed"; fi
rv1=$(kc -n stunner-system get secret stunner-auth-secret -o jsonpath='{.metadata.resourceVersion}')

# --- idempotent re-run
run --context test-stage && grep -q 'left unchanged' "${TMP}/out" && ok "second run reports 'left unchanged'" || { cat "${TMP}/out"; bad "second run"; }
[[ $(kc -n stunner-system get secret stunner-auth-secret -o jsonpath='{.metadata.resourceVersion}') == "$rv1" ]] && ok "second run did not touch the Secret (same resourceVersion)" || bad "second run changed the Secret"
[[ $(kc -n stunner-system get secret stunner-auth-secret -o go-template='{{index .data "secret" | base64decode}}') == "$value" ]] && ok "value unchanged" || bad "value changed"
grep -qF "$value" "${TMP}/out" && bad "re-run printed the secret"

# --- an existing Secret of the wrong shape is an error, not an overwrite
kc -n stunner-system create secret generic other-auth --from-literal=password=x >/dev/null
if run --context test-stage --name other-auth; then bad "accepted a Secret of the wrong shape"; else
  grep -q 'not a TURN-REST secret' "${TMP}/out" && ok "a Secret of the wrong shape is refused, not overwritten" || bad "wrong message for wrong shape"; fi
[[ $(kc -n stunner-system get secret other-auth -o jsonpath='{.data.password}') == "$(printf x | base64)" ]] && ok "the wrong-shape Secret is untouched" || bad "wrong-shape Secret changed"

# --- an existing namespace is not modified
kc create namespace custom-ns >/dev/null
run --context test-stage --namespace custom-ns && ok "works in an existing namespace" || bad "existing namespace"
[[ -z $(kc get ns custom-ns -o jsonpath='{.metadata.labels.istio-injection}') ]] && ok "an existing namespace's labels are not modified" || bad "existing namespace modified"
grep -q 'note: namespace custom-ns has istio-injection' "${TMP}/out" && ok "a note for an existing namespace in the mesh" || bad "no note"

# --- --allow-production gets past the guard (against the throwaway server)
run --context test-prod-eks --allow-production --namespace prod-guard && ok "--allow-production passes the guard" || bad "--allow-production"

echo
if [[ $fail -ne 0 ]]; then echo "tests FAILED"; exit 1; fi
echo "tests passed"
