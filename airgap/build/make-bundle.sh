#!/usr/bin/env bash
# make-bundle.sh — build the airgap bundle on a connected Linux machine (I-01).
#
#   airgap/build/make-bundle.sh --gitops ../platform-applications-gitops-teknoir-local
#   -> dist/teknoir-airgap-<bundleId>.tar  and  dist/teknoir-airgap-<bundleId>.tar.sha256
#
# bundleId = <env>-aoa<APP_OF_APPS_VERSION>-<YYYYMMDD>-i<infra sha7>-g<gitops sha7>[-dirty][-incomplete]
#
# Everything is built in <out>/.staging-<bundleId>/ and moved into place only
# after the gate passed; a failed build leaves the staging dir for inspection
# and no tar. Steps:
#   1. sources     airgap/teknoir-airgap, airgap/node/**, docs/airgap/*.md and
#                  the site files of this domain, as a commit would contain them
#   2. tools       fetch-tools.sh: node/bin, node/k3s, tools/<os>-<arch>/kubectl
#   3. charts      collect-charts.sh: node/charts (+ pins.txt), every Application rendered
#   4. one-shot    render-oneshot.sh: node/oneshot (TIERS, <tier>[-crds].yaml)
#   5. images      collect-images.sh: node/images, node/bootstrap-images, images.lock
#   6. gate        secret material, offline completeness, single platform,
#                  node IPs, internet references, script syntax, size
#   7. checksums   node/SHA256SUMS, MANIFEST.yaml (sha256 of every file), self-verify
#   8. tar         one plain tar (posix, sorted, root-owned) + .sha256 [+ --split parts]
#
# Options:
#   --gitops DIR        platform-applications-gitops checkout (required); its
#                       branch must be the site's env (teknoir-local) or airgap-redesign*
#   --site ENV|FILE     site config (default teknoir-local = airgap/site/teknoir-local.env)
#   --out DIR           output directory (default <infra>/dist)
#   --allow-dirty       build from uncommitted trees or with pin overrides; the
#                       bundle id gets "-dirty" and MANIFEST.yaml records it
#   --images-limit N    TEST ONLY: pull the first N images per list (bundle id
#                       "-incomplete", the completeness and size gates only warn)
#   --split             also write 3900 MiB parts (FAT32 media)
#   --keep-staging      keep <out>/.staging-<bundleId> after a successful build
#   --dry-run           check inputs and print the plan; download and write nothing
#   -h, --help
#
# Needs bash >= 4.4, git, curl, tar (GNU), gzip, bzip2, sha256sum; helm, crane, jq
# and yq come pinned and verified from the tool cache. No python.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-build.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-build.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

GITOPS="" SITE_ARG="teknoir-local" OUT_DIR="${INFRA_ROOT}/dist"
ALLOW_DIRTY=0 IMAGES_LIMIT_ARG="${IMAGES_LIMIT:-}" SPLIT=0 KEEP_STAGING=0 DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gitops) GITOPS="${2:?--gitops needs a directory}"; shift ;;
    --site) SITE_ARG="${2:?--site needs a name or file}"; shift ;;
    --out) OUT_DIR="${2:?--out needs a directory}"; shift ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --images-limit) IMAGES_LIMIT_ARG="${2:?--images-limit needs a number}"; shift ;;
    --split) SPLIT=1 ;;
    --keep-staging) KEEP_STAGING=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "${GITOPS}" ]] || die "--gitops DIR is required (see --help)"
