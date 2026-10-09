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

# --- 5. teamspace plugin supply (TS-C3) -------------------------------------------------------
PF="${FIX}/plugins"
# rc_of <cmd...> — the exit status of a command run in a subshell (die exits)
rc_of() { local rc=0; ( "$@" ) > "${T}/rc.out" 2>&1 || rc=$?; echo "${rc}"; }

cfg() { plugin_chart_config "$1" teknoir.airgapped && echo "ok ${PLUGIN_REPO} ${PLUGIN_VERSION}" || echo "error ${PLUGIN_CONFIG_ERROR}"; }
check "plugin_chart_config: the Harbor repo and an exact version pass" "$(cfg "${PF}/pc-harbor.yaml")" "ok harbor.teknoir.airgapped/teknoir 0.0.99"
has "plugin_chart_config: a github.io repo fails" "$(cfg "${PF}/pc-github.yaml")" "error ConfigMap profile-controller-config: PLUGIN_CHART_REPO is 'https://teknoir.github.io/profile-plugins-helm', not harbor.teknoir.airgapped/teknoir"
has "plugin_chart_config: an oci:// prefix fails" "$(cfg "${PF}/pc-oci.yaml")" "error ConfigMap profile-controller-config: PLUGIN_CHART_REPO is 'oci://"
has "plugin_chart_config: a render without PLUGIN_CHART_REPO fails (compiled github.io default)" "$(cfg "${PF}/pc-nokey.yaml")" "sets no PLUGIN_CHART_REPO"
has "plugin_chart_config: an empty version fails" "$(cfg "${PF}/pc-noversion.yaml")" "PLUGIN_CHART_VERSION '' is not an exact chart version"
has "plugin_chart_config: another domain fails" "$(plugin_chart_config "${PF}/pc-harbor.yaml" example.test || echo "error ${PLUGIN_CONFIG_ERROR}")" "not harbor.example.test/teknoir"
check "profile_names: the GitOps Profile" "$(profile_names "${PF}/pc-harbor.yaml")" "teknoir-default"
check "configmap_value: an absent ConfigMap is exit 1" "$(configmap_value "${PF}/pc-harbor.yaml" nope X >/dev/null || echo $?)" "1"
check "configmap_value: an absent key is exit 2" "$(configmap_value "${PF}/pc-nokey.yaml" profile-controller-config PLUGIN_CHART_REPO >/dev/null || echo $?)" "2"

# fetch_plugin_chart against a file:// repo with charts packaged here; the
# pins are computed from them (the real pins are in versions.env)
R="${T}/plugin-repo"
mkdir -p "${R}/src"
for c in alpha beta; do
  mkdir -p "${R}/src/profile-plugin-${c}/templates"
  printf 'apiVersion: v2\nname: profile-plugin-%s\nversion: 0.0.7\n' "${c}" > "${R}/src/profile-plugin-${c}/Chart.yaml"
  printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: %s}\nspec:\n  template:\n    spec:\n      containers:\n        - name: c\n          image: ghcr.io/teknoir/%s:latest\n        - name: d\n          image: docker.io/library/alpine:latest\n' "${c}" "${c}" \
    > "${R}/src/profile-plugin-${c}/templates/deploy.yaml"
  helm_package_reproducible "${R}/src/profile-plugin-${c}" "${R}"
