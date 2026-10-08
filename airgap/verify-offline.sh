#!/usr/bin/env bash
# verify-offline.sh — offline-readiness verification (plan §8):
#   1. bash -n every airgap/ + scripts/ shell script
#   2. helm template every pinned chart version (lib.sh:load_chart_pins;
#      bundle .tgz, else the working tree at that version) and grep the
#      rendered output for internet dependencies
#      (teknoir.cloud | github.com | storage.googleapis.com | ghcr creds)
#      => zero hits per chart = pass; and check the pins against the pinned
#      app-of-apps (lib.sh:check_app_of_apps_pins)
#   3. image completeness: every image the pinned charts reference (image:
#      fields and image-valued container args) plus images-extra.txt must be in
#      the bundle image index (<bundle>/images/images.txt), else FAIL
#   4. optional (--live): diff the images running in the cluster against the
#      bundle image list (via KUBECONFIG kubectl, or ssh to $TEKNOIR_HOST)
#
# Usage: airgap/verify-offline.sh [--live] [--bundle DIR]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --live         also diff live-cluster images vs the bundle image list
                 (uses \$KUBECONFIG kubectl when available, else ssh ${TEKNOIR_HOST})
  --bundle DIR   bundle directory (default: $(bundle_dir))
  -h, --help     show this help
EOF
}

LIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) LIVE=1 ;;
    --bundle) BUNDLE_DIR="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# Always-forbidden strings (real configuration, never legitimate offline):
STRICT_PATTERN='teknoir\.cloud|ghcr-token'
# Internet hosts flagged only in configuration *values* (repoURL:, url:, ...);
# upstream CRDs legitimately mention github.com in schema description prose.
CONFIG_URL_PATTERN='(repoURL|url|host|hostname|server|endpoint|registry|repository|issuer)"?[[:space:]]*:[[:space:]]*[^[:space:]]*(github\.com|storage\.googleapis\.com)'
# Config values that are known-benign in the air gap and must not fail the gate.
# Backstage's app-config declares its GitHub App integration host
# (`integrations.github[].host: github.com`). No GitHub App secret is provisioned
# in the air gap and the value never triggers an image/chart pull, so it is an
# inert app-level setting rather than an offline-readiness violation.
BENIGN_CONFIG_PATTERN='host:[[:space:]]*github\.com'
FAILURES=0

fail() {
  warn "$*"
  FAILURES=$((FAILURES + 1))
}

# ---------------------------------------------------------------------------
# 1. bash -n on all shell scripts
# ---------------------------------------------------------------------------
log "== 1/4: bash -n syntax check (airgap/ + scripts/)"
shopt -s nullglob
scripts=("${AIRGAP_DIR}/"*.sh "${REPO_ROOT}/scripts/"*.sh)
shopt -u nullglob
for s in "${scripts[@]}"; do
  if bash -n "${s}" 2>/dev/null; then
    log "  ok: ${s#"${REPO_ROOT}"/}"
  else
    fail "syntax error: ${s#"${REPO_ROOT}"/}"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  log "running shellcheck on airgap/ scripts"
  if ! shellcheck -x -P "${AIRGAP_DIR}" "${AIRGAP_DIR}/"*.sh; then
    fail "shellcheck reported issues in airgap/ scripts"
  fi
else
  warn "shellcheck not installed — skipping"
fi

# ---------------------------------------------------------------------------
# 2. helm template every chart + forbidden-pattern grep
# ---------------------------------------------------------------------------
log "== 2/4: helm template + internet-dependency grep"
require_cmd helm python3
load_chart_pins

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

while read -r name version; do
  if ! dir="$(chart_source "${name}" "${version}")"; then
    warn "skipped: released ${name}-${version} has no .tgz in the bundle (must already be in Harbor)"
    continue
  fi
  helm_dep_build "${dir}" 2>/dev/null || warn "dependency build failed for ${name} (offline?)"
  if ! helm_template_chart "${name}" "${dir}" > "${tmpdir}/${name}.yaml" 2>"${tmpdir}/${name}.err"; then
    fail "helm template FAILED: ${name}-${version} ($(head -1 "${tmpdir}/${name}.err"))"
    continue
  fi
  {
    grep -n -E "${STRICT_PATTERN}" "${tmpdir}/${name}.yaml" || true
    grep -n -E "${CONFIG_URL_PATTERN}" "${tmpdir}/${name}.yaml" \
      | grep -v -E "${BENIGN_CONFIG_PATTERN}" || true
  } > "${tmpdir}/${name}.hits"
  hits="$(wc -l < "${tmpdir}/${name}.hits" | tr -d ' ')"
  if [[ "${hits}" -eq 0 ]]; then
    log "  pass: ${name}-${version} (zero internet references)"
  else
    fail "${name}-${version}: ${hits} internet reference(s):"
    head -10 "${tmpdir}/${name}.hits" >&2
  fi
  extract_images < "${tmpdir}/${name}.yaml" | sed "s|\$| ${name}-${version}|" >> "${tmpdir}/required-images"
