#!/usr/bin/env bash
# staging-root.sh: render (default) or apply the staging root Application from
# teknoir-cloud-app-of-apps.yaml.tmpl, filled with a RELEASE (a commit SHA plus its staging-YYYYMMDD.N tag).
#
#   scripts/staging-root.sh [--context vpro] [--apply]            resolve the release, print the manifest
#   scripts/staging-root.sh --release staging-20261017.1 --sha <40-hex> [--apply]   explicit release, no lookup
#
# The release is resolved in this order, and never as "the newest tag":
#   1. the live root: with --context, the annotation teknoir.org/release of Application app-of-apps in
#      teknoir-system (its targetRevision must be a 40-hex SHA). This keeps a re-apply from moving staging.
#   2. the newest GitHub Release of teknoir/platform-applications-gitops (gh) that is named
#      staging-YYYYMMDD.N, is not a draft, not a prerelease (= verified) and is not marked rolled back
#      (title or body mentions "rolled back"). Its tag is resolved with `git ls-remote --tags` (the peeled
#      <tag>^{} commit for an annotated tag); the script stops if the tag is missing, is not a commit SHA, or
#      that commit is not in the history of teknoir-cloud (GitHub compare API).
# Applying needs an explicit --apply and --context. With a live root, --apply only re-applies the SAME release;
# moving staging to another release is scripts/staging-release in platform-applications-gitops.
# Stdout carries only the manifest; messages go to stderr. Overridable for tests: GH, GIT, KUBECTL.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE="${STAGING_ROOT_TEMPLATE:-$HERE/../teknoir-cloud-app-of-apps.yaml.tmpl}"
GH=${GH:-gh} GIT=${GIT:-git} KUBECTL=${KUBECTL:-kubectl}
REPO=${STAGING_GITOPS_REPO:-teknoir/platform-applications-gitops}
APP_NS=teknoir-system APP_NAME=app-of-apps
TAG_RE='^staging-[0-9]{8}\.[0-9]+$'
SHA_RE='^[0-9a-f]{40}$'

CONTEXT='' APPLY='' RELEASE='' SHA=''
die() { echo "staging-root: $*" >&2; exit 1; }
log() { echo "staging-root: $*" >&2; }
usage() { sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; }

while [ $# -gt 0 ]; do
	case $1 in
	--context) CONTEXT=${2:?--context needs a value}; shift ;;
	--apply) APPLY=1 ;;
	--release) RELEASE=${2:?--release needs a value}; shift ;;
	--sha) SHA=${2:?--sha needs a value}; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage; die "unknown argument $1" ;;
	esac
	shift
done

[ -r "$TEMPLATE" ] || die "template not found: $TEMPLATE"
if [ -n "$CONTEXT" ]; then
	case $CONTEXT in *eks* | *online* | *prod*) die "refusing a production-looking context: $CONTEXT" ;; esac
fi
[ -z "$APPLY" ] || [ -n "$CONTEXT" ] || die "--apply needs an explicit --context (never the current context)"
{ [ -n "$RELEASE" ] && [ -n "$SHA" ]; } || { [ -z "$RELEASE" ] && [ -z "$SHA" ]; } || die "--release and --sha go together"

k() { "$KUBECTL" --context "$CONTEXT" "$@"; }

