#!/usr/bin/env bash
# migrate-argo-untracked-test.sh — unit test (no cluster) of lib/migrate.sh's
# migrate_argo_untracked (r5, HYG-C6): which objects of teknoir-argo.yaml are
# left without an owner after migrate --argo.
#
#   - CRDs with no tracking annotation but a Synced entry in the argo
#     Application's .status.resources are tracked (ArgoCD 3.5 writes no
#     tracking-id on CRDs), so they are not reported;
#   - an object with argo's tracking-id ("argo:..." or "<ns>_argo:...") is
#     tracked; another app's tracking-id is not;
#   - argocd-tls-certs-cm (reconciled by the secrets phase) and any object
#     labelled app.kubernetes.io/managed-by=teknoir-node are converge-owned:
#     listed separately, not warned;
#   - argocd-cm (neither) is reported, and so is an object whose
#     .status.resources entry is OutOfSync;
#   - objects outside the baseline are ignored; only names leave kubectl.
#
# Usage: airgap/test/unit/migrate-argo-untracked-test.sh
# shellcheck disable=SC2016  # the scenario script expands in the child shell
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tkn2-untracked.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/node/bin" "${WORK}/tmp"
ln -s "$(command -v jq)" "${WORK}/node/bin/jq"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
eq() { [[ "$1" == "$2" ]] || { printf '      want: %s\n      got:  %s\n' "$1" "$2"; return 1; }; }

# The argo Application as ArgoCD 3.5.1 reports it on teknoir-local: CRDs as
# Synced resources without a namespace; argocd-rbac-cm drifted (OutOfSync).
cat > "${WORK}/argo.json" <<'EOF'
{"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"name":"argo","namespace":"teknoir-system"},
 "status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"},"resources":[
  {"group":"apiextensions.k8s.io","version":"v1","kind":"CustomResourceDefinition","name":"applications.argoproj.io","status":"Synced"},
  {"group":"apiextensions.k8s.io","version":"v1","kind":"CustomResourceDefinition","name":"appprojects.argoproj.io","status":"Synced"},
  {"group":"apiextensions.k8s.io","version":"v1","kind":"CustomResourceDefinition","name":"applicationsets.argoproj.io","status":"Synced"},
  {"group":"apps","version":"v1","kind":"Deployment","namespace":"teknoir-system","name":"argocd-server","status":"Synced"},
  {"version":"v1","kind":"Secret","namespace":"teknoir-system","name":"argocd-secret","status":"Synced"},
  {"version":"v1","kind":"ConfigMap","namespace":"teknoir-system","name":"argocd-rbac-cm","status":"OutOfSync"}]}}
EOF
# kubectl's jsonpath answer per resource: namespace|name|tracking-id|managed-by
cat > "${WORK}/ConfigMap.v1." <<'EOF'
teknoir-system|argocd-cm||Helm
teknoir-system|argocd-tls-certs-cm||Helm
teknoir-system|argocd-rbac-cm||
teknoir-system|argocd-cmd-params-cm|argo:/ConfigMap:teknoir-system/argocd-cmd-params-cm|
teknoir-system|argocd-ssh-known-hosts-cm|teknoir-system_argo:/ConfigMap:teknoir-system/argocd-ssh-known-hosts-cm|
teknoir-system|argocd-gpg-keys-cm|monitoring:/ConfigMap:teknoir-system/argocd-gpg-keys-cm|
teknoir-system|teknoir-labelled||teknoir-node
teknoir-system|kube-root-ca.crt||
EOF
cat > "${WORK}/CustomResourceDefinition.apiextensions.k8s.io" <<'EOF'
|applications.argoproj.io||
|appprojects.argoproj.io||
|applicationsets.argoproj.io||
|users.teknoir.org||
EOF
cat > "${WORK}/Deployment.apps" <<'EOF'
teknoir-system|argocd-server||
EOF
cat > "${WORK}/Secret.v1." <<'EOF'
teknoir-system|argocd-secret||
EOF
# the baseline: every object of the teknoir-argo Addon (resource|ns|name|uid)
cat > "${WORK}/base.txt" <<'EOF'
ConfigMap.v1.|teknoir-system|argocd-cm|u1
ConfigMap.v1.|teknoir-system|argocd-tls-certs-cm|u2
ConfigMap.v1.|teknoir-system|argocd-rbac-cm|u3
ConfigMap.v1.|teknoir-system|argocd-cmd-params-cm|u4
ConfigMap.v1.|teknoir-system|argocd-ssh-known-hosts-cm|u5
ConfigMap.v1.|teknoir-system|argocd-gpg-keys-cm|u6
ConfigMap.v1.|teknoir-system|teknoir-labelled|u7
CustomResourceDefinition.apiextensions.k8s.io||applications.argoproj.io|u8
CustomResourceDefinition.apiextensions.k8s.io||appprojects.argoproj.io|u9
CustomResourceDefinition.apiextensions.k8s.io||applicationsets.argoproj.io|u10
Deployment.apps|teknoir-system|argocd-server|u11
Secret.v1.|teknoir-system|argocd-secret|u12
EOF

