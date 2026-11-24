#!/usr/bin/env bash
# Test of scripts/kargo-root.sh, clusters/r415/root.yaml and the --kargo path of scripts/staging-bootstrap.sh.
# git and kubectl are fakes on PATH (fixture files say what the remote has and what the cluster answers), so nothing
# outside $TMP is touched: no network, no cluster.
#   scripts/tests/kargo-root-test.sh
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
# shellcheck disable=SC2016,SC2034,SC2317  # literals grepped on purpose; check() runs its args indirectly
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/scripts/kargo-root.sh"
BOOTSTRAP="${ROOT}/scripts/staging-bootstrap.sh"
ROOTFILE="${ROOT}/clusters/r415/root.yaml"
LEGACY_TMPL="${ROOT}/teknoir-cloud-app-of-apps.yaml.tmpl"
TMP=$(mktemp -d)
FIX="$TMP/fix"; mkdir -p "$FIX" "$TMP/bin" "$TMP/home"

fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# fixture commits (any 40 lowercase hex works for the fakes) ------------------------------------
C1=1111111111111111111111111111111111111111
C2=2222222222222222222222222222222222222222
C3=3333333333333333333333333333333333333333
C4=4444444444444444444444444444444444444444
ELSE=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
TAGOBJ=9999999999999999999999999999999999999999

# fakes: git and kubectl ------------------------------------------------------------------------
cat >"$TMP/bin/git" <<'F'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$FIX/git.log"
case "$1" in
ls-remote)
	case " $* " in
	*" --symref "*) cat "$FIX/symref"; exit 0 ;;
	*" --tags "*) cat "$FIX/tags" 2>/dev/null; exit 0 ;;
	esac
	echo "fake git: unexpected ls-remote $*" >&2; exit 9 ;;
init | remote) exit 0 ;;
-C)
	shift; shift # -C <dir>
	case "$1" in
	fetch | remote) exit 0 ;;
	merge-base)
		shift # --is-ancestor <commit> <ref>
		grep -qx -- "$2" "$FIX/ancestors" 2>/dev/null && exit 0
		exit 1 ;;
	*) echo "fake git: unexpected -C $*" >&2; exit 9 ;;
	esac ;;
*) echo "fake git: unexpected $*" >&2; exit 9 ;;
esac
F
cat >"$TMP/bin/kubectl" <<'F'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$FIX/kubectl.log"
case " $* " in
*" get application "*)
	# the first read is the live root; later ones (after a --cutover apply) are the read-back in $FIX/live2
	n=$(cat "$FIX/live-count" 2>/dev/null || echo 0)
	printf '%s\n' "$((n + 1))" >"$FIX/live-count"
	if [ "$n" -ge 1 ] && [ -f "$FIX/live2" ]; then cat "$FIX/live2"; exit 0; fi
	[ -f "$FIX/kubectl-err" ] && cat "$FIX/kubectl-err" >&2
	[ -f "$FIX/live" ] && cat "$FIX/live"
	exit "$(cat "$FIX/kubectl-rc" 2>/dev/null || echo 0)" ;;
*" annotate application "*) exit 0 ;;
*" get validatingadmissionpolicy "*)
	[ -f "$FIX/guard" ] && cat "$FIX/guard"
	exit "$(cat "$FIX/guard-rc" 2>/dev/null || echo 0)" ;;
