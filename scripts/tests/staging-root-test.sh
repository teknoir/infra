#!/usr/bin/env bash
# Test of scripts/staging-root.sh and teknoir-cloud-app-of-apps.yaml.tmpl. Release resolution runs against
# fake gh/git/kubectl, so no cluster or GitHub is touched. Optional, when K3D_CONTEXT is set (a throwaway
# cluster, never vpro): a server-side dry-run apply of the rendered root there. Needs kubeconform.
#   scripts/tests/staging-root-test.sh
#   K3D_CONTEXT=k3d-teknoir-dev scripts/tests/staging-root-test.sh
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/scripts/staging-root.sh"
TMPL="${ROOT}/teknoir-cloud-app-of-apps.yaml.tmpl"
BASELINE="${BASELINE:-$HOME/git/ai/plans/staging-releases-baseline/root-app-of-apps.yaml}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$FIX"

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
SHA3=3333333333333333333333333333333333333333
PEEL=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# fakes ------------------------------------------------------------------------------------
cat >"$TMP/gh" <<'F'
#!/usr/bin/env bash
case "$1 $2" in
"release list") cat "$FIX/releases.tsv" ;;
"release view") cat "$FIX/body-$3" 2>/dev/null || true ;;
"api repos"*|"api "*) cat "$FIX/compare" 2>/dev/null || echo behind ;;
*) echo "fake gh: unexpected $*" >&2; exit 9 ;;
esac
F
cat >"$TMP/git" <<'F'
#!/usr/bin/env bash
[ "$1" = ls-remote ] || { echo "fake git: unexpected $*" >&2; exit 9; }
cat "$FIX/lsremote" 2>/dev/null
F
cat >"$TMP/kubectl" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$FIX/kubectl.log"
case " $* " in
*" apply -f - "*) cat >"$FIX/applied"; exit 0 ;;
*" get application "*)
	[ -f "$FIX/kubectl-err" ] && cat "$FIX/kubectl-err" >&2
	[ -f "$FIX/kubectl-out" ] && cat "$FIX/kubectl-out"
	exit "$(cat "$FIX/kubectl-rc" 2>/dev/null || echo 0)" ;;
esac
echo "fake kubectl: unexpected $*" >&2; exit 9
F
chmod +x "$TMP/gh" "$TMP/git" "$TMP/kubectl"
export FIX GH="$TMP/gh" GIT="$TMP/git" KUBECTL="$TMP/kubectl"