rc=0
env -i PATH="${PATH}" TMPDIR="${WORK}/tmp" NODE_ROOT="${WORK}/node" W="${WORK}" \
  COMMON="${REPO}/airgap/node/lib/common.sh" LIB="${REPO}/airgap/node/lib/migrate.sh" \
  bash -c '
    set -euo pipefail
    source "${COMMON}"
    source "${LIB}"
    MIGRATE_JQ=jq
    kc() {
      echo "kc $*" >> "${W}/kc.log"
      case " $* " in
        *" get applications.argoproj.io argo -o json "*) cat "${W}/argo.json" ;;
        *" -o jsonpath="*)
          # names, annotations and labels only: never -o json for listed objects
          [[ "$*" == *"argocd\.argoproj\.io/tracking-id"* && "$*" == *"app\.kubernetes\.io/managed-by"* ]] || return 1
          cat "${W}/$2" ;;
        *) echo "unexpected kc call: $*" >&2; return 1 ;;
      esac
    }
    MIGRATE_BASE_OBJS="$(cat "${W}/base.txt")"
    MIGRATE_BASE_RES="$(cut -d "|" -f1 <<<"${MIGRATE_BASE_OBJS}" | sort -u | tr "\n" " ")"
    migrate_argo_untracked
    printf "untracked=%s\n" "${MIGRATE_UNTRACKED}"
    printf "converge=%s\n" "${MIGRATE_CONVERGE_OWNED}"
  ' > "${WORK}/out" 2>&1 || rc=$?

check "exits 0" eq 0 "${rc}"
untracked="$(sed -n 's/^untracked=//p' "${WORK}/out")"
converge="$(sed -n 's/^converge=//p' "${WORK}/out")"
check "reported: argocd-cm (no owner), argocd-rbac-cm (OutOfSync in argo), another app's tracking-id; nothing else" \
  eq "ConfigMap.v1. teknoir-system/argocd-cm; ConfigMap.v1. teknoir-system/argocd-rbac-cm; ConfigMap.v1. teknoir-system/argocd-gpg-keys-cm; " "${untracked}"
check "Synced CRDs without an annotation are not reported" bash -c "! grep -q CustomResourceDefinition <<<'${untracked}${converge}'"
check "argo's tracking-id (plain and <ns>_argo) and Synced status entries count as tracked" \
  bash -c "! grep -qE 'argocd-cmd-params-cm|argocd-ssh-known-hosts-cm|argocd-server|argocd-secret' <<<'${untracked}${converge}'"
check "converge-owned: argocd-tls-certs-cm (by name) and the managed-by=teknoir-node object" \
  eq "ConfigMap.v1. teknoir-system/argocd-tls-certs-cm; ConfigMap.v1. teknoir-system/teknoir-labelled; " "${converge}"
check "objects outside the baseline are ignored" bash -c "! grep -qE 'kube-root-ca|users.teknoir.org' '${WORK}/out'"
if (( rc != 0 )); then sed 's/^/      /' "${WORK}/out"; fi

printf '\npassed %d, failed %d\n' "${PASS}" "${FAIL}"
(( FAIL == 0 ))
