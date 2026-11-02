#!/bin/sh
# Install ArgoCD on the staging k3s server through k3s's auto-deploy manifests directory.
#   STAGING_HOST    ssh target (default anders@192.168.2.19, vpro; r415 until 2026-10-16)
#   K3S_MANIFESTS   k3s server manifests dir (default /var/lib/rancher/k3s/server/manifests;
#                   r415 used data-dir /opt/k3s)
#   FORCE_DEPLOY=1  write teknoir-argo.yaml even when ArgoCD manages itself (break-glass: turn off
#                   automated sync on app-of-apps, then on argo, first, or selfHeal reverts it; the
#                   file stays in the manifests directory until the next normal run detaches it)
#
# First install only. Once the Application teknoir-system/argo exists (platform-applications-gitops
# teknoir-cloud, charts/argo, same Helm release name argo), ArgoCD manages itself and this script
# changes nothing in the cluster: when that Application is Synced and Healthy it moves
# teknoir-argo.yaml out of the manifests directory (k3s would re-apply it over the Application on
# every restart); otherwise it warns and leaves the file for a later run. If the cluster cannot be
# read it stops: it never falls back to writing the file. The kube-system Addon teknoir-argo stays behind:
# k3s deletes nothing when a file disappears, so the Addon is a harmless orphan.
# The ssh commands expand $K3S_MANIFESTS and $DETACHED_DIR locally on purpose.
# shellcheck disable=SC2029
set -e
STAGING_HOST=${STAGING_HOST:-anders@192.168.2.19}
K3S_MANIFESTS=${K3S_MANIFESTS:-/var/lib/rancher/k3s/server/manifests}
DETACHED_DIR=$(dirname "$K3S_MANIFESTS")/manifests-detached

# Empty: no Application CRD (a fresh cluster) or no Application argo. Any kubectl or ssh error stops here.
if ! app_status=$(ssh "$STAGING_HOST" "crd=\$(sudo k3s kubectl get crd applications.argoproj.io --ignore-not-found -o name) || exit 1
    [ -n \"\$crd\" ] || exit 0
    sudo k3s kubectl -n teknoir-system get applications.argoproj.io argo --ignore-not-found \
      -o jsonpath='{.status.sync.status}/{.status.health.status}'"); then
  echo "deploy-argo: cannot read the cluster on $STAGING_HOST; nothing changed" >&2
  exit 1
fi

if [ -n "$app_status" ] && [ "${FORCE_DEPLOY:-0}" != 1 ]; then
  echo "deploy-argo: Application teknoir-system/argo exists ($app_status): ArgoCD manages itself; change it in platform-applications-gitops charts/argo"
  if [ "$app_status" != "Synced/Healthy" ]; then
    echo "deploy-argo: WARNING: teknoir-argo.yaml left in place until the Application is Synced/Healthy; re-run then" >&2
    exit 0
  fi
  ssh "$STAGING_HOST" "if sudo test -f $K3S_MANIFESTS/teknoir-argo.yaml; then
      sudo install -d $DETACHED_DIR && sudo mv $K3S_MANIFESTS/teknoir-argo.yaml $DETACHED_DIR/teknoir-argo.yaml.\$(date -u +%Y%m%dT%H%M%SZ) &&
      echo 'deploy-argo: moved teknoir-argo.yaml to $DETACHED_DIR (k3s no longer applies it)'
    else
      echo 'deploy-argo: teknoir-argo.yaml already detached'
    fi"
  exit 0
fi
[ -z "$app_status" ] || echo "deploy-argo: FORCE_DEPLOY=1: writing teknoir-argo.yaml over the self-managed ArgoCD; with automated sync on, selfHeal reverts it" >&2

helm dependency build charts/argo >/dev/null
helm template --namespace teknoir-system --values charts/argo/values.yaml argo charts/argo > teknoir-argo.yaml

ssh "$STAGING_HOST" "sudo install -d $K3S_MANIFESTS && sudo tee $K3S_MANIFESTS/teknoir-argo.yaml >/dev/null" \
  < teknoir-argo.yaml
echo "deploy-argo: teknoir-argo.yaml applied on $STAGING_HOST"
