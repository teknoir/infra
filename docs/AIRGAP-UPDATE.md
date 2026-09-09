# Air-Gap Update & Rollback Runbook

How to roll new chart versions, images, or bootstrap-tier components into the
air-gapped `teknoir-local` cluster after the first install
([AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md)).

## 1. Update model

```
make-bundle.sh [--diff]  ──►  USB  ──►  push-to-harbor.sh  ──►  update-airgap.sh
(connected workstation)                 (LAN laptop)             (LAN laptop)
```

Two update paths exist:

| Path | Components | Mechanism |
|---|---|---|
| GitOps tier | auth, cert-manager, monitoring, controllers, app-of-apps itself | New charts/images pushed to Harbor; `update-airgap.sh` bumps the app-of-apps `targetRevision`; ArgoCD syncs |
| Bootstrap tier | Istio, ArgoCD, Harbor | `bootstrap-airgap.sh --update` re-copies image tarballs and re-applies the re-rendered static manifests; ArgoCD reconciles adoption afterwards (§5) |

Everything is pinned in `airgap/versions.env` (chart versions,
`ISTIO_VERSION`, `ARGOCD_HELM_VERSION`, `HARBOR_HELM_VERSION`, tool versions).
Per-Application chart pins live in the gitops
`charts/app-of-apps/templates/*.yaml` (`targetRevision`), so shipping a new
version of any GitOps chart means bumping both that chart's version and the
`app-of-apps` chart version.

## 2. GitOps-tier update (charts / images)

### 2.1 Connected workstation

1. Bump the chart version(s) in the gitops repo, update the matching
   `targetRevision` in `charts/app-of-apps/templates/`, bump the `app-of-apps`
   chart version, and mirror the new pins in `airgap/versions.env`
   (`GITOPS_CHARTS`). Add any new runtime-only images to
   `airgap/images-extra.txt`.
2. Rebuild the bundle incrementally:

   ```sh
   ./airgap/make-bundle.sh --diff
   ./airgap/verify-offline.sh
   ```

   `--diff` compares the fresh `bundle-manifest.yaml` against the previous one
   and emits only the changed artifacts into
   `bundle/teknoir-airgap-bundle-<version>-diff/` (an unchanged repo yields an
   empty delta and no diff directory). A previous manifest can also be passed
   explicitly: `--diff path/to/old/bundle-manifest.yaml`.

### 2.2 USB → LAN laptop

Copy the diff (or full) bundle over. If you transferred only the diff
directory, merge it into the laptop's existing bundle copy first, e.g.:

```sh
rsync -a bundle/teknoir-airgap-bundle-<version>-diff/ bundle/teknoir-airgap-bundle-<version>/
```

### 2.3 Push and roll

```sh
HARBOR_ADMIN_PASSWORD='…' ./airgap/push-to-harbor.sh          # idempotent: projects, charts, images
./scripts/gen-argocd-harbor-repo-secret.sh && ./scripts/deploy-secrets.sh   # robot secret was rotated!
./airgap/update-airgap.sh <new-app-of-apps-revision>          # e.g. 0.0.2
```

> **Robot rotation:** `push-to-harbor.sh` rotates the `robot$argocd`
> credential on every run and rewrites `airgap/.secrets/robot-argocd.env`.
> Always regenerate + redeploy the `argocd-harbor-repo` secret afterwards, or
> ArgoCD loses pull access to Harbor.

`update-airgap.sh` patches `targetRevision` **in the file**
`/opt/k3s/server/manifests/teknoir-app-of-apps.yaml` on the node (the K3s
deploy controller owns that file — a live `kubectl patch` alone would be
reverted) and additionally patches the live Application for an immediate
reconcile. Alternatively, re-copy the bundle's `app-of-apps.yaml` wholesale:

```sh
./airgap/update-airgap.sh --from-bundle       # delegates to deploy-app-of-apps.sh
```

Monitor:

```sh
ssh teknoir@teknoir.airgapped sudo k3s kubectl -n teknoir-system get applications
```

