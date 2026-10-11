# Airgap changelog and history

What changed in the airgapped `teknoir-local` tooling, and why. The runbooks
([OPERATE.md](OPERATE.md), [HOST-SETUP.md](HOST-SETUP.md), [BUILD.md](BUILD.md))
describe only the current procedure; past procedures, incidents and the
reasons for the redesign are kept here. The git history of `infra` and
`platform-applications-gitops` (branch `teknoir-local`) is the full archive.

## 2026-10-11: profile plugin charts 0.0.101

- **Profile plugin charts 0.0.101** are pinned in the bundle (pins for 0.0.99 and
  0.0.100 stay for rollback bundles). EMQX 5 now serves the platform certificate
  on the TLS listener 8883 (the EMQX 4 `EMQX_LISTENER__SSL__*` env names were
  ignored by emqx 5.8.9, so it served the built-in self-signed "EMQ RootCA"), and
  the max packet size uses `EMQX_MQTT__MAX_PACKET_SIZE=3MB`.
- **backstage-api waits for Postgres** (gitops 926b0b4, 9f3eafc): an initContainer, so it no
  longer starts before its database after a node reboot and stays unready. The
  first version ran `pg_isready` as uid 1000, which has no passwd entry in the postgres
  image, so it answered "no attempt" on every try and always waited the full 10 min;
  9f3eafc passes `-U backstage -d postgres`.
- **jwks-watch recreates istiod when its JWKS fetch stays failed** (istio chart 0.0.4).
  After a node reboot istiod could fetch the Keycloak JWKS while Keycloak was still
  starting; it drops a failed fetch from its cache and does not retry it until the next
  full push of the configuration (no timer: `PILOT_JWT_PUB_KEY_REFRESH_INTERVAL` does not
  apply to it). Every sign-in then got 401 "Jwt verification fails" although all pods were
  Ready, until something else changed a Service or Gateway. Found when the backstage-api
  wait stopped hiding it (the 10 min delay had covered the window). The `jwks-watch`
  Deployment in istio-system watches istiod's `pilot_jwks_resolver_network_fetch_*`
  counters and deletes the istiod pod once (proxies keep their configuration meanwhile)
  when a fetch failed and every `jwksUri` answers again.

## 2026-10-11: live node decommissioned, the VM rig moves to the dev host

- **Live teknoir-local node decommissioned.** `192.168.5.181`: k3s removed, data
  archived on that machine in `/opt/teknoir-local.decommissioned-20261011T110224Z`.
  The hardware is now the dev host (`teknoir.airgapped`, `192.168.2.181`).
  teknoir-local is verified only in the VM rig (`airgap/test/vm/`); the
  `teknoir-local` branches stay the release branches for customer installs, and
  `site/teknoir-local.env` stays the reference site file (header comment only).
- **The rig operator host is the dev host** (it was vpro). The rig scripts changed
  for it, with no change to the VM or the platform:
  - `lan-netns.sh`: the host is called `teknoir.airgapped`, the platform domain, so
    the namespace hosts file no longer gets `127.0.1.1 <host name>` (the domain
    would have resolved to loopback first); `up` and `status` check that every
    platform name resolves to `NODE_IP` only inside the namespace.
  - `vm.sh net-up`: Docker re-inserts its FORWARD jumps at the top whenever its
    daemon starts, so the bridge DROP rules are kept ahead of them (`lan-netns.sh
    up` keeps its accept rule ahead of the DROPs). The VM may ping `10.77.0.1`
    but reaches no host service (INPUT drop); IPv6 is off on the bridge and tap.
    New `net-down` and `ram-check`.
  - `vm.sh start` and `e2e.sh` refuse to boot the VM when MemAvailable is below
    `VM_MEM_MB` (default 10240) plus 2048 MiB, instead of an OOM kill; `e2e.sh`
    also checks sudo, KVM and the bridge subnet up front.
- **Profile plugin charts 0.0.100** are pinned in the bundle (deadend 0.0.100 runs
  its tls-terminator from `ghcr.io/teknoir/stunnel` instead of `apk add stunnel`);
  the 0.0.99 pins stay so a rollback bundle still builds.

## r5 (app-of-apps 0.0.5)

