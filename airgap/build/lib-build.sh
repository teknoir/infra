# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034  # BUILD_DIR, INFRA_ROOT, CACHE_DIR, ... are for the sourcing scripts
# lib-build.sh — shared helpers for the connected-side bundle build
# (airgap/build/*.sh). Sourced, never executed. Needs bash >= 4.4.
#
# Nothing here prints a secret: the build handles none. The gate in
# make-bundle.sh fails the build if any secret material shows up anyway.

# The version check must parse and run under any bash (macOS ships 3.2), so it
# comes first and uses nothing newer.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "[build] ERROR: bash >= 4.4 is required (this is ${BASH_VERSION:-not bash}); on macOS run the build on Linux" >&2
  exit 1
fi

if [[ -n "${AIRGAP_BUILD_LIB_SOURCED:-}" ]]; then
  return 0
fi
AIRGAP_BUILD_LIB_SOURCED=1

set -o errexit -o nounset -o pipefail
shopt -s inherit_errexit

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRGAP_DIR="$(cd "${BUILD_DIR}/.." && pwd)"
INFRA_ROOT="$(cd "${AIRGAP_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  _C_LOG=$'\033[1;34m' _C_WARN=$'\033[1;33m' _C_ERR=$'\033[1;31m' _C_OFF=$'\033[0m'
else
  _C_LOG="" _C_WARN="" _C_ERR="" _C_OFF=""
fi
log()  { printf '%s[build]%s %s\n' "${_C_LOG}" "${_C_OFF}" "$*" >&2; }
warn() { printf '%s[build] WARN:%s %s\n' "${_C_WARN}" "${_C_OFF}" "$*" >&2; }
die()  { printf '%s[build] ERROR:%s %s\n' "${_C_ERR}" "${_C_OFF}" "$*" >&2; exit 1; }
step() { printf '%s[build] ==%s %s\n' "${_C_LOG}" "${_C_OFF}" "$*" >&2; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "${c}" >/dev/null 2>&1 || die "required command not found: ${c}"
  done
}

# ---------------------------------------------------------------------------
# Pins (versions.env) with recorded test overrides
# ---------------------------------------------------------------------------
# Variables a test may override from the environment. Any override is listed
# in PIN_OVERRIDES; make-bundle.sh treats it like a dirty tree.
PIN_OVERRIDABLE=(APP_OF_APPS_VERSION ONESHOT_TIERS EXTRA_CHART_PINS IMAGE_PLATFORMS)
PIN_OVERRIDES=()
declare -A _pin_env=()
for _v in "${PIN_OVERRIDABLE[@]}"; do
  if [[ -n "${!_v+set}" ]]; then _pin_env[${_v}]="${!_v}"; fi
done
# shellcheck source=../versions.env
source "${AIRGAP_DIR}/versions.env"
for _v in "${PIN_OVERRIDABLE[@]}"; do
  if [[ -n "${_pin_env[${_v}]+set}" && "${_pin_env[${_v}]}" != "${!_v}" ]]; then
    PIN_OVERRIDES+=("${_v}=${_pin_env[${_v}]}")
    printf -v "${_v}" '%s' "${_pin_env[${_v}]}"
  fi
done
unset _v _pin_env

# ---------------------------------------------------------------------------
# Paths and caches
# ---------------------------------------------------------------------------
# Version-keyed download cache, shared by every build of every checkout:
#   tools/<key>/<file>        verified upstream artifacts (key carries the version)
#   images/oci/<digest-hex>/  single-platform OCI layouts, keyed by manifest digest
#   images/docker/<hex>-<slug>.tar  docker archives (the tag is in RepoTags)
#   images/manifests/<hex>.json   raw manifests and indexes, keyed by their digest
#   helm/                     isolated HELM_{CACHE,CONFIG,DATA}_HOME
CACHE_DIR="${TEKNOIR_AIRGAP_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/teknoir-airgap}"

# Kubernetes version the charts are rendered for (ArgoCD passes the cluster's).
kube_version() {
  local v="${K3S_VERSION%%+*}"
  echo "${v#v}"
}

# K3S_VERSION contains '+', which must be %2B inside a URL path.
k3s_url_version() {
  echo "${K3S_VERSION//+/%2B}"
}

host_platform() {
  # host_platform — "<os>-<arch>" of the build host, in Go naming
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "unsupported build host OS: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported build host architecture: $(uname -m)" ;;
  esac
  echo "${os}-${arch}"
}

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------
sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

sha256_stdin() {
  sha256sum | awk '{print $1}'
}

# ---------------------------------------------------------------------------
# Safe removal of build-owned directories (never an empty or root path)
# ---------------------------------------------------------------------------
rm_build_dir() {
  # rm_build_dir <dir> — remove a directory this build created. Refuses
  # anything that is not below dist/, the work dir or the cache.
  local d="$1"
  [[ -n "${d}" && "${d}" == /* && "${d}" != "/" ]] || die "refusing to remove '${d}'"
  case "${d}" in
    */.staging-*|*/work|*/work/*|"${CACHE_DIR}"/*) ;;
    *) die "refusing to remove '${d}' (not a build-owned path)" ;;
  esac
  rm -rf -- "${d}"
}

# ---------------------------------------------------------------------------
# Build-host tools: helm, crane, jq, yq at the pinned versions, extracted from
# the verified cache into <work>/bin and put first on PATH
# ---------------------------------------------------------------------------
use_build_tools() {
  # use_build_tools <work-dir>
  local work="$1"
  if [[ ! -f "${work}/bin/.complete" ]]; then
    "${BUILD_DIR}/fetch-tools.sh" --host-bin "${work}/bin"
  fi
  PATH="${work}/bin:${PATH}"
  export PATH
  hash -r
  helm_isolate
}

helm_isolate() {
  # Keep helm away from the operator's helm config, repos and registry logins.
  export HELM_CACHE_HOME="${CACHE_DIR}/helm/cache"
  export HELM_CONFIG_HOME="${CACHE_DIR}/helm/config"
  export HELM_DATA_HOME="${CACHE_DIR}/helm/data"
  export HELM_REGISTRY_CONFIG="${CACHE_DIR}/helm/registry-config.json"
  mkdir -p "${HELM_CACHE_HOME}" "${HELM_CONFIG_HOME}" "${HELM_DATA_HOME}"
}

# ---------------------------------------------------------------------------
# git sources
# ---------------------------------------------------------------------------
git_branch() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || echo "DETACHED"
}

git_is_dirty() {
  # git_is_dirty <repo> — 0 when tracked changes or untracked (non-ignored) files exist
  [[ -n "$(git -C "$1" status --porcelain --untracked-files=normal)" ]]
}

branch_allowed() {
  # branch_allowed <branch> <env> — the env branch or an airgap-redesign* branch
  [[ "$1" == "$2" || "$1" == airgap-redesign* ]]
}

copy_git_files() {
  # copy_git_files <repo> <pathspec> <dest> — copy what a commit of the
  # current tree would contain under <pathspec> (tracked + untracked files that
  # are not ignored; deleted files skipped) into <dest>, keeping relative
  # paths and the executable bit. Ignored build leftovers (vendored subcharts,
  # Chart.lock, .secrets) never get in.
  local repo="$1" spec="$2" dest="$3" f
  mkdir -p "${dest}"
  while IFS= read -r -d '' f; do
    [[ -f "${repo}/${f}" ]] || continue
    [[ ! -L "${repo}/${f}" ]] || die "symlink in the source tree is not supported: ${repo}/${f}"
    mkdir -p "${dest}/$(dirname "${f}")"
    cp -p "${repo}/${f}" "${dest}/${f}"
  done < <(git -C "${repo}" ls-files -z --cached --others --exclude-standard -- "${spec}")
}

# ---------------------------------------------------------------------------
# Chart helpers
# ---------------------------------------------------------------------------
chart_field() {
  # chart_field <chart-dir> <field> — a top-level scalar of Chart.yaml
  yq -r ".$2 // \"\"" "$1/Chart.yaml"
}

helm_package_reproducible() {
  # helm_package_reproducible <chart-dir> <dest-dir> — vendor dependencies,
  # `helm package` (validation, .helmignore), then re-pack the archive with
  # sorted entries, one constant mtime, root ownership and `gzip -n`. helm 4
  # writes the expanded subcharts in a varying order and Chart.lock carries a
  # "generated:" stamp, so its own output differs on every run; this one
  # depends on the chart content only, which Harbor's digest check relies on.
  local dir="$1" dest="$2" name version tmpd tgz
  if [[ "$(yq '.dependencies // [] | length' "${dir}/Chart.yaml")" != "0" ]]; then
    SOURCE_DATE_EPOCH="${CHART_SOURCE_DATE_EPOCH}" helm dependency build "${dir}" >/dev/null \
      || die "helm dependency build failed for ${dir}"
  fi
  rm -f "${dir}/Chart.lock"
  name="$(chart_field "${dir}" name)"
  version="$(chart_field "${dir}" version)"
  tmpd="$(mktemp -d)"
  SOURCE_DATE_EPOCH="${CHART_SOURCE_DATE_EPOCH}" helm package "${dir}" --destination "${tmpd}" >/dev/null \
    || { rm -rf "${tmpd}"; die "helm package failed for ${dir}"; }
  tgz="${tmpd}/${name}-${version}.tgz"
  [[ -f "${tgz}" ]] || { rm -rf "${tmpd}"; die "helm package did not produce ${name}-${version}.tgz"; }
  mkdir -p "${tmpd}/x" "${dest}"
  tar -xzf "${tgz}" -C "${tmpd}/x"
  [[ -d "${tmpd}/x/${name}" ]] || { rm -rf "${tmpd}"; die "${name}-${version}.tgz has no top-level ${name}/"; }
  tar --sort=name --mtime="@${CHART_SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
      --mode='a+rX,u+w,go-w' --format=ustar -C "${tmpd}/x" -cf - "${name}" \
    | gzip -n -9 > "${dest}/${name}-${version}.tgz.tmp"
  mv -f "${dest}/${name}-${version}.tgz.tmp" "${dest}/${name}-${version}.tgz"
  rm -rf "${tmpd}"
}

helm_render() {
  # helm_render <release> <namespace> <chart.tgz> [extra helm args...] — the
  # render ArgoCD performs for an Application: release name, destination
  # namespace, cluster version, CRDs included. stdout: the manifests.
  local release="$1" ns="$2" chart="$3"
  shift 3
  helm template "${release}" "${chart}" \
    --namespace "${ns}" \
    --kube-version "$(kube_version)" \
    --include-crds \
    "$@"
}

render_app() {
  # render_app <app-json> <charts-dir> <out-file> [strict] — render one
  # Application (a line of <work>/apps.jsonl) from its bundled chart exactly as
  # ArgoCD would: its own helm.values / valuesObject / parameters, nothing
  # from the build. With "strict" (one-shot tiers) any Application-level value
  # override is refused: the bundle render must equal ArgoCD's with zero
  # overrides, so every value has to live in the chart's values.yaml.
  local json="$1" charts="$2" out="$3" strict="${4:-}"
  local app chart version release ns tgz tmpd n i name value force
  local -a args=()
  app="$(jq -r .app <<<"${json}")"
  chart="$(jq -r .chart <<<"${json}")"
  version="$(jq -r .version <<<"${json}")"
  release="$(jq -r .release <<<"${json}")"
  ns="$(jq -r .namespace <<<"${json}")"
  tgz="${charts}/${chart}-${version}.tgz"
  [[ -f "${tgz}" ]] || die "render ${app}: ${tgz} is missing"
  if [[ "$(jq '.overrides | length' <<<"${json}")" != "0" ]]; then
    [[ "${strict}" != strict ]] \
      || die "Application ${app} sets helm $(jq -r '.overrides | keys | join(", ")' <<<"${json}"): a one-shot tier is rendered with zero overrides, so move those values into charts/${chart}/values.yaml"
    if jq -e '.overrides | has("valueFiles") or has("fileParameters")' <<<"${json}" >/dev/null; then
      die "Application ${app}: helm.valueFiles / helm.fileParameters are not supported by the airgap build"
    fi
    tmpd="$(mktemp -d)"
    if jq -e '.overrides | has("values")' <<<"${json}" >/dev/null; then
      jq -r '.overrides.values' <<<"${json}" > "${tmpd}/values.yaml"
      args+=(--values "${tmpd}/values.yaml")
    fi
    if jq -e '.overrides | has("valuesObject")' <<<"${json}" >/dev/null; then
      jq '.overrides.valuesObject' <<<"${json}" | yq -P > "${tmpd}/values-object.yaml"
      args+=(--values "${tmpd}/values-object.yaml")
    fi
    n="$(jq '.overrides.parameters // [] | length' <<<"${json}")"
    for (( i = 0; i < n; i++ )); do
      name="$(jq -r ".overrides.parameters[${i}].name" <<<"${json}")"
      value="$(jq -r ".overrides.parameters[${i}].value // \"\"" <<<"${json}")"
      force="$(jq -r ".overrides.parameters[${i}].forceString // false" <<<"${json}")"
      if [[ "${force}" == true ]]; then args+=(--set-string "${name}=${value}"); else args+=(--set "${name}=${value}"); fi
    done
  fi
  if ! helm_render "${release}" "${ns}" "${tgz}" ${args[@]+"${args[@]}"} > "${out}.tmp" 2> "${out}.err"; then
    [[ -z "${tmpd:-}" ]] || rm -rf "${tmpd}"
    die "helm template failed for ${app} (${chart}-${version}): $(head -3 "${out}.err")"
  fi
  [[ -z "${tmpd:-}" ]] || rm -rf "${tmpd}"
  rm -f "${out}.err"
  mv -f "${out}.tmp" "${out}"
}

split_crds() {
  # split_crds <render> <crds-out> <rest-out> — split a helm render into its
  # CustomResourceDefinition documents and everything else. Each document is
  # copied byte for byte, so the concatenation of both files is the render
  # with the CRDs moved to the front (identical when helm already put them
  # first, as it does for a chart's crds/ directory).
  awk -v crds="$2" -v rest="$3" '
    function flush() {
      if (doc != "") { if (iscrd) printf "%s", doc > crds; else printf "%s", doc > rest }
      doc = ""; iscrd = 0
    }
    /^---([[:space:]].*)?$/ { flush() }
    { doc = doc $0 "\n" }
    /^kind:[[:space:]]*CustomResourceDefinition[[:space:]]*$/ { iscrd = 1 }
    END { flush() }
  ' "$1"
  touch "$2" "$3"
}

# ---------------------------------------------------------------------------
# Image references
# ---------------------------------------------------------------------------
normalize_image() {
  # normalize_image <ref> — canonical form (docker.io[/library] added), or
  # nothing for template leftovers / untagged noise (istiod's injection
  # template carries literal `image: {{ ... }}` and `image: auto` lines).
  local ref="$1" first rest
  ref="${ref%\"}"; ref="${ref#\"}"
  ref="${ref%\'}"; ref="${ref#\'}"
  [[ -n "${ref}" ]] || return 0
  case "${ref}" in
    *['{}$`, ']*) return 0 ;;
    auto|*/auto) return 0 ;;
  esac
  first="${ref%%/*}"
  if [[ "${ref}" != */* ]]; then
    ref="docker.io/library/${ref}"
  elif [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
    ref="docker.io/${ref}"
  fi
  if [[ "${ref}" == docker.io/* ]]; then
    rest="${ref#docker.io/}"
    [[ "${rest}" == */* ]] || ref="docker.io/library/${rest}"
  fi
  # rendered charts always pin a tag or digest; bare names are config noise
  [[ "${ref##*/}" == *[:@]* ]] || return 0
  echo "${ref}"
}

extract_images() {
  # extract_images — read rendered manifests on stdin, print normalized refs from
  #   image: REF            containers, initContainers, CR image fields
  #   - --<flag>=REF        image-valued operator args (prometheus-operator's
  #                         --prometheus-config-reloader=, --thanos-default-base-image=)
  local ref
  sed -n -E \
    -e 's/^[[:space:]]*-?[[:space:]]*"?image"?:[[:space:]]*//p' \
    -e 's/^[[:space:]]*-[[:space:]]*"?--[A-Za-z0-9-]*(image|reloader)[A-Za-z0-9-]*=([^"[:space:]]+)"?[[:space:]]*$/\2/p' \
    | tr -d '"'"'" \
    | while read -r ref; do normalize_image "${ref}"; done
}

image_list_file() {
  # image_list_file <file> — refs from a list file (comments, blanks dropped), normalized
  local ref
  sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$1" | while read -r ref; do normalize_image "${ref}"; done
}

image_slug() {
  # image_slug <ref> — filesystem-safe, unique name for a ref
  local s="$1"
  s="${s//\//_}"; s="${s//:/_}"; s="${s//@/_}"
  echo "${s}"
}

image_repo() {
  # image_repo <ref> — the repository part (no tag, no digest)
  local ref="$1" last
  ref="${ref%%@*}"
  last="${ref##*/}"
  if [[ "${last}" == *:* ]]; then ref="${ref%:*}"; fi
  echo "${ref}"
}

image_tag() {
  # image_tag <ref> — the tag, empty for a digest-only ref
  local ref="$1" last
  ref="${ref%%@*}"
  last="${ref##*/}"
  if [[ "${last}" == *:* ]]; then echo "${last##*:}"; fi
}

is_teknoir_image() {
  [[ "$1" == ghcr.io/teknoir/* || "$1" == docker.io/teknoir/* || "$1" == gcr.io/teknoir*/* ]]
}

is_immutable_tag() {
  # is_immutable_tag <ref> — pinned by digest, or a version-like tag
  # (v1.2.3, 1.2, 0.0.83-rc1, sha-<hex>); latest, branch names and
  # date-stamped branch builds are mutable
  local tag
  [[ "$1" == *@sha256:* ]] && return 0
  tag="$(image_tag "$1")"
  [[ "${tag}" =~ ^v?[0-9]+(\.[0-9]+)+([-+][0-9A-Za-z.-]+)?$ || "${tag}" =~ ^sha-[0-9a-f]{7,}$ ]]
}

# ---------------------------------------------------------------------------
# Secret gate (yq and jq from the build tools)
# ---------------------------------------------------------------------------
# Keys a credential-less ArgoCD repository Secret may carry (D3: the Harbor
# chart project is public, so ArgoCD needs only where, never who).
ARGOCD_REPO_SECRET_KEYS="url type name enableOCI project insecure"

secret_gate() {
  # secret_gate <chart-repo> <yaml-file>... — classify every Secret that
  # carries at least one non-empty data/stringData value. One line each:
  #   allow <ns>/<name> <why>  an ArgoCD repository/repo-creds Secret
  #                            (label argocd.argoproj.io/secret-type) whose
  #                            keys are all in ARGOCD_REPO_SECRET_KEYS and
  #                            whose url is <chart-repo> (optionally oci://)
  #   deny <ns>/<name> <why>   every other one
  # Prints key names, never a value (not even a non-matching url). Fails when
  # a file does not parse or a data value is not valid base64: an unreadable
  # Secret must never pass as an empty one.
  local repo="$1" json out
  shift
  (( $# > 0 )) || return 0
  json="$(yq -o=json -I=0 'select(.kind == "Secret")' "$@")" || die "secret_gate: cannot parse $*"
  [[ -n "${json}" ]] || return 0
  out="$(jq -r --arg repo "${repo}" --arg allowed "${ARGOCD_REPO_SECRET_KEYS}" '
    def nonempty: map(select(.value != null and .value != ""));
    . as $s
    | ((($s.data // {}) | to_entries | map(.value |= (if . == null then null else (tostring | @base64d) end)))
       + (($s.stringData // {}) | to_entries | map(.value |= (if . == null then null else tostring end)))) as $all
    | select(($all | nonempty | length) > 0)
    | "\($s.metadata.namespace // "-")/\($s.metadata.name // "?")" as $id
    | ($s.metadata.labels["argocd.argoproj.io/secret-type"] // "") as $type
    | ($all | map(.key) | unique) as $keys
    | ($keys - ($allowed | split(" "))) as $extra
    | ($all | map(select(.key == "url") | .value)) as $urls
    | if ($type == "repository" or $type == "repo-creds") then
        if ($extra | length) > 0 then
          "deny \($id) ArgoCD \($type) Secret with keys beyond the credential-less set: \($extra | join(","))"
        elif ($urls | length) == 0 then
          "deny \($id) ArgoCD \($type) Secret without url"
        elif ($urls | all(. == $repo or . == "oci://" + $repo)) | not then
          "deny \($id) ArgoCD \($type) Secret whose url is not \($repo)"
        else
          "allow \($id) credential-less ArgoCD \($type) Secret for \($repo) (keys: \($keys | join(",")))"
        end
      else
        "deny \($id) Secret with data/stringData (keys: \($keys | join(",")))"
      end
  ' <<<"${json}" 2>/dev/null)" \
    || die "secret_gate: a Secret in $* does not decode (data must be base64; jq's own message would quote the value, so it is not shown)"
  [[ -z "${out}" ]] || LC_ALL=C sort -u <<<"${out}"
}

secret_gate_report() {
  # secret_gate_report <fail-fn> <label> <chart-repo> <yaml-file>... — run
  # secret_gate, log the allowed Secrets and pass each denied one to
  # <fail-fn> (gate_fail, gate_warn, ...) as one message
  local fail="$1" label="$2" repo="$3" verdicts verdict id why
  shift 3
  verdicts="$(secret_gate "${repo}" "$@")"
  [[ -n "${verdicts}" ]] || return 0
  while read -r verdict id why; do
    case "${verdict}" in
      allow) log "${label}: ${id}: ${why}" ;;
      *) "${fail}" "${label}: ${id}: ${why}" ;;
    esac
  done <<<"${verdicts}"
}

# ---------------------------------------------------------------------------
# Site env (airgap/site/<env>.env): plain KEY=value lines, read without
# executing them
# ---------------------------------------------------------------------------
SITE_KEYS_REQUIRED=(TEKNOIR_ENV TEKNOIR_DOMAIN NODE_IP NODE TEKNOIR_HOSTNAMES K3S_DATA_DIR)
SITE_KEYS_OPTIONAL=(TIME_SOURCE)

site_check() {
  # site_check <file> — the file must be plain assignments the LAN host
  # (bash 3.2) and the node can source safely: known keys, literal values (no
  # expansion, command substitution or escapes), no secrets
  local f="$1" line key n=0 bad=0
  [[ -f "${f}" ]] || die "site file not found: ${f}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    [[ "${line}" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ ! "${line}" =~ ^([A-Z][A-Z0-9_]*)=(\"[^\"\$\`\\]*\"|\'[^\']*\'|[^\"\'\$\`\\[:space:]\;\&\|\<\>\(\)]*)$ ]]; then
      warn "${f}:${n}: not a plain KEY=value assignment"
      bad=1
      continue
    fi
    key="${BASH_REMATCH[1]}"
    if [[ " ${SITE_KEYS_REQUIRED[*]} ${SITE_KEYS_OPTIONAL[*]} " != *" ${key} "* ]]; then
      warn "${f}:${n}: unknown key ${key}"
      bad=1
    fi
  done < "${f}"
  for key in "${SITE_KEYS_REQUIRED[@]}"; do
    [[ -n "$(site_get "${f}" "${key}")" ]] || { warn "${f}: ${key} is not set"; bad=1; }
  done
  if grep -v '^[[:space:]]*#' "${f}" | grep -qiE '(password|passwd|secret|token|private)'; then
    warn "${f}: mentions a credential; site files are public and must hold none"
    bad=1
  fi
  (( bad == 0 )) || die "invalid site file ${f}"
}

site_get() {
  # site_get <file> <KEY> — the literal value of KEY (quotes removed), empty if unset
  awk -v k="$2" '
    index($0, k "=") == 1 {
      v = substr($0, length(k) + 2)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      val = v
    }
    END { print val }
  ' "$1"
}

usage_from_header() {
  # usage_from_header <script> — the script's leading comment block as help text
  awk 'NR == 1 { next } /^#/ { if ($0 ~ /^# shellcheck/) next; sub(/^# ?/, ""); print; next } { exit }' "$1"
}
