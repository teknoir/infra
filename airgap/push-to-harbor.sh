#!/usr/bin/env bash
# push-to-harbor.sh — populate the in-cluster Harbor from the bundle
# (LAN-laptop side, https to https://harbor.teknoir.airgapped).
#
#   1. create the six Harbor projects idempotently
#      (teknoir = charts, dockerhub/ghcr/gcr/quay/k8s = public registry mirrors)
#   2. ensure the system robot account `robot$argocd` (pull on all projects)
#      matches the credential in airgap/.secrets/robot-argocd.env (or
#      --robot-env FILE) — generated only together with the robot, never
#      rotated implicitly — and regenerate the ArgoCD repo secret manifest
#      from it (scripts/gen-argocd-harbor-repo-secret.sh)
#   3. push every pinned chart version (<bundle>/charts/pins.txt, see
#      lib.sh:load_chart_pins) from <bundle>/charts to
#      oci://harbor/teknoir that Harbor does not have yet. An existing version
#      is never overwritten (OCI tags are mutable: on 2026-09-14 re-pushes
#      silently changed app-of-apps 0.0.1/0.0.2), and a tag-immutability rule
#      on the project enforces that server-side
#   4. crane push every OCI image layout from <bundle>/images into the mirror
#      projects (docker.io/* -> dockerhub/*, ghcr.io/* -> ghcr/*, ...)
#
# Admin credentials: env HARBOR_ADMIN_PASSWORD (prompted when unset).
#
# Re-running is safe: projects, robot and credential converge to the same state.
#
# Usage: airgap/push-to-harbor.sh [--bundle DIR] [--robot-env FILE] [--robot-only]
#                                 [--rotate-robot] [--force-charts] [--insecure]
#                                 [--dry-run]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --bundle DIR   bundle directory (default: $(bundle_dir))
  --robot-env FILE
                 the robot credential file (default: \$ROBOT_ENV_FILE, else
                 ${ROBOT_ENV_FILE_DEFAULT#"${REPO_ROOT}"/}). It never travels
                 in a bundle: running from one, copy it into the bundle or
                 point here at the operator's copy
  --robot-only   only ensure projects + robot account + ArgoCD repo secret
                 manifest (no charts/images; no bundle needed)
  --rotate-robot generate a NEW robot secret and set it in Harbor (then
                 redeploy the ArgoCD secret with scripts/deploy-secrets.sh).
                 Without it an existing robot's secret is never changed
  --force-charts also push chart versions Harbor already has (refused while the
                 teknoir tag-immutability rule is enabled; bump versions instead)
  --insecure     skip TLS verification instead of using teknoir-root-ca.crt
  --dry-run      print planned actions, no network calls
  -h, --help     show this help

Environment:
  HARBOR_ADMIN_PASSWORD   Harbor admin password (prompted when unset)
  ROBOT_ENV_FILE          as --robot-env
EOF
}

ROBOT_ENV_FILE_DEFAULT="${AIRGAP_DIR}/.secrets/robot-argocd.env"
ROBOT_ENV_FILE="${ROBOT_ENV_FILE:-${ROBOT_ENV_FILE_DEFAULT}}"
INSECURE=0
ROBOT_ONLY=0
ROTATE_ROBOT=0
FORCE_CHARTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE_DIR="$2"; shift ;;
    --robot-env) ROBOT_ENV_FILE="$2"; shift ;;
    --robot-only) ROBOT_ONLY=1 ;;
    --rotate-robot) ROTATE_ROBOT=1 ;;
    --force-charts) FORCE_CHARTS=1 ;;
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
# Absolute, so scripts/gen-argocd-harbor-repo-secret.sh (which runs from the
# repo root) reads the same file.
case "${ROBOT_ENV_FILE}" in
  /*) ;;
  *) ROBOT_ENV_FILE="${PWD}/${ROBOT_ENV_FILE}" ;;
esac
export ROBOT_ENV_FILE
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

# Chart pins: the bundle's pins.txt (no render needed on this side).
[[ "${ROBOT_ONLY}" == "1" ]] || load_chart_pins

# --- dry-run: report the plan and exit ---------------------------------------
if [[ "${DRY_RUN}" == "1" ]]; then
  log "[dry-run] would ensure projects on ${HARBOR_URL}: ${ALL_PROJECTS[*]} (mirrors public, ${HARBOR_CHART_PROJECT} private)"
  if [[ "${ROTATE_ROBOT}" == "1" ]]; then
    log "[dry-run] would ensure robot account ${ROBOT_FULL_NAME} (pull on all projects) with a NEW secret, written to ${ROBOT_ENV_FILE} (ROTATED)"
  elif [[ -f "${ROBOT_ENV_FILE}" ]]; then
    log "[dry-run] would ensure robot account ${ROBOT_FULL_NAME} (pull on all projects) accepts the credential in ${ROBOT_ENV_FILE} (refused if Harbor rejects it)"
  else
    warn "[dry-run] ${ROBOT_ENV_FILE} does not exist: a credential is generated only if ${ROBOT_FULL_NAME} does not exist yet; otherwise the run is refused (use --robot-env FILE, or --rotate-robot)"
  fi
  log "[dry-run] would regenerate .secrets/manifest-argocd-harbor-repo-secret.yaml"
  [[ "${ROBOT_ONLY}" == "1" ]] && { log "dry-run complete (--robot-only)"; exit 0; }
  log "[dry-run] would ensure the tag-immutability rule (all repositories, all tags) on ${HARBOR_CHART_PROJECT}"
  while read -r name version; do
    if [[ -f "${BUNDLE}/charts/${name}-${version}.tgz" ]]; then
      log "[dry-run] helm push ${name}-${version}.tgz -> oci://${HARBOR_HOST}/${HARBOR_CHART_PROJECT} unless Harbor has it$( [[ "${FORCE_CHARTS}" == "1" ]] && echo ' (--force-charts: push anyway)')"
    else
      log "[dry-run] ${name} ${version} is not in the bundle: must already be in Harbor"
    fi
  done < <(pinned_charts)
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
# ${ROBOT_ENV_FILE} is the single source of truth for the robot credential.
# Harbor's robot secret is only ever set by this script, and only
#   * when it creates the robot (with the stored credential, or a new one if
#     there is no file yet), or
#   * on --rotate-robot (a new credential, written to the file first).
# An existing robot whose secret the file does not match is never "fixed" by
# setting the file's secret: the file may be a stale or missing copy (a new
# bundle directory, another laptop), and overwriting Harbor would break the
# credential ArgoCD uses (the 2026-09-14 incident). The run is refused instead.
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

write_robot_env() {
  # write_robot_env <token> — store the credential (mode 600, dir 700)
  mkdir -p "$(dirname "${ROBOT_ENV_FILE}")"
  chmod 700 "$(dirname "${ROBOT_ENV_FILE}")"
  (
    umask 077
    printf "HARBOR_ROBOT_USER='%s'\nHARBOR_ROBOT_TOKEN='%s'\n" "${ROBOT_FULL_NAME}" "$1" > "${ROBOT_ENV_FILE}.tmp"
  )
  mv -f "${ROBOT_ENV_FILE}.tmp" "${ROBOT_ENV_FILE}"
}

robot_token=""
if [[ -f "${ROBOT_ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  robot_token="$(. "${ROBOT_ENV_FILE}" && printf '%s' "${HARBOR_ROBOT_TOKEN:-}")"
  [[ -n "${robot_token}" ]] || die "${ROBOT_ENV_FILE} does not set HARBOR_ROBOT_TOKEN"
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

set_secret=0
if [[ -z "${robot_json}" ]]; then
  if [[ "${ROTATE_ROBOT}" == "1" || -z "${robot_token}" ]]; then
    log "generating the robot credential -> ${ROBOT_ENV_FILE}"
    robot_token="$(gen_robot_secret)"
    write_robot_env "${robot_token}"
  fi
  log "creating robot account ${ROBOT_FULL_NAME}"
  robot_id="$(api POST "/robots" \
    "{\"name\":\"${ROBOT_NAME}\",\"description\":\"ArgoCD pull-only robot (airgap)\",\"duration\":-1,\"level\":\"system\",\"disable\":false,\"permissions\":${permissions}}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  set_secret=1   # Harbor generated its own secret on create
else
  robot_id="$(printf '%s' "${robot_json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  if [[ "${ROTATE_ROBOT}" == "1" ]]; then
    log "--rotate-robot: generating a new robot credential -> ${ROBOT_ENV_FILE}"
    robot_token="$(gen_robot_secret)"
    write_robot_env "${robot_token}"
    set_secret=1
  elif [[ -z "${robot_token}" ]]; then
    die "${ROBOT_FULL_NAME} exists in Harbor but ${ROBOT_ENV_FILE} does not: refusing to generate a credential, which would rotate the robot and break ArgoCD's Harbor login. Copy robot-argocd.env from the machine that holds it (airgap/.secrets/ of that checkout or bundle) to ${ROBOT_ENV_FILE}, or pass --robot-env FILE; only to rotate deliberately, pass --rotate-robot"
  fi
  log "robot account ${ROBOT_FULL_NAME} exists (id ${robot_id}); ensuring permissions"
  api PUT "/robots/${robot_id}" "$(printf '%s' "${robot_json}" | python3 -c '
import json, sys
r = json.load(sys.stdin)
r["permissions"] = json.loads(sys.argv[1])
r["disable"] = False
print(json.dumps(r))' "${permissions}")" >/dev/null
fi

robot_auth_status() {
  curl -s -o /dev/null -w '%{http_code}' "${CURL_TLS[@]}" \
    -K <(printf 'user = "%s:%s"\n' "${ROBOT_FULL_NAME}" "${robot_token}") \
    "${HARBOR_URL}/service/token?service=harbor-registry"
}
if [[ "${set_secret}" == "1" ]]; then
  log "setting the robot secret from ${ROBOT_ENV_FILE}"
  printf '{"secret":"%s"}' "${robot_token}" \
    | curl -fsS -o /dev/null "${CURL_TLS[@]}" -K <(printf 'user = "admin:%s"\n' "${HARBOR_ADMIN_PASSWORD}") \
        -X PATCH -H 'Content-Type: application/json' --data @- "${API}/robots/${robot_id}"
  [[ "$(robot_auth_status)" == "200" ]] || die "Harbor still rejects the robot credential after setting it"
else
  status="$(robot_auth_status)"
  case "${status}" in
    200) log "robot credential in ${ROBOT_ENV_FILE} is valid in Harbor" ;;
    401|403)
      die "Harbor rejects the robot credential in ${ROBOT_ENV_FILE} (HTTP ${status}), so it is not the one ${ROBOT_FULL_NAME} uses: the file is stale (the robot was rotated elsewhere: copy that robot-argocd.env here, or pass --robot-env FILE) or Harbor's secret was changed by hand. Harbor's secret is left alone; to replace it deliberately, pass --rotate-robot and then redeploy the ArgoCD secret (scripts/deploy-secrets.sh)" ;;
    *) die "cannot check the robot credential against Harbor (HTTP ${status})" ;;
  esac
fi

# The ArgoCD repo secret manifest is derived from the env file; regenerating it
# is a no-op when the credential did not change.
"${REPO_ROOT}/scripts/gen-argocd-harbor-repo-secret.sh"

if [[ "${ROBOT_ONLY}" == "1" ]]; then
  log "push-to-harbor complete (--robot-only); deploy the ArgoCD secret if it changed: ./scripts/deploy-secrets.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Charts -> oci://harbor/teknoir: each pinned version is pushed once
# ---------------------------------------------------------------------------
# Tag immutability on the chart project (all repositories, all tags), so no
# client can overwrite a released chart version. Created once; a rule an
# operator disabled is reported and left alone.
project_id="$(api GET "/projects?name=${HARBOR_CHART_PROJECT}&page_size=100" | python3 -c '
import json, sys
for p in json.load(sys.stdin) or []:
    if p.get("name") == sys.argv[1]:
        print(p["project_id"])
        break' "${HARBOR_CHART_PROJECT}")"
[[ -n "${project_id}" ]] || die "Harbor project ${HARBOR_CHART_PROJECT} not found"
immutable_state="$(api GET "/projects/${project_id}/immutabletagrules" | python3 -c '
import json, sys
state = "absent"
for r in json.load(sys.stdin) or []:
    tags = r.get("tag_selectors") or []
    repos = (r.get("scope_selectors") or {}).get("repository") or []
    if any(t.get("decoration") == "matches" and t.get("pattern") == "**" for t in tags) and \
       any(s.get("decoration") == "repoMatches" and s.get("pattern") == "**" for s in repos):
        state = "disabled" if r.get("disabled") else "enabled"
        if state == "enabled":
            break
print(state)')"
case "${immutable_state}" in
  enabled) log "tag immutability rule on ${HARBOR_CHART_PROJECT}: enabled" ;;
  disabled) warn "the tag immutability rule on ${HARBOR_CHART_PROJECT} is DISABLED; left as is (re-enable it in Harbor: Projects > ${HARBOR_CHART_PROJECT} > Policy)" ;;
  *)
    log "creating the tag immutability rule on ${HARBOR_CHART_PROJECT} (all repositories, all tags)"
    api POST "/projects/${project_id}/immutabletagrules" \
      '{"disabled":false,"action":"immutable","template":"immutable_template","tag_selectors":[{"kind":"doublestar","decoration":"matches","pattern":"**"}],"scope_selectors":{"repository":[{"kind":"doublestar","decoration":"repoMatches","pattern":"**"}]}}' >/dev/null
    ;;
esac

log "helm registry login ${HARBOR_HOST}"
printf '%s' "${HARBOR_ADMIN_PASSWORD}" \
  | helm registry login "${HARBOR_HOST}" --username admin --password-stdin "${HELM_TLS[@]}"

# Check every pin first, so nothing is pushed when one cannot be satisfied.
to_push=()
while read -r name version; do
  tgz="${BUNDLE}/charts/${name}-${version}.tgz"
  status="$(api_status GET "/projects/${HARBOR_CHART_PROJECT}/repositories/${name}/artifacts/${version}")"
  case "${status}" in
    200)
      if [[ "${FORCE_CHARTS}" != "1" ]]; then
        log "chart ${name}:${version} already in Harbor — not pushed (Harbor's copy wins)"
        continue
      fi
      [[ -f "${tgz}" ]] || die "--force-charts: ${tgz} not in the bundle"
      warn "--force-charts: will overwrite ${name}:${version} in Harbor"
      ;;
    404)
      [[ -f "${tgz}" ]] || die "chart ${name}:${version} is pinned but neither in Harbor nor in ${BUNDLE}/charts/"
      ;;
    *) die "cannot check ${name}:${version} in Harbor (HTTP ${status})" ;;
  esac
  to_push+=("${tgz}")
done < <(pinned_charts)

for tgz in ${to_push[@]+"${to_push[@]}"}; do
  log "helm push $(basename "${tgz}")"
  helm push "${tgz}" "oci://${HARBOR_HOST}/${HARBOR_CHART_PROJECT}" "${HELM_TLS[@]}" >/dev/null \
    || die "helm push $(basename "${tgz}") failed (an existing tag is immutable: bump the chart version instead)"
done

shopt -s nullglob
for tgz in "${BUNDLE}/charts/"*.tgz; do
  base="$(basename "${tgz}" .tgz)"
  pinned_charts | awk -v b="${base}" '$1 "-" $2 == b {f=1} END {exit !f}' \
    || warn "${base}.tgz is in the bundle but not pinned in versions.env — not pushed"
done
shopt -u nullglob

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
