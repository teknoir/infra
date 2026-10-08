#!/usr/bin/env bash
# render-oneshot.sh — pre-render the one-shot bootstrap tiers (I-04) into
# <stage>/node/oneshot/:
#
#   TIERS                  the tier names in apply order (ONESHOT_TIERS)
#   <tier>-crds.yaml       the tier's CustomResourceDefinitions (only when it has any)
#   <tier>.yaml            everything else
#
# Each tier is the Application of that name (else the one whose chart has that
# name, else an EXTRA_CHART_PINS entry), rendered from its bundled chart .tgz
# exactly as ArgoCD renders it: `helm template <release> <chart.tgz>
# --namespace <destination> --kube-version <k3s> --include-crds` and NO value
# overrides at all — an Application that sets helm values/parameters is
# refused. So the node's server-side apply as argocd-controller equals what
# ArgoCD adopts. The split copies documents byte for byte:
# `cat <tier>-crds.yaml <tier>.yaml` is the helm output with the CRDs moved to
# the front (identical when the chart ships them in crds/).
#
# Gates (fatal): no Secret with data/stringData (the one exception is a
# credential-less ArgoCD repository Secret for harbor.<domain>/<project>, see
# secret_gate in lib-build.sh), no PEM private key header, no node IP (the
# coredns/registries templates substitute it at run time), a non-empty render
# for every tier.
#
# Usage: render-oneshot.sh --stage DIR --work DIR --site FILE
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib-build.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-build.sh"

usage() { usage_from_header "${BASH_SOURCE[0]}"; }

STAGE="" WORK="" SITE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) STAGE="${2:?}"; shift ;;
    --work) WORK="${2:?}"; shift ;;
    --site) SITE="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done
[[ -n "${STAGE}" && -n "${WORK}" && -n "${SITE}" ]] || { usage; exit 2; }
[[ -s "${WORK}/apps.jsonl" ]] || die "${WORK}/apps.jsonl is missing (run collect-charts.sh first)"
use_build_tools "${WORK}"

NODE_IP="$(site_get "${SITE}" NODE_IP)"
[[ -n "${NODE_IP}" ]] || die "${SITE} sets no NODE_IP"
DOMAIN="$(site_get "${SITE}" TEKNOIR_DOMAIN)"
[[ -n "${DOMAIN}" ]] || die "${SITE} sets no TEKNOIR_DOMAIN"
CHART_REPO="harbor.${DOMAIN}/${HARBOR_CHART_PROJECT}"

OUT="${STAGE}/node/oneshot"
[[ ! -e "${OUT}" ]] || rm -rf -- "${OUT:?}"
mkdir -p "${OUT}"
: > "${WORK}/oneshot.jsonl"

