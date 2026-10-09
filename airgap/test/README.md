# airgap/test — test harness of the airgap tooling

The test plan is in [docs/airgap/DESIGN.md](../../docs/airgap/DESIGN.md) ("Test plan", work item I-16).
CI runs everything except the VM test: [.github/workflows/airgap-ci.yml](../../.github/workflows/airgap-ci.yml).

| Suite | Command | Needs | Runs in CI |
|---|---|---|---|
| Static + unit | `airgap/test/run-static.sh` | shellcheck, docker (bash 3.2), gitleaks, curl (first bats install) | yes |
| bats only | `airgap/test/bats/run.sh [file.bats]` | bash, curl (first run only) | yes, from run-static.sh |
| K3s ownership (k3d) | `airgap/test/k3d/run.sh [T1 ... T9]` | docker, k3d, kubectl, jq (T6 also helm, yq) | T1-T5, T4N, T9; T6 on manual dispatch |
| VM end to end | `airgap/test/vm/e2e.sh [--allow-destroy] [E1 ...]` | vpro: KVM, sudo, the VM base image | no |

## bats (pinned, offline-friendly)

`bats/bootstrap-bats.sh` installs bats-core **1.13.0** from its immutable npm registry
tarball, checks it against the sha256 pinned in the script (the npm sha512 integrity was
cross-checked when pinning), and caches it in `~/.cache/teknoir-airgap/bats-core-1.13.0`.
After the first run no network is needed. Without network, put a copy of
`https://registry.npmjs.org/bats/-/bats-1.13.0.tgz` anywhere and run with
`BATS_TARBALL=/path/to/bats-1.13.0.tgz`. To bump: change `BATS_VERSION` and `BATS_SHA256`.

Test files:
- `common_contract.bats`: contract #3, the `lib/common.sh` API the phase libraries use
  (error vs absent, dry-run, server-side apply, waits, summary, secret reads). `run.sh` runs it
  against `airgap/node/lib/common.sh` and again against the stub `airgap/test/stubs/common.sh`,
  so the two cannot drift apart.
- `node_runner.bats`: `teknoir-node` CLI, lock (exit 75), 0600 run log, payload verify
  (tampered, unlisted), the downgrade guard, and `converge --dry-run` without a mutating
  call or a host file write in two stub worlds: a fresh node (no k3s: every API call is
  refused, only `kubectl version --client` works) and an existing cluster (k3s active,
  every object present, every server-side diff reports a change, Harbor healthy but
  empty, so the run reaches every apply, restart and push gate).
- `lan_entrypoint.bats`: the commands and flags of `teknoir-airgap` exist; bash 3.2.
- `harness.bats`: self-tests of the k3d, VM, netns and e2e scripts, including dry runs of
  E11, E12 and E13's backup check against stubs (`fixtures/e2e-world.bash`: a healthy
  teknoir-default world; `WORLD_BREAK` breaks one part, and exactly its check must fail),
  fixture JSON for the cluster reads, `vm.sh age-key` with a stand-in age-keygen, and
  `sntp-query.py` against a local NTP responder.
- `kc_login.bats`: `kc-login.sh` and e2e.sh's E14 checks against `stubs/fake-sso.py`, a
  local HTTPS stand-in for oauth2-proxy, Keycloak (realm teknoir: login form, required
  actions, SSO cookie, logout confirmation) and an ArgoCD-like OIDC client. Throwaway CA
  and passwords in the test's temp dir; curl maps the names to 127.0.0.1 through a
  `.curlrc` in `CURL_HOME`. Needs openssl, python3, curl and jq.
- `static.bats`: shebangs, no xtrace in node/LAN code, public site files, no key material,
  no writes to the test host's `/etc/hosts`.

A test whose code is not in the tree yet is skipped with the missing path.
Overrides: `COMMON_SH`, `TEKNOIR_NODE_DIR`, `TEKNOIR_LAN_BIN`.

### Stubs