reset() { rm -f "$FIX"/*; : >"$FIX/kubectl.log"; }
run() { OUT=$("$SCRIPT" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

# 1. template shape ------------------------------------------------------------------------
check "template has only the two placeholders" \
	bash -c "[ \"\$(grep -o '__STAGING_[A-Z_]*__' '$TMPL' | LC_ALL=C sort -u | tr '\n' ' ')\" = '__STAGING_RELEASE_SHA__ __STAGING_RELEASE__ ' ]"
check "old root file is gone" test ! -e "$ROOT/teknoir-cloud-app-of-apps.yaml"

# 2. explicit render, compare with the live root spec, kubeconform ---------------------------
reset
run --release staging-20261017.1 --sha "$SHA1"
check "explicit render exits 0" test "$RC" -eq 0
printf '%s\n' "$OUT" >"$TMP/root.yaml"
check "no placeholder left" bash -c "! grep -q '__STAGING_' '$TMP/root.yaml'"
check "render drops the template's comment header" bash -c "[ \"\$(head -1 '$TMP/root.yaml')\" = '---' ] && ! grep -q '^#' '$TMP/root.yaml'"
if [ -r "$BASELINE" ]; then
	python3 -I - "$TMP/root.yaml" "$BASELINE" "$SHA1" <<'PY' && ok "spec equals the live root except targetRevision and helm parameters" || bad "spec differs from the live root"
import sys, yaml
mine = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Application"][0]
live = yaml.safe_load(open(sys.argv[2]))
sha = sys.argv[3]
ms, ls = mine["spec"], live["spec"]
assert ms["source"]["targetRevision"] == sha, ms["source"]
helm = ms["source"].pop("helm")
assert helm == {"parameters": [{"name": "release", "value": sha, "forceString": True},
                               {"name": "releaseName", "value": "staging-20261017.1", "forceString": True}]}, helm
ms["source"].pop("targetRevision"); ls["source"].pop("targetRevision")
assert ls["syncPolicy"]["automated"]["enabled"] is True
assert ms.pop("sources") == []  # empty list in the manifest, dropped by the API server in the live object
assert ms == ls, (ms, ls)
assert mine["metadata"]["annotations"] == {"teknoir.org/release": "staging-20261017.1"}, mine["metadata"]
PY
else
	printf 'SKIP baseline compare: %s not found\n' "$BASELINE"
fi
if command -v kubeconform >/dev/null; then
	kubeconform -strict -ignore-missing-schemas -summary "$TMP/root.yaml" >"$TMP/kc.out" 2>&1 && ok "kubeconform: $(tail -1 "$TMP/kc.out")" || { bad "kubeconform"; cat "$TMP/kc.out"; }
else
	bad "kubeconform not installed"
fi

# 3. validation ---------------------------------------------------------------------------
reset; run --release staging-20261017.1 --sha abc
check "short sha rejected" test "$RC" -ne 0
reset; run --release latest --sha "$SHA1"
check "non staging-* release name rejected" test "$RC" -ne 0
reset; run --release staging-20261017.1
check "--release without --sha rejected" test "$RC" -ne 0
reset; run --apply --release staging-20261017.1 --sha "$SHA1"
check "--apply without --context rejected" test "$RC" -ne 0
reset; run --context teknoir-poc-eks --release staging-20261017.1 --sha "$SHA1"
check "production-looking context refused" test "$RC" -ne 0
reset; run --release staging-20261017.1 --sha "$SHA1"
check "default is print: kubectl never called" test ! -s "$FIX/kubectl.log"

# 4. live root wins -------------------------------------------------------------------------
reset
printf 'staging-20261001.3\t%s' "$SHA3" >"$FIX/kubectl-out"
printf 'staging-20261017.1\tfalse\tfalse\tx\n' >"$FIX/releases.tsv"
run --context vpro
check "live annotation resolves the release" bash -c "[ $RC -eq 0 ] && grep -q 'teknoir.org/release: \"staging-20261001.3\"' <<<'$OUT' && grep -q 'targetRevision: \"$SHA3\"' <<<'$OUT'"
reset; printf 'staging-20261001.3\tteknoir-cloud' >"$FIX/kubectl-out"
run --context vpro
check "live annotation with a branch targetRevision is refused" test "$RC" -ne 0
reset; printf 'staging-20261001.3\t%s' "$SHA3" >"$FIX/kubectl-out"
run --context vpro --apply
check "--apply re-applies the live release" bash -c "[ $RC -eq 0 ] && grep -q '$SHA3' '$FIX/applied'"
reset; printf 'staging-20261001.3\t%s' "$SHA3" >"$FIX/kubectl-out"
run --context vpro --apply --release staging-20261017.1 --sha "$SHA1"
check "--apply refuses to move a live release" bash -c "[ $RC -ne 0 ] && [ ! -e '$FIX/applied' ]"

# 5. GitHub path -------------------------------------------------------------------------------
gh_setup() {
	reset
	printf 'The cluster has no Application CRD' >/dev/null
	cat >"$FIX/releases.tsv" <<EOT
staging-20261016.9	false	false	staging-20261016.9
staging-20261017.2	false	false	staging-20261017.2
staging-20261017.10	false	false	staging-20261017.10
staging-20261018.1	true	false	staging-20261018.1 (prerelease)
staging-20261019.1	false	true	draft
v1.2.3	false	false	not a staging release
EOT
	printf '%s\trefs/tags/staging-20261017.10\n%s\trefs/tags/staging-20261017.10^{}\n' "$SHA2" "$PEEL" >"$FIX/lsremote"
	printf 'the server doesn'"'"'t have a resource type "application"\n' >"$FIX/kubectl-err"; echo 1 >"$FIX/kubectl-rc"
}
gh_setup; run --context vpro
check "newest verified release by number (.10 beats .2; prerelease and draft skipped), peeled sha" \
	bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT' && grep -q '$PEEL' <<<'$OUT' && ! grep -q '$SHA2' <<<'$OUT'"
gh_setup; printf '%s\trefs/tags/staging-20261017.10\n' "$SHA2" >"$FIX/lsremote"; run --context vpro
check "lightweight tag falls back to the plain sha" bash -c "[ $RC -eq 0 ] && grep -q '$SHA2' <<<'$OUT'"
gh_setup; printf 'Rolled back: it broke keycloak\n' >"$FIX/body-staging-20261017.10"
printf '%s\trefs/tags/staging-20261017.2^{}\n' "$SHA1" >"$FIX/lsremote"; run --context vpro
check "release marked rolled back (body) is skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.2' <<<'$OUT' && grep -q '$SHA1' <<<'$OUT'"
gh_setup; sed -i 's/^staging-20261017.10\tfalse\tfalse\t.*/staging-20261017.10\tfalse\tfalse\tstaging-20261017.10 ROLLED BACK/' "$FIX/releases.tsv"
printf '%s\trefs/tags/staging-20261017.2^{}\n' "$SHA1" >"$FIX/lsremote"; run --context vpro
check "release marked rolled back (title) is skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.2' <<<'$OUT'"
gh_setup; : >"$FIX/lsremote"; run --context vpro
check "tag missing on the remote is an error" test "$RC" -ne 0
gh_setup; echo diverged >"$FIX/compare"; run --context vpro
check "tag outside teknoir-cloud history is an error" bash -c "[ $RC -ne 0 ] && grep -q 'not part of its history' <<<'$ERR'"
gh_setup; : >"$FIX/releases.tsv"; run --context vpro
check "no releases is an error (never newest tag)" bash -c "[ $RC -ne 0 ] && grep -q 'no verified' <<<'$ERR'"
gh_setup; printf '\t%s' "teknoir-cloud" >"$FIX/kubectl-out"; echo 0 >"$FIX/kubectl-rc"; rm -f "$FIX/kubectl-err"; run --context vpro
check "branch-following live root (no annotation) falls through to GitHub" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT'"
gh_setup; run --context vpro --apply
check "GitHub-resolved release is applied via kubectl apply -f -" bash -c "[ $RC -eq 0 ] && grep -q '$PEEL' '$FIX/applied' && grep -q -- '--context vpro apply -f -' '$FIX/kubectl.log'"
gh_setup; printf 'Unable to connect to the server\n' >"$FIX/kubectl-err"; run --context vpro
check "an unreachable cluster is an error, not a silent GitHub fallback" test "$RC" -ne 0

# 6. optional: server-side dry-run on a throwaway cluster ----------------------------------
if [ -n "${K3D_CONTEXT:-}" ]; then
	case $K3D_CONTEXT in vpro | r415 | *eks* | *online* | *prod*) bad "K3D_CONTEXT must be a throwaway cluster"; K3D_CONTEXT='' ;; esac
fi
if [ -n "${K3D_CONTEXT:-}" ]; then
	if ! kubectl --context "$K3D_CONTEXT" get crd applications.argoproj.io appprojects.argoproj.io >/dev/null 2>&1; then
		printf 'SKIP k3d dry-run: Application/AppProject CRDs missing on %s (install them first)\n' "$K3D_CONTEXT"
	else
		kubectl --context "$K3D_CONTEXT" get ns teknoir-system >/dev/null 2>&1 || kubectl --context "$K3D_CONTEXT" create ns teknoir-system >/dev/null
		kubectl --context "$K3D_CONTEXT" apply --dry-run=server -f "$TMP/root.yaml" >"$TMP/dry.out" 2>&1 && ok "k3d server-side dry-run: $(tr '\n' ';' <"$TMP/dry.out")" || { bad "k3d server-side dry-run"; cat "$TMP/dry.out"; }
	fi
fi

[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "$fail"