read -r -a tiers <<<"${ONESHOT_TIERS}"
(( ${#tiers[@]} > 0 )) || die "ONESHOT_TIERS is empty"
printf '%s\n' "${tiers[@]}" > "${OUT}/TIERS"
[[ "$(sort "${OUT}/TIERS" | uniq -d)" == "" ]] || die "ONESHOT_TIERS lists a tier twice: ${ONESHOT_TIERS}"

bad=0
tier_fail() { warn "$*"; bad=1; }
for tier in "${tiers[@]}"; do
  [[ "${tier}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid tier name '${tier}'"
  app_json="$(jq -c --arg t "${tier}" 'select(.app == $t)' "${WORK}/apps.jsonl" | head -1)"
  [[ -n "${app_json}" ]] || app_json="$(jq -c --arg t "${tier}" 'select(.chart == $t)' "${WORK}/apps.jsonl" | head -1)"
  [[ -n "${app_json}" ]] \
    || die "one-shot tier ${tier}: app-of-apps ${APP_OF_APPS_VERSION} deploys no Application or chart named ${tier}, and EXTRA_CHART_PINS has no ${tier}@<version>"
  chart="$(jq -r .chart <<<"${app_json}")"
  version="$(jq -r .version <<<"${app_json}")"
  release="$(jq -r .release <<<"${app_json}")"
  ns="$(jq -r .namespace <<<"${app_json}")"
  if [[ "$(jq -r .skipCrds <<<"${app_json}")" == true ]]; then
    warn "tier ${tier}: its Application sets helm.skipCrds, so ArgoCD's render omits the chart's crds/ that this one-shot render includes"
  fi

  full="${WORK}/oneshot-${tier}.full.yaml"
  render_app "${app_json}" "${STAGE}/node/charts" "${full}" strict
  [[ -s "${full}" ]] || die "tier ${tier}: ${chart}-${version} renders nothing"
  if [[ -f "${WORK}/renders/$(jq -r .app <<<"${app_json}").yaml" ]] \
     && ! cmp -s "${full}" "${WORK}/renders/$(jq -r .app <<<"${app_json}").yaml"; then
    # same chart, same arguments: only template randomness (randAlphaNum,
    # genCA, htpasswd) can make two renders differ
    warn "tier ${tier}: two renders of ${chart}-${version} differ — the chart uses random functions, so neither ArgoCD's render nor a re-run equals this bundle's"
  fi

  crds="${OUT}/${tier}-crds.yaml"
  rest="${OUT}/${tier}.yaml"
  split_crds "${full}" "${crds}" "${rest}"
  if [[ ! -s "${crds}" ]]; then rm -f "${crds}"; fi
  [[ -s "${rest}" ]] || die "tier ${tier}: only CRDs rendered"

  # the split must reproduce the render exactly (as a multiset of lines)
  if ! cmp -s <(sort "${full}") <(cat "${crds}" "${rest}" 2>/dev/null | sort); then
    die "tier ${tier}: CRD split lost or changed content"
  fi
  ncrd=0
  [[ -f "${crds}" ]] && ncrd="$(grep -c '^kind:[[:space:]]*CustomResourceDefinition' "${crds}")"
  order=identical
  if [[ -f "${crds}" ]] && ! cmp -s "${full}" <(cat "${crds}" "${rest}"); then order="crds-moved-first"; fi

  # --- per-tier gates ---
  # secret material must come from platform-secrets / the node, never from a render
  secret_gate_report tier_fail "tier ${tier}" "${CHART_REPO}" "${full}"
  # stricter than the chart scan: the tiers ship verbatim, so any PEM private
  # key header fails, with or without a body
  rc=0
  grep -qE -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' "${full}" || rc=$?
  case "${rc}" in
    0) tier_fail "tier ${tier}: the render contains a PEM private key header" ;;
    1) ;;
    *) tier_fail "tier ${tier}: cannot scan the render (grep rc ${rc})" ;;
  esac
  if grep -qF -- "${NODE_IP}" "${full}" || grep -qE '(^|[^0-9.])192\.168\.[0-9]+\.[0-9]+' "${full}"; then
    warn "tier ${tier}: the render contains a node/LAN IP address (${NODE_IP} or 192.168.x.x); node IPs are substituted on the node at run time"
    bad=1
  fi

  jq -cn --arg tier "${tier}" --arg chart "${chart}" --arg version "${version}" --arg release "${release}" \
     --arg ns "${ns}" --argjson crds "${ncrd}" --arg order "${order}" --arg sha "$(sha256_file "${full}")" \
     '{tier: $tier, chart: $chart, version: $version, release: $release, namespace: $ns,
       crds: $crds, crdOrder: $order, renderSha256: $sha}' >> "${WORK}/oneshot.jsonl"
  log "tier ${tier}: ${chart}-${version} release=${release} namespace=${ns} crds=${ncrd} ($(grep -c '^kind:' "${rest}") other objects)"
done

(( bad == 0 )) || die "one-shot renders failed the gate (see above); fix the charts' values in the gitops branch"