done
sha_a="$(sha256_file "${R}/profile-plugin-alpha-0.0.7.tgz")"
sha_b="$(sha256_file "${R}/profile-plugin-beta-0.0.7.tgz")"
write_index() {
  # write_index <alpha digest> <beta digest> — urls relative, as chart-releaser's are absolute: both work
  printf 'apiVersion: v1\nentries:\n  profile-plugin-alpha:\n    - version: 0.0.7\n      digest: %s\n      urls: [profile-plugin-alpha-0.0.7.tgz]\n  profile-plugin-beta:\n    - version: 0.0.7\n      digest: %s\n      urls: ["file://%s/profile-plugin-beta-0.0.7.tgz"]\n' \
    "$1" "$2" "${R}" > "${R}/index.yaml"
}
write_index "${sha_a}" "${sha_b}"
REAL_CACHE="${CACHE_DIR}"
CACHE_DIR="${T}/plugin-cache"
PROFILE_PLUGIN_SOURCE="file://${R}"
PINNED_SHA256["profile-plugin-alpha-0.0.7"]="${sha_a}"
PINNED_SHA256["profile-plugin-beta-0.0.7"]="${sha_b}"
check "fetch_plugin_chart: pin = index = file passes" "$(rc_of fetch_plugin_chart profile-plugin-alpha 0.0.7 "${T}/pc-out")" "0"
check "fetch_plugin_chart: the archive is copied byte for byte" "$(sha256_file "${T}/pc-out/profile-plugin-alpha-0.0.7.tgz")" "${sha_a}"
check "fetch_plugin_chart: an absolute index url works too" "$(rc_of fetch_plugin_chart profile-plugin-beta 0.0.7 "${T}/pc-out")" "0"
check "fetch_plugin_chart: cached by sha256" "$(ls "${CACHE_DIR}/charts/${sha_a}")" "profile-plugin-alpha-0.0.7.tgz"
rm -rf "${CACHE_DIR}"
PINNED_SHA256["profile-plugin-alpha-0.0.7"]="$(printf '%064d' 1)"
mkdir -p "${T}/pc-out2"
check "fetch_plugin_chart: a plugin sha mismatch (pin vs index) fails" "$(rc_of fetch_plugin_chart profile-plugin-alpha 0.0.7 "${T}/pc-out2")" "1"
has "fetch_plugin_chart: names both digests" "$(cat "${T}/rc.out")" "lists digest ${sha_a}, but versions.env pins $(printf '%064d' 1)"
write_index "$(printf '%064d' 1)" "${sha_b}"
check "fetch_plugin_chart: an archive that differs from pin and index fails" "$(rc_of fetch_plugin_chart profile-plugin-alpha 0.0.7 "${T}/pc-out2")" "1"
has "fetch_plugin_chart: reports the downloaded sha256" "$(cat "${T}/rc.out")" "downloaded sha256 ${sha_a} differs from the pin"
check "fetch_plugin_chart: nothing cached after a failure" "$(find "${CACHE_DIR}/charts" -name '*.tgz' | wc -l)" "0"
check "fetch_plugin_chart: nothing copied after a failure" "$(find "${T}/pc-out2" -type f | wc -l)" "0"
PINNED_SHA256["profile-plugin-alpha-0.0.7"]="${sha_a}"
write_index "${sha_a}" "${sha_b}"
fetch_plugin_chart profile-plugin-alpha 0.0.7 "${T}/pc-out3" 2>/dev/null
echo tampered >> "${CACHE_DIR}/charts/${sha_a}/profile-plugin-alpha-0.0.7.tgz"
check "fetch_plugin_chart: a modified cache entry fails" "$(rc_of fetch_plugin_chart profile-plugin-alpha 0.0.7 "${T}/pc-out3")" "1"
has "fetch_plugin_chart: says how to recover" "$(cat "${T}/rc.out")" "the cache entry was modified"
check "fetch_plugin_chart: no pin, no download" "$(rc_of fetch_plugin_chart profile-plugin-gamma 0.0.7 "${T}/pc-out3")" "1"
CACHE_DIR="${REAL_CACHE}"
PROFILE_PLUGIN_SOURCE="https://teknoir.github.io/profile-plugins-helm"

# collect-charts.sh end to end on a fixture gitops tree (an app-of-apps that
# deploys only profile-controller), with the real PROFILE_PLUGIN_CHARTS and
# pins: the 9 published archives (downloaded once into the build cache,
# offline afterwards), their teamspace-* renders and apps.jsonl lines (K8)
make_gitops() {
  # make_gitops <dir> [sed expression for profile-controller values.yaml] — a git checkout of the fixture
  local d="$1"
  mkdir -p "${d}"
  cp -r "${PF}/gitops/charts" "${d}/charts"
  if [[ -n "${2:-}" ]]; then sed -i -e "$2" "${d}/charts/profile-controller/values.yaml"; fi
  git -C "${d}" init -q -b airgap-redesign-fixture
  git -C "${d}" add -A
  git -C "${d}" -c user.name=gate-test -c user.email=gate-test@example.invalid commit -qm fixture
}
make_gitops "${T}/gitops"
CC="${T}/cc"
rc=0
APP_OF_APPS_VERSION=9.9.9 "${BUILD}/collect-charts.sh" --gitops "${T}/gitops" --domain teknoir.airgapped \
  --stage "${CC}/stage" --work "${CC}/work" > "${T}/cc.log" 2>&1 || rc=$?
