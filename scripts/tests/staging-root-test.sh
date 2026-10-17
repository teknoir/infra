#!/usr/bin/env bash
# Test of scripts/staging-root.sh, scripts/staging-bootstrap.sh (release resolution before any change) and
# teknoir-cloud-app-of-apps.yaml.tmpl. gh and kubectl are fakes; git is the real git against a fixture repository
# (file://, merges, annotated and lightweight tags), so first-parent membership, tag peeling and the blobless fetch
# are exercised for real. Nothing outside $TMP is touched.
# Optional, when K3D_CONTEXT is set (a throwaway cluster, never vpro): the rendered root is applied into a scratch
# namespace, bound to the staging-release-guard policy (chart in RELEASE_GUARD_CHART, default
# ~/git/ai/.worktrees/gitops-release-tooling/charts/release-guard; needs helm and python3 yaml) and re-applied, as
# scripts/staging-root.sh does on every bootstrap rerun. The guard must let the unchanged spec through.
#   scripts/tests/staging-root-test.sh
#   K3D_CONTEXT=k3d-teknoir-dev scripts/tests/staging-root-test.sh
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/scripts/staging-root.sh"
TMPL="${ROOT}/teknoir-cloud-app-of-apps.yaml.tmpl"
BASELINE="${HERE}/fixtures/live-root-spec.yaml"
GUARD_CHART="${RELEASE_GUARD_CHART:-$HOME/git/ai/.worktrees/gitops-release-tooling/charts/release-guard}"
TMP=$(mktemp -d)
FIX="$TMP/fix"; mkdir -p "$FIX" "$TMP/bin"

fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# git fixture: a real repository ------------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
GR="$TMP/gitops"
g() { git -C "$GR" "$@"; }
git init -q -b teknoir-cloud "$GR"
g config uploadpack.allowFilter true
mkdir -p "$GR/charts/app-of-apps"
printf 'project: teknoir-cloud\n' >"$GR/charts/app-of-apps/values.yaml"
g add -A; g commit -qm c1-without-release-helper; C1=$(g rev-parse HEAD)
printf 'project: teknoir-cloud\nrelease: ""\nreleaseName: ""\n' >"$GR/charts/app-of-apps/values.yaml"
g commit -qam c2-release-helper; C2=$(g rev-parse HEAD)
g checkout -q -b feature; echo f >"$GR/f"; g add f; g commit -qm f1-on-a-feature-branch; F1=$(g rev-parse HEAD)
g checkout -q teknoir-cloud; g merge -q --no-ff feature -m m1-merge-of-feature; M1=$(g rev-parse HEAD)
echo c >"$GR/c"; g add c; g commit -qm c3; C3=$(g rev-parse HEAD)
ELSE=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
export STAGING_GITOPS_URL="file://$GR"
tags_reset() { g tag -l | xargs -r git -C "$GR" tag -d >/dev/null; }
tag_ann() { g tag -a -m "release $1" "$1" "$2"; }
tag_lw() { g tag "$1" "$2"; }

# fakes for gh and kubectl ---------------------------------------------------------------------
cat >"$TMP/bin/gh" <<'F'
#!/usr/bin/env bash
case "$1" in
release)
	case "$2" in
	list) cat "$FIX/releases.tsv" ;;
	view) cat "$FIX/body-$3" 2>/dev/null || true ;;
	*) exit 9 ;;
	esac ;;