`stubs/bin/` holds recording stubs for `kubectl`, `k3s`, `ssh`, `crane`, `helm`, `curl`,
`systemctl` and `ip` (`test_helper.bash: setup_stubs` puts them first on PATH):
- every call is logged to `$STUB_LOG`;
- a call whose arguments match `$STUB_FAIL_ON` (an ERE) exits 97;
- `stub_<name>` functions in `$STUB_HANDLER` answer calls;
- the default is exit `$STUB_DEFAULT_RC` (0), and `k3s kubectl` forwards to the kubectl stub.

`-f -` input is saved as `$STUB_STDIN`. `mutating_calls` lists every recorded call that
would change something (`MUTATING_RE`: kubectl writes, `exec` and `cp`, rollout restarts,
k3s ctr imports, systemctl state changes, crane and helm pushes, curl with POST, PUT, PATCH,
DELETE or a body); a `kubectl ... --dry-run` call does not count.

`stage_payload` copies `airgap/node` and adds stand-ins for what only the bundle build
produces (contract #1): `k3s/` (a `k3s` that answers `--version` and hands everything else
to the k3s stub), one bootstrap image archive, `charts/app-of-apps-0.0.4.tgz` with
`pins.txt`, `oneshot/TIERS` with an empty render per tier, an empty `images/images.lock`,
then `SHA256SUMS`.

## k3d ownership suite

`k3d/run.sh` runs on `rancher/k3s:v1.33.5-k3s1`, the live version. It proves what deletes
objects owned by K3s manifest files:
- T1 Addon and labels;
- T2 dropping an object from a file deletes it, even with Prune=false;
- T3 a deleted file leaves an orphan Addon and its objects;
- T4 the detach recipe, also across restarts, with old files next to `.skip` and undo;
- T4N why the strip step is needed;
- T5 a restart reverts edits;
- T6 ArgoCD adoption;
- T9 `teknoir-node migrate`, then converge's cluster phases twice and across a restart, on a
  fixture of the live layout.

Note on T6: ArgoCD 3.5.1 writes no `argocd.argoproj.io/tracking-id` annotation on CRDs, whether it
adopted them or created them. teknoir-local's monitoring CRDs are the same. A CRD therefore belongs
to an app when the Application's `status.resources` lists it as Synced; T6 and E10 check that.

Every kubectl call passes `--context k3d-<name>` and uses a kubeconfig in the work dir.
Clusters are deleted afterwards (`--keep` keeps them).

T9 runs the real `teknoir-node migrate` and `teknoir-node converge --only
verify,preflight,cluster-base,secrets` as a normal user through the runner's test sandbox
(`TEKNOIR_HOST_ROOT`). Lock, log and state are kept in the work dir. The fixture's root CA is a
real throwaway CA (generated into the work dir, 0600), so the secrets phase can read it and sign
the gateway placeholder as on the live node. T9 does not check CRD adoption by ArgoCD (no
ArgoCD runs in the fixture); T6 and E10 do.

## VM end to end (vpro)

- `vm/vm.sh`: the airgapped KVM node `tk-airgap`, domain `teknoir.airgapped`, 10.77.0.10.
  It sits on bridge `tkvm0`, which has no NAT and drops all forwarded traffic. VM state lives
  in `VM_DIR` (default `~/vmtest`).
- `vm/lan-netns.sh up|down|status|hosts|exec`: the LAN host. It is network namespace `tklan`
  at 10.77.0.20, with no default route. Its own `/etc/netns/tklan/{hosts,nsswitch.conf,resolv.conf}`
  map the platform names to the VM. vpro's `/etc/hosts` and the live env are never touched.