check "collect-charts: a profile-controller with the Harbor plugin repo builds" "${rc}" "0"
[[ "${rc}" == 0 ]] || sed 's/^/#   /' "${T}/cc.log"
check "collect-charts: pins.txt lists the 9 profile-plugin charts at 0.0.99" \
  "$(grep -c '^profile-plugin-[a-z-]* 0\.0\.99$' "${CC}/stage/node/charts/pins.txt" 2>/dev/null)" "9"
check "collect-charts: app-of-apps stays first in pins.txt" "$(head -1 "${CC}/stage/node/charts/pins.txt" 2>/dev/null)" "app-of-apps 9.9.9"
ok_sums=1
for p in ${PROFILE_PLUGIN_CHARTS}; do
  [[ "$(sha256_file "${CC}/stage/node/charts/profile-plugin-${p}-0.0.99.tgz" 2>/dev/null)" == "${PINNED_SHA256["profile-plugin-${p}-0.0.99"]}" ]] || ok_sums=0
done
check "collect-charts: every plugin archive equals its versions.env pin" "${ok_sums}" "1"
check "collect-charts: K8 apps.jsonl lines" \
  "$(jq -c 'select(.app == "teamspace-fleet-metrics") | {app, chart, version, namespace, release, overrides, deployed}' "${CC}/work/apps.jsonl" 2>/dev/null)" \
  '{"app":"teamspace-fleet-metrics","chart":"profile-plugin-fleet-metrics","version":"0.0.99","namespace":"teknoir-default","release":"fleet-metrics","overrides":{"values":"domain: teknoir.airgapped"},"deployed":false}'
check "collect-charts: one teamspace render per plugin" "$(find "${CC}/work/renders" -name 'teamspace-*.yaml' -size +0 2>/dev/null | wc -l)" "9"
has "collect-charts: the deadend render names its image" "$(extract_images < "${CC}/work/renders/teamspace-deadend.yaml" 2>/dev/null)" "ghcr.io/teknoir/deadend:latest"
has "collect-charts: plugins rendered for the Profile's namespace" "$(grep -m1 'namespace: teknoir-default' "${CC}/work/renders/teamspace-emqx.yaml" 2>/dev/null)" "teknoir-default"

# plugin_supply_gate over that output: complete, then with one image dropped
# from images.lock, a github.io repo, a tampered archive and an extra plugin
GATE_MSGS=()
record() { GATE_MSGS+=("$*"); }
cat "${CC}/work/renders/"*.yaml | extract_images | LC_ALL=C sort -u \
  | awk '{printf "%s@sha256:%064d slug%d\n", $1, NR, NR}' > "${T}/images.lock"
plugin_supply_gate record "${CC}/work/renders" "${CC}/stage/node/charts" "${T}/images.lock" teknoir.airgapped
check "plugin_supply_gate: the complete supply passes" "${#GATE_MSGS[@]}" "0"
GATE_MSGS=()
grep -v '^ghcr.io/teknoir/observatory-wss-mqtt:latest@' "${T}/images.lock" > "${T}/images-missing.lock"
plugin_supply_gate record "${CC}/work/renders" "${CC}/stage/node/charts" "${T}/images-missing.lock" teknoir.airgapped
check "plugin_supply_gate: a missing plugin image fails" "${GATE_MSGS[*]:-}" \
  "teamspace plugins: image ghcr.io/teknoir/observatory-wss-mqtt:latest (teamspace-observatory) is not in images.lock"
GATE_MSGS=()
cp -r "${CC}/work/renders" "${T}/renders-gh"
cp "${PF}/pc-github.yaml" "${T}/renders-gh/profile-controller.yaml"
plugin_supply_gate record "${T}/renders-gh" "${CC}/stage/node/charts" "${T}/images.lock" teknoir.airgapped
has "plugin_supply_gate: a github.io plugin repo fails" "${GATE_MSGS[*]:-}" "PLUGIN_CHART_REPO is 'https://teknoir.github.io/profile-plugins-helm'"
GATE_MSGS=()
cp -r "${CC}/stage/node/charts" "${T}/charts-bad"
printf 'x' >> "${T}/charts-bad/profile-plugin-jwks-0.0.99.tgz"
echo "profile-plugin-postgres 0.0.99" >> "${T}/charts-bad/pins.txt"
sed -i '/^profile-plugin-grafana /d' "${T}/charts-bad/pins.txt"
plugin_supply_gate record "${CC}/work/renders" "${T}/charts-bad" "${T}/images.lock" teknoir.airgapped
has "plugin_supply_gate: a plugin archive that differs from its pin fails" "${GATE_MSGS[*]:-}" "node/charts/profile-plugin-jwks-0.0.99.tgz has sha256"
has "plugin_supply_gate: a plugin missing from pins.txt fails" "${GATE_MSGS[*]:-}" "profile-plugin-grafana 0.0.99 is not in node/charts/pins.txt"
has "plugin_supply_gate: an unsupported plugin (postgres) fails" "${GATE_MSGS[*]:-}" "profile-plugin-postgres is in pins.txt but not in PROFILE_PLUGIN_CHARTS"

