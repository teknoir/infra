#!/usr/bin/env bash
# kargo-root.sh: render (default) or apply the r415 root Application clusters/r415/root.yaml, filled with ONE
# verified commit of teknoir/platform-applications-gitops - never a branch and never a staging-YYYYMMDD.N release
# tag.
#
#   scripts/kargo-root.sh                      resolve the verified commit, print the manifest (no cluster access)
#   scripts/kargo-root.sh --check              what --apply would do, applying nothing; stdout: "<sha> <tag>"
#   scripts/kargo-root.sh --apply              apply it (--context r415 only)
#   scripts/kargo-root.sh --sha <40-hex> ...   use this commit instead of the newest verified/* tag
#
# The commit is resolved as, in this order:
#   1. --sha, if given;
#   2. on a live Kargo-owned root and no --sha, that root's own targetRevision (the staging-bootstrap.sh rerun):
#      the tag reported is `live`;
#   3. the commit of the newest stamped tag `verified/<UTC yyyymmddThhmmssZ>-<sha8>` of the gitops repo
#      (`git ls-remote --tags`, the peeled commit for an annotated tag). Stamps are fixed-width UTC, so the
#      lexically greatest stamp is the newest, and the tag's sha8 must be the start of the peeled commit.
#      Unstamped tags `verified/<sha8>` (the `verifiedTagStamp: none` fallback) carry no order, so they are never
#      chosen automatically: when only unstamped tags exist the script refuses unless --sha is given. With --sha,
#      the newest verified/* tag that points at it is reported, else `-`.
# Every commit is verified the same way: 40 lowercase hex, and an ancestor or equal of the gitops default branch
# (read from the remote HEAD symref; blobless fetch of that branch into a scratch repository).
#
# --apply needs --context r415 exactly (production-looking contexts are refused first) and never moves a live root:
#   - no live Application (fresh cluster, or no Application CRD yet): it applies;
#   - a Kargo-owned root - one carrying the kargo.akuity.io/authorized-stage annotation, whatever other
#     annotations it also has - already at the resolved commit is left alone; at another commit it is refused,
#     because Kargo owns that field; the message points to clusters/r415/BREAK-GLASS.md (Anders only);
#   - any other live root - a legacy root with the teknoir.org/release annotation, or a branch-following root
#     whose targetRevision is not a 40-hex SHA - is refused too: no pre-cutover root exists anywhere any more, so
#     moving one is break-glass (clusters/r415/BREAK-GLASS.md, Anders only).
# --check applies nothing and prints "<sha> <tag>" on stdout; it refuses what --apply would refuse, and on a live
# root already at the commit it prints that line too (nothing to apply).
# Stdout carries only the manifest or that line; messages go to stderr.
# Overridable for tests: GIT, KUBECTL, KARGO_GITOPS_URL, KARGO_ROOT_TEMPLATE.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE="${KARGO_ROOT_TEMPLATE:-$HERE/../clusters/r415/root.yaml}"
GIT=${GIT:-git} KUBECTL=${KUBECTL:-kubectl}
REPO_URL=${KARGO_GITOPS_URL:-https://github.com/teknoir/platform-applications-gitops}
APP_NS=teknoir-system APP_NAME=app-of-apps
SHA_RE='^[0-9a-f]{40}$'
STAMPED_RE='^verified/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'
UNSTAMPED_RE='^verified/[0-9a-f]{8}$'
BREAK_GLASS="clusters/r415/BREAK-GLASS.md"

CONTEXT='' SHA='' APPLY='' CHECK=''
die() { echo "kargo-root: $*" >&2; exit 1; }
log() { echo "kargo-root: $*" >&2; }
usage() { sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//' >&2; }

while [ $# -gt 0 ]; do
	case $1 in
	--context) CONTEXT=${2:?--context needs a value}; shift ;;
	--sha) SHA=${2:?--sha needs a value}; shift ;;
	--apply) APPLY=1 ;;
	--check) CHECK=1 ;;
	-h | --help) usage; exit 0 ;;
	*) usage; die "unknown argument $1" ;;
	esac
	shift
done

[ -r "$TEMPLATE" ] || die "root template not found: $TEMPLATE"
if [ -n "$CONTEXT" ]; then
	case $CONTEXT in *eks* | *online* | *prod*) die "refusing a production-looking or retired context: $CONTEXT" ;; esac
	[ "$CONTEXT" = r415 ] || die "--context must be exactly r415 (the Kargo root is r415's), got: $CONTEXT"
fi
[ -z "$APPLY" ] || [ -n "$CONTEXT" ] || die "--apply needs --context r415 (never the current context)"
[ -z "$CHECK" ] || [ -n "$CONTEXT" ] || die "--check needs --context r415"
[ -z "$APPLY" ] || [ -z "$CHECK" ] || die "--apply and --check exclude each other"
[ -z "$SHA" ] || [[ $SHA =~ $SHA_RE ]] || die "bad SHA '$SHA' (want 40 lowercase hex characters)"
WRITE=${APPLY}${CHECK} # set when the run must meet the conditions of --apply

