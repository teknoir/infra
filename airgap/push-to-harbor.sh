#!/usr/bin/env bash
# push-to-harbor.sh — populate the in-cluster Harbor from the bundle
# (LAN-laptop side, https to https://harbor.teknoir.airgapped).
#
#   1. create the six Harbor projects idempotently
#      (teknoir = charts, dockerhub/ghcr/gcr/quay/k8s = public registry mirrors)
#   2. create/rotate the system robot account `robot$argocd` (pull on all projects)
#      and write its credential to airgap/.secrets/robot-argocd.env
#      (consumed by scripts/gen-argocd-harbor-repo-secret.sh)
#   3. helm push every chart from <bundle>/charts to oci://harbor/teknoir
#   4. crane push every OCI image layout from <bundle>/images into the mirror
#      projects (docker.io/* -> dockerhub/*, ghcr.io/* -> ghcr/*, ...)
#
# Admin credentials: env HARBOR_ADMIN_PASSWORD (prompted when unset).
#
# Usage: airgap/push-to-harbor.sh [--bundle DIR] [--insecure] [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR   bundle directory (default: $(bundle_dir))
  --insecure     skip TLS verification instead of using teknoir-root-ca.crt
  --dry-run      print planned actions, no network calls
  -h, --help     show this help

Environment:
  HARBOR_ADMIN_PASSWORD   Harbor admin password (prompted when unset)
EOF
}

INSECURE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
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
  log "[dry-run] would create/rotate robot account ${ROBOT_FULL_NAME} (pull on all projects) -> ${ROBOT_ENV_FILE}"
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

require_cmd curl crane helm python3

# --- admin credential ---------------------------------------------------------
if [[ -z "${HARBOR_ADMIN_PASSWORD:-}" ]]; then
  read -rs -p "Harbor admin password: " HARBOR_ADMIN_PASSWORD
  echo >&2
fi
[[ -n "${HARBOR_ADMIN_PASSWORD}" ]] || die "empty Harbor admin password"

api() {
  # api <method> <path> [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS "${CURL_TLS[@]}" -u "admin:${HARBOR_ADMIN_PASSWORD}" -X "${method}" \
              -H 'Content-Type: application/json' "${API}${path}")
  if [[ -n "${body}" ]]; then
    args+=(-d "${body}")
  fi
  curl "${args[@]}"
}

api_status() {
  # api_status <method> <path> — print only the http status code.
  # Use curl's -I for HEAD: -X HEAD makes curl expect a body per Content-Length
  # that a HEAD response never sends, so it exits 18 (partial file), which under
  # `set -euo pipefail` would abort the whole script on the first project check.
  local method="$1" method_args=(-X "$1")
  [[ "${method}" == "HEAD" ]] && method_args=(-I)
  curl -s -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" \
    -u "admin:${HARBOR_ADMIN_PASSWORD}" "${method_args[@]}" "${API}$2"
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
# 2. Robot account robot$argocd (create/rotate, pull on all projects)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # $ inside the python snippet is literal
existing_id="$(api GET "/robots?q=name%3D${ROBOT_NAME}&page_size=100" | python3 -c '
import json, sys
robots = json.load(sys.stdin) or []
for r in robots:
    if r.get("name") == "robot$argocd":
        print(r["id"])
        break
')"

if [[ -n "${existing_id}" ]]; then
  log "rotating existing robot account ${ROBOT_FULL_NAME} (id ${existing_id})"
  api DELETE "/robots/${existing_id}" >/dev/null
fi

permissions="$(python3 - "${ALL_PROJECTS[@]}" <<'PYEOF'
import json, sys
projects = sys.argv[1:]
perms = [
    {
        "kind": "project",
        "namespace": p,
        "access": [
            {"resource": "repository", "action": "pull"},
            {"resource": "repository", "action": "list"},
        ],
    }
    for p in projects
]
print(json.dumps(perms))
PYEOF
)"

log "creating robot account ${ROBOT_FULL_NAME}"
robot_response="$(api POST "/robots" \
  "{\"name\":\"${ROBOT_NAME}\",\"description\":\"ArgoCD pull-only robot (airgap)\",\"duration\":-1,\"level\":\"system\",\"disable\":false,\"permissions\":${permissions}}")"

robot_user="$(printf '%s' "${robot_response}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
robot_token="$(printf '%s' "${robot_response}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])')"
[[ -n "${robot_token}" ]] || die "robot creation returned no secret"

mkdir -p "${AIRGAP_DIR}/.secrets"
chmod 700 "${AIRGAP_DIR}/.secrets"
{
  printf "HARBOR_ROBOT_USER='%s'\n" "${robot_user}"
  printf "HARBOR_ROBOT_TOKEN='%s'\n" "${robot_token}"
} > "${ROBOT_ENV_FILE}"
chmod 600 "${ROBOT_ENV_FILE}"
log "robot credential written: ${ROBOT_ENV_FILE} (feed scripts/gen-argocd-harbor-repo-secret.sh)"

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
crane auth login ${CRANE_TLS[@]+"${CRANE_TLS[@]}"} "${HARBOR_HOST}" --username admin --password "${HARBOR_ADMIN_PASSWORD}"

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

log "push-to-harbor complete — next: deploy-app-of-apps.sh"
