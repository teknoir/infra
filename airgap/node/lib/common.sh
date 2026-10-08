# shellcheck shell=bash
# Globals defined here are used by the other libraries:
# shellcheck disable=SC2034
# common.sh: shared framework for teknoir-node (sourced by bin/teknoir-node,
# never executed). Contract: docs/airgap/DESIGN.md I-05 and the shared
# contract #3 of the redesign.
#
# What every phase library can rely on (set before any phase runs):
#   NODE_ROOT          the node/ payload dir (bin/ lib/ templates/ k3s/ ...)
#   STATE_DIR          /var/lib/teknoir-airgap (durable node state)
#   DRY_RUN            1 = read-only; mutations only print what they would do
#   KUBECTL            "k3s kubectl" (tests: "kubectl --context k3d-x")
#   site variables     TEKNOIR_ENV TEKNOIR_DOMAIN NODE_IP NODE
#                      TEKNOIR_HOSTNAMES TIME_SOURCE K3S_DATA_DIR, plus the
#                      derived HARBOR_HOST (harbor.<domain>)
#   bundle variables   BUNDLE_ID APP_OF_APPS_VERSION MANIFEST_SHA256
#                      INFRA_COMMIT GITOPS_COMMIT (load_bundle_info)
#   converge options   ROLLBACK REAPPLY_TIERS FORCE_IMAGES LAN_TIME LAN_USER
#   tools              JQ HELM CRANE AGE (bundled linux-amd64 binaries),
#                      K3S_BIN (/usr/local/bin/k3s)
#
# Never-print discipline: no `set -x` anywhere; secret values live only in
# shell variables, private tmpfs files and pipes. Read them with read_secret
# (marks the value for the leak check at exit) or capture secret_value. Never
# pass a secret value as a command-line argument or to log/warn/die. Mark only
# generated or credential values: a public literal stored next to them (a user
# name such as "keycloak") also appears in ordinary log lines and would fail
# the leak check; read it with secret_value.
#
# Test-only knob: TEKNOIR_HOST_ROOT prefixes every host path (/etc, /opt,
# /var, /run, /usr/local) so the host phase can run in a sandbox directory
# with stub binaries. It also lifts the root requirement. Never set it on a
# real node.

if [[ -n "${TEKNOIR_COMMON_SOURCED:-}" ]]; then
  return 0
fi
TEKNOIR_COMMON_SOURCED=1

# bash 5.2 expands '&' in ${var//pat/rep} replacements; templates and values
# must be substituted literally.
shopt -u patsub_replacement 2>/dev/null || true
# A failure inside $(...) must fail the substitution, as it does elsewhere.
shopt -s inherit_errexit

: "${NODE_ROOT:?NODE_ROOT must be set before sourcing common.sh}"

HOST_ROOT="${TEKNOIR_HOST_ROOT:-}"
STATE_DIR="${STATE_DIR:-${HOST_ROOT}/var/lib/teknoir-airgap}"
LOG_DIR="${TEKNOIR_LOG_DIR:-${HOST_ROOT}/var/log/teknoir-airgap}"
LOCK_FILE="${TEKNOIR_LOCK_FILE:-${HOST_ROOT}/run/teknoir-airgap.lock}"
KUBECTL="${KUBECTL:-k3s kubectl}"
DRY_RUN="${DRY_RUN:-0}"
K3S_BIN="${HOST_ROOT}/usr/local/bin/k3s"
K3S_DATA_DIR="${K3S_DATA_DIR:-/opt/k3s}"
WAIT_INTERVAL="${WAIT_INTERVAL:-5}"

ROLLBACK="${ROLLBACK:-0}"
REAPPLY_TIERS="${REAPPLY_TIERS:-}"
FORCE_IMAGES="${FORCE_IMAGES:-0}"
LAN_TIME="${LAN_TIME:-}"
LAN_USER="${LAN_USER:-}"

_bundled_or_path() {
  # _bundled_or_path <name> - the bundled linux-amd64 tool, else the one on PATH
  if [[ -x "${NODE_ROOT}/bin/$1" ]]; then
    printf '%s' "${NODE_ROOT}/bin/$1"
  else
    command -v "$1" 2>/dev/null || printf '%s' "$1"
  fi
}
JQ="${JQ:-$(_bundled_or_path jq)}"
HELM="${HELM:-$(_bundled_or_path helm)}"
CRANE="${CRANE:-$(_bundled_or_path crane)}"
AGE="${AGE:-$(_bundled_or_path age)}"

