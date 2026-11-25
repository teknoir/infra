# r415 break-glass: move the staging root by hand

> **Anders only. Agents never run these commands.** Opus, DeepSeek and subagent sessions stop, say why, and ask.
> This is the only sanctioned way to move `teknoir-system/app-of-apps` by hand (`AGENTS.md`, CI v4 section 7.4 rule 5).

After the Kargo cut-over (CI v4 P5.2) the root Application `teknoir-system/app-of-apps` on r415 has
`targetRevision` = one verified commit of `teknoir/platform-applications-gitops`, and Stage `platform/staging` owns that
field. Day to day nobody moves it: gitops merges become Freight, Kargo promotes the newest, verification tags
`verified/<stamp>-<sha8>`, and only then does the next promotion build on it. `clusters/r415/root.yaml` (rendered by
`scripts/kargo-root.sh`) is for a fresh cluster and refuses to move a live root.

These commands exist for the cases where that chain is broken: a bad promotion or verification, Kargo or ArgoCD down,
or a Kargo reinstall. Use `--context r415` on every command; never rely on the current context.

Set the commit you are moving to first (a full 40-hex SHA):

```sh
SHA=<40-hex gitops commit>
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || { echo "bad SHA"; exit 1; }
```

## 1. Pause Kargo (always first)

Kargo checks the root's own annotation before it changes `targetRevision`: a Promotion whose `argocd-update` step
would update an Application lacking `kargo.akuity.io/authorized-stage` ends in `Errored` instead, and it retries for up
to 10 minutes before giving up. Nothing manages that annotation except Kargo and ArgoCD's self-heal of the root, so
removing it is the brake that actually holds:

```sh
kubectl --context r415 -n teknoir-system annotate application app-of-apps kargo.akuity.io/authorized-stage-
kubectl --context r415 -n platform get promotions
```

Wait until no Promotion shows `Running`: one already in its `argocd-update` step keeps retrying for up to 10 minutes,
and is refused once the annotation is gone. Promotions still queued behind it fail the same way.

Resume, once you are done (section 3):

```sh
kubectl --context r415 -n teknoir-system annotate application app-of-apps kargo.akuity.io/authorized-stage=platform:staging --overwrite
```

After the annotation is back, Kargo does **not** retry a Promotion it refused while paused (P4.3 rehearsal, 2026-11-24:
the refused one stays `Errored ... is not authorized`). Staging moves with the next merge to `main`, or promote the
newest gitops-main Freight by hand (`KCTX=r415 KARGO_REFS_OK=1 plans/cicd/v4/rehearsal-tools/promote.sh staging <freight>`).

No Application syncs the root itself (it is the root), so nothing restores the annotation while it is off: the pause
holds until you put it back in section 3. `clusters/r415/root.yaml` still names it, which is what a fresh cluster
needs.

**Optional noise reduction, not the brake:** the `ProjectConfig` `platform` in namespace `platform` sets
auto-promotion for the Stages `staging` and `staging-verified` (and one entry per `pin-<group>`). Check it:

```sh
kubectl --context r415 -n platform get projectconfig platform \
  -o jsonpath='{range .spec.promotionPolicies[*]}{.stageSelector.name}{"\t"}{.autoPromotionEnabled}{"\n"}{end}'
```

A gitops PR on the `charts/kargo-config` values (`autoPromotion: {staging: false, staging-verified: false}`) only
takes effect once the root is at a commit that contains it, and even then it stops auto-promotion only: a Promotion
someone starts by hand still meets the annotation brake. The emergency patch is undone by `kargo-config`'s self-heal
within seconds, so disable its automated sync first:

