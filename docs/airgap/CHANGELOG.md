# Airgap changelog and history

What changed in the airgapped `teknoir-local` tooling, and why. The runbooks
([OPERATE.md](OPERATE.md), [HOST-SETUP.md](HOST-SETUP.md), [BUILD.md](BUILD.md))
describe only the current procedure; past procedures, incidents and the
reasons for the redesign are kept here. The git history of `infra` and
`platform-applications-gitops` (branch `teknoir-local`) is the full archive.

## r5 (app-of-apps 0.0.5)

### monitoring 0.0.5, argo 0.0.4, harbor 0.0.10: access for group admin only (gitops)

- **Grafana, Prometheus and Alertmanager are for Keycloak group `admin`
  only.** Before, every realm user who signed in at the gateway reached all
  three, and Grafana gave everyone the Admin role (anonymous access with
  `org_role: Admin`). Now each of the three checks the access token that
  oauth2-proxy forwards, against realm `teknoir`, and lets the gateway in only
  when the token's `groups` claim holds `admin`. Any other realm user gets
  `403` (`RBAC: access denied`) on
  `https://teknoir.airgapped/teknoir-system/{grafana,prometheus,alertmanager}/`.
  Grafana signs the user in from the same token. The login is the Keycloak
  username (`preferred_username`): the e-mail address for users that
  user-controller creates (`./teknoir-airgap admin-user` included), while a
  user made by hand in the Keycloak console signs in with the username it was
  given. Group `admin` is Grafana Admin. Anonymous access and self sign-up are
  off.
- **Alerts reach Alertmanager again.** Prometheus sent alerts to
  Alertmanager's pod IP. That request left the mesh in plaintext, and
  Alertmanager's sidecar (STRICT mTLS) reset it, so every notification failed
  with `503` ("Error sending alerts" in the Prometheus log). Prometheus now
  addresses Alertmanager's Service, over mTLS, and a new policy lets
  Prometheus in. Alertmanager stays at one replica, and the chart now refuses
  to render more: with Service addressing, each batch of alerts would reach
  one replica only.
- **Prometheus' and Alertmanager's lifecycle endpoints are closed.** Every
  request to `.../-/quit` or `.../-/reload` gets `403` from any source: through
  the gateway (group `admin` included) and from pods in the mesh, also when a
  slash is percent-encoded (`-%2Fquit`). Before, a cross-site POST from a page
  that an admin visited could stop Prometheus through the gateway (the
  oauth2-proxy cookie is `SameSite=None`), and any teknoir-system or
  teknoir-auth pod could stop it without a token. The config-reloader
  sidecars reload through `127.0.0.1`, which does not pass the sidecar, so
  configuration changes still apply.
- **Render guards.** The monitoring chart refuses to render (ArgoCD shows a
  ComparisonError and syncs nothing) when a values change would weaken the
  access setup: Grafana's issuer differs from `monitoring.access.issuer`,
  `auth.jwt` is off, anonymous access is on, alerts would not go to
  Alertmanager's Service, or Alertmanager has more than one replica.
- **Grafana trusts the Teknoir Root CA.** Grafana fetches the realm's signing
  keys from `https://auth.teknoir.airgapped`, so it mounts Secret
  `teknoir-root-ca-bundle` (optional). Grafana must be restarted after that
  Secret is created or rotated (OPERATE.md, "r5 (app-of-apps 0.0.5)").
- **ArgoCD: group `admin` only.** Group `admin` is `role:admin`. The default
  role `role:readonly` is gone, and so is group `argocd-admins` (realm
  `teknoir` has no such group).
  Other realm users can still sign in, but they see no Applications, projects
  or settings. The local `admin` stays enabled as break-glass (`argocd-admin`).
- **Harbor: only admins create projects.** Project creation is limited to
  Harbor admins: the local `admin` and group `admin`
  (`project_creation_restriction: adminonly`). Before, every user who signed
  in could create a project. The five `fix-permissions` init containers run
  `busybox:1.36.1` (was `latest`), which the bundle already carries.