k() { "$KUBECTL" --context "$CONTEXT" "$@"; }
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# 1. live root on r415 ----------------------------------------------------------------
# Read first: without --sha, a live Kargo-owned root's targetRevision is the commit (the bootstrap rerun).
LIVE_STATE=absent LIVE_RELEASE='' LIVE_KARGO='' LIVE_TARGET=''
if [ -n "$CONTEXT" ]; then
	if out=$(k -n "$APP_NS" get application "$APP_NAME" --ignore-not-found \
		-o jsonpath='{.metadata.annotations.teknoir\.org/release}{"\n"}{.metadata.annotations.kargo\.akuity\.io/authorized-stage}{"\n"}{.spec.source.targetRevision}' 2>"$TMPD/err"); then
		if [ -n "$out" ]; then
			# one line per field: an empty annotation keeps its line (read with IFS=$'\t' would collapse it)
			LIVE_STATE=present
			{ IFS= read -r LIVE_RELEASE || :; IFS= read -r LIVE_KARGO || :; IFS= read -r LIVE_TARGET || :; } <<<"$out"
		fi
	elif grep -qiE "doesn't have a resource type|no matches for kind|could not find the requested resource" "$TMPD/err"; then
		log "no Application CRD on $CONTEXT yet (fresh cluster)"
	else
		die "cannot read the live root on $CONTEXT: $(tr '\n' ' ' <"$TMPD/err")"
	fi
fi

# 2. verified/* tags ------------------------------------------------------------------
# tags.tsv: "<stamp>\t<tag>\t<commit>", an empty stamp for an unstamped verified/<sha8> tag
GIT_TERMINAL_PROMPT=0 "$GIT" ls-remote --tags "$REPO_URL" 'refs/tags/verified/*' 'refs/tags/verified/*^{}' >"$TMPD/tags.raw" ||
	die "git ls-remote --tags failed for $REPO_URL"
