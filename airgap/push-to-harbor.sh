#!/usr/bin/env bash
# push-to-harbor.sh — populate the in-cluster Harbor from the bundle
# (LAN-laptop side, https to https://harbor.teknoir.airgapped).
#
#   1. create the six Harbor projects idempotently
#      (teknoir = charts, dockerhub/ghcr/gcr/quay/k8s = public registry mirrors)
#   2. ensure the system robot account `robot$argocd` (pull on all projects)
#      matches the credential in airgap/.secrets/robot-argocd.env — generated
#      once, never rotated implicitly — and regenerate the ArgoCD repo secret
#      manifest from it (scripts/gen-argocd-harbor-repo-secret.sh)
#   3. helm push every chart from <bundle>/charts to oci://harbor/teknoir
#   4. crane push every OCI image layout from <bundle>/images into the mirror
#      projects (docker.io/* -> dockerhub/*, ghcr.io/* -> ghcr/*, ...)
#
# Admin credentials: env HARBOR_ADMIN_PASSWORD (prompted when unset).
#
# Re-running is safe: projects, robot and credential converge to the same state.
#
# Usage: airgap/push-to-harbor.sh [--bundle DIR] [--robot-only] [--rotate-robot]
#                                 [--insecure] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR   bundle directory (default: $(bundle_dir))
  --robot-only   only ensure projects + robot account + ArgoCD repo secret
                 manifest (no charts/images; no bundle needed)
  --rotate-robot generate a NEW robot secret (then redeploy the ArgoCD secret
                 with scripts/deploy-secrets.sh)
  --insecure     skip TLS verification instead of using teknoir-root-ca.crt
  --dry-run      print planned actions, no network calls
  -h, --help     show this help

Environment:
  HARBOR_ADMIN_PASSWORD   Harbor admin password (prompted when unset)
EOF
}

INSECURE=0
ROBOT_ONLY=0
ROTATE_ROBOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --robot-only) ROBOT_ONLY=1 ;;
    --rotate-robot) ROTATE_ROBOT=1 ;;
    --insecure) INSECURE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

BUNDLE="$(bundle_dir)"
ROBOT_NAME="argocd"
# shellcheck disable=SC2016  # literal $ — Harbor prefixes system robots with 'robot$'
ROBOT_FULL_NAME='robot$argocd'
ROBOT_ENV_FILE="${AIRGAP_DIR}/.secrets/robot-argocd.env"
API="${HARBOR_URL}/api/v2.0"

MIRROR_PROJECTS=()
for entry in "${MIRRORED_REGISTRIES[@]}"; do
  MIRROR_PROJECTS+=("${entry##* }")
done
ALL_PROJECTS=("${HARBOR_CHART_PROJECT}" "${MIRROR_PROJECTS[@]}")

# --- CA trust ---------------------------------------------------------------
CA_FILE=""
for c in "${BUNDLE}/bootstrap/k3s/teknoir-root-ca.crt" "${REPO_ROOT}/teknoir-root-ca.crt"; do
  if [[ -f "${c}" ]]; then CA_FILE="${c}"; break; fi
done

CURL_TLS=()
HELM_TLS=()
CRANE_TLS=()
if [[ "${INSECURE}" == "1" ]]; then
  CURL_TLS+=(--insecure)
  HELM_TLS+=(--insecure-skip-tls-verify)
  CRANE_TLS+=(--insecure)
elif [[ -n "${CA_FILE}" ]]; then
  CURL_TLS+=(--cacert "${CA_FILE}")
  HELM_TLS+=(--ca-file "${CA_FILE}")
  # crane (go-containerregistry) has no CA flag. On Linux Go's crypto/x509
  # honors SSL_CERT_FILE, so point it at the teknoir CA. On macOS Go defers TLS
  # verification to Security.framework and ignores SSL_CERT_FILE entirely
  # (crypto/x509/root_unix.go excludes darwin), so the CA cannot be fed to crane
  # that way — the push would fail with 'certificate is not trusted'. Fall back
  # to --insecure for crane only: the Harbor endpoint identity is still pinned by
  # the CA-verified curl health check and helm login above, so crane then talks
  # to the already-authenticated same host.
  export SSL_CERT_FILE="${CA_FILE}"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    warn "macOS: crane cannot consume ${CA_FILE} (Go ignores SSL_CERT_FILE on darwin); using --insecure for crane only (endpoint already verified via CA-pinned curl/helm)"
    CRANE_TLS+=(--insecure)
  fi
