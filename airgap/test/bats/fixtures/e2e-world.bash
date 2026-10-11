# shellcheck shell=bash
# e2e-world.bash — a stand-in cluster for dry runs of e2e.sh's checks in bats
# (harness.bats): source e2e.sh, then this file. vm_kc, vmx and the netns
# helpers answer from a healthy teknoir-default world with fixture JSON; a test
# breaks one thing through WORLD_BREAK and checks that exactly that assertion
# fails. Nothing here reaches a VM, a cluster or the network.
#
# WORLD_BREAK (one of): appproject-cluster-kinds, plugin-fail, no-sidecar,
#   image-missing, dns, claim, catalog-member

WORLD_BREAK="${WORLD_BREAK:-}"
WORLD_DOMAIN="teknoir.airgapped"
WORLD_TS="teknoir-default"
WORLD_OWNER="Owner@Example.com"

world_profile() {
  local st="Success" argo_owns='"f:owner": {}'
  [[ "${WORLD_BREAK}" == plugin-fail ]] && st="Fail"
  # the controller fills spec.plugins and owns it; ArgoCD's Apply owns only f:owner
  [[ "${WORLD_BREAK}" == gitops-plugins ]] && argo_owns='"f:owner": {}, "f:plugins": {}'
  cat <<EOF
{"metadata": {"name": "${WORLD_TS}", "annotations": {
   "argocd.argoproj.io/sync-options": "Prune=false, Delete=false",
   "argocd.argoproj.io/tracking-id": "profile-controller:teknoir.org/Profile:/${WORLD_TS}"},
   "managedFields": [
     {"manager": "argocd-controller", "operation": "Apply", "fieldsV1": {"f:spec": {${argo_owns}}}},
     {"manager": "manager", "operation": "Update", "fieldsV1": {"f:spec": {"f:plugins": {}, "f:resourceQuotaSpec": {}}}}]},
 "spec": {"owner": {"kind": "User", "name": "${WORLD_OWNER}"}, "plugins": [{"kind": "EMQX"}, {"kind": "Deadend"}]},
 "status": {"appliedconfig": {"plugins": {
   "EMQX": {"appliedConfig": {"settings": {"enabled": true}}, "applyStatus": {"status": "${st}"}},
   "Deadend": {"appliedConfig": {"settings": {"enabled": true}}, "applyStatus": {"status": "Success"}},
   "Postgres": {"appliedConfig": {"settings": {"enabled": false}}, "applyStatus": {"status": "Fail"}}}}}}
EOF
}