# the build refuses a profile-controller whose plugin repo is github.io
make_gitops "${T}/gitops-gh" 's#pluginChartRepo: .*#pluginChartRepo: https://teknoir.github.io/profile-plugins-helm#'
rc=0
APP_OF_APPS_VERSION=9.9.9 "${BUILD}/collect-charts.sh" --gitops "${T}/gitops-gh" --domain teknoir.airgapped \
  --stage "${T}/cc-gh/stage" --work "${T}/cc-gh/work" > "${T}/cc-gh.log" 2>&1 || rc=$?
check "collect-charts: a github.io plugin repo fails the build" "${rc}" "1"
has "collect-charts: names the repo" "$(cat "${T}/cc-gh.log")" "PLUGIN_CHART_REPO is 'https://teknoir.github.io/profile-plugins-helm', not harbor.teknoir.airgapped/teknoir"
make_gitops "${T}/gitops-nokey" '/pluginChartRepo:/d'
rc=0
APP_OF_APPS_VERSION=9.9.9 "${BUILD}/collect-charts.sh" --gitops "${T}/gitops-nokey" --domain teknoir.airgapped \
  --stage "${T}/cc-nk/stage" --work "${T}/cc-nk/work" > "${T}/cc-nk.log" 2>&1 || rc=$?
check "collect-charts: a profile-controller without PLUGIN_CHART_REPO fails the build" "${rc}" "1"
rc=0
PROFILE_PLUGIN_CHARTS="" APP_OF_APPS_VERSION=9.9.9 "${BUILD}/collect-charts.sh" --gitops "${T}/gitops-nokey" --domain teknoir.airgapped \
  --stage "${T}/cc-nk2/stage" --work "${T}/cc-nk2/work" > "${T}/cc-nk2.log" 2>&1 || rc=$?
check "collect-charts: PROFILE_PLUGIN_CHARTS=\"\" builds without plugins (rollback bundles)" "${rc} $(grep -c '^profile-plugin-' "${T}/cc-nk2/stage/node/charts/pins.txt" 2>/dev/null)" "0 0"
rc=0
APP_OF_APPS_VERSION=9.9.9 "${BUILD}/collect-charts.sh" --gitops "${T}/gitops" --domain teknoir.airgapped \
  --stage "${T}/cc-dry/stage" --work "${T}/cc-dry/work" --dry-run > "${T}/cc-dry.log" 2>&1 || rc=$?
check "collect-charts --dry-run: exits 0" "${rc}" "0"
check "collect-charts --dry-run: plans the 9 plugin pins" "$(grep -c '\[dry-run\] teamspace plugin profile-plugin-[a-z-]* 0\.0\.99 from https://teknoir.github.io/profile-plugins-helm (pin [0-9a-f]\{64\})' "${T}/cc-dry.log")" "9"
check "collect-charts --dry-run: no plugin archive downloaded or staged" "$(find "${T}/cc-dry" -name 'profile-plugin-*.tgz' | wc -l)" "0"