*" apply -f - "*) cat >"$FIX/applied"; exit 0 ;;
*" get crd "*) exit 0 ;;
*" create namespace "*) echo "kind: Namespace"; exit 0 ;;
*" -f - "*) cat >/dev/null; echo "kind: Fake"; exit 0 ;;
esac
echo "fake kubectl: unexpected $*" >&2; exit 9
F
chmod +x "$TMP/bin/git" "$TMP/bin/kubectl"
export FIX GIT="$TMP/bin/git" KUBECTL="$TMP/bin/kubectl"
export KARGO_GITOPS_URL="https://gitops.example.invalid/teknoir/platform-applications-gitops"
# keep a stray real gh/git config out of the way
export HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# reset: fresh remote fixture (default branch main at C4, nothing ancestors), no cluster, no tags
reset() {
	rm -f "$FIX"/applied "$FIX"/live "$FIX"/live2 "$FIX"/live-count "$FIX"/guard "$FIX"/guard-rc \
		"$FIX"/kubectl-err "$FIX"/kubectl-rc "$FIX"/tags
	: >"$FIX/kubectl.log"; : >"$FIX/git.log"
	printf 'ref: refs/heads/main\tHEAD\n%s\tHEAD\n' "$C4" >"$FIX/symref"
	printf '%s\n' "$C1" "$C2" "$C3" "$C4" >"$FIX/ancestors"
}
# tag <name> <commit>: a lightweight tag; annotated tags are written inline with their peeled ref
tag() { printf '%s\trefs/tags/%s\n' "$2" "$1" >>"$FIX/tags"; }
# the live root read, line by line: teknoir.org/release, kargo.akuity.io/authorized-stage, targetRevision
live_kargo() { printf '%s\n%s\n%s\n' '' platform:staging "$1" >"$FIX/live"; } # Kargo-owned, targetRevision <sha>
live_kargo_stale() { printf '%s\n%s\n%s\n' "$1" platform:staging "$2" >"$FIX/live"; } # + old release annotation
live_legacy() { printf '%s\n%s\n%s\n' "$1" '' "$2" >"$FIX/live"; }            # teknoir.org/release, pre-cutover
live_branch() { printf '%s\n%s\n%s\n' '' '' "$1" >"$FIX/live"; }              # branch-following root
# the read-back of a good --cutover apply, as kargo-root.sh's jsonpath prints it
readback_ok() { printf '%s\n\n%s\n%s\n' "$1" platform:staging 'release=$ARGOCD_APP_REVISION' >"$FIX/live2"; }
readback_bad() { printf '%s\n%s\n%s\n%s\n' "$@" >"$FIX/live2"; }

