#!/usr/bin/env bash
# harbor-pin-test.sh — unit test (no cluster, no registry) of G-09 image pins
# on the node: lib/harbor.sh harbor_push_images and lib/release.sh
# post_image_check (with lib/host.sh host_normalize_image_ref) for references
# "<repo>:<tag>@sha256:<d>".
#
#   1. a pin equal to the bundle's manifest is pushed by tag without a
#      warning, and <repo>@<d> is verified in Harbor afterwards; a second run
#      pushes nothing;
#   2. a pin that differs from the bundle's manifest is fatal;
#   3. a tag that already holds the same image in another manifest (an old
#      multi-platform push) gets the pinned manifest added by digest;
#   4. a push after which <repo>@<d> is missing is fatal;
#   5. digest-only references still push by digest; a mismatching one is fatal;
#      unpinned tags are unchanged;
#   6. post_image_check looks up "<repo>@<d>" in the mirror and in containerd.
#
# Harbor is a stub harbor_crane over a state file ("<ref> <config>" lines).
# Usage: airgap/test/unit/harbor-pin-test.sh
#   TEKNOIR_COMMON=<common.sh>   test against that common.sh (default: the tree's)
# shellcheck disable=SC2016  # the scenario scripts expand in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
COMMON="${TEKNOIR_COMMON:-${REPO}/airgap/node/lib/common.sh}"
LIBS="${REPO}/airgap/node/lib"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-hpin.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
NODE="${WORK}/node"
mkdir -p "${NODE}/bin" "${NODE}/images" "${WORK}/tmp" "${WORK}/host/usr/local/bin"
for t in crane helm; do ln -s "$(command -v true)" "${NODE}/bin/${t}"; done
ln -s "$(command -v jq)" "${NODE}/bin/jq"
ln -s "$(type -P true)" "${WORK}/host/usr/local/bin/k3s"
ln -s "${LIBS}" "${NODE}/lib"   # host.sh and release.sh source ${NODE_ROOT}/lib/common.sh

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
expect() {
  # expect <description> <grep -E pattern>... — every pattern is in the output
  local desc="$1" p
  shift
  for p in "$@"; do
    if ! grep -qE -- "${p}" "${WORK}/out"; then bad "${desc}: no /${p}/"; sed 's/^/      /' "${WORK}/out"; return 0; fi
  done
  ok "${desc}"
}
refute() {
  # refute <description> <grep -E pattern> — the pattern is not in the output
  if grep -qE -- "$2" "${WORK}/out"; then bad "$1: /$2/ found"; sed 's/^/      /' "${WORK}/out"; else ok "$1"; fi
}

hex() { printf "$1%.0s" {1..64}; }
M="sha256:$(hex a)"      # the manifest the bundle's layout holds
OTHER="sha256:$(hex b)"  # some other manifest (an index, a re-push)

layout() {
  # layout <slug> <config content> — an OCI layout with one manifest ${M}
  # whose config digest is sha256(<config content>)
  local d="${NODE}/images/$1" cfg
  mkdir -p "${d}/blobs/sha256"
  cfg="sha256:$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"
  printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":1}]}\n' "${M}" > "${d}/index.json"
  printf '{"schemaVersion":2,"config":{"digest":"%s"},"layers":[]}\n' "${cfg}" > "${d}/blobs/sha256/${M#sha256:}"
  printf '%s' "$2" > "${d}/cfgname"
  printf '{}' > "${d}/oci-layout"
}