world_pods() {
  local sidecar='"initContainers": [{"name": "istio-proxy", "image": "docker.io/istio/proxyv2:1.29.2"}],'
  [[ "${WORLD_BREAK}" == no-sidecar ]] && sidecar=''
  cat <<EOF
{"items": [
  {"metadata": {"name": "emqx-0"}, "spec": {${sidecar} "containers": [{"name": "emqx", "image": "docker.io/emqx/emqx:5.8.6"}]},
   "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}},
  {"metadata": {"name": "job-done"}, "spec": {"containers": [{"name": "c", "image": "docker.io/emqx/emqx:5.8.6"}]},
   "status": {"phase": "Succeeded"}}]}
EOF
}

vm_kc() {
  local a="$*" p
  case "${a}" in
    "get profiles.teknoir.org ${WORLD_TS} -o json"|"get profiles.teknoir.org ${WORLD_TS} --show-managed-fields -o json") world_profile ;;
    "get profiles.teknoir.org ${WORLD_TS} -o jsonpath={.spec.owner.name}") printf '%s' "${WORLD_OWNER}" ;;
    "get namespace ${WORLD_TS} -o json")
      echo "{\"metadata\": {\"labels\": {\"istio-injection\": \"enabled\"}, \"annotations\": {\"owner\": \"owner@example.com\"},
             \"ownerReferences\": [{\"kind\": \"Profile\", \"name\": \"${WORLD_TS}\"}]}}" ;;
    "-n ${WORLD_TS} get rolebinding namespaceAdmin -o json")
      echo '{"roleRef": {"kind": "ClusterRole", "name": "teknoir-admin"}, "subjects": [{"kind": "User", "name": "Owner@example.com"}]}' ;;
    "-n ${WORLD_TS} get rolebinding user-owner-at-example.com-teknoir-role-binding -o "*)
      echo '{"roleRef": {"kind": "ClusterRole", "name": "teknoir-admin"}, "subjects": [{"kind": "User", "name": "owner@example.com"}]}' ;;
    "get users.teknoir.org owner-at-example.com -o jsonpath="*)
      [[ "${WORLD_BREAK}" == claim ]] || printf 'viewer@other\nowner@%s\n' "${WORLD_TS}" ;;
    "-n ${WORLD_TS} get "*" -o name") echo "${a#* get }" ;;
    "-n teknoir-system get configmap profile-controller-config -o jsonpath={.data.PLUGIN_CHART_REPO}") printf 'harbor.%s/teknoir' "${WORLD_DOMAIN}" ;;
    "-n teknoir-system get configmap profile-controller-config -o jsonpath={.data.PLUGIN_CHART_VERSION}") printf '0.0.99' ;;
    "-n teknoir-system get appprojects.argoproj.io ${WORLD_TS} -o json")
      if [[ "${WORLD_BREAK}" == appproject-cluster-kinds ]]; then
        echo "{\"spec\": {\"sourceRepos\": [\"harbor.${WORLD_DOMAIN}/teknoir\"], \"clusterResourceWhitelist\": [{\"group\": \"*\", \"kind\": \"*\"}]}}"
      else
        echo "{\"spec\": {\"sourceRepos\": [\"harbor.${WORLD_DOMAIN}/teknoir\"]}}"
      fi ;;
    "-n teknoir-system get applications.argoproj.io ${WORLD_TS}-"*" -o json")
      echo "{\"spec\": {\"source\": {\"repoURL\": \"harbor.${WORLD_DOMAIN}/teknoir\", \"targetRevision\": \"0.0.99\"},
             \"project\": \"${WORLD_TS}\", \"syncPolicy\": {\"syncOptions\": [\"CreateNamespace=true\", \"RespectIgnoreDifferences=true\"]}}}" ;;
    "-n teknoir-system get applications.argoproj.io --no-headers -o custom-columns="*)
      for p in "${PLUGINS[@]}"; do echo "${WORLD_TS}-${p} Synced Healthy"; done ;;
    "-n ${WORLD_TS} get pods -o json"|"get pods -n ${WORLD_TS} -o json") world_pods ;;
    "-n ${WORLD_TS} get pods -o name") echo pod/emqx-0 ;;
    "-n ${WORLD_TS} get events --no-headers") : ;;
    "get events -n ${WORLD_TS} -o json") echo '{"items": []}' ;;
    "-n default run "*"nslookup mqtt-${WORLD_TS}.${WORLD_DOMAIN}")
      printf 'Server:\t\t10.43.0.10\nAddress:\t10.43.0.10:53\n\nName:\tmqtt-%s.%s\n' "${WORLD_TS}" "${WORLD_DOMAIN}"
      [[ "${WORLD_BREAK}" == dns ]] || printf 'Address: 10.77.0.10\n' ;;
    *) echo "world: unexpected vm_kc ${a}" >&2; return 1 ;;
  esac
}

vmx() {
  case "$*" in
    "sudo k3s crictl images -o json")
      if [[ "${WORLD_BREAK}" == image-missing ]]; then echo '{"images": [{"repoTags": ["docker.io/emqx/emqx:5.8.6"]}]}'
      else echo '{"images": [{"repoTags": ["docker.io/emqx/emqx:5.8.6"]}, {"repoTags": [], "repoDigests": ["docker.io/istio/proxyv2@sha256:aa"]}, {"repoTags": ["docker.io/istio/proxyv2:1.29.2"]}]}'; fi ;;
    *) echo "world: unexpected vmx $*" >&2; return 1 ;;
  esac
}

lan() {
  shift
  case "$1 $2" in
    "openssl s_client") printf 'CONNECTION ESTABLISHED\nProtocol version: TLSv1.3\nVerification: OK\n' ;;
    *) echo "world: unexpected lan $*" >&2; return 1 ;;
  esac
}

ca_file() { echo /dev/null; }
# shellcheck disable=SC2034  # LOGIN_OK is read by e2e.sh
login_check() { pass "$1"; LOGIN_OK=1; }
app_status() { printf '200 %s' "$2"; }
bs_token() { echo "user:default/owner-at-example.com"; : > "$2"; }
bs_entity() {
  local member="group:${WORLD_TS}/${WORLD_TS}"
  [[ "${WORLD_BREAK}" == catalog-member ]] && member="group:${WORLD_TS}/viewer"
  echo "{\"spec\": {\"memberOf\": [\"group:teknoir/public\", \"${member}\"]}}" > "$4"
  printf '200'
}
