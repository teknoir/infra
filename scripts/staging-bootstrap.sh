#!/usr/bin/env bash
# staging-bootstrap.sh: bring up staging (teknoir-cloud) on a fresh single-node k3s server.
#
#   scripts/staging-bootstrap.sh --context vpro|r415 [--host ...] [--release TAG --sha SHA [--untagged]] [--no-ci]
#   scripts/staging-bootstrap.sh --context vpro|r415 [--host ...] --pre-release BRANCH [--no-ci]
#   scripts/staging-bootstrap.sh --context r415 [--host ...] --kargo [--sha SHA] [--no-ci]
#
# --host defaults to anders@192.168.2.19 on vpro and anders@192.168.2.166 on r415; on r415 K3S_MANIFESTS
# defaults to /opt/k3s/server/manifests (r415's k3s data-dir) and is passed to scripts/deploy-argo.sh.
# --pre-release BRANCH follows a platform-applications-gitops branch instead of a release, for a NEW staging
# cluster before its first release (the cutover is scripts/staging-release --bootstrap). It excludes
# --release/--sha/--untagged. --no-ci skips the teknoir-ci namespace and its github-ci Secret.
#
# --kargo is the root of a cluster after the Kargo cut-over (CI v4 P5.2): step 3 uses scripts/kargo-root.sh and
# clusters/r415/root.yaml instead of scripts/staging-root.sh and the release template, so the root starts at a
# verified gitops commit (newest stamped verified/* tag, or --sha) and Kargo moves it from then on. It needs
# --context r415, excludes --release, --untagged and --pre-release (--sha names the commit), and, like the rest of
# this script, is for a FRESH cluster: against a live Kargo-moved root kargo-root.sh refuses, and moving a live root
# is clusters/r415/BREAK-GLASS.md (Anders only). Everything else, including the order of the steps, is unchanged.
# A rerun after the cut-over stays a no-op: with no --sha, a live root carrying kargo.akuity.io/authorized-stage
# supplies its own targetRevision (kargo-root.sh --check prints "<sha> live"), and --apply finds the root already there.
#
# The release of the root app-of-apps is resolved and verified FIRST (scripts/staging-root.sh --check, or
# scripts/kargo-root.sh --check with --kargo; both change nothing); a failure there (no verified release, no gh
# auth, a pre-cutover branch-following root) stops the script before any namespace, Secret or ArgoCD change.
#
# Everything random is generated in-cluster by GitOps (platform-secrets), and Keycloak is
# configured by GitOps (charts/auth realm file), so this script only does what GitOps
# cannot:
#   1. pre-create the namespaces that platform-secrets writes into on its first sync
#      (labels as the charts set them; ArgoCD adopts them);
#   2. the external-credential Secrets, from stdin / environment, never printed:
#        teknoir-system/ghcr-token, teknoir-auth/ghcr-token  ghcr pull (GITHUB_PAT, default `gh auth token`)
#        teknoir-ci/github-ci                                CI token  (same PAT: repo + write:packages)
#        cert-manager/godaddy-api-key-prod                   GODADDY_API_KEY + GODADDY_API_SECRET (DNS-01)
#        teknoir-system/backstage-github-app-secret          BACKSTAGE_GITHUB_APP_FILE (+ BACKSTAGE_GCP_SA_FILE)
#        teknoir-system/teknoirbot-model-keys                TEKNOIRBOT_MODEL_KEY: the Anthropic API key for the bots
#                                                            of teamspace teknoir-demo (data key teknoir-demo)
#      An existing Secret is left alone unless FORCE=1;
#   3. ArgoCD (scripts/deploy-argo.sh) and the root app-of-apps, rendered for a RELEASE by scripts/staging-root.sh
#      (optional --release staging-YYYYMMDD.N --sha <40-hex> to name one explicitly; --untagged if that tag does not
#      exist yet, i.e. before the first release). Against a live branch-following root it refuses: that is the cutover,
#      scripts/staging-release --bootstrap in platform-applications-gitops. --pre-release BRANCH renders the
#      pre-release template instead, so a new cluster can follow a gitops branch before its first release.
#      --kargo renders clusters/r415/root.yaml with scripts/kargo-root.sh instead (a verified gitops commit, Kargo
#      moves it afterwards; see the top of this header).
# Idempotent: rerun it after providing a missing credential.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT='' HOST='' ROOT_ARGS=() PRERELEASE='' NO_CI='' EXPLICIT='' KARGO='' RELEASE_ARG='' SHA_ARG='' UNTAGGED=''
while [ $# -gt 0 ]; do
	case $1 in
	--context) CONTEXT=$2; shift ;;
	--host) HOST=$2; shift ;;
	--release) RELEASE_ARG=$2; ROOT_ARGS+=("$1" "$2"); EXPLICIT=1; shift ;;
	--sha) SHA_ARG=$2; ROOT_ARGS+=("$1" "$2"); EXPLICIT=1; shift ;;
	--untagged) ROOT_ARGS+=("$1"); UNTAGGED=1; EXPLICIT=1 ;;
	--pre-release) PRERELEASE=$2; ROOT_ARGS+=("--pre-release" "$2"); shift ;;
	--kargo) KARGO=1 ;;
	--no-ci) NO_CI=1 ;;
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$CONTEXT" ] || { echo "--context is required (never the current context)" >&2; exit 2; }
case $CONTEXT in *eks*|*online*|*prod*) echo "refusing a production-looking or retired context: $CONTEXT" >&2; exit 2 ;; esac
case $CONTEXT in vpro|r415) ;; *) echo "context must be vpro or r415 (staging), got: $CONTEXT" >&2; exit 2 ;; esac
[ -z "$PRERELEASE" ] || [ -z "$EXPLICIT" ] || { echo "--pre-release excludes --release, --sha and --untagged" >&2; exit 2; }
if [ -n "$KARGO" ]; then
	[ -z "$PRERELEASE$RELEASE_ARG$UNTAGGED" ] || { echo "--kargo excludes --release, --untagged and --pre-release (--sha names the commit)" >&2; exit 2; }
	[ "$CONTEXT" = r415 ] || { echo "--kargo is the r415 root after the Kargo cut-over; context must be r415" >&2; exit 2; }
	# scripts/kargo-root.sh takes --sha, not --release/--untagged
	ROOT_ARGS=()
	[ -z "$SHA_ARG" ] || ROOT_ARGS=(--sha "$SHA_ARG")