# --- 6. image pin policy (G-09, R3) -----------------------------------------------------------
D64="$(printf 'a%.0s' {1..64})"
check "teknoir_pin_ok: sha- tag + digest" "$(teknoir_pin_ok "ghcr.io/teknoir/x:sha-29d2ed6a@sha256:${D64}" && echo y)" "y"
check "teknoir_pin_ok: branch build tag + digest" "$(teknoir_pin_ok "ghcr.io/teknoir/x:teknoir-cloud-20260413-054338@sha256:${D64}" && echo y)" "y"
check "teknoir_pin_ok: semver + digest" "$(teknoir_pin_ok "ghcr.io/teknoir/x:v1.2.3@sha256:${D64}" && echo y)" "y"
for bad in "ghcr.io/teknoir/x:latest" "ghcr.io/teknoir/x:sha-29d2ed6a" "ghcr.io/teknoir/x:robot@sha256:${D64}" \
           "ghcr.io/teknoir/x:latest@sha256:${D64}" "ghcr.io/teknoir/x@sha256:${D64}" "ghcr.io/teknoir/x:1.2@sha256:${D64}" \
           "ghcr.io/teknoir/x:sha-29d2ed6a@sha256:abc"; do
  check "teknoir_pin_ok refuses ${bad:0:56}" "$(teknoir_pin_ok "${bad}" && echo y || echo n)" "n"
done
LISTS="${T}/lists"
mkdir -p "${LISTS}"
printf '%s\n' "ghcr.io/teknoir/user-controller:sha-0930b615@sha256:${D64}" "docker.io/library/postgres:16.15@sha256:${D64}" \
  "docker.io/library/busybox:1.36.1" > "${LISTS}/platform-ok"
printf '%s\n' "ghcr.io/teknoir/deadend:latest" "docker.io/library/alpine:latest" "docker.io/emqx/emqx:5.8.9" > "${LISTS}/teamspace"
printf '%s\n' "docker.io/istio/proxyv2:1.29.2" "docker.io/alpine/k8s:1.34.11" > "${LISTS}/oneshot-ok"
FAILS=() WARNS=()
pfail() { FAILS+=("$*"); }
pwarn() { WARNS+=("$*"); }
image_policy pfail pwarn "${LISTS}/platform-ok" "${LISTS}/teamspace" "${LISTS}/oneshot-ok" "${LISTS}/mutable"
check "image_policy: pinned platform images and teamspace :latest pass" "${#FAILS[@]}" "0"
check "image_policy: the teamspace mutable list (R3)" "$(cat "${LISTS}/mutable")" \
  "docker.io/library/alpine:latest"$'\n'"ghcr.io/teknoir/deadend:latest"
has "image_policy: teamspace :latest only warns" "${WARNS[*]}" "teamspace plugin image on a mutable tag (accepted for r5, pinned by digest in images.lock only): ghcr.io/teknoir/deadend:latest"
FAILS=() WARNS=()
printf '%s\n' "ghcr.io/teknoir/backstage:robot" "docker.io/library/postgres:16" > "${LISTS}/platform-bad"
image_policy pfail pwarn "${LISTS}/platform-bad" /dev/null "${LISTS}/oneshot-ok"
has "image_policy: a floating Teknoir tag in a platform render fails" "${FAILS[*]:-}" "unpinned Teknoir image ghcr.io/teknoir/backstage:robot"
has "image_policy: a major-only non-Teknoir tag warns" "${WARNS[*]:-}" "floating image tag (latest or major-only; the build locks today's digest): docker.io/library/postgres:16"
FAILS=() WARNS=()
ALLOW_MUTABLE_TEKNOIR_TAGS=1 image_policy pfail pwarn "${LISTS}/platform-bad" /dev/null "${LISTS}/oneshot-ok"
check "image_policy: ALLOW_MUTABLE_TEKNOIR_TAGS=1 downgrades it to a warning" "${#FAILS[@]}" "0"
has "image_policy: ... and says so" "${WARNS[*]:-}" "ALLOW_MUTABLE_TEKNOIR_TAGS=1: the bundle is -mutable"
FAILS=() WARNS=()
printf '%s\n' "docker.io/library/busybox:1.36.1@sha256:${D64}" > "${LISTS}/oneshot-bad"
image_policy pfail pwarn "${LISTS}/platform-ok" /dev/null "${LISTS}/oneshot-bad"
has "image_policy: a digest in a one-shot tier fails" "${FAILS[*]:-}" "one-shot tier image docker.io/library/busybox:1.36.1@sha256:${D64} carries a digest"