else
  die "teknoir-root-ca.crt not found (bundle or repo root) — use --insecure to override"
fi

# --- dry-run: report the plan and exit ---------------------------------------
if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] would ensure projects on ${HARBOR_URL}: ${ALL_PROJECTS[*]} (mirrors public, ${HARBOR_CHART_PROJECT} private)"
  log "[dry-run] would ensure robot account ${ROBOT_FULL_NAME} (pull on all projects) matches ${ROBOT_ENV_FILE}$( [[ "${ROTATE_ROBOT}" == "1" ]] && echo ' (ROTATED)')"
  log "[dry-run] would regenerate .secrets/manifest-argocd-harbor-repo-secret.yaml"
  [[ "${ROBOT_ONLY}" == "1" ]] && { log "dry-run complete (--robot-only)"; exit 0; }
  shopt -s nullglob
  for tgz in "${BUNDLE}/charts/"*.tgz; do
    log "[dry-run] helm push ${tgz} oci://${HARBOR_HOST}/${HARBOR_CHART_PROJECT}"
  done
  shopt -u nullglob
  if [[ -f "${BUNDLE}/images/images.txt" ]]; then
    while read -r ref name; do
      [[ -n "${ref}" ]] || continue
      log "[dry-run] crane push ${BUNDLE}/images/${name} -> $(
        for e in "${MIRRORED_REGISTRIES[@]}"; do
          u="${e%% *}"; p="${e##* }"
          if [[ "${ref}" == "${u}/"* ]]; then echo "${HARBOR_HOST}/${p}/${ref#"${u}"/}"; break; fi
        done)"
    done < "${BUNDLE}/images/images.txt"
  else
    warn "[dry-run] no ${BUNDLE}/images/images.txt (run collect-images.sh)"
  fi
  log "dry-run complete"
  exit 0
fi

require_cmd curl python3
[[ "${ROBOT_ONLY}" == "1" ]] || require_cmd crane helm

# --- admin credential ---------------------------------------------------------
if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  read -rs -p "Harbor admin password: " HARBOR_ADMIN_PASSWORD
  echo >&2
fi
[[ -n "${HARBOR_ADMIN_PASSWORD}" ]] || die "empty Harbor admin password"

api() {
  # api <method> <path> [json-body]
  # Credentials go through a curl config on a pipe, never on the command line
  # (the process substitution must sit on curl's own command line to stay open).
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS "${CURL_TLS[@]}" -X "${method}" \
              -H 'Content-Type: application/json' "${API}${path}")
  if [[ -n "${body}" ]]; then
    args+=(-d "${body}")
  fi
  curl -K <(printf 'user = "admin:%s"\n' "${HARBOR_ADMIN_PASSWORD}") "${args[@]}"
}

api_status() {
  # api_status <method> <path> — print only the http status code.
  # Use curl's -I for HEAD: -X HEAD makes curl expect a body per Content-Length
  # that a HEAD response never sends, so it exits 18 (partial file), which under
  # `set -euo pipefail` would abort the whole script on the first project check.
  local method="$1" method_args=(-X "$1")
  [[ "${method}" == "HEAD" ]] && method_args=(-I)
  curl -s -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" \
    -K <(printf 'user = "admin:%s"\n' "${HARBOR_ADMIN_PASSWORD}") "${method_args[@]}" "${API}$2"
}

log "checking Harbor availability at ${API}"
api GET "/health" >/dev/null || die "Harbor API not reachable at ${API}"

