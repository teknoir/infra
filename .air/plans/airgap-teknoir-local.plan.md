# Air-gapped Teknoir Platform — `teknoir-local` (rev. 2: Istio in bootstrap tier)

## 1. Goal

Make the infra repo (branch `teknoir-local`) bootstrap an existing air-gapped K3s cluster (`teknoir@teknoir.local`) with **Istio, ArgoCD, and Harbor** as the bootstrap tier plus base secrets — with all Helm charts and container images delivered via a portable bundle (USB) and served from in-cluster Harbor — and provide scripted, documented procedures for first-time bootstrap and updates.

## 2. Istio usage analysis (what changed in this revision and why)

Findings from the code:

1. **Everything is exposed exclusively through the Istio ingressgateway.** Harbor has `expose.type: none` (`platform-applications-gitops/charts/harbor/values.yaml:21`) — no Ingress, no NodePort. It is reachable only via the `harbor` VirtualService (`charts/harbor/templates/harbor-virtualservice.yaml`) bound to `istio-system/teknoir-gateway`, which terminates TLS with the wildcard cert (`charts/istio/templates/gateway.yaml`, `credentialName: <domain>-wildcard-tls`).
2. **The bootstrap charts themselves emit Istio CRs.** infra `charts/argo/templates/` contains `VirtualService`, `DestinationRule`, and `AuthorizationPolicy`; the harbor chart adds `PeerAuthentication` (STRICT mTLS) and `AuthorizationPolicy` requiring the `istio-ingressgateway` service-account principal. Applying these via K3s auto-deploy **fails without the Istio CRDs**, and STRICT mTLS assumes istiod + sidecars.
3. **Consequence — the previous plan deadlocked:** ArgoCD must pull OCI charts from `https://harbor.teknoir.local:443`, but nothing terminates 443 until the GitOps-tier istio Application syncs… from Harbor.

**Decision (confirmed): Istio joins the bootstrap tier.** The gitops `charts/istio` chart is rendered to static manifests (istio-base CRDs, istiod, ingressgateways) and installed via K3s auto-deploy before ArgoCD/Harbor; its images ship as containerd tarballs. ArgoCD later **adopts** the running Istio through the existing `istio` Application (same chart version ⇒ no drift).

**Do we still need node `/etc/hosts` + CoreDNS custom import? Yes — both.** They solve a *different* problem than Istio:

| Concern | Mechanism |
|---|---|
| Name resolution on the node (containerd pulls, host tools) | `/etc/hosts` entry `<node-ip> harbor.teknoir.local …` (no LAN DNS in the air gap) |
| Name resolution inside pods (ArgoCD repo-server → Harbor) | CoreDNS custom import (`coredns-custom` ConfigMap, natively supported by K3s CoreDNS) |
| Routing + TLS termination on 80/443 | Istio ingressgateway (published on the node IP by K3s klipper-lb) |

**Gateway TLS at bootstrap:** the `teknoir-gateway` references secret `teknoir-local-wildcard-tls`, normally created by the cert-manager `Certificate` (`charts/istio/templates/certificate.yaml`) — but cert-manager is GitOps-tier. The bootstrap therefore ships a **pre-issued wildcard cert secret** signed by the local Teknoir Root CA; the Certificate (switched from `letsencrypt-dns` to the CA `ClusterIssuer`, same `secretName`) takes over renewal once GitOps runs.

## 3. Harbor authentication analysis

Findings from the code:

1. Harbor **already bypasses oauth2-proxy**: the auth chart's gateway-level ext_authz EnvoyFilter explicitly disables `ext_authz` + lua for the `harbor.<domain>:443` vhost (`charts/auth/templates/istio-auth.yaml:144-160`), and `charts/harbor/values.yaml:9-12` states this is deliberate to keep Docker/Helm CLI flows working.
2. Harbor's default auth mode is its **local database** (`admin` + `HARBOR_ADMIN_PASSWORD` from `harbor-secret`). Keycloak OIDC is a *manual* configuration (`charts/harbor/README.md`). Robot accounts work in every auth mode.