# a pinned index digest (collect-images.sh resolve): the amd64 child is the pin
IDX="${T}/index.json"
cat > "${IDX}" <<EOF
{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
  {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:$(printf 'b%.0s' {1..64})", "size": 1, "platform": {"os": "linux", "architecture": "amd64"}},
  {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:$(printf 'c%.0s' {1..64})", "size": 1, "platform": {"os": "unknown", "architecture": "unknown"}}]}
EOF
printf '{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": {"digest": "sha256:%s"}, "layers": []}\n' "${D64}" > "${T}/image.json"
check "manifest_platform_digest: the amd64 child of an index" "$(manifest_platform_digest "${IDX}" "sha256:${D64}" linux amd64)" "sha256:$(printf 'b%.0s' {1..64})"
check "manifest_platform_digest: a single image is itself" "$(manifest_platform_digest "${T}/image.json" "sha256:${D64}" linux amd64)" "sha256:${D64}"
check "manifest_platform_digest: no arm64 child" "$(manifest_platform_digest "${IDX}" "sha256:${D64}" linux arm64 || echo none)" "none"
pinned_index_error "ghcr.io/teknoir/x:sha-1234567@sha256:${D64}" "sha256:$(printf 'b%.0s' {1..64})" linux/amd64 || true
has "pinned_index_error: an index pin fails and names the amd64 manifest" "${PINNED_INDEX_ERROR}" \
  "the pinned digest is a multi-platform index; pin the linux/amd64 manifest sha256:$(printf 'b%.0s' {1..64}), not the index"
check "pinned_index_error: a manifest pin passes" "$(pinned_index_error "ghcr.io/teknoir/x:sha-1234567@sha256:${D64}" "sha256:${D64}" linux/amd64 && echo ok)" "ok"
check "pinned_index_error: a tag-only ref passes" "$(pinned_index_error "docker.io/library/busybox:1.36.1" "sha256:${D64}" linux/amd64 && echo ok)" "ok"

# --- 7. node packages (debs_gate, TIME-T1) ------------------------------------------------------
DB="${T}/debs"
mkdir -p "${DB}/src" "${DB}/out"
make_deb() {
  # make_deb <package> <version> <out.deb> — a minimal real .deb (dpkg-deb), else plain bytes
  local d="${DB}/src/$1-$2"
  mkdir -p "${d}/DEBIAN"
  printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: gate-test <t@example.invalid>\nDescription: fixture\n' "$1" "$2" > "${d}/DEBIAN/control"
  if command -v dpkg-deb >/dev/null; then
    dpkg-deb --root-owner-group -Zgzip --build "${d}" "$3" >/dev/null
  else
    printf 'not a deb: %s %s\n' "$1" "$2" > "$3"
  fi
}
make_deb fake-a 1.0-1 "${DB}/out/fake-a_1.0-1_amd64.deb"
make_deb fake-b 2:3.0-1 "${DB}/out/fake-b_3.0-1_amd64.deb"
NODE_DEBS="fake-a=1.0-1 fake-b=2:3.0-1"
PINNED_SHA256["deb-fake-a-1.0-1-amd64"]="$(sha256_file "${DB}/out/fake-a_1.0-1_amd64.deb")"
PINNED_SHA256["deb-fake-b-2:3.0-1-amd64"]="$(sha256_file "${DB}/out/fake-b_3.0-1_amd64.deb")"
write_lock() {
  printf 'fake-a 1.0-1 amd64 %s fake-a_1.0-1_amd64.deb\nfake-b 2:3.0-1 amd64 %s fake-b_3.0-1_amd64.deb\n' \
    "${PINNED_SHA256["deb-fake-a-1.0-1-amd64"]}" "${PINNED_SHA256["deb-fake-b-2:3.0-1-amd64"]}" > "$1/debs.lock"
}
debs_case() {
  # debs_case <name> — a fresh copy of the good node/debs in ${DB}/<name>
  rm -rf "${DB:?}/$1"; cp -r "${DB}/out" "${DB}/$1"; write_lock "${DB}/$1"
}
GATE_MSGS=()
debs_case good
debs_gate record "${DB}/good"
check "debs_gate: the pinned debs and their lock pass" "${#GATE_MSGS[@]}" "0"
GATE_MSGS=()
debs_case tampered
printf 'x' >> "${DB}/tampered/fake-a_1.0-1_amd64.deb"
debs_gate record "${DB}/tampered"
has "debs_gate: a tampered deb fails" "${GATE_MSGS[*]:-}" "node/debs/fake-a_1.0-1_amd64.deb has sha256"
GATE_MSGS=()
debs_case unlisted
cp "${DB}/out/fake-a_1.0-1_amd64.deb" "${DB}/unlisted/extra_9_amd64.deb"
debs_gate record "${DB}/unlisted"
check "debs_gate: an unlisted deb fails" "${GATE_MSGS[*]:-}" "node/debs/extra_9_amd64.deb is not listed in debs.lock"
GATE_MSGS=()
debs_case lockpin
sed -i "s/ ${PINNED_SHA256["deb-fake-b-2:3.0-1-amd64"]} / $(printf '%064d' 7) /" "${DB}/lockpin/debs.lock"
debs_gate record "${DB}/lockpin"
has "debs_gate: a lock sha256 that is not the pin fails" "${GATE_MSGS[*]:-}" "fake-b_3.0-1_amd64.deb has sha256 $(printf '%064d' 7) in the lock, but versions.env pins"
GATE_MSGS=()
debs_case missing-line
sed -i '/^fake-a /d' "${DB}/missing-line/debs.lock"
debs_gate record "${DB}/missing-line"
has "debs_gate: a NODE_DEBS entry without a lock line fails" "${GATE_MSGS[*]:-}" "debs.lock has no line for fake-a 1.0-1 amd64"
if command -v dpkg-deb >/dev/null; then
  GATE_MSGS=()
  debs_case relabelled
  # a different package version under the expected name and pins: the lock
  # and the pins agree, the package itself does not
  make_deb fake-a 1.0-2 "${DB}/relabelled/fake-a_1.0-1_amd64.deb"
  PINNED_SHA256["deb-fake-a-1.0-1-amd64"]="$(sha256_file "${DB}/relabelled/fake-a_1.0-1_amd64.deb")"
  write_lock "${DB}/relabelled"
  debs_gate record "${DB}/relabelled"
  check "debs_gate: a lock line that does not match the package (dpkg-deb) fails" "${GATE_MSGS[*]:-}" \
    "node/debs/fake-a_1.0-1_amd64.deb: dpkg-deb says Version 1.0-2, the lock says 1.0-1"
  PINNED_SHA256["deb-fake-a-1.0-1-amd64"]="$(sha256_file "${DB}/out/fake-a_1.0-1_amd64.deb")"
else
  echo "# SKIP dpkg-deb field check (no dpkg-deb on this host)"
fi
GATE_MSGS=()
NODE_DEBS=""
debs_gate record "${DB}/good"
check "debs_gate: debs present although NODE_DEBS is empty fails" "${GATE_MSGS[*]:-}" "node/debs: NODE_DEBS is empty, but node/debs is not"

# --- 8. make-bundle.sh --dry-run lists the plugin pins and the debs ------------------------------
# (this infra checkout, possibly uncommitted: --allow-dirty; the fixture
# gitops tree; nothing is downloaded or written but the build tools)
NODE_DEBS="$(sed -n 's/^NODE_DEBS="\(.*\)"$/\1/p' "${BUILD}/../versions.env")"
rc=0
APP_OF_APPS_VERSION=9.9.9 "${BUILD}/make-bundle.sh" --gitops "${T}/gitops" --out "${T}/dist" --allow-dirty --dry-run \
  > "${T}/mb-dry.log" 2>&1 || rc=$?
check "make-bundle --dry-run: exits 0" "${rc}" "0"
[[ "${rc}" == 0 ]] || sed 's/^/#   /' "${T}/mb-dry.log" | tail -20
check "make-bundle --dry-run: the 9 plugin pins" \
  "$(grep -c '\[dry-run\] teamspace plugin profile-plugin-[a-z-]* 0\.0\.99 from .* (pin [0-9a-f]\{64\})' "${T}/mb-dry.log")" "9"
for e in ${NODE_DEBS}; do
  p="${e%%=*}"; v="${e#*=}"
  has "make-bundle --dry-run: plans ${p} ${v} with its pin" "$(grep -F "node/debs/${p}_${v#*:}_amd64.deb" "${T}/mb-dry.log")" \
    "(pin ${PINNED_SHA256[deb-${p}-${v}-amd64]}, fallback https://snapshot.debian.org/file/${PINNED_DEB_SHA1[deb-${p}-${v}-amd64]})"
done
check "make-bundle --dry-run: writes nothing to the output dir" "$(find "${T}/dist" -mindepth 1 -not -name '.staging-*' 2>/dev/null | wc -l)" "0"

echo "1..${N}"
if (( FAILED > 0 )); then
  echo "# ${FAILED} of ${N} checks failed"
  exit 1
fi
echo "# all ${N} checks passed"