[[ -z "${IMAGES_LIMIT_ARG}" || "${IMAGES_LIMIT_ARG}" =~ ^[0-9]+$ ]] || die "--images-limit must be a number"
require_cmd git curl tar gzip bzip2 sha256sum awk sort find split stat du
tar --version 2>/dev/null | grep -q 'GNU tar' || die "GNU tar is required on the build machine"
umask 022

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
step "inputs"
if [[ "${SITE_ARG}" == */* || "${SITE_ARG}" == *.env ]]; then
  SITE_FILE="$(cd "$(dirname "${SITE_ARG}")" && pwd)/$(basename "${SITE_ARG}")"
else
  SITE_FILE="${AIRGAP_DIR}/site/${SITE_ARG}.env"
fi
site_check "${SITE_FILE}"
TEKNOIR_ENV="$(site_get "${SITE_FILE}" TEKNOIR_ENV)"
TEKNOIR_DOMAIN="$(site_get "${SITE_FILE}" TEKNOIR_DOMAIN)"
SITE_NODE_IP="$(site_get "${SITE_FILE}" NODE_IP)"
[[ "${TEKNOIR_ENV}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "TEKNOIR_ENV '${TEKNOIR_ENV}' is not a valid bundle id part"

GITOPS="$(cd "${GITOPS}" && pwd)" || die "gitops checkout not found: ${GITOPS}"
git -C "${GITOPS}" rev-parse --git-dir >/dev/null 2>&1 || die "${GITOPS} is not a git checkout"
git -C "${INFRA_ROOT}" rev-parse --git-dir >/dev/null 2>&1 || die "${INFRA_ROOT} is not a git checkout"

INFRA_BRANCH="$(git_branch "${INFRA_ROOT}")"
GITOPS_BRANCH="$(git_branch "${GITOPS}")"
INFRA_COMMIT="$(git -C "${INFRA_ROOT}" rev-parse HEAD)"
GITOPS_COMMIT="$(git -C "${GITOPS}" rev-parse HEAD)"
branch_allowed "${INFRA_BRANCH}" "${TEKNOIR_ENV}" \
  || die "infra checkout ${INFRA_ROOT} is on '${INFRA_BRANCH}': build from branch ${TEKNOIR_ENV} (or airgap-redesign*)"
branch_allowed "${GITOPS_BRANCH}" "${TEKNOIR_ENV}" \
  || die "gitops checkout ${GITOPS} is on '${GITOPS_BRANCH}': build from branch ${TEKNOIR_ENV} (or airgap-redesign*) — never from another environment's branch"

DIRTY=0
dirty_reasons=()
if git_is_dirty "${INFRA_ROOT}"; then dirty_reasons+=("infra tree ${INFRA_ROOT} has uncommitted changes"); fi
if git_is_dirty "${GITOPS}"; then dirty_reasons+=("gitops tree ${GITOPS} has uncommitted changes"); fi
for o in ${PIN_OVERRIDES[@]+"${PIN_OVERRIDES[@]}"}; do dirty_reasons+=("pin override from the environment: ${o}"); done
if (( ${#dirty_reasons[@]} > 0 )); then
  for r in "${dirty_reasons[@]}"; do warn "${r}"; done
  (( ALLOW_DIRTY )) || die "refusing to build a bundle that the two commits do not describe (commit, or pass --allow-dirty for a -dirty test bundle)"
  DIRTY=1
fi
for b in "${INFRA_ROOT}:${INFRA_BRANCH}" "${GITOPS}:${GITOPS_BRANCH}"; do
  if [[ -z "$(git -C "${b%%:*}" branch -r --contains HEAD 2>/dev/null)" ]]; then
    warn "${b%%:*}: HEAD is not on any remote branch (push it, so the bundle's commit can be found again)"
  fi
done
for v in ${BROKEN_APP_OF_APPS_VERSIONS}; do
  [[ "${APP_OF_APPS_VERSION}" != "${v}" ]] || die "app-of-apps ${APP_OF_APPS_VERSION} is in BROKEN_APP_OF_APPS_VERSIONS"
done

INCOMPLETE=0
[[ -z "${IMAGES_LIMIT_ARG}" ]] || INCOMPLETE=1
CREATED_EPOCH="$(date -u +%s)"
CREATED_AT="$(date -u -d "@${CREATED_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
BUILD_DATE="$(date -u -d "@${CREATED_EPOCH}" +%Y%m%d)"
BUNDLE_ID="${TEKNOIR_ENV}-aoa${APP_OF_APPS_VERSION}-${BUILD_DATE}-i${INFRA_COMMIT:0:7}-g${GITOPS_COMMIT:0:7}"
(( DIRTY )) && BUNDLE_ID+="-dirty"
(( INCOMPLETE )) && BUNDLE_ID+="-incomplete"
[[ "${BUNDLE_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid bundle id ${BUNDLE_ID}"
NAME="teknoir-airgap-${BUNDLE_ID}"

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
STAGING="${OUT_DIR}/.staging-${BUNDLE_ID}"
TREE="${STAGING}/${NAME}"
WORK="${STAGING}/work"
log "bundle ${BUNDLE_ID}"
log "  site ${SITE_FILE#"${INFRA_ROOT}"/} (${TEKNOIR_ENV}, ${TEKNOIR_DOMAIN})"
log "  infra  ${INFRA_BRANCH} ${INFRA_COMMIT:0:12}  gitops ${GITOPS_BRANCH} ${GITOPS_COMMIT:0:12}"
log "  app-of-apps ${APP_OF_APPS_VERSION}, tiers: ${ONESHOT_TIERS}, k3s ${K3S_VERSION}, ${IMAGE_PLATFORMS}"

# Required sources written by the node and LAN implementations
NODE_SRC="${AIRGAP_DIR}/node"
missing=()
for f in teknoir-airgap node/bin/teknoir-node node/lib/common.sh \
         node/templates/config.yaml.tmpl node/templates/registries.yaml.tmpl \
         node/templates/coredns-custom.yaml.tmpl node/templates/app-of-apps.yaml.tmpl; do
  [[ -f "${AIRGAP_DIR}/${f}" ]] || missing+=("airgap/${f}")
done
(( ${#missing[@]} == 0 )) || die "missing bundle sources (LAN entrypoint / node runner): ${missing[*]}"
for f in host secrets release backup oneshot harbor migrate admin; do
  [[ -f "${NODE_SRC}/lib/${f}.sh" ]] || warn "airgap/node/lib/${f}.sh is missing (the node runner will lack that phase)"
done
for f in oneshot charts images bootstrap-images k3s site SHA256SUMS MANIFEST.yaml bin/helm bin/crane bin/jq bin/age; do
  [[ ! -e "${NODE_SRC}/${f}" ]] || die "airgap/node/${f} is generated by the build and must not exist in the source tree"
done

if (( DRY_RUN )); then
  step "dry run (nothing is downloaded or written except the build tools)"
  DRY_WORK="${OUT_DIR}/.staging-${BUNDLE_ID}-dryrun/work"
  trap 'rm_build_dir "${OUT_DIR}/.staging-${BUNDLE_ID}-dryrun"' EXIT
  "${BUILD_DIR}/fetch-tools.sh" --stage "${TREE}" --dry-run
  "${BUILD_DIR}/collect-charts.sh" --gitops "${GITOPS}" --domain "${TEKNOIR_DOMAIN}" --stage "${DRY_WORK}/stage" --work "${DRY_WORK}" --dry-run
  log "[dry-run] would render the one-shot tiers (${ONESHOT_TIERS}), pull every image, gate, checksum and write ${OUT_DIR}/${NAME}.tar"
  exit 0
fi

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------
[[ ! -e "${STAGING}" ]] || { log "removing the stale staging dir of an earlier build"; rm_build_dir "${STAGING}"; }
mkdir -p "${TREE}" "${WORK}"
on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ -d "${STAGING}" ]]; then
    warn "build FAILED; staging kept for inspection: ${STAGING}"
  fi
}
trap on_exit EXIT

step "1/8 sources"
copy_git_files "${INFRA_ROOT}" airgap/node "${WORK}/src-infra"
copy_git_files "${INFRA_ROOT}" airgap/teknoir-airgap "${WORK}/src-infra"
copy_git_files "${INFRA_ROOT}" docs/airgap "${WORK}/src-infra"
copy_git_files "${INFRA_ROOT}" airgap/site "${WORK}/src-infra"
[[ -f "${WORK}/src-infra/airgap/teknoir-airgap" ]] || die "airgap/teknoir-airgap is not committed or is ignored"
install -m 0755 "${WORK}/src-infra/airgap/teknoir-airgap" "${TREE}/teknoir-airgap"
cp -a "${WORK}/src-infra/airgap/node" "${TREE}/node"
chmod 0755 "${TREE}/node/bin/teknoir-node"
mkdir -p "${TREE}/docs" "${TREE}/site" "${TREE}/node/site"
shopt -s nullglob
for f in "${WORK}/src-infra/docs/airgap/"*.md; do install -m 0644 "${f}" "${TREE}/docs/"; done
sites=()
for f in "${WORK}/src-infra/airgap/site/"*.env; do
  site_check "${f}"
  if [[ "$(site_get "${f}" TEKNOIR_DOMAIN)" != "${TEKNOIR_DOMAIN}" ]]; then
    log "site $(basename "${f}") is for $(site_get "${f}" TEKNOIR_DOMAIN), not ${TEKNOIR_DOMAIN}: not bundled"
    continue
  fi
  install -m 0644 "${f}" "${TREE}/site/"
  install -m 0644 "${f}" "${TREE}/node/site/"
  sites+=("$(basename "${f}")")
done
shopt -u nullglob
if [[ ! -f "${TREE}/site/$(basename "${SITE_FILE}")" ]]; then
  # a site file outside the repo (--site FILE): bundled as the default site
  [[ "$(basename "${SITE_FILE}")" == "${TEKNOIR_ENV}.env" ]] \
    || die "--site ${SITE_FILE} is not in airgap/site/ and not named ${TEKNOIR_ENV}.env"
  install -m 0644 "${SITE_FILE}" "${TREE}/site/"
  install -m 0644 "${SITE_FILE}" "${TREE}/node/site/"
  sites+=("$(basename "${SITE_FILE}")")
fi
cmp -s "${SITE_FILE}" "${TREE}/site/$(basename "${SITE_FILE}")" \
  || die "the bundled site/$(basename "${SITE_FILE}") differs from ${SITE_FILE} (uncommitted or ignored?)"
log "sources: teknoir-airgap, node/ ($(find "${TREE}/node" -type f | wc -l) files), docs/ ($(find "${TREE}/docs" -type f | wc -l)), site/ (${sites[*]})"

step "2/8 tools"
"${BUILD_DIR}/fetch-tools.sh" --stage "${TREE}"

step "3/8 charts"
"${BUILD_DIR}/collect-charts.sh" --gitops "${GITOPS}" --domain "${TEKNOIR_DOMAIN}" --stage "${TREE}" --work "${WORK}"
use_build_tools "${WORK}"

step "4/8 one-shot tiers"
"${BUILD_DIR}/render-oneshot.sh" --stage "${TREE}" --work "${WORK}" --site "${SITE_FILE}"

step "5/8 images"
"${BUILD_DIR}/collect-images.sh" --stage "${TREE}" --work "${WORK}" ${IMAGES_LIMIT_ARG:+--images-limit "${IMAGES_LIMIT_ARG}"}
[[ "$(cat "${WORK}/images.incomplete")" == "${INCOMPLETE}" ]] || die "image collection completeness does not match the bundle id"

# ---------------------------------------------------------------------------
# 6. Gate
# ---------------------------------------------------------------------------
step "6/8 gate"
GATE_FAIL=0
gate_fail() { warn "GATE: $*"; GATE_FAIL=1; }
gate_warn() { warn "gate: $*"; }

# 6a. secret material.
#  - PEM private key headers nowhere in the plain files of the tree (binaries
#    and docs included; image layers and the k3s images are upstream content
#    and compressed). The bare phrase "PRIVATE KEY" is legitimate in binaries
#    (crypto libraries) and prose, so it is refused only in the plain-text
#    config the bundle ships.
#  - Inside every chart archive (gzip, so the tree scan cannot see into it;
#    chart_secret_findings): credential-like member names, PEM private key
#    blocks (a header plus a base64 body, so the upstream documentation
#    examples "-----BEGIN ... PRIVATE KEY-----\n...\n" in the argo-cd and
#    redis-ha values pass) and base64-encoded keys. The same key checks run
#    over every Application render.
#  - No Secret with data in what the node applies as is (the one-shot tiers),
#    except a credential-less ArgoCD repository Secret for the Harbor chart
#    project (secret_gate); Secrets with data in the other renders are
#    ArgoCD's to apply from the chart and only warned about.
pem_re='-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----'
HITS=()
grep_hits() {
  # grep_hits <what> <ERE> <file|dir>... — HITS=(matching files); runs in this
  # shell (never in $(...)) so that a grep error fails the gate
  local what="$1" re="$2" out rc=0
  shift 2
  HITS=()
  (( $# > 0 )) || return 0   # grep -r without a path would search the cwd
  out="$(grep -rlaE -- "${re}" "$@")" || rc=$?
  case "${rc}" in
    0) mapfile -t HITS <<<"${out}" ;;
    1) ;;
    *) gate_fail "cannot scan ${what} (grep rc ${rc})" ;;
  esac
}
mapfile -d '' tree_plain < <(find "${TREE}" -type f \
  ! -path "${TREE}/node/images/*/blobs/*" ! -path "${TREE}/node/bootstrap-images/*" \
  ! -name 'k3s-airgap-images-*' -print0)
grep_hits "the bundle tree" "${pem_re}" "${tree_plain[@]}"
for f in "${HITS[@]}"; do gate_fail "PEM private key in ${f#"${TREE}"/}"; done
plain_cfg=()
while IFS= read -r -d '' f; do plain_cfg+=("${f}"); done < <(
  find "${TREE}/node/oneshot" "${TREE}/node/templates" "${TREE}/site" "${TREE}/node/site" -type f -print0
  printf '%s\0' "${TREE}/node/charts/pins.txt" "${TREE}/node/images/images.lock"
)
grep_hits "the plain-text config" "PRIVATE KEY|${PEM_B64_RE}" "${plain_cfg[@]}"
for f in "${HITS[@]}"; do gate_fail "private key material in ${f#"${TREE}"/}"; done

# every member of every packaged chart, by name and by content
CHART_SCAN="${WORK}/chart-scan"
[[ ! -e "${CHART_SCAN}" ]] || rm_build_dir "${CHART_SCAN}"
mkdir -p "${CHART_SCAN}"
for t in "${TREE}/node/charts/"*.tgz; do
  c="$(basename "${t}")"
  findings="$(chart_secret_findings "${t}" "${CHART_SCAN}/${c}")" || findings="error the scan failed"
  while read -r kind what; do
    case "${kind}" in
      "") ;;
      name) gate_fail "credential-like file in node/charts/${c}: ${what}" ;;
      pem) gate_fail "PEM private key block in node/charts/${c}: ${what}" ;;
      b64) gate_fail "base64-encoded private key in node/charts/${c}: ${what}" ;;
      *) gate_fail "node/charts/${c}: ${what}" ;;
    esac
  done <<<"${findings}"
done

# every Application render (what ArgoCD will apply) and the one-shot tiers
CHART_REPO="harbor.${TEKNOIR_DOMAIN}/${HARBOR_CHART_PROJECT}"
hits="$(pem_private_keys "${WORK}/renders/"*.yaml "${TREE}/node/oneshot/"*.yaml)" || gate_fail "cannot scan the renders for PEM keys"
while IFS= read -r h; do
  [[ -z "${h}" ]] || gate_fail "PEM private key block in the render ${h}"
done <<<"${hits}"
grep_hits "the renders" "${PEM_B64_RE}" "${WORK}/renders" "${TREE}/node/oneshot"
for f in "${HITS[@]}"; do gate_fail "base64-encoded private key in the render ${f}"; done
secret_gate_report gate_fail "node/oneshot" "${CHART_REPO}" "${TREE}/node/oneshot/"*.yaml
for f in "${WORK}/renders/"*.yaml; do
  secret_gate_report gate_warn "the $(basename "${f}" .yaml) render (applied by ArgoCD from the chart)" "${CHART_REPO}" "${f}"
done
for f in "${TREE}/node/templates/"*; do
  if grep -qE '^kind:[[:space:]]*Secret[[:space:]]*$' "${f}"; then gate_fail "node/templates/$(basename "${f}") contains a Secret"; fi
done
# known literal default credentials (and their base64 form)
cred_re='change-me|changeit|Harbor12345|harbor_registry_password|prom-operator'
cred_b64_re="$(for w in change-me changeit Harbor12345 harbor_registry_password prom-operator; do
  printf '%s' "${w}" | base64 -w0 | tr -d '='; printf '|'; done | sed 's/|$//')"
grep_hits "the plain-text config" "${cred_re}|${cred_b64_re}" "${plain_cfg[@]}"
for f in "${HITS[@]}"; do gate_fail "known default credential literal in ${f#"${TREE}"/}"; done
grep_hits "the renders" "${cred_re}|${cred_b64_re}" "${WORK}/renders"
for f in "${HITS[@]}"; do
  gate_warn "the $(basename "${f}" .yaml) render carries a known default credential literal (G-08 territory: fix it in the gitops chart)"
done
# no credential-like files in the tree
while IFS= read -r -d '' f; do
  if credential_name "${f#"${TREE}"/}"; then gate_fail "credential-like file in the bundle: ${f#"${TREE}"/}"; fi
done < <(find "${TREE}" -type f ! -path "${TREE}/node/images/*/blobs/*" -print0)

# 6b. node IPs are a run-time input: none in the one-shot renders or templates
for f in "${TREE}/node/oneshot/"* "${TREE}/node/templates/"*; do
  if grep -qF -- "${SITE_NODE_IP}" "${f}" || grep -qE '(^|[^0-9.])192\.168\.[0-9]+\.[0-9]+' "${f}"; then
    gate_fail "a node/LAN IP address in ${f#"${TREE}"/} (substitute it on the node at run time)"
  fi
done

# 6c. offline completeness: every rendered image is locked and present
locked="$(awk '{sub(/@sha256:[0-9a-f]+$/, "", $1); print $1}' "${TREE}/node/images/images.lock" | LC_ALL=C sort -u)"
missing_images="$(LC_ALL=C comm -23 "${WORK}/images.required" <(printf '%s\n' "${locked}"))"
if [[ -n "${missing_images}" ]]; then
  n_missing="$(grep -c . <<<"${missing_images}")"
  if (( INCOMPLETE )); then
    gate_warn "${n_missing} required images not in the bundle (TEST ONLY --images-limit)"
  else
    while IFS= read -r r; do gate_fail "image missing from the bundle: ${r}"; done <<<"${missing_images}"
  fi
fi
while read -r refdigest slug; do
  [[ "${refdigest}" =~ @sha256:[0-9a-f]{64}$ ]] || gate_fail "images.lock entry without a digest: ${refdigest}"
  if [[ -d "${TREE}/node/images/${slug}" ]]; then
    # single platform: exactly one manifest, the locked digest, the right platform
    idx="${TREE}/node/images/${slug}/index.json"
    [[ "$(jq '.manifests | length' "${idx}")" == 1 ]] || gate_fail "images/${slug} is not single-manifest"
    [[ "$(jq -r '.manifests[0].digest' "${idx}")" == "${refdigest##*@}" ]] || gate_fail "images/${slug} does not hold ${refdigest##*@}"
    m="${TREE}/node/images/${slug}/blobs/sha256/$(jq -r '.manifests[0].digest | sub("^sha256:"; "")' "${idx}")"
    if [[ ! -f "${m}" ]] || jq -e '.manifests' "${m}" >/dev/null 2>&1; then
      gate_fail "images/${slug}: the manifest is missing or is an index (multi-platform)"
    else
      cfg="${TREE}/node/images/${slug}/blobs/sha256/$(jq -r '.config.digest | sub("^sha256:"; "")' "${m}")"
      [[ "$(jq -r '.os + "/" + .architecture' "${cfg}")" == "${IMAGE_PLATFORMS}" ]] \
        || gate_fail "images/${slug} is $(jq -r '.os + "/" + .architecture' "${cfg}"), not ${IMAGE_PLATFORMS}"
    fi
  elif [[ -f "${TREE}/node/bootstrap-images/${slug}.tar" ]]; then
    [[ "$(tar -xOf "${TREE}/node/bootstrap-images/${slug}.tar" manifest.json | jq length)" == 1 ]] \
      || gate_fail "bootstrap-images/${slug}.tar is not single-image"
  else
    gate_fail "images.lock lists ${slug}, but neither images/${slug}/ nor bootstrap-images/${slug}.tar exists"
  fi
done < "${TREE}/node/images/images.lock"
# nothing unlocked
for d in "${TREE}/node/images/"*/; do
  grep -q " $(basename "${d}")\$" "${TREE}/node/images/images.lock" || gate_fail "images/$(basename "${d}") is not in images.lock"
done
for t in "${TREE}/node/bootstrap-images/"*.tar; do
  [[ -e "${t}" ]] || continue
  grep -q " $(basename "${t}" .tar)\$" "${TREE}/node/images/images.lock" || gate_fail "bootstrap-images/$(basename "${t}") is not in images.lock"
done
# the injected sidecar must match the istio control plane
pilot="$(grep -h '^docker.io/istio/pilot:' "${WORK}/images.required" | head -1 || true)"
proxy="$(grep -h '^docker.io/istio/proxyv2:' "${WORK}/images.bootstrap" | head -1 || true)"
if [[ -n "${pilot}" && "${pilot##*:}" != "${proxy##*:}" ]]; then
  gate_fail "istio pilot ${pilot##*:} but bootstrap sidecar proxyv2 ${proxy##*:} (BOOTSTRAP_EXTRA_IMAGES in versions.env)"
fi
# charts: exactly the pins
while read -r name version; do
  [[ -f "${TREE}/node/charts/${name}-${version}.tgz" ]] || gate_fail "node/charts/${name}-${version}.tgz missing"
done < "${TREE}/node/charts/pins.txt"
[[ "$(head -1 "${TREE}/node/charts/pins.txt")" == "app-of-apps ${APP_OF_APPS_VERSION}" ]] || gate_fail "pins.txt does not start with app-of-apps ${APP_OF_APPS_VERSION}"
[[ "$(find "${TREE}/node/charts" -name '*.tgz' | wc -l)" == "$(grep -c . "${TREE}/node/charts/pins.txt")" ]] \
  || gate_fail "node/charts holds charts that pins.txt does not list"

# 6d. internet references in what will run (verify-offline): always-forbidden
# strings, and internet hosts in configuration values (CRD description prose
# may mention github.com; Backstage's inert GitHub integration host is benign)
strict_re='teknoir\.cloud|ghcr-token'
config_url_re='(repoURL|url|host|hostname|server|endpoint|registry|repository|issuer)"?[[:space:]]*:[[:space:]]*[^[:space:]]*(github\.com|storage\.googleapis\.com)'
benign_re='host:[[:space:]]*github\.com'
for f in "${WORK}/renders/"*.yaml "${TREE}/node/oneshot/"*.yaml "${TREE}/node/templates/"*; do
  hits="$( { grep -nE "${strict_re}" "${f}" || true; grep -nE "${config_url_re}" "${f}" | grep -vE "${benign_re}" || true; } | head -5)"
  [[ -z "${hits}" ]] || gate_fail "internet reference in ${f##*/}: $(head -1 <<<"${hits}" | cut -c1-160)"
done

# 6e. every shipped script parses
while IFS= read -r -d '' f; do
  if head -1 "${f}" | grep -qE '^#!.*\b(ba)?sh\b' || [[ "${f}" == *.sh ]]; then
    bash -n "${f}" 2>/dev/null || gate_fail "shell syntax error: ${f#"${TREE}"/}"
  fi
done < <(find "${TREE}/teknoir-airgap" "${TREE}/node/bin" "${TREE}/node/lib" -type f ! -name helm ! -name crane ! -name jq ! -name age -print0)

# 6f. no symlinks, no special files, no hardlinks; plain path names (the
# MANIFEST.yaml readers on the LAN host and the node split "path: sha256")
[[ -z "$(find "${TREE}" ! -type f ! -type d -print -quit)" ]] || gate_fail "the bundle holds symlinks or special files"
[[ -z "$(find "${TREE}" -type f -links +1 -print -quit)" ]] || gate_fail "the bundle holds hardlinked files"
odd="$(find "${TREE}" -mindepth 1 -printf '%P\n' | grep -vE '^[A-Za-z0-9][A-Za-z0-9._+/-]*$' | head -3 || true)"
[[ -z "${odd}" ]] || gate_fail "path names outside [A-Za-z0-9._+/-]: $(tr '\n' ' ' <<<"${odd}")"

(( GATE_FAIL == 0 )) || die "the bundle failed the gate (see GATE: lines above)"
log "gate passed"

# ---------------------------------------------------------------------------
# 7. Checksums and MANIFEST.yaml
# ---------------------------------------------------------------------------
step "7/8 checksums"
sum_tree() {
  # sum_tree <dir> <out> — "<sha256>  <path relative to dir>" for every file, sorted by path
  (cd "$1" && find . -type f -print0 | sed -z 's|^\./||' | xargs -0 -r -n 64 -P "$(nproc)" sha256sum) \
    | LC_ALL=C sort -k2 > "$2"
}
sum_tree "${TREE}/node" "${WORK}/node.sums"
# blob files are named by their digest: verify them while we have the sums
bad_blobs="$(awk '$2 ~ /^images\/[^\/]+\/blobs\/sha256\/[0-9a-f]+$/ { n = split($2, p, "/"); if (p[n] != $1) print "node/" $2 }' "${WORK}/node.sums")"
if [[ -n "${bad_blobs}" ]]; then
  # Backstop: collect-images.sh validated every staged layout blob by blob,
  # so the copy or the cache changed after that. Name and drop the cache
  # entries the bad copies came from, so the next run pulls them again.
  exec 8> "${CACHE_DIR}/images/.lock"
  locked=1
  flock -n 8 || locked=0
  for b in ${bad_blobs}; do
    slug="${b#node/images/}"
    slug="${slug%%/*}"
    pd="$(jq -r --arg s "${slug}" 'select(.slug == $s) | .platformDigest' "${WORK}/images.jsonl" | head -1)"
    entry="${CACHE_DIR}/images/oci/${pd#sha256:}"
    if [[ ! "${pd}" =~ ^sha256:[0-9a-f]{64}$ || ! -d "${entry}" ]]; then
      warn "blob checksum mismatch: ${b} (no cache entry found for images/${slug})"
    elif (( locked )); then
      rm_build_dir "${entry}"
      warn "blob checksum mismatch: ${b}; removed its cache entry ${entry}"
    else
      warn "blob checksum mismatch: ${b}; another build holds the image cache lock, so remove ${entry} by hand"
    fi
  done
  exec 8>&-
  die "corrupt image blobs in the bundle (see above); re-run the build to pull them again"
fi
cp "${WORK}/node.sums" "${TREE}/node/SHA256SUMS"
(cd "${TREE}/node" && sha256sum --quiet --strict -c SHA256SUMS) || die "node/SHA256SUMS does not verify"
sum_tree "${TREE}" "${WORK}/all.sums"

yaml_list() { local x out=""; for x in "$@"; do out+="${out:+, }${x}"; done; printf '[%s]' "${out}"; }
yaml_qlist() { local x out=""; for x in "$@"; do out+="${out:+, }\"${x//\"/}\""; done; printf '[%s]' "${out}"; }
{
  echo "# Teknoir airgap bundle manifest. Written by airgap/build/make-bundle.sh;"
  echo "# teknoir-airgap verifies every file below before it contacts the node."
  echo "apiVersion: teknoir.org/v1"
  echo "kind: AirgapBundleManifest"
  echo "bundleId: ${BUNDLE_ID}"
  echo "env: ${TEKNOIR_ENV}"
  echo "domain: ${TEKNOIR_DOMAIN}"
  echo "createdAt: ${CREATED_AT}"
  echo "infraCommit: ${INFRA_COMMIT}"
  echo "infraBranch: ${INFRA_BRANCH}"
  echo "gitopsCommit: ${GITOPS_COMMIT}"
  echo "gitopsBranch: ${GITOPS_BRANCH}"
  echo "dirty: $( (( DIRTY )) && echo true || echo false)"
  echo "incomplete: $( (( INCOMPLETE )) && echo true || echo false)"
  echo "appOfAppsVersion: ${APP_OF_APPS_VERSION}"
  # shellcheck disable=SC2086
  echo "brokenAppOfApps: $(yaml_list ${BROKEN_APP_OF_APPS_VERSIONS})"
  echo "k3sVersion: ${K3S_VERSION}"
  # shellcheck disable=SC2086
  echo "platforms: $(yaml_list ${IMAGE_PLATFORMS})"
  # shellcheck disable=SC2086
  echo "oneshotTiers: $(yaml_list ${ONESHOT_TIERS})"
  echo "pinOverrides: $(yaml_qlist ${PIN_OVERRIDES[@]+"${PIN_OVERRIDES[@]}"})"
  echo "tools:"
  echo "  helm: ${HELM_VERSION}"
  echo "  crane: ${CRANE_VERSION}"
  echo "  jq: ${JQ_VERSION}"
  echo "  age: ${AGE_VERSION}"
  echo "  kubectl: ${KUBECTL_VERSION}"
  echo "  yq: ${YQ_VERSION} # build only"
  echo "charts:"
  awk '{printf "  %s: %s\n", $1, $2}' "${TREE}/node/charts/pins.txt"
  echo "oneshot:"
  jq -r '"  - tier: \(.tier)\n    chart: \(.chart)\n    version: \(.version)\n    release: \(.release)\n    namespace: \(.namespace)\n    crds: \(.crds)\n    crdOrder: \(.crdOrder)\n    renderSha256: \(.renderSha256)"' \
    "${WORK}/oneshot.jsonl"
  echo "images:"
  jq -rs 'sort_by(.ref)[] | "  \"\(.ref)\":\n    digest: \(.digest)\n    platformDigest: \(.platformDigest)\n    indexDigest: \(.indexDigest)\n    format: \(.format)\n    bootstrap: \(.bootstrap)\n    slug: \(.slug)"' \
    "${WORK}/images.jsonl"
  echo "files:"
  awk '{ p = substr($0, 67); printf "  %s: %s\n", p, $1 }' "${WORK}/all.sums"
} > "${TREE}/MANIFEST.yaml"

# self-verify exactly as the LAN host will: every listed file matches, nothing unlisted
awk '/^files:$/ {f = 1; next} f && /^  [^ ]/ { line = substr($0, 3); i = index(line, ": "); print substr(line, i + 2) "  " substr(line, 1, i - 1) }' \
  "${TREE}/MANIFEST.yaml" > "${WORK}/manifest.check"
(cd "${TREE}" && sha256sum --quiet --strict -c "${WORK}/manifest.check") || die "MANIFEST.yaml does not verify"
diff <(awk '{print substr($0, 67)}' "${WORK}/manifest.check" | LC_ALL=C sort) \
     <(cd "${TREE}" && find . -type f ! -path ./MANIFEST.yaml | sed 's|^\./||' | LC_ALL=C sort) >/dev/null \
  || die "MANIFEST.yaml and the tree list different files"
[[ "$(grep -E '^  node/SHA256SUMS: ' "${TREE}/MANIFEST.yaml" | grep -oE '[0-9a-f]{64}')" == "$(sha256_file "${TREE}/node/SHA256SUMS")" ]] \
  || die "MANIFEST.yaml does not pin node/SHA256SUMS"
log "MANIFEST.yaml: $(grep -c . "${WORK}/manifest.check") files verified"

# ---------------------------------------------------------------------------
# 8. tar
# ---------------------------------------------------------------------------
step "8/8 tar"
TAR="${STAGING}/${NAME}.tar"
tar --create --file "${TAR}" --directory "${STAGING}" \
    --format=posix --pax-option='exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' \
    --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${CREATED_EPOCH}" \
    --mode='a+rX,u+w,go-w' "${NAME}"
size="$(stat -c %s "${TAR}")"
if (( size > BUNDLE_MAX_BYTES )); then
  if (( INCOMPLETE )); then gate_warn "the tar is ${size} bytes, over BUNDLE_MAX_BYTES"; else die "the tar is ${size} bytes, over BUNDLE_MAX_BYTES ${BUNDLE_MAX_BYTES}"; fi
fi
# the tar must list exactly the tree
diff <(tar -tf "${TAR}" | grep -v '/$' | LC_ALL=C sort) \
     <(cd "${STAGING}" && find "${NAME}" -type f | LC_ALL=C sort) >/dev/null || die "the tar does not hold exactly the bundle tree"
(cd "${STAGING}" && sha256sum "${NAME}.tar") > "${STAGING}/${NAME}.tar.sha256"

mv -f "${TAR}" "${OUT_DIR}/${NAME}.tar"
mv -f "${STAGING}/${NAME}.tar.sha256" "${OUT_DIR}/${NAME}.tar.sha256"
if (( SPLIT )); then
  rm -f "${OUT_DIR}/${NAME}.tar.part-"*
  split -b 3900m -d -a 2 "${OUT_DIR}/${NAME}.tar" "${OUT_DIR}/${NAME}.tar.part-"
  (cd "${OUT_DIR}" && sha256sum "${NAME}.tar.part-"*) > "${OUT_DIR}/${NAME}.tar.parts.sha256"
  log "split: ${NAME}.tar.part-* (+ .tar.parts.sha256); join with: cat ${NAME}.tar.part-* > ${NAME}.tar"
fi
if (( KEEP_STAGING )); then
  log "staging kept: ${STAGING}"
else
  rm_build_dir "${STAGING}"
fi
trap - EXIT
log "bundle: ${OUT_DIR}/${NAME}.tar ($(du -h "${OUT_DIR}/${NAME}.tar" | cut -f1))"
log "        ${OUT_DIR}/${NAME}.tar.sha256"
log "verify on the LAN host: shasum -a 256 -c ${NAME}.tar.sha256 (Linux: sha256sum -c)"