**Decision (confirmed):**
- **Registry/API path needs no Keycloak/oauth2-proxy and does not move into infra.** `push-to-harbor.sh` uses the admin credential; it also creates an idempotent **robot account** (`robot$argocd`, pull-only on chart/mirror projects) whose credentials feed the ArgoCD `repo-creds` secret.
- **Keycloak OIDC is mandatory for Harbor UI** (post-GitOps): the runbook gets a required section — create the `harbor` client in Keycloak, switch Harbor Auth Mode to OIDC against `https://auth.teknoir.local/auth/realms/master` (Verify Certificate ON, Root CA distributed). Local `admin` login remains available at `/account/sign-in` as break-glass; CLI uses robot accounts / OIDC CLI secrets.

## 4. Key design artifacts

### 4.1 Harbor layout (unchanged)

| Harbor project | Purpose |
|---|---|
| `teknoir` | Helm OCI charts: `harbor.teknoir.local/teknoir/<chart>:<version>` |
| `dockerhub` / `ghcr` / `gcr` / `quay` / `k8s` | mirrors of `docker.io` / `ghcr.io` / `gcr.io` / `quay.io` / `registry.k8s.io` |

### 4.2 K3s registry mirroring (`/etc/rancher/k3s/registries.yaml`) — unchanged

Mirrors all five upstream registries to `https://harbor.teknoir.local` with project-prefix rewrites; `ca_file: /etc/rancher/k3s/teknoir-root-ca.crt`.

### 4.3 Bundle layout (bootstrap tier now includes Istio)

```
teknoir-airgap-bundle-<version>/
├── bundle-manifest.yaml
├── bootstrap/
│   ├── images/                   # containerd tarballs: istio (pilot, proxyv2), argo-cd, harbor, pause
│   ├── manifests/                # 00-teknoir-istio.yaml, 10-teknoir-argo.yaml, 20-teknoir-harbor.yaml, app-of-apps.yaml
│   └── k3s/                      # registries.yaml, teknoir-root-ca.crt, coredns-custom.yaml
├── charts/                       # <chart>-<version>.tgz for every GitOps chart (deps vendored)
├── images/                       # workload images as OCI layout (crane), digest-deduplicated
└── tools/                        # pinned crane + helm binaries
```

Numeric prefixes give the K3s deploy controller deterministic ordering (CRDs → istiod/gateway → argo → harbor); its retry loop covers CRD-establishment races.

### 4.4 Bootstrap flow (first install)

```
[connected workstation]              [laptop on LAN]                  [teknoir@teknoir.local (K3s)]
make-bundle.sh ──► USB ──► bootstrap-airgap.sh ── ssh ──► CA + registries.yaml + /etc/hosts + image tarballs
                                                          restart k3s
                                                          secrets (incl. wildcard-tls) + coredns-custom
                                                          istio manifests → argo + harbor manifests
                                                          (auto-deploy → Istio gw :443, ArgoCD, Harbor up)
                           push-to-harbor.sh ── https ──► projects + robot$argocd, push charts + images
                           deploy-app-of-apps.sh ─ ssh ─► app-of-apps (oci://harbor…/teknoir/app-of-apps)
                                                          ArgoCD adopts istio + harbor, syncs auth,
                                                          cert-manager, monitoring, controllers
                           runbook (manual) ────────────► Keycloak clients (argocd, harbor) + Harbor OIDC
```

### 4.5 Update flow (unchanged from rev. 1)

`make-bundle.sh [--diff]` → USB → `push-to-harbor.sh` → `update-airgap.sh` patches app-of-apps `targetRevision`. Bootstrap-tier updates (Istio/ArgoCD/Harbor versions) via `bootstrap-airgap.sh --update` (re-copies tarballs, re-renders static manifests; ArgoCD reconciles adoption afterwards).

## 5. File Changes

### A. infra repo — remove (unchanged from rev. 1)

- **Delete** internet-dependent scripts: `scripts/create-dns-secret.sh`, `create-gcr-json-key-secret.sh`, `create-ghcr-token-secret.sh`, `gen-backstage-secrets.sh`, `gen-backstage-keycloak-secrets.sh`, `bootstrap_teknoir_master.sh`, `bootstrap_agent_worker.sh`.
- **Delete** obsolete secret manifests (clouddns, gcr, ghcr, godaddy, loopia, letsencrypt, github, backstage×2), stale artifacts (`test-output.yaml`, `teknoir-monitoring.yaml`, `teknoir-argo.yaml`), and `argocd-teknoir-cloud.2026-04-07.private-key.pem`; add root `.gitignore` for rendered outputs / `manifest-*.yaml` / `bundle/`.