done < <(pinned_charts)

# The pins (pins.txt) must be exactly what the pinned app-of-apps deploys.
( check_app_of_apps_pins ) || fail "the chart pins do not match the pinned app-of-apps"

# ---------------------------------------------------------------------------
# 3. image completeness: the bundle must carry every image the pins need
# ---------------------------------------------------------------------------
log "== 3/4: image completeness (pinned charts + images-extra.txt vs bundle index)"
INDEX_FILE="$(bundle_dir)/images/images.txt"
if [[ ! -f "${INDEX_FILE}" ]]; then
  fail "no bundle image index at ${INDEX_FILE} (run collect-images.sh / make-bundle.sh)"
else
  # Plain file lookups: `awk | grep -q` can report a miss under pipefail when
  # grep exits early and awk dies of SIGPIPE.
  cut -d' ' -f1 "${INDEX_FILE}" > "${tmpdir}/bundle-images"
  extra_images | sed 's|$| images-extra.txt|' >> "${tmpdir}/required-images"
  : > "${tmpdir}/missing-images"
  while read -r ref from; do
    if ! grep -qxF -- "${ref}" "${tmpdir}/bundle-images"; then
      warn "missing from the bundle: ${ref} (needed by ${from})"
      echo "${ref}" >> "${tmpdir}/missing-images"
    fi
  done < <(sort -u "${tmpdir}/required-images")
  missing_images="$(sort -u "${tmpdir}/missing-images" | wc -l | tr -d ' ')"
  if [[ "${missing_images}" -eq 0 ]]; then
    log "  pass: all $(cut -d' ' -f1 "${tmpdir}/required-images" | sort -u | wc -l | tr -d ' ') required images are in the bundle"
  else
    fail "${missing_images} required image(s) missing from the bundle — re-run collect-images.sh (or extend images-extra.txt)"
  fi
fi

# ---------------------------------------------------------------------------
# 3. optional live-cluster image diff
# ---------------------------------------------------------------------------
if [[ "${LIVE}" == "1" ]]; then
  log "== 4/4: live-cluster image diff vs bundle"
  BUNDLE="$(bundle_dir)"
  INDEX_FILE="${BUNDLE}/images/images.txt"
  if [[ ! -f "${INDEX_FILE}" ]]; then
    fail "no bundle image index at ${INDEX_FILE} (run collect-images.sh first)"
  else
    jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}'
    live_images=""
    if [[ -n "${KUBECONFIG:-}" ]] && command -v kubectl >/dev/null 2>&1 && kubectl version >/dev/null 2>&1; then
      log "querying live images via local kubectl (KUBECONFIG)"
      live_images="$(kubectl get pods -A -o jsonpath="${jsonpath}")"
    elif ssh_query "true" 2>/dev/null; then
      log "querying live images via ssh ${TEKNOIR_HOST}"
      live_images="$(remote_kubectl_query "get pods -A -o jsonpath='${jsonpath}'")"
    else
      fail "no cluster access (neither KUBECONFIG kubectl nor ssh ${TEKNOIR_HOST})"
    fi

    if [[ -n "${live_images}" ]]; then
      # Map mirrored refs (harbor.teknoir.airgapped/<project>/x) back to upstream form
      normalize_live() {
        local ref="$1" entry upstream project
        for entry in "${MIRRORED_REGISTRIES[@]}"; do
          upstream="${entry%% *}"
          project="${entry##* }"
          if [[ "${ref}" == "${HARBOR_HOST}/${project}/"* ]]; then
            echo "${upstream}/${ref#"${HARBOR_HOST}/${project}"/}"
            return 0
          fi
        done
        echo "${ref}"
      }
      missing=0
      while read -r img; do
        [[ -n "${img}" ]] || continue
        upstream_ref="$(normalize_live "${img}")"
        if ! cut -d' ' -f1 "${INDEX_FILE}" | grep -xF -- "${upstream_ref}" >/dev/null; then
          warn "running image NOT in bundle: ${img} (upstream: ${upstream_ref})"
          missing=$((missing + 1))
        fi
      done < <(printf '%s\n' "${live_images}" | sort -u)
      if [[ "${missing}" -eq 0 ]]; then
        log "  pass: every running image is covered by the bundle"
      else
        fail "${missing} running image(s) missing from the bundle — extend images-extra.txt"
      fi
    fi
  fi
else
  log "== 4/4: live-cluster image diff skipped (enable with --live)"
fi

# ---------------------------------------------------------------------------
echo >&2
if [[ "${FAILURES}" -eq 0 ]]; then
  log "verify-offline: PASS (no internet dependencies detected)"
  exit 0
else
  die "verify-offline: FAIL (${FAILURES} problem(s) found)"
fi