### Controllers: least privilege, admission policies, teknoir-default (gitops)

- **No controller is cluster-admin any more.** Before r5, user-controller and
  profile-controller were bound to `cluster-admin`, so either one could read
  every Secret, exec into any pod and grant itself anything.
  user-controller 0.0.85 and profile-controller 0.0.84 have their own
  ClusterRoles with only what they use. They can bind only `teknoir-admin`,
  `teknoir-edit` and `teknoir-view`. Neither can create ClusterRoles,
  ClusterRoleBindings, Roles or pods, or exec into a pod. ArgoCD prunes the
  old `cluster-admin` bindings and profile-controller's unused
  leader-election Role on the first sync.
- **Temporary passwords leave the User status.** user-controller writes a
  new user's temporary password to the Secret `user-initial-password-<User>`
  in the new namespace `teknoir-user-credentials`, before it sets the password
  in Keycloak. The Secret lasts 72 h, or until the user sets their own
  password. The controller no longer writes the password to
  `status.set_initial_password`. Its only Secret access is get, create,
  update and delete in that namespace (no list, no watch). The namespace has
  `Prune=false,Delete=false` and Pod Security `restricted`.
- **Admission policies keep both controllers inside the teamspaces.** Their
  RBAC still has to allow RoleBindings and Istio policies in every namespace,
  because teamspaces appear at run time. profile-controller also writes
  Applications and AppProjects in `teknoir-system`. RBAC cannot say "only in
  a teamspace", so three ValidatingAdmissionPolicies do:
  `user-controller-teamspace-access`, `profile-controller-teamspaces` and
  `profile-controller-argocd`. Each has `failurePolicy: Fail` and a binding
  with `Deny`. They refuse these writes from the two ServiceAccounts:
  - a write outside a namespace that a Profile owns;
  - a RoleBinding to any other role, or to a `system:` subject;
  - a change to an Application or AppProject that no teamspace Profile owns,
    such as the platform's projects `teknoir-local` and `default` and their
    Applications;
  - a teamspace AppProject or Application wider than the teamspace: it may
    use only the plugin chart repository, deploy only into the teamspace,
    and include no cluster-scoped kinds.

  The policies apply to no one else: people, ArgoCD and the other
  controllers are not affected. A denial shows in the controller log as
  `... is forbidden: ValidatingAdmissionPolicy '<policy>' with binding
  '<binding>' denied request: ...`. OPERATE.md (r5) has the break-glass.
- **Teamspaces install from Harbor.** The ConfigMap `profile-controller-config`
  now sets the plugin chart repository `harbor.teknoir.airgapped/teknoir`, the
  version `0.0.100` and the issuer
  `https://auth.teknoir.airgapped/auth/realms/teknoir`. The JWKS URL is left
  unset, so it defaults to the issuer's `/protocol/openid-connect/certs`.
  Before, teamspace Applications pointed at teknoir.github.io, and the
  teamspace RequestAuthentication trusted realm `master` on
  `auth.teknoir.online`. The r5 profile-controller also limits each
  teamspace AppProject to that repository, with no cluster-scoped kinds.
- **The default teamspace `teknoir-default` is declared in GitOps.** The
  profile-controller chart renders the Profile `teknoir-default` with owner
  `anders.aslund@teknoir.ai` and `Prune=false,Delete=false`, and
  profile-controller gives it its 9 default plugins. Before, a teamspace
  existed only when someone created it in Backstage.
- **Controller images pinned by digest.** device-, devstudio- and
  notebook-controller 0.0.84 pin the images they already ran under floating
  tags: `sha-9780e409`, `sha-4ec934c4` and `sha-c751073b`.
  user-controller 0.0.85 and profile-controller 0.0.84 pin their r5 builds.
  Each pin is the linux/amd64 digest, with `IfNotPresent`.
- The platform AppProject allows the namespace `teknoir-user-credentials` and
  the kinds `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding`.

### auth 0.0.9: legacy master clients, platform-admin, sign-in (gitops)