### B. infra repo — modify

- **Modify** `charts/argo/values.yaml`: `domain: teknoir.local`, `global.domain: argocd.teknoir.local`, OIDC issuer `https://auth.teknoir.local/auth/realms/master`.
- **Modify** `scripts/deploy-argo.sh` and `scripts/deploy-secrets.sh`: `TEKNOIR_HOST` variable (default `teknoir@teknoir.local`); reduced list-driven secret set — keep harbor, keycloak-db, oauth2-proxy(+redis), argocd-keycloak; add `teknoir-root-ca`, `teknoir-local-wildcard-tls`, `argocd-harbor-repo`.
- **Modify** `teknoir-cloud-app-of-apps.yaml` → rename `teknoir-local-app-of-apps.yaml`: Helm OCI source (`repoURL: harbor.teknoir.local/teknoir`, `chart: app-of-apps`, pinned `targetRevision`).
- **Modify** `README.md` / `README_infra.md`: air-gapped quick-start, link runbooks.

### C. infra repo — create

- **Create** `scripts/gen-local-ca-secret.sh` — Teknoir Root CA (10y) → `manifest-teknoir-ca-secret.yaml` + `teknoir-root-ca.crt`; **additionally issues the `*.teknoir.local` wildcard server cert (1y)** → `manifest-wildcard-tls-secret.yaml` (TLS secret `teknoir-local-wildcard-tls` in `istio-system`) so the gateway has TLS from the first boot.
- **Create** `scripts/gen-argocd-harbor-repo-secret.sh` — ArgoCD `repo-creds` secret (`enableOCI: "true"`, `url: harbor.teknoir.local/teknoir`) consuming the **robot account** credentials emitted by `push-to-harbor.sh` (admin fallback for first render).
- **Create** `airgap/` connected-side tooling:
  - `airgap/versions.env`, `airgap/images-extra.txt` (must list istio `proxyv2` sidecar image, trivy DB, busybox, pause).
  - `airgap/collect-charts.sh` — `helm dependency build` + `helm package` every gitops chart → `bundle/charts/`.
  - `airgap/collect-images.sh` — template-extract images + extras, `crane pull --format=oci`; bootstrap tier (**istio pilot/proxyv2**, argo-cd, harbor, pause) additionally saved as containerd tarballs.
  - `airgap/render-bootstrap.sh` — `helm template` of **three** charts with `teknoir.local` values: gitops `charts/istio` → `00-teknoir-istio.yaml`, infra `charts/argo` → `10-teknoir-argo.yaml`, gitops `charts/harbor` → `20-teknoir-harbor.yaml` (all labeled for ArgoCD adoption/takeOwnership); emits `registries.yaml` and `coredns-custom.yaml` (`*.teknoir.local` → node IP); copies `teknoir-root-ca.crt`.
  - `airgap/make-bundle.sh` — orchestrates the above + secrets + tools; `bundle-manifest.yaml` with checksums; `--diff` incremental mode.
- **Create** `airgap/` LAN-laptop-side tooling:
  - `airgap/bootstrap-airgap.sh` — over SSH: CA + `registries.yaml`, `/etc/hosts` entries, image tarballs → `/opt/k3s/agent/images/`, k3s restart, secrets + `coredns-custom.yaml` + ordered bootstrap manifests → `/opt/k3s/server/manifests/`, wait for istio-ingressgateway/ArgoCD/Harbor healthy (`--update`, `--dry-run` modes).
  - `airgap/push-to-harbor.sh` — create six projects, **create/rotate `robot$argocd`** (pull on `teknoir` + mirror projects) and write its credential for `gen-argocd-harbor-repo-secret.sh`, `helm push` charts, `crane cp` images; idempotent.
  - `airgap/deploy-app-of-apps.sh`, `airgap/update-airgap.sh` — unchanged from rev. 1.
- **Create** `docs/AIRGAP-BOOTSTRAP.md` — runbook incl. **mandatory Keycloak section**: create `argocd` and `harbor` clients, configure Harbor Auth Mode = OIDC (`https://auth.teknoir.local/auth/realms/master`, Verify Certificate ON), note local-admin break-glass via `/account/sign-in`, CA distribution to laptops/browsers.
- **Create** `docs/AIRGAP-UPDATE.md` — update/rollback runbook incl. bootstrap-tier (Istio/ArgoCD/Harbor) self-update special case.