```sh
kubectl --context r415 -n teknoir-system patch application kargo-config --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Then set the flags. The entries are ordered `staging`, `staging-verified`, then `pin-<group>` (the `kargo-config`
template), so the patch is exactly this. The two `test` operations make the whole patch fail, and apply nothing, if that
order is ever different:

```sh
kubectl --context r415 -n platform patch projectconfig platform --type json -p '[
  {"op":"test","path":"/spec/promotionPolicies/0/stageSelector/name","value":"staging"},
  {"op":"add","path":"/spec/promotionPolicies/0/autoPromotionEnabled","value":false},
  {"op":"test","path":"/spec/promotionPolicies/1/stageSelector/name","value":"staging-verified"},
  {"op":"add","path":"/spec/promotionPolicies/1/autoPromotionEnabled","value":false}
]'
```

Restore at the end of section 3, after the `ProjectConfig` in git agrees, by giving `kargo-config` its automated sync
back:

```sh
kubectl --context r415 -n teknoir-system patch application kargo-config --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"prune":true,"selfHeal":true}}}}'
```

## 2. Move the root to the commit

First, end any sync ArgoCD is running: a patch during a `Running` operation is reverted when that operation finishes.

```sh
kubectl --context r415 -n teknoir-system get application app-of-apps -o jsonpath='{.status.operationState.phase}'
```

If that prints `Running`, terminate the operation. Either `argocd app terminate-op --core`, run where it talks to the
in-cluster ArgoCD, or the UI's **Terminate**:

```sh
argocd app terminate-op teknoir-system/app-of-apps --core
```

Then move the root:

```sh
kubectl --context r415 -n teknoir-system patch application app-of-apps --type merge \
  -p '{"spec":{"source":{"targetRevision":"'"$SHA"'"}}}'
```

Watch the children converge on that commit (ArgoCD UI, or):

```sh
kubectl --context r415 -n teknoir-system get application app-of-apps \
  -o jsonpath='{.spec.source.targetRevision} {.status.sync.status} {.status.health.status}{"\n"}'
```

Every gitops-sourced child Application reports `status.sync.revision` = `$SHA`, and `devhost-ci`-destination children
report their own revision only. Then check the reason the root was moved (the failed verification, the incident) before
resuming.

## 3. Return to normal

1. Keep Kargo paused until the root is where you want it, and merge the fix, or the revert, to gitops `main` first,
   so the commit that repairs staging is on its way. That merge is a new Freight; Kargo does not re-promote Freight
   it already counts as current, so it does not move the hand-moved root.
2. Check that Kargo's newest Freight for the `gitops-main` Warehouse is that merge commit. Freight's `origin` is a
   map keyed by Warehouse, and each git origin carries the `commit` (the label `kargo.akuity.io/alias` is the
   Warehouse name, and `-l kargo.akuity.io/alias=gitops-main` narrows the list to it - drop the `-l` if the label
   is not there):

   ```sh
   kubectl --context r415 -n platform get warehouse
   kubectl --context r415 -n platform get freight -l kargo.akuity.io/alias=gitops-main \
     -o jsonpath='{range .items[*]}{.metadata.creationTimestamp}{"\t"}{.metadata.name}{"\t"}{.origin}{"\n"}{end}' |
     sort | tail -n 3
   ```

   The last line, the newest Freight, must name the merge commit (`git rev-parse origin/main` of gitops `main`).
   Delete stale Freight before resuming if it still predates the fix (P5.2, `plans/cicd/proposal-v4.md`).
3. Confirm `clusters/r415/root.yaml` renders `targetRevision: $SHA`, without applying anything:

   ```sh
   scripts/kargo-root.sh --sha "$SHA" | kubectl --context r415 diff -f -
   ```

   A rendered root and a live root that only differ in what Kargo and this break-glass own (the annotations, the helm
   parameters) is expected. The P5.2 cut-over is done: a root still carrying `teknoir.org/release` is not expected.
4. Resume Kargo: restore the annotation (section 1), and the `ProjectConfig` / `kargo-config` automated sync if
   section 1 disabled it.

   ```sh
   kubectl --context r415 -n teknoir-system annotate application app-of-apps kargo.akuity.io/authorized-stage=platform:staging --overwrite
   ```

5. Check the browser (`/home/anders/git/ai/.claude/skills/verify-rollout-browser/SKILL.md`) once `staging` is
   Synced/Healthy.

## 4. Kargo or Argo down

When Kargo cannot promote, or ArgoCD cannot sync the root, the same steps with the **revert** commit:

1. Prepare the revert in git: `git revert <G>` on a branch, PR, checks, merge (CI v4 section 3.4). That merge commit
   is `REVERT_SHA`: put its full SHA in `SHA` above (or in `REVERT_SHA`, used below), so the commands below move the
   root to the revert. The revert is in git whether or not it ever gets promoted.
2. If Kargo runs at all, pause it (section 1): annotate the root, wait for no `Running` Promotion.
3. Patch the root to `$REVERT_SHA` (section 2) and watch the children.
4. If **ArgoCD itself** is down, nothing syncs until it is back: ArgoCD self-manages from gitops (`charts/argo`), so
   bring it back first and then patch the root to `$REVERT_SHA`. If ArgoCD cannot reconcile at all, the last resort is
   `deploy-argo.sh` against r415, which needs the r415 host and k3s data-dir (its header lists the variables):

   ```sh
   STAGING_HOST=anders@192.168.2.166 K3S_MANIFESTS=/opt/k3s/server/manifests FORCE_DEPLOY=1 scripts/deploy-argo.sh
   ```

   `FORCE_DEPLOY=1` only pays off with automated sync off, or `selfHeal` reverts what it writes within a sync.
   Disable it on both Applications first, `app-of-apps` before `argo` (`app-of-apps`'s selfHeal would restore the next
   step):

   ```sh
   kubectl --context r415 -n teknoir-system patch application app-of-apps --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   kubectl --context r415 -n teknoir-system patch application argo --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

   Then run it, make `charts/argo` in gitops match, re-run `deploy-argo.sh` without `FORCE_DEPLOY` (it moves the file
   out of the k3s manifests directory again), and re-enable automated sync in the reverse order, `argo` first:

   ```sh
   kubectl --context r415 -n teknoir-system patch application argo --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"prune":true,"selfHeal":true}}}}'
   kubectl --context r415 -n teknoir-system patch application app-of-apps --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"prune":true,"selfHeal":true}}}}'
   ```

   See `README.md` and the header of `scripts/deploy-argo.sh`.
