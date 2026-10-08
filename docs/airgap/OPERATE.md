# Operating the airgapped Teknoir platform

Everything an operator does runs from an extracted bundle on a LAN host, with one
command: `./teknoir-airgap`. The first install and every update are the same
command, `./teknoir-airgap up`, and it is safe to run again at any time: it only
changes what differs and resumes where an interrupted run stopped.

Read [HOST-SETUP.md](HOST-SETUP.md) once before the first install (Debian on the
node, ssh access from the LAN host). Bundles are built as described in
[BUILD.md](BUILD.md). History and the reasons behind this design are in
[CHANGELOG.md](CHANGELOG.md).

The examples use the default site, `site/teknoir-local.env` in the bundle:

| Setting | Value |
|---|---|
| Domain | `teknoir.airgapped` (Backstage at `https://teknoir.airgapped/`) |
| Node address (`NODE_IP`) | `192.168.5.181` |
| ssh target (`NODE`) | `teknoir@192.168.5.181` |
| Platform names | `harbor`, `argocd`, `auth`, `keycloak`, `grafana` + `.teknoir.airgapped`, and the domain itself |
| kubectl context | `teknoir-local` |

Contents:

1. [How it works](#1-how-it-works)
2. [Carry and check a bundle](#2-carry-and-check-a-bundle)
3. [First install](#3-first-install)
4. [Update](#4-update)
5. [Rollback](#5-rollback)
6. [Status and checks](#6-status-and-checks)
7. [Kubeconfig and trust on a LAN host](#7-kubeconfig-and-trust-on-a-lan-host)
8. [Credentials](#8-credentials)
9. [Users and Backstage sign-in](#9-users-and-backstage-sign-in)
10. [Backup and restore](#10-backup-and-restore)
11. [Rotating secrets](#11-rotating-secrets)
12. [Troubleshooting](#12-troubleshooting)
13. [Who owns what](#13-who-owns-what)
14. [Migrating the live teknoir-local (temporary)](#14-migrating-the-live-teknoir-local-temporary)
15. [Command reference](#15-command-reference)

## 1. How it works

```
[build machine, online]      [USB]      [LAN host]                         [node 192.168.5.181]
make-bundle.sh ──► teknoir-airgap-<id>.tar ──► ./teknoir-airgap up ── ssh ──► teknoir-node converge
                   + .tar.sha256                verify, copy payload,          host, secrets, Harbor,
                                                kubeconfig, CA                 release, checks
```

`./teknoir-airgap up` on the LAN host:

1. verifies every file of the extracted bundle against `MANIFEST.yaml`;
2. connects over ssh with the node's host key pinned in
   `~/.teknoir-airgap/<site>/known_hosts` (the first connection asks you to
   confirm the fingerprint);
3. the first time only: asks once for the node user's sudo password and installs
   `/etc/sudoers.d/teknoir-airgap`;
4. copies the bundle's node payload to
   `/var/lib/teknoir-airgap/bundles/<bundleId>/node`, sending only files the node
   does not already have with the right sha256;
5. runs `teknoir-node converge` on the node as root, streaming its output;
6. saves the cluster's kubeconfig as context `teknoir-local` and the platform CA
   certificate in `~/.teknoir-airgap/<site>/teknoir-root-ca.crt`.

The converge on the node runs these phases, each idempotent:

| Phase | What it does |
|---|---|
| verify | checks the payload against `node/SHA256SUMS` before changing anything |
| preflight | `NODE_IP` is the node's address, enough free disk, clock within 30 s of the LAN host, bundle not older than the deployed release |
| backup | when the cluster runs another bundle: a backup to `/var/lib/teknoir-airgap/backups/<ts>` (keeps 3) |
| host | k3s install or upgrade (only when the version or config changes), `registries.yaml`, the CA in the OS and k3s trust, the `/etc/hosts` block, chrony, bootstrap images; restarts k3s only when its config changed |
| cluster-base | `coredns-custom` with `NODE_IP`, missing namespaces |
| secrets | creates the CA, the wildcard certificate placeholder and the Harbor token certificate if absent; refreshes the public CA copies |
| one-shot | first install only: applies platform-secrets, istio, harbor and argo once, then ArgoCD owns them |
| harbor | Harbor projects, charts and images (skips what is already there) |
| release | pins the root Application `app-of-apps` to the bundle's version and records the release |
| post | waits for every Application to be Synced and Healthy, checks that every running image is available offline, prunes old payloads |

Integrity is checked three times, and each check is fatal: you check the tar
against its `.tar.sha256`, `teknoir-airgap` checks the extracted files against
`MANIFEST.yaml` before any ssh, and the node checks its copy before any change.

No secret ever travels in a bundle or appears on a screen. Every password, key
and token is generated inside the cluster on the node, and the commands that hand
one out write it to a file with mode 0600.

Where things live:

| What | Where |
|---|---|
| Bundle payloads (current and previous) | node: `/var/lib/teknoir-airgap/bundles/<bundleId>/node` |
| Site config used by the converge | node: `/var/lib/teknoir-airgap/site/<site>.env` |
| Converge logs | node: `/var/log/teknoir-airgap/<UTC>-<command>.log` (mode 0600) |
| Automatic backups | node: `/var/lib/teknoir-airgap/backups/<ts>` (mode 0700, last 3) |
| Release record | ConfigMap `teknoir-system/teknoir-airgap-release` |
| k3s data | node: `/opt/k3s` (always pass `--data-dir /opt/k3s` to `k3s etcd-snapshot`, `k3s secrets-encrypt`, `k3s certificate` and the other k3s subcommands) |
| LAN cache: pinned host key, CA certificate, logs | LAN host: `~/.teknoir-airgap/<site>/` (safe to delete; `up` re-creates it) |
| Kubeconfig | LAN host: `~/.kube/config`, context `teknoir-local` |

## 2. Carry and check a bundle

Copy `teknoir-airgap-<bundleId>.tar` and `teknoir-airgap-<bundleId>.tar.sha256`
from the USB medium to the LAN host, then:

```sh
shasum -a 256 -c teknoir-airgap-<bundleId>.tar.sha256     # macOS
sha256sum -c teknoir-airgap-<bundleId>.tar.sha256         # Linux
tar -xf teknoir-airgap-<bundleId>.tar
cd teknoir-airgap-<bundleId>
./teknoir-airgap version      # bundle id, commits, app-of-apps and k3s versions
./teknoir-airgap verify       # optional: up verifies too
```

If the bundle was split for a FAT32 medium ([BUILD.md](BUILD.md#3-copy-to-the-usb-medium)),
join the parts first: `cat teknoir-airgap-<bundleId>.tar.part-* > teknoir-airgap-<bundleId>.tar`. Never edit files inside the extracted
bundle: `verify` and `up` refuse a bundle that differs from its `MANIFEST.yaml`.
macOS Finder files (`.DS_Store`, `._*`) are ignored.

Every command below runs from this directory. `./teknoir-airgap help` prints the
complete reference.

## 3. First install

Prerequisites: the node is installed as in [HOST-SETUP.md](HOST-SETUP.md) (static
address `192.168.5.181`, user `teknoir` with sudo rights, `ssh teknoir@192.168.5.181`
works with your key) and you hold a checked bundle (section 2).

1. Install the platform:

   ```sh
   ./teknoir-airgap up
   ```

   - It shows the ssh host key fingerprint the node presents. Compare it with
     the one you noted on the node console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`)
     and type `yes`.
   - It asks once for `teknoir`'s sudo password on the node.
   - It copies about 3 GB, installs k3s and the platform and waits for every
     Application. Expect 30 to 45 minutes.
   - It ends with `bundle <bundleId> is deployed on teknoir@192.168.5.181`.

2. Let this LAN host resolve the platform names and trust its CA (uses sudo on
   the LAN host; see section 7):

   ```sh
   ./teknoir-airgap trust
   ```

3. Check:

   ```sh
   ./teknoir-airgap status
   ./teknoir-airgap doctor
   ```

4. Get the initial platform admin's password into a file and sign in:

   ```sh
   ./teknoir-airgap credentials platform-admin --out ~/teknoir-platform-admin.txt
   ```

   Sign in at `https://auth.teknoir.airgapped/realms/teknoir/account` as
   `platform-admin` with that password. Keycloak asks for a new password at
   once. Then delete the file. The auth chart's realm import creates
   `platform-admin` (e-mail `platform-admin@teknoir.airgapped`) in the Keycloak
   group `admin`, which makes it an administrator in ArgoCD and Harbor. It has
   no Backstage user: Backstage needs the named admin of the next step.

5. Create a named admin for each person, and sign in to Backstage with it
   (section 9):

   ```sh
   ./teknoir-airgap admin-user --email anders.aslund@teknoir.ai --out ~/teknoir-admin.txt
   ```

The Keycloak realm `teknoir` (clients, scopes, the `admin` group), the Harbor
OIDC settings and every secret are created by the converge and GitOps; there are
no manual Keycloak or Harbor UI steps.

Verification checklist:

- [ ] `./teknoir-airgap status`: every Application `Synced`/`Healthy`, and the
      release shows this bundle id.
- [ ] `./teknoir-airgap doctor` reports no `FAIL`.
- [ ] `kubectl --context teknoir-local get nodes` shows the node `Ready`.
- [ ] In a browser on the LAN host, with no certificate warning:
      `https://harbor.teknoir.airgapped`, `https://argocd.teknoir.airgapped`,
      `https://grafana.teknoir.airgapped`,
      `https://auth.teknoir.airgapped/realms/teknoir/account` and
      `https://teknoir.airgapped/` (Backstage); single sign-on works on each.

## 4. Update

An update is the same command with a newer bundle:

1. Build it ([BUILD.md](BUILD.md)), carry it and check it (section 2).
2. Optionally preview what changes:

   ```sh
   ./teknoir-airgap up --dry-run
   ```

   A dry run still copies the bundle payload to the node (a cache that changes
   nothing by itself), then the node reports what it would change. It needs the
   one-time sudo setup from the first install.
3. Roll it out:

   ```sh
   ./teknoir-airgap up
   ```

That is all. The node takes a backup first, then converges k3s and the node
files, the secrets, Harbor's content and the app-of-apps pin; ArgoCD then rolls
out the new chart versions. A bundle older than the deployed release is refused
(section 5).

Verification checklist:

- [ ] `./teknoir-airgap status` shows the new bundle id and app-of-apps version,
      and every Application `Synced`/`Healthy`.
- [ ] `./teknoir-airgap doctor` reports no `FAIL`.
- [ ] The browser checks from section 3 pass.

## 5. Rollback

To go back to an older release, run `up` from the older bundle (extracted from
its own tar) with `--rollback`:

```sh
cd teknoir-airgap-<older bundleId>
./teknoir-airgap up --rollback
```

- Without `--rollback`, a bundle whose app-of-apps version is older than the
  deployed one is refused.
- app-of-apps 0.0.1 and 0.0.2 are refused even with `--rollback` (their Harbor
  contents were overwritten in 2026-09; see the CHANGELOG).
- The release record keeps the rollback, so a later plain `up` with the same
  older bundle stays on it. Moving forward again is a plain `up` with a newer
  bundle.
- A rollback re-pins charts and images. It does not undo a database migration
  that a newer chart already ran (Keycloak, Harbor): if one did, restore the
  databases from the backup taken before the update (section 10).

## 6. Status and checks

```sh
./teknoir-airgap status
```

Read-only for the node and the cluster; it only refreshes the node's copy of the
site config. Shows the bundle and site, the clock skew between the LAN host and the
node, k3s, the nodes, the release record (deployed bundle id), the ArgoCD
Applications and the bundle payloads on the node; when this bundle is on the
node it adds `teknoir-node status` (Harbor, certificate expiry and more).

```sh
./teknoir-airgap doctor
```

Checks this LAN host (tools, bundle integrity, name resolution of every platform
name to `NODE_IP`, CA trust, a TLS request to Harbor, macOS quarantine) and the
node (ssh with the pinned key, passwordless sudo, clock skew, the tools the
converge uses, chrony, `NODE_IP` on the node). Each line is `ok`, `WARN` or
`FAIL`; it exits non-zero on any `FAIL`.

Directly, with the kubeconfig from section 7:

```sh
kubectl --context teknoir-local -n teknoir-system get applications
kubectl --context teknoir-local -n teknoir-system get configmap teknoir-airgap-release -o yaml
```

On the node: `sudo k3s kubectl ...`, and the converge logs in
`/var/log/teknoir-airgap/`.

## 7. Kubeconfig and trust on a LAN host

`up` already does both for the LAN host it runs on. For another LAN host, give it
ssh access first ([HOST-SETUP.md](HOST-SETUP.md#4-give-the-lan-host-ssh-access)),
copy the bundle there, then:

```sh
./teknoir-airgap kubeconfig
./teknoir-airgap trust
```

`kubeconfig` reads `/etc/rancher/k3s/k3s.yaml` on the node and writes it into
`~/.kube/config` as context, cluster and user `teknoir-local`, with the server
`https://192.168.5.181:6443`. Older entries with that name are replaced, not
merged, so a reinstalled cluster's new credentials always win; other contexts and
your current context stay as they are, and the previous file is kept as
`~/.kube/config.teknoir-airgap.bak`. Options: `--context NAME` and
`--kubeconfig FILE`, for example:

```sh
./teknoir-airgap kubeconfig --context teknoir-lab --kubeconfig ~/.kube/teknoir-lab.yaml
```

Merging uses a kubectl: the bundle's `tools/<os>-<arch>/kubectl`, or one on
`PATH`. Without either, an existing `~/.kube/config` is left alone and the
kubeconfig goes to `~/.teknoir-airgap/<site>/kubeconfig`.

`trust` makes the LAN host's browsers and tools work with the platform:

- it writes (or replaces) a marked block in `/etc/hosts` that maps the domain and
  every platform name to `NODE_IP`;
- it adds the platform CA certificate (public part only) to the OS trust store:
  `/usr/local/share/ca-certificates/teknoir-airgap-<site>.crt` and
  `update-ca-certificates` on Debian and Ubuntu, the System keychain on macOS,
  and the user NSS database used by Chrome on Linux when `certutil` is installed.

To review or apply the changes by hand, print them instead:

```sh
./teknoir-airgap trust --print
```

Firefox keeps its own trust store: import `~/.teknoir-airgap/teknoir-local/teknoir-root-ca.crt`
under Settings > Privacy & Security > Certificates > View Certificates >
Authorities, and tick "Trust this CA to identify websites". Restart browsers
after `trust`.

## 8. Credentials

```sh
./teknoir-airgap credentials platform-admin --out ~/teknoir-platform-admin.txt
```

Writes one credential to the `--out` file with mode 0600 and never prints it. It
refuses a terminal, `-` and any path inside the bundle directory. Delete the file
when you no longer need it, and never paste a credential into a chat or ticket.

| Name | What |
|---|---|
| `platform-admin` | the initial Keycloak administrator in realm `teknoir` (group `admin`: ArgoCD, Harbor), created by the realm import; its password must be changed at the first sign-in. No Backstage user: use `admin-user` (section 9) |
| `keycloak-admin`, `keycloak-admin-username` | the Keycloak master realm administrator (break-glass) |
| `harbor-admin` | Harbor's local `admin` (break-glass; also `https://harbor.teknoir.airgapped/account/sign-in` when OIDC is on) |
| `argocd-admin` | ArgoCD's local `admin` (break-glass) |
| `grafana-admin` | Grafana's local administrator |

The node runner defines these names (`teknoir-node help` on the node lists
them).

## 9. Users and Backstage sign-in

Create a named administrator for each person:

```sh
./teknoir-airgap admin-user --email anders.aslund@teknoir.ai --out ~/teknoir-admin.txt
```

This:

- creates the `users.teknoir.org` User `anders.aslund-at-teknoir.ai` (the
  e-mail address in lower case with `@` replaced by `-at-`), role `superadmin`,
  e-mail verified;
- lets user-controller create the Keycloak user in realm `teknoir` with a
  temporary password, and puts it in the group `admin`;
- restarts Backstage's backend once, so its catalog knows the user right away
  (it otherwise reads users every 30 minutes);
- writes the temporary password to the `--out` file (mode 0600). On the node it
  exists only for a moment, in a root-only file under
  `/var/lib/teknoir-airgap/tmp`, which `teknoir-airgap` copies and deletes.

The address is used in lower case. It may contain letters, digits, `.` and `-`
around one `@`, with `.` and `-` only between letters or digits; `_` and `+` are
refused. The user name (the address with `@` replaced by `-at-`) must be a valid
Kubernetes and Backstage entity name of at most 63 characters, so the address
can have at most 60.

Re-running `admin-user` for the same address is safe: it leaves the User as it
is and writes the temporary password user-controller recorded again (useless
once that user has changed it). If the Keycloak user existed before
user-controller saw it, there is no temporary password: the command says so and
writes no file; set a password in Keycloak (realm `teknoir`, Users).

Sign in:

1. Open `https://teknoir.airgapped/`. You are sent to the Keycloak sign-in page of
   realm `teknoir`.
2. Sign in with the e-mail address and the temporary password from the file.
3. Keycloak asks for a new password, and possibly for first and last name.
4. Backstage opens. Delete the password file.

What does not work yet: the new user has no teamspace, and creating teamspaces
is not available on the airgapped platform in this release (the per-teamspace
charts are not mirrored yet).

## 10. Backup and restore

### Backups on the node

Before a converge that changes the deployed bundle (an update, a rollback, or the
first `up` on an existing cluster), the node writes a backup to
`/var/lib/teknoir-airgap/backups/<UTC>/` (mode 0700, the last 3 are kept).
Re-running the deployed bundle takes none, so the backups from before the last
update survive. `./teknoir-airgap backup` takes one on demand. A backup holds:

| Path in the backup | Content |
|---|---|
| `db/harbor.sql.gz`, `db/keycloak.sql.gz` | `pg_dumpall` of the Harbor and Keycloak databases (gzip-compressed SQL) |
| `k3s/db/` | the k3s datastore (copied during a brief `systemctl stop k3s`; running pods keep running) |
| `k3s/server/token`, `k3s/server/tls/`, `k3s/server/cred/` | the cluster token and certificates |
| `k3s/etc/config.yaml`, `k3s/etc/registries.yaml` | the k3s configuration |
| `secrets/bootstrap-secrets.json` | the Secrets a restore needs first: the CA, Harbor, Keycloak, the client secrets, oauth2-proxy, Backstage |
| `BACKUP.info`, `SHA256SUMS` | what was backed up, and checksums |

Container images and Harbor's registry blobs are not in the backup: every bundle
carries them and `up` pushes them again.

### A copy off the node

```sh
./teknoir-airgap backup --out /media/usb/teknoir-backups
```

This takes a fresh backup on the node, encrypts it there with `age` (you choose a
passphrase; it is asked twice) and copies
`teknoir-backup-<site>-<ts>.tar.age` into the `--out` directory (mode 0600). The
encrypted copy on the node is removed once the local file's sha256 matches it;
if the copy fails, it stays in `/var/lib/teknoir-airgap/exports/`. The
unencrypted backup never leaves the node. Keep the passphrase apart from the
file, for example in your password manager: without it the backup is useless. Run
it in a terminal; it needs one for the passphrase.

### Restore

Restore with two people and this section open; check each step's result before
the next. The restore commands run in a root shell on the node; the node's
bundle payload provides `age` at
`/var/lib/teknoir-airgap/bundles/<bundleId>/node/bin/age`.

1. Put the backup on the node and decrypt it there:

   ```sh
   scp teknoir-backup-teknoir-local-<ts>.tar.age teknoir@192.168.5.181:/tmp/
   ssh -t teknoir@192.168.5.181 sudo -i
   install -d -m 0700 /root/restore
   /var/lib/teknoir-airgap/bundles/<bundleId>/node/bin/age -d \
     -o /root/restore/backup.tar /tmp/teknoir-backup-teknoir-local-<ts>.tar.age
   tar -C /root/restore -xf /root/restore/backup.tar
   rm /tmp/teknoir-backup-teknoir-local-<ts>.tar.age
   cd /root/restore/<ts> && sha256sum -c SHA256SUMS && cat BACKUP.info
   ```

   A backup still on the node needs no decryption: use
   `/var/lib/teknoir-airgap/backups/<ts>/` instead of `/root/restore/<ts>/`.

2. Lost data inside a running cluster (for example a Keycloak realm or users, or
   a Harbor project): restore only that database. The dumps are `pg_dumpall`
   output, so drop the damaged database and let the dump re-create it. For
   Keycloak (pod `keycloak-db-0`, database user in `$POSTGRES_USER` inside the
   pod):

   ```sh
   cd /root/restore/<ts>
   gunzip -c db/keycloak.sql.gz | grep '^CREATE DATABASE'      # the database name
   k3s kubectl -n teknoir-auth scale statefulset keycloak --replicas=0
   k3s kubectl -n teknoir-auth exec keycloak-db-0 -- \
     sh -c 'psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE <name>"'
   gunzip -c db/keycloak.sql.gz | k3s kubectl -n teknoir-auth exec -i keycloak-db-0 -- \
     sh -c 'psql -U "$POSTGRES_USER" -d postgres'
   k3s kubectl -n teknoir-auth scale statefulset keycloak --replicas=1
   ```

   For Harbor, the same with pod `harbor-database-0` in `teknoir-system`, user
   `postgres`, the database `registry`, `db/harbor.sql.gz`, and the deployments
   `harbor-core` and `harbor-jobservice` scaled to 0 and back to 1. Messages
   that a role or the `postgres` database already exists are expected. Then run
   `./teknoir-airgap up` from the LAN host: it pushes any missing images and
   checks every Application.

3. A rebuilt node (new disk or reinstalled OS):
   1. Install Debian as in [HOST-SETUP.md](HOST-SETUP.md), with the same `NODE_IP`.
   2. Run `./teknoir-airgap up --forget-host-key` with the bundle that was deployed
      (the node has a new ssh host key). This installs k3s and a fresh platform.
   3. In a root shell on the node, put the cluster state back: stop k3s
      (`systemctl stop k3s`), replace `/opt/k3s/server/db`,
      `/opt/k3s/server/token`, `/opt/k3s/server/tls` and `/opt/k3s/server/cred`
      with `k3s/db`, `k3s/server/token`, `k3s/server/tls` and `k3s/server/cred`
      from the backup, move the fresh database directories
      `/opt/teknoir/keycloak/pg` and `/opt/teknoir/harbor/database` aside (their
      passwords no longer match the restored Secrets), and start k3s
      (`systemctl start k3s`). The databases start empty with the restored
      passwords. (On an etcd datastore the backup holds `k3s/etcd-snapshot`
      instead; restore it with
      `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot> --data-dir /opt/k3s`.)
   4. Load the Keycloak and Harbor dumps as in step 2 (the databases are empty,
      so nothing needs dropping).
   5. Run `./teknoir-airgap up` again. It pushes the images, re-applies the node
      files and checks every Application.
   6. Verify: sign in to Keycloak, Harbor and ArgoCD with existing users, and
      check that Harbor lists its projects and charts.

Finally remove the decrypted files: `rm -rf /root/restore` (root shell).

## 11. Rotating secrets

```sh
./teknoir-airgap rotate <name>
./teknoir-airgap rotate <name> --i-know
```

`rotate` replaces exactly one generated secret and restarts what uses it; the
node runner prints what it did. Rotation is never implicit: re-running `up`
never changes an existing secret.

| Name | Effect | Notes |
|---|---|---|
| `oauth2-proxy-cookie` | new oauth2-proxy cookie secret; oauth2-proxy restarts and everyone signs in again | safe at any time |
| `oauth2-proxy-redis` | new Redis password; Redis and oauth2-proxy restart, sessions are lost | safe at any time |
| `harbor-token-service` | new Harbor token certificate; harbor-core restarts | safe at any time |
| `harbor-secret-key` | new Harbor `secretKey`; Harbor can no longer decrypt values it stored with the old key (the OIDC client secret and similar) and they must be set again | refused without `--i-know`; take a backup first |
| `keycloak-db` | new Keycloak database password; it must also change inside PostgreSQL | refused without `--i-know`; take a backup first |

Not rotatable with `rotate` in this release: the Keycloak client secrets (the
realm import and their consumers would need a coordinated change), the admin
passwords (change them in the application; Harbor and Keycloak keep theirs in
their databases after the first start) and the platform CA (the live
teknoir-local keeps its current CA; a new CA means running
`./teknoir-airgap trust` on every LAN host again).

Never delete `backstage-postgres-secrets` while the PVC
`data-backstage-postgres-0` exists: a new random password would be generated, but
the database keeps the one it was initialized with.

## 12. Troubleshooting

**The host key changed.** `up` stops with `ssh host key mismatch` and prints the
fix. If the node was reinstalled, check the new fingerprint on its console
(`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), then:

```sh
./teknoir-airgap up --forget-host-key
```

If the node was not reinstalled, stop: another machine may answer on that
address.

**First connection without a terminal** (automation). Pass the fingerprint you
checked on the node console:

```sh
./teknoir-airgap up --host-key SHA256:<fingerprint>
```

**`no passwordless sudo yet`.** Run `./teknoir-airgap up` once in a terminal; it
asks for the sudo password once. If sudo refuses, the node user has no sudo
rights: when the Debian installer was given a root password, it installs no sudo
and does not put the first user in the `sudo` group. As root on the node console,
install sudo from the installation medium (`apt-get install sudo`), run
`usermod -aG sudo teknoir`, and log in again.

**Clock skew.** The converge refuses to run when the node and the LAN host differ
by more than 30 seconds. Set the clock on the side that is wrong, or let `up` set
the node's clock from the LAN host:

```sh
./teknoir-airgap up --sync-clock
```

**Interrupted run.** Run `./teknoir-airgap up` again. The payload copy resumes per
file and every converge phase skips what is already done. If the node says a
converge is already running (exit status 75), wait for it; only one runs at a
time.

**The bundle does not verify.** Copy the tar from the USB medium again and check
it against its `.tar.sha256`. Never fix files by hand.

**macOS: "cannot be opened" or a killed kubectl.** The tar was downloaded with a
browser or AirDrop and carries the quarantine attribute. `doctor` reports it;
clear it with `xattr -dr com.apple.quarantine teknoir-airgap-<bundleId>`.

**A platform name does not resolve or the browser warns about the certificate.**
Run `./teknoir-airgap doctor`, then `./teknoir-airgap trust`. Firefox needs the CA
imported separately (section 7). A certificate warning is itself a finding: do
not click through it.

**The converge fails.** Its last lines name the failing step; the full log is in
`/var/log/teknoir-airgap/` on the node. Fix the cause and run `up` again.

**An Application stays `OutOfSync` or shows a sync error.** Each Application
retries with back-off. To retry at once:

```sh
kubectl --context teknoir-local -n teknoir-system patch application <name> --type merge \
  -p '{"operation": {"initiatedBy": {"username": "operator"}, "sync": {}}}'
```

or use the ArgoCD UI (`https://argocd.teknoir.airgapped`, Sync).

**Harbor is down.** The platform keeps running: the bootstrap images (Istio,
ArgoCD, Harbor itself) are imported into containerd from the bundle, so they
start without Harbor. Check `kubectl --context teknoir-local -n teknoir-system get pods -l app=harbor`
and the events; `up` re-pushes missing images once Harbor is back.

**ArgoCD UI actions fail with "Request has been terminated".** The signed-in user
is not an ArgoCD admin (not in the Keycloak group `admin`), and the gateway turns
ArgoCD's `403` into a redirect the UI cannot follow. Add the user to the group
(or use `./teknoir-airgap admin-user`), then sign out and in again.

**Backstage says "user not found in catalog".** The catalog reads User objects
every 30 minutes; `admin-user` restarts Backstage's backend once so a new user can
sign in right away. Run it again, or wait.

## 13. Who owns what

Every object has exactly one owner, and there are no Teknoir files in the k3s
auto-deploy directory (`/opt/k3s/server/manifests`).

| Objects | Owner | Changed by |
|---|---|---|
| k3s binary, `/etc/rancher/k3s/config.yaml` and `registries.yaml`, the CA in the OS and k3s trust, the `/etc/hosts` block, chrony, bootstrap image tarballs in `/opt/k3s/agent/images` | the node converge (host phase) | `up`; files are written only when their content differs; k3s restarts only when its config changes |
| `kube-system/coredns-custom`, the root Application `teknoir-system/app-of-apps`, ConfigMap `teknoir-system/teknoir-airgap-release`, `argocd-tls-certs-cm` entry for Harbor, the public CA copies `teknoir-root-ca-bundle` | the node converge (server-side apply, field manager `teknoir-bootstrap`) | every `up` |
| The CA `cert-manager/teknoir-root-ca`, the wildcard certificate placeholder in `istio-system`, `teknoir-system/harbor-token-service` | the node converge, created once | `rotate` only |
| Random secrets (Harbor, Keycloak database and admin, Keycloak client secrets, oauth2-proxy, Backstage) | the `platform-secrets` chart's Job, created once; copies re-synced | `rotate` only; a new secret is a GitOps change |
| platform-secrets, istio (with its CRDs), harbor, argo | applied once on a new node, then ArgoCD | GitOps (new chart and app-of-apps version) |
| cert-manager (CRDs, `teknoir-ca` issuer, wildcard Certificate), auth (Keycloak realm as code), monitoring, the controllers, Backstage | ArgoCD | GitOps |
| Harbor content (projects, charts, images) | the node converge (harbor phase) | `up`; charts are immutable, mirror tags move only with `--force-images` |
| Namespaces | the GitOps charts that label them | the converge only creates a missing one |
| `~/.teknoir-airgap/<site>/`, `~/.kube/config` context `teknoir-local` | the LAN host | `up`, `kubeconfig`, `trust` (re-derivable) |

## 14. Migrating the live teknoir-local (temporary)

This section exists until the live `teknoir-local` runs on this model; then it,
the `migrate` command and the remaining legacy code are removed. Do not start
before all prerequisites hold, and only in an agreed maintenance window with
Anders' approval.

**M0. Prerequisites.**

- The k3d ownership tests (T2, T4, T5, T6, T9) and the VM migration rehearsal
  (E10) pass.
- The bundle contains the GitOps releases of this redesign (app-of-apps 0.0.4)
  and the realm import was generated from a read-only export of the live realm.
- The platform-secrets spec names the live Secrets and keys exactly, so they are
  adopted, not regenerated.

**M1. Hygiene, before anything else.** Rotate the Keycloak master admin away from
the published default password, delete the old bundle copy in
`/home/teknoir/teknoir-airgap-bundle-0.1.0` on the node (it holds the CA key and
other secrets at mode 0644), and move any `.secrets/` and `bundle/*/bootstrap/secrets`
copies on laptops and USB media into an encrypted backup.

**M2. Backup and baseline.** `backup` is the first `teknoir-airgap` command on
the live node. Run it in a terminal: it asks you to confirm the node's ssh host
key, asks once for `teknoir`'s sudo password (and installs
`/etc/sudoers.d/teknoir-airgap`), copies the bundle payload (about 3 GB) and the
site config to the node, then takes the backup. Do not run `up` before M4.

```sh
./teknoir-airgap backup --out /media/usb/teknoir-local-premigration
kubectl --context teknoir-local get crd -o name | sort > before-crds.txt
kubectl --context teknoir-local get ns,secrets -A --no-headers | wc -l > before-counts.txt
kubectl --context teknoir-local get virtualservices,gateways,destinationrules,authorizationpolicies,peerauthentications,certificates,clusterissuers,applications -A --no-headers | wc -l >> before-counts.txt
```

**M3. Detach the k3s manifest files** (the orphan Addons, the 8 legacy
`manifest-*-secret` files, the 10 `teknoir-*-secret` files, the namespaces, the
CRDs, `coredns-custom` and the root app-of-apps; `teknoir-argo` stays until M7).
Each file gets a `.skip` guard, is moved to
`/opt/k3s/server/manifests-retired/<UTC>/`, its objects lose the k3s ownership
labels, and its Addon is deleted; the object counts are checked after every
file.

```sh
./teknoir-airgap migrate --dry-run     # review the list
./teknoir-airgap migrate
./teknoir-airgap migrate --undo <name> # only to re-attach one file
```

Verify:

```sh
kubectl --context teknoir-local get addons -n kube-system   # only k3s's own addons, plus teknoir-argo
kubectl --context teknoir-local get crd,ns,secrets -A -l objectset.rio.cattle.io/hash --no-headers   # none of Teknoir's
ssh teknoir@192.168.5.181 sudo ls /opt/k3s/server/manifests   # .skip guards; no Teknoir *.yaml but teknoir-argo.yaml
```

**M4. Converge.**

```sh
./teknoir-airgap up
```

The node creates only what is missing (the Harbor token certificate,
`keycloak-platform-admin`, the Backstage secrets) and leaves every existing
Secret untouched; ArgoCD adopts the CRDs and moves the wildcard Certificate to
the cert-manager Application; harbor-core rolls once and then stops drifting.
Verify:

```sh
kubectl --context teknoir-local -n teknoir-system get applications
kubectl --context teknoir-local -n teknoir-system get cm teknoir-airgap-release -o yaml
kubectl --context teknoir-local -n teknoir-system get rs -l component=core   # no new ReplicaSet in the next hour
```

plus the browser checks from section 3.

**M5. Restart test.**

```sh
ssh teknoir@192.168.5.181 sudo systemctl restart k3s
```

Repeat the M2 counts: they must be equal, no Teknoir Addon re-appears, every
Application stays `Synced`, and the Secrets keep their `resourceVersion`.

**M6. Retire the Harbor robot.** Once app-of-apps syncs through the credential-less
repository, delete the old `teknoir-system/argocd-harbor-repo` Secret and the
Harbor robot account `robot$argocd`.

**M7. Later windows.** ArgoCD self-management (detach `teknoir-argo` the same
way), k3s secrets encryption
(`sudo k3s secrets-encrypt enable --data-dir /opt/k3s`, restart,
`sudo k3s secrets-encrypt reencrypt --data-dir /opt/k3s`), and, if decided, the
datastore move to embedded etcd.

**M8. Clean-up.** Remove the `migrate` command, this section and the legacy
code.

## 15. Command reference

`./teknoir-airgap help` prints this with every option. Options that every command
takes: `--site FILE|NAME`, `--node USER@HOST`, `--local` (run on the node itself,
from a bundle copied there), `--forget-host-key`, `--host-key FINGERPRINT`.

| Command | What it does |
|---|---|
| `./teknoir-airgap up` | Install or update (`--dry-run`, `--rollback`, `--sync-clock`, `--reapply TIER`, `--force-images`, `-- ARGS`) |
| `./teknoir-airgap status` | Report (changes only the node's copy of the site config) |
| `./teknoir-airgap verify` | Check the bundle against `MANIFEST.yaml` (no ssh) |
| `./teknoir-airgap version` | Bundle id and versions |
| `./teknoir-airgap kubeconfig` | Write the kubeconfig (`--context NAME`, `--kubeconfig FILE`) |
| `./teknoir-airgap trust` | `/etc/hosts` block and CA trust on this LAN host (`--print`) |
| `./teknoir-airgap credentials NAME --out FILE` | One credential into a 0600 file |
| `./teknoir-airgap admin-user --email ADDRESS --out FILE` | A named admin; temporary password into a 0600 file |
| `./teknoir-airgap backup --out DIR` | Encrypted node backup copied to this host |
| `./teknoir-airgap rotate NAME` | Replace one generated secret (`--i-know`) |
| `./teknoir-airgap migrate` | One-time detach of the legacy k3s files (`--dry-run`, `--undo NAME`) |
| `./teknoir-airgap doctor` | Check this LAN host and the node |
| `./teknoir-airgap help` | The full reference |

`--reapply TIER` is break-glass: it applies a one-shot tier (`platform-secrets`,
`istio`, `harbor`, `argo`) again over what ArgoCD owns. Use it only when told to
by a runbook. `--force-images` lets the converge move a mirror tag in Harbor to
a new digest (for example a re-pushed upstream tag).

On the node itself (the bundle copied there, for example when the LAN has no
second machine), `up`, `status`, `credentials`, `admin-user`, `backup`, `rotate`,
`migrate` and `doctor` work with `--local`; `kubeconfig` and `trust` are for LAN
hosts:

```sh
sudo ./teknoir-airgap up --local
```