### D. platform-applications-gitops repo (branch `teknoir-local`)

- **Modify** `charts/app-of-apps/values.yaml` + all templates (`istio.yaml`, `auth.yaml`, `cert-manager.yaml`, `monitoring.yaml`, `controllers.yaml`): OCI sources `repoURL: harbor.teknoir.local/teknoir`, `chart:`, pinned `targetRevision`; `project: teknoir-local`.
- **Modify** `charts/app-of-apps/templates/istio.yaml`: add `syncOptions: [ServerSideApply=true]` so the Application **adopts** the bootstrap-installed Istio without recreate; same for the new `harbor.yaml`.
- **Delete** `charts/app-of-apps/templates/backstage.yaml` (GitHub-dependent; documented limitation).
- **Create** `charts/app-of-apps/templates/harbor.yaml` — Application adopting bootstrap Harbor.
- **Modify** `charts/istio/templates/certificate.yaml`: `issuerRef` `letsencrypt-dns` → CA `ClusterIssuer` (`teknoir-ca`); keep `secretName` `teknoir-local-wildcard-tls` so cert-manager renews the pre-issued bootstrap secret in place.
- **Modify** `charts/cert-manager`: drop `godaddy-webhook` dep + ACME issuers; add CA `ClusterIssuer` referencing `teknoir-root-ca`.
- **Modify** domain values `teknoir.cloud` → `teknoir.local` across istio/auth/harbor/monitoring/controller charts (gateway hosts, oauth2-proxy redirect URLs, Keycloak hostname, virtualservice hosts).
- **No change to Harbor auth wiring**: `istio.auth.enabled: false` and the gateway-level ext_authz harbor-vhost bypass stay exactly as-is.

## 6. Implementation Steps

### Task 1: Strip internet dependencies from infra bootstrap
1. Delete files per §5.A; add `.gitignore`.
2. Update `charts/argo/values.yaml` for `teknoir.local`; parameterize `TEKNOIR_HOST`; rewrite `deploy-secrets.sh` list-driven.
3. `helm template charts/argo` renders cleanly offline.

### Task 2: Local CA, wildcard TLS, Harbor repo-creds
1. `scripts/gen-local-ca-secret.sh` (Root CA + **wildcard TLS secret for the gateway**).
2. `scripts/gen-argocd-harbor-repo-secret.sh` (OCI repo-creds, robot-account credential input).
3. Rename/rewrite app-of-apps manifest to Helm OCI source; wire new secrets into `deploy-secrets.sh`.

### Task 3: GitOps repo conversion (`teknoir-local` branch)
1. OCI app-of-apps templates + pinned versions; ServerSideApply on `istio.yaml`; add `harbor.yaml`; drop `backstage.yaml`.
2. cert-manager → CA ClusterIssuer; istio Certificate issuerRef swap (same secretName).
3. `teknoir.cloud` → `teknoir.local` everywhere; verify all charts template offline from vendored deps.

### Task 4: Bundle build tooling (connected side)
1. `versions.env`, `images-extra.txt` (incl. istio proxyv2).
2. `collect-charts.sh`, `collect-images.sh` (istio/argo/harbor bootstrap tarballs).
3. `render-bootstrap.sh` (ordered `00-istio` / `10-argo` / `20-harbor` manifests, `registries.yaml`, `coredns-custom.yaml`, CA).
4. `make-bundle.sh` with manifest checksums + `--diff`.

### Task 5: Air-gapped install & update tooling (LAN side)
1. `bootstrap-airgap.sh` (CA, registries, `/etc/hosts`, tarballs, restart, secrets, coredns-custom, ordered manifests, health waits, `--update`/`--dry-run`).
2. `push-to-harbor.sh` (projects, robot account, charts, images; idempotent).
3. `deploy-app-of-apps.sh`, `update-airgap.sh`.

### Task 6: Documentation
1. `docs/AIRGAP-BOOTSTRAP.md` — full runbook with mandatory Keycloak/Harbor-OIDC section and Istio-adoption verification.
2. `docs/AIRGAP-UPDATE.md` — update/rollback incl. bootstrap-tier self-update.
3. Rewrite `README.md` / `README_infra.md`.

## 7. Acceptance Criteria

