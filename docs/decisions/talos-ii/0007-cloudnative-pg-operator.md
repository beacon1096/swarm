# ADR talos-ii/0007 — CloudNativePG as the postgres operator

**Scope:** talos-ii. talos-i has its own observability stack (VictoriaMetrics) and doesn't currently host postgres workloads.
**Status:** accepted
**Date:** 2026-04-28

## Context

Multiple workloads in the keep-list (`docs/cluster-definition.md`) use postgres as their primary store:

| ns | app | db role |
|---|---|---|
| `identity` | authentik | session, user, application config |
| `collaboration` | matrix-synapse | message graph, federation state |
| `development` | coder | workspace metadata |
| `development` | n8n | workflow / execution history |
| `development` | forgejo | repos metadata, issues, PRs |

Choices for running these in-cluster:

1. **Manual `StatefulSet` per app** — simplest config but each app maintains its own backup logic, point-in-time recovery, failover. Brittle and forks effort.
2. **CloudNativePG (CNPG) operator** — declarative `Cluster` CR per app; operator handles primary/replica election, WAL streaming, switchover, scheduled backups, point-in-time-recovery from S3-format archives, restore-from-pg_dump bootstrap path. Single CRD set covering all postgres needs.
3. **Zalando postgres-operator** — comparable feature set, slightly older codebase, less active recent development.
4. **Crunchy Data PGO** — strong commercial backing but the helm-chart-only path is more locked down; their open-source release lags the commercial one.
5. **StackGres** — "everything in one operator" approach (PG + connection pooler + monitoring); broader scope than we need.

## Decision

Use **CloudNativePG** as the single postgres operator for talos-ii.

Pattern for each PG-backed app:

```
kubernetes/apps/<ns>/<app>/
└── app/
    ├── helmrelease.yaml      # the app itself
    ├── pg-cluster.yaml       # CNPG Cluster CR (1 primary + 2 replicas)
    ├── pg-secret.sops.yaml   # superuser + app-user passwords
    ├── pg-restore-job.yaml   # one-shot Job to load .sql.gz dump
    └── ...
```

The CNPG operator runs once cluster-wide in the `database` namespace; per-app `Cluster` CRs live in each app's own namespace (so RBAC, network policy, and restart blast radius are scoped to the app).

## Why CNPG specifically

- **Active upstream** — the project ships releases on a roughly monthly cadence in 2026; bugs fixed quickly.
- **Bootstrap from pg_dump is first-class** — `bootstrap.initdb` supports `postInitApplicationSQL` and an init pattern where you can feed in arbitrary SQL after `initdb`. Combined with a one-off restore Job that streams the gzipped dump, that's exactly the workflow we need for migrating from the old cluster.
- **CloudNativePG produces backups in barman-cloud format**, which means once we pick a backup target (S3-compatible or NFS), every cluster gets PITR for free.
- **Failover is automatic** — node loss → replica promoted, no operator-attention needed. Important for a one-person homelab.

## Implementation

What's deployed at `kubernetes/apps/database/cloudnative-pg/`:

- **Chart:** `cloudnative-pg` v0.28.0 from `oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg`
- **Namespace:** `database` (operator only; per-app `Cluster` CRs live in the app's own ns)
- **`replicaCount: 1`** — operator is leader-election; extra replicas only elect among themselves
- **CRDs:** the chart installs `clusters` / `backups` / `scheduledbackups` / `databases` / `imagecatalogs` / `clusterimagecatalogs` / `poolers` / `publications` / `subscriptions` / `failoverquorums`
- **Monitoring:** podMonitor + Grafana dashboard creation **off** for now; flip on once VictoriaMetrics is ported in from talos-i
- **Backup target:** undefined. Tracked alongside Longhorn's backup TODO in `docs/index.md` open questions

## Per-app conventions (when we land them)

Each app's `Cluster` CR should:

- Use `storageClassName: longhorn-r3` on its `storage` field if the app is in the critical list (forgejo, authentik, vaultwarden, matrix-synapse). Otherwise default `longhorn`.
- Set `instances: 3` for those critical workloads, `instances: 1` for non-critical (e.g. coder if we accept downtime on workspace metadata loss).
- Pin `imageName: ghcr.io/cloudnative-pg/postgresql:<major>` to the postgres major that matches the source dump (don't let CNPG pick latest, dumps are major-version-coupled).
- Always set `monitoring.enablePodMonitor: false` until VictoriaMetrics is in.

## Alternatives considered (briefly)

- **Just use a Deployment + Longhorn PVC.** No HA. No PITR. App writes its own backup script. Per-app effort multiplies. Rejected.
- **Run postgres outside the cluster** (a fixed VM somewhere). Adds another machine to manage. The whole point of the rebuild was to consolidate state into the cluster.
- **Per-app sqlite where possible.** Vaultwarden actually uses sqlite — that's fine, no PG cluster needed. But authentik / matrix / forgejo can't reasonably do sqlite. So we still need an operator.

## Consequences

Positive:
- Single CRD set across all PG workloads
- Failover handled by operator
- PITR is one cron line away once backup target is decided

Negative:
- Operator is one more thing to upgrade. CNPG's chart upgrades are well-behaved but each major needs a CRD review.
- A `Cluster` CR is more verbose than a one-line postgres URL. The added structure pays for itself once the second app needs it.

## Related

- ADR talos-ii/0002 — Longhorn provides the storage that CNPG consumes
- `docs/operations/talos-ii-bootstrap-lessons.md` — restore-flow caveats logged as we hit them