5. Resume Kargo (section 3 step 4) once it is healthy. The first new Freight after `$REVERT_SHA` promotes normally
   and takes the root over again. The read-only check of section 3 step 3, then the browser check, close it out.

## 5. Kargo reinstall

A reinstall or upgrade of Kargo must not start promoting from stale Freight or from pins nobody reviewed. Before it:

1. Pause with the annotation brake of section 1: `kubectl --context r415 -n teknoir-system annotate application
   app-of-apps kargo.akuity.io/authorized-stage-`, then wait until no Promotion is `Running`. That brake covers every
   Stage that updates the root, including the `pin-<group>` ones, without touching `ProjectConfig` at all.
2. Optionally also turn **every** auto-promotion off - not just `staging` and `staging-verified`, but each
   `pin-<group>` too - in `charts/kargo-config` values (durable, via PR). As an emergency stopgap on the live
   `ProjectConfig`, disable `kargo-config`'s automated sync first (section 1, or ArgoCD overwrites it at its next
   sync), then:

   ```sh
   pause=$(mktemp)
   kubectl --context r415 -n platform get projectconfig platform -o json |
     jq '[.spec.promotionPolicies | to_entries[] |
          {op: "add", path: ("/spec/promotionPolicies/" + (.key | tostring) + "/autoPromotionEnabled"),
           value: false}]' >"$pause"
   kubectl --context r415 -n platform patch projectconfig platform --type json --patch-file "$pause"
   rm -f "$pause"
   kubectl --context r415 -n platform get projectconfig platform \
     -o jsonpath='{range .spec.promotionPolicies[*]}{.stageSelector.name}{"\t"}{.autoPromotionEnabled}{"\n"}{end}'
   ```

   The last command must show `false` for every entry. Only then reinstall or upgrade Kargo.
3. After the reinstall, check `kubectl --context r415 -n platform get warehouses,stages` is Ready and that the
   newest Freight for `gitops-main` matches `git rev-parse origin/main` of gitops `main` (section 3 step 2). Delete
   stale Freight before turning anything back on, then the annotation (section 3 step 4, which is what lets Kargo
   move the root again), then `kargo-config` per PR.
