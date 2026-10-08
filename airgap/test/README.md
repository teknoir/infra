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
- `harness.bats`: self-tests of the k3d, VM, netns and e2e scripts.
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
- T9 `teknoir-node migrate` on a fixture of the live layout.

Note on T6: ArgoCD 3.5.1 writes no `argocd.argoproj.io/tracking-id` annotation on CRDs, whether it
adopted them or created them. teknoir-local's monitoring CRDs are the same. A CRD therefore belongs
to an app when the Application's `status.resources` lists it as Synced; T6 and E10 check that.

Every kubectl call passes `--context k3d-<name>` and uses a kubeconfig in the work dir.
Clusters are deleted afterwards (`--keep` keeps them).

T9 runs the real `teknoir-node migrate` as a normal user through the runner's test sandbox
(`TEKNOIR_HOST_ROOT`). Lock, log and state are kept in the work dir.

## VM end to end (vpro)

- `vm/vm.sh`: the airgapped KVM node `tk-airgap`, domain `teknoir.airgapped`, 10.77.0.10.
  It sits on bridge `tkvm0`, which has no NAT and drops all forwarded traffic. VM state lives
  in `VM_DIR` (default `~/vmtest`).
- `vm/lan-netns.sh up|down|status|hosts|exec`: the LAN host. It is network namespace `tklan`
  at 10.77.0.20, with no default route. Its own `/etc/netns/tklan/{hosts,nsswitch.conf,resolv.conf}`
  map the platform names to the VM. vpro's `/etc/hosts` and the live env are never touched.
- `vm/e2e.sh`: scenarios E1-E8 and E10 with a pass/fail summary. E1, E6 and E10 re-create the
  VM and run only with `--allow-destroy`. Inputs: `E2E_BUNDLE`, `E2E_BUNDLE_B`, `E2E_OLD_SETUP`
  (see the header of the script).
  Example: `E2E_BUNDLE=dist/teknoir-airgap-<id>.tar airgap/test/vm/e2e.sh --allow-destroy E1 E2 E3`.
- `vm/kc-login.sh`: scripted oauth2-proxy and Keycloak login. Passwords go only through files.
