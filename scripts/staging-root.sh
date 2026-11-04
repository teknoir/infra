#!/usr/bin/env bash
# staging-root.sh: render (default) or apply the staging root Application from
# teknoir-cloud-app-of-apps.yaml.tmpl, filled with a RELEASE (a commit SHA plus its staging-YYYYMMDD.N tag), or,
# before a new cluster's first release, from teknoir-cloud-app-of-apps-prerelease.yaml.tmpl with a BRANCH.
#
#   scripts/staging-root.sh [--context vpro|r415]                 resolve the release, print the manifest
#   scripts/staging-root.sh --context vpro|r415 --apply           apply it (fresh cluster, or a no-op re-apply)
#   scripts/staging-root.sh --context vpro|r415 --check           what --apply would do, applying nothing;
#                                                                 stdout: "<release> <sha>"
#   scripts/staging-root.sh --release staging-20261017.1 --sha <40-hex> [--untagged] [--apply]   explicit release
#   scripts/staging-root.sh [--context vpro|r415] [--check|--apply] --pre-release BRANCH
#                                                                 branch-following root, before the first release;
#                                                                 --check stdout: "<branch> <sha>"
#
# The release is resolved in this order, and never as "the newest tag":
#   1. the live root: with --context, the annotation teknoir.org/release of Application app-of-apps in
#      teknoir-system (its targetRevision must be a 40-hex SHA). This keeps a re-apply from moving staging.
#   2. the newest GitHub Release of teknoir/platform-applications-gitops (gh) that is named
#      staging-YYYYMMDD.N, is not a draft, not a prerelease (= verified) and is not marked. A release is marked
#      by scripts/staging-release with exactly these markers (matched, and nothing else):
#        rolled back:  title starts with "[rolled back]" or the body has the line "Rolled-Back: true"
#        not applied:  title starts with "[not applied]" or the body has the line "Not-Applied: true"
#      Its tag is resolved with `git ls-remote --tags` (the peeled <tag>^{} commit for an annotated tag).
# Every release that does not come from the live root, resolved or explicit (--release/--sha), is verified the same way:
#   - the tag exists and peels to the SHA (an explicit release without a tag needs --untagged, for the time
#     before the first release exists);
#   - the SHA is on the first-parent history of teknoir-cloud (blobless fetch of the branch);
#   - the SHA has the release helper: charts/app-of-apps/values.yaml contains a top-level `release:` key.
# --apply never moves a live root. A live root without the annotation is the pre-cutover branch-following root:
# --apply refuses it (the cutover is scripts/staging-release --bootstrap in platform-applications-gitops). A live
# root with the same release is left alone (no-op: re-applying would only churn the controller's spec rewrite).
# Moving staging to another release is scripts/staging-release.
# --pre-release BRANCH is for a NEW staging cluster before its first release: it renders the pre-release template,
# whose Application has no teknoir.org/release annotation and follows the gitops BRANCH (targetRevision and the helm
# `release` parameter) instead of a released SHA. The branch must exist on the remote and have the release helper
# (charts/app-of-apps/values.yaml with a top-level `release:` key); it is not required to be on teknoir-cloud's
# first-parent history, and the teknoir-cloud branch itself is excluded (it is staged by releases). It excludes
# --release, --sha and --untagged. --apply only acts on a fresh cluster or on a branch-following root already on
# BRANCH; it refuses a released root (it never moves one back to a branch) and a root on another branch.
# Applying needs an explicit --apply and --context; the context must be exactly vpro or r415 (production-looking
# contexts are refused first).
# Stdout carries only the manifest; messages go to stderr. Overridable for tests: GH, GIT, KUBECTL,
# STAGING_GITOPS_REPO, STAGING_GITOPS_URL, STAGING_ROOT_TEMPLATE, STAGING_ROOT_PRERELEASE_TEMPLATE.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE="${STAGING_ROOT_TEMPLATE:-$HERE/../teknoir-cloud-app-of-apps.yaml.tmpl}"
PRERELEASE_TEMPLATE="${STAGING_ROOT_PRERELEASE_TEMPLATE:-$HERE/../teknoir-cloud-app-of-apps-prerelease.yaml.tmpl}"
GH=${GH:-gh} GIT=${GIT:-git} KUBECTL=${KUBECTL:-kubectl}
REPO=${STAGING_GITOPS_REPO:-teknoir/platform-applications-gitops}
REPO_URL=${STAGING_GITOPS_URL:-https://github.com/$REPO}
APP_NS=teknoir-system APP_NAME=app-of-apps
TAG_RE='^staging-[0-9]{8}\.[1-9][0-9]*$'
SHA_RE='^[0-9a-f]{40}$'
BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
CUTOVER_MSG="pre-cutover branch-following root; the cutover is scripts/staging-release --bootstrap in platform-applications-gitops"

CONTEXT='' APPLY='' CHECK='' RELEASE='' SHA='' UNTAGGED='' PRERELEASE=''
die() { echo "staging-root: $*" >&2; exit 1; }
log() { echo "staging-root: $*" >&2; }
usage() { sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; }

while [ $# -gt 0 ]; do
	case $1 in
	--context) CONTEXT=${2:?--context needs a value}; shift ;;
	--apply) APPLY=1 ;;
	--check) CHECK=1 ;;
	--untagged) UNTAGGED=1 ;;
	--release) RELEASE=${2:?--release needs a value}; shift ;;
	--sha) SHA=${2:?--sha needs a value}; shift ;;
	--pre-release) PRERELEASE=${2:?--pre-release needs a value}; shift ;;
	-h | --help) usage; exit 0 ;;
	*) usage; die "unknown argument $1" ;;
	esac
	shift
