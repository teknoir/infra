# Air-Gap Update & Rollback Runbook

How to roll new chart versions, images, secrets or bootstrap-tier components
into the air-gapped `teknoir-local` cluster after the first install
([AIRGAP-BOOTSTRAP.md](AIRGAP-BOOTSTRAP.md)). Who owns what (K3s files,
ArgoCD, cert-manager) is described in
[README_infra.md § Ownership model](../README_infra.md#ownership-model).

Every step below is idempotent: re-running it with nothing changed is a no-op.

## 1. Update model

```
make-bundle.sh [--diff]  ──►  USB  ──►  push-to-harbor.sh ─► deploy-secrets.sh ─► update-airgap.sh / bootstrap-airgap.sh --update
(connected workstation)                 (LAN laptop)
```

| What changed | How it reaches the cluster |
|---|---|
| A GitOps chart (auth, cert-manager, istio, harbor, monitoring, controllers) or its images | New chart version pushed to Harbor; `update-airgap.sh` pins the new `app-of-apps` version; ArgoCD syncs |
| ArgoCD (`charts/argo`), the istio / cert-manager CRDs, bootstrap image tarballs | `bootstrap-airgap.sh --update` (K3s-owned files) |
| A secret | `scripts/gen-*.sh` → `scripts/deploy-secrets.sh` |

**Chart versions are released once.** `push-to-harbor.sh` pushes only the
versions pinned in `airgap/versions.env` that Harbor does not have yet, and a
tag-immutability rule on the Harbor project `teknoir` refuses any overwrite.
Changing a chart therefore always means a new version:

1. gitops repo (branch `teknoir-local`): bump the chart's `version`, bump the
   matching `targetRevision` in `charts/app-of-apps/templates/`, bump the
   `app-of-apps` version; commit.
2. this repo: update `GITOPS_CHARTS` (or `RELEASED_CHARTS`) in
   `airgap/versions.env` and the `targetRevision` in
   `teknoir-local-app-of-apps.yaml`; add runtime-only images to
   `airgap/images-extra.txt`.

`collect-charts.sh` (run by `make-bundle.sh`) refuses to build when the gitops
checkout is not on `teknoir-local`, when a `Chart.yaml` version differs from its
pin, or when `versions.env` does not pin exactly what the pinned `app-of-apps`
deploys. Pinned versions Harbor already has (today `auth 0.0.3`,
`cert-manager 0.0.1`, `harbor 0.0.5`) are still packaged, for rendering, image
collection and a first bootstrap, but never re-pushed. `RELEASED_CHARTS`
(empty today) is for versions that are in Harbor but no longer in the working
tree; they are never rebuilt.

## 2. Update procedure

### 2.1 Connected workstation

```sh
export GITOPS_REPO_DIR=../platform-applications-gitops-teknoir-local   # a teknoir-local checkout
./airgap/make-bundle.sh --diff
./airgap/verify-offline.sh
```

`verify-offline.sh` fails on internet references in the rendered charts, on a
`versions.env` / `app-of-apps` mismatch, and on any image a pinned chart needs
that is missing from the bundle (including images passed as container args).
`--diff` emits only the changed artifacts into
`bundle/teknoir-airgap-bundle-<version>-diff/`.

### 2.2 USB → LAN laptop

Copy the diff (or full) bundle over. A diff directory is merged into the
laptop's existing bundle copy first:

```sh
rsync -a bundle/teknoir-airgap-bundle-<version>-diff/ bundle/teknoir-airgap-bundle-<version>/
```

### 2.3 Roll out, in this order

```sh
HARBOR_ADMIN_PASSWORD='…' ./airgap/push-to-harbor.sh   # 1. new chart versions + images
./scripts/deploy-secrets.sh                            # 2. no-op unless a secret changed
./airgap/update-airgap.sh <app-of-apps version>        # 3. GitOps tier
./airgap/bootstrap-airgap.sh --update                  # 4. only if the bootstrap tier changed
```

1. Charts and images must be in Harbor before anything pins them. The robot
   account `robot$argocd` keeps its credential
   (`airgap/.secrets/robot-argocd.env`); the run only sets it in Harbor when
   Harbor rejects it.
2. The ArgoCD repo secret must match the robot credential before ArgoCD pulls.
3. `update-airgap.sh` redeploys the whole root manifest
   `teknoir-app-of-apps.yaml` (bundle content, requested `targetRevision`,
   automated sync) through K3s and retires the legacy `app-of-apps.yaml`. It
   never patches the file or the live Application in place.
4. `--update` copies only changed image tarballs (and restarts K3s only then),
   and redeploys namespaces, istio + cert-manager CRDs, `coredns-custom` and
   ArgoCD. It does not touch secrets, Istio/Harbor (ArgoCD owns them) or
   app-of-apps.

Steps 3 and 4 are independent unless a release says otherwise (see §2.4).
Finish with the checklist in §7.

### 2.4 Rolling out app-of-apps 0.0.3 (CRD ownership change)

app-of-apps 0.0.3 pins controllers 0.0.83, istio 0.0.2 (renders no CRDs),
monitoring 0.0.4 and the running harbor 0.0.5 / auth 0.0.3. The new ArgoCD
render (`charts/argo`) stops excluding CRDs, so the controller and monitoring
CRDs become ArgoCD-managed. Run step 3 **before** step 4: if ArgoCD stopped
excluding CRDs while istio 0.0.1 is still live, the `istio` Application would
take over the 14 istio CRDs, and istio 0.0.2 would later mark them for
pruning. The CRDs in `00-teknoir-istio-crds.yaml` /
`05-teknoir-certmanager-crds.yaml` carry
`argocd.argoproj.io/sync-options: Prune=false,Delete=false` as a safety net,
but only once step 4 has redeployed them.

## 3. Image-completeness check (live diff)

After an update settles, verify no running image is missing from the bundle
(catches injected sidecars and other images `helm template` does not reveal):

```sh
./airgap/verify-offline.sh --live
```

Any miss means the image only exists in the node's containerd cache and would
be unpullable after a GC or reinstall. Add it to `airgap/images-extra.txt`,
rebuild and push.

## 4. Rollback

Charts are never overwritten or deleted in Harbor, so a GitOps-tier rollback is
a re-pin of an older app-of-apps version:

```sh
./airgap/update-airgap.sh <previous version>
```

> **Do not roll back to app-of-apps 0.0.1 or 0.0.2.** Their Harbor contents
> were overwritten on 2026-09-14: both pin harbor 0.0.8 (Harbor 2.15.2, a
> one-way database migration, images not mirrored) and auth 0.0.6/0.0.7.

A bootstrap-tier rollback is `bootstrap-airgap.sh --update` run from the
previous bundle.

## 5. Bootstrap-tier updates (ArgoCD, CRDs, image tarballs)

The bootstrap tier lives in K3s-owned files in `/opt/k3s/server/manifests/` and
image tarballs in `/opt/k3s/agent/images/` (re-imported on every K3s start, so
Istio/ArgoCD/Harbor come up even when Harbor itself is down).

* **ArgoCD:** bump `ARGOCD_HELM_VERSION` / the `charts/argo` dependency, rebuild,
  `bootstrap-airgap.sh --update`. To iterate on `charts/argo` from a repo
  checkout, `scripts/deploy-argo.sh` renders and deploys the same file
  (`teknoir-argo.yaml`).
* **Istio, Harbor:** after the first bootstrap ArgoCD owns them, so a new
  version is a GitOps-tier update (new istio/harbor chart version + app-of-apps).
  Ship the new images as bootstrap tarballs too (`BOOTSTRAP_CHARTS`), so the
  node can still start them while Harbor is down.

## 6. Certificate renewal

No manual action in the steady state: cert-manager renews
`teknoir-airgapped-wildcard-tls` from the `teknoir-ca` `ClusterIssuer`. Only the
Root CA itself (10-year validity, `.secrets/ca/` on the connected workstation)
would ever need re-issuing: re-run `scripts/gen-local-ca-secret.sh`, redeploy
the CA secrets and re-distribute `teknoir-root-ca.crt` (bootstrap runbook §9).

## 7. Post-change checklist

```sh
H=teknoir@teknoir.airgapped

# 1. ArgoCD's Harbor credential works: expect 200
( . airgap/.secrets/robot-argocd.env
  curl --cacert teknoir-root-ca.crt -s -o /dev/null -w '%{http_code}\n' \
    -K <(printf 'user = "%s:%s"\n' "${HARBOR_ROBOT_USER}" "${HARBOR_ROBOT_TOKEN}") \
    "https://harbor.teknoir.airgapped/service/token?service=harbor-registry" )

# 2. No Application reports an OCI login error: expect no output
ssh "$H" sudo k3s kubectl -n teknoir-system get applications \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[*].message}{"\n"}{end}' \
  | grep -i 'logging into OCI'

# 3. Every Application Synced/Healthy, app-of-apps on the intended version
ssh "$H" sudo k3s kubectl -n teknoir-system get applications

# 4. One file per object: no legacy app-of-apps.yaml, 10-teknoir-argo.yaml or manifest-*.yaml
ssh "$H" sudo ls /opt/k3s/server/manifests
```
