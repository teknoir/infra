---
sessionId: session-260907-133534-1asa
---

# Requirements

### Overview & Goals
Revise the air-gapped `teknoir-local` plan around how Istio is actually used, and clarify Harbor authentication.

### Key Answers
- **Istio moves into the bootstrap tier** (rendered static manifests from the gitops `charts/istio` chart + image tarballs). Reason: Harbor (`expose.type: none`) and ArgoCD are reachable only via the Istio ingressgateway, and both bootstrap charts emit Istio CRs (VirtualService, AuthorizationPolicy, STRICT-mTLS PeerAuthentication) that fail without Istio CRDs/istiod.
- **`/etc/hosts` + CoreDNS custom import are still required** — they solve name resolution (node + pods, no LAN DNS), while Istio solves routing/TLS on 443. Both are needed.
- **Harbor registry path needs no oauth2-proxy/Keycloak**: the gateway ext_authz already bypasses the harbor vhost; native DB auth + a `robot$argocd` account cover ArgoCD/push flows.
- **Keycloak OIDC is mandatory for the Harbor UI** (user decision): required runbook step post-GitOps, with local-admin break-glass via `/account/sign-in`.

### Scope
In scope: infra repo (`teknoir-local` branch) bootstrap scripts, `airgap/` tooling, secrets generation, docs; gitops repo OCI conversion and domain/issuer changes.
Out of scope: Backstage (removed, GitHub-dependent); changes to Harbor's auth wiring in charts (stays as-is).

# Technical Design

### Current Implementation
- `charts/argo` (infra) emits Istio CRs: `templates/virtualservice.yaml`, `destinationrule.yaml`, `authorizationpolicy.yaml`.
- gitops `charts/harbor`: `expose.type: none`, VirtualService → harbor-core/portal, STRICT mTLS + ingressgateway-principal policies.
- gitops `charts/istio`: base/istiod/gateways 1.29.2, `teknoir-gateway` with `<domain>-wildcard-tls` (cert-manager Certificate, currently `letsencrypt-dns`).
- gitops `charts/auth`: gateway-level oauth2-proxy ext_authz EnvoyFilter with harbor/argocd/auth vhost bypasses.

### Key Decisions
1. **Istio in bootstrap tier** — render gitops istio chart to `00-teknoir-istio.yaml` (before `10-teknoir-argo.yaml`, `20-teknoir-harbor.yaml`) in K3s auto-deploy dir; ship pilot/proxyv2 tarballs; ArgoCD adopts via `ServerSideApply=true` on the istio Application.
2. **Pre-issued wildcard TLS** — `gen-local-ca-secret.sh` also issues `*.teknoir.local` cert → secret `teknoir-local-wildcard-tls` in `istio-system`; gitops Certificate switches issuerRef to CA ClusterIssuer with same secretName for seamless renewal.
3. **DNS kept** — `/etc/hosts` (node/containerd) + `coredns-custom.yaml` (pods) → node IP where klipper-lb publishes the gateway.
4. **Harbor auth** — `push-to-harbor.sh` uses admin, creates idempotent `robot$argocd` for ArgoCD repo-creds; Keycloak OIDC mandatory for UI in runbook.

### File Structure (new/changed highlights)
- infra: `airgap/{versions.env,images-extra.txt,collect-charts.sh,collect-images.sh,render-bootstrap.sh,make-bundle.sh,bootstrap-airgap.sh,push-to-harbor.sh,deploy-app-of-apps.sh,update-airgap.sh}`, `scripts/gen-local-ca-secret.sh`, `scripts/gen-argocd-harbor-repo-secret.sh`, `docs/AIRGAP-BOOTSTRAP.md`, `docs/AIRGAP-UPDATE.md`; delete internet-dependent scripts/manifests.
- gitops: OCI app-of-apps sources, `harbor.yaml` Application, cert-manager CA ClusterIssuer, `teknoir.cloud` → `teknoir.local`.

### Risks
- Istio adoption drift → render bootstrap from the same chart/version the Application pins.
- CRD ordering → numeric prefixes + K3s deploy-controller retries + health waits.
- OIDC lockout → local-admin break-glass documented; robot accounts unaffected by auth mode.

# Delivery Steps

###   Step 1: Strip internet dependencies and update infra bootstrap values
Infra `teknoir-local` branch has no internet-dependent scripts/manifests and targets `teknoir.local`.

- Delete DNS/gcr/ghcr/backstage/bootstrap scripts and obsolete secret manifests; add root `.gitignore`.
- Update `charts/argo/values.yaml` (domain, argocd host, OIDC issuer).
- Parameterize `TEKNOIR_HOST` in `deploy-argo.sh`; rewrite `deploy-secrets.sh` list-driven with the reduced secret set.

###   Step 2: Local CA, wildcard TLS, and Harbor repo-creds secrets
Bootstrap secrets exist for CA, gateway TLS, and ArgoCD→Harbor OCI access.

- Create `scripts/gen-local-ca-secret.sh` (Root CA + `teknoir-local-wildcard-tls` secret in `istio-system`).
- Create `scripts/gen-argocd-harbor-repo-secret.sh` (OCI repo-creds using robot credentials).
- Rename/rewrite app-of-apps manifest to Helm OCI source; wire new secrets into `deploy-secrets.sh`.

###   Step 3: Convert gitops repo to Harbor OCI with Istio adoption
All gitops Applications pull pinned OCI charts from Harbor; istio/harbor are adoptable.

- OCI sources + pinned versions in app-of-apps; `ServerSideApply=true` on istio; add `harbor.yaml`; drop `backstage.yaml`.
- cert-manager → CA ClusterIssuer; istio Certificate issuerRef swap (same secretName).
- Replace `teknoir.cloud` with `teknoir.local` across charts; verify offline templating.

###   Step 4: Bundle build tooling (connected side)
`make-bundle.sh` produces a complete USB bundle including the Istio bootstrap tier.

- `versions.env`, `images-extra.txt` (incl. istio proxyv2).
- `collect-charts.sh`, `collect-images.sh` (istio/argo/harbor containerd tarballs).
- `render-bootstrap.sh` (ordered 00-istio/10-argo/20-harbor manifests, `registries.yaml`, `coredns-custom.yaml`, CA).
- `make-bundle.sh` with checksum manifest and `--diff` mode.

###   Step 5: Air-gapped install and update tooling (LAN side)
Scripts bootstrap and update the cluster over SSH from the LAN laptop.

- `bootstrap-airgap.sh`: CA, registries, `/etc/hosts`, tarballs, k3s restart, secrets, coredns-custom, ordered manifests, health waits, `--update`/`--dry-run`.
- `push-to-harbor.sh`: projects, idempotent `robot$argocd`, chart/image pushes.
- `deploy-app-of-apps.sh`, `update-airgap.sh` (targetRevision patch).

###   Step 6: Documentation and runbooks
Runbooks cover bootstrap, mandatory Keycloak/Harbor OIDC, and updates.

- `docs/AIRGAP-BOOTSTRAP.md` incl. required Keycloak clients + Harbor Auth Mode OIDC and break-glass admin login.
- `docs/AIRGAP-UPDATE.md` incl. bootstrap-tier self-update and rollback.
- Rewrite `README.md`/`README_infra.md` for the air-gapped flow.