# run <args...>: OUT/ERR are plain text (no interpolation into bash -c below)
run() { "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(cat "$TMP/err"); }
has() { grep -qF -- "$1" "$TMP/out"; }
haserr() { grep -qF -- "$1" "$TMP/err"; }
no_apply() { [ ! -e "$FIX/applied" ] && ! grep -q ' apply ' "$FIX/kubectl.log"; }

# 1. the template ---------------------------------------------------------------------------
check "root.yaml has exactly one placeholder, __VERIFIED_SHA__" \
	bash -c "[ \"\$(grep -o '__[A-Z_]*__' '$ROOTFILE' | LC_ALL=C sort -u | tr '\n' ' ')\" = '__VERIFIED_SHA__ ' ]"
check "root.yaml has the Kargo authorized-stage annotation and no release annotation" bash -c "
	grep -qF 'kargo.akuity.io/authorized-stage: \"platform:staging\"' '$ROOTFILE' &&
	! grep -q 'teknoir.org/release' '$ROOTFILE' && ! grep -q 'releaseName' '$ROOTFILE'"
check "root.yaml documents that Kargo owns targetRevision and that it is never applied unfilled" bash -c "
	grep -q 'Kargo owns targetRevision' '$ROOTFILE' && grep -q 'never applied as is' '$ROOTFILE'"
check "root.yaml parses as two documents and its AppProject equals the legacy template's" \
	bash -c "python3 -I - '$ROOTFILE' '$LEGACY_TMPL' <<'PY'
import sys, yaml
def docs(path):
    return [d for d in yaml.safe_load_all(open(path)) if d]
mine, legacy = docs(sys.argv[1]), docs(sys.argv[2])
assert [d['kind'] for d in mine] == ['AppProject', 'Application'], [d['kind'] for d in mine]
assert mine[0] == [d for d in legacy if d['kind'] == 'AppProject'][0], mine[0]
app = mine[1]
assert app['metadata']['name'] == 'app-of-apps' and app['metadata']['namespace'] == 'teknoir-system'
assert app['metadata']['annotations'] == {'kargo.akuity.io/authorized-stage': 'platform:staging'}, app['metadata']
src = app['spec']['source']
assert src['repoURL'] == 'https://github.com/teknoir/platform-applications-gitops', src
assert src['path'] == 'charts/app-of-apps' and src['targetRevision'] == '__VERIFIED_SHA__', src
assert src['helm'] == {'parameters': [{'name': 'release', 'value': '\$ARGOCD_APP_REVISION', 'forceString': True}]}, src['helm']
assert app['spec']['project'] == 'default'
legacy_app = [d for d in legacy if d['kind'] == 'Application'][0]
assert app['spec']['syncPolicy'] == legacy_app['spec']['syncPolicy'], app['spec']['syncPolicy']
assert app['spec']['destination'] == legacy_app['spec']['destination']
PY"

# 2. explicit --sha: render -----------------------------------------------------------------
reset; run --sha "$C3"
check "explicit --sha renders, exit 0" test "$RC" -eq 0
check "explicit --sha: no placeholder left" bash -c "! grep -q '__VERIFIED_SHA__' '$TMP/out'"
check "explicit --sha: render drops the template's comment header" bash -c "[ \"\$(head -1 '$TMP/out')\" = '---' ] && ! grep -q '^#' '$TMP/out'"
check "explicit --sha: targetRevision is the commit" has "targetRevision: \"$C3\""
check "explicit --sha: authorized-stage annotation is in the manifest" has 'kargo.akuity.io/authorized-stage: "platform:staging"'
check "explicit --sha: \$ARGOCD_APP_REVISION is literal" has '$ARGOCD_APP_REVISION'
check "explicit --sha: no releaseName parameter" bash -c "! grep -q 'releaseName' '$TMP/out'"
check "print mode never calls kubectl" bash -c "[ ! -s '$FIX/kubectl.log' ]"
check "explicit --sha: no verified tag yet is reported as '-', not a failure" haserr '(tag -)'

# 3. newest stamped tag ---------------------------------------------------------------------
reset
tag verified/20261120T101010Z-11111111 "$C1"
tag verified/20261121T090000Z-22222222 "$C2"
tag verified/20261121T090000Z-33333333 "$C3" # same stamp, another commit: a later name wins only on a tie
tag verified/ffffffff "$C4"                  # unstamped: never chosen automatically
run
check "newest stamped verified/* tag is chosen (by stamp), not the unstamped one" bash -c "
	[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C3\"' '$TMP/out' && grep -q 'verified/20261121T090000Z-33333333' '$TMP/err'"
reset; tag verified/20261121T235959Z-22222222 "$C2"; tag verified/20261122T000000Z-33333333 "$C3"
run
check "a tag stamped one second later wins" bash -c "[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C3\"' '$TMP/out'"

# 4. annotated tag peeling ------------------------------------------------------------------
reset; tags_ann() { printf '%s\trefs/tags/verified/20261123T120000Z-22222222\n%s\trefs/tags/verified/20261123T120000Z-22222222^{}\n' "$TAGOBJ" "$C2" >"$FIX/tags"; }; tags_ann
run
check "an annotated tag is peeled to its commit (not the tag object)" bash -c "
	[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C2\"' '$TMP/out' && ! grep -qF '$TAGOBJ' '$TMP/out'"
reset; printf '%s\trefs/tags/verified/20261123T120000Z-22222222^{}\n' "$C2" >"$FIX/tags" # peeled line only
run
check "a peeled ref without the plain ref still resolves" bash -c "[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C2\"' '$TMP/out'"

# 5. unstamped tags only ---------------------------------------------------------------------
reset; tag verified/11111111 "$C1"
run
check "only unstamped tags: refused with a pointer to --sha, nothing rendered" bash -c "
	[ $RC -ne 0 ] && grep -q 'Pass --sha' '$TMP/err' && [ ! -s '$TMP/out' ]"
run --sha "$C1"
check "only unstamped tags + --sha: accepted, the unstamped tag is reported (not silently preferred)" bash -c "
	[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C1\"' '$TMP/out' && grep -q '(tag verified/11111111)' '$TMP/err'"
reset; tag verified/11111111 "$C1"
run --sha "$C2"
check "--sha without any matching verified tag is reported as 'tag -'" bash -c "[ $RC -eq 0 ] && grep -q 'tag -' '$TMP/err'"
reset; tag verified/20261123T120000Z-11111111 "$C1"
run --sha "$C1"
check "--sha names the tagged commit: the tag is reported" bash -c "[ $RC -eq 0 ] && grep -q 'verified/20261123T120000Z-11111111' '$TMP/err'"

# 6. the commit must be on the default branch -------------------------------------------------
reset; run --sha "$ELSE"
check "a commit that is not an ancestor of the default branch is refused, nothing rendered" bash -c "
	[ $RC -ne 0 ] && grep -q 'not an ancestor' '$TMP/err' && [ ! -s '$TMP/out' ]"
reset; tag verified/20261123T120000Z-eeeeeeee "$ELSE"; run
check "a tag on a non-ancestor commit is refused the same way" bash -c "[ $RC -ne 0 ] && grep -q 'not an ancestor' '$TMP/err'"
reset; tag verified/20261123T120000Z-22222222 "$C3"; run
check "a stamped tag whose sha8 disagrees with its peeled commit is refused" bash -c "
	[ $RC -ne 0 ] && grep -q 'tag verified/20261123T120000Z-22222222 names 22222222 but peels to $C3' '$TMP/err' && [ ! -s '$TMP/out' ]"
reset; printf '%s\tHEAD\n' "$C4" >"$FIX/symref"; run --sha "$C3"
check "a remote without a HEAD symref is refused" bash -c "[ $RC -ne 0 ] && grep -q 'default branch' '$TMP/err'"
reset; run --sha abc
check "a short sha is refused" bash -c "[ $RC -ne 0 ] && grep -q 'bad SHA' '$TMP/err'"

# 7. arguments ------------------------------------------------------------------------------
reset; run --apply
check "--apply without --context is refused, kubectl never called" bash -c "[ $RC -ne 0 ] && [ ! -s '$FIX/kubectl.log' ]"
reset; run --check
check "--check without --context is refused" test "$RC" -ne 0
for c in vpro teknoir-poc-eks prod-cluster teknoir-online k3d-r415 r415-old r415-prod; do
	reset; run --context "$c" --sha "$C3"
	check "context $c refused, kubectl never called" bash -c "[ $RC -ne 0 ] && [ ! -s '$FIX/kubectl.log' ]"
done
reset; run --sha "$C3" --apply --context r415 --check
check "--apply and --check exclude each other" test "$RC" -ne 0
reset; run --sha "$C3" --cutover
check "--cutover without --apply/--check is refused" test "$RC" -ne 0
reset; run --context r415 --bogus
check "an unknown argument is refused" test "$RC" -ne 0

# 8. --check ---------------------------------------------------------------------------------
reset; tag verified/20261123T120000Z-11111111 "$C1"; run --context r415 --check
check "--check on a fresh cluster prints '<sha> <tag>' and applies nothing" bash -c "
	[ $RC -eq 0 ] && [ \"\$(cat '$TMP/out')\" = '$C1 verified/20261123T120000Z-11111111' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
reset; run --context r415 --check --sha "$C2"
check "--check with --sha and no tag prints '<sha> -'" bash -c "[ $RC -eq 0 ] && [ \"\$(cat '$TMP/out')\" = '$C2 -' ]"
reset; live_kargo "$C3"; run --context r415 --check --sha "$C3"
check "--check on a live root already at the commit prints the line (nothing to apply)" bash -c "
	[ $RC -eq 0 ] && [ \"\$(cat '$TMP/out')\" = '$C3 -' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
reset; live_kargo "$ELSE"; run --context r415 --check --sha "$C3"
check "--check refuses what --apply would refuse" bash -c "[ $RC -ne 0 ] && [ -z \"\$(cat '$TMP/out')\" ]"

# 9. --apply on a fresh cluster ---------------------------------------------------------------
reset; run --context r415 --apply --sha "$C3"
check "fresh cluster: reads the live root, then applies through kubectl --context r415 apply -f -" bash -c "
	[ $RC -eq 0 ] && head -1 '$FIX/kubectl.log' | grep -q ' get application ' &&
	tail -1 '$FIX/kubectl.log' | grep -q -- '--context r415 apply -f -'"
check "fresh cluster: the applied manifest carries the commit and the annotation" bash -c "
	grep -qF 'targetRevision: \"$C3\"' '$FIX/applied' && grep -qF 'kargo.akuity.io/authorized-stage: \"platform:staging\"' '$FIX/applied'"
reset; printf "the server doesn't have a resource type \"application\"\n" >"$FIX/kubectl-err"; echo 1 >"$FIX/kubectl-rc"
run --context r415 --apply --sha "$C3"
check "no Application CRD yet: treated as a fresh cluster and applied" bash -c "[ $RC -eq 0 ] && [ -e '$FIX/applied' ]"
reset; printf 'Unable to connect to the server\n' >"$FIX/kubectl-err"; echo 1 >"$FIX/kubectl-rc"
run --context r415 --apply --sha "$C3"
check "an unreachable cluster is an error, not a silent apply" bash -c "[ $RC -ne 0 ] && [ ! -e '$FIX/applied' ]"

# 10. a live root is never moved --------------------------------------------------------------
reset; live_kargo "$C2"; run --context r415 --apply --sha "$C3"
check "a Kargo-owned root at another commit is refused, with the BREAK-GLASS pointer" bash -c "
	[ $RC -ne 0 ] && grep -q 'BREAK-GLASS.md' '$TMP/err' && grep -q 'Kargo owns' '$TMP/err'"
check "a refused apply writes nothing" no_apply
reset; live_kargo "$C2"; run --context r415 --apply --sha "$C3" --cutover
check "--cutover does not move a Kargo-owned root either" bash -c "[ $RC -ne 0 ] && grep -q 'BREAK-GLASS.md' '$TMP/err'"
check "--cutover refusal writes nothing" no_apply
reset; live_kargo "$C3"; run --context r415 --apply --sha "$C3"
check "a Kargo-owned root already at the commit is a no-op" bash -c "
	[ $RC -eq 0 ] && grep -q 'nothing to apply' '$TMP/err' && [ ! -e '$FIX/applied' ]"
reset; live_kargo "$C3"; tag verified/20261123T120000Z-33333333 "$C3"; run --context r415 --apply --sha "$C3"
check "the no-op holds with a verified tag too" bash -c "[ $RC -eq 0 ] && [ ! -e '$FIX/applied' ]"
# the Kargo annotation decides, whatever else the root carries (a leftover release annotation cannot make it legacy)
reset; live_kargo_stale staging-20261116.4 "$C3"; run --context r415 --apply --sha "$C3"
check "a Kargo-owned root that still carries teknoir.org/release is a no-op at its commit" bash -c "
	[ $RC -eq 0 ] && grep -q 'nothing to apply' '$TMP/err' && [ ! -e '$FIX/applied' ] &&
	! grep -q 'cut-over: replacing the legacy root' '$TMP/err'"
reset; live_kargo_stale staging-20261116.4 "$C3"; run --context r415 --check --sha "$C3"
check "the same root is a no-op for --check" bash -c "[ $RC -eq 0 ] && [ \"\$(cat '$TMP/out')\" = '$C3 -' ]"
reset; live_kargo_stale staging-20261116.4 "$C2"; run --context r415 --apply --sha "$C3"
check "the same root at another commit is refused" bash -c "
	[ $RC -ne 0 ] && grep -q 'BREAK-GLASS.md' '$TMP/err' && [ ! -e '$FIX/applied' ]"
reset; live_kargo_stale staging-20261116.4 "$C2"; run --context r415 --apply --sha "$C3" --cutover
check "--cutover is refused over it too: the annotation makes it Kargo-owned" bash -c "
	[ $RC -ne 0 ] && grep -q 'Kargo owns' '$TMP/err' && grep -q 'BREAK-GLASS.md' '$TMP/err'"
check "the refused --cutover writes nothing" no_apply

# 11. cut-over from the pre-cutover roots ----------------------------------------------------
reset; live_legacy staging-20261116.4 "$C2"; run --context r415 --apply --sha "$C3"
check "the legacy release-annotated root is refused without --cutover" bash -c "
	[ $RC -ne 0 ] && grep -q -- '--cutover' '$TMP/err' && [ ! -e '$FIX/applied' ]"
reset; live_legacy staging-20261116.4 "$C2"; readback_ok "$C3"; run --context r415 --apply --sha "$C3" --cutover
check "legacy root + --cutover: applied at the verified commit" bash -c "
	[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C3\"' '$FIX/applied' && ! grep -q 'teknoir.org/release' '$FIX/applied' &&
	grep -q 'cut-over: replacing the legacy root' '$TMP/err'"
check "cut-over removes the legacy annotations: client-side apply cannot" bash -c "
	grep -q ' annotate application app-of-apps teknoir.org/release- teknoir.org/previous-release-' '$FIX/kubectl.log'"
check "cut-over reads the root back and accepts it" bash -c "
	grep -q 'cut-over: read back teknoir-system/app-of-apps at $C3' '$TMP/err'"
reset; live_branch teknoir-cloud; run --context r415 --apply --sha "$C3"
check "a branch-following root is refused without --cutover" bash -c "[ $RC -ne 0 ] && grep -q -- '--cutover' '$TMP/err'"
reset; live_branch teknoir-cloud; readback_ok "$C3"; run --context r415 --apply --sha "$C3" --cutover
check "branch-following root + --cutover: applied" bash -c "
	[ $RC -eq 0 ] && grep -qF 'targetRevision: \"$C3\"' '$FIX/applied' && grep -q 'cut-over: replacing the branch-following root' '$TMP/err'"
# a read-back that disagrees with the cut-over fails the run, after the apply and the annotation removal
reset; live_legacy staging-20261116.4 "$C2"; readback_bad "$C2" '' platform:staging 'release=$ARGOCD_APP_REVISION'
run --context r415 --apply --sha "$C3" --cutover
check "read-back at another targetRevision fails the cut-over (non-zero)" bash -c "
	[ $RC -ne 0 ] && grep -q 'read-back targetRevision' '$TMP/err'"
reset; live_legacy staging-20261116.4 "$C2"; readback_bad "$C3" '' '' 'release=$ARGOCD_APP_REVISION'
run --context r415 --apply --sha "$C3" --cutover
check "read-back without the Kargo annotation fails the cut-over" bash -c "
	[ $RC -ne 0 ] && grep -q 'authorized-stage is' '$TMP/err'"
reset; live_legacy staging-20261116.4 "$C2"; readback_bad "$C3" '' platform:staging 'release=staging-20261116.4'
run --context r415 --apply --sha "$C3" --cutover
check "read-back with the wrong helm parameter fails the cut-over" bash -c "
	[ $RC -ne 0 ] && grep -q 'helm parameters' '$TMP/err'"

# 11b. the staging release guard (P4.6) must be gone ------------------------------------------
reset; echo 'validatingadmissionpolicy.admissionregistration.k8s.io/staging-release-guard' >"$FIX/guard"
run --context r415 --check --sha "$C3"
check "the release guard is still installed: --check refuses" bash -c "
	[ $RC -ne 0 ] && grep -q 'staging release guard is still installed' '$TMP/err' && grep -q 'P4.6 first' '$TMP/err' &&
	[ -z \"\$(cat '$TMP/out')\" ]"
reset; echo 'validatingadmissionpolicy.admissionregistration.k8s.io/staging-release-guard' >"$FIX/guard"
run --context r415 --apply --sha "$C3"
check "the release guard is still installed: --apply refuses, applies nothing" bash -c "
	[ $RC -ne 0 ] && grep -q 'P4.6 first' '$TMP/err' && [ ! -e '$FIX/applied' ]"
reset; echo 'validatingadmissionpolicy.admissionregistration.k8s.io/staging-release-guard' >"$FIX/guard"
printf "the server doesn't have a resource type \"application\"\n" >"$FIX/kubectl-err"; echo 1 >"$FIX/kubectl-rc"
run --context r415 --apply --sha "$C3"
check "no Application CRD (fresh cluster): the guard is not consulted" bash -c "
	[ $RC -eq 0 ] && [ -e '$FIX/applied' ] && ! grep -q validatingadmissionpolicy '$FIX/kubectl.log'"
reset; run --context r415 --apply --sha "$C3"
check "no guard installed: applies" bash -c "[ $RC -eq 0 ] && [ -e '$FIX/applied' ]"
reset; run --sha "$C3"
check "print mode never asks the cluster about the guard" bash -c "[ ! -s '$FIX/kubectl.log' ]"

# 12. staging-bootstrap.sh --kargo --------------------------------------------------------------
# only the argument handling: nothing here reaches a cluster or the network
boot() { (PATH="$TMP/bin:$PATH" "$BOOTSTRAP" "$@" >"$TMP/out" 2>"$TMP/err"); RC=$?; }
reset; boot --kargo --context r415 --release staging-20261116.4 --sha "$C3"
check "bootstrap --kargo excludes --release" bash -c "[ $RC -ne 0 ] && grep -q -- '--kargo excludes' '$TMP/err'"
reset; boot --kargo --context r415 --untagged
check "bootstrap --kargo excludes --untagged" bash -c "[ $RC -ne 0 ] && grep -q -- '--kargo excludes' '$TMP/err'"
reset; boot --kargo --context r415 --pre-release main
check "bootstrap --kargo excludes --pre-release" bash -c "[ $RC -ne 0 ] && grep -q -- '--kargo excludes' '$TMP/err'"
reset; boot --kargo --context vpro
check "bootstrap --kargo needs context r415" bash -c "[ $RC -ne 0 ] && grep -q 'context must be r415' '$TMP/err'"
reset; boot --kargo --context r415
check "bootstrap --kargo with no verified tag stops before any cluster change" bash -c "
	[ $RC -ne 0 ] && grep -q 'nothing was changed' '$TMP/err' && [ ! -e '$FIX/applied' ]"

# a tree that has the two scripts and root.yaml side by side, so bootstrap's --kargo path runs for real
TREE="$TMP/tree"; mkdir -p "$TREE/scripts" "$TREE/clusters/r415"
cp "$BOOTSTRAP" "$ROOT/scripts/kargo-root.sh" "$TREE/scripts/"
cp "$ROOTFILE" "$TREE/clusters/r415/"
cat >"$TREE/scripts/deploy-argo.sh" <<'F'
#!/usr/bin/env bash
echo "deploy-argo.sh (stub)" >>"$FIX/kubectl.log"
F
cat >"$TREE/scripts/staging-root.sh" <<'F'
#!/usr/bin/env bash
echo "staging-root.sh must not run with --kargo" >>"$FIX/kubectl.log"
exit 9
F
chmod +x "$TREE"/scripts/*.sh
boot_tree() { (PATH="$TMP/bin:$PATH" "$TREE/scripts/staging-bootstrap.sh" "$@" >"$TMP/out" 2>"$TMP/err"); RC=$?; }
reset; tag verified/20261123T120000Z-33333333 "$C3"; boot_tree --kargo --context r415 --no-ci
check "bootstrap --kargo: succeeds and applies clusters/r415/root.yaml at the verified commit last" bash -c "
	[ $RC -eq 0 ] && [ \"\$(tail -1 '$FIX/kubectl.log' | grep -c ' apply -f -')\" = 1 ] &&
	grep -qF 'targetRevision: \"$C3\"' '$FIX/applied' &&
	grep -qF 'kargo.akuity.io/authorized-stage: \"platform:staging\"' '$FIX/applied' &&
	! grep -q 'teknoir.org/release' '$FIX/applied'"
check "bootstrap --kargo: staging-root.sh never runs, and the root read comes first" bash -c "
	! grep -q 'staging-root.sh must not run' '$FIX/kubectl.log' && head -1 '$FIX/kubectl.log' | grep -q ' get application ' &&
	grep -q 'Kargo owns targetRevision' '$TMP/out'"
# rerun after the cut-over: a live Kargo-owned root, no --sha and no verified tag: its own commit, nothing applied
reset; live_kargo "$C3"; boot_tree --kargo --context r415 --no-ci
check "bootstrap --kargo rerun on a live Kargo root: uses its targetRevision ('<sha> live') and applies nothing" bash -c "
	[ $RC -eq 0 ] && grep -q 'root verified commit: live ($C3)' '$TMP/out' &&
	grep -q 'live root on r415 is Kargo-owned at $C3' '$TMP/err' &&
	grep -q 'nothing to apply' '$TMP/err' && [ ! -e '$FIX/applied' ]"
reset; live_kargo "$C3"; boot_tree --kargo --context r415 --no-ci --sha "$C3"
check "bootstrap --kargo rerun with --sha at the live commit: still a no-op" bash -c "
	[ $RC -eq 0 ] && grep -q 'nothing to apply' '$TMP/err' && [ ! -e '$FIX/applied' ]"

[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "$fail"
