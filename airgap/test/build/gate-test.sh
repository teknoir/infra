#!/usr/bin/env bash
# gate-test.sh — fixture tests for the bundle build's secret-material gates
# (airgap/build/lib-build.sh, render-oneshot.sh). Offline once the pinned build
# tools are in the cache (~/.cache/teknoir-airgap/tools); bash >= 4.4.
#
#   1. secret_gate: credential-less ArgoCD repository Secrets for
#      harbor.<domain>/<project> pass; any other Secret with data, any
#      credential key, a foreign url, a missing label or url, and undecodable
#      data are refused (fixtures/secrets/{allow,deny,clean,error}-*.yaml)
#   2. render-oneshot.sh: a tier rendering the credential-less repository
#      Secret passes; with basic-auth keys, or for another domain, it fails
#
# Usage: airgap/test/build/gate-test.sh        (exit 0 = every check passed)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="${HERE}/fixtures"
BUILD="$(cd "${HERE}/../../build" && pwd)"
SITE="$(cd "${HERE}/../../site" && pwd)/teknoir-local.env"
# shellcheck source-path=SCRIPTDIR source=../../build/lib-build.sh
source "${BUILD}/lib-build.sh"

T="$(mktemp -d)"
trap 'rm -rf -- "${T}"' EXIT
use_build_tools "${T}/work"
REPO="harbor.teknoir.airgapped/teknoir"

N=0 FAILED=0
ok()     { N=$((N + 1)); printf 'ok %d - %s\n' "${N}" "$1"; }
not_ok() {
  N=$((N + 1)); FAILED=$((FAILED + 1))
  printf 'not ok %d - %s\n' "${N}" "$1"
  if [[ -n "${2:-}" ]]; then while IFS= read -r l; do printf '#   %s\n' "${l}"; done <<<"$2"; fi
}
check()  { if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1" "want: $3"$'\n'"got:  $2"; fi; }
has()    { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else not_ok "$1" "missing: $3"$'\n'"in: $2"; fi; }
lacks()  { if ! grep -qF -- "$3" <<<"$2"; then ok "$1"; else not_ok "$1" "unexpected: $3"$'\n'"in: $2"; fi; }

# --- 1. secret_gate ------------------------------------------------------------------------
for f in "${FIX}/secrets/"*.yaml; do
  name="$(basename "${f}" .yaml)"
  rc=0
  out="$(secret_gate "${REPO}" "${f}" 2>"${T}/err")" || rc=$?
  case "${name}" in
    allow-*) check "secret_gate ${name}: allowed" "${rc} $(cut -d' ' -f1 <<<"${out}" | sort -u)" "0 allow" ;;
    deny-*)  check "secret_gate ${name}: refused" "${rc} $(cut -d' ' -f1 <<<"${out}" | sort -u)" "0 deny" ;;
    clean-*) check "secret_gate ${name}: no Secret with data" "${rc} ${out}" "0 " ;;
    error-*)
      check "secret_gate ${name}: fails closed" "$(( rc != 0 )) ${out}" "1 "
      lacks "secret_gate ${name}: never quotes the value" "$(cat "${T}/err")" "not-base64"
      ;;
  esac
done
out="$(secret_gate "${REPO}" "${FIX}/secrets/allow-repo-data.yaml" "${FIX}/secrets/deny-repo-password.yaml")"
check "secret_gate classifies each Secret of several files" "$(cut -d' ' -f1,2 <<<"${out}")" \
  "allow teknoir-system/argocd-repo-harbor-teknoir"$'\n'"deny teknoir-system/repo-basic-auth"
out="$(secret_gate "harbor.example.test/teknoir" "${FIX}/secrets/allow-repo-data.yaml")"
has "secret_gate refuses the right Secret for another domain" "${out}" "deny teknoir-system/argocd-repo-harbor-teknoir"
lacks "secret_gate never prints a url value" \
  "$(secret_gate "${REPO}" "${FIX}/secrets/deny-repo-url-override.yaml" "${FIX}/secrets/deny-repo-wrong-domain.yaml")" "github.com"

# --- 2. render-oneshot.sh ------------------------------------------------------------------------
render_tier() {
  # render_tier <fixture-dir> <chart-name> <site> — rc of render-oneshot.sh; output in ${T}/render.log
  local src="$1" chart="$2" site="$3" s
  s="${T}/r-${chart}-$(basename "${site}")"
  mkdir -p "${s}/stage/node/charts" "${s}/work/renders"
  cp -r "${T}/work/bin" "${s}/work/bin"
  cp -r "${src}" "${s}/src"
  helm_package_reproducible "${s}/src" "${s}/stage/node/charts"
  jq -cn --arg c "${chart}" '{app: "argo", chart: $c, version: "0.0.1", repo: "", namespace: "teknoir-system",
         release: "argo", skipCrds: false, overrides: {}, deployed: false, nChartSources: 1}' > "${s}/work/apps.jsonl"
  ONESHOT_TIERS=argo "${BUILD}/render-oneshot.sh" --stage "${s}/stage" --work "${s}/work" --site "${site}" > "${T}/render.log" 2>&1
}
rc=0; render_tier "${FIX}/chart-src/repo-secret" fixture-repo "${SITE}" || rc=$?
check "render-oneshot: the credential-less repository Secret passes" "${rc}" "0"
has "render-oneshot: logs the allowed Secret" "$(cat "${T}/render.log")" "credential-less ArgoCD repository Secret"
rc=0; render_tier "${FIX}/chart-src/repo-secret-password" fixture-repo-password "${SITE}" || rc=$?
check "render-oneshot: a repository Secret with credentials fails" "$(( rc != 0 ))" "1"
has "render-oneshot: names the credential keys" "$(cat "${T}/render.log")" "keys beyond the credential-less set: password,username"
sed 's/^TEKNOIR_DOMAIN=.*/TEKNOIR_DOMAIN=example.test/' "${SITE}" > "${T}/other.env"
rc=0; render_tier "${FIX}/chart-src/repo-secret" fixture-repo "${T}/other.env" || rc=$?
check "render-oneshot: the repository Secret of another domain fails" "$(( rc != 0 ))" "1"
lacks "render-oneshot: never prints the Secret's url" "$(cat "${T}/render.log")" "harbor.teknoir.airgapped/teknoir"

echo "1..${N}"
if (( FAILED > 0 )); then
  echo "# ${FAILED} of ${N} checks failed"
  exit 1
fi
echo "# all ${N} checks passed"
