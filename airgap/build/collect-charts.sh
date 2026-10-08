#!/usr/bin/env bash
# collect-charts.sh — package the charts pinned by APP_OF_APPS_VERSION into
# <stage>/node/charts/ and render every Application for the later steps.
#
#   1. app-of-apps APP_OF_APPS_VERSION from <gitops>/charts/app-of-apps (the
#      Chart.yaml version must be exactly that)
#   2. render it as ArgoCD renders the root Application and read every
#      Application: chart, targetRevision, repoURL, destination, helm settings
#      -> <work>/apps.jsonl
#   3. package every chart@version it deploys, plus EXTRA_CHART_PINS, from the
#      gitops tree (else this repo's charts/) at exactly that version, with
#      vendored dependencies and reproducible bytes -> <stage>/node/charts/
#   4. <stage>/node/charts/pins.txt: "name version", app-of-apps first
#   5. render every Application from its packaged chart -> <work>/renders/
#
# Sources are what a commit of each tree would contain (tracked + untracked,
# never ignored files), copied to <work>/src first: the gitops checkout is never
# modified. Every check is fatal.
#
# Usage: collect-charts.sh --gitops DIR --domain DOMAIN --stage DIR --work DIR [--dry-run]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-build.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-build.sh"

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

GITOPS="" DOMAIN="" STAGE="" WORK="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gitops) GITOPS="${2:?}"; shift ;;
    --domain) DOMAIN="${2:?}"; shift ;;
    --stage) STAGE="${2:?}"; shift ;;
    --work) WORK="${2:?}"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "${GITOPS}" && -n "${DOMAIN}" && -n "${STAGE}" && -n "${WORK}" ]] || { usage; exit 2; }
GITOPS="$(cd "${GITOPS}" && pwd)"
[[ -d "${GITOPS}/charts" ]] || die "no charts/ in the gitops checkout ${GITOPS}"

use_build_tools "${WORK}"
CHARTS_OUT="${STAGE}/node/charts"
SRC="${WORK}/src"
HARBOR_REPO="harbor.${DOMAIN}/${HARBOR_CHART_PROJECT}"

for v in ${BROKEN_APP_OF_APPS_VERSIONS}; do
  [[ "${APP_OF_APPS_VERSION}" != "${v}" ]] \
    || die "app-of-apps ${APP_OF_APPS_VERSION} is in BROKEN_APP_OF_APPS_VERSIONS and must never be built"
done

# --- sources ------------------------------------------------------------------------
step "chart sources"
[[ ! -e "${SRC}" ]] || rm_build_dir "${SRC}"
copy_git_files "${GITOPS}" charts "${SRC}/gitops"
if [[ -d "${INFRA_ROOT}/charts" ]]; then
  copy_git_files "${INFRA_ROOT}" charts "${SRC}/infra"
fi

chart_dir_for() {
  # chart_dir_for <name> <version> — the source dir holding exactly that chart
  # version (gitops first, then infra); fails when neither does
  local name="$1" version="$2" d found=""
  for d in "${SRC}/gitops/charts/${name}" "${SRC}/infra/charts/${name}"; do
    [[ -f "${d}/Chart.yaml" ]] || continue
    if [[ "$(chart_field "${d}" name)" == "${name}" && "$(chart_field "${d}" version)" == "${version}" ]]; then
      found="${d}"
      break
    fi
  done
  [[ -n "${found}" ]] || return 1
  echo "${found}"
}

describe_versions() {
  # describe_versions <name> — what the trees carry instead, for error messages
  local name="$1" d out=""
  for d in "${SRC}/gitops/charts/${name}" "${SRC}/infra/charts/${name}"; do
    [[ -f "${d}/Chart.yaml" ]] && out+=" ${d#"${SRC}/"}=$(chart_field "${d}" version)"
  done
  echo "${out:- none}"
}

# --- app-of-apps ----------------------------------------------------------------------
step "app-of-apps ${APP_OF_APPS_VERSION}"
AOA_DIR="$(chart_dir_for app-of-apps "${APP_OF_APPS_VERSION}")" \
  || die "app-of-apps ${APP_OF_APPS_VERSION} not found in the gitops checkout (have:$(describe_versions app-of-apps)) — check out the matching gitops revision or fix APP_OF_APPS_VERSION in airgap/versions.env"