# ---------------------------------------------------------------------------
# 1. Projects (idempotent; mirrors are public so containerd can pull unauthenticated)
# ---------------------------------------------------------------------------
project_public() {
  case "$1" in
    "${HARBOR_CHART_PROJECT}") echo "false" ;;
    *) echo "true" ;;
  esac
}

for p in "${ALL_PROJECTS[@]}"; do
  status="$(api_status HEAD "/projects?project_name=${p}")"
  if [[ "${status}" == "200" ]]; then
    log "project exists: ${p}"
  else
    log "creating project: ${p} (public=$(project_public "${p}"))"
    api POST "/projects" \
      "{\"project_name\":\"${p}\",\"metadata\":{\"public\":\"$(project_public "${p}")\"}}" >/dev/null
  fi
done

# ---------------------------------------------------------------------------
# 2. Robot account robot$argocd (idempotent, pull on all projects)
# ---------------------------------------------------------------------------
# ${ROBOT_ENV_FILE} is the single source of truth for the robot credential. It
# is generated once (or on --rotate-robot); every run then makes Harbor match it
# (create the robot if missing, set its permissions, set its secret) instead of
# deleting and recreating the robot, which used to rotate the token on every
# push and silently break ArgoCD's Harbor login.
gen_robot_secret() {
  # Harbor policy: 8-128 chars with upper, lower and digit.
  python3 -c 'import secrets, string
a = string.ascii_letters + string.digits
while True:
    s = "".join(secrets.choice(a) for _ in range(32))
    if any(c.islower() for c in s) and any(c.isupper() for c in s) and any(c.isdigit() for c in s):
        print(s)
        break'
}