- **The legacy master-realm clients are deleted.** Before the redesign the
  platform clients `teknoir`, `argocd` and `harbor` lived in realm `master`.
  The migration moved them to realm `teknoir` and left the old ones in place.
  The legacy `teknoir` client's service account has master-realm
  `manage-users`, which is enough to reset the master admin's password, and its
  secret is the one oauth2-proxy uses. On its first sync, auth 0.0.9's
  PostSync Job deletes the three clients and their service-account users from
  realm `master`. It deletes each one only when realm `teknoir` has a client
  with the same clientId, and never touches a built-in client. The deletion is
  irreversible except from a backup, so take the encrypted backup first
  (OPERATE.md, "r5 (app-of-apps 0.0.5)"). After the deletion,
  `migrate --undo` can no longer give a working old layout.
- **platform-admin is disabled.** The realm import now creates `platform-admin`
  disabled, and every sync of `auth` disables it again. On a fresh install the
  first admin comes from `teknoir-airgap admin-user`, whose group `admin` gives
  ArgoCD, Harbor and Backstage. The master admin (`keycloak-admin`) stays the
  Keycloak break-glass.
- **Every denied request ends at the sign-in page.** On the HTTPS listener, a
  request that oauth2-proxy denies is now redirected to `/oauth2/start` when it
  is a page load, and the stale session cookie is expired. A fetch, XHR or
  websocket request gets a plain `401` instead. Before, a request with a stale
  or garbage cookie got a bare `403`. A backend's own `401` or `403` for a
  signed-in user passes through unchanged, so ArgoCD's `403` for a non-admin
  is no longer turned into a redirect.
- **Sign-out and profile.** Client `teknoir` allows the post-logout redirect to
  `https://teknoir.airgapped/...`, so signing out returns to the platform.
  Keycloak's VERIFY_PROFILE required action is off, so a user without a last
  name (user-controller sets none) no longer gets the Update Profile form at
  the first sign-in.
- **Images pinned by digest.** keycloak-theme `sha-29d2ed6a` (was `latest`),
  keycloak-db `postgres:16.15` (was `16`), oauth2-proxy-redis
  `redis:7.2.16-alpine` (was `7.2-alpine`) and httpbin (was `latest`), each by
  its linux/amd64 digest, all `IfNotPresent`.
- The update restarts `keycloak-0`, `keycloak-db-0` and `oauth2-proxy-redis-0`
  once, with the same image content and no database migration. Keycloak is
  away for 1-2 minutes, every session is dropped, and everyone signs in again.

### Bundle: teamspace plugins, node packages, pinned images

- **Teamspaces work offline.** The bundle carries the 9 teamspace plugin
  charts profile-controller deploys by default (profile-plugin-* 0.0.99, the
  published archives, pinned by sha256) and their ~20 images (~1.8 GiB). The
  node pushes the charts to `harbor.<domain>/teknoir` with the other charts;
  profile-controller reads them from there (its `PLUGIN_CHART_REPO`). Before,
  a teamspace's Applications pointed at teknoir.github.io and stayed
  `Unknown`.
- **Time packages.** chrony and util-linux-extra (hwclock) ship as pinned
  `.deb` files in `node/debs`; the node has no NTP egress and no hwclock
  today.
- **Pinned Teknoir images (G-09).** The build fails on a Teknoir image that is
  not `<repo>:<immutable tag>@sha256:<linux/amd64 manifest>`, on a pinned
  index, and on a digest in a one-shot tier; the teamspace plugin images on
  `:latest` only warn (listed in `MANIFEST.yaml`). The node refuses a pin that
  is not the bundle's manifest and verifies the pinned manifest in Harbor
  after the push; the post check looks the pinned manifest up in Harbor and
  containerd. `airgap/build/pin-images.sh` prints and verifies pins.
- **Size.** A bundle is about 5.8 GB; the limit is 6.5 GiB. Use exFAT or ext4
  media, or `make-bundle.sh --split` for FAT32.
- **Rollback.** To roll back from r5, run `up --rollback` with the retained
  0.0.4 bundle, not a rebuild. The rollback is not clean: 0.0.4 does not
  prune r5's kept objects, so its post phase fails on `user-controller`, and
  nobody has rehearsed it. OPERATE.md ("Rolling back from r5") explains how to
  confirm it.

### Node time, RTC, teamspace DNS and site keys