CHANGES=()
_SENSITIVE=()
_AT_EXIT=()
WORK_DIR=""
FILE_CHANGED=0

# ---------------------------------------------------------------------------
# Logging. Everything human-readable goes to stderr; stdout is reserved for
# data (a credential, a backup stream, a path) in the commands that emit one.
# ---------------------------------------------------------------------------
log()  { printf '%s [teknoir-node] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '%s [teknoir-node] WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf '%s [teknoir-node] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

dry_run() { [[ "${DRY_RUN}" == "1" ]]; }

run() {
  # run <cmd...> - execute a mutating command; in dry-run print it instead.
  # Never pass secret values as arguments (they would be printed here).
  if dry_run; then
    log "[dry-run] would run: $*"
    return 0
  fi
  "$@"
}

changed() {
  # changed <description> - record a change (or, in dry-run, a would-change)
  # for the end-of-run summary.
  if dry_run; then
    CHANGES+=("would: $*")
    log "[dry-run] would change: $*"
  else
    CHANGES+=("$*")
    log "changed: $*"
  fi
}

summary() {
  local n="${#CHANGES[@]}" c
  if dry_run; then
    log "summary (dry-run): ${n} change(s) would be made"
  elif (( n == 0 )); then
    log "summary: 0 changes"
  else
    log "summary: ${n} change(s)"
  fi
  for c in ${CHANGES[@]+"${CHANGES[@]}"}; do
    log "  - ${c}"
  done
}

at_exit() {
  # at_exit <command string> - run at exit (LIFO), also after die. The string
  # is eval'd: quote paths with printf %q.
  _AT_EXIT+=("$1")
}

run_at_exit() {
  local i
  for (( i = ${#_AT_EXIT[@]} - 1; i >= 0; i-- )); do
    eval "${_AT_EXIT[i]}" || true
  done
  _AT_EXIT=()
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    find "${WORK_DIR}" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "${WORK_DIR}"
  fi
}

ensure_work_dir() {
  # ensure_work_dir - create WORK_DIR, this run's private (0700) scratch dir,
  # on tmpfs when possible; its files are shredded and it is removed at exit.
  # Call it in the main shell (not inside $(...)), so the exit handler knows
  # the path.
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] && return 0
  local base
  for base in /dev/shm "${TMPDIR:-/tmp}"; do
    if [[ -d "${base}" && -w "${base}" ]]; then
      WORK_DIR="$(umask 077 && mktemp -d "${base}/teknoir-node.XXXXXX")" && break
    fi
  done
  [[ -n "${WORK_DIR}" ]] || die "cannot create a private scratch directory"
  chmod 0700 "${WORK_DIR}"
}

mark_sensitive() {
  # mark_sensitive <value> - remember a secret value so the exit-time leak
  # check can prove it never reached the log.
  [[ -n "${1:-}" ]] && _SENSITIVE+=("$1")
  return 0
}

leak_check() {
  # leak_check <log-file> - fail when the log holds any remembered secret
  # value (values shorter than 8 characters are too ambiguous to check) or a
  # private key. Values go to grep through a pipe, never through argv.
  local logf="$1"
  [[ -f "${logf}" ]] || return 0
  if grep -q 'PRIVATE KEY' "${logf}"; then
    printf '%s [teknoir-node] ERROR: leak check: %s contains a private key\n' "$(date -u +%H:%M:%S)" "${logf}" >&2
    return 1
  fi
  (( ${#_SENSITIVE[@]} > 0 )) || return 0
  if printf '%s\n' "${_SENSITIVE[@]}" | awk 'length($0) >= 8' | grep -qF -f - "${logf}"; then
    printf '%s [teknoir-node] ERROR: leak check: %s contains a secret value\n' "$(date -u +%H:%M:%S)" "${logf}" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# kubectl
# ---------------------------------------------------------------------------
kc() {
  # kc <args...> - run ${KUBECTL} (word-split) with the args; rc preserved.
  local -a _kc
  read -r -a _kc <<<"${KUBECTL}"
  "${_kc[@]}" "$@"
}

cluster_up() {
  # cluster_up - 0 when the API server answers /readyz (read-only).
  kc get --raw=/readyz --request-timeout=10s >/dev/null 2>&1
}

require_cluster() {
  # require_cluster <what> - 0 when the API is reachable. In dry-run an
  # unreachable API (e.g. before the first k3s install) returns 1 with a note;
  # otherwise it dies.
  cluster_up && return 0
  if dry_run; then
    log "[dry-run] ${1}: the cluster is not reachable (yet); it would run after k3s is up"
    return 1
  fi
  die "${1}: the Kubernetes API is not reachable (${KUBECTL} get --raw=/readyz failed)"
}

in_cluster() {
  # in_cluster <resource> <name> [namespace] - 0 exists, 1 absent. Any error
  # (API unreachable, RBAC, ...) dies: an error is never read as "absent".
  # A resource type the server does not know (CRD not installed yet) means
  # the object cannot exist: absent.
  local res="$1" name="$2" ns="${3:-}" out rc=0
  local -a nsarg=()
  [[ -n "${ns}" ]] && nsarg=(-n "${ns}")
  out="$(kc get "${res}" "${name}" ${nsarg[@]+"${nsarg[@]}"} --ignore-not-found -o name 2>&1)" || rc=$?
  if (( rc != 0 )); then
    if [[ "${out}" == *"the server doesn't have a resource type"* ]]; then
      return 1
    fi
    die "cannot check ${res}/${name}${ns:+ in ${ns}}: ${out}"
  fi
  [[ -n "${out}" ]]
}

crd_established() {
  # crd_established <crd-name> - 0 when the CRD exists and is Established.
  [[ "$(kc get crd "$1" --ignore-not-found -o 'jsonpath={.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" == "True" ]]
}

_manifest_objects() {
  # _manifest_objects <file> - "Kind/name" of every document (YAML or JSON).
  if [[ "$(head -c 64 "$1" | tr -d '[:space:]' | head -c 1)" == "{" ]]; then
    "${JQ}" -r 'if .kind == "List" then .items[] else . end | "\(.kind)/\(.metadata.name)"' "$1" | tr '\n' ' '
    return 0
  fi
  awk '
    /^---/ { if (k != "") print k "/" n; k = ""; n = ""; meta = 0; next }
    /^kind:/ { k = $2 }
    /^metadata:/ { meta = 1; next }
    meta && /^  name:/ && n == "" { n = $2 }
    /^[^ ]/ && !/^metadata:/ { meta = 0 }
    END { if (k != "") print k "/" n }
  ' "$1" | tr -d '"' | tr '\n' ' '
}

apply_ssa() {
  # apply_ssa <file|-> [field-manager] [description] - server-side apply
  # (--force-conflicts) as field manager teknoir-bootstrap by default.
  # Applies only when `kubectl diff --server-side` reports a difference, so an
  # unchanged object is never written and the run summary stays exact. In
  # dry-run the diff decides "unchanged" / "would change" (the diff itself is
  # shown only for non-Secret objects). Returns 0 unchanged/applied; dies on
  # errors.
  local src="$1" fm="${2:-teknoir-bootstrap}" desc="${3:-}" file rc=0 out
  ensure_work_dir
  file="$(umask 077 && mktemp "${WORK_DIR}/apply.XXXXXX")"
  if [[ "${src}" == "-" ]]; then
    cat > "${file}"
  else
    [[ -f "${src}" ]] || die "apply_ssa: missing ${src}"
    cat "${src}" > "${file}"
  fi
  [[ -n "${desc}" ]] || desc="$(_manifest_objects "${file}")"
  [[ -n "${desc}" ]] || desc="$(basename "${src}")"
  local secret=0
  if grep -qE '^kind:[[:space:]]*"?Secret"?[[:space:]]*$|"kind":[[:space:]]*"Secret"' "${file}"; then
    secret=1
  fi
  out="$(KUBECTL_EXTERNAL_DIFF="diff -q" kc diff --server-side --field-manager="${fm}" --force-conflicts -f "${file}" 2>&1)" || rc=$?
  case "${rc}" in
    0)
      log "unchanged: ${desc}"
      rm -f "${file}"
      return 0
      ;;
    1)
      if dry_run; then
        if (( secret == 0 )); then
          kc diff --server-side --field-manager="${fm}" --force-conflicts -f "${file}" >&2 2>&1 || true
        fi
        changed "server-side apply ${desc} (field manager ${fm})"
        rm -f "${file}"
        return 0
      fi
      ;;
    *)
      (( secret == 1 )) && out="(output suppressed: Secret)"
      die "kubectl diff failed for ${desc}: ${out}"
      ;;
  esac
  out="$(kc apply --server-side --field-manager="${fm}" --force-conflicts -f "${file}" 2>&1)" \
    || { (( secret == 1 )) && out="(output suppressed: Secret)"; die "server-side apply of ${desc} failed: ${out}"; }
  rm -f "${file}"
  changed "server-side applied ${desc} (field manager ${fm})"
}

wait_for() {
  # wait_for <description> <timeout-seconds> <cmd...> - poll <cmd> every
  # WAIT_INTERVAL seconds until it succeeds; dies on timeout. In dry-run it
  # checks once and only reports.
  local desc="$1" timeout="$2" deadline
  shift 2
  if dry_run; then
    if "$@" >/dev/null 2>&1; then
      log "[dry-run] ${desc}: already satisfied"
    else
      log "[dry-run] would wait up to ${timeout}s for ${desc}"
    fi
    return 0
  fi
  if "$@" >/dev/null 2>&1; then
    return 0
  fi
  log "waiting up to ${timeout}s for ${desc} ..."
  deadline=$(( SECONDS + timeout ))
  while ! "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die "timed out after ${timeout}s waiting for ${desc}"
    sleep "${WAIT_INTERVAL}"
  done
  log "${desc}: ok"
}

# ---------------------------------------------------------------------------
# Files and secrets
# ---------------------------------------------------------------------------
sha256_file() {
  # sha256_file <path> - hex sha256 of a file; dies when it cannot be read.
  local out
  out="$(sha256sum "$1" 2>/dev/null)" || die "cannot checksum $1"
  printf '%s' "${out%% *}"
}

secret_value() {
  # secret_value <ns> <name> <key> - print the decoded value to stdout, ONLY
  # for capture into a variable (v="$(secret_value ...)" - never with `local`
  # on the same line, which would hide a failure). Dies when the Secret or key
  # is missing or unreadable. Prefer read_secret, which also marks the value.
  local ns="$1" name="$2" key="$3" b64
  b64="$(kc -n "${ns}" get secret "${name}" -o "go-template={{ with .data }}{{ index . \"${key}\" }}{{ end }}" 2>/dev/null)" \
    || die "cannot read Secret ${ns}/${name}"
  [[ -n "${b64}" && "${b64}" != "<no value>" ]] || die "Secret ${ns}/${name} has no key ${key}"
  printf '%s' "${b64}" | base64 -d || die "Secret ${ns}/${name} key ${key} is not valid base64"
}

read_secret() {
  # read_secret <var> <ns> <name> <key> - set <var> to the decoded value and
  # mark it for the leak check. Never prints it.
  local __rs_v
  __rs_v="$(secret_value "$2" "$3" "$4")" || die "cannot read key $4 of Secret $2/$3"
  printf -v "$1" '%s' "${__rs_v}"
  mark_sensitive "${__rs_v}"
}

random_alnum() {
  # random_alnum <length> - print a random [A-Za-z0-9] string (capture only).
  local n="$1" v=""
  while (( ${#v} < n )); do
    v+="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${v:0:n}"
}

random_b64url() {
  # random_b64url <bytes> - <bytes> random bytes, base64url without padding.
  openssl rand "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='
}

ensure_dir() {
  # ensure_dir <dir> <mode> - create a missing directory with <mode>. An
  # existing one is left as it is: its mode may belong to the OS or k3s
  # (e.g. Debian's setgid /usr/local/share/ca-certificates).
  local d="$1" mode="$2"
  [[ -d "${d}" ]] && return 0
  run mkdir -p -m "${mode}" "${d}"
}

install_file() {
  # install_file <src> <dst> <mode> <description> - copy <src> to <dst>
  # atomically (temp file + rename in the same dir) when the content differs;
  # fix the mode otherwise. Sets FILE_CHANGED=1 when <dst> changed (or, in
  # dry-run, would change), else 0. Always returns 0 (dies on errors).
  local src="$1" dst="$2" mode="$3" desc="$4" tmp
  FILE_CHANGED=0
  if [[ -f "${dst}" ]] && cmp -s "${src}" "${dst}"; then
    if [[ "$(stat -c %a "${dst}")" != "${mode#0}" ]]; then
      run chmod "${mode}" "${dst}"
      changed "mode ${mode} on ${dst} (${desc})"
      FILE_CHANGED=1
    fi
    return 0
  fi
  FILE_CHANGED=1
  if dry_run; then
    changed "write ${dst} (${desc})"
    return 0
  fi
  mkdir -p "$(dirname "${dst}")"
  tmp="$(dirname "${dst}")/.$(basename "${dst}").teknoir-tmp"
  ( umask 077 && cat "${src}" > "${tmp}" ) || die "cannot write ${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${dst}" || die "cannot rename ${tmp} -> ${dst}"
  changed "wrote ${dst} (${desc})"
}

# ---------------------------------------------------------------------------
# Versions, templates
# ---------------------------------------------------------------------------
version_lt() {
  # version_lt <a> <b> - 0 when version a sorts strictly before b (sort -V).
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

teknoir_fqdns() {
  # teknoir_fqdns - every name that resolves to NODE_IP: <short>.<domain> for
  # each TEKNOIR_HOSTNAMES entry, then the apex domain.
  local h names=()
  for h in ${TEKNOIR_HOSTNAMES}; do
    names+=("${h}.${TEKNOIR_DOMAIN}")
  done
  names+=("${TEKNOIR_DOMAIN}")
  printf '%s' "${names[*]}"
}

render_template() {
  # render_template <template> [KEY=VALUE ...] - print the template with every
  # __KEY__ replaced. Built-in keys: DOMAIN NODE_IP HARBOR_HOST K3S_DATA_DIR
  # K3S_CA_FILE APP_OF_APPS_VERSION HOSTS_ENTRIES. A line holding only a
  # placeholder expands a multi-line value with the line's indentation, or
  # disappears when the value is empty. Dies on any unknown placeholder.
  local tmpl="$1" kv line key indent val out="" l h
  shift
  [[ -f "${tmpl}" ]] || die "missing template ${tmpl}"
  local hosts=""
  for h in $(teknoir_fqdns); do
    hosts+="${NODE_IP} ${h}"$'\n'
  done
  local -A vars=(
    [DOMAIN]="${TEKNOIR_DOMAIN:-}"
    [NODE_IP]="${NODE_IP:-}"
    [HARBOR_HOST]="${HARBOR_HOST:-}"
    [K3S_DATA_DIR]="${K3S_DATA_DIR:-}"
    [K3S_CA_FILE]="/etc/rancher/k3s/teknoir-root-ca.crt"
    [APP_OF_APPS_VERSION]="${APP_OF_APPS_VERSION:-}"
    [HOSTS_ENTRIES]="${hosts%$'\n'}"
  )
  for kv in "$@"; do
    vars["${kv%%=*}"]="${kv#*=}"
  done
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^([[:space:]]*)__([A-Z0-9_]+)__[[:space:]]*$ ]] && [[ -n "${vars[${BASH_REMATCH[2]}]+x}" ]]; then
      indent="${BASH_REMATCH[1]}"
      val="${vars[${BASH_REMATCH[2]}]}"
      [[ -z "${val}" ]] && continue
      while IFS= read -r l; do
        out+="${indent}${l}"$'\n'
      done <<<"${val}"
      continue
    fi
    for key in "${!vars[@]}"; do
      line="${line//__${key}__/${vars[${key}]}}"
    done
    out+="${line}"$'\n'
  done < "${tmpl}"
  if [[ "${out}" =~ __[A-Z0-9_]+__ ]]; then
    die "template ${tmpl}: unsubstituted placeholder ${BASH_REMATCH[0]}"
  fi
  printf '%s' "${out}"
}

# ---------------------------------------------------------------------------
# Site and bundle
# ---------------------------------------------------------------------------
load_site() {
  # load_site <file> - source the site env (public, committed, no secrets) and
  # validate it.
  local f="$1" h
  [[ -f "${f}" ]] || die "site file not found: ${f}"
  # shellcheck disable=SC1090
  source "${f}"
  SITE_FILE="${f}"
  [[ -n "${TEKNOIR_ENV:-}" ]] || die "${f}: TEKNOIR_ENV is not set"
  [[ "${TEKNOIR_DOMAIN:-}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "${f}: invalid TEKNOIR_DOMAIN '${TEKNOIR_DOMAIN:-}'"
  [[ "${NODE_IP:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "${f}: invalid NODE_IP '${NODE_IP:-}'"
  for h in ${TEKNOIR_HOSTNAMES:-}; do
    [[ "${h}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "${f}: invalid TEKNOIR_HOSTNAMES entry '${h}'"
  done
  K3S_DATA_DIR="${K3S_DATA_DIR:-/opt/k3s}"
  [[ "${K3S_DATA_DIR}" == /* ]] || die "${f}: K3S_DATA_DIR must be absolute"
  TIME_SOURCE="${TIME_SOURCE:-}"
  HARBOR_HOST="harbor.${TEKNOIR_DOMAIN}"
}

manifest_get() {
  # manifest_get <key> - a top-level scalar of the bundle's MANIFEST.yaml
  # (quotes stripped), empty when absent.
  [[ -n "${BUNDLE_MANIFEST:-}" && -f "${BUNDLE_MANIFEST}" ]] || return 0
  awk -v k="$1" '
    $0 ~ "^" k ":" {
      sub("^" k ":[[:space:]]*", ""); sub(/[[:space:]]+#.*$/, "")
      gsub(/^["\047]|["\047]$/, ""); print; exit
    }' "${BUNDLE_MANIFEST}"
}

load_bundle_info() {
  # load_bundle_info - identify this payload. The LAN side places
  # MANIFEST.yaml next to node/ (/var/lib/teknoir-airgap/bundles/<id>/), so
  # the bundle id, versions and commits come from there; without it they fall
  # back to the payload dir name and charts/pins.txt. Environment overrides
  # win (tests).
  local parent
  parent="$(cd "${NODE_ROOT}/.." && pwd)"
  BUNDLE_MANIFEST=""
  if [[ -f "${parent}/MANIFEST.yaml" ]]; then
    BUNDLE_MANIFEST="${parent}/MANIFEST.yaml"
  elif [[ -f "${NODE_ROOT}/MANIFEST.yaml" ]]; then
    BUNDLE_MANIFEST="${NODE_ROOT}/MANIFEST.yaml"
  fi
  BUNDLE_ID="${BUNDLE_ID:-$(manifest_get bundleId)}"
  BUNDLE_ID="${BUNDLE_ID:-$(basename "${parent}")}"
  if [[ -z "${APP_OF_APPS_VERSION:-}" ]]; then
    APP_OF_APPS_VERSION="$(manifest_get appOfAppsVersion)"
  fi
  if [[ -z "${APP_OF_APPS_VERSION}" && -f "${NODE_ROOT}/charts/pins.txt" ]]; then
    APP_OF_APPS_VERSION="$(awk '$1 == "app-of-apps" {print $2; exit}' "${NODE_ROOT}/charts/pins.txt")"
  fi
  if [[ -z "${MANIFEST_SHA256:-}" ]]; then
    if [[ -n "${BUNDLE_MANIFEST}" ]]; then
      MANIFEST_SHA256="$(sha256_file "${BUNDLE_MANIFEST}")"
    elif [[ -f "${NODE_ROOT}/SHA256SUMS" ]]; then
      MANIFEST_SHA256="$(sha256_file "${NODE_ROOT}/SHA256SUMS")"
    else
      MANIFEST_SHA256=""
    fi
  fi
  INFRA_COMMIT="${INFRA_COMMIT:-$(manifest_get infraCommit)}"
  GITOPS_COMMIT="${GITOPS_COMMIT:-$(manifest_get gitopsCommit)}"
  BUNDLE_DOMAIN="$(manifest_get domain)"
  BUNDLE_ENV="$(manifest_get env)"
}

# ---------------------------------------------------------------------------
# Phase selection (converge --only / --skip)
# ---------------------------------------------------------------------------
PHASE_ONLY="${PHASE_ONLY:-}"
PHASE_SKIP="${PHASE_SKIP:-}"

phase_wanted() {
  # phase_wanted <phase> - 0 when the phase runs in this converge.
  local p="$1"
  if [[ -n "${PHASE_ONLY}" ]]; then
    [[ ",${PHASE_ONLY}," == *",${p},"* ]] || return 1
  fi
  [[ ",${PHASE_SKIP}," != *",${p},"* ]]
}

tier_reapply_requested() {
  # tier_reapply_requested <tier> - 0 when --reapply <tier> was given.
  [[ " ${REAPPLY_TIERS} " == *" $1 "* ]]
}
