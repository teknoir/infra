#!/usr/bin/env bash
# staging-bootstrap.sh: bring up staging (teknoir-cloud) on a fresh single-node k3s server.
#
#   scripts/staging-bootstrap.sh --context vpro [--host anders@192.168.2.19] [--release TAG --sha SHA]
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
#      An existing Secret is left alone unless FORCE=1;
#   3. ArgoCD (scripts/deploy-argo.sh) and the root app-of-apps, rendered for a RELEASE by scripts/staging-root.sh
#      (optional --release staging-YYYYMMDD.N --sha <40-hex> to name one explicitly, e.g. before the first release).
# Idempotent: rerun it after providing a missing credential.
set -euo pipefail
cd "$(dirname "$0")/.."

CONTEXT='' HOST=anders@192.168.2.19 ROOT_ARGS=()
while [ $# -gt 0 ]; do
	case $1 in
	--context) CONTEXT=$2; shift ;;
	--host) HOST=$2; shift ;;
	--release | --sha) ROOT_ARGS+=("$1" "$2"); shift ;; # explicit release for scripts/staging-root.sh
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$CONTEXT" ] || { echo "--context is required (never the current context)" >&2; exit 2; }
case $CONTEXT in *eks*|*online*|*prod*) echo "refusing a production-looking context: $CONTEXT" >&2; exit 2 ;; esac
k() { kubectl --context "$CONTEXT" "$@"; }
log() { printf 'staging-bootstrap: %s\n' "$*"; }
warn() { printf 'staging-bootstrap: WARNING: %s\n' "$*" >&2; }

has_secret() { [ -n "$(k -n "$1" get secret "$2" --ignore-not-found -o name)" ] && [ -z "${FORCE:-}" ]; }
apply_stdin() { k apply --server-side --field-manager=staging-bootstrap -f - >/dev/null; }

# 1. namespaces ------------------------------------------------------------------------
ns() { # <name> <istio-injection>
	k create namespace "$1" --dry-run=client -o yaml |
		k label --local -f - istio-injection="$2" -o yaml | apply_stdin
}
ns teknoir-system enabled
ns teknoir-auth enabled
ns cert-manager disabled
ns teknoir-ci disabled
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
	if has_secret teknoir-ci github-ci; then log "teknoir-ci/github-ci exists"; else
		printf '%s' "$pat" | k -n teknoir-ci create secret generic github-ci --from-literal=username="$user" \
			--from-file=token=/dev/stdin --dry-run=client -o yaml | apply_stdin
		log "teknoir-ci/github-ci created"
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

# 3. ArgoCD + root app-of-apps ---------------------------------------------------------
STAGING_HOST=$HOST scripts/deploy-argo.sh
log "waiting for the ArgoCD CRDs"
until k get crd applications.argoproj.io appprojects.argoproj.io >/dev/null 2>&1; do sleep 5; done
# Staging follows a released commit, not the branch: staging-root.sh fills teknoir-cloud-app-of-apps.yaml.tmpl
# from the live root annotation, else the newest verified GitHub Release (see plans/staging-releases.md).
scripts/staging-root.sh --context "$CONTEXT" --apply ${ROOT_ARGS[@]+"${ROOT_ARGS[@]}"}
log "app-of-apps applied; ArgoCD now installs the platform from the released platform-applications-gitops commit"