api)
	ref=${*: -1}; sha=${ref##*ref=}
	case $ref in repos/*/contents/charts/app-of-apps/values.yaml\?ref=*) git -C "$GR" show "$sha:charts/app-of-apps/values.yaml" 2>/dev/null ;; *) exit 9 ;; esac ;;
*) echo "fake gh: unexpected $*" >&2; exit 9 ;;
esac
F
cat >"$TMP/bin/kubectl" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$FIX/kubectl.log"
case " $* " in
*" apply -f - "*) if [[ " $* " != *--server-side* ]]; then cat >"$FIX/applied"; else cat >/dev/null; fi; exit 0 ;;
*" get application "*)
	[ -f "$FIX/kubectl-err" ] && cat "$FIX/kubectl-err" >&2
	[ -f "$FIX/kubectl-out" ] && cat "$FIX/kubectl-out"
	exit "$(cat "$FIX/kubectl-rc" 2>/dev/null || echo 0)" ;;
*" get crd "*) exit 0 ;;
*" get secret "*) exit 0 ;;
*" -f - "* | *" --from-file="*) cat >/dev/null; echo "kind: Fake"; exit 0 ;;
*" create namespace "*) echo "kind: Namespace"; exit 0 ;;
esac
echo "fake kubectl: unexpected $*" >&2; exit 9
F
chmod +x "$TMP/bin/gh" "$TMP/bin/kubectl"
export FIX GR GH="$TMP/bin/gh" KUBECTL="$TMP/bin/kubectl"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

reset() { rm -f "$FIX"/*; : >"$FIX/kubectl.log"; tags_reset; }
# OUT and ERR are interpolated into bash -c strings below: strip single quotes (Let's Encrypt, doesn't ...)
run() { "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(tr -d "'" <"$TMP/out"); ERR=$(tr -d "'" <"$TMP/err"); }

# 1. template shape -----------------------------------------------------------------------------
check "template has only the two placeholders" \
	bash -c "[ \"\$(grep -o '__STAGING_[A-Z_]*__' '$TMPL' | LC_ALL=C sort -u | tr '\n' ' ')\" = '__STAGING_RELEASE_SHA__ __STAGING_RELEASE__ ' ]"
check "old root file is gone" test ! -e "$ROOT/teknoir-cloud-app-of-apps.yaml"
check "template has no 'sources:' (the controller drops an empty list; re-applying it is a spec change)" bash -c "! grep -qE '^[[:space:]]*sources:' '$TMPL'"

# 2. explicit render, compare with the live root spec ---------------------------------------------
reset; tag_ann staging-20261017.1 "$C3"
run --release staging-20261017.1 --sha "$C3"
check "explicit render exits 0" test "$RC" -eq 0
cp "$TMP/out" "$TMP/root.yaml"
check "no placeholder left" bash -c "! grep -q '__STAGING_' '$TMP/root.yaml'"
check "render drops the template's comment header" bash -c "[ \"\$(head -1 '$TMP/root.yaml')\" = '---' ] && ! grep -q '^#' '$TMP/root.yaml'"
check "baseline fixture exists (a missing baseline is a failure)" test -r "$BASELINE"
python3 -I - "$TMP/root.yaml" "$BASELINE" "$C3" <<'PY' && ok "spec equals the live root except targetRevision and helm parameters; no sources key" || bad "spec differs from the live root"
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
assert "sources" not in ms, ms
assert ms == ls, (ms, ls)
assert mine["metadata"]["annotations"] == {"teknoir.org/release": "staging-20261017.1"}, mine["metadata"]
PY

# 3. argument validation ----------------------------------------------------------------------------
reset; run --release staging-20261017.1 --sha abc
check "short sha rejected" test "$RC" -ne 0
reset; run --release latest --sha "$C3"
check "non staging-* release name rejected" test "$RC" -ne 0
reset; run --release staging-20261017.08 --sha "$C3"
check "leading zero in the release number rejected (regex, not an octal crash)" bash -c "[ $RC -ne 0 ] && grep -q 'bad release name' <<<'$ERR' && ! grep -qi octal <<<'$ERR'"
reset; run --release staging-20261017.0 --sha "$C3"
check "release number 0 rejected" test "$RC" -ne 0
reset; run --release staging-20261017.1
check "--release without --sha rejected" test "$RC" -ne 0
reset; run --untagged
check "--untagged without --release rejected" test "$RC" -ne 0
reset; run --apply --release staging-20261017.1 --sha "$C3"
check "--apply without --context rejected" test "$RC" -ne 0
reset; run --check
check "--check without --context rejected" test "$RC" -ne 0
for c in teknoir-poc-eks prod-cluster teknoir-online r415 k3d-r415; do
	reset; run --context "$c" --release staging-20261017.1 --sha "$C3"
	check "context $c refused, kubectl never called" bash -c "[ $RC -ne 0 ] && [ ! -s '$FIX/kubectl.log' ]"
done
reset; tag_ann staging-20261017.1 "$C3"; run --release staging-20261017.1 --sha "$C3"
check "default is print: kubectl never called" test ! -s "$FIX/kubectl.log"

# 4. explicit release is verified like a resolved one ------------------------------------------------
R=staging-20261017.1
reset; tag_ann $R "$C3"; run --release $R --sha "$C3"
check "explicit: annotated tag peels to the sha" test "$RC" -eq 0
reset; tag_lw $R "$C3"; run --release $R --sha "$C3"
check "explicit: lightweight tag matches" test "$RC" -eq 0
reset; run --release $R --sha "$C3"
check "explicit: missing tag without --untagged is refused" bash -c "[ $RC -ne 0 ] && grep -q 'does not exist' <<<'$ERR' && grep -q -- '--untagged' <<<'$ERR'"
reset; run --release $R --sha "$C3" --untagged
check "explicit: missing tag with --untagged is allowed (pre-first-release)" bash -c "[ $RC -eq 0 ] && grep -q 'warning' <<<'$ERR'"
reset; tag_ann $R "$C2"; run --release $R --sha "$C3" --untagged
check "explicit: a tag that peels to another commit is refused even with --untagged" bash -c "[ $RC -ne 0 ] && grep -q 'peels to' <<<'$ERR'"
reset; tag_ann $R "$F1"; run --release $R --sha "$F1"
check "explicit: a commit of a merged feature branch (not first-parent) is refused" bash -c "[ $RC -ne 0 ] && grep -q 'first-parent' <<<'$ERR'"
reset; run --release $R --sha "$ELSE" --untagged
check "explicit: a sha that is not in teknoir-cloud is refused" bash -c "[ $RC -ne 0 ] && grep -q 'first-parent' <<<'$ERR'"
reset; tag_ann $R "$M1"; run --release $R --sha "$M1"
check "explicit: a first-parent merge commit is accepted" test "$RC" -eq 0
reset; tag_ann $R "$C1"; run --release $R --sha "$C1"
check "explicit: a sha without the release: key in values.yaml is refused" bash -c "[ $RC -ne 0 ] && grep -q 'release helper' <<<'$ERR'"
reset; tag_ann $R "$C2"; run --release $R --sha "$C2"
check "explicit: the first sha with the release: key is accepted" test "$RC" -eq 0

# 5. live root ------------------------------------------------------------------------------------------
LIVE_R=staging-20261001.3
live() { printf '%s\t%s' "$1" "$2" >"$FIX/kubectl-out"; }
reset; live $LIVE_R "$C3"; run --context vpro
check "live annotation resolves the release (no GitHub, no verification needed)" bash -c "[ $RC -eq 0 ] && grep -q 'teknoir.org/release: \"$LIVE_R\"' <<<'$OUT' && grep -q 'targetRevision: \"$C3\"' <<<'$OUT'"
reset; live $LIVE_R teknoir-cloud; run --context vpro
check "live annotation with a branch targetRevision is refused" test "$RC" -ne 0
reset; live $LIVE_R "$C3"; run --context vpro --apply
check "--apply of the live release is a no-op: nothing applied" bash -c "[ $RC -eq 0 ] && grep -q 'nothing to apply' <<<'$ERR' && [ ! -e '$FIX/applied' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
reset; live $LIVE_R "$C3"; run --context vpro --apply --release $LIVE_R --sha "$C3"
check "--apply of an explicit release equal to the live one is a no-op" bash -c "[ $RC -eq 0 ] && [ ! -e '$FIX/applied' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
reset; live $LIVE_R "$C3"; run --context vpro --check
check "--check prints '<release> <sha>' and applies nothing" bash -c "[ $RC -eq 0 ] && [ '$OUT' = '$LIVE_R $C3' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
reset; tag_ann $R "$C3"; live $LIVE_R "$C2"; run --context vpro --apply --release $R --sha "$C3"
check "--apply refuses to move a live release" bash -c "[ $RC -ne 0 ] && [ ! -e '$FIX/applied' ]"
reset; tag_ann $R "$C3"; live $LIVE_R "$C2"; run --context vpro --release $R --sha "$C3"
check "print mode may show another release than the live one (with a note)" bash -c "[ $RC -eq 0 ] && grep -q 'note: live root is on' <<<'$ERR'"

# 6. pre-cutover branch-following live root: no write ------------------------------------------------------
gh_setup() { # releases on GitHub (tags in the fixture repo), fresh cluster unless the test sets kubectl-out
	reset
	cat >"$FIX/releases.tsv" <<EOT
staging-20261016.9	false	false	staging-20261016.9
staging-20261017.2	false	false	staging-20261017.2
staging-20261017.10	false	false	staging-20261017.10
staging-20261018.1	true	false	staging-20261018.1 (prerelease)
staging-20261019.1	false	true	draft
v1.2.3	false	false	not a staging release
EOT
	tag_ann staging-20261017.10 "$C3"; tag_lw staging-20261017.2 "$C2"
	printf 'the server doesn'"'"'t have a resource type "application"\n' >"$FIX/kubectl-err"; echo 1 >"$FIX/kubectl-rc"
}
branch_following() { rm -f "$FIX/kubectl-err" "$FIX/kubectl-rc"; printf '\tteknoir-cloud' >"$FIX/kubectl-out"; }
gh_setup; branch_following; run --context vpro
check "print mode with a branch-following root resolves from GitHub" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT'"
gh_setup; branch_following; run --context vpro --apply
check "--apply (resolved) against a branch-following root is refused, points to the cutover" \
	bash -c "[ $RC -ne 0 ] && grep -q 'scripts/staging-release --bootstrap' <<<'$ERR' && [ ! -e '$FIX/applied' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
gh_setup; branch_following; run --context vpro --apply --release staging-20261017.10 --sha "$C3"
check "--apply (explicit, tagged) against a branch-following root is refused" \
	bash -c "[ $RC -ne 0 ] && grep -q 'scripts/staging-release --bootstrap' <<<'$ERR' && [ ! -e '$FIX/applied' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"
gh_setup; branch_following; run --context vpro --apply --release staging-20261017.10 --sha "$C3" --untagged
check "--apply (explicit, --untagged) against a branch-following root is refused" bash -c "[ $RC -ne 0 ] && [ ! -e '$FIX/applied' ]"
gh_setup; branch_following; run --context vpro --check
check "--check against a branch-following root is refused" bash -c "[ $RC -ne 0 ] && grep -q 'staging-release --bootstrap' <<<'$ERR' && [ -z '$OUT' ]"

# 7. GitHub path ---------------------------------------------------------------------------------------------
gh_setup; run --context vpro
check "newest verified release by number (.10 beats .2; prerelease, draft skipped), peeled sha" \
	bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT' && grep -q '$C3' <<<'$OUT' && ! grep -q '$(g rev-parse staging-20261017.10)' <<<'$OUT'"
gh_setup; tags_reset; tag_lw staging-20261017.10 "$C3"; run --context vpro
check "lightweight tag falls back to the plain sha" bash -c "[ $RC -eq 0 ] && grep -q '$C3' <<<'$OUT'"
skip_case() { # <name> <title> <body>: .10 carries the marker, .2 is the expected result
	gh_setup
	sed -i "s/^staging-20261017.10\tfalse\tfalse\t.*/staging-20261017.10\tfalse\tfalse\t$2/" "$FIX/releases.tsv"
	printf '%s\n' "$3" >"$FIX/body-staging-20261017.10"
	run --context vpro
}
skip_case x '[rolled back] staging-20261017.10' 'plain body'
check "title prefix [rolled back] is skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.2' <<<'$OUT' && ! grep -q 'staging-20261017.10' <<<'$OUT'"
skip_case x 'staging-20261017.10' $'notes\nRolled-Back: true\nmore'
check "body trailer 'Rolled-Back: true' is skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.2' <<<'$OUT'"
skip_case x '[not applied] staging-20261017.10' 'plain body'
check "title prefix [not applied] is skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.2' <<<'$OUT'"
skip_case x 'staging-20261017.10' $'Not-Applied: true'
check "body trailer 'Not-Applied: true' is skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.2' <<<'$OUT'"
skip_case x 'staging-20261017.10 [rolled-back]' 'plain body'
check "hyphen form in the title is not the marker (release is used)" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT'"
skip_case x 'staging-20261017.10 [rolled back]' 'plain body'
check "marker at the end of the title is not the prefix marker (release is used)" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT'"
skip_case x 'staging-20261017.10' $'Pending:\n- note that .1 was rolled back\n- Rolled back the keycloak bump in review'
check "a body that only mentions 'rolled back' in passing is not skipped" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT'"
skip_case x 'staging-20261017.10' $'rolled-back: true\nRolled-Back: false\n Rolled-Back: true'
check "near-miss trailers (case, value, indentation) are not markers" bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT'"
gh_setup; cat >"$FIX/releases.tsv" <<EOT
staging-20261017.08	false	false	zero padded
staging-20261017.9	false	false	staging-20261017.9
staging-20261017.10	false	false	staging-20261017.10
EOT
tags_reset; tag_lw staging-20261017.9 "$C2"; tag_lw staging-20261017.10 "$C3"; run --context vpro
check "a zero-padded tag in the list is ignored, no octal abort; .10 beats .9" \
	bash -c "[ $RC -eq 0 ] && grep -q 'staging-20261017.10' <<<'$OUT' && ! grep -qi octal <<<'$ERR'"
