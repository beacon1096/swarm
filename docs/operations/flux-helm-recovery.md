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

Three cases on talos-ii where this pattern came up:

### attic (Phase 4a, 2026-04-29)

helm-controller landed in `MissingRollbackTarget` after multiple failed install attempts. Used **Hard** (delete v1+v2+v3+v4 secrets). Pod stayed up 13h+ across the cleanup; flux re-installed and adopted as v1.

### zot (Phase 4b, 2026-04-30)

Multi-step iterative debug; helm-storage state churned across ~10 commits as the chart's hardcoded probe paths were chased. Final fix used **Nuclear** (delete sts + helm secrets) **plus** chart values fix (`tcpSocket` probe override via `postRenderers.kustomize.patches`).

### n8n (Phase 4b cleanup, 2026-04-30)

helm-controller pod restarted on 2026-04-28 ~06:39 UTC and lost storage. Pod was healthy 47h+ but HR was `Stalled / RetriesExceeded`. Tried `flux reconcile hr` — didn't clear. Used **Soft + Hard combined**: `flux suspend → kubectl delete secret -l owner=helm,name=n8n → flux resume`. Pod 0 restarts; clean v1 created. Also bumped HelmRelease `spec.timeout: 15m` so the next helm-controller restart doesn't trip on n8n's slow JS bootstrap (~8min to Available).

### vaultwarden (Phase 4b cleanup, 2026-04-30)

Same helm-controller restart event (2026-04-28) exposed an unrelated bug: the chart 0.35.1 reads `existingSecret` at the top-level `sso.existingSecret`, but our HelmRelease had it nested at `sso.clientId.existingSecret` — chart's fallback used an empty Secret, vaultwarden binary panicked with a misleading "SSO_CLIENT_ID, SSO_CLIENT_SECRET and SSO_AUTHORITY must be set" message. Fixed via Hard (after the values fix landed in git).

## Why helm-controller storage gets lost

We've not pinned this down precisely. Suspected causes, none confirmed:
- Pod evicted under memory pressure during reconcile burst
- Pod restarted by node drain / image upgrade without graceful shutdown
- A flux-operator upgrade rolling helm-controller while a release was mid-flight

Mitigation hooks the operator could consider (none implemented yet):
- `helm-controller` deployment with explicit `resources.requests.memory` so it's not first to evict under pressure
- A weekly job that snapshots `sh.helm.release.v1.*` Secrets to a backup namespace, so a lost storage event can be recovered without re-installing
- Set HelmRelease `spec.timeout` generously (≥ 15m) on slow-starting charts (n8n, attic chart with PVC bootstrap, etc.) so a fresh post-restart install doesn't trip on chart wait

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
