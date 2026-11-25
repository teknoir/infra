#!/usr/bin/env bash
# staging-bootstrap.sh: bring up staging (teknoir-cloud, r415) on a fresh single-node k3s server.
#
#   scripts/staging-bootstrap.sh --context r415 [--host ...] [--sha SHA] [--no-ci]
#
# The root is clusters/r415/root.yaml, rendered by scripts/kargo-root.sh: the root starts at a verified gitops
# commit (newest stamped verified/* tag, or --sha) and Kargo moves it from then on. Like the rest of this script it
# is for a FRESH cluster: against a live Kargo-moved root kargo-root.sh refuses, and moving a live root is
# clusters/r415/BREAK-GLASS.md (Anders only). A rerun stays a no-op: with no --sha, a live root carrying
# kargo.akuity.io/authorized-stage supplies its own targetRevision (kargo-root.sh --check prints "<sha> live"), and
# --apply finds the root already there. --kargo is accepted for compatibility; the Kargo root is the only root
# since CI v4 P7.1. The release-based root (scripts/staging-root.sh, the *.tmpl templates) was retired in CI v4
# P7.1 (2026-11-25).
#
# --host defaults to anders@192.168.2.166; K3S_MANIFESTS defaults to /opt/k3s/server/manifests (r415's k3s
# data-dir) and is passed to scripts/deploy-argo.sh. --no-ci skips the teknoir-ci namespace and its github-ci
# Secret.
#
# The commit of the root app-of-apps is resolved and verified FIRST (scripts/kargo-root.sh --check, which changes
# nothing); a failure there (no stamped verified/* tag, an unverifiable commit, a live root it may not move) stops
# the script before any namespace, Secret or ArgoCD change.
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
#   3. ArgoCD (scripts/deploy-argo.sh) and the root app-of-apps, clusters/r415/root.yaml rendered by
#      scripts/kargo-root.sh at the verified commit resolved in step 0 (Kargo moves it afterwards; see the top of
#      this header).
# Idempotent: rerun it after providing a missing credential.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT='' HOST='' ROOT_ARGS=() NO_CI='' SHA_ARG=''
while [ $# -gt 0 ]; do
	case $1 in
	--context) CONTEXT=$2; shift ;;
	--host) HOST=$2; shift ;;
	--sha) SHA_ARG=$2; shift ;;
	# accepted for compatibility; the Kargo root is the only root since CI v4 P7.1
	--kargo) ;;
	--release | --untagged | --pre-release)
		echo "$1 was retired in CI v4 P7.1 (the release-based root is gone); use --sha <40-hex> to name the gitops commit" >&2
		exit 2 ;;
	--no-ci) NO_CI=1 ;;
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$CONTEXT" ] || { echo "--context is required (never the current context)" >&2; exit 2; }
case $CONTEXT in *eks*|*online*|*prod*) echo "refusing a production-looking or retired context: $CONTEXT" >&2; exit 2 ;; esac
[ "$CONTEXT" = r415 ] || { echo "context must be r415 (staging since CI v4), got: $CONTEXT" >&2; exit 2; }
ROOT_ARGS=()
[ -z "$SHA_ARG" ] || ROOT_ARGS=(--sha "$SHA_ARG")
if [ -z "$HOST" ]; then HOST=anders@192.168.2.166; fi
if [ -z "${K3S_MANIFESTS:-}" ]; then K3S_MANIFESTS=/opt/k3s/server/manifests; fi
k() { kubectl --context "$CONTEXT" "$@"; }
log() { printf 'staging-bootstrap: %s\n' "$*"; }
warn() { printf 'staging-bootstrap: WARNING: %s\n' "$*" >&2; }

has_secret() { [ -n "$(k -n "$1" get secret "$2" --ignore-not-found -o name)" ] && [ -z "${FORCE:-}" ]; }
apply_stdin() { k apply --server-side --field-manager=staging-bootstrap "$@" -f - >/dev/null; } # [extra apply flags]

# 0. commit of the root, before anything changes ------------------------------------------
# Print/check mode is read-only (kubectl get, git ls-remote/fetch). It fails on no stamped verified/* tag, an
# unverifiable commit or a live root it may not move, all before step 1.
if ! root_commit=$(scripts/kargo-root.sh --context "$CONTEXT" --check ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"}); then
	echo "staging-bootstrap: the root commit cannot be resolved or applied; nothing was changed" >&2
	exit 1
fi
read -r ROOT_SHA ROOT_RELEASE <<<"$root_commit" # kargo-root.sh --check prints "<sha> <tag>"
log "root verified commit: $ROOT_RELEASE ($ROOT_SHA)"

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
# clusters/r415/root.yaml is filled with the verified commit resolved in step 0 (kargo-root.sh): Kargo then moves
# targetRevision; against a live Kargo-moved root kargo-root.sh refuses (break-glass is Anders').
scripts/kargo-root.sh --context "$CONTEXT" --apply --sha "$ROOT_SHA"
log "app-of-apps applied at verified commit $ROOT_SHA ($ROOT_RELEASE); Kargo owns targetRevision from now on"