- The update restarts Grafana once. Because the init image changed, it also
  restarts `harbor-database`, `harbor-redis`, `harbor-trivy`,
  `harbor-registry` and `harbor-jobservice` once during the sync, so image
  pulls retry for a short while. The Istio policies and ArgoCD's RBAC apply
  without a restart. Harbor's OIDC Job runs again and changes only
  `project_creation_restriction`.

## 2026-10: redesign (app-of-apps 0.0.4)

One build command, one LAN-host command, and the same command for the first
install and every update.

- **One file per bundle.** `teknoir-airgap-<bundleId>.tar` plus `.tar.sha256`;
  the bundle id names the env, the app-of-apps version, the build date and both
  commits. `MANIFEST.yaml` records the commits, versions, image digests and the
  sha256 of every file. Images are linux/amd64 only (about 3 GB instead of
  8.1 GB). The fixed `BUNDLE_VERSION` 0.1.0 and the `--diff` delta bundles are
  gone.
- **No secrets in bundles.** Every secret is created inside the cluster on the
  node, once: the CA, the wildcard placeholder and the Harbor token certificate
  by the node converge, every random secret by the `platform-secrets` chart.
  The `scripts/gen-*.sh` generators, `deploy-secrets.sh` and the `.secrets/`
  directory are retired. `teknoir-airgap credentials` hands a value out into a
  0600 file.
- **One LAN command.** `./teknoir-airgap up` verifies the bundle, pins the node's
  ssh host key, sets up sudo once, copies only the payload files the node lacks,
  runs the converge on the node and fetches the kubeconfig (context
  `teknoir-local`, replacing stale entries) and the CA. The LAN host needs only
  ssh, tar and sha256sum or shasum; Python, crane and helm are no longer needed
  there, and admin credentials never reach it.
- **Converge on the node.** `teknoir-node converge` runs as root under a lock
  with a log in `/var/log/teknoir-airgap/`: verify, preflight (address, disk,
  clock), automatic backup, host (k3s, registries, CA, hosts, chrony, bootstrap
  images), cluster base, secrets, one-shot tiers, Harbor content, release pin,
  post-checks. Every phase is idempotent and an interrupted run resumes.
- **Works on a node with no route and no resolver.** The pod network is pinned
  to `NODE_IP`'s interface, and CoreDNS forwards to `UPSTREAM_DNS` (new optional
  site key), the node's resolvers, or the node's systemd-resolved on `NODE_IP`;
  before, k3s fell back to `8.8.8.8` and lookups hung.
- **Single owners, no Teknoir k3s files.** Nothing of Teknoir's lives in
  `/opt/k3s/server/manifests` any more. `coredns-custom` and the root
  Application are server-side applied by each `up`; the istio and cert-manager
  CRDs belong to their charts (Prune=false, Delete=false); ArgoCD manages
  itself. The CRD gate and hand-over code is gone.
- **Keycloak realm `teknoir` as code.** Clients (`teknoir`, `argocd`, `harbor`,
  `user-controller`), scopes, the `admin` group and the initial `platform-admin`
  come from a realm import; issuers are `https://auth.<domain>/auth/realms/teknoir`.
  The master realm keeps only the admin, whose password is generated in the
  cluster: the published default password is gone. The manual Keycloak and
  Harbor UI steps of the old runbook are gone too.
- **Harbor.** The `teknoir` chart project is public on the LAN: no robot account,
  no repository credential. Charts are immutable; images are pushed by digest.
  Harbor's token certificate comes from a Secret, so ArgoCD no longer rolls
  harbor-core on every sync.
- **Backstage and user-controller** ship enabled; `teknoir-airgap admin-user`
  creates the first admin; istiod and oauth2-proxy trust the platform CA.
- **Operations.** An automatic backup before every converge that changes the
  deployed bundle, `teknoir-airgap backup` (age-encrypted copy), explicit
  `rotate`, `status`,
  `doctor`, `trust`, release record with a downgrade guard and `--rollback`.