# push <lock line> [state lines] — harbor_push_images over an images.lock with that one line
push() {
  local rc=0
  printf '%s\n' "$1" > "${NODE}/images/images.lock"
  printf '%s' "${2:-}" > "${WORK}/state"
  : > "${WORK}/calls"
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${NODE}" TEKNOIR_DOMAIN=teknoir.airgapped \
    COMMON="${COMMON}" LIB="${LIBS}/harbor.sh" STATE="${WORK}/state" CALLS="${WORK}/calls" \
    STUB_PUSH_NO_DIGEST="${STUB_PUSH_NO_DIGEST:-0}" HARBOR_RETRY_DELAY=0 HARBOR_PUSH_ATTEMPTS=1 WAIT_INTERVAL=0 \
    bash -c '
      set -euo pipefail
      source "${COMMON}"
      source "${LIB}"
      HARBOR_TMP="$(mktemp -d)"
      HARBOR_REGISTRY=reg.test:5000
      HARBOR_API=https://reg.test:5000/api/v2.0
      HARBOR_JQ=jq
      harbor_healthy() { return 0; }
      present() { awk -v r="$1" '"'"'$1 == r {print $2; f = 1; exit} END {exit !f}'"'"' "${STATE}"; }
      harbor_crane() {
        printf "%s\n" "$*" >> "${CALLS}"
        local c
        case "$1" in
          config)
            c="$(present "$4")" || { echo "GET $4: MANIFEST_UNKNOWN: manifest unknown" >&2; return 1; }
            printf "%s" "${c}" ;;
          manifest)
            present "$2" >/dev/null || { echo "GET $2: MANIFEST_UNKNOWN: manifest unknown" >&2; return 1; }
            echo "{\"schemaVersion\": 2}" ;;
          push)
            c="$(cat "$2/cfgname")"
            echo "$3 ${c}" >> "${STATE}"
            # a registry stores the pushed manifest under its digest too
            if [[ "$3" != *@* && "${STUB_PUSH_NO_DIGEST}" != 1 ]]; then
              echo "$(harbor_ref_repo "$3")@$(jq -r ".manifests[0].digest" "$2/index.json") ${c}" >> "${STATE}"
            fi ;;
          *) return 1 ;;
        esac
      }
      harbor_push_images 0
      rm -rf "${HARBOR_TMP}"
    ' > "${WORK}/out" 2>&1 || rc=$?
  cat "${WORK}/calls" >> "${WORK}/out"
  echo "rc=${rc}" >> "${WORK}/out"
}

layout pinned cfg-x
T_REPO="reg.test:5000/ghcr/teknoir/x"
LOCK="ghcr.io/teknoir/x:sha-1234567@${M}@${M} pinned"

echo "# 1. pin = the bundle's manifest"
push "${LOCK}"
expect "pushed by tag, then the pinned manifest verified" '^rc=0$' \
  "changed: pushed image ghcr.io/teknoir/x:sha-1234567@${M} -> ${T_REPO}:sha-1234567" \
  'images: 1 in the bundle, 0 already in Harbor, 1 to push, 1 pushed'
expect "the push is by tag; the verification reads <repo>@<pin>" "^push ${NODE}/images/pinned ${T_REPO}:sha-1234567$" "^manifest ${T_REPO}@${M}$"
refute "no 'pushed by tag' warning any more" 'WARN'
push "${LOCK}" "${T_REPO}:sha-1234567 cfg-x"$'\n'"${T_REPO}@${M} cfg-x"$'\n'
expect "second run: present, nothing pushed" '^rc=0$' 'images: 1 in the bundle, 1 already in Harbor, 0 to push, 0 pushed'

echo "# 2. pin != the bundle's manifest"
push "ghcr.io/teknoir/x:sha-1234567@${OTHER}@${M} pinned"
expect "fatal, naming both digests" '^rc=1$' "ghcr.io/teknoir/x:sha-1234567@${OTHER}: the bundle holds manifest ${M}, not the pinned ${OTHER}"
refute "nothing pushed" 'changed: pushed'

echo "# 3. the tag holds the same image in another manifest"
push "${LOCK}" "${T_REPO}:sha-1234567 cfg-x"$'\n'
expect "the pinned manifest is added by digest; the tag stays" '^rc=0$' "^push ${NODE}/images/pinned ${T_REPO}@${M}$" \
  "changed: pushed image ghcr.io/teknoir/x:sha-1234567@${M} -> ${T_REPO}@${M}"
