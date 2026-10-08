#!/usr/bin/env bash
# gate-test.sh — fixture tests for the bundle build's secret-material gates
# (airgap/build/lib-build.sh, render-oneshot.sh). Offline once the pinned build
# tools are in the cache (~/.cache/teknoir-airgap/tools); bash >= 4.4, openssl.
#
#   1. secret_gate: credential-less ArgoCD repository Secrets for
#      harbor.<domain>/<project> pass; any other Secret with data, any
#      credential key, a foreign url, a missing label or url, and undecodable
#      data are refused (fixtures/secrets/{allow,deny,clean,error}-*.yaml)
#   2. pem_private_keys: real keys (generated here, never committed) in a YAML
#      block, commented out, escaped on one line, legacy-encrypted, and the
#      base64 form are found; the upstream documentation examples are not
#   3. chart_secret_findings: a clean chart is clean; credential-like member
#      names, key blocks in any member (also inside a .bz2) and base64 keys
#      in a planted chart are all reported; upstream template names such as
#      templates/repository-credentials-secret.yaml are not
#   4. render-oneshot.sh: a tier rendering the credential-less repository
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
require_cmd openssl bzip2

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

# --- 2. pem_private_keys --------------------------------------------------------------------
P="${T}/pem"
mkdir -p "${P}"
openssl genpkey -algorithm ed25519 -out "${P}/k.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 2>/dev/null \
  | openssl rsa -traditional -aes128 -passout pass:x -out "${P}/enc.pem" 2>/dev/null
{ echo 'tls.key: |'; sed 's/^/  /' "${P}/k.pem"; } > "${P}/block.yaml"
{ echo '# tls.key: |'; sed 's/^/#   /' "${P}/k.pem"; } > "${P}/commented.yaml"
printf 'key: "%s"\n' "$(awk '{printf "%s\\n", $0}' "${P}/k.pem")" > "${P}/oneline.yaml"
for f in block commented oneline; do
  check "pem_private_keys finds a key (${f})" "$(pem_private_keys "${P}/${f}.yaml" | wc -l)" "1"
done
check "pem_private_keys finds a legacy encrypted key (Proc-Type/DEK-Info)" "$(pem_private_keys "${P}/enc.pem" | wc -l)" "1"
check "pem_private_keys ignores the documentation examples" "$(pem_private_keys "${FIX}/pem/doc-examples.yaml")" ""
base64 -w0 "${P}/k.pem" > "${P}/b64.txt"
if grep -qE "${PEM_B64_RE}" "${P}/b64.txt"; then ok "PEM_B64_RE finds a base64-encoded key"; else not_ok "PEM_B64_RE finds a base64-encoded key"; fi
check "pem_private_keys_tree scans a directory" "$(pem_private_keys_tree "${P}" | wc -l)" "5"

# --- 3. chart_secret_findings ------------------------------------------------------------------
C="${T}/charts"
mkdir -p "${C}"
cp -r "${FIX}/chart-src/repo-secret" "${C}/src"
helm_package_reproducible "${C}/src" "${C}"
check "chart_secret_findings: the clean fixture chart" "$(chart_secret_findings "${C}/fixture-repo-0.0.1.tgz" "${C}/scan-clean")" ""
# planted: what an untracked file under --allow-dirty could carry
cp -r "${FIX}/chart-src/repo-secret" "${C}/planted"
mkdir -p "${C}/planted/files"
cp "${P}/k.pem" "${C}/planted/files/ca.key"
cp "${P}/k.pem" "${C}/planted/files/notes.txt"
bzip2 -c "${P}/k.pem" > "${C}/planted/files/crds.bz2"
base64 -w0 "${P}/k.pem" > "${C}/planted/files/blob.txt"
sed 's/^/# /' "${P}/k.pem" >> "${C}/planted/values.yaml"
echo 'apiVersion: v1' > "${C}/planted/files/kubeconfig"
echo '{{/* a manifest template with an upstream-style name */}}' > "${C}/planted/templates/kubeconfig-secret.yaml"
tar -czf "${C}/planted.tgz" -C "${C}" planted
out="$(chart_secret_findings "${C}/planted.tgz" "${C}/scan-planted")"
for want in "name planted/files/ca.key" "name planted/files/kubeconfig" "pem planted/files/ca.key:1" \
            "pem planted/files/notes.txt:1" "pem planted/files/crds.bz2.unpacked:1" "pem planted/values.yaml:" \
            "b64 planted/files/blob.txt"; do
  has "chart_secret_findings reports ${want}" "${out}" "${want}"
done
lacks "chart_secret_findings: upstream template names are not credential files" "${out}" "templates/"
printf 'not gzip' > "${C}/broken.tgz"
has "chart_secret_findings: an unreadable archive is an error, never clean" \
  "$(chart_secret_findings "${C}/broken.tgz" "${C}/scan-broken")" "error "

# --- 4. render-oneshot.sh ------------------------------------------------------------------------
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
