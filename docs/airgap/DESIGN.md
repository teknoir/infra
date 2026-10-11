# Airgap redesign — design contract

Status: APPROVED DESIGN for the `airgap-redesign` branches (infra + platform-applications-gitops),
2026-10-08. This file is the contract every implementer works against. When the
implementation differs, update this file in the same commit.

## Decisions (owner: Anders Åslund, 2026-10-08)

| # | Decision |
|---|---|
| D1 | **Keep the current live CA** on teknoir-local (no re-issue). New installs: the node generates a name-constrained CA (permitted DNS: `<domain>`, `.<domain>`) in-cluster, create-if-absent; the CA key never travels in a bundle. |
| D2 | **Dedicated Keycloak realm `teknoir`**, declared as code (keycloak-config-cli `docker.io/adorsys/keycloak-config-cli:6.5.1-26.5.5`, matching Keycloak 26.5.3) in the auth chart. The master realm only holds the Keycloak admin, whose password comes from an in-cluster generated Secret (`teknoir-auth/keycloak-admin`); the published `change-me` is removed. All clients (oauth2-proxy `teknoir`, `argocd`, `harbor`, `user-controller` with a service account holding realm-management manage-users/view-users/query-users) live in realm `teknoir`; their secrets come from platform-secrets (single source of truth) and are substituted into the realm import. Issuer URLs change to `https://auth.<domain>/auth/realms/teknoir` everywhere (Keycloak runs with KC_HTTP_RELATIVE_PATH=/auth) (oauth2-proxy, ArgoCD oidc.config, Harbor OIDC, istio RequestAuthentication for Backstage, user-controller `KEYCLOAK_REALM=teknoir`). |
| D3 | **Harbor `teknoir` chart project is public** (LAN-only; charts are on public GitHub anyway). No robot account, no repo-creds credential, no robot env file. Tag immutability stays on the `teknoir` project. |
| D4 | **Sequencing: redesign first.** user-controller + Backstage ship inside the redesign (app-of-apps 0.0.4). The full procedure is tested end to end in the airgapped KVM VM before the live teknoir-local is migrated. Staging (r415) gets the user-controller secret fix afterwards. |
| D5 | **Toolbox image** for in-cluster Jobs (platform-secrets, Harbor OIDC config, misc): `docker.io/alpine/k8s:1.34.11` (sh, kubectl, curl, jq). Mirrored like every other image. |
| D6 | Datastore stays sqlite for now (etcd later). New installs set `secrets-encryption: true`; the live node gets it in a later window. Time (r5): chrony and hwclock ship in the bundle (`node/debs`, installed offline by the host phase); chrony serves NTP to the LAN from a local stratum-10 reference fed by a LAN-host sample on every `up`, or from `TIME_SOURCE` when set; a node/LAN skew up to 30 s is corrected automatically (a node behind is stepped forward, one ahead is slewed by chrony), more only with `--sync-clock`; chrony learns the drift only from samples at least 12 h apart (`maxdrift 100`); `up` writes the RTC. |
| D7 | The bundle ships `kubectl` for the LAN host (linux-amd64, darwin-arm64) as a convenience; `up` itself needs only ssh, tar and sha256sum/shasum. |
| D8 | Teknoir image tags stay mutable for now (warn only); `images.lock` records digests. Immutable image tags need CI changes in the image repos (out of scope). **Superseded in r5 by G-09** (section "r5 (app-of-apps 0.0.5)"): platform charts pin `<repo>:<immutable tag>@sha256:<linux/amd64 manifest>` with the CI's existing `sha-<hex>` tags, and the build fails otherwise; only the teamspace plugin images still warn. |
| D9 | No tag immutability on the mirror projects (only on `teknoir`). |
| D10 | ArgoCD becomes **self-managed** (argo chart moves to gitops, G-07). Local admin is kept as break-glass; `argocd-initial-admin-secret` is deleted after SSO works. r5: `teknoir-node rotate argocd-admin` sets a new local admin password (bcrypt inside argocd-server, stored in `teknoir-system/argocd-admin-break-glass`, which `credentials argocd-admin` reads and every backup includes) and deletes `argocd-initial-admin-secret` after a successful login with it. |
| D11 | Multi-node: keep the `role=server|agent` parameter in the host phase, but do not implement/test agent join in this round. |
| D12 | Bundle authenticity: sha256 only for now (signing later). |
| D13 | Domain stays per env branch (`teknoir.airgapped`). The VM e2e test uses the same domain inside an isolated LAN network namespace, so vpro's real /etc/hosts and the live env are never touched. |
| D14 | Chart versions for this release (Harbor already has the older ones; never reuse a version): istio 0.0.3, cert-manager 0.0.2, auth 0.0.8, harbor 0.0.9 (from the 0.0.5 source; 0.0.8 in Harbor is the unadopted Harbor 2.15), platform-secrets 0.0.1, argo 0.0.3 (moved to gitops), backstage 0.0.83, user-controller 0.0.84, app-of-apps 0.0.4. Controllers 0.0.83 and monitoring 0.0.4 unchanged unless a work item needs them. |

## Implementation notes (integration, 2026-10-08)

Verified facts and agreed deviations that supersede the text below where they differ:

