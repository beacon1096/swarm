# ADR talos-ii/0008 — Authentik on CloudNativePG, dump-restored

**Scope:** talos-ii. authentik isn't planned for talos-i.
**Status:** accepted
**Date:** 2026-04-28

## Context

We're rebuilding talos-ii from a scratch Talos install. The old
swarm-01 cluster's identity provider was authentik 2026.2.2 backed by
the bitnami `postgresql` Helm subchart (a single-instance
StatefulSet bundled with the chart). That data needs to come across
intact — `secret_key`-bound encrypted columns, MFA tokens, SSO
configuration, application bindings, etc. The dump available at
[`.private/talos-ii-export-20260426/authentik-pg.sql.gz`](../../../.private/talos-ii-export-20260426/authentik-pg.sql.gz)
is a `pg_dump` from PostgreSQL 18.3 containing the authentik schema
and rows.

ADR talos-ii/0007 already ratified **CloudNativePG** as the operator
for any postgres-backed workload in this cluster. That decision was
made before any PG-backed app actually landed — authentik is the
first one. Three concrete sub-decisions remain for this ADR:

1. Whether to honor ADR 0007 here (CNPG) or fall back to the bitnami
   subchart that the source cluster used (which would minimize
   operational delta but contradict the operator decision).
2. PostgreSQL major version pinning.
3. How the dump gets restored into the empty cluster.

## Decision

### 1. CloudNativePG, not the bitnami subchart

Use CloudNativePG with a per-app `Cluster` CR, with
`postgresql.enabled: false` in the authentik Helm values. This is
the path ADR 0007 already prescribed; deviating because "the source
cluster used something else" would invalidate the operator decision
on its first real test.

What this looks like in practice:

```
kubernetes/apps/identity/authentik/
├── ks.yaml                 # flux Kustomization
└── app/
    ├── kustomization.yaml
    ├── pg-cluster.yaml     # CNPG Cluster CR (PG 18, 3 instances)
    ├── pg-secret.sops.yaml # superuser + app-user passwords
    ├── ocirepository.yaml  # authentik chart on LAN zot
    ├── helmrelease.yaml    # authentik server + worker
    ├── secret.sops.yaml    # AUTHENTIK_SECRET_KEY + smtp + pg-password
    └── httproute.yaml      # id.${SECRET_DOMAIN} via envoy-external
```

The bitnami subchart is left bundled inside the authentik chart tgz
but disabled — that's where the chart ships it, and disabling via
values is one line; ripping it out via postRenderer would be more
brittle than just leaving the unused YAML behind.

### 2. PostgreSQL 18 (matching the source dump major)

Pin `imageName: ghcr.io/cloudnative-pg/postgresql:18.3` on the
`Cluster` CR. The source dump is `pg_dump version 18.3`, and
`pg_dump` output is **not forward-compatible** across majors —
loading an 18.3 dump into a PG 19 cluster would either silently
break or require a separate pg_upgrade-style migration. Lock to the
source major now; bump deliberately later via a follow-up ADR if a
PG 19+ feature ever justifies the work.

CNPG defaults to whatever the chart ships as `latest`, which is why
ADR 0007 explicitly required pinning. This is the first place that
matters in practice.

### 3. Restore via `kubectl exec | psql`, not `bootstrap.recovery`

CNPG offers two relevant bootstrap modes:

- `bootstrap.initdb` — run `initdb`, optionally execute SQL
  post-init, optionally `import` from a *live* PG cluster.
- `bootstrap.recovery` — restore from a barman-cloud snapshot in
  S3-compatible object storage.

Neither natively consumes a `.sql.gz` file from local disk. The
options for getting our 9.8 MB dump into the cluster:

- **A.** Build a tiny image with the dump baked in, schedule a Job
  that runs it. Minimum drift, but each restore needs a custom
  image build.
- **B.** Stand up a temporary `restic`/object-storage path,
  `barman-cloud-backup` the source as if it were a live cluster,
  use `bootstrap.recovery`. Massive overkill for a one-shot 9.8 MB
  load.
- **C.** Bring up the cluster empty, run `gunzip -c dump.sql.gz |
  kubectl exec -i ... -- psql -U postgres authentik` from the
  operator's machine. One operator command, no extra cluster state.

We pick **(C)**. The cluster spec is fully declarative; the load is
a documented one-time runbook step (see
[operations/authentik-restore.md](../../operations/authentik-restore.md)).
Future PG-backed apps that have larger dumps or need automation should
revisit this — for 9.8 MB through stdin, building infrastructure
isn't justified.

### 4. Critical-path settings carried over from ADR 0007

- `instances: 3` — authentik gates *every* login to *every* other
  service in the cluster; outage radius justifies replicas.
- `storageClassName: longhorn-r3` — per ADR 0007's critical-list
  rule. Yes, this means up to 3-instance × 3-longhorn-replica = 9
  copies of a 9.8 MB DB; the absolute storage cost is trivial and
  consistency with the rule pays back when matrix / coder land.
- `monitoring.enablePodMonitor: false` — flip on with the rest of
  the stack when VictoriaMetrics ports in.

### 5. Cluster-internal: `secret_key` carried over from swarm-01

The chart's `authentik.secret_key` is the salt for every encrypted
column (passwords for upstream sources, OAuth client secrets stored
in DB, recovery keys, etc.). Generating a fresh one would brick all
of those fields after restore. We lift the existing
`secret-key` value from the swarm-01 secret and re-encrypt under
talos-ii's age key.

PG passwords are *not* carried over — those are an internal
boundary; we control both ends, so a fresh password is simpler than
re-encrypting the old one.

## Consequences

Positive:

- First real exercise of the CNPG path — exposes any operator quirks
  before matrix / coder add their own clusters
- `kubectl exec | psql` keeps the bootstrap path mechanically obvious;
  no hidden state in image catalogs
- 3-replica PG removes authentik as a single-node-failure pivot point

Negative / accepted trade-offs:

- The `kubectl exec | psql` step is **manual** — adopting CNPG's
  declarative philosophy half-way. If we end up doing this for >2
  apps, build the bake-into-image Job pattern.
- bitnami subchart YAML ships in the chart tgz even though disabled.
  Cosmetic; the rendered manifest set is clean.
- `instances: 3` × `longhorn-r3` is over-replicated for a 9.8 MB DB.
  Documented; revisit if storage pressure ever shows up.

## Related

- [ADR talos-ii/0007](0007-cloudnative-pg-operator.md) — CNPG operator decision
- [Operations runbook: authentik restore](../../operations/authentik-restore.md)
- [zot mirror](../../operations/zot-mirror.md) — where the chart is hosted