1. No references to `github.com`, `ghcr.io` creds, `gcloud`, GoDaddy/Loopia/CloudDNS, or Let's Encrypt in active scripts/manifests on `teknoir-local`.
2. `render-bootstrap.sh` output contains, in order-prefixed files: istio CRDs + istiod + ingressgateway, then ArgoCD, then Harbor — and `kubectl apply --dry-run=client` succeeds on each file given the previous ones' CRDs.
3. The rendered `teknoir-gateway` references `teknoir-local-wildcard-tls`, and `gen-local-ca-secret.sh` produces a TLS secret with that exact name/namespace (`istio-system`), cert CN `*.teknoir.local`, CA validity ≥ 10y.
4. `coredns-custom.yaml` + `/etc/hosts` entries both resolve `harbor.teknoir.local`/`argocd.teknoir.local`/`auth.teknoir.local` to the node IP; documented as required *in addition to* Istio.
5. Rendered app-of-apps: every Application uses `harbor.teknoir.local/teknoir` OCI source with pinned version; `istio` and `harbor` Applications carry `ServerSideApply=true`.
6. `push-to-harbor.sh` creates `robot$argocd` idempotently; `argocd-harbor-repo` secret uses the robot credential, not admin.
7. `make-bundle.sh` produces the §4.3 layout with checksum manifest; `--diff` on unchanged repo yields an empty delta.
8. Every gitops chart templates offline from vendored deps; rendered output contains zero `teknoir.cloud` / upstream-repo URLs.
9. All new shell scripts pass `bash -n` + `shellcheck`; air-gapped-side scripts support `--dry-run`.
10. `AIRGAP-BOOTSTRAP.md` contains the mandatory Keycloak/Harbor-OIDC procedure (client creation → Auth Mode OIDC → verification), and the break-glass local-admin note.

## 8. Verification Steps

- `bash -n` + `shellcheck` on all scripts.
- `helm template` each chart in both repos; grep rendered output for `teknoir.cloud|github.com|storage.googleapis.com` ⇒ zero hits (scriptable as `airgap/verify-offline.sh`).
- `kubectl apply --dry-run=client` on generated secrets, ordered bootstrap manifests, and `teknoir-local-app-of-apps.yaml`.
- `openssl verify -CAfile teknoir-root-ca.crt` on the wildcard cert; SAN check for `*.teknoir.local`.
- Run `make-bundle.sh` end-to-end on the connected workstation; validate checksums.
- Manual runbook execution on `teknoir@teknoir.local`: ingressgateway serving 443 on the node IP, `https://harbor.teknoir.local` + `https://argocd.teknoir.local` reachable with CA-trusted TLS, all Applications Synced/Healthy, istio Application shows adopted resources (no recreation), OIDC login to Harbor UI via Keycloak, robot-account chart pull by ArgoCD.

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| **Istio adoption drift** — bootstrap-rendered manifests differ from ArgoCD's later render, causing recreate of istiod/gateway | Render bootstrap from the *same* gitops chart + values + version that the istio Application pins; `ServerSideApply=true`; verify `argocd app diff` empty in runbook |
| **CRD ordering in K3s auto-deploy** — istio CRs applied before CRDs established | Numeric file prefixes + K3s deploy-controller retry loop; `bootstrap-airgap.sh` waits for istiod/gateway health before proceeding |
| **STRICT mTLS during bootstrap** — Harbor pods start before istiod ⇒ no sidecars ⇒ policies block gateway traffic | Ordering guarantees istiod ready before Harbor manifests land; health-wait also checks harbor pods have `istio-proxy` containers |
| **Wildcard cert renewal seam** — cert-manager Certificate must take over the pre-issued secret | Same `secretName`; cert-manager re-issues on first reconcile from the CA ClusterIssuer (brief, non-disrupting secret update); documented |
| **Image list incompleteness** (istio sidecar proxyv2, trivy DB, admission jobs) | `images-extra.txt` + live-cluster diff step in `verify-offline.sh`/update runbook |
| **Harbor self-hosting deadlock** after reboot/GC | Istio/ArgoCD/Harbor images always shipped as tarballs in `/opt/k3s/agent/images/` (re-imported on K3s start) |
| **Keycloak-OIDC lockout** — OIDC mandated for Harbor UI but auth chart unhealthy | Local `admin` break-glass via `/account/sign-in` documented; registry path (robot accounts) unaffected by auth-mode |
| **Secrets in git** | `.gitignore` all `manifest-*.yaml`; operator laptop/USB storage only |