# 1. live root -------------------------------------------------------------------------
LIVE_RELEASE='' LIVE_SHA=''
if [ -n "$CONTEXT" ]; then
	err=$(mktemp); trap 'rm -f "$err"' EXIT
	if out=$(k -n "$APP_NS" get application "$APP_NAME" --ignore-not-found \
		-o jsonpath='{.metadata.annotations.teknoir\.org/release}{"\t"}{.spec.source.targetRevision}' 2>"$err"); then
		if [ -n "$out" ]; then
			LIVE_RELEASE=${out%%$'\t'*}
			LIVE_SHA=${out#*$'\t'}
			if [ -z "$LIVE_RELEASE" ]; then
				log "live root exists without a teknoir.org/release annotation (branch-following, before the cutover); ignoring it"
				LIVE_SHA=''
			elif ! [[ $LIVE_RELEASE =~ $TAG_RE && $LIVE_SHA =~ $SHA_RE ]]; then
				die "live root is inconsistent (release '$LIVE_RELEASE', targetRevision '$LIVE_SHA'); not guessing"
			fi
		fi
	elif grep -qiE "doesn't have a resource type|no matches for kind|could not find the requested resource" "$err"; then
		log "no Application CRD on $CONTEXT yet (fresh cluster)"
	else
		die "cannot read the live root on $CONTEXT: $(tr '\n' ' ' <"$err")"
	fi
fi

# 2. resolve ---------------------------------------------------------------------------
resolve_from_github() {
	local rows tag title body prerelease draft best='' best_key='' key date n
	rows=$("$GH" release list -R "$REPO" -L 200 --json tagName,isPrerelease,isDraft,name \
		--jq '.[] | [.tagName, (.isPrerelease|tostring), (.isDraft|tostring), .name] | @tsv') ||
		die "gh release list failed for $REPO (is gh authenticated?)"
	while IFS=$'\t' read -r tag prerelease draft title; do
		[ -n "$tag" ] || continue
		[[ $tag =~ $TAG_RE ]] || continue
		if [ "$prerelease" != false ] || [ "$draft" != false ]; then continue; fi
		date=${tag#staging-}; n=${date#*.}; date=${date%%.*}
		key=$(printf '%s%08d' "$date" "$n")
		[[ -z $best_key || $key > $best_key ]] || continue
		if [[ $title =~ [Rr][Oo][Ll][Ll][Ee][Dd]\ [Bb][Aa][Cc][Kk] ]]; then log "skipping $tag: title says rolled back"; continue; fi
		body=$("$GH" release view "$tag" -R "$REPO" --json body --jq .body) || die "gh release view $tag failed"
		if [[ $body =~ [Rr][Oo][Ll][Ll][Ee][Dd]\ [Bb][Aa][Cc][Kk] ]]; then log "skipping $tag: marked rolled back"; continue; fi
		best=$tag best_key=$key
	done <<<"$rows"
	[ -n "$best" ] || die "no verified, non-rolled-back staging-* GitHub Release in $REPO. Before the first release (cutover) use scripts/staging-release --bootstrap in platform-applications-gitops, or pass --release and --sha explicitly."
	RELEASE=$best
	local refs
	refs=$("$GIT" ls-remote --tags "https://github.com/$REPO" "refs/tags/$RELEASE" "refs/tags/$RELEASE^{}") ||
		die "git ls-remote failed for $REPO"
	SHA=$(awk -v r="refs/tags/$RELEASE^{}" '$2 == r {print $1}' <<<"$refs")
	[ -n "$SHA" ] || SHA=$(awk -v r="refs/tags/$RELEASE" '$2 == r {print $1}' <<<"$refs")
	[ -n "$SHA" ] || die "release $RELEASE has no tag in $REPO (git ls-remote found nothing)"
	# cross-check through the GitHub API: the tagged commit must lie in the history of teknoir-cloud
	local rel
	rel=$("$GH" api "repos/$REPO/compare/teknoir-cloud...$SHA" --jq .status) || die "cannot compare $SHA with teknoir-cloud"
	case $rel in identical | behind) ;; *) die "tag $RELEASE ($SHA) is '$rel' teknoir-cloud, not part of its history" ;; esac
}

if [ -n "$RELEASE" ]; then
	if [ -n "$LIVE_RELEASE" ] && { [ "$RELEASE" != "$LIVE_RELEASE" ] || [ "$SHA" != "$LIVE_SHA" ]; }; then
		[ -z "$APPLY" ] || die "live root is on $LIVE_RELEASE ($LIVE_SHA); --apply will not move it to $RELEASE. Use scripts/staging-release."
		log "note: live root is on $LIVE_RELEASE, rendering the explicit $RELEASE"
	fi
	log "using explicit release $RELEASE"
elif [ -n "$LIVE_RELEASE" ]; then
	RELEASE=$LIVE_RELEASE SHA=$LIVE_SHA
	log "release from the live root: $RELEASE"
else
	resolve_from_github
	log "release from GitHub Releases: $RELEASE"
fi
[[ $RELEASE =~ $TAG_RE ]] || die "bad release name '$RELEASE' (want staging-YYYYMMDD.N)"
[[ $SHA =~ $SHA_RE ]] || die "bad SHA '$SHA' (want 40 lowercase hex characters)"

# 3. render ----------------------------------------------------------------------------
# the leading comment block of the template documents the placeholders; it is not part of the manifest
MANIFEST=$(sed -e '1,/^---$/{/^#/d}' -e "s/__STAGING_RELEASE_SHA__/$SHA/g" -e "s/__STAGING_RELEASE__/$RELEASE/g" "$TEMPLATE")
if grep -q '__STAGING_' <<<"$MANIFEST"; then die "unfilled placeholder left in $TEMPLATE"; fi

if [ -z "$APPLY" ]; then
	printf '%s\n' "$MANIFEST"
	log "rendered $RELEASE ($SHA); nothing applied (add --apply --context <ctx> to apply)"
	exit 0
fi
printf '%s\n' "$MANIFEST" | k apply -f - >&2
log "applied root app-of-apps at $RELEASE ($SHA) on $CONTEXT"
