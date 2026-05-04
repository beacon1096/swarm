# Flux + Helm: recovering stuck HelmReleases

When `helm-controller` restarts and loses its release storage state, downstream HelmReleases get stuck. This runbook covers the three recovery patterns, in increasing destructiveness.

## When this hits us

`helm-controller` (in `flux-system`) keeps Helm release history as a set of Secrets named `sh.helm.release.v1.<name>.v<N>` per release. If the controller pod is restarted while the cluster is partway through a reconcile, or if the release Secrets get evicted/deleted, helm-controller can land in a state where:

- the running workload (Pod / Deployment / StatefulSet) is **healthy**, but
- the `HelmRelease` resource shows **`Stalled` / `MissingRollbackTarget` / `RetriesExceeded`** because Helm sees no `deployed` revision in its history (or the only revisions are `failed`)

Telltale signs:
- `flux get hr -n <ns> <name>` shows `Ready=False`, message contains `MissingRollbackTarget` or `timeout waiting for ... InProgress` or `failed early due to stalled resources`
- `kubectl get pod -n <ns>` looks healthy (1/1, days of uptime, low restart count)
- `kubectl get secret -n <ns> -l owner=helm,name=<name>` shows v1/v2 with `status=failed`, no `status=deployed`

This has hit us at least three times — see [Cases](#cases) below.

## Recovery, in order of escalation

### 1. Soft — `suspend → resume`

If the HR config in git is correct and you just want helm-controller to **try again** (clearing the `RetriesExceeded` terminal state), this is the cheapest fix. Reconciling alone is **not** enough — `flux reconcile hr` does not reset the retry counter on a terminal-stalled HR. You must explicitly suspend and resume:

```sh
flux suspend hr -n <ns> <name>
flux resume hr -n <ns> <name>
```

Resume triggers a fresh reconcile that will install or upgrade depending on what helm-controller finds in its storage. If a `deployed` revision exists, it'll upgrade. If only `failed` revisions exist (most common cause of `MissingRollbackTarget`), proceed to Hard.

### 2. Hard — delete failed Helm storage Secrets

When helm-controller's history has only `failed` revisions, the next install attempt sees them and tries to roll back to the last `deployed` — which doesn't exist — and gives up with `MissingRollbackTarget`. Wipe the failed Secrets so helm-controller sees a clean slate, then it'll do a fresh install that **adopts** the existing running resources without restarting them:

```sh
kubectl delete secret -n <ns> -l owner=helm,name=<name>
flux reconcile hr -n <ns> <name>
```

The fresh install creates a new `sh.helm.release.v1.<name>.v1` Secret with `status=deployed`. The Pod / StatefulSet is **not** recreated — Helm matches existing resources by chart-rendered name and adopts them. Verify with `kubectl get pod -n <ns> -l <selector>` that AGE didn't reset.

If `flux reconcile hr` after the secret-delete still fails (e.g., because the chart's wait timeout is shorter than the workload's actual ready time), bump `spec.timeout` and `spec.install.timeout` / `spec.upgrade.timeout` on the HelmRelease to a generous value (15m+) **and** see Soft above (suspend → resume).

### 3. Nuclear — delete StatefulSet/Deployment + Helm storage

Used when the chart's reconcile-time wait keeps failing because the underlying resource itself can't become Ready (probe path 404, image pull stuck, OOM, etc.). Clear both the running resource AND the helm storage so helm-controller installs from scratch with the corrected manifest:

```sh
flux suspend hr -n <ns> <name>
kubectl delete sts -n <ns> <name> --cascade=foreground   # or: kubectl delete deployment -n <ns> <name>
kubectl delete secret -n <ns> -l owner=helm,name=<name>
flux resume hr -n <ns> <name>
```

If the workload uses a PVC managed by the chart's `volumeClaimTemplates`, **first** check `sts.spec.persistentVolumeClaimRetentionPolicy` is `whenDeleted: Retain` (the talos-ii repo default). If it's `Delete`, your data goes with the StatefulSet — patch the policy to `Retain` first, OR back up the PVC contents to a separate volume.

After resume, watch:
```sh
flux get hr -n <ns> <name>          # → Ready=True / Helm install succeeded
kubectl get pod -n <ns> -w
kubectl get pvc -n <ns>             # PVC should still be Bound, same UID
```

## Cases

Four cases on talos-ii where this pattern came up:

### attic (Phase 4a, 2026-04-29)

helm-controller landed in `MissingRollbackTarget` after multiple failed install attempts. Used **Hard** (delete v1+v2+v3+v4 secrets). Pod stayed up 13h+ across the cleanup; flux re-installed and adopted as v1.

### zot (Phase 4b, 2026-04-30)

Multi-step iterative debug; helm-storage state churned across ~10 commits as the chart's hardcoded probe paths were chased. Final fix used **Nuclear** (delete sts + helm secrets) **plus** chart values fix (`tcpSocket` probe override via `postRenderers.kustomize.patches`).

### n8n (Phase 4b cleanup, 2026-04-30)

helm-controller pod restarted on 2026-04-28 ~06:39 UTC and lost storage. Pod was healthy 47h+ but HR was `Stalled / RetriesExceeded`. Tried `flux reconcile hr` — didn't clear. Used **Soft + Hard combined**: `flux suspend → kubectl delete secret -l owner=helm,name=n8n → flux resume`. Pod 0 restarts; clean v1 created. Also bumped HelmRelease `spec.timeout: 15m` so the next helm-controller restart doesn't trip on n8n's slow JS bootstrap (~8min to Available).

### vaultwarden (Phase 4b cleanup, 2026-04-30)

Same helm-controller restart event (2026-04-28) exposed an unrelated bug: the chart 0.35.1 reads `existingSecret` at the top-level `sso.existingSecret`, but our HelmRelease had it nested at `sso.clientId.existingSecret` — chart's fallback used an empty Secret, vaultwarden binary panicked with a misleading "SSO_CLIENT_ID, SSO_CLIENT_SECRET and SSO_AUTHORITY must be set" message. Fixed via Hard (after the values fix landed in git).

> **Caveat surfaced 2026-05-04** — Hard recovery is documented as
> non-destructive to PVCs (Helm only adopts existing resources). In
> this case the PVC `vaultwarden-data` (UID `ed32535d`, never
> recreated since 2026-04-28) ended up with **`db.sqlite3` replaced
> by an empty schema-only file**, mtime 2026-04-30 14:38:37 UTC —
> right after the SSO values fix `dce74ef` (2026-04-30 14:24 UTC)
> let helm-controller install cleanly. All `__diesel_schema_migrations`
> rows share that same timestamp, proving vaultwarden booted against
> an empty `/data/db.sqlite3` and re-ran every migration from scratch.
> The `users` / `ciphers` / etc. tables stayed at 0 rows from then
> until rediscovery on 2026-05-04. Root cause not pinned down (PVC
> wasn't deleted, sts wasn't Nuclear-pathed) — the working hypothesis
> is that during one of the crash-loop restarts under the broken SSO
> config, vaultwarden's startup truncated/replaced db.sqlite3 before
> failing. **Lesson:** before any Hard/Nuclear recovery on a
> stateful chart, take a Longhorn snapshot of the PVC. Recovery
> here was straightforward only because we still had the
> 2026-04-26 swarm-01 export tarball — see
> [`docs/operations/vaultwarden-restore.md`](vaultwarden-restore.md).

## Why helm-controller storage gets lost

helm-controller's "last successful release" reference for each HR
is **in-memory only**, even though `sh.helm.release.v1.*` Secrets
themselves are persisted in etcd. When the controller process is
replaced, that adoption history vanishes and any HR currently in
`UpgradeFailed` state has no rollback target → `RollbackFailed` →
`MissingRollbackTarget` until cleared with `suspend → resume`.

### Root cause of the 2026-04-28 incident

Investigated 2026-05-03 (commit history + RS forensics on the live
cluster). Conclusion: **flux-operator's first reconciliation of the
`FluxInstance` CR**, NOT memory pressure or node-drain.

Timeline (UTC):

| timestamp     | event                                                                  |
|---------------|------------------------------------------------------------------------|
| 04-27 17:28   | Cluster bootstrap — `flux install` directly. Initial 4 controller RSs. |
| 04-28 06:09   | flux-operator pod created (post-bootstrap install).                    |
| 04-28 06:17–06:35 | flux-operator first-reconcile applies 7 `kustomize.patches` from FluxInstance CR sequentially → 7 Deployment generations → 7 ReplicaSets per controller within ~17min. Each rollout terminates the running pod. |
| 04-28 06:35+  | Settled. RS revision 8 (= original spec hash) is current.              |

`kubectl get rs -n flux-system` still shows the 6 stale RSs. Image
SHA is identical across all of them — proving it was spec churn
(args/resources/feature-gate patches), not an image upgrade.

Each RS rollover terminated the helm-controller pod, wiping the
in-memory adoption cache. Several HRs were mid-flight at that
moment (Phase 4 services bootstrapping) and ended up with stuck
storage refs that needed manual `suspend → resume`.

### Will it recur?

**No, not from the same root cause.** flux-operator is now the sole
owner; its desired state is stable; current pod has 0 restarts over
5+ days. The 7-revision burst was a one-time install-time artifact.

### Future restart risks (still real, lower frequency)

| Trigger                              | Blast radius                | Mitigation                                              |
|--------------------------------------|-----------------------------|---------------------------------------------------------|
| Modify FluxInstance CR (add patch)   | 1 helm-controller restart   | `flux suspend hr -A` before, `resume` after            |
| Talos node reboot / drain            | helm-controller pod replace | post-reboot sweep `flux get hr -A \| grep -v True`     |
| Flux version upgrade (v1.5.3 → next) | 1 controller restart        | same as FluxInstance change                             |

### What we considered and rejected

- **Bumping memory limit** (currently 1Gi via FluxInstance patch). 5
  days of stable runtime, OOMWatch threshold 95% never triggered.
  No evidence of pressure.
- **Increasing replicas to 2.** helm-controller uses leader-election
  (active/passive). The standby has no in-memory cache, so failover
  doesn't preserve adoption history. No benefit.
- **Persisting adoption history to disk/CR.** Would require upstream
  helm-controller changes; not worth a fork.

The reactive runbook above is the equilibrium answer: detect stuck
HRs after any controller restart, escalate Soft → Hard → Nuclear.

### Generic guidance for slow-starting charts

Set HelmRelease `spec.timeout` generously (≥ 15m) on charts whose
Pod takes minutes to reach Available — n8n, attic with PVC
bootstrap, etc. — so a fresh post-restart install doesn't trip on
chart wait timing and add itself to the stuck list.

## Decision tree (quick reference)

```
HR Ready=False?
├── Pod healthy 1/1 Running, but HR says timeout/Stalled/MissingRollbackTarget?
│   ├── Try Soft (suspend → resume) first.
│   ├── If still failing → Hard (delete helm secrets, reconcile).
│   └── If chart values are actually wrong (config error / probe broken) → fix in git first, push, THEN do Hard.
└── Pod CrashLoop / not Running?
    ├── It's not "stuck HR storage" — it's a real chart values / image / probe bug.
    ├── Diagnose Pod logs first.
    └── After fixing root cause in git, may need Hard or Nuclear to clear stuck STS.
```
