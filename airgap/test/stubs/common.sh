# shellcheck shell=bash
# TEST STUB of airgap/node/lib/common.sh (contract #3 of docs/airgap/DESIGN.md).
#
# The real common.sh is written by another implementer. This stub provides
# only the API the node phase libraries are written against, with the same
# semantics, so lib/{oneshot,harbor,migrate,admin}.sh can be tested on k3d
# before the real runner exists:
#   log/warn/die, DRY_RUN, run, KUBECTL, kc, in_cluster, apply_ssa, wait_for,
#   changed/summary, sha256_file, secret_value, NODE_ROOT, STATE_DIR, site vars.
# Never source it on a node.

DRY_RUN="${DRY_RUN:-0}"
KUBECTL="${KUBECTL:-k3s kubectl}"
STATE_DIR="${STATE_DIR:-/var/lib/teknoir-airgap}"
STUB_CHANGES=()

log()  { printf '[teknoir-node] %s\n' "$*" >&2; }
warn() { printf '[teknoir-node] WARN: %s\n' "$*" >&2; }
die()  { printf '[teknoir-node] ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

kc() {
  # word splitting of KUBECTL is intended ("k3s kubectl", "kubectl --context X")
  # shellcheck disable=SC2086
  ${KUBECTL} "$@"
}

in_cluster() {
  # in_cluster <resource> <name> [namespace] — 0 exists, 1 absent, dies on errors
  local out
  if [[ -n "${3:-}" ]]; then
    out="$(kc get "$1" "$2" -n "$3" --ignore-not-found -o name)" || die "cannot check $1 $3/$2"
  else
    out="$(kc get "$1" "$2" --ignore-not-found -o name)" || die "cannot check $1 $2"
  fi
  [[ -n "${out}" ]]
}

apply_ssa() {
  local src="${1:--}" manager="${2:-teknoir-bootstrap}"
  run kc apply --server-side --field-manager="${manager}" --force-conflicts -f "${src}"
}

wait_for() {
  # wait_for <description> <timeout-seconds> <cmd...>
  local desc="$1" timeout="$2" deadline
  shift 2
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] would wait for ${desc} (up to ${timeout}s)"
    return 0
  fi
  deadline=$(( $(date +%s) + timeout ))
  until "$@"; do
    (( $(date +%s) < deadline )) || die "timed out after ${timeout}s waiting for ${desc}"
    sleep "${STUB_WAIT_INTERVAL:-3}"
  done
}

changed() {
  STUB_CHANGES+=("$*")
  log "changed: $*"
}

summary() {
  log "summary: ${#STUB_CHANGES[@]} change(s)"
  local c
  for c in ${STUB_CHANGES[@]+"${STUB_CHANGES[@]}"}; do
    log "  - ${c}"
  done
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

secret_value() {
  # secret_value <ns> <name> <key> — decoded value on stdout, for capture only
  local b64
  b64="$(kc -n "$1" get secret "$2" -o json | jq -r --arg k "$3" '.data[$k] // empty')" \
    || die "cannot read Secret $1/$2"
  [[ -n "${b64}" ]] || die "Secret $1/$2 has no key $3"
  printf '%s' "${b64}" | base64 -d
}