mkdir -p "${CHARTS_OUT}" "${WORK}/renders"
if (( DRY_RUN )); then
  # no packaging and no dependency downloads in a dry run: render the source dir
  helm_render "${ROOT_APP_NAME}" "${ROOT_APP_NAMESPACE}" "${AOA_DIR}" > "${WORK}/renders/${ROOT_APP_NAME}.yaml" \
    || die "helm template failed for app-of-apps ${APP_OF_APPS_VERSION}"
else
  helm_package_reproducible "${AOA_DIR}" "${CHARTS_OUT}"
  aoa_json="$(jq -cn --arg a "${ROOT_APP_NAME}" --arg v "${APP_OF_APPS_VERSION}" --arg n "${ROOT_APP_NAMESPACE}" \
    '{app: $a, chart: "app-of-apps", version: $v, repo: "", namespace: $n, release: $a, skipCrds: false, overrides: {}, deployed: true}')"
  render_app "${aoa_json}" "${CHARTS_OUT}" "${WORK}/renders/${ROOT_APP_NAME}.yaml" strict
fi

# --- Applications -------------------------------------------------------------------------
step "Applications rendered by app-of-apps ${APP_OF_APPS_VERSION}"
yq -o=json -I=0 'select(.kind == "Application")' "${WORK}/renders/${ROOT_APP_NAME}.yaml" \
  | jq -c '
      .metadata.name as $app
      | ([.spec.source // empty] + (.spec.sources // [])) as $srcs
      | ($srcs | map(select(.chart != null))) as $charts
      | ($charts[0] // {}) as $c
      | {
          app: $app,
          chart: ($c.chart // null),
          version: ($c.targetRevision // null),
          repo: ($c.repoURL // null),
          namespace: (.spec.destination.namespace // ""),
          release: ($c.helm.releaseName // $app),
          skipCrds: ($c.helm.skipCrds // false),
          overrides: (($c.helm // {})
                      | with_entries(select(.key == "values" or .key == "valuesObject" or .key == "parameters"
                                            or .key == "fileParameters" or .key == "valueFiles"))
                      | with_entries(select(.value != null and .value != "" and .value != [] and .value != {}))),
          deployed: true,
          nChartSources: ($charts | length)
        }' > "${WORK}/apps.deployed.jsonl"

[[ -s "${WORK}/apps.deployed.jsonl" ]] || die "app-of-apps ${APP_OF_APPS_VERSION} renders no Application"

bad=0
while IFS= read -r a; do
  app="$(jq -r .app <<<"${a}")"
  n="$(jq -r .nChartSources <<<"${a}")"
  chart="$(jq -r '.chart // ""' <<<"${a}")"
  version="$(jq -r '.version // ""' <<<"${a}")"
  repo="$(jq -r '.repo // ""' <<<"${a}")"
  ns="$(jq -r .namespace <<<"${a}")"
  if [[ "${n}" != 1 ]]; then
    warn "Application ${app}: ${n} Helm chart sources (exactly one is supported: the bundle carries Harbor charts only)"
    bad=1; continue
  fi
  if [[ "${repo#oci://}" != "${HARBOR_REPO}" ]]; then
    warn "Application ${app}: chart ${chart} comes from ${repo}, not ${HARBOR_REPO} (site domain ${DOMAIN})"
    bad=1
  fi
  if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    warn "Application ${app}: targetRevision '${version}' is not an exact chart version"
    bad=1
  fi
  if [[ -z "${ns}" ]]; then
    warn "Application ${app}: no destination namespace"
    bad=1
  fi
done < "${WORK}/apps.deployed.jsonl"
dups="$(jq -r '.chart' "${WORK}/apps.deployed.jsonl" | sort | uniq -d)"
for c in ${dups}; do
  if [[ "$(jq -r --arg c "${c}" 'select(.chart == $c) | .version' "${WORK}/apps.deployed.jsonl" | sort -u | wc -l)" != 1 ]]; then
    warn "app-of-apps ${APP_OF_APPS_VERSION} deploys more than one version of chart ${c}"
    bad=1
  fi
done
(( bad == 0 )) || die "app-of-apps ${APP_OF_APPS_VERSION} does not fit the airgap bundle (see above)"

# extra pins: charts the bundle carries although app-of-apps does not deploy them
cp "${WORK}/apps.deployed.jsonl" "${WORK}/apps.jsonl"
for pin in ${EXTRA_CHART_PINS}; do
  name="${pin%%@*}"
  rest="${pin#*@}"
  version="${rest%%:*}"
  ns="${ROOT_APP_NAMESPACE}"
  [[ "${rest}" == *:* ]] && ns="${rest#*:}"
  [[ -n "${name}" && -n "${version}" && "${pin}" == *@* ]] || die "EXTRA_CHART_PINS entry '${pin}' is not name@version[:namespace]"
  deployed="$(jq -r --arg c "${name}" 'select(.chart == $c) | .version' "${WORK}/apps.deployed.jsonl" | sort -u)"
  if [[ -n "${deployed}" ]]; then
    [[ "${deployed}" == "${version}" ]] \
      || die "EXTRA_CHART_PINS pins ${name} ${version}, but app-of-apps ${APP_OF_APPS_VERSION} deploys ${name} ${deployed}"
    log "extra pin ${name}@${version}: deployed by app-of-apps"
    continue
  fi
  jq -cn --arg a "${name}" --arg v "${version}" --arg n "${ns}" \
    '{app: $a, chart: $a, version: $v, repo: "", namespace: $n, release: $a, skipCrds: false, overrides: {}, deployed: false, nChartSources: 1}' \
    >> "${WORK}/apps.jsonl"
  log "extra pin ${name}@${version} (namespace ${ns}): not deployed by app-of-apps ${APP_OF_APPS_VERSION}"
done

# --- package -------------------------------------------------------------------------------
step "packaging charts"
jq -r '.chart + " " + .version' "${WORK}/apps.jsonl" | sort -u > "${WORK}/charts.txt"
while read -r name version; do
  dir="$(chart_dir_for "${name}" "${version}")" \
    || die "chart ${name} ${version} is pinned, but no source tree carries it (have:$(describe_versions "${name}")) — release it in the gitops branch or fix the pin"
  if (( DRY_RUN )); then
    log "[dry-run] package ${name}-${version} from ${dir#"${SRC}/"}"
    continue
  fi
  helm_package_reproducible "${dir}" "${CHARTS_OUT}"
  [[ -f "${CHARTS_OUT}/${name}-${version}.tgz" ]] || die "helm package did not produce ${name}-${version}.tgz"
  log "packaged ${name}-${version} ($(sha256_file "${CHARTS_OUT}/${name}-${version}.tgz" | cut -c1-12))"
done < "${WORK}/charts.txt"

{
  echo "app-of-apps ${APP_OF_APPS_VERSION}"
  grep -v '^app-of-apps ' "${WORK}/charts.txt" || true
} > "${WORK}/pins.txt"
if (( DRY_RUN )); then
  log "[dry-run] node/charts/pins.txt would be:"
  sed 's/^/  /' "${WORK}/pins.txt" >&2
  exit 0
fi
cp "${WORK}/pins.txt" "${CHARTS_OUT}/pins.txt"

# Exactly the pinned charts, nothing else
for f in "${CHARTS_OUT}"/*.tgz; do
  b="$(basename "${f}" .tgz)"
  grep -qxF "${b% *}" <(awk '{print $1 "-" $2}' "${WORK}/pins.txt") || die "unexpected chart in the bundle: ${b}.tgz"
done

# --- render every Application ------------------------------------------------------------
step "rendering $(grep -c . "${WORK}/apps.jsonl") Applications"
while IFS= read -r a; do
  app="$(jq -r .app <<<"${a}")"
  render_app "${a}" "${CHARTS_OUT}" "${WORK}/renders/${app}.yaml"
done < "${WORK}/apps.jsonl"
log "pins: $(tr '\n' ' ' < "${CHARTS_OUT}/pins.txt" | sed 's/ $//')"