done

if [ -n "$PRERELEASE" ]; then
	[ -z "$RELEASE$SHA$UNTAGGED" ] || die "--pre-release excludes --release, --sha and --untagged"
	TEMPLATE=$PRERELEASE_TEMPLATE
fi
[ -r "$TEMPLATE" ] || die "template not found: $TEMPLATE"
if [ -n "$CONTEXT" ]; then
	case $CONTEXT in *eks* | *online* | *prod*) die "refusing a production-looking or retired context: $CONTEXT" ;; esac
	case $CONTEXT in vpro | r415) ;; *) die "context must be vpro or r415 (staging), got: $CONTEXT" ;; esac
fi
[ -z "$APPLY" ] || [ -n "$CONTEXT" ] || die "--apply needs an explicit --context (never the current context)"
[ -z "$CHECK" ] || [ -n "$CONTEXT" ] || die "--check needs an explicit --context"
[ -z "$APPLY" ] || [ -z "$CHECK" ] || die "--apply and --check exclude each other"
{ [ -n "$RELEASE" ] && [ -n "$SHA" ]; } || { [ -z "$RELEASE" ] && [ -z "$SHA" ]; } || die "--release and --sha go together"
[ -z "$UNTAGGED" ] || [ -n "$RELEASE" ] || die "--untagged only goes with --release and --sha"
if [ -n "$RELEASE" ]; then
	[[ $RELEASE =~ $TAG_RE ]] || die "bad release name '$RELEASE' (want staging-YYYYMMDD.N, N without leading zeros)"
	[[ $SHA =~ $SHA_RE ]] || die "bad SHA '$SHA' (want 40 lowercase hex characters)"
fi
if [ -n "$PRERELEASE" ]; then
	[[ $PRERELEASE =~ $BRANCH_RE ]] || die "bad branch name '$PRERELEASE'"
	[[ ! $PRERELEASE =~ $SHA_RE ]] || die "'$PRERELEASE' is a SHA, not a branch; use --release/--sha"
	[ "$PRERELEASE" != teknoir-cloud ] || die "the teknoir-cloud branch is staged by releases, not by --pre-release"
fi
WRITE=${APPLY}${CHECK} # set when the run must meet the conditions of --apply