Found on the live node on 2026-10-09: no chrony and no `hwclock` were
installed; systemd-timesyncd had not reached an NTP server since 2026-09-08
(the gateway blocks NTP egress); the clock lost 118 s in 30.65 days (about
-3.85 s a day), and each `up` only refused or, with `--sync-clock`, set the
system clock: skews below 30 s were never corrected and the RTC was never
written (93 s behind), so a reboot would have started the node outside `up`'s
30 s window. Inside the cluster, teamspace names such as
`mqtt-teknoir-default.teknoir.airgapped` did not resolve.

- chrony and util-linux-extra ship in the bundle (`node/debs`) and the host
  phase installs them offline, behind an apt simulate that allows nothing but
  those two and the removal of systemd-timesyncd (else a WARN; the converge
  goes on). apt sees only the bundle's `.deb` files, not the node's package
  lists: on the live node, whose lists offer the same versions, apt would
  otherwise plan a download and fail offline. The install runs without
  `--no-download`, with which apt 3.0 removed systemd-timesyncd and then
  failed on the local `.deb` files (found by the new real-apt test,
  `airgap/test/node/packages-test.sh`).
- chrony serves NTP to the LAN from a local stratum-10 reference; every `up`
  gives it the LAN host's time (`chronyc settime`). It learns the drift only
  from samples at least 12 h apart (a re-run drops the earlier sample first:
  two samples a minute apart taught chrony 4.6.1 a rate error of 16455 ppm),
  and `maxdrift 100` caps the rate it may learn. `TIME_SOURCE` takes a list of
  servers.
- Clock policy: up to 2 s nothing, up to 30 s corrected by `up` itself (a node
  behind is stepped forward, a node ahead is slewed back by chrony, never
  stepped back without the flag; a refused `date -u -s` is a WARN), more only
  with `--sync-clock`; `up` writes the RTC when it is more than 2 s off. The
  age of `--lan-time` is measured on a clock that setting the time does not
  move, so preflight's own correction no longer skews the host phase's sample.
- `status` and `doctor` report chrony, the RTC offset, `TIME_SOURCE` in use and
  whether `NODE_IP` is a DHCP lease (new site key `NODE_IP_DHCP_RESERVED`; the
  live node keeps its address through a UniFi reservation).
- coredns-custom answers every `<name>.<domain>` (one label) with `NODE_IP`, so
  every teamspace's MQTT, deadend and EMQX dashboard names resolve in the
  cluster.
- New optional site keys, checked by the build, the node and the LAN tool:
  `NODE_IP_DHCP_RESERVED` and `BACKUP_AGE_RECIPIENTS` (age public keys for the
  encrypted backups); `TIME_SOURCE` entries must be IPv4 addresses or host
  names. An age private key pasted into the site file is refused without
  being printed ("treat that identity as exposed"); other bad recipients are
  named by their first 8 characters.
- HOST-SETUP no longer installs chrony from the DVD, no longer suggests
  `timedatectl set-time` (refused while NTP is active), describes the
  cloud-image network layout of the live node, and has new sections on the
  fixed address and on name resolution for devices.