robot_token=""
if [[ "${ROTATE_ROBOT}" != "1" && -f "${ROBOT_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  robot_token="$(. "${ROBOT_ENV_FILE}" && printf '%s' "${HARBOR_ROBOT_TOKEN:-}")"
fi
if [[ -z "${robot_token}" ]]; then
  log "generating a new robot secret -> ${ROBOT_ENV_FILE}"
  robot_token="$(gen_robot_secret)"
  mkdir -p "${AIRGAP_DIR}/.secrets"
  chmod 700 "${AIRGAP_DIR}/.secrets"
  (
    umask 077
    printf "HARBOR_ROBOT_USER='%s'\nHARBOR_ROBOT_TOKEN='%s'\n" "${ROBOT_FULL_NAME}" "${robot_token}" > "${ROBOT_ENV_FILE}"
  )
fi

permissions="$(python3 - "${ALL_PROJECTS[@]}" <<'PYEOF'
import json, sys
print(json.dumps([
    {"kind": "project", "namespace": p, "access": [
        {"resource": "repository", "action": "pull"},
        {"resource": "repository", "action": "list"},
    ]}
    for p in sys.argv[1:]
]))
PYEOF
)"

# shellcheck disable=SC2016  # literal $ in the python snippet
robot_json="$(api GET "/robots?q=name%3D${ROBOT_NAME}&page_size=100" | python3 -c '
import json, sys
for r in json.load(sys.stdin) or []:
    if r.get("name") == "robot$argocd":
        print(json.dumps(r))
        break
')"

if [[ -z "${robot_json}" ]]; then
  log "creating robot account ${ROBOT_FULL_NAME}"
  robot_id="$(api POST "/robots" \
    "{\"name\":\"${ROBOT_NAME}\",\"description\":\"ArgoCD pull-only robot (airgap)\",\"duration\":-1,\"level\":\"system\",\"disable\":false,\"permissions\":${permissions}}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  robot_id="$(printf '%s' "${robot_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  log "robot account ${ROBOT_FULL_NAME} exists (id ${robot_id}); ensuring permissions"
  api PUT "/robots/${robot_id}" "$(printf '%s' "${robot_json}" | python3 -c '
import json, sys
r = json.load(sys.stdin)
r["permissions"] = json.loads(sys.argv[1])
r["disable"] = False
print(json.dumps(r))' "${permissions}")" >/dev/null
fi

# Set the secret to the stored value only when Harbor does not accept it yet.
robot_auth_status() {
  curl -s -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" \
    -K <(printf 'user = "%s:%s"\n' "${ROBOT_FULL_NAME}" "${robot_token}") \
    "${HARBOR_URL}/service/token?service=harbor-registry"
}
if [[ "$(robot_auth_status)" == "200" ]]; then
  log "robot credential in ${ROBOT_ENV_FILE} is valid in Harbor"
else
  log "setting the robot secret from ${ROBOT_ENV_FILE}"
  printf '{"secret":"%s"}' "${robot_token}" \
    | curl -fsS -o /dev/null "${CURL_TLS[@]}" -K <(printf 'user = "admin:%s"\n' "${HARBOR_ADMIN_PASSWORD}") \
        -X PATCH -H 'Content-Type: application/json' --data @- "${API}/robots/${robot_id}"
  [[ "$(robot_auth_status)" == "200" ]] || die "Harbor still rejects the robot credential after setting it"
fi

# The ArgoCD repo secret manifest is derived from the env file; regenerating it
# is a no-op when the credential did not change.
"${REPO_ROOT}/scripts/gen-argocd-harbor-repo-secret.sh"

if [[ "${ROBOT_ONLY}" == "1" ]]; then
  log "push-to-harbor complete (--robot-only); deploy the ArgoCD secret if it changed: ./scripts/deploy-secrets.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Charts -> oci://harbor/teknoir
# ---------------------------------------------------------------------------
log "helm registry login ${HARBOR_HOST}"
printf '%s' "${HARBOR_ADMIN_PASSWORD}" \
  | helm registry login "${HARBOR_HOST}" --username admin --password-stdin "${HELM_TLS[@]}"

shopt -s nullglob
chart_tgzs=("${BUNDLE}/charts/"*.tgz)
shopt -u nullglob
if [[ ${#chart_tgzs[@]} -eq 0 ]]; then
  warn "no charts in ${BUNDLE}/charts/ (run collect-charts.sh)"
fi
for tgz in "${chart_tgzs[@]}"; do
  log "helm push $(basename "${tgz}")"
  helm push "${tgz}" "oci://${HARBOR_HOST}/${HARBOR_CHART_PROJECT}" "${HELM_TLS[@]}" >/dev/null
done

# ---------------------------------------------------------------------------
# 4. Images -> mirror projects (registry-prefix rewrite)
# ---------------------------------------------------------------------------
rewrite_ref() {
  local ref="$1" entry upstream project
  for entry in "${MIRRORED_REGISTRIES[@]}"; do
    upstream="${entry%% *}"
    project="${entry##* }"
    if [[ "${ref}" == "${upstream}/"* ]]; then
      echo "${HARBOR_HOST}/${project}/${ref#"${upstream}"/}"
      return 0
    fi
  done
  return 1
}

log "crane auth login ${HARBOR_HOST}"
printf '%s' "${HARBOR_ADMIN_PASSWORD}" \
  | crane auth login ${CRANE_TLS[@]+"${CRANE_TLS[@]}"} "${HARBOR_HOST}" --username admin --password-stdin

INDEX_FILE="${BUNDLE}/images/images.txt"
[[ -f "${INDEX_FILE}" ]] || die "missing ${INDEX_FILE} (run collect-images.sh)"

while read -r ref name; do
  [[ -n "${ref}" ]] || continue
  layout="${BUNDLE}/images/${name}"
  if [[ ! -f "${layout}/index.json" ]]; then
    warn "missing OCI layout for ${ref} (${layout}) — skipping"
    continue
  fi
  if ! target="$(rewrite_ref "${ref}")"; then
    warn "no mirror project for registry of ${ref} — skipping"
    continue
  fi
  log "crane push ${ref} -> ${target}"
  crane push ${CRANE_TLS[@]+"${CRANE_TLS[@]}"} "${layout}" "${target}"
done < "${INDEX_FILE}"

log "push-to-harbor complete"
log "next: ./scripts/deploy-secrets.sh (no-op when unchanged), then ./airgap/update-airgap.sh <app-of-apps version>"