k() { "$KUBECTL" --context "$CONTEXT" "$@"; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# 1. live root -------------------------------------------------------------------------
LIVE_RELEASE='' LIVE_SHA='' LIVE_TARGET=''
if [ -n "$CONTEXT" ]; then
	if out=$(k -n "$APP_NS" get application "$APP_NAME" --ignore-not-found \
		-o jsonpath='{.metadata.annotations.teknoir\.org/release}{"\t"}{.spec.source.targetRevision}' 2>"$TMPD/err"); then
		if [ -n "$out" ]; then
			LIVE_RELEASE=${out%%$'\t'*}
			LIVE_TARGET=${out#*$'\t'}
			LIVE_SHA=$LIVE_TARGET
			if [ -z "$LIVE_RELEASE" ]; then
				if [ -n "$PRERELEASE" ]; then
					: # branch-following: compared with the --pre-release branch in step 2
				elif [ -n "$WRITE" ]; then
					die "$CUTOVER_MSG (live targetRevision '$LIVE_SHA'); refusing to touch it"
				else
					log "live root exists without a teknoir.org/release annotation (branch-following, before the cutover); ignoring it"
					LIVE_SHA=''
				fi
			elif ! [[ $LIVE_RELEASE =~ $TAG_RE && $LIVE_TARGET =~ $SHA_RE ]]; then
				die "live root is inconsistent (release '$LIVE_RELEASE', targetRevision '$LIVE_TARGET'); not guessing"
			fi
		fi
	elif grep -qiE "doesn't have a resource type|no matches for kind|could not find the requested resource" "$TMPD/err"; then
		log "no Application CRD on $CONTEXT yet (fresh cluster)"
	else
		die "cannot read the live root on $CONTEXT: $(tr '\n' ' ' <"$TMPD/err")"
	fi
fi

# 2. resolve and verify ----------------------------------------------------------------
# is_marked <title> <body>: prints the reason and returns 0 when scripts/staging-release marked the release
is_marked() {
	local title=$1 body=${2//$'\r'/}
	if [[ $title == '[rolled back]'* ]] || grep -qx 'Rolled-Back: true' <<<"$body"; then echo "rolled back"; return 0; fi
	if [[ $title == '[not applied]'* ]] || grep -qx 'Not-Applied: true' <<<"$body"; then echo "not applied"; return 0; fi
	return 1
}

# tag_commit <tag>: prints the commit the remote tag points to (peeled for an annotated tag); empty when no such tag
tag_commit() {
	local refs c
	refs=$("$GIT" ls-remote --tags "$REPO_URL" "refs/tags/$1" "refs/tags/$1^{}") || die "git ls-remote failed for $REPO_URL"
	c=$(awk -v r="refs/tags/$1^{}" '$2 == r {print $1}' <<<"$refs")
	[ -n "$c" ] || c=$(awk -v r="refs/tags/$1" '$2 == r {print $1}' <<<"$refs")
	printf '%s' "$c"
}

# branch_commit <branch>: prints the commit the remote branch points to; empty when there is no such branch
branch_commit() {
	local refs
	refs=$("$GIT" ls-remote --heads "$REPO_URL" "refs/heads/$1") || die "git ls-remote failed for $REPO_URL"
	awk -v r="refs/heads/$1" '$2 == r {print $1}' <<<"$refs"
}

# release_helper <sha>: charts/app-of-apps/values.yaml at <sha> has the release helper (top-level `release:` key)
release_helper() {
	local sha=$1 values
	values=$("$GH" api -H 'Accept: application/vnd.github.raw' \
		"repos/$REPO/contents/charts/app-of-apps/values.yaml?ref=$sha") ||
		die "cannot read charts/app-of-apps/values.yaml at $sha"
	grep -Eq '^release:' <<<"$values" ||
		die "$sha predates the release helper (no 'release:' key in charts/app-of-apps/values.yaml); its children would keep following the branch"
}

# verify_sha <sha>: first-parent membership of teknoir-cloud, and the release helper in charts/app-of-apps
verify_sha() {
	local sha=$1 repo=$TMPD/repo
	"$GIT" init -q --bare "$repo" || die "cannot set up a scratch repository"
	"$GIT" -C "$repo" remote add origin "$REPO_URL" || die "cannot set up a scratch repository"
	GIT_TERMINAL_PROMPT=0 "$GIT" -C "$repo" fetch -q --no-tags --filter=blob:none origin \
		"+refs/heads/teknoir-cloud:refs/remotes/origin/teknoir-cloud" || die "cannot fetch teknoir-cloud from $REPO_URL"
	"$GIT" -C "$repo" rev-list --first-parent refs/remotes/origin/teknoir-cloud |
		awk -v s="$sha" '$0 == s {f = 1} END {exit !f}' ||
		die "$sha is not on the first-parent history of teknoir-cloud"
	release_helper "$sha"
}

resolve_from_github() {
	local rows tag title body prerelease draft best='' best_key='' key date n why
	rows=$("$GH" release list -R "$REPO" -L 200 --json tagName,isPrerelease,isDraft,name \
		--jq '.[] | [.tagName, (.isPrerelease|tostring), (.isDraft|tostring), .name] | @tsv') ||
		die "gh release list failed for $REPO (is gh authenticated?)"
	while IFS=$'\t' read -r tag prerelease draft title; do
		[ -n "$tag" ] || continue
		[[ $tag =~ $TAG_RE ]] || continue
		if [ "$prerelease" != false ] || [ "$draft" != false ]; then continue; fi
		date=${tag#staging-}; n=${date#*.}; date=${date%%.*}
		key=$(printf '%s%08d' "$date" "$((10#$n))")
		[[ -z $best_key || $key > $best_key ]] || continue
		body=$("$GH" release view "$tag" -R "$REPO" --json body --jq .body) || die "gh release view $tag failed"
		if why=$(is_marked "$title" "$body"); then log "skipping $tag: marked $why"; continue; fi
		best=$tag best_key=$key
	done <<<"$rows"
	[ -n "$best" ] || die "no verified, unmarked staging-* GitHub Release in $REPO. Before the first release (cutover) use scripts/staging-release --bootstrap in platform-applications-gitops."
	RELEASE=$best
	SHA=$(tag_commit "$RELEASE")
	[ -n "$SHA" ] || die "release $RELEASE has no tag in $REPO (git ls-remote found nothing)"
}

SOURCE='' BRANCH_SHA=''
if [ -n "$PRERELEASE" ]; then
	BRANCH_SHA=$(branch_commit "$PRERELEASE")
	[ -n "$BRANCH_SHA" ] || die "branch $PRERELEASE does not exist in $REPO"
	release_helper "$BRANCH_SHA"
	log "verified branch $PRERELEASE ($BRANCH_SHA): has the release helper"
	if [ -n "$LIVE_RELEASE" ]; then
		[ -z "$WRITE" ] || die "live root is on release $LIVE_RELEASE; --pre-release never moves a released root back to a branch"
		log "note: live root is on $LIVE_RELEASE; rendering the pre-release root for $PRERELEASE"
	elif [ -n "$LIVE_TARGET" ] && [ "$LIVE_TARGET" != "$PRERELEASE" ]; then
		[ -z "$WRITE" ] || die "live root follows $LIVE_TARGET, not $PRERELEASE; not moving it"
		log "note: live root follows $LIVE_TARGET; rendering the pre-release root for $PRERELEASE"
	fi
else
	if [ -n "$RELEASE" ] && [ "$RELEASE" = "$LIVE_RELEASE" ] && [ "$SHA" = "$LIVE_SHA" ]; then
		SOURCE=live
		log "explicit release equals the live root: $RELEASE"
	elif [ -n "$RELEASE" ]; then
		if [ -n "$LIVE_RELEASE" ]; then
			[ -z "$WRITE" ] || die "live root is on $LIVE_RELEASE ($LIVE_SHA); --apply will not move it to $RELEASE. Use scripts/staging-release."
			log "note: live root is on $LIVE_RELEASE, rendering the explicit $RELEASE"
		fi
		SOURCE=explicit
		tagged=$(tag_commit "$RELEASE")
		if [ -n "$tagged" ]; then
			[ "$tagged" = "$SHA" ] || die "tag $RELEASE peels to $tagged, not to $SHA"
		elif [ -n "$UNTAGGED" ]; then
			log "warning: tag $RELEASE does not exist in $REPO (--untagged)"
		else
			die "tag $RELEASE does not exist in $REPO (pass --untagged only for the time before the first release)"
		fi
	elif [ -n "$LIVE_RELEASE" ]; then
		RELEASE=$LIVE_RELEASE SHA=$LIVE_SHA SOURCE=live
		log "release from the live root: $RELEASE"
	else
		resolve_from_github
		SOURCE=github
		log "release from GitHub Releases: $RELEASE"
	fi
	[[ $RELEASE =~ $TAG_RE ]] || die "bad release name '$RELEASE' (want staging-YYYYMMDD.N, N without leading zeros)"
	[[ $SHA =~ $SHA_RE ]] || die "bad SHA '$SHA' (want 40 lowercase hex characters)"
	if [ "$SOURCE" != live ]; then
		verify_sha "$SHA"
		log "verified $RELEASE ($SHA): first-parent of teknoir-cloud, has the release helper"
	fi
fi

# 3. render ----------------------------------------------------------------------------
# the leading comment block of the template documents the placeholders; it is not part of the manifest
if [ -n "$PRERELEASE" ]; then
	MANIFEST=$(sed -e '1,/^---$/{/^#/d}' -e "s|__STAGING_BRANCH__|$PRERELEASE|g" "$TEMPLATE")
else
	MANIFEST=$(sed -e '1,/^---$/{/^#/d}' -e "s/__STAGING_RELEASE_SHA__/$SHA/g" -e "s/__STAGING_RELEASE__/$RELEASE/g" "$TEMPLATE")
fi
if grep -q '__STAGING_' <<<"$MANIFEST"; then die "unfilled placeholder left in $TEMPLATE"; fi

if [ -z "$WRITE" ]; then
	printf '%s\n' "$MANIFEST"
	if [ -n "$PRERELEASE" ]; then
		log "rendered branch $PRERELEASE ($BRANCH_SHA); nothing applied (add --apply --context <ctx> to apply)"
	else
		log "rendered $RELEASE ($SHA); nothing applied (add --apply --context <ctx> to apply)"
	fi
	exit 0
fi
if [ -n "$PRERELEASE" ]; then
	if [ "$LIVE_TARGET" = "$PRERELEASE" ]; then
		log "live root already follows $PRERELEASE; nothing to apply"
	elif [ -n "$CHECK" ]; then
		log "would apply the pre-release root for $PRERELEASE ($BRANCH_SHA) on $CONTEXT (fresh cluster); --check applied nothing"
	else
		printf '%s\n' "$MANIFEST" | k apply -f - >&2
		log "applied root app-of-apps following branch $PRERELEASE ($BRANCH_SHA) on $CONTEXT"
	fi
	[ -z "$CHECK" ] || printf '%s %s\n' "$PRERELEASE" "$BRANCH_SHA"
	exit 0
fi
if [ "$LIVE_RELEASE" = "$RELEASE" ] && [ "$LIVE_SHA" = "$SHA" ]; then
	log "live root on $CONTEXT is already at $RELEASE ($SHA); nothing to apply"
elif [ -n "$CHECK" ]; then
	log "would apply the root at $RELEASE ($SHA) on $CONTEXT (fresh cluster); --check applied nothing"
else
	printf '%s\n' "$MANIFEST" | k apply -f - >&2
	log "applied root app-of-apps at $RELEASE ($SHA) on $CONTEXT"
fi
[ -z "$CHECK" ] || printf '%s %s\n' "$RELEASE" "$SHA"