- **Inotify limits (found in the VM e2e).** On a fresh node the teamspace pods'
  istio-proxy aborted (`inotify_fd_ >= 0`) because Debian keeps
  `fs.inotify.max_user_instances=128`. The host phase now manages
  `/etc/sysctl.d/teknoir.inotify.conf` (1024 instances, 524288 watches; the
  live node's hand-made file of that name is adopted) before k3s starts, and
  runs `sysctl --system` when the file changed or a running value is lower.

### Encrypted backups and the ArgoCD break-glass

- **Backups encrypted on the node.** New optional site key
  `BACKUP_AGE_RECIPIENTS` (age public keys). With it every node backup is also
  encrypted to those keys in `/var/lib/teknoir-airgap/exports/<ts>.tar.age`, and
  the node keeps the 3 newest encrypted backups but only the newest unencrypted
  one (older ones are encrypted before they are removed). Before, the node kept
  3 unencrypted sets, and old copies piled up in `/root`.
- **`teknoir-airgap backup --out DIR` without a terminal.** With recipients the
  node encrypts and the LAN host only copies (sha256-checked, 0600); no
  passphrase, no plaintext export. `--name TS` copies an existing backup.
  Without recipients the passphrase flow is unchanged.
- **`rotate argocd-admin`.** A new ArgoCD local admin password in
  `teknoir-system/argocd-admin-break-glass` (read by `credentials argocd-admin`,
  included in backups); `argocd-initial-admin-secret` is deleted once the new
  password logs in. `rotate argocd-admin --out FILE` writes it to a 0600 file.
- **One-time clean-up runbook** (OPERATE.md, r5): encrypted backup first, then
  the plaintext copies on the node and on vpro, the world-readable cloud-init
  seed, finalize and rotations. The pre-migration set is streamed and verified
  before the deployed payload's `--take`, which runs with `BACKUP_KEEP=99` so
  that it prunes nothing; every stream fails on a failed `tar` (`pipefail`).
  The node unit tests run these blocks against the deployed 0.0.4 payload.
- vpro: `~/.config/teknoir/install-devtools.sh` installs `age` and `age-keygen`
  v1.3.1 (sha256-pinned) for decryption.
- **One recipient check.** The build, the node and the LAN tool check
  `BACKUP_AGE_RECIPIENTS` with the same function; an age private key pasted
  there (or anywhere in a site file, for the build) is refused as such and
  never printed, so it reaches no log or build output.

### Post phase, failed syncs and migrate --finalize (infra)

- **The post phase waits for the platform only.** Since 2026-10-09 06:30 the
  live cluster has 9 Applications of the teamspace `teknoir-demo`, created in
  Backstage, whose chart repository (`teknoir.github.io`) is unreachable
  offline. The 0.0.4 tooling waited for every Application, so the next `up`
  would have failed after 20 minutes. Now `up` waits for the root and the
  Applications it tracks, and for teamspaces declared in GitOps
  (`teknoir-default`); other Applications are reported in a `WARN`. For such a
  teamspace it also waits until the profile-controller has created its
  Applications, so a controller that cannot create them fails `up` instead of
  passing with an empty teamspace. An update that creates such a teamspace
  (r5 creates `teknoir-default`) waits 45 minutes instead of 20, because its
  first chart syncs come on top of the platform's own restarts. A failed sync
  of a teamspace Application is not re-synced by post; its reason says to sync
  it in the ArgoCD UI, since re-running `up` alone would never clear it.
- **A failed sync is no longer missed or left behind.** On 2026-10-08
  `monitoring`'s first sync failed while its 1-replica Prometheus had no ready
  pod; ArgoCD spent its 5 retries, then never retried that revision. The
  Application still showed Synced and Healthy, so `up` passed, the PostSync hook
  never ran and both admission webhooks kept an empty `caBundle` (PrometheusRule
  validation silently off), with self-heal off. A manual retry at 05:40 failed
  in 22 ms: it set `.operation` alone, so the controller resumed the stale
  failed state and the spent retry count. Now a failed last sync of the current
  revision counts as not ready, and post re-syncs such a platform Application
  once per run, setting the operation and clearing the old state in one patch,
  as ArgoCD's own API does. The troubleshooting command in OPERATE does the same.
  Post re-syncs only a failure of the version the Application stays at: right
  after r5 pins `monitoring` 0.0.5, its 0.0.4 failure is left to the new
  version's own sync.
- **Secrets left over from the migration.** Post removes the Keycloak admin's
  `previous-password` once the current password logs in (it was removed by hand
  on live). `migrate` retires files with mode 0600, and `migrate --finalize`
  shreds `manifests-retired` (the CA key and the old secrets) once the migration
  is accepted. It refuses without an encrypted backup taken after the migration.
- **`migrate --argo` reported false "no owner" warnings.** ArgoCD 3.5 writes no
  tracking annotation on CRDs, so the argoproj CRDs looked ownerless although
  the `argo` Application lists them as Synced; `argocd-tls-certs-cm` belongs to
  the converge. The k3d test passed only because it annotated the CRDs by hand.
  The check now reads the Application's status.

### admin-user

- **The temporary password is handed out once.** `admin-user` reads it from
  user-controller's short-lived Secret
  `teknoir-user-credentials/user-initial-password-<name>` (or, with an older
  user-controller, from the User's `status.set_initial_password`), writes it to
  the `--out` file (0600, checked by sha256), then deletes the Secret or the
  status field. Before, the password stayed in the User object, where anyone
  who can read Users could see it, and every re-run wrote it out again.
- **`--out` is never overwritten.** A file that exists and is not empty is
  refused; with nothing on record no file is written, and the warning names
  `--reset-password`. The LAN tool keeps the password when the node fails
  after the handover (for example on a catalog timeout).
- **`--reset-password`** (explicit only, needs `--out`) sets a new temporary
  password through the Keycloak admin API (`temporary: true`). The file is
  written first and removed again if Keycloak refuses.
- **Teamspace owner.** `admin-user` adds ClaimSet `owner` on every teamspace
  whose Profile names the address as owner (`teknoir-default`; `--teamspace
  NAME` limits it) and waits for user-controller's RoleBinding. An existing User
  now gets missing owner claims; before, it was never touched.
- **No Backstage restart.** The restart never made the catalog read the user
  earlier: Backstage's scheduler keeps min(stored, now + cadence) as the next
  run. `admin-user` now waits until the catalog lists `user:default/<name>`
  as a member of each of its teamspaces (`group:<teamspace>/<teamspace>` in
  `memberOf`, which the provider adds only on its next run after the owner
  claim; read-only query on backstage-postgres-0, `ADMIN_CATALOG_TIMEOUT`,
  default 240 s); backstage chart 0.0.84 runs the user and profile providers
  every minute. Sign out and in again after `admin-user` has finished.

### VM end-to-end test

The VM test (`airgap/test/vm/e2e.sh`) covers the r5 changes before they reach the
live node.

- **New scenarios.** E11 checks the default teamspace `teknoir-default`. E12 checks
  node time: the bundled chrony, skew correction, `up --sync-clock`, the RTC, a
  reboot, SNTP from the LAN and `doctor`. E13 checks access and credentials: a
  non-admin realm user against Grafana, Prometheus, Alertmanager, ArgoCD and Harbor;
  the disabled platform-admin; controller RBAC; the encrypted LAN backup; and
  `rotate argocd-admin` and `keycloak-db`. E14 checks sign-in robustness: a garbage
  cookie, XHR 401, http to https, upstream 401/403 passthrough and the logout
  chain. E15 rehearses the live rollout: the old layout, bundle A, the injected
  live state, then bundle B. The injected state includes the master-realm legacy
  clients that the live node got by hand; before B they must exist and answer,
  so their deletion is really rehearsed.
- E13 also checks that the non-admin's temporary-password Secret is deleted after
  its first sign-in. A reconcile is started with an annotation, so the deletion
  does not fall into E2's no-change window. E2 tolerates only such K1 deletions
  in teknoir-user-credentials.
- **Extended scenarios.**
  - E1: every platform operation Succeeded, the admission caBundle, the digest
    pins, post's image check, `/oauth2/start`, the one-time password handover, no
    Update Profile form, Backstage identity within 3 minutes, no backstage-api
    restart.
  - E2: teknoir-default is not synced again, its Secrets keep their
    resourceVersions, and profile-controller does not restart.
  - E1 with a pre-r5 bundle (app-of-apps below 0.0.5, the upgrade run's A) is a
    baseline: the r5-only checks warn instead of failing (`E2E_E1_BASELINE`).
  - E4: the same release checks after the update, and A's legacy password field
    cleared. `E2E_E4_APPS=auto` derives the expected Applications from the pins.
    The rollback from r5 to a pre-r5 A meets an open design gap (DESIGN.md).
    `E2E_E4_ROLLBACK=1` runs it and asserts each part; `=0` waives it on purpose.
    Left at auto, E4 fails, because a rollback that was not rehearsed is not
    green.
  - E7: the passwords the LAN side holds and the test age identities appear in no
    log.
  - E8: the pre-rotation cookie gets a login redirect.
  - E10: no "no owner" warning, then `migrate --finalize`.
- The first admin of a VM run is the owner of Profile teknoir-default.
- `kc-login.sh` gains the options `--cookie-jar`, `--forbid-profile-form`,
  `--session-cookie`, `--accept-status` and `--logout`.
- `vmtest.env` has two test age recipients. Their identities stay on vpro
  (`vm.sh age-key`). The VM network stays static.

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