- **Docs.** `docs/airgap/` (BUILD, HOST-SETUP, OPERATE, this CHANGELOG) replaces
  `docs/AIRGAP-HOST-SETUP.md`, `AIRGAP-BOOTSTRAP.md` and `AIRGAP-UPDATE.md` and
  ships in every bundle. Removed with it: `airgap/upload-bundle.sh` (replaced
  by the payload sync of `up`), `airgap/extract-kubeconfig.sh` (`teknoir-airgap
  kubeconfig`), and the stale `.air/` and `.junie/` plans.

Known limits of this release: one node only (agent join is prepared, not
built); teamspace creation needs per-teamspace charts that are not mirrored yet;
Teknoir image tags are still mutable (the build records digests and warns);
bundles are checked by sha256, not signed; requests to public CDNs (fonts,
`hls.js`, picsum) fail offline by design.

### Why the redesign

A review of the 0.1.0 tooling (2026-10-08) found, among others:

- Secrets were generated on the build machine and shipped in plaintext in the
  bundle. A copy of the 0.1.0 bundle on the node held the CA private key and the
  Harbor and Keycloak secrets at mode 0644. The old runbook's claim that "the
  private key never leaves `.secrets/ca/`" was false.
- The secret generators were not idempotent: a re-run created a new Harbor
  `secretKey`, a new Keycloak database password and, from an empty directory, a
  new CA. Four of them printed secrets.
- The Keycloak master admin used a default password published in the gitops
  repository; the `admin` group maps to ArgoCD and Harbor admin.
- The bundle could not find itself, needed python3, kubectl and crane on the LAN
  host, was 8.1 GB of multi-arch images with no outer checksum.
- A first install took about 41 commands plus about 40 Keycloak and Harbor UI
  clicks; an update 4 to 5 ordered commands, a typed admin password and a
  version that had to equal the pin, and a robot credential file carried by hand.
- Secrets, CRDs, namespaces, ArgoCD and the root Application were k3s
  auto-deploy files. k3s re-applies them on every start and garbage-collects
  objects removed from a file, whatever ArgoCD's Prune=false says; it also
  reverted secret rotations.
- Failures did not converge: restart decisions came from the current run only,
  and kubectl, ssh or sudo errors were read as "absent".
- No time sync on the node, no backups, no secrets encryption, a DHCP host-setup
  runbook for a static address, and `StrictHostKeyChecking=accept-new`.
- Images were pulled by tag without digests; Keycloak and the controllers used
  floating tags with `pullPolicy: Always`.

## 2026-10-08: tooling 0.1.0, last of the old model

- One canonical k3s manifest file per object (`00-teknoir-namespaces.yaml`,
  `00-teknoir-istio-crds.yaml`, `05-teknoir-certmanager-crds.yaml`,
  `teknoir-argo.yaml`, `teknoir-app-of-apps.yaml`, `teknoir-<name>.yaml` for
  secrets), with legacy duplicates (`10-teknoir-argo.yaml`, `app-of-apps.yaml`,
  `manifest-*-secret.yaml`) moved to `/opt/k3s/server/manifests-retired/`. Two
  files with the same objects had fought: a stale copy once reverted the Harbor
  robot token, and the app-of-apps sync freeze had to be applied twice.
- ArgoCD (argo chart 0.0.2) manages the controller and monitoring CRDs. The
  hand-over from an ArgoCD that excluded CRDs needed istio 0.0.2 (no CRDs) live
  first, a gate that refused otherwise, and a re-run of the automated syncs that
  had failed meanwhile (`failed to discover server resources for group version
  monitoring.coreos.com/v1` on `monitoring` and `user-controller`).
- app-of-apps 0.0.3 with automated sync: controllers 0.0.83, istio 0.0.2,
  monitoring 0.0.4, harbor 0.0.5 and auth 0.0.3 rebuilt from their restored
  sources.
- `robot$argocd` with a credential that was never rotated implicitly
  (`--rotate-robot` only), stored in a file the operator carried between bundle
  directories.
- Image collection also reads images passed as container arguments (the
  prometheus-operator config reloader), and the build failed on a missing image.
- Chart versions pinned, released once and never overwritten in Harbor.