gh_setup; tags_reset; run --context vpro
check "tag missing on the remote is an error" bash -c "[ $RC -ne 0 ] && grep -q 'no tag' <<<'$ERR'"
gh_setup; tags_reset; tag_ann staging-20261017.10 "$F1"; run --context vpro
check "tag on a feature-branch commit (not first-parent) is an error" bash -c "[ $RC -ne 0 ] && grep -q 'first-parent' <<<'$ERR'"
gh_setup; tags_reset; tag_ann staging-20261017.10 "$C1"; run --context vpro
check "tag on a pre-helper commit is an error" bash -c "[ $RC -ne 0 ] && grep -q 'release helper' <<<'$ERR'"
gh_setup; : >"$FIX/releases.tsv"; run --context vpro
check "no releases is an error (never newest tag)" bash -c "[ $RC -ne 0 ] && grep -q 'no verified' <<<'$ERR'"
gh_setup; run --context vpro --apply
check "GitHub-resolved release on a fresh cluster is applied via kubectl apply -f -" \
	bash -c "[ $RC -eq 0 ] && grep -q '$C3' '$FIX/applied' && grep -q -- '--context vpro apply -f -' '$FIX/kubectl.log'"
gh_setup; printf 'Unable to connect to the server\n' >"$FIX/kubectl-err"; run --context vpro
check "an unreachable cluster is an error, not a silent GitHub fallback" test "$RC" -ne 0
gh_setup; run --context vpro --check
check "--check on a fresh cluster prints '<release> <sha>' and applies nothing" bash -c "[ $RC -eq 0 ] && [ '$OUT' = 'staging-20261017.10 $C3' ] && ! grep -q ' apply ' '$FIX/kubectl.log'"

