#!/usr/bin/env bash
# Creates the STUNner TURN shared secret Secret/stunner-system/stunner-auth-secret, if absent.
#
#   scripts/gen-stunner-auth-secret.sh --context <kubectl-context> [--namespace stunner-system]
#                                      [--name stunner-auth-secret] [--allow-production] [--dry-run]
#
# The Secret holds the TURN-REST (ephemeral) shared secret of the STUNner gateway
# (platform-applications-gitops charts/stunner, GatewayConfig authRef) that wg-hub signs TURN
# credentials with: stringData type=ephemeral, secret=<48 random bytes, base64>. It is NOT in
# Git. Unlike the other gen-*.sh scripts it does not write a manifest file and never prints the
# value: it applies the Secret straight to the cluster, from a pipe (the value is never in
# argv, the environment of a child process or a file).
#
#  - --context is REQUIRED: this script never uses the current kubectl context.
#  - Idempotent: an existing Secret is left alone (its value is never printed or changed), so
#    re-running is safe. A wrong shape (no `type: ephemeral` / no `secret`) is an error, not
#    an overwrite. Rotating the secret deletes it by hand and resets every WireGuard tunnel
#    (credentials minted from the old value stop working; clients re-create their sessions).
#  - The namespace is created if missing, labelled istio-injection=disabled (stunnerd runs
#    outside the mesh). An existing namespace is not modified.
#  - A production-looking context (eks, prod, teknoir-online) needs --allow-production.
#    Production changes go through the people who own it; this script is for staging.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

CONTEXT=""
NAMESPACE="stunner-system"
SECRET_NAME="stunner-auth-secret"
ALLOW_PROD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT="${2:-}"; shift 2 || { echo "--context needs a value" >&2; exit 2; } ;;
    --context=*) CONTEXT="${1#*=}"; shift ;;
    --namespace) NAMESPACE="${2:-}"; shift 2 || { echo "--namespace needs a value" >&2; exit 2; } ;;
    --name) SECRET_NAME="${2:-}"; shift 2 || { echo "--name needs a value" >&2; exit 2; } ;;
    --allow-production) ALLOW_PROD=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "${CONTEXT}" ]; then
  echo "error: --context is required (this script never uses the current kubectl context)" >&2
  usage >&2
  exit 2
fi
case "${CONTEXT}" in
  *eks*|*prod*|*teknoir-online*)
    if [ "${ALLOW_PROD}" -ne 1 ]; then
      echo "error: context '${CONTEXT}' looks like production; pass --allow-production only when that was explicitly decided" >&2
      exit 2
    fi
    ;;
esac
for tool in kubectl openssl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "error: ${tool} is required" >&2
    exit 1
  fi
done

kc() { kubectl --context "${CONTEXT}" "$@"; }

# A failing kubectl (no such context, forbidden, unreachable) must never be read as "absent":
# --ignore-not-found only hides NotFound, and set -e stops the script on any other error.
ns_existing="$(kc get namespace "${NAMESPACE}" --ignore-not-found -o name)"
if [ -z "${ns_existing}" ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "dry-run: would create namespace ${NAMESPACE} (label istio-injection=disabled) in context ${CONTEXT}"
  else
    printf '%s\n' \
      'apiVersion: v1' 'kind: Namespace' 'metadata:' "  name: ${NAMESPACE}" \
      '  labels:' '    istio-injection: disabled' |
      kc create -f - >/dev/null
    echo "created namespace ${NAMESPACE} (istio-injection=disabled) in context ${CONTEXT}"
  fi
else
  injection="$(kc get namespace "${NAMESPACE}" -o jsonpath='{.metadata.labels.istio-injection}')"
  if [ "${injection}" != "disabled" ]; then
    echo "note: namespace ${NAMESPACE} has istio-injection='${injection}'; the Argo CD stunner Application sets it to disabled" >&2
  fi
fi

existing="$(kc -n "${NAMESPACE}" get secret "${SECRET_NAME}" --ignore-not-found -o name)"
if [ -n "${existing}" ]; then
  # Shape check only; the value is neither read nor printed.
  shape="$(kc -n "${NAMESPACE}" get secret "${SECRET_NAME}" \
    -o go-template='{{with index .data "type"}}{{. | base64decode}}{{end}}|{{if index .data "secret"}}secret{{end}}')"
  if [ "${shape}" != "ephemeral|secret" ]; then
    echo "error: ${NAMESPACE}/${SECRET_NAME} exists but is not a TURN-REST secret (need type=ephemeral and a non-empty secret); not touching it" >&2
    exit 1
  fi
  echo "secret ${NAMESPACE}/${SECRET_NAME} already exists in context ${CONTEXT}; left unchanged"
  exit 0
fi

if [ "${DRY_RUN}" -eq 1 ]; then
  echo "dry-run: would create secret ${NAMESPACE}/${SECRET_NAME} (type=ephemeral, secret=<48 random bytes>) in context ${CONTEXT}"
  exit 0
fi

# 48 random bytes, base64 (64 characters, no newline). The Secret goes to kubectl on stdin only.
secret="$(openssl rand -base64 48 | tr -d '\n')"
if [ "${#secret}" -ne 64 ]; then
  echo "error: could not generate the secret" >&2
  exit 1
fi
set +e
out="$(printf '%s\n' \
  'apiVersion: v1' 'kind: Secret' 'metadata:' "  name: ${SECRET_NAME}" "  namespace: ${NAMESPACE}" \
  '  labels:' '    app.kubernetes.io/managed-by: gen-stunner-auth-secret.sh' \
  'type: Opaque' 'stringData:' '  type: ephemeral' "  secret: \"${secret}\"" |
  kc create -f - 2>&1)"
rc=$?
set -e
unset secret
if [ "${rc}" -ne 0 ]; then
  # Lost a race with another run: fine. Anything else is an error (the message holds no secret).
  if printf '%s' "${out}" | grep -q 'AlreadyExists'; then
    echo "secret ${NAMESPACE}/${SECRET_NAME} was created concurrently; left unchanged"
    exit 0
  fi
  printf '%s\n' "${out}" >&2
  exit 1
fi
echo "created secret ${NAMESPACE}/${SECRET_NAME} (type=ephemeral, 48 random bytes) in context ${CONTEXT}"
echo "Rotating it resets every WireGuard tunnel: delete the Secret, re-run this script, restart the wg-hub."