declare -A PEELED=() PLAIN=() SEEN=()
while IFS=$'\t' read -r commit ref; do # git ls-remote prints "<sha>\t<ref>"
	[ -n "$ref" ] || continue
	case $ref in
	refs/tags/verified/*'^{}')
		name=${ref#refs/tags/}
		PEELED[${name%\^\{\}}]=$commit
		;;
	refs/tags/verified/*) PLAIN[${ref#refs/tags/}]=$commit ;;
	esac
done <"$TMPD/tags.raw"
: >"$TMPD/tags.tsv"
add_tag() { # <tag name>: one tags.tsv line, the peeled commit when the tag is annotated
	local name=$1 stamp='' commit
	[ -z "${SEEN[$name]:-}" ] || return 0
	SEEN[$name]=1
	if [[ $name =~ $STAMPED_RE ]]; then
		stamp=${name#verified/}
		stamp=${stamp%-*}
	elif ! [[ $name =~ $UNSTAMPED_RE ]]; then
		log "ignoring tag $name (not a verified/<stamp>-<sha8> or verified/<sha8> name)"
		return 0
	fi
	commit=${PLAIN[$name]:-}
	if [ -n "${PEELED[$name]:-}" ]; then commit=${PEELED[$name]}; fi
	[ -n "$commit" ] || { log "ignoring tag $name (git ls-remote gave no commit for it)"; return 0; }
	printf '%s\t%s\t%s\n' "$stamp" "$name" "$commit" >>"$TMPD/tags.tsv"
}
for name in "${!PLAIN[@]}"; do add_tag "$name"; done
for name in "${!PEELED[@]}"; do add_tag "$name"; done
LC_ALL=C sort -u -o "$TMPD/tags.tsv" "$TMPD/tags.tsv"

# newest_tag_for <commit>: the newest verified/* tag that points at <commit> (stamped first), else nothing
newest_tag_for() {
	[ -s "$TMPD/tags.tsv" ] || return 0
	awk -F'\t' -v c="$1" '$3 == c {print ($1 == "" ? "0" : "1") "\t" $1 "\t" $2}' "$TMPD/tags.tsv" |
		LC_ALL=C sort -t $'\t' -k1,1nr -k2,2r | awk -F'\t' 'NR == 1 {print $3}'
}

LIVE_TAG=''
if [ -z "$SHA" ] && [ -n "$WRITE" ] && [ "$LIVE_STATE" = present ] && [ -n "$LIVE_KARGO" ] && [[ $LIVE_TARGET =~ $SHA_RE ]]; then
	# Kargo owns a live root: its current commit is the one there is nothing to do for (bootstrap rerun).
	SHA=$LIVE_TARGET LIVE_TAG=1
	log "live root on $CONTEXT is Kargo-owned at $SHA; using its targetRevision"
fi
if [ -n "$SHA" ]; then
	if [ -n "$LIVE_TAG" ]; then
		TAG=live
	else
		TAG=$(newest_tag_for "$SHA")
		if [ -z "$TAG" ]; then
			TAG='-'
			log "no verified/* tag points at $SHA; using it because --sha named it"
		fi
	fi
else
	TAG=$(awk -F'\t' '$1 != ""' "$TMPD/tags.tsv" | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 | tail -n 1 | cut -f2)
	[ -n "$TAG" ] || die "no stamped verified/<UTC yyyymmddThhmmssZ>-<sha8> tag in $REPO_URL, and an unstamped verified/<sha8> tag has no order; refusing to guess. Pass --sha <40-hex>."
	SHA=$(awk -F'\t' -v t="$TAG" '$2 == t {print $3}' "$TMPD/tags.tsv")
	[[ $SHA =~ $SHA_RE ]] || die "tag $TAG does not peel to a 40-hex commit ('$SHA')"
	[[ $SHA == "${TAG##*-}"* ]] || die "tag $TAG names ${TAG##*-} but peels to $SHA"
	log "newest stamped verified tag: $TAG ($SHA)"
fi

# 3. the commit is on the gitops default branch --------------------------------------
symref=$(GIT_TERMINAL_PROMPT=0 "$GIT" ls-remote --symref "$REPO_URL" HEAD) || die "git ls-remote --symref failed for $REPO_URL"
BRANCH=$(awk '$1 == "ref:" && $3 == "HEAD" {sub("^refs/heads/", "", $2); print $2}' <<<"$symref")
[ -n "$BRANCH" ] || die "cannot read the gitops default branch (no HEAD symref in $REPO_URL)"
case $BRANCH in *[!A-Za-z0-9._/-]*) die "refusing an odd default branch name '$BRANCH'" ;; esac
REPO="$TMPD/repo"
"$GIT" init -q --bare "$REPO" || die "cannot set up a scratch repository"
"$GIT" -C "$REPO" remote add origin "$REPO_URL" || die "cannot set up a scratch repository"
GIT_TERMINAL_PROMPT=0 "$GIT" -C "$REPO" fetch -q --no-tags --filter=blob:none origin \
	"+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" || die "cannot fetch $BRANCH from $REPO_URL"
"$GIT" -C "$REPO" merge-base --is-ancestor "$SHA" "refs/remotes/origin/$BRANCH" 2>/dev/null ||
	die "$SHA is not an ancestor of the gitops default branch $BRANCH (or does not exist there); refusing"
log "verified $SHA: ancestor or equal of $BRANCH, tag ${TAG}"

# 4. a live root is never moved by hand -------------------------------------------------
NOOP=''
if [ -n "$WRITE" ] && [ "$LIVE_STATE" = present ]; then
	if [ -n "$LIVE_KARGO" ]; then
		# The Kargo annotation decides, whatever else the root carries.
		if [ "$LIVE_TARGET" != "$SHA" ]; then
			die "live root $APP_NS/$APP_NAME is Kargo-owned (kargo.akuity.io/authorized-stage=$LIVE_KARGO) at targetRevision '$LIVE_TARGET'; Kargo owns that field, so this script never applies over it. Break-glass is $BREAK_GLASS (Anders only)."
		fi
		NOOP=1
	elif [ -n "$LIVE_RELEASE" ]; then
		die "live root $APP_NS/$APP_NAME is the retired legacy root for release $LIVE_RELEASE (targetRevision '$LIVE_TARGET'); the release-based and pre-cutover roots are gone since CI v4 P7.1, so moving it is $BREAK_GLASS (Anders only)."
	elif [[ $LIVE_TARGET =~ $SHA_RE ]]; then
		if [ "$LIVE_TARGET" != "$SHA" ]; then
			die "live root $APP_NS/$APP_NAME is at targetRevision '$LIVE_TARGET' without a kargo.akuity.io/authorized-stage annotation: a root pinned to a commit is not moved by hand (if the annotation was lost, restore it as $BREAK_GLASS says). Refusing to move it to $SHA."
		fi
		NOOP=1
	else
		die "live root $APP_NS/$APP_NAME is not Kargo-owned: it follows '$LIVE_TARGET' (a branch-following root is retired since CI v4 P7.1), so moving it is $BREAK_GLASS (Anders only)."
	fi
fi

# 5. render ---------------------------------------------------------------------------
# the leading comment block of the template documents the placeholders; it is not part of the manifest
MANIFEST=$(sed -e '1,/^---$/{/^#/d}' -e "s/__VERIFIED_SHA__/$SHA/g" "$TEMPLATE")
if grep -q '__VERIFIED_SHA__' <<<"$MANIFEST"; then die "unfilled __VERIFIED_SHA__ left in $TEMPLATE"; fi

if [ -z "$WRITE" ]; then
	printf '%s\n' "$MANIFEST"
	log "rendered the root at $SHA (tag $TAG); nothing applied (add --apply --context r415 to apply)"
	exit 0
fi
if [ -n "$NOOP" ]; then
	log "live root on $CONTEXT is already at $SHA; nothing to apply"
elif [ -n "$CHECK" ]; then
	log "would apply the root at $SHA on $CONTEXT; --check applied nothing"
else
	printf '%s\n' "$MANIFEST" | k apply -f - >&2
	log "applied the root app-of-apps at $SHA (tag $TAG) on $CONTEXT"
fi
[ -z "$CHECK" ] || printf '%s %s\n' "$SHA" "$TAG"