# 8. staging-bootstrap.sh resolves and validates the release before it changes anything -------------------
TREE="$TMP/tree"; mkdir -p "$TREE/scripts"
cp "$ROOT/scripts/staging-bootstrap.sh" "$ROOT/scripts/staging-root.sh" "$TREE/scripts/"; cp "$TMPL" "$TREE/"
cat >"$TREE/scripts/deploy-argo.sh" <<'F'
#!/usr/bin/env bash
echo "deploy-argo.sh (stub)" >>"$FIX/kubectl.log"
F
chmod +x "$TREE"/scripts/*.sh
boot() { PATH="$TMP/bin:$PATH" GITHUB_PAT=dummy-not-a-token "$TREE/scripts/staging-bootstrap.sh" "$@" >"$TMP/out" 2>"$TMP/err"; RC=$?; OUT=$(cat "$TMP/out"); ERR=$(tr -d "'" <"$TMP/err"); }
# shellcheck disable=SC2317
only_reads() { ! grep -vE ' get application ' "$FIX/kubectl.log" | grep -q .; }
gh_setup; : >"$FIX/releases.tsv"; boot --context vpro
check "bootstrap: no release resolvable aborts before any cluster change" bash -c "[ $RC -ne 0 ] && grep -q 'nothing was changed' <<<'$ERR'" && check "bootstrap: only a read happened (no namespace, Secret, deploy-argo)" only_reads
gh_setup; branch_following; boot --context vpro
check "bootstrap: pre-cutover branch-following root aborts before any cluster change" bash -c "[ $RC -ne 0 ] && grep -q 'staging-release --bootstrap' <<<'$ERR'" && check "bootstrap: only a read happened (branch-following)" only_reads
gh_setup; boot --context vpro --release staging-20261017.10 --sha "$C1"
check "bootstrap: an unverifiable explicit release aborts before any cluster change" bash -c "[ $RC -ne 0 ]" && check "bootstrap: only a read happened (explicit)" only_reads
gh_setup; boot --context r415
check "bootstrap refuses r415" bash -c "[ $RC -eq 2 ] && [ ! -s '$FIX/kubectl.log' ]"
gh_setup; boot --context vpro
check "bootstrap: fresh cluster succeeds" test "$RC" -eq 0
check "bootstrap: the release read comes first, the root is applied last, with the checked release" bash -c "
	[ \"\$(head -1 '$FIX/kubectl.log' | grep -c ' get application ')\" = 1 ] &&
	[ \"\$(tail -1 '$FIX/kubectl.log' | grep -c ' apply -f -$')\" = 1 ] &&
	grep -q 'deploy-argo.sh' '$FIX/kubectl.log' && grep -q 'targetRevision: \"$C3\"' '$FIX/applied' && grep -q 'staging-20261017.10' '$FIX/applied'"
gh_setup; live staging-20261017.10 "$C3"; rm -f "$FIX/kubectl-err" "$FIX/kubectl-rc"; boot --context vpro
check "bootstrap rerun on a cluster already at the release does not touch the root" bash -c "[ $RC -eq 0 ] && [ ! -e '$FIX/applied' ] && grep -q 'nothing to apply' <<<'$ERR'"

# 9. optional: re-apply under the guard on a throwaway cluster -------------------------------------------------
if [ -n "${K3D_CONTEXT:-}" ]; then
	case $K3D_CONTEXT in vpro | r415 | *eks* | *online* | *prod*) bad "K3D_CONTEXT must be a throwaway cluster"; K3D_CONTEXT='' ;; esac
fi
if [ -n "${K3D_CONTEXT:-}" ]; then
	KC() { kubectl --context "$K3D_CONTEXT" "$@"; }
	NS="wp2-root-guard-$$" POL="wp2-root-guard-$$"
	k3d_cleanup() {
		KC delete validatingadmissionpolicybinding "$POL-binding" --ignore-not-found >/dev/null 2>&1
		KC delete validatingadmissionpolicy "$POL" --ignore-not-found >/dev/null 2>&1
		KC delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
	}
	trap 'k3d_cleanup; cleanup' EXIT
	if ! KC get crd applications.argoproj.io appprojects.argoproj.io >/dev/null 2>&1; then
		bad "k3d: Application/AppProject CRDs missing on $K3D_CONTEXT"
	elif [ ! -d "$GUARD_CHART" ] || ! command -v helm >/dev/null; then
		bad "k3d: need helm and the release-guard chart ($GUARD_CHART; set RELEASE_GUARD_CHART)"
	else
		reset; tag_ann staging-20261017.1 "$C3"; run --release staging-20261017.1 --sha "$C3"
		cp "$TMP/out" "$TMP/root.yaml"
		# the Application only, in the scratch namespace; plus a variant with the old template's `sources: []`
		python3 -I - "$TMP/root.yaml" "$NS" "$TMP/app.yaml" "$TMP/app-sources.yaml" <<'PY'
import sys, yaml
src, ns, out, out_sources = sys.argv[1:5]
app = [d for d in yaml.safe_load_all(open(src)) if d and d["kind"] == "Application"][0]
app["metadata"]["namespace"] = ns
yaml.safe_dump(app, open(out, "w"), sort_keys=False)
app["spec"]["sources"] = []
yaml.safe_dump(app, open(out_sources, "w"), sort_keys=False)
PY
		KC create ns "$NS" >/dev/null 2>&1 || bad "k3d: cannot create scratch namespace $NS"
		KC apply --dry-run=server -f "$TMP/app.yaml" >"$TMP/dry.out" 2>&1 && ok "k3d: server-side dry-run of the rendered root" || { bad "k3d: server-side dry-run"; cat "$TMP/dry.out"; }
		KC apply -f "$TMP/app.yaml" >"$TMP/k3d1.out" 2>&1 && ok "k3d: root applied into scratch namespace $NS" || bad "k3d: first apply: $(cat "$TMP/k3d1.out")"
		gen=$(KC -n "$NS" get application app-of-apps -o jsonpath='{.metadata.generation}')
		# the guard policy of the chart, renamed, bound to the scratch namespace only
		helm template guard "$GUARD_CHART" --set namespace="$NS" --set guard.mode=Deny >"$TMP/guard.yaml"
		python3 -I - "$TMP/guard.yaml" "$POL" "$TMP/guard-scratch.yaml" <<'PY'
import sys, yaml
src, pol, out = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(src)) if d and d["kind"] in ("ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding")]
assert len(docs) == 2, [d["kind"] for d in docs]
for d in docs:
    if d["kind"] == "ValidatingAdmissionPolicy":
        d["metadata"]["name"] = pol
    else:
        d["metadata"]["name"] = pol + "-binding"
        d["spec"]["policyName"] = pol
yaml.safe_dump_all(docs, open(out, "w"), sort_keys=False)
PY
		KC apply -f "$TMP/guard-scratch.yaml" >/dev/null 2>&1 && ok "k3d: release-guard policy bound to $NS (Deny)" || bad "k3d: binding the guard"
		# wait until the guard is enforced: a spec change by this user must be denied
		sed "s/$C3/$ELSE/g" "$TMP/app.yaml" >"$TMP/app-moved.yaml"
		denied=''
		for _ in $(seq 1 30); do
			if KC apply --dry-run=server -f "$TMP/app-moved.yaml" >"$TMP/moved.out" 2>&1; then sleep 1; else denied=1; break; fi
		done
		check "k3d: the guard is active (a hand change of the release is denied)" bash -c "[ -n '$denied' ] && grep -q 'may not UPDATE' '$TMP/moved.out'"
		KC apply -f "$TMP/app.yaml" >"$TMP/reapply.out" 2>&1
		check "k3d: re-applying the same rendered root under the guard is accepted and unchanged" \
			bash -c "grep -q 'unchanged' '$TMP/reapply.out' && ! grep -qi denied '$TMP/reapply.out'"
		check "k3d: the re-apply did not bump the generation" test "$(KC -n "$NS" get application app-of-apps -o jsonpath='{.metadata.generation}')" = "$gen"
		KC apply --dry-run=server -f "$TMP/app-sources.yaml" >"$TMP/src.out" 2>&1
		check "k3d: control: the old template's 'sources: []' IS a spec change and the guard denies it" bash -c "grep -q 'may not UPDATE' '$TMP/src.out'"
	fi
fi

[ "$fail" -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "$fail"