## 2026-09-14: overwritten app-of-apps 0.0.1 and 0.0.2

The Harbor copies of app-of-apps 0.0.1 and 0.0.2 were overwritten. Both now pin
harbor 0.0.8 (Harbor 2.15.2: a one-way database migration, with images that are
not mirrored) and auth 0.0.6/0.0.7 (oauth2-proxy v7.15.4, not mirrored). Since
Harbor is ArgoCD's only chart source, a broken Harbor cannot be repaired from the
cluster. These two versions are refused forever, also as a rollback target, and
the `teknoir` project got tag immutability. Bundles built before 2026-10-08 must
never be run: their `--update` recreated `app-of-apps.yaml` at 0.0.2 with
automated sync, re-applied Harbor 2.15.2 over ArgoCD's Harbor, overwrote the
issued wildcard certificate with the bootstrap placeholder and re-added a stale
Harbor credential.

## 2026-09-15: CA trust

The local Root CA and the `teknoir-root-ca-bundle` Secrets (`teknoir-auth`,
`teknoir-system`) for oauth2-proxy and Harbor OIDC; ArgoCD's repo-server and
OIDC got the CA at render time.

## 2026-09-08/09: first airgap tooling

Bundle build (`make-bundle.sh`, charts, images, k3s), `bootstrap-airgap.sh`
(Istio, then ArgoCD, then Harbor, then app-of-apps), `push-to-harbor.sh`, the
local CA and secret generators, `upload-bundle.sh`, image-import waits, and the
crane, helm and ArgoCD OCI TLS fixes. Design choices of that time, still valid:

- Istio is part of the bootstrap tier, because Harbor and ArgoCD are reachable
  only through the Istio ingress gateway, which terminates TLS with a
  `*.<domain>` wildcard certificate signed by the local CA.
- Name resolution is solved twice: `/etc/hosts` on the node (containerd, host
  tools) and the k3s CoreDNS `coredns-custom` import (pods). Istio only routes.
- Harbor mirrors docker.io, ghcr.io, gcr.io, quay.io and registry.k8s.io as the
  projects `dockerhub`, `ghcr`, `gcr`, `quay` and `k8s`, wired into containerd
  with `/etc/rancher/k3s/registries.yaml`.

## 2026-02 to 2026-04: infra charts

Staged infra Helm charts (`infra-stage-*`: Istio gateways, Keycloak,
oauth2-proxy, Harbor, monitoring) for the online environments. On 2026-04-21 all
platform charts moved to `platform-applications-gitops`, leaving infra with the
GitOps bootstrap only.

## Problems solved along the way

- **Istio gateways in `ImagePullBackOff` while Harbor was empty.** The gateway
  pods use the image `auto`, which the API server treats as `:latest` with
  `imagePullPolicy: Always`, and the injected proxy copied that policy, so every
  start pulled `proxyv2` from Harbor even though it was imported into
  containerd. Fixed by rendering the gateways and sidecars with
  `imagePullPolicy: IfNotPresent` (gitops istio values).
- **ArgoCD UI: "Request has been terminated".** Mutating actions failed because
  the user lacked the `admin` group (ArgoCD answered `403`), and the
  oauth2-proxy lua filter on the gateway turned that `403` into a cross-origin
  redirect the UI cannot follow. The lua change that limits the rewrite to page
  navigations exists in auth 0.0.7, which needs the unmirrored oauth2-proxy
  v7.15.4; auth 0.0.8 does not carry it, so the group membership is the fix.
- **user-controller `CreateContainerConfigError`** (2026-10-08): the Secret
  `backstage-keycloak-secrets` was missing. The redesign creates it from
  platform-secrets (realm `teknoir`, client `user-controller`).
- **istiod `x509: certificate signed by unknown authority`** when fetching JWKS
  from Keycloak: istiod did not trust the local CA. istio 0.0.3 mounts the CA as
  `/cacerts/extra.pem`, which istiod reads at start (restart istiod if the CA
  ever changes).
- **ArgoCD's Redis image** comes from `docker.io/library/redis`, because the
  upstream default on `public.ecr.aws` is not mirrored.