refute "the tag is not pushed again" "^push .* ${T_REPO}:sha-1234567$"

echo "# 4. the pinned manifest is missing after the push"
STUB_PUSH_NO_DIGEST=1 push "${LOCK}"
expect "fatal" '^rc=1$' "${T_REPO}@${M}: the pinned manifest is not in Harbor after the push"

echo "# 5. digest-only and unpinned references"
layout httpbin cfg-h
push "docker.io/kennethreitz/httpbin@${M}@${M} httpbin"
expect "a digest-only ref is pushed by digest" '^rc=0$' "^push ${NODE}/images/httpbin reg.test:5000/dockerhub/kennethreitz/httpbin@${M}$"
push "docker.io/kennethreitz/httpbin@${OTHER}@${M} httpbin"
expect "a digest-only ref whose pin is not the bundle's manifest is fatal" '^rc=1$' "not the pinned ${OTHER}"
layout busybox cfg-b
push "docker.io/library/busybox:1.36.1@${M} busybox"
expect "an unpinned tag is pushed by tag, with no pin check" '^rc=0$' "^push ${NODE}/images/busybox reg.test:5000/dockerhub/library/busybox:1.36.1$"
refute "no digest lookup for an unpinned tag" "^manifest reg.test:5000/dockerhub/library/busybox@"

echo "# 6. post_image_check"
cat > "${WORK}/crane" <<'EOF'
#!/usr/bin/env bash
printf 'crane %s\n' "$*" >> "${CALLS}"
[[ "${CRANE_OK:-0}" == 1 && "$*" == "digest --platform linux/amd64 harbor.teknoir.airgapped/ghcr/teknoir/x@${PIN}" ]]
EOF
chmod +x "${WORK}/crane"
imgcheck() {
  # imgcheck <crane ok 0|1> <containerd names> — post_image_check over one pod
  local rc=0
  : > "${WORK}/calls"
  env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${NODE}" TEKNOIR_HOST_ROOT="${WORK}/host" \
    COMMON="${COMMON}" LIBS="${LIBS}" CRANE="${WORK}/crane" CRANE_OK="$1" CTR="$2" PIN="${M}" CALLS="${WORK}/calls" \
    bash -c '
      set -euo pipefail
      source "${COMMON}"; source "${LIBS}/host.sh"; source "${LIBS}/release.sh"
      HARBOR_HOST=harbor.teknoir.airgapped
      kc() { printf "%s" "{\"items\": [{\"status\": {\"phase\": \"Running\"}, \"spec\": {\"containers\": [{\"image\": \"ghcr.io/teknoir/x:sha-1234567@${PIN}\"}]}}]}"; }
      host_containerd_images() { printf "%s\n" "${CTR}"; }
      post_image_check
    ' > "${WORK}/out" 2>&1 || rc=$?
  cat "${WORK}/calls" >> "${WORK}/out"
  echo "rc=${rc}" >> "${WORK}/out"
}
imgcheck 1 ""
expect "the mirror is asked for <repo>@<digest>" '^rc=0$' "^crane digest --platform linux/amd64 harbor.teknoir.airgapped/ghcr/teknoir/x@${M}$" \
  'live image check: 1 pullable from Harbor, 0 only in containerd, 0 missing'
imgcheck 0 "ghcr.io/teknoir/x@${M}"
expect "containerd's <repo>@<digest> name counts as present" '^rc=0$' 'live image check: 0 pullable from Harbor, 1 only in containerd, 0 missing'
imgcheck 0 "ghcr.io/teknoir/x:sha-1234567"
expect "a tag-only containerd name does not count" '^rc=1$' "running images neither in Harbor nor in containerd: ghcr.io/teknoir/x@${M}"

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