## 3. Image-completeness check (live diff)

After any update settles, verify no running image is missing from the bundle
(catches injected sidecars, admission jobs, and other images `helm template`
does not reveal):

```sh
./airgap/verify-offline.sh --live
```

This lists every image running in the cluster (via `$KUBECONFIG` kubectl if
set, else over ssh to `TEKNOIR_HOST`), maps mirrored refs
(`harbor.teknoir.airgapped/<project>/…`) back to their upstream form, and diffs
against the bundle's `images/images.txt`. Any miss means the image only exists
in the node's containerd cache and would be unpullable after a GC or reinstall
— add it to `airgap/images-extra.txt` and rebuild/push.

## 4. Rollback

Charts are never deleted from Harbor, so rolling back the GitOps tier is a
re-pin to the previous app-of-apps revision:

```sh
./airgap/update-airgap.sh <previous-revision>   # e.g. back to 0.0.1
```

ArgoCD (automated sync with `prune` + `selfHeal`) converges every Application
back to the versions pinned by that app-of-apps chart. If a rollback target
predates the current bundle, keep the older bundle (or at least its
`bundle-manifest.yaml` and pushed charts) around — Harbor already holds the
old chart/image versions unless they were manually deleted.

Bootstrap-tier rollback works the same way as a bootstrap-tier update (§5),
run with the previous bundle.

## 5. Bootstrap-tier self-update (Istio / ArgoCD / Harbor)

The bootstrap tier is *not* delivered by ArgoCD — it lives as static manifests
in `/opt/k3s/server/manifests/` and image tarballs in `/opt/k3s/agent/images/`.
Version changes therefore need the special path:

1. **Connected workstation:** bump `ISTIO_VERSION` / `ARGOCD_HELM_VERSION` /
   `HARBOR_HELM_VERSION` (and the affected chart pins) in `airgap/versions.env`
   *and* the matching `targetRevision` in the gitops
   `charts/app-of-apps/templates/istio.yaml` / `harbor.yaml` — the ArgoCD
   Applications must pin the **same chart versions** the bootstrap renders, or
   adoption drifts. Rebuild: `./airgap/make-bundle.sh --diff`.
2. **USB → LAN laptop**, then push the new charts/images so ArgoCD's render
   source matches:

   ```sh
   HARBOR_ADMIN_PASSWORD='…' ./airgap/push-to-harbor.sh
   ./scripts/gen-argocd-harbor-repo-secret.sh && ./scripts/deploy-secrets.sh
   ```
3. **Apply the bootstrap update:**

   ```sh
   ./airgap/bootstrap-airgap.sh --update
   ```

   `--update` re-copies the image tarballs, restarts K3s (re-importing them),
   and re-applies the re-rendered `00-teknoir-istio.yaml` /
   `10-teknoir-argo.yaml` / `20-teknoir-harbor.yaml` with the same health
   waits — but skips the one-time node mutations (CA, `registries.yaml`,
   `/etc/hosts`).
4. **Let ArgoCD reconcile adoption**, then verify no drift:

   ```sh
   argocd app diff istio      # empty = bootstrap render == Application render
   argocd app diff harbor
   ./airgap/verify-offline.sh --live
   ```

The tarballs in `/opt/k3s/agent/images/` are what breaks the Harbor
self-hosting deadlock: Istio/ArgoCD/Harbor images are re-imported by
containerd on every K3s start, so the bootstrap tier comes up even when Harbor
itself is down (reboot, image GC, disaster recovery).

## 6. Certificate renewal

No manual action in the steady state: cert-manager renews
`teknoir-airgapped-wildcard-tls` from the `teknoir-ca` `ClusterIssuer`. Only the
Root CA itself (10-year validity, `.secrets/ca/` on the connected workstation)
would ever need re-issuing — that is a re-run of
`scripts/gen-local-ca-secret.sh` plus a redeploy of the CA/wildcard secrets and
re-distribution of `teknoir-root-ca.crt` (bootstrap runbook §9).