fi
if [ -z "$HOST" ]; then
	case $CONTEXT in
	r415) HOST=anders@192.168.2.166 ;;
	*) HOST=anders@192.168.2.19 ;;
	esac
fi
if [ "$CONTEXT" = r415 ] && [ -z "${K3S_MANIFESTS:-}" ]; then K3S_MANIFESTS=/opt/k3s/server/manifests; fi
k() { kubectl --context "$CONTEXT" "$@"; }
log() { printf 'staging-bootstrap: %s\n' "$*"; }
warn() { printf 'staging-bootstrap: WARNING: %s\n' "$*" >&2; }

has_secret() { [ -n "$(k -n "$1" get secret "$2" --ignore-not-found -o name)" ] && [ -z "${FORCE:-}" ]; }
apply_stdin() { k apply --server-side --field-manager=staging-bootstrap "$@" -f - >/dev/null; } # [extra apply flags]

# 0. commit or release of the root, before anything changes ------------------------------
# Print/check mode is read-only (kubectl get, gh, git ls-remote/fetch). It fails on no verified release (or no
# stamped verified/* tag with --kargo), no gh auth, an unverifiable explicit release or a pre-cutover
# branch-following root, all before step 1.
if [ -n "$KARGO" ]; then
	if ! root_commit=$(scripts/kargo-root.sh --context "$CONTEXT" --check ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"}); then
		echo "staging-bootstrap: the root commit cannot be resolved or applied; nothing was changed" >&2
		exit 1
	fi
	read -r ROOT_SHA ROOT_RELEASE <<<"$root_commit" # kargo-root.sh --check prints "<sha> <tag>"
	log "root verified commit: $ROOT_RELEASE ($ROOT_SHA)"
else
	if ! root_release=$(scripts/staging-root.sh --context "$CONTEXT" --check ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"}); then
		echo "staging-bootstrap: the root release cannot be resolved or applied; nothing was changed" >&2
		exit 1
	fi
	read -r ROOT_RELEASE ROOT_SHA <<<"$root_release"
	if [ -n "$PRERELEASE" ]; then
		log "root follows branch $PRERELEASE (pre-release), commit $ROOT_SHA"
	else
		log "root release: $ROOT_RELEASE ($ROOT_SHA)"
	fi
fi

# 1. namespaces ------------------------------------------------------------------------
ns() { # <name> <istio-injection>
	k create namespace "$1" --dry-run=client -o yaml |
		k label --local -f - istio-injection="$2" -o yaml | apply_stdin
}
ns teknoir-system enabled
ns teknoir-auth enabled
ns cert-manager disabled
if [ -z "$NO_CI" ]; then
	ns teknoir-ci disabled
else
	log "--no-ci: namespace teknoir-ci and Secret github-ci skipped"
fi
ns stunner-system disabled
log "namespaces ready"

# 2. external credentials --------------------------------------------------------------
pat=${GITHUB_PAT:-}
if [ -z "$pat" ] && command -v gh >/dev/null; then pat=$(gh auth token 2>/dev/null || true); fi
if [ -n "$pat" ]; then
	user=${GITHUB_USER:-tekn0ir}
	auth=$(printf '%s:%s' "$user" "$pat" | base64 | tr -d '\n')
	for n in teknoir-system teknoir-auth; do
		if has_secret "$n" ghcr-token; then log "$n/ghcr-token exists"; continue; fi
		printf '{"auths":{"ghcr.io":{"username":"%s","password":"%s","auth":"%s"}}}' "$user" "$pat" "$auth" |
			k -n "$n" create secret generic ghcr-token --type=kubernetes.io/dockerconfigjson \
				--from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml | apply_stdin
		log "$n/ghcr-token created"
	done
	if [ -z "$NO_CI" ]; then
		if has_secret teknoir-ci github-ci; then log "teknoir-ci/github-ci exists"; else
			printf '%s' "$pat" | k -n teknoir-ci create secret generic github-ci --from-literal=username="$user" \
				--from-file=token=/dev/stdin --dry-run=client -o yaml | apply_stdin
			log "teknoir-ci/github-ci created"
		fi
	fi
	unset pat auth
else
	warn "no GitHub token (GITHUB_PAT or gh auth): ghcr-token and github-ci not created"
fi

if has_secret cert-manager godaddy-api-key-prod; then log "cert-manager/godaddy-api-key-prod exists"
elif [ -n "${GODADDY_API_KEY:-}" ] && [ -n "${GODADDY_API_SECRET:-}" ]; then
	printf '%s:%s' "$GODADDY_API_KEY" "$GODADDY_API_SECRET" |
		k -n cert-manager create secret generic godaddy-api-key-prod --from-file=token=/dev/stdin \
			--dry-run=client -o yaml | apply_stdin
	log "cert-manager/godaddy-api-key-prod created"
else
	warn "GODADDY_API_KEY/GODADDY_API_SECRET not set: no Let's Encrypt certificates until it exists"
fi

if has_secret teknoir-system backstage-github-app-secret; then log "teknoir-system/backstage-github-app-secret exists"
elif [ -n "${BACKSTAGE_GITHUB_APP_FILE:-}" ] && [ -r "$BACKSTAGE_GITHUB_APP_FILE" ]; then
	d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; chmod 700 "$d"
	# backend-auth: a random service-to-service secret (Backstage backend.auth.keys).
	printf 'secret: %s\n' "$(head -c 36 /dev/urandom | base64 | tr -d '\n/+=')" >"$d/backend-auth-backstage-secrets.yaml"
	if [ -n "${BACKSTAGE_GCP_SA_FILE:-}" ]; then cp "$BACKSTAGE_GCP_SA_FILE" "$d/admin-credentials.json"; else echo '{}' >"$d/admin-credentials.json"; fi
	k -n teknoir-system create secret generic backstage-github-app-secret \
		--from-file=github-app-backstage-teknoir-credentials.yaml="$BACKSTAGE_GITHUB_APP_FILE" \
		--from-file=backend-auth-backstage-secrets.yaml="$d/backend-auth-backstage-secrets.yaml" \
		--from-file=admin-credentials.json="$d/admin-credentials.json" --dry-run=client -o yaml | apply_stdin
	log "teknoir-system/backstage-github-app-secret created"
else
	warn "BACKSTAGE_GITHUB_APP_FILE not set: backstage-api will not start until the Secret exists"
fi

# TeknoirBot's model proxy in backstage-api reads one data key per teamspace from this Secret (60 s cache); staging
# has teknoir-demo only. The check is for the teknoir-demo entry, not the Secret: a missing or empty entry is added to
# an existing Secret. FORCE=1 replaces the teknoir-demo entry; --force-conflicts takes it over from a hand edit
# (kubectl patch, or kubectl create without --save-config), which a plain apply refuses as a conflict. Another
# teamspace's entry survives FORCE=1 only if it was added with `kubectl patch` or server-side apply under its own field
# manager (e.g. --field-manager=teknoirbot-<namespace>). Never use --field-manager=staging-bootstrap for it (each
# apply drops what the other sent), a client-side `kubectl apply` or `kubectl create --save-config` (kubectl's
# server-side apply takes those fields over and drops them).
if [ -n "$(k -n teknoir-system get secret teknoirbot-model-keys --ignore-not-found -o jsonpath='{.data.teknoir-demo}')" ] &&
	[ -z "${FORCE:-}" ]; then log "teknoir-system/teknoirbot-model-keys exists (entry teknoir-demo)"
elif [ -n "${TEKNOIRBOT_MODEL_KEY:-}" ]; then
	printf '%s' "$TEKNOIRBOT_MODEL_KEY" |
		k -n teknoir-system create secret generic teknoirbot-model-keys --from-file=teknoir-demo=/dev/stdin \
			--dry-run=client -o yaml | apply_stdin ${FORCE:+--force-conflicts}
	log "teknoir-system/teknoirbot-model-keys created"
else
	warn "TEKNOIRBOT_MODEL_KEY not set: TeknoirBot's model proxy answers 503 (no model key) until the Secret exists"
fi

# 3. ArgoCD + root app-of-apps ---------------------------------------------------------
if [ -n "${K3S_MANIFESTS:-}" ]; then
	STAGING_HOST=$HOST K3S_MANIFESTS=$K3S_MANIFESTS scripts/deploy-argo.sh
else
	STAGING_HOST=$HOST scripts/deploy-argo.sh
fi
log "waiting for the ArgoCD CRDs"
until k get crd applications.argoproj.io appprojects.argoproj.io >/dev/null 2>&1; do sleep 5; done
# Staging follows a released commit, not the branch: staging-root.sh fills teknoir-cloud-app-of-apps.yaml.tmpl with the
# release resolved and verified in step 0 (see plans/staging-releases.md). A live root already at it is left alone.
# --pre-release does the same with the prerelease template, for a new cluster before its first release.
# --kargo fills clusters/r415/root.yaml with the verified commit resolved in step 0 (kargo-root.sh): Kargo then moves
# targetRevision; against a live Kargo-moved root kargo-root.sh refuses (break-glass is Anders').
if [ -n "$PRERELEASE" ]; then
	scripts/staging-root.sh --context "$CONTEXT" --apply --pre-release "$PRERELEASE"
	log "app-of-apps applied; ArgoCD now installs the platform from branch $PRERELEASE (pre-release)"
elif [ -n "$KARGO" ]; then
	scripts/kargo-root.sh --context "$CONTEXT" --apply --sha "$ROOT_SHA"
	log "app-of-apps applied at verified commit $ROOT_SHA ($ROOT_RELEASE); Kargo owns targetRevision from now on"
else
	scripts/staging-root.sh --context "$CONTEXT" --apply --release "$ROOT_RELEASE" --sha "$ROOT_SHA" ${UNTAGGED:+--untagged}
	log "app-of-apps applied; ArgoCD now installs the platform from the released platform-applications-gitops commit"
fi