- **Issuer path**: `https://auth.<domain>/auth/realms/teknoir` (Keycloak `KC_HTTP_RELATIVE_PATH=/auth`), used by oauth2-proxy, ArgoCD `oidc.config`, the Harbor OIDC Job, istio RequestAuthentication and `admin-user`.
- **K3s Addon semantics on v1.33.5 (k3d T1–T5, T4N)**: deleting an Addon object or its file does **not** delete the objects it applied; objects are garbage-collected when a file's content changes (objects dropped from it) or when an Addon of the same name comes back with different content. Hence the migrate recipe: `.skip` guard, move the file, strip objectset labels/annotations, delete the Addon.
- **CRD adoption check**: ArgoCD v3.5.1 writes no tracking-id annotation on CRDs; "adopted" means the CRD is a Synced resource in the Application's `.status.resources`.
- **ArgoCD**: app-of-apps 0.0.4 ships the `argo` Application, so the live migration runs `migrate` (all Teknoir K3s files except `teknoir-argo`) → `up` (ArgoCD adopts argo while the K3s file is still there; the one-shot argo tier is skipped) → `migrate --argo` (detach `teknoir-argo`).
- **Secrets the charts render that are not site secrets** are allowed by the build gate: Harbor 1.18.3's chart-default internal Secrets (internal DB password `changeit`, registry credential) and argo's credential-less `argocd-repo-harbor-teknoir` repository Secret. Rotating Harbor's internal DB password is a follow-up (needs an in-database change).
- **Credentials**: `platform-admin` (realm `teknoir`, group `admin`, temporary password from `teknoir-auth/keycloak-platform-admin`, forced change at first login) is the break-glass/initial admin; `admin-user --email` creates the Backstage superadmin User CR.
- **Payload layout**: the LAN entrypoint copies `MANIFEST.yaml` next to `node/` (`/var/lib/teknoir-airgap/bundles/<id>/MANIFEST.yaml`) and the site file to `/var/lib/teknoir-airgap/site/<site>.env`; converge takes `--lan-user` (alias `--operator`).
- **Image digests**: Harbor comparisons use the linux/amd64 image config digest (old pushes left multi-arch indexes; crane rewrites docker-archive manifests); charts compare the content layer digest, then the unpacked files.
- **Size gate**: 4.5 GiB (backstage, keycloak-config-cli and the toolbox add ~650 MiB); 6.5 GiB since r5 (the teamspace plugin images add ~1.8 GiB).
- **VM e2e findings (E0/E1, 2026-10-08)**, all fixed in the converge:
  - A node with no default route made flannel fail to pick an interface (k3s crash-loop): the host phase pins `flannel-iface` to the interface that holds `NODE_IP`.
  - A node with no resolver made k3s hand CoreDNS `8.8.8.8`; every external lookup (ArgoCD repo-server's health checks among them) then hung until timeout. The host phase writes `/etc/rancher/k3s/resolv.conf`: `UPSTREAM_DNS` from the site config, else nothing when the node has its own resolvers, else systemd-resolved exposed on `NODE_IP` (`DNSStubListenerExtra`), which answers at once. A change restarts k3s and re-creates the CoreDNS pods.
  - Harbor's token service needs the token key in PKCS#1 (the traditional RSA PEM type, `openssl genrsa -traditional`); a PKCS#8 key gave HTTP 500 on every token request. The secrets phase generates PKCS#1 and replaces a PKCS#8 key (rolling core and registry).
  - Istio gateway pods created before istiod answered its injection webhook keep `image: auto` and never start; after the istio tier the converge waits for istiod and re-creates those pods.
  - The Backstage postgres StatefulSet stayed OutOfSync on client-side diff (defaulted fields); every Application, the root one included, uses `ServerSideDiff=true`.
- Known residuals: over HTTP/2 the ingress gateway resets the stream (RST_STREAM PROTOCOL_ERROR) right after ext_authz's 302 to `/oauth2/start` (`content-length: 0`), on staging and production as well; browsers tolerate it, curl does not (the e2e login uses HTTP/1.1); `grafana.<domain>` is in the hosts list but has no route (Grafana is at `/teknoir-system/grafana/`); Backstage logout hard-codes realm `master` (backstage repo `Header.tsx`, needs an image rebuild); Keycloak asks for Update Profile at first login (user-controller sets no lastName); teamspace creation needs the profile-plugins charts mirrored (out of scope; r5 carries them).

## r5 (app-of-apps 0.0.5)

Changes of release r5 that supersede the text below where they differ. Each
work package adds its own subsection.

### Bundle supply: teamspace plugins, node packages, pinned images

- **Teamspaces are in scope.** profile-controller creates one ArgoCD Application per plugin and Profile at run time, so app-of-apps never renders them. The bundle therefore carries the published archives of the plugins the controller enables by default (`PROFILE_PLUGIN_CHARTS`: deadend, emqx, prometheus, jwks, fleet-metrics, grafana, mongodb, historian, observatory), byte for byte from teknoir.github.io/profile-plugins-helm, each pinned by sha256 (equal to the gh-pages index digest). Postgres and claims are disabled by default and are not carried; airgap Profiles must not enable them or set another version.
- **One source of truth for repo and version.** The build reads `PLUGIN_CHART_REPO` and `PLUGIN_CHART_VERSION` from the ConfigMap `profile-controller-config` in the profile-controller render (contract K2) and refuses anything but `harbor.<domain>/teknoir` and an exact version, so the bundle and the controller cannot disagree. Each plugin becomes an `apps.jsonl` line `{app: teamspace-<plugin>, chart: profile-plugin-<plugin>, version, namespace: <first GitOps Profile, else teknoir-default>, release: <plugin>, overrides: {values: "domain: <domain>"}, deployed: false}` (contract K8), so pins.txt, the Harbor chart push, the renders (`teamspace-<plugin>.yaml`) and the image collection cover the plugins with no special case. The make-bundle gate re-checks the repo, every plugin archive against its pin and every plugin image against images.lock; `MANIFEST.yaml` lists the plugin pins (`teamspacePlugins`).
- **Accepted limitations in r5:** the plugin charts list 11 `ghcr.io/teknoir/*:latest` images and `alpine:latest` (warned, listed as `teamspace_mutable_images`, locked by digest in images.lock), `imagePullSecrets: ghcr-token` and Google Cloud Storage settings (the internet-reference gate only warns for `teamspace-*` renders), and Grafana's plugin installer calls grafana.com (non-fatal). A plugin chart release with pinned images is the follow-up.
- **Node packages.** `NODE_DEBS` (chrony, util-linux-extra) ship as `node/debs/*.deb` with `debs.lock` lines `<pkg> <version> <arch> <sha256> <file>` (contract K8), pinned by sha256 (D12) with the snapshot.debian.org sha1 as the fallback source. The gate requires exactly `NODE_DEBS`, each file equal to its lock line and pin, and (with dpkg-deb on the build host) the package's own Package/Version/Architecture. The host phase installs them.
- **G-09 in force** for platform renders (see G-09 below); teamspace renders only warn (R3).
- **Size**: `BUNDLE_MAX_BYTES` 6.5 GiB (about 5.8 GiB measured); USB media must be exFAT/ext4 or use `--split`.
- **Rollback from r5** is `up --rollback` with the retained bundle A (app-of-apps 0.0.4, `teknoir-airgap-teknoir-local-aoa0.0.4-20261009-i8610f8d-ga8fe7af.tar`, built by the pre-r5 infra 8610f8d), kept on the USB medium next to the r5 bundle. This replaces the original r5 plan, which had the r5 build make an app-of-apps 0.0.4 bundle. The r5 build cannot rebuild 0.0.4 as a clean bundle, for two reasons. First, its profile-controller predates K2: the plugin supply gate fails unless `PROFILE_PLUGIN_CHARTS=""`, which means no teamspaces offline. Second, it has 8 Teknoir images without a G-09 pin: the build fails unless `ALLOW_MUTABLE_TEKNOIR_TAGS=1`, which makes the bundle `-mutable`. Such a rebuild, with both settings committed on a release branch, is the one documented exception to "a `-mutable` bundle never goes live". It is allowed only when bundle A is lost, and only with `--rollback` to an app-of-apps version that was already live. It pairs r5 node code with 0.0.4 charts (untested) and re-resolves the floating tags on the build day (BUILD.md "Rollback bundles").
- **The rollback from r5 to 0.0.4 is not clean, and it is not rehearsed.** E4 does not run the rollback from r5 to a pre-r5 bundle by default. A's post phase (infra 8610f8d, `RELEASE_JQ_READY`) waits for every Application in teknoir-system. It finds r5 objects that 0.0.4 neither renders nor prunes. The analysis below follows ArgoCD 3.5's comparison (`controller/state.go`): live objects that the AppProject does not permit are dropped before the diff, and an extraneous object counts as `OutOfSync` unless it carries `argocd.argoproj.io/compare-options: IgnoreExtraneous`.
  - The Namespace `teknoir-user-credentials` (user-controller 0.0.85, `Prune=false,Delete=false`) is kept. 0.0.4's AppProject whitelists core Namespaces, so the `user-controller` Application stays `OutOfSync`, and `up --rollback` exits non-zero after the 1200 s wait. The release record is already written by then, so the platform rollback itself has happened. OPERATE.md "Rolling back from r5" explains how to confirm it.
  - The Profile `teknoir-default` (`Prune=false,Delete=false`) is kept, but 0.0.4's whitelist has no `teknoir.org/Profile`, so ArgoCD drops it from the comparison. The same goes for the admission policies and their bindings, which are not in 0.0.4's whitelist either, and for the Role and RoleBinding in `teknoir-user-credentials`, which is not a 0.0.4 destination. None of these objects is pruned. The policies keep constraining the 0.0.4 controllers, which run under the same ServiceAccounts.
  - 0.0.4's profile-controller (pre-K2, hard-coded teknoir.github.io; `plugin_utils.go` updates every `Application` it renders) tries to point the teamspace Applications back at github.io, where they would be `Unknown` offline. `profile-controller-argocd` should refuse that write and leave them on Harbor. Nobody has observed this yet.
  - Candidate fix: put `IgnoreExtraneous` on the Namespace `teknoir-user-credentials` and on the GitOps Profile template (gitops charts). For the Profile it matters for a rollback between two versions that both permit Profiles, for example r6 back to r5. After that, E4 with its rollback leg switched on shows whether A's post phase passes.
- **Release branches.** `make-bundle.sh` accepts `r<N>[-name]` branches besides the env branch and `airgap-redesign*`, so the r5 bundle is built from the r5 integration branches before they are merged.

### Node time, RTC, teamspace DNS and site keys (WP-I-HOST)

Live facts this answers (2026-10-09, read-only): the node had no chrony and no
`hwclock` (util-linux-extra not installed), systemd-timesyncd's NTP queries were
blocked by the gateway, the clock lost 118 s in 30.65 days (about -3.85 s/day),
and the RTC was 93 s behind, so a reboot would have started the node outside
the 30 s window. Inside the cluster `mqtt-teknoir-default.<domain>` did not
resolve (coredns-custom knew only the platform names).

- **Packages (TIME-T2).** The bundle carries `node/debs` (chrony and
  util-linux-extra, pinned by sha256 in `node/debs/debs.lock`, built by
  WP-I-BUNDLE). The host phase installs a package only when `dpkg-query` does
  not report exactly the pinned version. apt simulates first, offline
  (`apt-get install -s --no-download`); a plan with anything but installing
  those packages and removing `systemd-timesyncd` (chrony replaces it: both
  provide `time-daemon`), or a failing simulate, is a WARN and the step is
  skipped. The converge goes on: a node on another Debian point release must
  not be blocked from a platform update. The install uses
  `DPkg::Lock::Timeout=300` (unattended-upgrades) and keeps changed conffiles.
  Both apt calls see an empty lists dir (`-o Dir::State::Lists=<scratch dir>`)
  and no binary caches, so the local `.deb` files are the only origin apt
  knows and nothing can be fetched. With the node's lists in view, a version
  that a repository also offers made apt plan the fetch from that repository,
  which `--no-download` refuses (`E: Unable to fetch some archives`, exit
  100): the live node's lists, from its install, carry both pins (review r5).
  The install itself runs without `--no-download`: with it, apt 3.0 never
  runs the file method that resolves a local `.deb`'s path and fails after
  its removals (`E: Internal Error, Pathname to install is not absolute`),
  leaving neither systemd-timesyncd nor chrony. When an install fails after
  apt removed systemd-timesyncd, the WARN says the node has no time service.
  `airgap/test/node/packages-test.sh` runs `host_packages` against Debian 13's
  apt and dpkg with no network, with and without such lists; it found the
  `--no-download` install failure, which the stub tests cannot see.
- **chrony (TIME-T3).** The drop-in `/etc/chrony/conf.d/teknoir-airgap.conf`
  holds one `server <s> iburst prefer` line per `TIME_SOURCE` entry, then
  `allow <NODE_IP network>/<prefix>`, `local stratum 10`, `manual` and
  `maxdrift 100` (the largest clock-rate correction chrony may use, 8.6 s a
  day; chrony's default is 500000 ppm). chrony
  restarts only when the drop-in changes, and is enabled and started when it
  is installed but not active. Debian's own `pool 2.debian.pool.ntp.org` line
  stays: a drop-in cannot remove it, it fails or times out on an airgap, and
  it is a valid source if egress ever opens.
- **Clock policy (TIME-T3).** Preflight compares the node with `--lan-time`
  (skew = node - LAN host): up to 2 s nothing; up to 30 s corrected by this
  run without a flag, but never by a step back: with an active chrony through
  the host-phase sample, else a node behind is stepped forward at once with
  `date -u -s` (a refused `date` is a WARN: time must not block a platform
  update) and a node ahead is left to chrony (WARN); more is refused unless
  `--sync-clock`, which steps at once in either direction (`chronyc settime` +
  `makestep`, or `date -u -s`, fatal if refused) and writes the RTC. The host
  phase gives chrony one sample per `up` (`TZ=UTC chronyc settime`) while its
  reference is LOCAL, MANU or none and no source is selected (`^*`).
  Deviations from the investigation: when the node is more than 2 s behind
  the sample, the host phase also runs `chronyc makestep`, so the correction
  applies at once instead of slewing for minutes (20 s at chrony's maximum
  slew rate takes about 4 min) and the VM e2e can assert it within 60 s; a
  node more than 2 s ahead is slewed by chrony (teknoir-node does not step a
  running node back without `--sync-clock`; chrony itself may step it under
  Debian's `makestep 1 3` in its first three updates after a start).
- **Drift learning (TIME-T3, review r5).** chrony fits a clock rate across its
  manual samples, and each sample is only good to about a second (whole
  seconds on both sides, ssh latency): with the bundled chrony 4.6.1, two
  samples 60 s apart with a 1 s error set the frequency to -16455 ppm (about
  23 minutes a day). So before each sample `clock_manual_guard` reads
  `chronyc -c manual list` and, when the newest sample is younger than 12 h
  (`CLOCK_RATE_MIN_AGE`; a re-run, a second `up` the same day) or the list
  cannot be read, runs `chronyc manual reset`: the sample then corrects the
  offset only and the rate learned so far stays. Samples at least 12 h apart
  still teach chrony the node's drift (live: about -45 ppm); a second of
  sample error over 12 h is a rate error of 23 ppm, and later samples refine
  it; chrony's list lives in memory, so a restart starts a new one, and
  the learned rate persists in the driftfile. `maxdrift 100` bounds any fit.
  `airgap/test/node/chrony-test.sh` checks the drop-in, the guard and the cap
  against chronyd 4.6.1 (`chronyd -x`, which sets no clock).
- **LAN time (review r5).** teknoir-node measures the age of `--lan-time` on
  CLOCK_BOOTTIME (`/proc/uptime`), which setting the wall clock does not move.
  bash's `SECONDS` follows the wall clock: with it, preflight's own `date`
  step went into the host phase's sample, which then stepped the node that
  far ahead again. The RTC is written
  (`hwclock --systohc --utc`) when it is more than 2 s off the system clock;
  never when `/etc/adjtime` says the RTC keeps local time. A routine sample is
  not a recorded change, so an unchanged second `up` still reports 0 changes.
- **Indirection.** `CHRONYC`, `HWCLOCK` and `DATE_BIN` (the date that sets the
  clock) can be overridden, so the sandbox tests run against stubs and never
  touch the test host's clock or packages.
- **Status and doctor (TIME-T4).** `teknoir-node status` prints
  `time: <utc> source=<LOCAL|MANU|none|name> stratum N freq X ppm ...
  NTPSynchronized=..; RTC <+-N> s; chrony <state>`. The LAN `status` adds the
  RTC offset, chrony's Reference ID, Stratum and Frequency, and whether
  `NODE_IP` is static or a DHCP lease. `doctor` reads the same facts as the ssh
  user and reports: chrony active (ok) or not (WARN); the RTC offset (ok up to
  5 s, WARN up to 30 s, FAIL above: a reboot would start the node that far
  off); with `TIME_SOURCE` set, WARN unless chrony uses one of its entries
  (`^*` or `^+`); a `dynamic` `NODE_IP` is a WARN unless the site says
  `NODE_IP_DHCP_RESERVED=yes`.
- **Teamspace DNS in the cluster (TS-C5).** coredns-custom answers the apex and
  every `<name>.<domain>` with `NODE_IP` (A) and NODATA (AAAA) from a
  `template`, so `mqtt-<ns>`, `deadend-<ns>` and `emqx-dashboard-<ns>` resolve
  for every teamspace, also ones created in Backstage later; the hosts block
  stays for the other types. Deviations from the investigation, both checked
  against CoreDNS 1.12.3 (the live version) by
  `airgap/test/node/coredns-test.sh`: CoreDNS orders its plugins at compile
  time and runs `template` before `hosts`, so `fallthrough` on hosts would only
  turn today's silent SERVFAIL for unknown names into an error log line, and
  is left out; and the template matches one label below the domain only
  (`match ^([a-z0-9-]+[.])?<domain>[.]$`, the reach of the wildcard
  certificate), so a search-path expansion such as `github.com.<domain>` keeps
  its SERVFAIL instead of resolving to the node. No k3s restart: the names are
  not in config.yaml.
- **Site keys (R9).** `TIME_SOURCE` is a space-separated list of IPv4
  addresses or host names; `NODE_IP_DHCP_RESERVED` is `yes`, `no` or empty;
  `BACKUP_AGE_RECIPIENTS` is a space-separated list of age public keys
  (`^age1[0-9a-z]{58}$`, consumed by the backup work). The build
  (`site_check`), the node (`load_site`) and the LAN tool check all three;
  `BACKUP_AGE_RECIPIENTS` through the one validator
  `site_age_recipients_check` (see the backup subsection above). None of them
  prints a recipient whole: an age private key (`AGE-SECRET-KEY-...`, any
  case) is refused with "remove it now ... and treat that identity as
  exposed", any other bad entry is named by its first 8 characters; the build
  also refuses a private key anywhere else in the site file, comments
  included.
- **Not in r5:** the `teknoir-node net` tool for a static or keep-lease netplan
  with a dead-man revert (TIME-T6). teknoir-local keeps its DHCP address,
  pinned by a UniFi reservation (HOST-SETUP "Fixed address").

### Encrypted backups and the ArgoCD break-glass (WP-I-BACKUP: SEC-C8, SEC-C9, SEC-C12)

- **Site key `BACKUP_AGE_RECIPIENTS`** (optional): space-separated age X25519
  public keys, each `^age1[0-9a-z]{58}$`; public values in the committed site
  file. One validator, `site_age_recipients_check VALUE [LABEL]`, checks it
  everywhere: the build (`site_values_check`), the node (`load_site`, and
  again in `lib/backup.sh` before a backup and for `backup --recipient`) and
  the LAN tool (`site_load`, `backup`). The three runtimes share no sourced
  code (the LAN tool is a self-contained bash 3.2 script), so the function is
  the same text in `lib/common.sh`, `teknoir-airgap` and `build/lib-build.sh`,
  and `airgap/test/unit/site-age-recipients-test.sh` fails when the copies
  differ or a caller checks the format itself. It uses case patterns only
  (bash 3.2, no locale-dependent ranges). A value holding `SECRET-KEY` (any
  case, anywhere) is refused with "holds an age PRIVATE key
  (AGE-SECRET-KEY-...) ... treat that identity as exposed" and nothing of the
  value is printed; any other bad entry is shown with at most its first 8
  characters (control and glob characters as `?`), so neither the run logs nor
  the build output ever hold a key. The build's `site_check` also refuses an
  age identity (`AGE-SECRET-KEY-1` and key characters; a comment that only
  names the prefix passes) anywhere else in a site file, a comment included.
  The message texts are WP-I-HOST's, so both packages' tests check one text.
  Decision:
  two recipients, the operator's key and an offline recovery key; no identity
  ever goes onto the node or into a repo.
- **Node backups** (I-12 superseded): with recipients, `backup_take` also writes
  `exports/<ts>.tar.age` (0600; `tar` of `backups/<ts>` piped into
  `age -r R1 -r R2 ...`; written as `.partial` and renamed). Retention:
  `BACKUP_KEEP_PLAIN` (default 1) plaintext sets and `BACKUP_KEEP` (default 3)
  encrypted exports; a plaintext set without an export is encrypted before it
  is pruned (kept when that fails). An age failure fails the backup (and so
  the converge) with the complete plaintext set in place and nothing pruned.
  Without recipients the old keep-3 plaintext rotation stays, with a warning.
  Recipients and the age binary are checked before k3s is stopped. One
  plaintext set is a deliberate trade-off: the live datastore is unencrypted
  anyway (D6), and it keeps a fast local rollback.
- **Off-node copy**: `teknoir-airgap backup --out DIR [--name TS]` uses
  `teknoir-node backup --recipient-site --take` (or `--name TS`) when the site
  has recipients: no terminal, no passphrase, the node's export is copied with
  a sha256 check into a 0600 file and stays on the node; no plaintext export
  exists. `--name` of a set pruned to its export hands that export out as it
  is. Without recipients the passphrase flow (`--export`, tty) is unchanged.
- **`rotate argocd-admin`** (D10): `random_alnum 32`; `argocd account bcrypt`
  (no `--password`: ArgoCD v3.5.1 reads it from a non-terminal stdin and
  prints `Password: <hash>`) runs in `deploy/argo-argocd-server` (container
  `server`) with the value on `kubectl exec -i` stdin, so it is in no argv (node
  or container) and no log. Order: store in `argocd-admin-break-glass` (create or merge
  patch, never apply: no last-applied annotation), merge-patch `argocd-secret`
  `admin.password` and `admin.passwordMtime` (ends older admin sessions) from a
  0600 file, then up to `ARGOCD_LOGIN_ATTEMPTS` (4) spaced logins on
  `/api/v1/session` (ArgoCD locks a user for 5 minutes after 5 failures), and
  only after a 200 delete `argocd-initial-admin-secret`. The LAN
  `rotate argocd-admin --out FILE` reads the new value back with
  `credentials argocd-admin`.
- **Runbook**: OPERATE.md "r5 (app-of-apps 0.0.5)" orders the one-time clean-up:
  verified encrypted backup first, then deleting plaintext copies (node, vpro,
  cloud-init seed mode), then finalize and rotations. Step 2 runs on the
  deployed 0.0.4 payload, whose `--take` keeps 3 sets and so would prune the
  pre-migration set: that set is streamed (`bash -o pipefail` on the node) and
  decrypted and checked (`sha256sum -c` in `/dev/shm`) first, and the take
  runs with `BACKUP_KEEP=99`, which 0.0.4 reads from the environment. Every
  stream lands as `.partial` and is renamed only on success; step 4 deletes
  the vpro `.secrets` only when the decrypted archive equals them
  (`diff -rq`). `airgap/test/node/run.sh` runs the step 2 and 4 blocks as
  written against the 0.0.4 payload (`git archive 8610f8d`) and the real age,
  including a tar that fails halfway and the plain `--take` that prunes.

### Post phase classification, failed-sync re-sync, keycloak-admin clean-up, migrate --finalize (infra lib/release.sh, lib/migrate.sh)

- **Which Applications post waits for (R2).** Platform: the root `app-of-apps`
  and every Application whose `argocd.argoproj.io/tracking-id` starts with
  `app-of-apps:` (or `<ns>_app-of-apps:`). Teamspace: an ownerReference of kind
  `Profile`; strict only when that Profile itself carries an ArgoCD tracking-id
  (declared in GitOps by the profile-controller chart, contract K3) and the
  ownerReference uid matches. Platform and strict teamspace Applications must be
  ready; all others (teamspaces created in Backstage, Applications with no
  Teknoir owner) are listed in one WARN and never block. The root must exist.
  `teknoir-node status` prints one `apps:` line per class; the table has a
  CLASS column (`*` = reported only). The same rules gate `migrate --finalize`.
- **A Profile declared in GitOps is itself waited for (TS-C6).** Its
  Applications only exist once profile-controller has reconciled it, so without
  this a Profile with none (profile-controller down, or Forbidden by its RBAC)
  or only some would add nothing to wait for. Post adds a strict entry
  `profile/<name>` that is not ready while `status.appliedconfig.lastRunStart`
  is missing ("not reconciled by profile-controller yet"), while `lastRunEnd`
  is missing or earlier ("run in progress"), while the Profile owns no
  Application (owner uid checked), or while an enabled chart plugin's
  Application is missing (profile-controller names it
  `<profile>-<pluginConfig.name>`). A plugin whose `applyStatus.status` is not
  `Success` is only reported: EMQX's fails until the EMQX pod answers its API,
  and profile-controller retries with a backoff of up to ~17 min, which would
  fail `up` on timing alone (E11 asserts every plugin `Success` on the VM).
  Profiles not declared in GitOps get the same entry, reported only. Only
  names, uids, run times and plugin kind/enabled/chart/status are read; never
  a plugin's configuration. `status` prints one `profile:` line per Profile.
- **The wait (TS-C6).** Without `--wait-timeout`, post waits
  POST_WAIT_DEFAULT (1200 s) on an update and POST_WAIT_FIRST_INSTALL (2700 s)
  on a first install. An update that creates a teamspace declared in GitOps
  gets 2700 s too, counted from the start of the wait, as soon as one poll
  sees it being created (`_release_post_creating`): a strict Profile that
  profile-controller has not run for, or whose Applications are not all
  created yet (a run in progress alone does not count), or a strict teamspace
  Application that is not ready and has an empty `status.history` (ArgoCD adds
  an entry per successful sync, so it has never synced). The r5 update creates
  `teknoir-default` this way: the root pin, the profile-controller sync, its
  reconcile and the first sync of 9 charts (MongoDB's init included) all fall
  in one `up`, next to Keycloak, Harbor and Backstage restarts, which can take
  longer than 20 min. An explicit `--wait-timeout` is never extended. The
  timeout error says that re-running `up` is safe.
- **Failed last sync (HYG-C3).** `why()` reports `last sync to <rev> <phase>:
  <message>` when `.status.operationState.phase` is Failed or Error, its
  revision (`syncResult.revision[s]`, else `operation.sync.revision[s]`) equals
  `.status.sync.revision[s]`, and no `.operation` is pending; a pending
  `.operation` is itself not ready ("requested, not started yet"), which closes
  the window between the re-sync patch and the controller picking it up. Post
  re-syncs each such *platform* Application, but only while that failure is
  about the spec the Application keeps: its own status is not stale (no
  operation pending or running, `comparedTo` equals the spec's source[s], an
  exact chart pin equals `status.sync.revision`, the root reconciled since this
  run's pin) and, for a child, the root is `Synced` with a status that is not
  stale either. Right after a pin the old revision's failure is still in the
  status (the root has not synced the new child spec yet, or ArgoCD has not
  compared the child's new spec); re-syncing it would re-apply the superseded
  chart, spend the once-per-run budget and, with the spec's retry, hold an
  operation that blocks the new revision's auto-sync. The root's own failure
  at its current pin makes the root the candidate. At most once per run
  (RELEASE_RESYNCED) with one merge patch: `metadata.resourceVersion` (the
  apiserver rejects a stale write with 409; retried at the next poll),
  `.operation` = {initiatedBy teknoir-node, sync {revision[s] it is at,
  prune = `spec.syncPolicy.automated.prune`, syncOptions from the spec}, retry =
  `spec.syncPolicy.retry` or ArgoCD's default `{limit: 5}`}, and
  `status.operationState: null`. That mirrors ArgoCD's SetAppOperation and
  auto-sync. Setting `.operation` alone makes the controller merge the new
  operation into the stale state (it writes operationState with a JSON merge
  patch and the empty fields are omitempty) and fail at once (live, 05:40).
  Dry-run records the re-sync as a would-change. Teamspace (and other)
  Applications are never re-synced (R2). ArgoCD never retries a failed
  revision either, so `why()` adds to such an Application's failed-sync reason
  that post re-syncs platform Applications only and how to sync it (ArgoCD UI,
  or the OPERATE section 12 patch). Otherwise a strict teamspace Application
  whose first sync spent its retries would fail every `up` with no way out
  named.
- **keycloak-admin `previous-password` (SEC-C10).** After the wait, post reads
  only the resourceVersion and the key names of `teknoir-auth/keycloak-admin`.
  With `previous-password` and `password` present, it logs in to realm master
  with `password` (admin-cli password grant, credentials in a curl config on a
  pipe, through the gateway on NODE_IP with the platform CA). On 200 it removes
  the key with a JSON patch whose first op tests the resourceVersion; on 400/401
  or any other status it keeps it with a WARN. Dry-run does not log in. Post
  also warns while `teknoir-system/argocd-initial-admin-secret` exists.
- **`migrate --finalize [--i-know]` (SEC-C10).** Refuses unless: no Teknoir
  K3s file or Addon is left (teknoir-argo included); every retired
  `*.yaml|*.yml|*.json` keeps `<manifests>/<name>.skip`; the post phase's
  strict Applications are ready; and `/var/lib/teknoir-airgap/exports` holds an
  age file (`age-encryption.org/v1` header) whose backup stamp (UTC in its
  name, else its mtime) is newer than the newest `manifests-retired/<UTC>` dir.
  `--i-know` waives only the export check (an encrypted copy kept off the
  node). It then shreds every retired file (symlinks are unlinked, never
  followed), removes the directories and `manifests-retired`, and logs names
  only. The `.skip` guards are never touched. New retirements are mode 0600.
- **`migrate --argo` ownership check (HYG-C6).** An object of the detached file
  is ArgoCD's when it carries the `argo` tracking-id or is a Synced entry of the
  `argo` Application's `.status.resources` (mapped to `Kind.v1.` / `Kind.group`).
  `argocd-tls-certs-cm` and objects labelled
  `app.kubernetes.io/managed-by=teknoir-node` are logged as converge-owned; only
  the rest is warned. The secrets phase now applies that label to
  `argocd-tls-certs-cm` (one label-only server-side apply on the next `up`).
- **Tests.** `airgap/test/unit/release-ready-test.sh` (classification, reasons,
  candidates, patch body, wait loop with a stub controller, keycloak clean-up,
  status lines), `airgap/test/unit/migrate-argo-untracked-test.sh`, k3d
  `run.sh T10` (the real runner's post phase against stand-in Applications and
  `stubs/fake-keycloak.py`) and `migrate-test.sh` (CRD adoption via status,
  0600 retirements, every finalize refusal and the shred). VM: E1/E10/E15 assert
  operationState Succeeded and a non-empty admission `caBundle` (WP-I-E2E).

### admin-user: one-time password handover, teamspace owner, catalog wait (SEC-C2, TS-C4, SIGN-C6)

`teknoir-node admin-user --email ADDR --out FILE [--display-name NAME] [--teamspace NAME]... [--reset-password]` (lib/admin.sh) runs these steps in this order (plan R8); each converges, so a re-run resumes:

1. Ensure the User (superadmin; an existing User only gets missing owner claims in step 4). The `--teamspace` names are checked before anything changes: each Profile must exist and be owned by the address.
2. Wait for `status.computed_status` (user-controller has created the Keycloak user), then Keycloak group `admin` (realm `teknoir`, master admin from `teknoir-auth/keycloak-admin`).
3. Password handover:
   - Source (contract K1): Secret `<ns>/user-initial-password-<name>`, key `password`, where `<ns>` is `USER_CREDENTIALS_NAMESPACE` of ConfigMap `teknoir-system/user-controller-config`, default `teknoir-user-credentials` (override `ADMIN_CREDENTIALS_NS`). Fallback for an older user-controller: `status.set_initial_password`.
   - Write: temp file next to `--out`, mode 0600 (owned by `$SUDO_USER`), rename; then the file's sha256 must equal the sha256 of the value plus a newline (computed from a builtin `printf` through a pipe; the value is never in a process's argv and never logged; it is marked for the runner's leak check).
   - Never overwrite: a non-empty `--out` is refused before the value is consumed, except when it already holds exactly that value (an interrupted earlier run). `--reset-password` checks this before step 1. An empty `--out` (the LAN tool's fresh temp file) is fine.
   - Consume: the Secret is deleted with DeleteOptions preconditions on its uid and resourceVersion (`kubectl delete --raw ... -f -`), so a Secret replaced meanwhile (a reset) is never deleted. The legacy field is removed with a JSON patch on the status subresource, `test /metadata/resourceVersion` then `remove /status/set_initial_password` (retried; no value in the patch); when the value came from the field, only while the field still has the same sha256. A legacy field next to a Secret is removed too (dead value).
   - Nothing on record (already handed out, or the user has signed in and the controller cleaned up): a warning that names `--reset-password`; `--out` is not touched; exit 0.
   - `--reset-password` (explicit only): a random 20-character password goes into a JSON body `{type: password, temporary: true, value}` in a 0600 file in the run's private scratch dir, is written to `--out` first, then `PUT /admin/realms/teknoir/users/{id}/reset-password`. A non-2xx answer shreds `--out` and fails; no answer fails with "may or may not be set". Afterwards a superseded Secret or legacy field is deleted. This password never reaches Kubernetes.
4. Teamspace owner: the Profiles with `lower(spec.owner.name) == email` (or the `--teamspace` ones). Wait until each namespace exists with annotation `owner` equal to the address (profile-controller), then add the missing `{name: owner, namespace: <profile>}` entries to `spec.claim_set` with a JSON patch guarded by `test /metadata/resourceVersion` (the whole list when `claim_set` is absent or null, else `/spec/claim_set/-` per entry), retried on conflict; then wait for RoleBinding `<profile>/user-<name>-teknoir-role-binding`. user-controller reacts only to User changes, so the claim is added after the Profile namespace exists. Only Profiles the address owns are touched; existing entries are kept.
5. Catalog wait: `kubectl exec -i backstage-postgres-0 -c postgres` runs `psql -U "$POSTGRES_USER" -d backstage_plugin_catalog` over the local socket (no credential) with the SQL on stdin; the entity ref and the groups are psql variables. The predicate is not only that `user:default/<name>` exists: sign-in takes the user's ownership refs and initial teamspace from that entity, and UserEntityProvider derives `spec.memberOf` from `spec.claim_set` only on its next run, so for an existing User (the r5 rollout, E15) the entity is there up to a minute before the new owner claims are. The query is `final_entity::jsonb -> 'spec' -> 'memberOf' ?& string_to_array(:'grps', ',')` on the row `entity_ref = :'ref' and final_entity is not null`, with `grps` = `group:<ns>/<ns>` for every teamspace of step 4 (the group E11 assertion 9 checks; empty when there is none, then the row alone counts). It runs for every listed teamspace on every run, so a re-run after a timeout also waits. Poll every WAIT_INTERVAL up to `ADMIN_CATALOG_TIMEOUT` (default 240 s); on timeout fail with a hint that says whether the user is not listed, is listed without a group (provider not run yet, or Backstage lacks the teamspace's ClaimSet `owner`: the provider warns `Claimset ... not found`), or the query failed, plus the `catalog.providers.k8s.users` schedule and the provider log. Never a restart. No StatefulSet `backstage-postgres`: a warning. Dry-run does not exec.

The LAN tool passes `--teamspace` and `--reset-password` through; `--reset-password` without `--out` is a usage error (exit 2); a non-empty `--out` is refused before the node is contacted; the node's temp file is fetched even when the runner fails, because a later step (catalog wait) can fail after the handover and that file is then the only copy.

Tests: `airgap/test/k3d/admin-user-test.sh` (stand-in controllers in K1-Secret and legacy modes, stand-in Profiles, a postgres catalog whose stand-in user provider trails every claim change, fake Keycloak with reset-password, and a kubectl wrapper that replaces the Secret or the legacy value right after admin-user read it, or changes the User right before a patch: resume, reset over a pending value, the delete preconditions, the sha256 guard and both conflict retries are covered, and so is an existing empty 0600 `--out` as node_mktemp creates it, filled by a handover and by `--reset-password` without a temp file left behind), `airgap/test/unit/admin-out-file-test.sh` (no cluster, run by run-static: the never-overwrite checks refuse only a non-empty `--out`, so a tightening to "exists" fails it), `airgap/test/bats/lan_entrypoint.bats` (admin-user flags through `--local` with a path-mapping sudo stub) and `airgap/test/lan/` (bash 3.2, real sshd).

### VM e2e additions (test plan 3)

Each run uses a freshly created VM. The VM's Harbor keeps the first push of
every version.

- Fresh: `E1 E11 E12 E13 E14 E2 E3 E7 E8` with bundle B.
- Upgrade: `E2E_BUNDLE=<A> E2E_BUNDLE_B=<B> E2E_E4_APPS=auto E2E_E4_ROLLBACK=1 e2e.sh --allow-destroy E1 E4`,
  with A = aoa0.0.4.
  - E1 installs A as a baseline. A bundle whose app-of-apps is below 0.0.5 is a baseline,
    and the r5-only E1 checks below only warn there.
  - E4 then asserts the release checks on B. It also asserts that r5 clears A's legacy
    password field.
  - `E2E_E4_APPS=auto` derives the expected changes from the two bundles' pins, plus the
    teknoir-default plugin Applications.
- Live rehearsal: E15.

Rollback from r5 to a pre-r5 bundle is an open design gap. B's GitOps Profile
teknoir-default and Namespace teknoir-user-credentials carry
Prune=false,Delete=false but no `argocd.argoproj.io/compare-options: IgnoreExtraneous`.
Once A no longer renders them, three things happen:
- profile-controller and user-controller stay OutOfSync, because a skipped prune keeps an
  Application OutOfSync;
- A's profile-controller points the teknoir-default Applications back at github.io
  (Unknown offline);
- A's post waits for every Application.

The plan's rollback, an r5-built 0.0.4 bundle, has the same problem: under R2 the kept,
tracked Profile keeps its teamspace Applications strict.

An untested rollback is not green:
- `E2E_E4_ROLLBACK=1` (the release run) runs the leg. It asserts each part separately (up
  exits 0; every Application except teknoir-default-* Synced/Healthy; profile-controller
  and user-controller Synced; Profile and Namespace kept; release record A rollback;
  revisions back), and it reports the teknoir-default Applications. Today it fails, by
  name, on the parts above.
- `E2E_E4_ROLLBACK=0` waives the leg on purpose, and the summary row says so.
- Left at auto, E4 fails when the rollback would cross r5.

The decision belongs to WP-G-CTRL, WP-I-RELEASE and WP-I-BUNDLE, before the live rollout.
One option is `argocd.argoproj.io/compare-options: IgnoreExtraneous` on the GitOps Profile
and the credentials Namespace; another is a documented rollback procedure.

The first admin is the owner of the GitOps Profile teknoir-default, so E11 can
check its grants.

- E1 adds these checks:
  - every platform Application (the root and what it tracks) has operationState
    Succeeded;
  - both monitoring-admission webhook configurations have a caBundle;
  - every digest-pinned container's imageID ends in its digest;
  - post logs "live image check: N pullable ..., 0 missing";
  - `/oauth2/start` returns 302 to auth.<domain>;
  - after admin-user, no `status.set_initial_password` and no temporary-password
    Secret remain;
  - the `--out` password signs in under `kc-login --forbid-profile-form`;
  - Backstage resolves the session to `user:default/<name>` within 3 minutes of the
    User's creation;
  - backstage-api has restartCount 0.
- E11 checks the default teamspace:
  - the Profile has Prune=false,Delete=false and a tracking-id, its owner is the
    admin, and it has no spec.plugins;
  - the namespace has its label, owner annotation and ownerReference;
  - namespaceAdmin and the user's RoleBinding both bind teknoir-admin;
  - the User has the claim owner@teknoir-default;
  - the policies, the TLS Secret (checked by name only) and the ConfigMaps exist;
  - the AppProject's sourceRepos is harbor.<domain>/teknoir only, with no cluster
    whitelist;
  - the 9 plugin Applications come from Harbor at PLUGIN_CHART_VERSION with
    RespectIgnoreDifferences=true, and are Synced/Healthy within 20 minutes;
  - every enabled plugin reports Success;
  - every pod is Ready with the sidecar, its images are local, and nothing failed
    to pull;
  - an in-pod nslookup of mqtt-teknoir-default resolves to NODE_IP;
  - TLS works on 8883 and 2222;
  - the teamspace's Grafana and Prometheus answer 200;
  - the Backstage system and the user's group membership appear (PT1M polling).
- E12 checks node time:
  - the pinned .debs are installed, timesyncd is gone, chrony is active and
    hwclock exists;
  - at -20 s, a plain up gets within 2 s in 60 s and changes no package;
  - at -400 s with the RTC also off, up exits 1 with the hint, and
    `up --sync-clock` brings both clock and RTC within 2 s;
  - after a guest reboot, the clock is within 5 s (QEMU keeps the RTC the guest
    wrote);
  - SNTP from the netns gets stratum 11 or lower and an offset within 2 s;
  - doctor reports no FAIL for the node.
- E13 checks access and credentials:
  - a non-admin realm user (a User CR with role viewer) signs in with a forced
    password change; after a reconcile its temporary-password Secret is gone (K1
    case b);
  - that user gets 403 on the teknoir-system monitoring UIs, no ArgoCD
    Applications, and 403 from Harbor project creation (not a CSRF failure);
  - the admin gets 200 and Grafana Admin by e-mail;
  - platform-admin is disabled and its login is refused;
  - the can-i matrix of rbac-k3d holds, and no "forbidden" appears in the
    controller logs;
  - keycloak-admin has no previous-password;
  - the LAN backup without a tty decrypts with each test identity, sha256sum -c
    passes, and one plaintext set remains;
  - after `rotate argocd-admin`: the initial secret is gone, the old password
    gets 401, the new one 200, and the SSO admin can still sync;
  - after `rotate keycloak-db --i-know`, sign-in still works;
  - Prometheus logs no "Error sending alerts" for 5 minutes.
- E14 checks sign-in robustness:
  - a garbage cookie gets 302 to `/oauth2/start` and two expiring Set-Cookies;
  - CORS and XHR requests get 401 without Location;
  - http gets 301 to https;
  - a signed-in API call without a Backstage token gets the upstream 401/403;
  - the logout chain ends at the login form.
- E15 rehearses the live rollout:
  - The setup is E10's old layout, migrate, up A, one admin login, migrate
    --argo and M6.
  - Then the live state is injected: Profile teknoir-demo on github.io, a stale
    Failed monitoring operation with retryCount 5, and empty admission caBundles.
  - The master-realm legacy clients are created through the master admin API,
    because neither the old layout nor A creates them (the live node got them by
    hand, old AIRGAP-BOOTSTRAP 8): teknoir, with the oauth2-proxy client's secret
    and a service account holding master-realm manage-users; argocd; and harbor.
    The teknoir service account lists master's users, which shows the severity.
    Before B, all three exist and teknoir's secret gets a token on master, so the
    check after B cannot pass on an empty realm.
  - Then up B runs, and these must hold:
    - post passes;
    - teknoir-demo moves to Harbor (a warning only if it stays unhealthy);
    - monitoring Succeeds with its caBundle;
    - the legacy field is cleared with the credential's created_date unchanged
      (read-only SQL);
    - previous-password is gone;
    - the master legacy clients are gone, and the old teknoir secret gets 401 on
      master;
    - admin-user grants owner@teknoir-default and owner@teknoir-demo and writes
      no file;
    - the E11, E13 and E14 checks pass.
- E2, E4, E7, E8 and E10 are extended as described in the CHANGELOG.

The e2e harness itself is tested without a VM (airgap/test/README.md):
`kc_login.bats` uses a local HTTPS stand-in for oauth2-proxy and Keycloak, and
`harness.bats` dry-runs E1, E4, E11, E12, all of E13, E15's injection and the whole
E15 sequence against stub worlds. Each broken part of a world fails exactly its
assertion.

### monitoring 0.0.5, argo 0.0.4, harbor 0.0.10 (WP-G-ACCESS: SEC-C5, HYG-C8)

- **Monitoring access (SEC-C5, K7).** New values `monitoring.access.issuer`
  (`https://auth.<domain>/auth/realms/teknoir`) and `monitoring.access.groups`
  (default `[admin]`).
  - `templates/requestauthentication.yaml`: one RequestAuthentication each for
    Grafana, Prometheus and Alertmanager. The issuer comes from
    `monitoring.access.issuer`, and `jwksUri` is the issuer plus
    `/protocol/openid-connect/certs` (istiod fetches it and trusts the CA
    through the istio chart). The token is read from
    `X-Auth-Request-Access-Token` or `X-Forwarded-Access-Token`, and
    `forwardOriginalToken: true` keeps it for Grafana. An invalid token gets
    `401`. Only `X-Auth-Request-Access-Token` comes from oauth2-proxy: its
    auth endpoint sets it, and the gateway passes it upstream in place of any
    value the client sent. oauth2-proxy never sets `X-Forwarded-Access-Token`
    (the plan's header list, as in the Backstage chart), so only a client
    sends it, and it passes the gateway unchanged. It counts only as a valid,
    unexpired token of realm `teknoir`, so using it needs a group-admin token
    as well as a session at the gateway. Grafana reads only
    `X-Auth-Request-Access-Token`. Dropping the second header from `jwtRules`
    would close that path; that is a plan change, left for a later release.
  - `grafana-`, `prometheus-` and `alertmanager-allow-ingress` require the
    ingress gateway's principal AND `request.auth.claims[groups]` in
    `monitoring.access.groups`. A list claim matches when any element
    matches.
  - In-namespace ALLOWs: `prometheus-allow-internal` (namespace
    `teknoir-system`: Grafana's Prometheus datasource, the operator) and the
    new `alertmanager-allow-prometheus` (principal
    `cluster.local/ns/teknoir-system/sa/monitoring-prometheus`).
  - `templates/access-check.yaml` fails the render (so ArgoCD shows a
    ComparisonError and syncs nothing) when:
    - `grafana.ini`'s issuer (`expect_claims.iss`) or JWKS URL differs from
      `monitoring.access.issuer`, or the issuer is not https;
    - `auth.jwt` is off or anonymous access is on. Both are read as Grafana
      reads booleans, so the string `"false"` counts as off and `"on"` as on;
    - `kube-prometheus-stack.namespaceOverride` is not the namespace the
      policies are rendered into;
    - an alerting endpoint is not this release's Alertmanager Service
      (namespace, name, `routePrefix` and the one `__address__` rewrite);
    - `alertmanagerSpec.replicas` is more than 1 (see alert delivery below).
- **Grafana sign-in.** `grafana.ini` `auth.jwt` reads the token from
  `X-Auth-Request-Access-Token`. The login is `preferred_username`, the
  Keycloak username: the e-mail address for users that user-controller
  creates (`admin-user` included), while a user made by hand in the Keycloak
  console keeps the username it was given. So the login is not always the
  e-mail. The e-mail is `email` (docker test G3 tells the two apart), and
  `expect_claims` pins `iss`. `auto_sign_up` is on.
  `role_attribute_path` gives group `admin` the Admin role and everyone else
  Viewer, and `role_attribute_strict` refuses a token that maps to no role.
  The role is set again from the token at every sign-in. Anonymous access and
  `users.allow_sign_up` are off. `auth.basic` stays on for the dashboard and
  datasource sidecars, and `auth.disable_login_form` stays `true` (unchanged
  from 0.0.4). So the local admin's only way in is basic auth against the
  HTTP API over a port-forward, not the browser (OPERATE.md). Update checks
  and usage reporting are off.
- **Why Grafana's `jwk_set_url` is https (a deviation from SEC-C5).** SEC-C5
  specified the in-mesh `http://keycloak-http.teknoir-auth.svc.cluster.local`
  JWKS URL. Grafana 12.4.2 refuses to start with an http `jwk_set_url`
  ("jwt_set_url must have https scheme"), so that URL would have taken Grafana
  down. Grafana therefore fetches the issuer's own
  `https://auth.<domain>/auth/realms/teknoir/protocol/openid-connect/certs`,
  the same path argocd-server's OIDC uses. This needs two things:
  - The pod must resolve `auth.<domain>` to the node: coredns-custom's hosts
    block, which TS-C5 keeps.
  - It must trust the Teknoir Root CA. Secret `teknoir-root-ca-bundle` (public
    `ca.crt`, written by the secrets phase on every run) is mounted optional
    at `/etc/teknoir/ca`, and `SSL_CERT_DIR=/etc/ssl/certs:/etc/teknoir/ca`, as
    for argocd-server.

  Go loads the trusted roots once per process, so a CA Secret that appears or
  changes after Grafana started is used only after a restart (docker test
  G11). On an install the secrets phase writes the Secret before the release
  phase creates the Applications, so Grafana starts with it; on teknoir-local
  it already exists. Without the CA, Grafana starts but no token verifies.
- **Alert delivery (found while implementing SEC-C5).** The live "Error
  sending alerts ... 503" was not an authorization denial. Read-only sidecar
  stats on teknoir-local showed every Prometheus request to Alertmanager's pod
  IP going to the PassthroughCluster in plaintext, with response flag UC, and
  no RBAC decision at Alertmanager's sidecar. The upstream chart's default
  discovers Alertmanager's pod IPs, and the sidecar does not apply mTLS to a
  bare pod IP, while Alertmanager is STRICT. `prometheusSpec.alertingEndpoints`
  keeps the same endpoint but rewrites `__address__` to
  `monitoring-alertmanager.teknoir-system.svc.cluster.local:9093`. The request
  is then routed through the mesh over mTLS as `monitoring-prometheus`, which
  `alertmanager-allow-prometheus` admits. VM E13 proves it: no "Error sending
  alerts" for 5 minutes. Every replica now gets the same Service address, so
  each batch reaches one Alertmanager replica only, and replicas do not share
  alerts. Alertmanager therefore stays at one replica (the upstream default,
  unchanged), and the render refuses more; HA needs per-pod addresses over
  mTLS first.
- **Lifecycle endpoints (found while implementing SEC-C5).** The operator
  runs Prometheus with `--web.enable-lifecycle` (read on teknoir-local), so
  POST or PUT `/teknoir-system/prometheus/-/quit` stops it and `/-/reload`
  reloads it; Alertmanager serves `/-/reload`. Both accept a simple
  cross-site POST, and the oauth2-proxy cookie is `SameSite=None`, so a page
  an admin visited could stop Prometheus through the gateway with the
  admin's token. In the mesh, `prometheus-allow-internal` and
  `harbor-allow-internal` let any teknoir-system or teknoir-auth pod do the
  same without a token. `prometheus-deny-lifecycle` and
  `alertmanager-deny-lifecycle` (selector `app.kubernetes.io/name`, no
  source condition) DENY both endpoints from every source; DENY is evaluated
  before every ALLOW, whichever chart renders it.
  - Istio matches paths without the query and after the mesh's path
    normalization, which is BASE (the istio chart sets none, unchanged in
    r5). BASE resolves dot segments and decodes encoded unreserved
    characters (`%2D`, `%71`), but keeps an encoded slash, while Prometheus
    and Alertmanager (Go) decode `%2F` before they route. A plain
    `*/-/quit` therefore let `.../prometheus/-%2Fquit` and
    `.../prometheus%2F-/quit` through, and Prometheus stopped. The paths are
    `*-/quit`, `*-%2Fquit`, `*-%2fquit` and the same for `reload`; matching
    from the `-` covers the slash before it in every spelling. A doubled or
    trailing slash gets a redirect to the clean path, which goes back
    through the sidecar.
  - The config-reloader sidecars call `http://127.0.0.1:9090/...` and
    `:9093/...` (read on teknoir-local). Loopback traffic does not pass the
    inbound sidecar, so reloads keep working, and so does a manual reload
    over a port-forward.
  - A mesh-wide `pathNormalization: DECODE_AND_MERGE_SLASHES` would close
    encoded slashes for every path-based policy. It is an istio chart change
    for a later release.
- **What "group admin only" does not cover.** The harbor chart's
  `harbor-allow-internal` has no selector, so it applies to every workload in
  teknoir-system, the monitoring stack included. It admits any mTLS source in
  teknoir-system and teknoir-auth without a token. Platform pods in those two
  namespaces can therefore use the Prometheus and Alertmanager APIs, silences
  included; teamspaces and the gateway without the groups claim cannot. Today
  Grafana's Alertmanager datasource works only through that policy.
  `charts/monitoring/tests/namespace-authz-test.sh` evaluates every policy
  that applies to the three workloads, whichever chart renders it. Planned
  for the next release, with VM tests: a selector on `harbor-allow-internal`
  plus explicit in-namespace ALLOWs for every workload that relies on it.
- **Known residual, not changed in r5.** Prometheus scrapes sidecar-injected
  pods by pod IP, so those scrapes also go to the PassthroughCluster in
  plaintext and get `503` (UC) under STRICT mTLS. The live stats show this for
  two targets. Scraping under STRICT mTLS is a wider change for a later
  release.
- **ArgoCD RBAC (argo 0.0.4, SEC-C5).** `policy.default: ""` (was
  `role:readonly`), and `policy.csv` is only `g, admin, role:admin`. The scope
  stays `[groups]`, and `admin.enabled: "true"` is now explicit. Only
  `argocd-rbac-cm` changes, which ArgoCD reloads without a restart. The plan's
  lock-out risk is covered because the admin's token carries `groups: [admin]`
  (E13 checks that the admin can sync), and the local `admin` is the
  break-glass (`argocd-admin`).
- **Harbor (harbor 0.0.10).** `oidcConfig.settings.project_creation_restriction:
  adminonly` (SEC-C5): the PostSync OIDC Job PUTs only the settings that
  differ, so on teknoir-local it PUTs only this one. HYG-C8:
  `busybox:1.36.1` in all five `fix-permissions` init containers (database,
  redis, trivy, registry and jobservice; the plan listed four). It is pinned
  by tag only, because harbor is a one-shot tier whose images the bootstrap
  imports from docker archives (G-09). `airgap/images-extra.txt` already
  carries it.
- **Tests** (gitops repo):
  - `charts/monitoring/tests/render-test.sh` M1-M11: the RequestAuthentications,
    the groups conditions, alert delivery and the one Alertmanager replica,
    the `grafana.ini` keys (the login form off included), the CA mount, every
    render guard, `istioctl validate`, and the two lifecycle DENYs (with no
    other DENY in the chart).
  - `charts/monitoring/tests/namespace-authz-test.sh` N1-N4: every policy from
    any chart that applies to the three workloads. With `--renders DIR` it
    reads `tests/render.sh --out DIR`, so render.sh's monitoring-authz check
    can use the same evaluator. It treats `prometheus-allow-internal`,
    `alertmanager-allow-prometheus` and `harbor-allow-internal` as in-mesh
    ALLOWs that admit no gateway, and ignores a DENY limited to operations
    (the lifecycle DENYs); its self-test proves both.
  - `charts/monitoring/tests/grafana-jwt-docker-test.sh` G1-G11: the chart's
    Grafana image with the rendered `grafana.ini`, a test CA in a Secret
    volume's layout and an https JWKS. It covers sign-in, Admin and Viewer
    (G3 tells the login, `preferred_username`, from the e-mail), rejected
    tokens, basic auth on the API, the login form off, TLS verification, a
    late CA needing a restart, the https rule and no secrets in the logs.
  - `charts/monitoring/tests/lifecycle-deny-docker-test.sh` L1-L5: Envoy
    from the istio chart's proxyv2 version, with BASE normalization and the
    rendered lifecycle DENYs as RBAC, in front of the chart's Prometheus and
    Alertmanager. The API stays reachable; every spelling of quit and reload
    gets `403`, or at least never a 2xx; Prometheus survives every quit probe;
    and a self-test shows that a plain `*/-/quit` lets `-%2Fquit` stop
    Prometheus.
  - `charts/argo/tests/render-test.sh` A1-A2 and
    `charts/harbor/tests/render-test.sh` H1-H3 and O1-O3 (the OIDC Job's
    script against a stub Harbor API).

  The VM e2e E13 proves the gateway path, Grafana's in-mesh JWKS fetch and
  alert delivery on a real node.

## Backstage + user-controller (folded into the redesign)

Findings that the implementation must respect (from the read-only investigation of 2026-10-08):

### Design notes

VERIFIED STATE (read-only, 2026-10-08 ~17:25)
- kubectl --context teknoir-local -n teknoir-system get applications:
  - app-of-apps 0.0.3, auth 0.0.3, istio 0.0.2, monitoring 0.0.4: Synced.
  - user-controller 0.0.83: Synced/Progressing. Pod user-controller-77c586885f-* is 1/2 CreateContainerConfigError (secret "backstage-keycloak-secrets" not found).
- CRDs users/claims/claimsets/profiles.teknoir.org exist, as do ClusterRoles teknoir-admin/edit/view and 23 Claims/ClaimSets in teknoir-system.
- No Users, no Profiles, no backstage-* Secrets, no backstage PVC. So the first generated Postgres password will be the one initdb uses.
- istiod: 36 'x509: certificate signed by unknown authority' JWKS errors in the last 30 min. istiod volumes: local-certs, istio-token, cacerts, istio-kubeconfig, istio-csr-*; no Teknoir CA.
- Keycloak: KC_HOSTNAME=auth.teknoir.airgapped is a bare hostname (no scheme), with KC_PROXY_HEADERS=xforwarded.
- oauth2-proxy v7.6.0 has no CA mount. v7.6.0 does support --provider-ca-file (oauth2-proxy v7.6.0 pkg/apis/options/legacy_options.go). It loads the CA into http.DefaultClient, per pkg/validation/options.go.
- Istio 1.29.2 reads /cacerts/extra.pem once, at JWKS-resolver creation (pilot/pkg/model/jwks_resolver.go jwksExtraRootCABundlePath). The vendored istiod chart passes istiod.volumes/volumeMounts through (istiod deployment.yaml:260,309); I rendered it with the proposed values.
- CA sources (key names only):
  - istio-system/teknoir-airgapped-wildcard-tls is kubernetes.io/tls with keys [ca.crt, tls.crt, tls.key], issuer teknoir-ca.
  - teknoir-auth/teknoir-root-ca-bundle has key [ca.crt]; it also exists in teknoir-system.
- Mesh: no outboundTrafficPolicy override (ALLOW_ANY). auth.teknoir.airgapped is in coredns-custom. No NetworkPolicy in teknoir-auth.
- ArgoCD v3.5.1 uses default (annotation) tracking, so Secrets created by Jobs are untracked: never diffed, never pruned.
- The mirrored quay.io/kiwigrid/k8s-sidecar:2.5.4 (used by Grafana) has `python` 3.14.3 on PATH (/app/.venv/bin), runs as user 65534 and has /bin/sh. I read its config from the Harbor registry API anonymously.
- Backstage authorization does NOT need a teknoir_claims token mapper. packages/backend/src/plugins/teknoir-permissions.ts:52-70 checks user.ownershipEntityRefs (catalog groups), which UserEntityProvider.ts:201-249 builds from User CR claims_v0/claim_set. This matches staging, where Keycloak users have zero attributes.
- Sign-in requirements: helpers.ts:39-58 requires an unexpired exp, email_verified and email. resolvers.ts:26-31 needs catalog user default/<User CR name>.
- The GCP entity providers are commented out (packages/backend/src/index.ts:64-73), and GCP clients are only constructed lazily in routers. So a missing admin-credentials.json does not block startup.

CHOSEN DESIGN
1) user-controller: secret supplied by an auth-chart "keycloak-client-export" CronJob. No user-controller chart or code change.
   - Source of truth: teknoir-auth/oauth2-proxy-secret[client-secret], the copy oauth2-proxy uses and which matches Keycloak.
   - Every 5 min the CronJob makes teknoir-system/backstage-keycloak-secrets equal to {KEYCLOAK_REALM=master, KEYCLOAK_CLIENTID=teknoir, KEYCLOAK_CLIENTSECRET=<source>}:
     - It creates the Secret if missing.
     - It merge-patches only those 3 keys when they differ.
     - It skips (with a warning) a target owned by a K3s auto-deploy manifest, which makes it safe to adopt later on r415.
     - After an update (not after the first create) it sets kubectl.kubernetes.io/restartedAt on Deployment user-controller.
   - The script is Python 3 stdlib only. It talks to the API server with the SA token, never prints values, and compares base64 values in memory.
   - The pod is labelled sidecar.istio.io/inject=false (it only calls the API server), runs non-root with a read-only root filesystem, and uses imagePullPolicy IfNotPresent.
   - RBAC: get on oauth2-proxy-secret (teknoir-auth). In teknoir-system: create secrets; get/patch on resourceNames [backstage-keycloak-secrets]; get/patch on deployments [user-controller].
   - Because the copy is re-synced, a rotated client secret can no longer silently 401 the controller, which is what happened on r415.
   - Why the auth chart: it owns the client and its secret, it needs a release anyway for the oauth2-proxy CA, and a later Keycloak-client reconciler would live there too.
   - Why a CronJob and not a hook: rotation of oauth2-proxy-secret never triggers an ArgoCD sync. First convergence is within 5 min; kubelet then starts the waiting pod by itself.

2) Login path, auth 0.0.8: oauth2-proxy trusts the Teknoir CA.
   - Port the caSecretName/caSecretKey template from commit 0811068 onto the 0.0.3 source: --provider-ca-file=/etc/ssl/teknoir/ca.crt plus a Secret volume teknoir-root-ca-bundle (non-optional, so a missing CA is a visible failure).
   - Keep image v7.6.0, which is already mirrored. No lua or v7.15.4 changes.
   - Version 0.0.8, because 0.0.6/0.0.7 are in Harbor (pinned by the overwritten app-of-apps 0.0.1/0.0.2) and 0.0.4/0.0.5 may be. push-to-harbor.sh keeps Harbor's copy silently (push-to-harbor.sh:401).

3) Token verification, istio 0.0.3: istiod mounts the CA.
   - istiod.volumes: secret teknoir-airgapped-wildcard-tls, items [ca.crt -> extra.pem], optional: true. istiod.volumeMounts: /cacerts, read-only.
   - cert-manager keeps that ca.crt equal to the Teknoir Local Root CA, so no PEM goes into the public repo. The istiod rollout makes it load.
   - This also fixes the existing httpbin-jwt RequestAuthentication.

4) Backstage, chart 0.0.83:
   (a) templates/secret-generator.yaml + files/secret-generator.py:
     - SA, Role, RoleBinding and ConfigMap at sync-wave -2.
     - A Job with argocd.argoproj.io/hook: Sync, hook-delete-policy BeforeHookCreation, sync-wave -1 (before workloads at wave 0).
     - Create-only: backstage-postgres-secrets {POSTGRES_USER=backstage (the probes run psql -U backstage), POSTGRES_PASSWORD=random, DATA_SOURCE_USER=backstage, DATA_SOURCE_PASS=same}, and backstage-backend-auth {backend-auth-backstage-secrets.yaml: "secret: <random>"}.
     - Existing Secrets are never touched. No ArgoCD tracking and no ownerReference, so nothing is ever pruned and the Postgres password stays stable.
   (b) deployment.yaml:91-92: keycloak secretRef gets optional: true. Backstage never reads KEYCLOAK_*; the keycloakOrg provider is commented out in app-config.yaml:187-195.
   (c) configmap-app-config.yaml:34-38: wrap integrations.github in `if .Values.backstageApi.github.enabled` (false here). Its $include made a GitHub App file mandatory. Without it Backstage falls back to an unauthenticated default github.com integration; the GitHub discovery provider only logs errors every 30 min.
   (d) values backstageApi.secrets.authSecretsName: backstage-backend-auth (the /app/secrets volume).
   (e) Optional CA mount: teknoir-root-ca-bundle, optional, at /etc/teknoir-ca, with NODE_EXTRA_CA_CERTS. This keeps externalAccess JWKS on https://auth.<domain> working, matching staging's URLs.
   - URL: https://teknoir.airgapped/ (apex VirtualService, created after the oauth2-proxy and monitoring VirtualServices, so the route order is correct).

5) app-of-apps 0.0.4: backstage.enabled=true; backstage 0.0.83, auth 0.0.8, istio 0.0.3; user-controller stays 0.0.83.

6) First user: no GitOps object. The operator applies one User CR once: superadmin, email_verified true, no claim_set, or only an existing teamspace.
   - user-controller then creates the Keycloak user with a temporary password in status.set_initial_password. Only the operator reads it. (r5: in Secret teknoir-user-credentials/user-initial-password-<name> instead, contract K1; admin-user hands it over once and deletes it.)
   - Keycloak forces a password change at first login; no SMTP is needed.

ALTERNATIVES REJECTED
- Laptop script writing a K3s addon from the live secret: not self-healing, vpro lacks .secrets, and it is the exact drift pattern broken on r415.
- user-controller code change to read a cross-namespace Secret: needs a rebuild and mirror; possible later.
- Helm lookup/randAlphaNum: ArgoCD renders with helm template, so values would regenerate every render. The harbor-core token CA shows this live.
- kubectl image: k8s/kubectl:v1.33.0 in Harbor is distroless.
- keycloak-config-cli or --import-realm: realm import skips the existing master realm; new image; and no Keycloak change is needed now.
- Dedicated least-privilege user-controller client: needs an in-cluster Keycloak admin credential. Today only the temporary admin exists, with the public 'change-me' password. Follow-up.
- istiod JWKS options: an in-cluster http jwksUri fails (istiod has no sidecar, teknoir-auth is STRICT mTLS); JWKS_RESOLVER_INSECURE_SKIP_VERIFY is weak; jwksResolverExtraRootCA puts the PEM in the public repo.
- oauth2-proxy redeem over in-cluster http: KC_HOSTNAME has no scheme, so a backchannel http request would mint iss=http://..., which fails the https issuer check.
- auth 0.0.7: needs the unmirrored oauth2-proxy v7.15.4.
- teknoir_claims mapper / unmanagedAttributePolicy: not needed, see above.
- Out of scope: TechDocs offline (docs not in the image) and the teknoir-cli client (tnctl, externalAccess).

KNOWN RESIDUALS (not blockers)
- picsum.photos and cdn.jsdelivr.net (hls.js) requests fail offline; api.github.com and GCP features are dead offline.
- Access token lifespan is 60s, the Keycloak master default and very likely the same on staging.
- Unrelated but notable: the harbor-core token CA regenerates on every ArgoCD re-render (harbor 1.18.3 core-secret.yaml genCA). Set harbor.core.secretName later.

### Adversarial review corrections (apply them)

- The runbook's bootstrap User CR must set metadata.name to the lowercased email with '@' replaced by '-at-' (for example anders.aslund-at-teknoir.ai). The plan only says 'superadmin, email_verified true'. Evidence: Backstage signs in with entityRef default/<email.replace('@','-at-')> (backstage plugins/auth-backend-module-istio-verified-jwt-provider/src/resolvers.ts:20-31; helpers.ts:62 lowercases the email). The catalog User name is the CR's metadata.name (packages/backend/src/plugins/providers/UserEntityProvider.ts:337,379). Any other CR name, for example 'superadmin', means sign-in never resolves. The name must also be a valid Backstage entity name (63 characters or fewer, so no '+'). Use user-controller origin/teknoir-cloud manifests/user_admin_anders.aslund-at-teknoir.ai.yaml as the template: claims_v0.role superadmin, email_verified true, enabled true, plugins [].
- Ordering of the first User. UserEntityProvider ingests User CRs only on its schedule: app-config.yaml:248-251 sets users frequency to 30 min, and UserEntityProvider.ts:128-150 runs it as a scheduled task. A kubectl-applied CR triggers no event. The plan applies the User CR after Backstage is already up, so sign-in fails with 'user not found in catalog' for up to 30 minutes. The browser check would fail falsely. Fix: the users.teknoir.org CRD already exists on teknoir-local, so apply the User CR BEFORE update-airgap.sh 0.0.4. user-controller reconciles it when its pod starts, and backstage-api ingests it on its first run. Otherwise, restart backstage-api once after applying the CR; the scheduler persists next-run as min(existing, now), so a restart runs the task right away. Or wait 30 minutes. **Corrected in r5:** the restart premise is wrong. @backstage/backend-defaults 0.15.2 (TaskWorker persistTask) upserts an existing task row with next_run_start_at = min(stored, now + cadence), so a restart never pulls the run forward (live: backstage-api started 05:12:29Z, the first user-provider run was at 05:36:02Z). admin-user no longer restarts Backstage; it waits until the catalog lists user:default/<name> (read-only psql on backstage-postgres-0), and backstage chart 0.0.84 runs the users and profiles providers every minute (PT1M). See "r5 (app-of-apps 0.0.5)".
- Restart logic of the keycloak-client-export script (designer charts/auth/files/keycloak-client-export.py create branch, roughly lines 62-70). It restarts Deployments only after a PATCH, never after a create. This is fine on teknoir-local today, where the pod is stuck in CreateContainerConfigError. It breaks the staging adoption plan. Removing r415's K3s manifest garbage-collects the live Secret (infra-teknoir-local airgap/lib.sh:613-615, 632: removing an Addon GCs its objects). The CronJob then re-creates the Secret, but the Running user-controller keeps its stale env and keeps getting 401. Fix: also restart restartDeployments after a 201 create. It is harmless on teknoir-local. In the staging runbook, state that deleting the manifest deletes the Secret; deploy the CronJob first, then remove the manifest, then confirm the CronJob re-created the Secret and restarted user-controller.
- Weak istiod verification. JWKS fetches are logged only at push time and in refresh bursts. On the broken cluster right now, `logs deploy/istiod --since=15m | grep -c x509` returns 0, because the last burst was at 17:29. So a zero count in a --since window is not proof. Use the new istiod pod's logs since it started (no --since), taken after the backstage RequestAuthentications exist: there must be no 'JWKS fetch failed' and no 'JWT requests will be rejected'. Treat the browser sign-in that reaches backstage-api with verified-jwt as the positive check.
- Floating tags will be re-pulled and overwritten. With backstage enabled, collect-images.sh pulls ghcr.io/teknoir/backstage:robot and backstage-app:robot fresh from ghcr. push-to-harbor.sh then crane-pushes every index entry unconditionally (push-to-harbor.sh, image loop after line 450), which overwrites Harbor's copies from 2026-09-11. The robot branch is active, so 'already in Harbor with identical digests' must be re-checked when the bundle is built, not assumed. Compare `crane digest` of the ghcr tags with Harbor's ghcr/teknoir/backstage{,-app}:robot before pushing. Better: pin digests in the teknoir-local backstage values. The same applies to ghcr.io/teknoir/keycloak-theme:latest (auth values.yaml, pullPolicy Always). A silently newer Keycloak would run a one-way DB migration on the next keycloak-0 restart.
- Check the chart versions in Harbor before building, not from the push log afterwards. push-to-harbor.sh pushes the app-of-apps 0.0.4 tag in the same run, and the tag is immutable. If backstage 0.0.83 or auth 0.0.8 were already in Harbor, app-of-apps 0.0.4 would be published with stale pins and waste a version. The existing evidence says they are free: scratchpad charts-dl/auth lists only 0.0.3, 0.0.6, 0.0.7 and an untagged artifact, and the investigation lists teknoir/backstage as 0.0.82 only. So 0.0.8 and 0.0.83 are fine, but list the tags explicitly first.
- Keep the CA trust GitOps-first. oauth2-proxy now hard-depends (non-optional) on teknoir-auth/teknoir-root-ca-bundle. That Secret is a K3s addon (owner teknoir-auth-ca-bundle-secret) generated from laptop .secrets that vpro does not have. If that addon is ever retired, oauth2-proxy cannot start, and ext_authz then fails closed on every protected vhost. The plan accepts this, but a GitOps-native source would fit the owner principles better: a small cert-manager Certificate in the auth chart (and in the backstage chart for teknoir-system) from ClusterIssuer teknoir-ca, mounting its Secret's ca.crt, the same pattern the plan already uses for istiod. At minimum, document the dependency in the AIRGAP-BOOTSTRAP §8 / §2.5 docs.
- Correct the rationale for rejecting jwksResolverExtraRootCA. A CA certificate is public, so putting the PEM in the public repo is not a secret leak. Mounting the cert-manager wildcard ca.crt is still the better choice (no duplication, follows the issuer), but say that instead. Note in AIRGAP-BOOTSTRAP that istiod reads /cacerts/extra.pem only at startup: on a fresh bootstrap, or if the CA ever changes, istiod must be restarted after the wildcard Secret has ca.crt. Today the placeholder from gen-local-ca-secret.sh:122-134 already carries ca.crt. Consider dropping optional:true so that a missing CA fails visibly.
- ArgoCD hook failures need an operator. The backstage Application template has no syncPolicy.retry. Automated syncs here run with the default retry limit of 5 (the monitoring op shows 'retried 5 times'). If backstage-secret-generator fails that many times, for example while Harbor restarts because harbor-core's genCA regenerates, ArgoCD skips auto-sync for that revision until someone syncs manually. Add retry with backoff to templates/backstage.yaml in app-of-apps 0.0.4, or add a runbook line: 'if backstage shows SyncError, run argocd app sync backstage'.
- Add runbook notes. (a) Never delete backstage-postgres-secrets while PVC data-backstage-postgres-0 exists: the generator would mint a new password, and initdb has already fixed the old one. (b) At first login, Keycloak 26 forces Update Password and probably Update Profile, because user-controller sets only firstName and the default user profile requires lastName. (c) Read status.set_initial_password only after computed_status is set.
- Scope 'Backstage works' honestly. Sign-in and the catalog will work. The superadmin will have no teamspace, though: no Profiles exist, and creating one makes profile-controller emit HelmCharts from https://teknoir.github.io/profile-controller-helm (profile-controller plugin_*.go:27-38), which is unreachable airgapped. Also, profile-, notebook- and devstudio-controller pods are 1/1 (no sidecar) with more than 5000 restarts in a STRICT-mTLS namespace. List teamspace creation and the per-teamspace charts/images as an explicit follow-up, so the rollout is not declared fully working.
- Minor reference fixes. In verify-offline.sh, the benign-pattern comment is at lines 51-56, not 45-51. The app-of-apps draft in scratchpad/designer/charts/app-of-apps is still 0.0.3 (backstage disabled, auth 0.0.3, istio 0.0.2), so it has not been drafted yet; do not copy it as is.

### How it maps onto the redesign
- The Backstage secrets (`backstage-postgres-secrets`, `backstage-backend-auth`) and `teknoir-system/backstage-keycloak-secrets` (for user-controller: `KEYCLOAK_REALM=teknoir`, `KEYCLOAK_CLIENTID=user-controller`, `KEYCLOAK_CLIENTSECRET=<random>`) are **platform-secrets entries** (G-04), not ad-hoc generator Jobs or CronJobs. The same random client secret is substituted into the realm import (G-05), so Keycloak and the consumer can never drift apart (the bug that breaks staging today).
- oauth2-proxy gets `--provider-ca-file` from the CA bundle; istiod mounts the CA as `/cacerts/extra.pem` (JWKS for RequestAuthentication). The CA-bundle Secrets are reconciled by the node secrets phase (I-07), not K3s files.
- Backstage chart 0.0.83: GitHub integration gated off, keycloak envFrom optional, `NODE_EXTRA_CA_CERTS`, issuer/JWKS of realm `teknoir`, Application retry.
- First admin user: `teknoir-airgap admin-user --email <addr>` creates the `users.teknoir.org` User CR (metadata.name = lowercased email with `@` → `-at-`, claims_v0.role superadmin, email_verified true, enabled true), ensures Keycloak group `admin` membership via the Keycloak admin API (realm `teknoir`), hands the temporary password over once into a 0600 file (never to the terminal), grants ClaimSet `owner` on the teamspaces the address owns, and waits until the Backstage catalog lists the user (r5; before, it restarted backstage-api, which did not help: see the correction above).
- Teamspace creation (profile-controller plugin charts from GitHub) is OUT OF SCOPE: Backstage sign-in and the catalog work, but creating a teamspace is a follow-up. (r5 brings it in scope: see "r5 (app-of-apps 0.0.5)".)

## Critique (what is wrong today)

RANKED CRITIQUE (the 5 reviews merged; contested points checked read-only on 2026-10-08)

1. CRITICAL: the secrets lifecycle is wrong from start to end.
   - Secrets are generated on the connected build machine.
   - They travel in plaintext inside the bundle (airgap/make-bundle.sh:89-118).
   - upload-bundle.sh copies them into the node's home directory. Verified: /home/teknoir/teknoir-airgap-bundle-0.1.0/bootstrap/secrets/ holds 6 files at mode 0644, manifest-teknoir-ca-secret.yaml among them, which contains the CA tls.key. This also contradicts AIRGAP-BOOTSTRAP.md:498.
   - Secrets then live for good as K3s auto-deploy files, and K3s re-applies those on every restart.
     - Verified: 9 teknoir-*-secret Addons (corrected 2026-10-08; the wildcard Secret is applied with kubectl) plus 8 legacy manifest-*-secret duplicates sit on the node, plus 3 orphan Addons: 10-teknoir-argo, app-of-apps and manifest-argocd-harbor-repo-secret.
     - Correction to the reviews: the canonical teknoir-*-secret files are 0644 and the legacy ones 0600. The directory is 0700.
   - The generators are not idempotent. A re-run gives Harbor a new secretKey and Keycloak a new DB password, and an empty CWD gets a new CA. Four generators also print secrets (gen-harbor-secrets.sh:50-51, gen-keycloak-db-secret.sh:41, gen-oauth2-proxy-redis-secret.sh:38, gen-oauth2-proxy-secrets.sh:34,54).
   - The built bundle holds 1 of the 10 secret manifests (verified: bootstrap/secrets contains only manifest-argocd-harbor-repo-secret.yaml). A first bootstrap from it cannot succeed, and the default-mode re-run, which the docs call safe, dies in deploy-secrets after it has already changed the node.

2. CRITICAL: the Keycloak master admin is admin/change-me.
   - The password is in the public gitops repo (charts/auth/values.yaml:41-44, verified) and the live StatefulSet runs with it.
   - Keycloak group `admin` maps to ArgoCD role:admin and to Harbor admin. The AppProject is wide open (appprojects.yaml: `*` repos, destinations and cluster resources), so this is a path to cluster-admin.
   - The CA is the online cert-manager issuer, carries no name constraints, and its key has been copied to about 6 places.

3. CRITICAL: the package is not portable or self-contained.
   - The scripts cannot find their own bundle. Verified: `bootstrap-airgap.sh --help` inside the bundle defaults to <bundle>/bundle/teknoir-airgap-bundle-0.1.0 (lib.sh:48-50).
   - Nothing puts tools/ on PATH.
   - python3, kubectl and sha256sum are required on the LAN host. On a fresh Mac, python3 is a CLT stub that needs internet.
   - crane on macOS sends the Harbor admin credentials with --insecure.
   - The output is an 8.1 GB directory of multi-arch layouts (about 2.5 GB is linux/amd64), with no outer checksum or provenance.
   - BUNDLE_VERSION is fixed at 0.1.0 (versions.env:7). An unsafe pre-fix "0.1.0" copy is still runnable on the node.

4. MAJOR: too many manual, order-dependent steps.
   - A first install takes about 41 steps, plus about 40 Keycloak/Harbor UI clicks (BOOTSTRAP §8).
   - An update takes 4-5 ordered commands, a typed admin password, a typed version that must equal the pin, and an "only if the bootstrap tier changed" judgement.
   - The robot credential file has to be carried between bundle directories by hand.
   - Durable state lives in disposable bundle directories and the CWD.

5. MAJOR: the ownership model contradicts the owner requirement.
   - Several objects are K3s-owned files: the istio and cert-manager CRDs, the namespaces (also ArgoCD-tracked, so they have two owners), all secrets, the root app-of-apps, coredns-custom and ArgoCD.
   - K3s re-applies these files on every start. A file that shrinks garbage-collects the missing objects, whatever ArgoCD's Prune=false says.
   - The design needs the excludedCRDs hack (gitops istio/values.yaml:40-56), render-time overrides (lib.sh chart_template_args), the CRD gate and hand-over (about 140 lines of lib.sh, now dead because the hand-over is finished), tracking-id pre-computation, and the canonical/legacy file-name machinery.
   - The ArgoCD CRDs lack Prune=false. Verified: applications.argoproj.io has sync-options ServerSideApply=true only.
   - The cert-manager Application has no ServerSideApply, which its 1.27 MB of CRDs need.

6. MAJOR: failures do not converge.
   - restart_needed is computed from what changed in the current run (bootstrap-airgap.sh:230-299), so a run that dies before the restart never gets it on the re-run.
   - Truncated crane pulls are skipped as "exists".
   - kubectl, ssh or sudo errors are read as "absent" (argocd_owns, node_has, remote_sha256).
   - Robot creation has a crash window between POST and PATCH.
   - Harbor's render is not deterministic (random token cert and htpasswd), so selfHeal rolls harbor-core. Verified: an automated sync rolled harbor-core to revision 10 at 2026-10-08T17:19:58Z with no revision change.

7. MAJOR: host and operations basics are missing.
   - The host-setup runbook was never run on the real node: it was built with cloud-init and netplan, its interface is enp4s0, and it has online NVIDIA apt sources.
   - NODE_IP is baked into coredns-custom at build time, so `--node-ip` is a no-op for pods.
   - DHCP in the docs contradicts the static NODE_IP. (r5: HOST-SETUP "Fixed address": static, or a router reservation; doctor warns about a lease.)
   - There is no time sync. Verified: NTPSynchronized=no. (r5: chrony and hwclock from the bundle, a LAN-time sample on every up, the RTC written; see "r5".)
   - There are no backups of the Harbor DB, the Keycloak DB, the k3s sqlite datastore or the token.
   - Secrets encryption is off.
   - The datastore is sqlite, with no join or agent path and no nodeAffinity on the hostPath PVs.
   - StrictHostKeyChecking=accept-new (lib.sh:465) breaks after a reinstall and gives a misleading error.

8. MAJOR: the supply chain is not pinned.
   - Images are pulled by tag, with no digests.
   - Keycloak and the controllers use :latest or branch tags with pullPolicy Always.
   - Mirror tags are overwritten on every push.
   - helm, crane and install.sh (from the unversioned get.k3s.io) are downloaded without verification.
   - The build cache is keyed on file presence, not version, so a version bump can silently have no effect.

9. MINOR: the docs mix about 1,370 lines of procedure with history. They make wrong claims ("the CA key never leaves .secrets/ca"). copy-cert-secret.sh (staging-only, uses the implicit kubectl context) and deploy-argo.sh (cannot run from a bundle) ship in the bundle. The .air/ and .junie/ plans are stale.

10. MINOR: the kubeconfig merge keeps stale credentials, and the context is named teknoir-airgapped instead of teknoir-local. Registry logins leave the admin credential on the laptop. Dry-run reports copies of files that are already identical.

HOW THE CONTESTED POINTS WERE DECIDED
- Where the converge runs: on the node, with the LAN host as a thin orchestrator.
  - The node already has k3s kubectl, trusts the CA, resolves harbor through /etc/hosts, and has openssl, rsync and python3. Verified on Debian 13.
  - This removes every LAN-side tool dependency except OpenSSH and tar, which ship with macOS and Linux. It also removes macOS TLS problems, and admin credentials never touch the laptop.
  - The LAN host only verifies the bundle, sends the payload over ssh, and runs one remote command.
- Where secret state lives: in the cluster (create-if-absent), not in a LAN state directory.
  - The LAN host keeps nothing it cannot re-derive.
  - Backups are explicit and encrypted.
- Harbor `teknoir` chart project: made public, like the mirror projects. That deletes the robot account, the repo-creds K3s file and the admin fallback.
- K3s auto-deploy files: zero Teknoir files in the target. The root Application pin and coredns-custom are server-side applied on every `up`.
- Delta bundles (--diff): dropped. A single-platform full bundle is about 3 GB, and Harbor pushes are already per-blob incremental.
- Site-agnostic bundle: partly adopted. NODE_IP and the node list become runtime site config. The domain stays per environment, because the gitops branch bakes it into the chart values. No gitops chart contains a node IP (verified).
- Test environment: qemu-system-x86_64 is in fact installed on vpro now. A disposable VM harness already exists at /home/anders/vmtest/vm.sh: VM tk-airgap at 10.77.0.10 on the isolated bridge tkvm0, with FORWARD DROP both ways. The test plan reuses it.

## Target operator flow

TARGET OPERATOR FLOW. There is one build command and one LAN-host command. That same LAN-host command does both bootstrap and update, and is idempotent.

A. CONNECTED BUILD MACHINE (Linux, bash 4.4 or later, internet)
   # both checkouts on branch teknoir-local, clean and pushed (the build refuses dirty trees unless --allow-dirty, which tags the bundle id "-dirty")
   cd ~/git/ai/infra-teknoir-local
   airgap/make-bundle.sh --gitops ../platform-applications-gitops-teknoir-local
   # -> dist/teknoir-airgap-teknoir-local-aoa0.0.4-20261009-i<infra7>-g<gitops7>.tar  (+ .tar.sha256)
   cp dist/teknoir-airgap-*.tar dist/teknoir-airgap-*.tar.sha256 /media/$USER/USB/

   What make-bundle does, all in a fresh staging directory:
   - fetch tools, k3s and install.sh at the pinned versions, with checksums verified;
   - package the charts pinned by APP_OF_APPS_VERSION;
   - pull every image single-platform (linux/amd64) and record ref@digest;
   - pre-render the one-shot tiers (platform-secrets, istio, harbor, and argo until it is self-managed) with zero value overrides;
   - write MANIFEST.yaml (bundle id, infra and gitops SHAs, versions, sha256 of every file, image digests);
   - run the offline-completeness gate, which fails the build if any rendered image is missing, any secret material is present, or any image is multi-arch;
   - tar the result.

B. LAN HOST (Linux or macOS, same LAN as the node, no internet; needs only the OS-provided ssh, tar and shasum/sha256sum)
   shasum -a 256 -c teknoir-airgap-<id>.tar.sha256        # Linux: sha256sum -c
   tar -xf teknoir-airgap-<id>.tar && cd teknoir-airgap-<id>
   ./teknoir-airgap up        # first install OR update; safe to re-run at any time
   ./teknoir-airgap trust     # once per LAN host: writes the /etc/hosts block and adds the CA to OS trust (sudo prompt; prints the exact commands with --print)
   ./teknoir-airgap status    # read-only: node, k3s, Applications, Harbor, cert expiry, clock skew, deployed bundle

   `up` reads site/teknoir-local.env from the bundle: domain, NODE_IP=192.168.5.181, NODE=teknoir@192.168.5.181 and the node list. Override with --site FILE or --node user@host.

   What `up` does, every step idempotent:
   - Locally, verify MANIFEST against the extracted files.
   - Run ssh preflight with ControlMaster.
     - The host key is pinned in ~/.teknoir-airgap/<site>/known_hosts. On a mismatch it prints the exact ssh-keygen -R command, or the operator passes --forget-host-key.
     - If `sudo -n true` fails, it asks once for the sudo password (tty) and installs /etc/sudoers.d/teknoir-airgap.
   - Send node/ to /var/lib/teknoir-airgap/bundles/<id>/ by content: one ssh call lists the remote sha256s, one tar stream sends only missing or different files, so an interrupted copy resumes at file granularity.
   - Run `ssh -t NODE sudo /var/lib/teknoir-airgap/bundles/<id>/bin/teknoir-node converge --site <site.env>`. Its output streams to the terminal and to /var/log/teknoir-airgap/<UTC>-converge.log on the node, and it never contains secret values.
   - Fetch the kubeconfig into ~/.kube/config as context teknoir-local, replacing stale entries, and the CA certificate into ~/.teknoir-airgap/<site>/teknoir-root-ca.crt.
   - Print a summary: what changed, the Application states and the deployed bundle id.

   teknoir-node converge phases (on the node, as root, with an flock lock; --dry-run prints the plan from read-only checks):
   0. verify: bundle sha256s on the node.
      preflight:
      - NODE_IP is one of the node's addresses;
      - free disk is above the threshold;
      - clock skew from the LAN host's time (passed as an argument) is under 30 s; otherwise fail with the fix, or set the clock with --sync-clock;
      - the bundle is not older than the release record unless --rollback (see phase 7).
   1. backup: if a cluster exists, take an automatic pre-change backup to /var/lib/teknoir-airgap/backups/<ts> (pg_dump harbor and keycloak, the k3s datastore snapshot and the token; keep the last 3).
   2. host:
      - install or upgrade k3s from node/k3s only if the version or the config.yaml hash differs;
      - write registries.yaml (mirrors to harbor.<domain>), the CA into OS and k3s trust, the managed /etc/hosts block and chrony (if installed);
      - sync the bootstrap image tarballs into /opt/k3s/agent/images, prune ones not in the bundle, and import any image missing in containerd with `k3s ctr -n k8s.io images import` (no restart);
      - restart k3s only when config.yaml or registries.yaml differs from the stamp written after the last successful restart.
   3. cluster-base:
      - server-side apply kube-system/coredns-custom, rendered with NODE_IP at run time;
      - create the namespaces if absent (labels belong to GitOps).
   4. secrets (create-if-absent, never printed):
      - the Root CA in cert-manager/teknoir-root-ca, via openssl in a root-only tmpfs, name-constrained to the domain;
      - the wildcard TLS placeholder signed by the CA;
      - the Harbor token-service TLS secret;
      - derived objects reconciled every run: argocd-tls-certs-cm and the CA-bundle copies.
   5. one-shot tiers. For platform-secrets, istio (CRDs first, wait Established), harbor and argo (until it is self-managed):
      - if the Application <name> does not exist yet, `k3s kubectl apply --server-side --field-manager=argocd-controller --force-conflicts` the bundle render, then wait for Ready. The platform-secrets Job then creates every other random secret (harbor-secret, keycloak-db, keycloak-admin, client secrets, cookie, redis, backstage).
      - if the Application exists, skip: ArgoCD owns the tier from then on (break-glass: --reapply <tier>).
   6. harbor content:
      - read the admin password from Secret harbor-secret into memory;
      - use a temporary DOCKER_CONFIG and HELM_REGISTRY_CONFIG in a 0700 mktemp directory, removed by a trap;
      - create the projects (all public; tag immutability on teknoir);
      - push charts: skip when the digest is equal, refuse when it differs;
      - push images by digest: skip when present, refuse to move a mirror tag to a different digest without --force-images.
   7. root:
      - server-side apply the root Application app-of-apps at the bundle's APP_OF_APPS_VERSION;
      - write ConfigMap teknoir-system/teknoir-airgap-release (bundle id, manifest sha256, infra and gitops SHAs, app-of-apps version, time, operator);
      - refuse an older bundle unless --rollback.
   8. post:
      - wait until every Application is Synced/Healthy (timeout, then per-app report);
      - run the live image check: every running image resolvable from Harbor or containerd;
      - prune old bundle payloads on the node, keeping the current and the previous one.

C. FIRST INSTALL ONLY (fresh hardware)
   1. Install Debian 13 from the offline ISO as HOST-SETUP.md describes: hostname teknoir, static IP equal to NODE_IP, user teknoir, "SSH server" plus "standard system utilities" only, no network mirror.
   2. On the LAN host: ssh-copy-id -i ~/.ssh/id_ed25519.pub teknoir@192.168.5.181
   3. ./teknoir-airgap up   (asks once for the sudo password)
   4. ./teknoir-airgap trust
   5. ./teknoir-airgap admin-user --email <your address> --out ~/teknoir-admin.txt   (the temporary password goes to a 0600 file, never to the screen)
   This is the first admin path (see "How it maps onto the redesign"): a superadmin User CR, which user-controller turns into a Keycloak user of realm `teknoir`, put into group admin. There is no platform-admin user and no keycloak-platform-admin Secret. Then sign in at https://teknoir.airgapped; Keycloak forces a password change. Add the other human users.
   That is 5 operator steps after the OS install. The Keycloak clients, scopes, groups and Harbor OIDC are created by GitOps, so BOOTSTRAP §8 disappears.

D. UPDATE
   Build (A), carry, then `./teknoir-airgap up`. Nothing else: secrets, node files, Harbor content, the pin and legacy clean-up are all converged.
   Rollback: `./teknoir-airgap up --rollback` with the older bundle. It is refused for versions in the broken list, and it is recorded in the release ConfigMap so the next plain `up` with that bundle does not roll forward unexpectedly.

E. OTHER COMMANDS (all thin wrappers over teknoir-node)
   - ./teknoir-airgap backup --out DIR: an age-encrypted copy of the latest node backup, passphrase prompted. A restore is documented in OPERATE.md.
   - ./teknoir-airgap rotate <secret>: explicit rotation for one secret, with the dependent rollouts.
   - ./teknoir-airgap kubeconfig
   - ./teknoir-airgap doctor: checks LAN-host name resolution, CA trust, ssh and clock.
   - ./teknoir-airgap up --local: when the bundle was copied onto the node itself, run on the node as root, with no ssh hop.

## Target ownership

OWNERSHIP AFTER BOOTSTRAP: every object has exactly one owner. There are zero Teknoir files in /opt/k3s/server/manifests.

1. Node OS: owned by `teknoir-node converge`, host phase. Each file is written only when its content hash differs; k3s restarts only on a config.yaml or registries.yaml change.
   - k3s binary and install: K3S_VERSION, data-dir /opt/k3s.
   - /etc/rancher/k3s/config.yaml:
     - disable traefik, tls-san;
     - secrets-encryption: true;
     - cluster-init: true (if the etcd decision is accepted);
     - etcd-snapshot schedule.
   - /etc/rancher/k3s/registries.yaml: mirrors docker.io, ghcr.io, gcr.io, quay.io and registry.k8s.io to harbor.<domain>, with the CA file.
   - CA certificate: in /usr/local/share/ca-certificates (update-ca-certificates runs every time, which is cheap) and in the k3s path.
   - Managed /etc/hosts block: every TEKNOIR_HOSTNAME resolves to NODE_IP.
   - chrony: node1 serves time on the LAN, or uses the decided source.
   - Bootstrap image tarballs in /opt/k3s/agent/images: exactly the bundle's set; stale ones are pruned.
   - For agent nodes: the same function with role=agent, reading the token from the server.

2. Cluster objects the bootstrap re-applies on every `up`: server-side apply, field manager teknoir-bootstrap.
   - kube-system/coredns-custom: NODE_IP is substituted at run time.
   - The root Application teknoir-system/app-of-apps: the pin comes from the bundle, or the recorded rollback pin.
   - ConfigMap teknoir-system/teknoir-airgap-release: the release record.
   - Derived trust objects, recomputed from the CA Secret each run:
     - teknoir-system/argocd-tls-certs-cm entry for harbor.<domain>;
     - CA-bundle copies in teknoir-auth and teknoir-system, which hold only the public certificate.

3. Created once, never overwritten. Only `rotate <name>` replaces one.
   - By the node (needs openssl):
     - cert-manager/teknoir-root-ca: the CA, name-constrained for new installs;
     - the istio-system wildcard TLS placeholder: cert-manager replaces it on first issuance;
     - teknoir-system/harbor-token-service TLS, referenced by harbor core.secretName, which makes Harbor's render deterministic.
   - By the platform-secrets chart's ensure Job: every random secret.
     - The specs live in gitops charts/platform-secrets/values.yaml.
     - The bootstrap applies that chart once, before Harbor. ArgoCD runs the same Job as a Sync hook afterwards, so a new secret is a gitops change only.
     - The Secrets: harbor-secret, keycloak-db-secret, keycloak-admin, keycloak-client-secrets, the oauth2-proxy-secret client and cookie, oauth2-proxy-redis-secret, the argocd and harbor OIDC client secrets, and backstage-keycloak-secrets.
   - The generated Secrets carry no ArgoCD tracking, so no Application can prune them. They are not K3s files, so no restart reverts a rotation.

4. One-shot apply, then adopted by ArgoCD.
   - Tiers: platform-secrets, istio including its 14 CRDs, harbor, and argo including its CRDs (after G-07).
   - The bootstrap applies the bundle render server-side as field manager argocd-controller, only while the Application does not exist. Its render equals ArgoCD's render, because no value overrides are passed.
   - From then on, ArgoCD alone owns them.
   - Break-glass: `--reapply <tier>`.

5. ArgoCD (GitOps, Applications in charts/app-of-apps, each with retry, sync-waves, ServerSideApply and no resources-finalizer).
   - istio: vendored CRDs annotated Prune=false,Delete=false.
   - cert-manager: vendored CRDs annotated Prune=false,Delete=false, the ClusterIssuer teknoir-ca and the wildcard Certificate, which moves here from the istio chart.
   - harbor: ignoreDifferences plus RespectIgnoreDifferences for the htpasswd Secret and the checksum annotations, and a PostSync OIDC-config Job.
   - auth: Keycloak admin from a Secret, and realm-as-code through a keycloak-config-cli Job (clients, scopes, mappers, the admin group). The first human admin comes from `teknoir-airgap admin-user`, not from the realm import.
   - monitoring, the controllers and backstage.
   - platform-secrets.
   - argo: ArgoCD self-managed once the CA is mounted from a Secret instead of rendered in.
   - Namespaces: owned by the GitOps charts that already track and label them. The bootstrap only does `kubectl create` when one is absent.

6. Harbor content: pushed by converge phase 6, with charts immutable and images digest-checked. No robot accounts. ArgoCD reads the public `teknoir` project without credentials, through a repository Secret declared in the argo chart with no username or password.

7. K3s manifests directory: only K3s's own packaged addons. Every retired Teknoir name has a `<name>.yaml.skip` guard, so an old bundle can never re-create a Teknoir file.

8. LAN host: nothing durable is required. ~/.teknoir-airgap/<site>/ is a re-derivable cache: the pinned known_hosts, the CA certificate, the ssh ControlPath and logs. The kubeconfig goes to ~/.kube/config as context teknoir-local. The operator keeps their own ssh key and the encrypted backups.

9. infra repo after the change:
   - airgap/build/: make-bundle.sh, collect-charts.sh, collect-images.sh, fetch-tools.sh, lib-build.sh
   - airgap/node/: bin/teknoir-node; lib for host, secrets, oneshot, harbor, release, backup, and migrate (temporary)
   - airgap/teknoir-airgap: the LAN entrypoint
   - airgap/site/teknoir-local.env
   - airgap/versions.env
   - airgap/test/
   - docs/airgap/
   There are no charts (after G-07) and no secret generators.

## Package format

ONE FILE: teknoir-airgap-<bundleId>.tar plus teknoir-airgap-<bundleId>.tar.sha256, with an optional .tar.sig (see the open decision on signing).

- bundleId = <env>-aoa<APP_OF_APPS_VERSION>-<YYYYMMDD>-i<infra short SHA>-g<gitops short SHA>[-dirty], for example teknoir-local-aoa0.0.4-20261009-i1a2b3c4-g5d6e7f8. It replaces the fixed BUNDLE_VERSION.
- The tar is plain (uncompressed): image layers are already gzip and the k3s images already zstd.
- The tar is split into 3900m pieces with `--split` only for FAT32 media.
- Target size is about 3 GB (today 8.1 GB): images are single-platform linux/amd64, and bootstrap-tier images are stored once.

Layout inside teknoir-airgap-<bundleId>/:
  teknoir-airgap                LAN entrypoint (bash 3.2 compatible; uses only ssh, tar, sha256sum or shasum, mktemp; works from any CWD; finds its bundle via its own path)
  MANIFEST.yaml                 bundleId, env, domain, createdAt, infraCommit, gitopsCommit, dirty flag, appOfApps, k3sVersion, platforms, broken app-of-apps list, the sha256 of EVERY file (unlisted files fail verify), and the image ref -> digest map
  site/teknoir-local.env        default site config (public, committed): TEKNOIR_DOMAIN, NODE_IP, NODE (ssh target), NODES list with roles, TEKNOIR_HOSTNAMES, TIME_SOURCE, UPSTREAM_DNS, NODE_IP_DHCP_RESERVED, BACKUP_AGE_RECIPIENTS
  docs/                         BUILD.md, HOST-SETUP.md, OPERATE.md (bootstrap, update, rollback, backup and restore, rotate, troubleshooting), CHANGELOG.md, readable offline
  tools/linux-amd64/kubectl, tools/darwin-arm64/kubectl, tools/darwin-amd64/kubectl
                                operator convenience only; `up` does not need them
  node/                         the payload sent to /var/lib/teknoir-airgap/bundles/<bundleId>/ on the node
    bin/teknoir-node            node converge (bash, runs as root)
    bin/helm, bin/crane, bin/jq, bin/age   linux-amd64, sha256-verified at build
    lib/*.sh
    k3s/k3s, k3s/k3s-airgap-images-amd64.tar.zst, k3s/install.sh (pinned to raw.githubusercontent.com/k3s-io/k3s/<K3S_VERSION>/install.sh), k3s/sha256sum-amd64.txt
    templates/                  coredns-custom.yaml.tmpl and registries.yaml.tmpl (NODE_IP and domain substituted at run time); root app-of-apps Application template
    oneshot/platform-secrets.yaml, oneshot/istio-crds.yaml, oneshot/istio.yaml, oneshot/harbor.yaml, oneshot/argo.yaml
                                pre-rendered from the bundled charts with zero overrides; contain no Secrets with data (one exception: the credential-less ArgoCD repository Secret, see "NOT in the bundle") and no node IP
    bootstrap-images/*.tar      single-platform docker archives of the bootstrap tier (istio, harbor, argocd, redis, pause, the platform-secrets Job image), used both for the containerd import and for the crane push to Harbor
    charts/*.tgz, charts/pins.txt
    images/<ref-slug>/          one OCI layout per non-bootstrap image, single platform, written atomically at build (.tmp then mv), no hardlinks
    images/images.lock          ref@sha256 lines

NOT in the bundle:
- any Secret, private key, password or robot credential. The build gate (make-bundle.sh step 6a, render-oneshot.sh) checks:
  - PEM private key headers in every plain file of the tree; "PRIVATE KEY" and its base64 forms in the plain-text config (oneshot, templates, site, pins, images.lock);
  - inside every chart .tgz (gzip, invisible to a tree-wide grep; compressed members such as kube-prometheus-stack's crds.bz2 are unpacked first) and in every Application render: credential-like file names (`*.key`, `*.pem`, `id_rsa*`, `kubeconfig*`, `*credentials*`, ...; inside a chart, manifest templates such as argo-cd's `templates/.../repository-credentials-secret.yaml` may carry those words), PEM private key blocks (a BEGIN ... PRIVATE KEY header followed by a base64 body line, also when commented out or escaped on one line, so the upstream documentation examples a PEM key header followed by a literal \n (a documentation example) in the argo-cd and redis-ha values pass) and base64-encoded keys;
  - kind: Secret with data/stringData: fatal in the one-shot tiers, a warning in the other renders (ArgoCD applies those from the chart);
  - known literal default credentials.
  One exception, by design (D3): an ArgoCD repository Secret (label `argocd.argoproj.io/secret-type: repository` or `repo-creds`) whose data/stringData keys are all in {url, type, name, enableOCI, project, insecure} and whose decoded url is `harbor.<domain>/<HARBOR_CHART_PROJECT>` (optionally with `oci://`). It tells ArgoCD where the public chart project is and holds no credential; the argo chart renders it as `teknoir-system/argocd-repo-harbor-teknoir`. Any other key (username, password, sshPrivateKey, tlsClientCert*, githubApp*, bearerToken, ...), another url, or a Secret without that label still fails. The gate prints key names only, never values (not even a non-matching url);
- per-site mutable state;
- python;
- scripts for other environments (copy-cert-secret.sh, deploy-argo.sh).

Integrity, in three layers, each fatal:
1. The operator runs `shasum -c` on the tar.
2. The entrypoint verifies MANIFEST.yaml against the extracted tree before any ssh.
3. teknoir-node verifies the sha256s again on the node before any mutation. It also checks k3s against sha256sum-amd64.txt before installing.

LAN host support:
- Linux amd64/arm64 and macOS arm64/amd64: only OS-provided tools are needed.
- Windows: only through WSL2.

## Migration of the live teknoir-local

LIVE MIGRATION OF teknoir-local TO THE TARGET MODEL
Every step is idempotent. Each step's verification is a read-only command. Always pass --context teknoir-local.

M0. PREREQUISITES. Do not touch the live env until all of these hold.
- The k3d ownership suite passes: T2, T4, T5, T6 and T9 in the test plan, run on rancher/k3s:v1.33.5-k3s1, which is the live version.
- The VM migration rehearsal E10 passes: an old-style install on the VM is migrated, then k3s restarts, and nothing is lost.
- The gitops releases are built and in the new bundle, not deployed: istio 0.0.3, cert-manager 0.0.2, platform-secrets 0.0.1, auth with realm-as-code, harbor with core.secretName/OIDC Job/ignoreDifferences, and app-of-apps 0.0.4 pinning them.
- The auth realm import was generated from a read-only export of the live realm (kcadm get), so that its first run is a no-op on the existing clients.
- The platform-secrets spec names the existing live Secrets and keys exactly (oauth2-proxy-secret, argocd-keycloak-secret, keycloak-db-secret, harbor-secret and so on). They are then adopted, not regenerated.
- A maintenance window is agreed.

M1. IMMEDIATE HYGIENE (L-01; can happen now, before any code).
- Rotate the Keycloak master admin:
  1. Create Secret teknoir-auth/keycloak-admin with a random password (openssl rand inside a subshell, never echoed).
  2. Run kcadm.sh set-password inside keycloak-0. Feed the new password over stdin, not argv.
  3. Verify: an anonymous token request with admin/change-me returns 401. kubectl exec, using curl against the master realm token endpoint, prints only the status code.
- Delete /home/teknoir/teknoir-airgap-bundle-0.1.0 on the node. It holds the CA key and Harbor/Keycloak secrets at mode 0644, and is an unsafe pre-fix bundle.
- Wipe any USB stick or laptop copy of bundle/*/bootstrap/secrets.
- Move vpro's infra-teknoir-local/.secrets into an encrypted backup before deleting it. It may hold the only offline CA key.
- Decide on the CA re-issue (open decision).

M2. BACKUP (automatic in the new `up`; done explicitly here):
  ./teknoir-airgap backup --out /media/usb/teknoir-local-premigration
  - pg_dump of harbor-database and keycloak-db through kubectl exec.
  - `systemctl stop k3s` (pods keep running), then copy /opt/k3s/server/{db,token,tls,cred}, then `systemctl start k3s`.
  - Copy /opt/teknoir hostPath data, since Harbor's registry blobs can be re-pushed from the bundle.
  - Snapshot baseline counts to a file:
    kubectl --context teknoir-local get crd -o name | sort
    kubectl --context teknoir-local get ns,secrets -A --no-headers | wc -l
    kubectl --context teknoir-local get virtualservices,gateways,destinationrules,authorizationpolicies,peerauthentications,certificates,clusterissuers,applications -A --no-headers | wc -l

M3. DETACH K3S FILES: `./teknoir-airgap migrate --dry-run`, review, then `./teknoir-airgap migrate`.
For each name, in this order:
  a. Orphan Addons whose file is already gone: 10-teknoir-argo, app-of-apps, manifest-argocd-harbor-repo-secret.
  b. The 8 legacy manifest-*-secret files.
  c. The 10 canonical teknoir-*-secret files (including teknoir-argocd-harbor-repo-secret).
  d. 00-teknoir-namespaces.
  e. teknoir-coredns-custom and teknoir-app-of-apps.
  f. 00-teknoir-istio-crds and 05-teknoir-certmanager-crds.
  g. teknoir-argo is NOT in this pass; it is migrated in M7a (`migrate --argo`).
Recipe per name:
  (1) Create /opt/k3s/server/manifests/<name>.yaml.skip.
  (2) Move <name>.yaml to /opt/k3s/server/manifests-retired/<UTC>/. Never truncate or edit it.
  (3) For every GVK in the Addon's addon.k3s.cattle.io/gvks annotation, select the objects with label objectset.rio.cattle.io/hash=<addon hash>. Remove that label and the annotations objectset.rio.cattle.io/{applied,id,owner-gvk,owner-name,owner-namespace}.
  (4) Delete the Addon object.
Assert after every name: the object counts equal the baseline. Before the first change, migrate records one baseline for the whole run: kind, namespace, name and UID of every object of every Addon in the run, plus the counts of namespaces, Secrets per namespace, CRDs, applications.argoproj.io and the M2 istio and cert-manager kinds (virtualservices, gateways, destinationrules, authorizationpolicies, peerauthentications, certificates, clusterissuers). After every name, every baseline object must still exist with the same UID and every count must be unchanged; the first lost or re-created object, or changed count, stops the run with the undo command. So an earlier step that deletes or re-creates an object of a later name is caught, which a per-name check cannot see. The baseline goes to the log as names and counts only. A re-run takes a new baseline, so investigate a stop first.
Never use the k3s `disable:` list. It deletes the objects.
Undo: `migrate --undo <name>` removes the .skip and restores the file with a fresh mtime (content unchanged). K3s then re-applies it and re-labels the objects. The fresh mtime matters: K3s's deploy watcher skips a file whose mtime it has already seen since its last start (k3s pkg/deploy/controller.go keeps a per-path modTime map and never prunes it), so a file put back with `mv` alone is ignored after an earlier detach and undo of the same name.
Verify:
  kubectl --context teknoir-local get addons -n kube-system   # only K3s packaged addons, plus teknoir-argo
  kubectl --context teknoir-local get crd,ns,secrets -A -l objectset.rio.cattle.io/hash --no-headers   # only K3s's own (coredns, metrics-server, ...), none of Teknoir's
  ssh teknoir@teknoir.airgapped sudo ls /opt/k3s/server/manifests   # no teknoir *.yaml except teknoir-argo.yaml; .skip files present

M4. CONVERGE WITH THE NEW BUNDLE: ./teknoir-airgap up
Expected effects:
- Node files are re-asserted: chrony, registries.yaml, CA, hosts and the tarball prune of the stale v2.15.2/busybox/dex images.
- The node creates harbor-token-service TLS.
- The platform-secrets Job creates only Secrets that are missing (keycloak-client-secrets, the backstage secrets) and leaves every existing one untouched. Verify with metadata.resourceVersion before and after.
- Harbor: charts and images are pushed, and the teknoir project becomes public.
- The root app-of-apps is pinned to 0.0.4.
- ArgoCD then:
  - adopts the istio CRDs: the tracking-id is added, Prune=false is already present, and the spec is unchanged because the versions are identical;
  - adopts the cert-manager CRDs through SSA;
  - moves the wildcard Certificate from the istio app to the cert-manager app. If istio prunes it first, the Secret survives, because cert-manager runs without --enable-certificate-owner-ref (verify the flag first), and the re-created Certificate finds a valid Secret, so nothing is re-issued;
  - rolls harbor-core once, for the new token cert, after which Harbor stops drifting;
  - runs keycloak-config-cli, which must be a no-op on the existing clients (see M0);
  - runs the Harbor OIDC Job, which finds the configuration already equal.
Verify:
  kubectl --context teknoir-local -n teknoir-system get applications   # all Synced/Healthy; user-controller is fixed once backstage-keycloak-secrets exists
  kubectl --context teknoir-local get crd gateways.networking.istio.io certificates.cert-manager.io -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.argocd\.argoproj\.io/tracking-id} {.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}{end}'
  kubectl --context teknoir-local -n teknoir-system get rs -l component=core   # no new harbor-core ReplicaSet appears over the following hour (drift fixed)
  kubectl --context teknoir-local -n teknoir-system get cm teknoir-airgap-release -o yaml
  Plus a browser check of harbor, argocd, auth and grafana per CLAUDE.md, from a LAN host with the CA trusted.

M5. DELIBERATE RESTART TEST in the window:
  ssh teknoir@teknoir.airgapped sudo systemctl restart k3s
  Then re-run the M2 baseline count commands and diff them: they must be equal. No Teknoir Addon re-appears, every Application stays Synced, and the Secrets' resourceVersions are unchanged.

M6. RETIRE THE ROBOT:
  1. Once app-of-apps has synced through the credential-less repository Secret (argo chart value), delete the old repo-creds Secret in teknoir-system. It is unowned after M3.
  2. Delete robot$argocd through the Harbor API, from teknoir-node (`harbor robot-delete argocd`).
  Verify: argocd app get app-of-apps shows no repo errors after a hard refresh.

M7. LATER, IN SEPARATE WINDOWS:
  a. ArgoCD self-management (G-07). DECIDED (2026-10-08): app-of-apps 0.0.4 declares the argo Application but disabled (`applications.argo.enabled: false`, gitops 29e6775), so in 0.0.4 teknoir-argo.yaml stays ArgoCD's only owner on teknoir-local, and fresh installs run ArgoCD from the one-shot argo tier (argo chart 0.0.3, D14). App-of-apps 0.0.5 enables the argo Application, with crds.annotations Prune=false,Delete=false; ideally its render equals the live teknoir-argo.yaml, otherwise its adoption rolls the ArgoCD pods once.
     Order:
       1. `./teknoir-airgap up` with the 0.0.5 bundle: the oneshot phase skips the argo tier while the K3s file is live, and ArgoCD adopts itself through the argo Application;
       2. right after it, with no k3s restart in between (K3s would re-apply its file over ArgoCD's): `teknoir-node migrate --argo` (`--dry-run` first). It refuses unless Application teknoir-system/argo is Synced/Healthy and every argoproj.io CRD carries Prune=false and Delete=false. It records the running ArgoCD pods (label app.kubernetes.io/part-of=argocd) by UID, then applies the M3 recipe and baseline to teknoir-argo alone (.skip, move teknoir-argo.yaml, strip the objectset labels, delete the Addon). After a short settle it asserts that the pod UIDs and the CRD annotations are unchanged, and warns about objects of the file that carry no argo tracking-id, which are left in place without an owner.
     This adopts first and detaches second, the reverse of the earlier plan, so ArgoCD always has an owner: if the adoption fails, teknoir-argo.yaml is still in place.
     Verify: `get addons -n kube-system` lists no Teknoir Addon; the ArgoCD pods were not restarted by the detach (pod UIDs); the argoproj CRDs carry Prune=false,Delete=false.
  b. Secrets encryption: `sudo k3s secrets-encrypt enable --data-dir /opt/k3s`, restart, `sudo k3s secrets-encrypt reencrypt --data-dir /opt/k3s`, then `status --data-dir /opt/k3s` shows Enabled. Always pass --data-dir explicitly.
  c. If decided, sqlite to embedded etcd: add cluster-init: true to config.yaml through converge and restart, after a fresh M2 backup. Verify that `k3s etcd-snapshot ls --data-dir /opt/k3s` works.
  d. If decided, PKI re-issue: `./teknoir-airgap rotate ca`, which issues the new name-constrained CA, renews every Certificate, updates node and containerd trust, then redistributes trust with `./teknoir-airgap trust` on every LAN host.

M8. CLEAN-UP: once the live env is migrated, delete the migrate subcommand and the remaining legacy code (I-13 and I-14).

## Test plan

1. STATIC TESTS (CI on every PR, both repos; also run locally on vpro)
- shellcheck -x on every script.
  - The LAN entrypoint is also run under the docker image bash:3.2 for `--help`, `doctor` (stub ssh) and MANIFEST verify. This proves macOS /bin/bash compatibility.
- bats unit tests (airgap/test/bats) with stub kubectl, k3s, ssh and crane:
  - error-vs-absent handling: rc!=0 aborts;
  - lock contention;
  - dry-run makes no mutating calls;
  - the downgrade guard;
  - the content-addressed sync picks exactly the changed files;
  - kubeconfig replacement;
  - host-key mismatch message.
- Build-gate tests on a real build:
  - MANIFEST verifies, and an unlisted file fails;
  - no PEM private key (also inside the chart archives and the renders), no `kind: Secret` with data/stringData apart from the credential-less ArgoCD repository Secret, and no known literal credentials anywhere in the tar (fixtures: airgap/test/build/gate-test.sh);
  - every image in images/ has exactly one linux/amd64 manifest;
  - every image referenced by the rendered charts is in images.lock;
  - the bundle is under 3.5 GB;
  - bundleId carries both SHAs;
  - a dirty tree is refused.
- GitOps render tests (G-08):
  - every chart renders;
  - every CRD has Prune=false,Delete=false;
  - every Application has retry and ServerSideApply;
  - no change-me-class literals;
  - teknoir images use immutable tags (warn for now);
  - for each one-shot chart, `helm template` equals node/oneshot/<tier>.yaml byte for byte, so the bootstrap render equals ArgoCD's render.
- gitleaks in both repos.
- Doc lint: every `./teknoir-airgap …` command in the docs exists in `teknoir-airgap help`.

2. K3D TESTS (airgap/test/k3d/run.sh on vpro and in CI)
Setup:
  - k3d cluster create k3sown --image rancher/k3s:v1.33.5-k3s1 --k3s-arg '--disable=traefik@server:0' --volume "$PWD/airgap/test/k3d/manifests:/var/lib/rancher/k3s/server/manifests/teknoir@server:0"
  - Always pass `kubectl --context k3d-k3sown`. Restart with `docker restart k3d-k3sown-server-0`.
  - These tests prove the K3s ownership semantics the design depends on, and must pass before any live step.
Tests:
  - T1 (baseline): a file creates an Addon, and its objects get objectset.rio.cattle.io/hash plus the owner annotations.
  - T2 (hazard, negative test): removing one object from a file deletes that object, even when it carries argocd.argoproj.io/sync-options Prune=false. This documents the K3s garbage collection.
  - T3: deleting a file leaves the objects and the Addon. A restart does not re-create the file's objects or remove them.
  - T4 (detach recipe): .skip, move, strip, delete the Addon, then restart. All objects survive and no Addon re-appears. A file with the old name dropped next to the .skip is ignored. `migrate --undo` re-adopts.
  - T5 (restart forces re-apply): editing a Secret that a K3s file owns, then restarting, reverts the edit. This shows why secrets must not be K3s files.
  - T6 (adoption): install ArgoCD v3.5.1 from the same chart and server-side apply the istio one-shot render as argocd-controller. Then create the istio Application from the same chart (served from an in-cluster OCI registry such as registry:2, or a local chart repo).
    - Expect Synced with pod UIDs unchanged and the CRDs tracked with Prune=false.
    - Removing a CRD from the chart does not delete it.
    - Deleting the Application without cascade leaves everything.
  - T7 (converge idempotency): run the cluster phases of teknoir-node against the k3d cluster in --local mode with KUBECTL=kubectl, twice. The second run reports 0 changes and every Secret keeps its resourceVersion. Deleting one generated Secret re-creates only that Secret.
  - T8 (never print): capture stdout, stderr and the log of T7. For every value of every generated Secret, read through kubectl in the test harness only, the grep count must be 0.
  - T9 (migration rehearsal on the legacy fixture): reproduce the live layout with dummy secrets and a throwaway real root CA, using the old render's 00-teknoir-*, 05-*, teknoir-*-secret and manifest-*-secret files plus orphan Addons.
    - A converge before `migrate` is refused (preflight) and changes nothing.
    - Run `migrate` (dry-run, run, re-run), then the cluster phases of converge (verify, preflight, cluster-base, secrets) twice. The second run reports 0 changes. The existing Secrets, CRDs, namespaces and root Application keep their uids and resourceVersions.
    - Restart k3s with an old file next to its .skip, then converge again (0 changes); then `migrate --undo` and re-migrate.
    - Object counts must equal the baseline, and there must be no Teknoir Addons but teknoir-argo.
    - Not in T9: CRD adoption by ArgoCD (the fixture runs no ArgoCD). T6 covers it on k3d and E10 on the VM: the CRDs are Synced resources of their Applications (ArgoCD 3.5 writes no tracking-id on CRDs). The oneshot, harbor, release and post phases need the built bundle and run in E10.

3. END-TO-END AIRGAP TEST IN A KVM VM ON vpro (airgap/test/vm/e2e.sh)
Environment:
- The existing harness /home/anders/vmtest/vm.sh moves into airgap/test/vm/vm.sh.
- qemu-system-x86_64 is in fact installed already, and VM tk-airgap is running.
- The VM runs Debian 13 genericcloud through cloud-init with 8 vCPU, 10 GiB RAM and a 120 GB disk, on the isolated bridge tkvm0 10.77.0.0/24 with iptables FORWARD DROP both ways and no NAT.
- The VM domain is changed to teknoir.airgapped, because the bundle is per env, and VM_IP is 10.77.0.10. site/vmtest.env sets NODE_IP=10.77.0.10 and NODE=teknoir@10.77.0.10.
- The LAN host is a network namespace on vpro: `airgap/test/vm/lan-netns.sh up` creates netns tklan with a veth into tkvm0 at 10.77.0.20 and no default route. /etc/netns/tklan/hosts maps the *.teknoir.airgapped names to 10.77.0.10, and `ip netns exec` bind-mounts it over /etc/hosts. vpro's own /etc/hosts and the real 192.168.5.181 env are never touched.
- Commands run as:
  sudo ip netns exec tklan sudo -u anders env HOME=/home/anders/vmtest/lanhome ./teknoir-airgap up --site site/vmtest.env
- Memory: stop other docker workloads on vpro during the run. If 10 GiB OOMs, raise it to 11 GiB. The agent-node scenario E9 needs a second VM of 2-3 GiB and is optional.
- Add anders to group kvm. The script uses `sg kvm`.

Scenarios. Each asserts and prints a pass/fail summary.
- E1 fresh bootstrap from the extracted tar in the netns, on a just-created VM.
  - Every Application must reach Synced/Healthy within 45 min.
  - curl with --cacert set to the fetched CA must succeed against:
    - https://harbor.teknoir.airgapped/api/v2.0/health
    - https://argocd.teknoir.airgapped (200)
    - https://auth.teknoir.airgapped/realms/master/.well-known/openid-configuration
  - The oauth2-proxy login with the first admin must work (`admin-user --email ... --out FILE`, then a scripted form login with curl that sets the new password).
  - Optional: run chromium in the netns for a screenshot.
- E2 idempotency: run `up` again.
  - The converge summary reports 0 changes.
  - Pod UIDs are identical.
  - k3s ActiveEnterTimestamp is unchanged.
  - Harbor uploads 0 blobs.
  - Secret resourceVersions are unchanged.
- E3 no egress:
  - In the VM, `curl -m5 https://registry-1.docker.io/v2/` and `getent hosts github.com` fail.
  - In the netns, curl to a public IP fails.
  - The vpro `iptables -L FORWARD -v` DROP counters for tkvm0 grow.
  - Every image in `k3s crictl images` was imported or came from the harbor.teknoir.airgapped mirror.
  - There are no ErrImagePull events.
- E4 update and rollback:
  - Build bundle B (a trivial chart version bump of one controller plus an app-of-apps bump) and run `up`. Only that Application changes revision, and the release ConfigMap records B.
  - Run `up` with bundle A: it is refused.
  - Run `up --rollback` with A: it is accepted, and the next plain `up` with A keeps A.
- E5 interruption: kill `up` during the payload sync, during the Harbor image push, and during the tarball import. Each re-run completes with no manual repair.
- E6 node rebuild: run vm.sh destroy and create, which gives a new host key.
  - `up` prints the host-key fix. After --forget-host-key the bootstrap completes.
  - Restore from the I-12 backup brings back the Harbor projects and the Keycloak users.
- E7 secrets hygiene:
  - grep the full LAN transcript and the node logs for every Secret value (read inside the VM by the harness): count 0.
  - grep the tar for 'PRIVATE KEY': none.
  - ~/.docker and ~/.config/helm in the netns HOME and on the node are unchanged.
- E8 rotation: `teknoir-airgap rotate oauth2-proxy-cookie` changes only that Secret, oauth2-proxy rolls, and login still works.
- E9 (optional, memory permitting): a second VM joins as an agent through the host phase. Pods scheduled there pull from Harbor through registries.yaml with the CA trusted. The hostPath PVs stay on the server.
- E10 migration rehearsal, the gate for the live env:
  1. On a fresh VM, run the CURRENT tooling (HEAD e9a3b7f bundle, with generated dummy secrets) to reach the old layout (airgap/test/vm/old-setup.sh, including the live node's legacy file names and orphan Addons).
  2. Run the new bundle's `migrate --dry-run`, `migrate`, `up`, `migrate --argo --dry-run`, `migrate --argo`, `migrate` again (M6), then a k3s restart.
  3. Assert:
     - no object loss: every object of the baseline survives by name, except the expected-gone list (harbor-registry-htpasswd, which harbor 0.0.9 replaces, and the robot repo-creds Secret, which M6 deletes), and those are gone;
     - migrate carries the Keycloak admin over (keycloak-admin with username and previous-password), and after up the admin logs in with password and not with previous-password; realm teknoir answers; admin-user and an oauth2-proxy login work;
     - the CRDs are ArgoCD-tracked, and every argoproj.io CRD carries Prune=false,Delete=false;
     - no Teknoir files or Addons under K3s, no old bundle copy on the node;
     - after M6 the repo-creds Secret and robot$argocd are gone and app-of-apps still syncs;
     - the restart changes no object, re-creates no Addon and keeps the platform Secrets' resourceVersions;
     - the existing secrets are unchanged, which proves adoption by name and key;
     - Harbor is stable for 1 h with no new harbor-core ReplicaSet.
- Host-setup doc check, manual and once: install Debian 13 from the offline ISO into a VM attached to tkvm0 using only HOST-SETUP.md, then E1 from the netns. This validates the installer path the cloud image skips.

## Work items

NOTE: G-05 is superseded by D2 (dedicated realm `teknoir`, not an adoption of master). G-04 must include the Backstage/user-controller secrets above. L-01 hygiene is folded into the migration (keycloak admin rotation happens via G-05/D2).

### L-01 — Immediate live-env hygiene: rotate Keycloak admin, remove plaintext secret copies
- repo: live-env (teknoir-local node + cluster; no code)
- depends on: -
- files: /home/teknoir/teknoir-airgap-bundle-0.1.0 (node), teknoir-auth/keycloak-0, /home/anders/git/ai/infra-teknoir-local/.secrets, /home/anders/git/ai/infra-teknoir-local/bundle/

(1) Create Secret teknoir-auth/keycloak-admin with a random password (never echoed). Set it on the existing master admin with kcadm.sh set-password inside keycloak-0, fed through stdin. Changing the chart env does not change an existing admin. (2) Delete the node copy of the pre-fix bundle, which contains manifest-teknoir-ca-secret.yaml and others at mode 0644. (3) Move vpro .secrets and the bundle secrets into an encrypted backup (age) and delete the plaintext copies; check the USB sticks used before. (4) Record the decision on re-issuing the CA. Explicit approval from Anders is required before running.

**Test:** An admin/change-me token request against the master realm returns 401 (only the status code is printed). `ssh teknoir.airgapped ls ~` shows no teknoir-airgap-bundle-*. `grep -rl 'PRIVATE KEY'` over vpro bundle/ and the USB returns nothing.

### I-01 — make-bundle: staged build, derived bundle id, provenance manifest, single tar + sha256, hard gates
- repo: infra (branch teknoir-local)
- depends on: -
- files: airgap/build/make-bundle.sh (from airgap/make-bundle.sh), airgap/build/lib-build.sh (build half of airgap/lib.sh), airgap/versions.env, airgap/site/teknoir-local.env (new)

Build into dist/.staging-<id> and rename into place only after the gate passes. Derive bundleId from env, APP_OF_APPS_VERSION, date and the infra/gitops short SHAs; refuse dirty trees unless --allow-dirty. Write MANIFEST.yaml: commits, versions, the sha256 of every file, image digests. Produce one plain tar plus .sha256 with the layout defined in package_format; this layout is the contract for I-02..I-11. Delete step 4 (secrets), --diff, BUNDLE_VERSION, the in-place truncate-then-render and the warn-only kubectl dry-run loop. Fail hard on any missing input. The gate covers: offline completeness (verify-offline logic folded in), no Secret data or private keys, no known literal credentials, single-platform images, and app-of-apps not in the broken list. Check bash>=4.4 at start.

**Test:** bats: two builds from the same commits produce identical MANIFEST file lists and sha256s (apart from createdAt). A dirty tree is refused. A planted PEM private-key header fails the gate. `sha256sum -c` passes. Unlisted extra files fail verify. The tar extracts on macOS bsdtar.

### I-02 — Image collection: single-platform, digest-locked, atomic, version-keyed cache
- repo: infra (branch teknoir-local)
- depends on: -
- files: airgap/build/collect-images.sh, airgap/images-extra.txt, airgap/versions.env (IMAGE_PLATFORMS)

Pull with crane pull --platform linux/amd64 (IMAGE_PLATFORMS is a list, ready for arm64). Resolve tag to digest first and write images.lock (ref@sha256). Pull into <slug>.tmp and mv into place only after validation (index has exactly one manifest; tar -tf passes for archives). A cache entry is re-validated in full every time it is used, on the copy that ships: every OCI blob's sha256 equals its digest; a docker archive holds exactly manifest.json, the config and the layers, its config and ordered layer digests equal the registry manifest's, every member's sha256 equals the digest in its name, and its `crane digest --tarball` equals the one recorded at the first pull (<entry>.digest). A corrupt entry is named, removed and pulled again in the same run, so a re-run always converges (airgap/test/build/image-cache-test.sh). The cache in ~/.cache/teknoir-airgap/images is keyed by digest, so mutable tags are re-resolved on every build. Store bootstrap-tier images once, as single-platform docker archives under node/bootstrap-images, used both for import and push. Drop the hardlink dedupe and the duplicate proxyv2/pause entries in images-extra.txt. Add a gate that lists teknoir images on :latest or branch tags as warnings, and errors once G-09 lands. Skip helm dependency builds in dry-run.

**Test:** Every images/<slug> has exactly one linux/amd64 manifest (jq on index.json). Killing a pull mid-way and re-running leaves no partial layout. Total images plus bootstrap-images is under 3.5 GB. Every image referenced by the rendered charts is present in images.lock.

### I-03 — Tool, k3s and installer downloads: pinned, checksum-verified, cached by version
- repo: infra (branch teknoir-local)
- depends on: -
- files: airgap/build/fetch-tools.sh (new, from make-bundle.sh:138-208), airgap/versions.env

Download into ~/.cache/teknoir-airgap/<tool>-<version>/ through a .tmp file, verify against the upstream checksum files (helm .sha256sum, crane checksums.txt, k3s sha256sum-amd64.txt, kubectl .sha256), and pin each sha256 in versions.env. Fetch install.sh from raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh. Node tools for linux-amd64: helm, crane, jq, age. LAN-convenience kubectl for linux-amd64, darwin-arm64 and darwin-amd64. A version bump must invalidate the cache. Delete the dead pins ARGOCD_HELM_VERSION, ARGOCD_IMAGE_VERSION, HARBOR_HELM_VERSION, ISTIO_PILOT_IMAGE and TOOL_PLATFORMS darwin-only logic.

**Test:** A tampered cached binary fails the build. Bumping HELM_VERSION fetches the new version (the old cache entry is untouched). install.sh carries K3S_VERSION in its URL.

### I-04 — Override-free one-shot renders and the templated root Application
- repo: infra (branch teknoir-local)
- depends on: G-01, G-02, G-03
- files: airgap/build/render-oneshot.sh (replaces airgap/render-bootstrap.sh), airgap/node/templates/app-of-apps.yaml.tmpl, airgap/node/templates/coredns-custom.yaml.tmpl, airgap/node/templates/registries.yaml.tmpl, teknoir-local-app-of-apps.yaml (delete), airgap/lib.sh chart_template_args/helm_template_chart (delete)

Render platform-secrets, istio (CRDs split into istio-crds.yaml only for apply ordering), harbor and, until G-07, argo from the bundled chart .tgz with `helm template --include-crds` and NO --set at all; every value must come from the env-branch values (G-01..G-06). Render the root Application from APP_OF_APPS_VERSION and delete the committed root manifest and the lib.sh:223-227 cross-check. Keep __NODE_IP__ and __DOMAIN__ placeholders in the coredns and registries templates for run-time substitution. Delete TRACK_PY, FILTER_CRD_PY, render_split_chart, render_crds_only, 00-teknoir-namespaces, the CRD K3s files, the RELEASED_CHARTS and PINS_FROM_WORKTREE paths and the python3 requirement on the build side, using `yq` from the tool cache or helm's own output split by kind.

**Test:** For every one-shot chart, `diff <(helm template X chart.tgz) oneshot/X.yaml` is empty, so the bootstrap render equals ArgoCD's render. `grep -c 192.168` over node/oneshot is 0. A grep for 'kind: Secret' with data/stringData in oneshot/ finds nothing except the credential-less ArgoCD repository Secret of the argo tier.

### I-05 — teknoir-node converge framework (node-side runner)
- repo: infra (branch teknoir-local)
- depends on: -
- files: airgap/node/bin/teknoir-node, airgap/node/lib/common.sh

A bash runner, executed as root on the node, with the subcommands converge|status|credentials|rotate|backup|migrate. It owns the phase ordering from target_procedure, an flock at /run/teknoir-airgap.lock, and a tee log to /var/log/teknoir-airgap/<UTC>-<cmd>.log (0600). Dry-run is computed from read-only checks: sha256 compares against Addon checksums and live objects, printed as unchanged / would change. KUBECTL='k3s kubectl'. Helpers: in_cluster() via `get --ignore-not-found -o name`, branching on rc so non-zero dies and empty means absent; one wait helper; sha256_file; a summary of changed objects. Never-print guards: no set -x; secret values only in variables or pipes; and a self-check that greps the log for every value held in memory at exit (debug builds). Verify the bundle sha256s before any mutation. Contains no python.

**Test:** shellcheck -x clean. bats with a stub kubectl and k3s: error-vs-absent handling (a stub returning rc=1 with 'connection refused' must abort, not be read as absent); a second lock holder exits 75; dry-run makes no mutating stub calls.

#### Node runner interface (addendum to shared contract #3)
`teknoir-airgap` runs `teknoir-node` as root from /var/lib/teknoir-airgap/bundles/<bundleId>/node/bin/ with these argument lists. The two sides change together; airgap/test/node/run.sh runs the exact `up` argv.
- `converge --site FILE --lan-time EPOCH --lan-user USER [--rollback] [--sync-clock] [--reapply TIER]... [--force-images] [--dry-run]`. `--operator USER` is an alias of `--lan-user`. For tests and break-glass only: `--only`/`--skip PHASE[,PHASE]`, `--no-backup`, `--backup`, `--wait-timeout SECONDS`. Unknown arguments are a usage error (exit 2).
- `status --site FILE [--lan-time EPOCH]`, `verify`, `credentials NAME --site FILE [--out FILE]` (without --out: stdout, never a terminal), `rotate NAME --site FILE [--i-know]`, `backup --site FILE [--list | --recipient-site | --export | --stream FILE [--keep] | --recipient AGE1...] [--take | --name TS]` (no option: take a backup now; `--recipient-site` encrypts to the site's `BACKUP_AGE_RECIPIENTS` and prints the export's path; `--recipient` is repeatable), `migrate --site FILE [--dry-run | --undo NAME]`, `admin-user --site FILE --email ADDR --out FILE [--teamspace NAME] [--reset-password]` (r5).
- Phase functions (`phase_<name>`, one per lib file) take no arguments. The break-glass flags reach them as environment variables, set by `converge` from its command line: `ONESHOT_REAPPLY` (space-separated tier names; each must be listed in oneshot/TIERS, otherwise converge exits 2 before any phase runs) for lib/oneshot.sh, and `HARBOR_FORCE_IMAGES` (0|1) for lib/harbor.sh. Further inputs: `DRY_RUN`, `ROLLBACK`, `LAN_TIME`, `LAN_USER`, `WAIT_TIMEOUT`, `BACKUP_MODE`.
- Exit codes: 0 ok, 1 error, 2 usage, 70 the leak check found a secret value or a private key in the run log, 75 another run holds /run/teknoir-airgap.lock.

### I-06 — Host phase: idempotent k3s install/upgrade and node files, ready for agents
- repo: infra (branch teknoir-local)
- depends on: I-05, I-03
- files: airgap/node/lib/host.sh, airgap/install-k3s.sh (delete), airgap/bootstrap-airgap.sh steps 1-2 (delete)

Install or upgrade k3s only when `k3s --version` differs from the pin or the config.yaml hash changes. Run install.sh with INSTALL_K3S_SKIP_DOWNLOAD and the bundled binary after checking its sha256. config.yaml: data-dir /opt/k3s, disable traefik, tls-san, kubelet max-pods, secrets-encryption: true for new installs, plus cluster-init and etcd snapshots per decision. Write registries.yaml from the template before the first k3s start, so the first install needs no restart. Install the CA into OS trust (always run update-ca-certificates) and the k3s path; keep the managed /etc/hosts block. Configure chrony if it is installed (serve the LAN subnet), otherwise report skew. Sync bootstrap tarballs, prune ones no longer listed, and run `k3s ctr -n k8s.io images import` for each missing image (no restart). Restart k3s only when config.yaml or registries.yaml differs from /var/lib/teknoir-airgap/restart.stamp, which is written after a successful restart. Use sudo -n everywhere. Role server|agent: an agent reads the token from the server over the same ssh hop. Pass --data-dir to every k3s subcommand.

**Test:** VM E2: a second `up` gives the same k3s ActiveEnterTimestamp, 0 files changed and 0 imports. Deleting one bootstrap image from containerd gets it re-imported without a restart. Changing registries.yaml triggers exactly one restart. E9 agent join (optional).

### I-07 — Node secrets phase: CA, wildcard placeholder, Harbor token TLS, derived trust; credentials and rotate
- repo: infra (branch teknoir-local)
- depends on: I-05
- files: airgap/node/lib/secrets.sh, scripts/gen-local-ca-secret.sh (delete), scripts/deploy-secrets.sh (delete)

ensure_ca: if Secret cert-manager/teknoir-root-ca is absent, generate it with openssl in a 0700 tmpfs dir: a 10y root with basicConstraints critical CA:TRUE,pathlen:0 and nameConstraints critical permitted DNS:<domain>, DNS:.<domain>. Create the Secret by piping into kubectl, then shred the tmp files. The live env keeps its existing CA. ensure_wildcard_placeholder: create the cert only if the istio-system wildcard Secret is absent. ensure_harbor_token_tls: the Secret for core.secretName. Derived objects, reconciled every run from the CA Secret's tls.crt: argocd-tls-certs-cm entry and the CA-bundle copies in teknoir-auth and teknoir-system (public cert only). `credentials <name> --out FILE` writes a single value to a 0600 file and refuses a TTY stdout. `rotate <name>` replaces exactly one Secret and restarts the documented consumers (refused for harbor secretKey and keycloak-db without --i-know, with the rotation steps in OPERATE.md).

**Test:** k3d T7: a second run leaves resourceVersions unchanged; deleting only the wildcard Secret re-creates only that one. Every value appearing in the run log is absent (grep). openssl x509 -text shows the name constraints. `credentials` to a TTY is refused.

### I-08 — One-shot adoption phase: SSA as argocd-controller, skip once ArgoCD owns the tier
- repo: infra (branch teknoir-local)
- depends on: I-04, I-05, G-04
- files: airgap/node/lib/oneshot.sh, airgap/lib.sh:661-819 CRD gate and hand-over (delete), airgap/lib.sh argocd_owns (replace)

For each tier in order (platform-secrets, istio, harbor, argo): if Application teknoir-system/<tier> exists (rc-checked), skip. Otherwise run `k3s kubectl apply --server-side --field-manager=argocd-controller --force-conflicts -f oneshot/<tier>-crds.yaml`, wait for the CRDs to be Established, apply the rest, and wait for rollouts and Job completion. Then delete the completed one-shot platform-secrets Job, which carries no tracking. Provide `--reapply <tier>` as break-glass, which logs a warning. Delete the CRD gate, the hand-over resync, version_ge, ISTIO_CRD_FREE_SINCE, --skip-crd-gate and the tracking-id machinery.

**Test:** k3d T6: after the one-shot apply and Application creation, ArgoCD is Synced, pod UIDs are unchanged, istiod managedFields hold only argocd-controller, and a second converge does not re-apply (audit by the field-manager list).

### I-09 — Harbor content phase on the node: projects, charts, images by digest, no robot
- repo: infra (branch teknoir-local)
- depends on: I-02, I-05
- files: airgap/node/lib/harbor.sh, airgap/push-to-harbor.sh (delete), scripts/gen-argocd-harbor-repo-secret.sh (delete)

Read the admin password from Secret harbor-secret into a variable. Use DOCKER_CONFIG and HELM_REGISTRY_CONFIG under mktemp -d (0700, trap rm), and run curl with -K <(...) for credentials. Create projects idempotently, all public; set tag immutability on teknoir (and on the mirrors for non-latest tags, per decision). Charts: push with the node helm; skip if the tag exists with the same digest; refuse if the digest differs (an immutable release). Images: crane push from OCI layouts and docker archives by digest; skip if present; refuse to move an existing mirror tag to another digest without --force-images. JSON goes through the bundled jq. Remove the robot code, the robot env file and the --robot-* and --rotate-robot flags, plus a one-time `harbor robot-delete argocd`.

**Test:** VM E1/E2: the second run uploads 0 blobs (Harbor access log or crane digest checks). A mismatching chart digest is refused. ~/.docker and ~/.config/helm on the node and the LAN host are untouched after the run.

### I-10 — Root pin, release record, downgrade/rollback guard and post-checks
- repo: infra (branch teknoir-local)
- depends on: I-05
- files: airgap/node/lib/release.sh, airgap/deploy-app-of-apps.sh (delete), airgap/update-airgap.sh (delete), airgap/verify-offline.sh live mode (fold in)

Server-side apply the root Application from the template with APP_OF_APPS_VERSION, or with the rollback pin recorded in ConfigMap teknoir-system/teknoir-airgap-release. Write and refresh that ConfigMap: bundleId, manifest sha, commits, aoa version, operator ($SUDO_USER plus the LAN user passed in), time and history (last 10). Refuse when the bundle's aoa version is lower than the recorded one unless --rollback, and refuse versions in the broken list at all times. Post: wait until every Application is Synced/Healthy (default 20 min) and print a table of failures with each app's last operation message. Live image check: every running container image is in Harbor or in containerd.

**Test:** k3d: apply 0.0.4 then 0.0.3 without --rollback and it is refused; with --rollback it is accepted and recorded; the next plain `up` with the 0.0.3 bundle keeps 0.0.3. An Application that fails to sync makes `up` exit non-zero with that app named.

### I-11 — LAN entrypoint `teknoir-airgap` (bash 3.2, ssh+tar only)
- repo: infra (branch teknoir-local)
- depends on: I-05
- files: airgap/teknoir-airgap, airgap/extract-kubeconfig.sh (delete), airgap/upload-bundle.sh (delete), airgap/lib.sh ssh helpers (delete)

Locate the bundle from $0, read the site env (--site, --node), verify MANIFEST locally, then open ssh with ControlMaster/ControlPersist under ~/.teknoir-airgap/<site>/. Pin the host key in its own known_hosts with StrictHostKeyChecking=yes after first-use confirmation; on a mismatch, print the exact ssh-keygen -R command or accept --forget-host-key; show ssh stderr. First run: if `sudo -n true` fails, prompt once over -t and install /etc/sudoers.d/teknoir-airgap. Payload sync is content-addressed: one ssh call lists remote sha256s, then one tar stream sends only what is missing. Run teknoir-node over ssh -t, passing the LAN time and user. Subcommands: up, status, kubeconfig (replaces an existing teknoir-local cluster/user/context, never merges stale entries), trust (applies or with --print shows the /etc/hosts block and CA trust for Debian, Ubuntu and macOS keychain), credentials, backup (pull + age encrypt), rotate, doctor (name resolution, CA trust, ssh, skew, macOS quarantine xattrs). --local runs on the node without ssh. No python, no GNU-only flags.

**Test:** Runs under docker bash:3.2 for --help, doctor with a stub ssh, and a manifest verify. shellcheck -s bash clean. The VM E1 run from the netns LAN host. A host-key-change scenario (E6) prints the fix. Re-running kubeconfig after a k3s reinstall replaces the credentials.

### I-12 — Backup and restore (automatic pre-change on the node, encrypted export)
- repo: infra (branch teknoir-local)
- depends on: I-05
- files: airgap/node/lib/backup.sh, docs/airgap/OPERATE.md (restore section)

Before each mutating converge on an existing cluster: pg_dump harbor-database and keycloak-db through kubectl exec. If on etcd: k3s etcd-snapshot save --data-dir /opt/k3s. If on sqlite: brief k3s stop (pods keep running), copy state.db, start. Also copy server/token, server/tls and cred, plus a YAML export of the bootstrap-tier Secrets (CA, harbor-secret, keycloak-db, keycloak-admin), all into /var/lib/teknoir-airgap/backups/<ts> (0700, keep 3). `teknoir-airgap backup --out DIR` streams the latest backup age-encrypted (passphrase) to the LAN host. Write and test the restore procedure once.

**Test:** VM: back up, then delete the Keycloak DB PVC data and a Harbor project, restore following OPERATE.md; the realm, users and Harbor content come back. The backup file contains no plaintext ('PRIVATE KEY' absent before decryption).

### I-13 — One-time live migration subcommand (K3s detach recipe) - temporary
- repo: infra (branch teknoir-local)
- depends on: I-05
- files: airgap/node/lib/migrate.sh

`teknoir-node migrate [--dry-run] [--undo NAME]` implements the M3 recipe (see migration_for_live_env): .skip guard, move to manifests-retired/<ts>, strip objectset labels and annotations by GVK annotation and hash label, delete the Addon, in the documented order. It also deletes orphan Addons, removes ~teknoir/teknoir-airgap-bundle-* on the node, and prunes stale agent/images tarballs. Before the first change it records the M3 baseline (the UID of every object of every Addon in the run, and the counts); after each name it compares all of it and stops at the first mismatch. `teknoir-node migrate --argo [--dry-run]` is the M7a step for teknoir-argo alone, with its preconditions and pod-UID check. Never touch K3s's packaged addons (allow-list only teknoir-*, 00-teknoir-*, 05-teknoir-*, 10-teknoir-*, manifest-*-secret, app-of-apps). Delete this file and lib.sh:559-659 (k3s_canonical_name, k3s_legacy_names, k3s_owners, k3s_retire_legacy) once teknoir-local is migrated.

**Test:** k3d T4 and T9 (legacy-state fixture): after migrate and a k3s server restart, every object survives, no Teknoir Addon exists, and re-adding an old file next to its .skip is ignored. --undo re-adopts the object. Dry-run against the live node (read-only) lists exactly 3 orphan, 8 legacy, 10 canonical secret, 1 namespaces, 2 CRD, coredns and app-of-apps entries.

### I-14 — Delete superseded scripts, code paths and stale files
- repo: infra (branch teknoir-local)
- depends on: I-01, I-02, I-03, I-04, I-05, I-06, I-07, I-08, I-09, I-10, I-11
- files: see delete_list

Remove everything in delete_list that belongs to infra once I-01..I-11 are merged: old airgap/*.sh, scripts/*.sh, root manifest, .air/ and .junie/ plans, dead versions.env variables, and the RELEASED_CHARTS and BROKEN-list duplication (keep a single list in versions.env, read by make-bundle and release.sh). Update .gitignore (dist/, no repo-root teknoir-root-ca.crt). Keep the git history as the archive.

**Test:** `git grep -n 'gen-\|deploy-secrets\|bootstrap-airgap\|push-to-harbor\|robot-argocd\|python3' -- airgap scripts docs` returns nothing. CI is green.

### I-15 — Documentation rewrite: BUILD, HOST-SETUP, OPERATE (+CHANGELOG), shipped in the bundle
- repo: infra (branch teknoir-local)
- depends on: I-01, I-11
- files: docs/airgap/BUILD.md, docs/airgap/HOST-SETUP.md, docs/airgap/OPERATE.md, docs/airgap/CHANGELOG.md, docs/AIRGAP-*.md (delete), README.md, README_infra.md (airgap parts)

BUILD: prerequisites and one command. HOST-SETUP: the Debian 13 offline install choices (static IP equal to NODE_IP, enp4s0-agnostic, user, SSH server only, no mirror, no NVIDIA/online apt sources), ssh-copy-id, the LAN-host support matrix, chrony/time, then first `up`. OPERATE: bootstrap and update are the same `up`, plus status, rollback, backup/restore, rotate (per secret, incl. the Harbor secretKey/Keycloak DB caveats and CA rotation), multi-node join, troubleshooting (host key, skew, Harbor down, sync failures), and the ownership table from target_ownership. Each runbook is prerequisites, command and verification checklist; paths are correct from the bundle root. Move all incident and migration history to CHANGELOG.md. Fix the false CA-key claim. Mention --data-dir for every k3s subcommand.

**Test:** A doc lint in CI extracts every `./teknoir-airgap ...` line and checks that the subcommand and flags exist in `teknoir-airgap help`; markdown link check; a fresh-operator dry run in the VM (E1) follows only HOST-SETUP and OPERATE.

### I-16 — Test harness: static, k3d ownership suite, VM airgap e2e, CI
- repo: infra (branch teknoir-local)
- depends on: -
- files: airgap/test/bats/*.bats, airgap/test/k3d/run.sh, airgap/test/k3d/fixtures/, airgap/test/vm/vm.sh (from /home/anders/vmtest/vm.sh), airgap/test/vm/lan-netns.sh, airgap/test/vm/e2e.sh, airgap/site/vmtest.env, .github/workflows/airgap-ci.yml

Implement the test_plan: shellcheck plus bats unit tests, the k3d suite T1-T9 on rancher/k3s:v1.33.5-k3s1, and the VM e2e E1-E10 driven by e2e.sh with assertions and a summary. Move the existing vm.sh into the repo; its default domain becomes teknoir.airgapped with VM_IP 10.77.0.10, and vmtest.env sets NODE_IP to that address. lan-netns.sh creates netns tklan with a veth into tkvm0 (10.77.0.20, no default route) and /etc/netns/tklan/hosts mapping the *.teknoir.airgapped names to 10.77.0.10, so vpro's real /etc/hosts and the live env are never touched. CI runs static checks, bats and k3d on PRs, plus gitleaks.

**Test:** The harness tests itself: the k3d negative test T2 must observe the GC deletion; E3 must observe failed egress from both the VM and the netns.

### I-17 — Node hardening knobs: secrets-encryption, datastore, firewall
- repo: infra (branch teknoir-local)
- depends on: I-06, I-12
- files: airgap/node/lib/host.sh, airgap/site/teknoir-local.env

config.yaml carries secrets-encryption: true and, per decision, cluster-init: true with etcd-snapshot-schedule-cron and retention. For existing clusters: an explicit `teknoir-node host enable-encryption` (enable, restart, reencrypt, verify) and `migrate-etcd` (backup first). nftables allow-list from site env: 22, 443 and 6443 from ADMIN_CIDR; 80/443 from the LAN for services; udp/123 from the LAN (since r5 the node serves NTP to Robots and cameras); device ports as configured; default accept until enabled by a site flag.

**Test:** VM: after enable-encryption, `k3s secrets-encrypt status --data-dir /opt/k3s` shows Enabled and Secrets read back fine. With etcd, `etcd-snapshot ls` lists the scheduled snapshots. With the firewall on, 6443 is unreachable from a non-admin netns.

### G-01 — istio chart owns its CRDs (vendored, Prune=false), Certificate removed
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: -
- files: charts/istio/crds/*.yaml (new), charts/istio/update-crds.sh (new), charts/istio/templates/crds-version-check.yaml (new), charts/istio/values.yaml, charts/istio/templates/certificate.yaml (delete), charts/istio/Chart.yaml (0.0.3), charts/app-of-apps/templates/istio.yaml

Apply the monitoring pattern. update-crds.sh vendors base/files/crd-all.gen.yaml from the pinned istio base chart into crds/, adding argocd.argoproj.io/sync-options: Prune=false,Delete=false and the same labels the base template sets. The version check fails the render on a version mismatch, and also fails if istio-base.base.excludedCRDs differs from the vendored CRD names; the list is generated by update-crds.sh, so no CRD is ever rendered twice. Remove helm.skipCrds from the istio Application. Remove certificate.enabled and the Certificate template (it moves to G-02).

**Test:** `helm template --include-crds` renders 14 CRDs, each with Prune=false. Read-only `kubectl --context teknoir-local get crd <name> -o json | jq .spec` equals the rendered spec for all 14, so adoption changes nothing. Bumping the base version without update-crds fails the render.

### G-02 — cert-manager chart owns CRDs + wildcard Certificate, SSA on the Application
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: -
- files: charts/cert-manager/crds/*.yaml (new), charts/cert-manager/update-crds.sh (new), charts/cert-manager/templates/crds-version-check.yaml (new), charts/cert-manager/templates/certificate.yaml (new, from istio), charts/cert-manager/values.yaml, charts/cert-manager/Chart.yaml (0.0.2), charts/app-of-apps/templates/cert-manager.yaml

Vendor the cert-manager 1.20.1 CRDs annotated Prune=false,Delete=false; the chart's crds.enabled cannot annotate them, so keep it false. Add the teknoir-wildcard Certificate (the same name, namespace and secretName as the istio chart's) with sync-wave after the ClusterIssuer. On the Application: ServerSideApply=true (the CRDs exceed the client-side annotation limit), remove skipCrds, add retry. Confirm that the cert-manager controller does not run with --enable-certificate-owner-ref, so the Secret survives the move.

**Test:** helm template renders 6 annotated CRDs and the Certificate. The read-only spec comparison against the live CRDs shows no change. On k3d, moving the Certificate between apps keeps the Secret's resourceVersion and does not re-issue.

### G-03 — app-of-apps 0.0.4: retries, waves, harbor drift fix, project narrowing, platform-secrets app
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: G-01, G-02, G-04, G-05, G-06
- files: charts/app-of-apps/templates/*.yaml, charts/app-of-apps/values.yaml, charts/app-of-apps/Chart.yaml (0.0.4)

Every Application gets syncPolicy.retry (limit 10; backoff 30s, factor 2, max 5m), ServerSideApply=true and no resources-finalizer. Sync waves: platform-secrets -10, cert-manager and istio -5, harbor/auth/monitoring 0, controllers and backstage 5. The harbor Application gets ignoreDifferences for Secret harbor-registry-htpasswd /data and the checksum annotations on the core/registry/jobservice Deployments, plus syncOptions RespectIgnoreDifferences=true. Add the platform-secrets Application. Narrow the AppProject: sourceRepos harbor.teknoir.airgapped/teknoir; destinations limited to the namespaces in use; clusterResourceWhitelist limited to the kinds in use (CRD, ClusterRole/Binding, ClusterIssuer, Namespace, webhook configs). Pin the new chart versions from G-01, G-02, G-04, G-05 and G-06.

**Test:** A render test asserts retry and SSA on every Application. On k3d with ArgoCD, harbor stays Synced across `argocd app get --hard-refresh` x3 with no new ReplicaSets. A forbidden destination is rejected by the project.

### G-04 — platform-secrets chart: declarative create-if-absent secret generation
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: -
- files: charts/platform-secrets/Chart.yaml, charts/platform-secrets/values.yaml, charts/platform-secrets/files/ensure-secrets.sh, charts/platform-secrets/templates/{configmap,job,rbac}.yaml

values.secrets is a list of {namespace, name, type, labels, keys: {KEY: {random: {length, charset}} | {copyFrom: ns/name/key} | {value}}}. It covers harbor-secret (HARBOR_ADMIN_PASSWORD, secretKey of 16 chars, REGISTRY_HTTP_SECRET, JOBSERVICE_SECRET, core secret, CSRF), keycloak-db-secret, keycloak-admin, keycloak-client-secrets, oauth2-proxy-secret (client-secret, cookie-secret of 32 bytes), oauth2-proxy-redis-secret, the argocd and harbor OIDC client secrets, and backstage-keycloak-secrets (coordinate with the backstage design in progress). It uses the existing live names and keys so they are adopted. ensure-secrets.sh is POSIX sh using kubectl and /dev/urandom only. It creates a Secret only when absent and never patches an existing value; it adds missing keys to an existing Secret only with an explicit addMissingKeys flag. It never prints a value. The Job runs as an ArgoCD Sync hook (BeforeHookCreation, wave -10) with a ServiceAccount whose Role may only get/create the listed Secrets. Its image is a mirrored, version-pinned image with sh and kubectl, which also goes into the bootstrap tarballs.

**Test:** k3d: install; delete one Secret and re-sync, and only it is re-created; the existing Secrets' data hashes are unchanged across 3 syncs; the Job logs contain none of the values; RBAC denies reading an unlisted Secret.

### G-05 — auth: admin from Secret, realm-as-code via keycloak-config-cli, pinned images
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: G-04
- files: charts/auth/values.yaml, charts/auth/templates/keycloak-config-job.yaml (new), charts/auth/files/realm/*.yaml (new), charts/auth/Chart.yaml

KC_BOOTSTRAP_ADMIN_PASSWORD comes through valueFrom keycloak-admin, removing change-me. Add a PostSync keycloak-config-cli Job (mirrored image, version-pinned to the Keycloak major) that imports the realm config from files/realm with $(env:...) substitution of the client secrets from platform-secrets. The config covers the clients teknoir (oauth2-proxy), argocd, harbor and backstage, the client scopes and group mappers, group admin and service-account roles. No human user is imported: the first admin comes from `teknoir-airgap admin-user` (user-controller creates the Keycloak user with a temporary password). For teknoir-local, generate the initial files from a read-only kcadm export of the live realm, so the first import changes nothing. Pin keycloak-theme to an immutable tag with IfNotPresent (G-09). Moving to a dedicated realm is an open decision.

**Test:** k3d or VM fresh install: a client-credentials token for each client works; the first admin's login (admin-user) forces a password change; a second import produces no changes (keycloak-config-cli reports no diff). The render test has no literal passwords.

### G-06 — harbor: deterministic token cert, OIDC config Job, PV nodeAffinity
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: G-04, G-05
- files: charts/harbor/values.yaml, charts/harbor/templates/oidc-config-job.yaml (new), charts/harbor/templates/harbor-pv.yaml, charts/harbor/Chart.yaml

Set core.secretName: harbor-token-service (created by I-07). Feed database.internal.password and the registry credentials from harbor-secret where the 1.18.3 chart allows it; otherwise rely on the G-03 ignoreDifferences for the htpasswd. Add a PostSync Job (mirrored curl+jq image) that reads the admin password and the OIDC client secret from Secrets, GETs /api/v2.0/configurations, and PUTs only the keys that differ (auth_mode oidc_auth, endpoint https://auth.<domain>/..., client id and secret, groups claim, admin group 'admin', verify cert with the CA bundle mounted); it never switches auth_mode once non-admin users exist. Give the hostPath PVs nodeAffinity on label teknoir.org/storage=true, which I-06 sets on the server node. Do the same for the auth keycloak-postgres PV in G-05.

**Test:** Two consecutive helm template renders produce byte-identical core Secret and Deployment annotations (apart from the htpasswd, which is ignored). On the VM, the OIDC login to Harbor works for the first admin (admin-user, group admin); re-running the Job PUTs nothing.

### G-07 — ArgoCD self-managed: move charts/argo to gitops, CA by Secret mount, protected CRDs
- repo: platform-applications-gitops (branch teknoir-local) + infra
- depends on: G-03, I-08, I-13
- files: charts/argo/** (moved from infra), charts/app-of-apps/templates/argo.yaml (new), infra: charts/argo (delete), scripts/deploy-argo.sh (delete)

Set configs.tls.create=false; argocd-tls-certs-cm is reconciled by I-07. For OIDC discovery, mount teknoir-system-ca-bundle into argocd-server and repo-server (an extra /etc/ssl/certs file, or SSL_CERT_DIR; verify on k3d) and drop rootCA from oidc.config, so no render-time CA is needed. Set crds.annotations to argocd.argoproj.io/sync-options: Prune=false,Delete=false. Declare the Harbor OCI repository in configs.repositories without credentials (the teknoir project is public). Add an argo Application with SSA, no finalizer and wave -5. Decide whether to disable the local admin or keep it as break-glass, and delete argocd-initial-admin-secret. Keep the ArgoCD images in the bootstrap tarballs. Live adoption follows M7a.

**Test:** k3d: ArgoCD adopts itself without restarting pods; deleting the argocd-repo-server Deployment self-heals; a chart bump upgrades ArgoCD through app-of-apps; Keycloak SSO and the Harbor OCI pull work with no rootCA in argocd-cm.

### G-08 — GitOps render and policy CI
- repo: platform-applications-gitops (branch teknoir-local)
- depends on: -
- files: .github/workflows/charts-ci.yml (new), tests/render.sh (new)

For every chart: helm template must succeed; every CRD carries Prune=false,Delete=false; no literal credentials (change-me, changeit, Harbor12345, harbor_registry_password); teknoir images are on non-mutable tags (warn, then error after G-09); every Application has retry and SSA; gitleaks.

**Test:** Re-introducing change-me in auth values fails CI; an unannotated CRD fails CI.

### G-09 — Immutable image tags for Teknoir images
- repo: platform-applications-gitops (+ image repos' CI: keycloak-theme, *-controller)
- depends on: G-08
- files: charts/auth/values.yaml, charts/*-controller/values.yaml

Replace :latest, :applicationset and :teknoir-cloud with released version tags and use pullPolicy IfNotPresent. This needs each image repo to publish version tags; that part is an open decision. Turn the G-08 and I-02 gates from warn to error.

**Test:** Render check: no Teknoir image without a semver or sha tag. A re-pin of app-of-apps to the previous version restores the previous image digests.

**r5 implementation (infra side; the gitops side is tests/render.sh):** no CI change was needed. The pin is `<repo>:<immutable tag>@sha256:<linux/amd64 manifest>`, where the immutable tag is `^sha-[0-9a-f]{7,}$`, `<branch>-YYYYMMDD-HHMMSS` or semver (`lib-build.sh` `IMMUTABLE_TAG_RE`, `teknoir_pin_ok`), and the digest is the amd64 manifest, never the index (`airgap/build/pin-images.sh` prints and verifies pins). `collect-images.sh` fails an unpinned Teknoir image in a platform render (`ALLOW_MUTABLE_TEKNOIR_TAGS=1` warns and marks the bundle `-mutable`), fails a pinned index and a digest in a one-shot tier, and only warns for the teamspace plugin renders and for floating non-Teknoir tags. On the node, `harbor_push_images` fails when a pin is not the bundle's manifest and verifies `<repo>@<pin>` in Harbor after the push; `post_image_check` checks `<repo>@<pin>` in the mirror and in containerd (whose ParseDockerRef drops the tag of a tag+digest reference).

### L-02 — Execute the live migration (M0-M6) in a maintenance window
- repo: live-env (teknoir-local)
- depends on: I-13, I-11, I-12, G-03, L-01, I-16
- files: runbook: docs/airgap/OPERATE.md#migration (temporary section)

Follow migration_for_live_env M0-M6 with the new bundle: backup, migrate --dry-run, migrate, up, deliberate k3s restart test, robot retirement, then the browser verification per CLAUDE.md. Requires explicit approval from Anders, and the VM rehearsal E10 and k3d T9 must be green.

**Test:** The M5 restart test gives identical before/after counts; every Application is Synced/Healthy; `get addons` has no Teknoir entries apart from teknoir-argo; the browser checks pass for harbor, argocd, auth and grafana with no certificate errors.

## Delete list

- infra airgap/upload-bundle.sh: the whole 8 GB bundle, secrets included, went to the node home; replaced by the content-addressed node/ payload sync in teknoir-airgap
- infra airgap/update-airgap.sh: an exec wrapper whose positional version had to equal the pin
- infra airgap/deploy-app-of-apps.sh: folded into teknoir-node release phase
- infra airgap/bootstrap-airgap.sh: replaced by teknoir-node converge, including the --update mode and restart_needed logic
- infra airgap/push-to-harbor.sh: replaced by node-side lib/harbor.sh; robot code, --robot-env/--robot-only/--rotate-robot, macOS --insecure crane path and python3 usage are removed
- infra airgap/extract-kubeconfig.sh: replaced by `teknoir-airgap kubeconfig`, which replaces entries instead of merging and names the context teknoir-local
- infra airgap/install-k3s.sh: folded into node lib/host.sh
- infra airgap/verify-offline.sh: folded into the make-bundle gate (build) and release post-check (live)
- infra airgap/render-bootstrap.sh: replaced by override-free render-oneshot.sh; TRACK_PY, FILTER_CRD_PY, render_split_chart, render_crds_only, 00-teknoir-namespaces, baked-IP coredns and the warn-only dry-run loop are removed
- infra airgap/lib.sh:661-819: CRD gate, argocd_failed_autosyncs, argocd_crd_handover_resync, version_ge, ISTIO_CRD_FREE_SINCE
- infra airgap/lib.sh:559-659: k3s_canonical_name, k3s_legacy_names, k3s_owners, k3s_retire_legacy; delete after the live migration
- infra airgap/lib.sh: chart_template_args/helm_template_chart overrides (excludedCRDs=[], certificate.enabled=false, cert-manager.crds.enabled=true, CA --set-file), RELEASED_CHARTS, PINS_FROM_WORKTREE, render_app_of_apps python, ssh_query/remote_kubectl quoting layer
- infra airgap/versions.env: BUNDLE_VERSION (derived), RELEASED_CHARTS, ISTIO_PILOT_IMAGE, ARGOCD_HELM_VERSION, ARGOCD_IMAGE_VERSION, HARBOR_HELM_VERSION, TOOL_PLATFORMS (replaced by LAN-kubectl list and node arch)
- infra airgap/images-extra.txt: duplicate proxyv2:1.29.2 and pause entries
- infra make-bundle.sh: step 4 (bootstrap/secrets), --diff/delta machinery, skip-if-present downloads, the second SECRET_MANIFESTS list
- infra scripts/gen-local-ca-secret.sh, gen-harbor-secrets.sh, gen-keycloak-db-secret.sh, gen-oauth2-proxy-redis-secret.sh, gen-oauth2-proxy-secrets.sh, gen-argocd-keycloak-secrets.sh, gen-argocd-harbor-repo-secret.sh
- infra scripts/deploy-secrets.sh, including --create-only, --bootstrap-wildcard and --retire-legacy
- infra scripts/deploy-argo.sh: bootstrap and ArgoCD own argo; it cannot run from a bundle
- infra scripts/copy-cert-secret.sh: teknoir-cloud-only, implicit kubectl context, shipped in the airgap bundle by accident
- infra teknoir-local-app-of-apps.yaml: the root Application is rendered from APP_OF_APPS_VERSION
- infra charts/argo/ and charts/argo/files/oidc.config: moved to gitops in G-07; render-time CA injection removed
- infra docs/AIRGAP-HOST-SETUP.md, docs/AIRGAP-BOOTSTRAP.md, docs/AIRGAP-UPDATE.md: replaced by docs/airgap/{BUILD,HOST-SETUP,OPERATE,CHANGELOG}.md; history moves to the CHANGELOG
- infra README_infra.md airgap sections that describe robot/secret-file/CRD-gate procedures
- infra .air/plans/*, .junie/plans/*: stale (teknoir.local, /Volumes/GIT paths)
- gitops charts/istio/templates/certificate.yaml and the certificate.enabled value: moved to the cert-manager chart
- gitops charts/app-of-apps/templates/istio.yaml and cert-manager.yaml: helm.skipCrds: true
- gitops charts/cert-manager/values.yaml comment and setup claiming bootstrap-owned CRDs, replaced by the vendored crds/
- gitops charts/auth/values.yaml:41-44: literal KC_BOOTSTRAP_ADMIN_PASSWORD change-me
- Node K3s files, via the detach recipe, not by deleting them directly: 00-teknoir-namespaces.yaml, 00-teknoir-istio-crds.yaml, 05-teknoir-certmanager-crds.yaml, teknoir-coredns-custom.yaml, teknoir-app-of-apps.yaml, all teknoir-*-secret.yaml (10), all manifest-*-secret.yaml (8); later teknoir-argo.yaml
- Node orphan Addon objects: 10-teknoir-argo, app-of-apps, manifest-argocd-harbor-repo-secret
- Node /home/teknoir/teknoir-airgap-bundle-0.1.0: CA key and secrets at mode 0644, unsafe pre-fix bundle
- Node /opt/k3s/agent/images stale tarballs not in the current bundle: goharbor *_v2.15.2, valkey-photon, busybox_1.28/latest if unused, dex, redis 8.6.4 if unused (pruned by host phase)
- Harbor robot$argocd and the ArgoCD repo-creds Secret using it, after the credential-less repository is live
- vpro infra-teknoir-local/bundle/teknoir-airgap-bundle-0.1.0 and the plaintext .secrets/: move to an encrypted backup, then delete