- `vm/e2e.sh`: scenarios E1-E8, E10 and E11-E15 with a pass/fail summary (the header of the
  script lists every assertion). E1, E6, E10 and E15 re-create the VM and run only with
  `--allow-destroy`. Inputs: `E2E_BUNDLE`, `E2E_BUNDLE_B`, `E2E_OLD_SETUP` and more (see the
  header). The first admin is the owner of the GitOps Profile teknoir-default unless
  `E2E_ADMIN_EMAIL` is set; it is remembered in `E2E_WORK/state/admin-email`.
  Example: `E2E_BUNDLE=dist/teknoir-airgap-<id>.tar airgap/test/vm/e2e.sh --allow-destroy E1 E2 E3`.
  A release (r5) runs, each on a re-created VM:
  - fresh: `E2E_BUNDLE=<B> e2e.sh --allow-destroy E1 E11 E12 E13 E14 E2 E3 E7 E8`;
  - upgrade, with A = the deployed `dist/teknoir-airgap-teknoir-local-aoa0.0.4-….tar`:
    `E2E_BUNDLE=<A> E2E_BUNDLE_B=<B> E2E_E4_APPS=auto e2e.sh --allow-destroy E1 E4`.
    - E1 installs A. A predates r5 (its app-of-apps, from `MANIFEST.yaml` or
      `node/charts/pins.txt`, is below `E2E_R5_AOA`, default 0.0.5), so E1 treats it as a
      baseline. The r5-only checks warn instead of failing: platform operations, caBundle,
      digest pins, the temporary-password handover, the Update Profile form (the baseline
      login fills it in), the Backstage identity and backstage-api restarts.
      `E2E_E1_BASELINE=0|1` overrides the detection.
    - E4 updates to B and asserts the release checks there. That includes the legacy
      password field, which r5's user-controller clears.
    - `E2E_E4_APPS=auto` expects app-of-apps, each Application whose chart pin differs
      between A and B, and the nine teknoir-default plugin Applications that B's GitOps
      Profile adds.
    - By default E4 does not run the rollback from r5 B to the pre-r5 A, and its summary
      row says so. This is an open design gap:
      - after the rollback, B's Profile teknoir-default and Namespace
        teknoir-user-credentials remain (Prune=false,Delete=false, without
        IgnoreExtraneous), so profile-controller and user-controller stay OutOfSync;
      - A's profile-controller points the teknoir-default Applications back at github.io;
      - A's post waits for every Application.

      `E2E_E4_ROLLBACK=1` runs the rollback and asserts each part of the expected state.
      `E2E_E4_ROLLBACK=0` stops after the refused A.
  - live rehearsal: `E2E_BUNDLE=<A> E2E_BUNDLE_B=<B> E2E_OLD_SETUP="$PWD/airgap/test/vm/old-setup.sh"
    e2e.sh --allow-destroy E15`.
- `vm/vm.sh age-key [--check SITE]`: the two test age identities behind `vmtest.env`'s
  `BACKUP_AGE_RECIPIENTS`, `VM_DIR/age/{vmtest,vmtest-recovery}.key` (0600, made with
  age-keygen when missing, never in the repo or on the VM). E13 decrypts the LAN backup with
  each. After a new `VM_DIR`, put the printed recipients into `vmtest.env`.
- `vm/sntp-query.py HOST`: one SNTP query (stratum, offset), E12's check that the node serves
  time to the LAN.
- `vm/old-setup.sh`: the `E2E_OLD_SETUP` command for E10. It installs the live env's old layout
  on the fresh VM with the old tooling itself (infra e9a3b7f, gitops 158b3da = app-of-apps 0.0.3)
  and dummy secrets, then adds the legacy file names and orphan Addons the live node has. Its
  test-environment workarounds are listed in its header. `--build-only` runs only the vpro side
  (worktrees, dummy secrets, bundle in `~/vmtest/old-setup`). Example:
  `E2E_OLD_SETUP="$PWD/airgap/test/vm/old-setup.sh" E2E_BUNDLE=... airgap/test/vm/e2e.sh --allow-destroy E10`.
- `vm/kc-login.sh`: scripted oauth2-proxy and Keycloak login. Passwords go only through files.
  `--cookie-jar FILE` keeps the session for API calls and reuses its Keycloak SSO session
  (ArgoCD, Harbor: `--session-cookie argocd.token|sid`, no password); `--forbid-profile-form`
  fails on Update Profile; `--accept-status 403` for a non-admin realm user at an admin-only
  app; `--logout` checks the sign-out chain (oauth2-proxy sign_out, Keycloak's logout
  confirmation, back to the app, `/oauth2/start`, the login form).
