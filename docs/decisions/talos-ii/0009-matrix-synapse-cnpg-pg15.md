# ADR talos-ii/0009 — Matrix-synapse on CNPG, pinned to PG 15

**Scope:** talos-ii. talos-i has its own observability stack and no
matrix workload.
**Status:** accepted
**Date:** 2026-04-28

## Context

Matrix-synapse is the second PG-backed app to land on talos-ii (after
authentik, ADR 0008). The ananace `matrix-synapse` Helm chart bundles
its own bitnami `postgresql` subchart by default; ADR 0007 says we
use CloudNativePG instead. Three choices specific to this app:

1. **PG major version**: the swarm-01 dump is `pg_dump 15.4`. authentik
   used PG 18.3; bumping synapse to match would require an
   out-of-band `pg_upgrade`-style migration, which is more risk than
   value for a barely-used homeserver.
2. **Locale**: synapse requires the database to be created with
   `lc_collate=C` and `lc_ctype=C`. The bitnami chart pre-configures
   this; CNPG has it as the default but the field is settable.
3. **Redis**: synapse 1.148 still uses redis for replication and
   background tasks — there's no PG-only mode like authentik 2026.2
   has. The chart's bundled bitnami redis stays.

## Decision

### 1. CNPG `Cluster` pinned to PG 15.4

```yaml
imageName: ghcr.io/cloudnative-pg/postgresql:15.4
```

The first cluster-template app to use a different major than
authentik (which is on 18.3). When this homeserver gets used enough
to want PG 17/18 features, plan a deliberate `pg_upgrade` window;
until then, lock to the dump's major.

### 2. Explicit `localeCollate: C` / `localeCType: C`

Even though both default to `C` in CNPG 1.29.0
(`kubectl explain cluster.spec.bootstrap.initdb`), pin them
explicitly:

```yaml
bootstrap:
  initdb:
    encoding: UTF8
    localeCollate: C
    localeCType: C
```

Future operator versions might change defaults; an unannounced switch
to `en_US.UTF-8` would break synapse silently with `database has
incorrect collation` on first connection.

### 3. Keep the chart's bundled redis

Matrix synapse + redis is a tight pairing: synapse 1.148's
event-stream replication and background-task scheduling assume a
redis instance reachable as configured at startup. The bitnami
subchart bundled with `ananace/matrix-synapse` 3.12.22 stays on,
provisioned with a fresh password (carry-over from swarm-01 isn't
necessary — redis is cache, not state).

Auth: `existingSecret: matrix-synapse-secret`,
`existingSecretPasswordKey: redis-password`.

### 4. Existing `Matrix @ Beacoworks` OAuth provider

The OAuth provider lives in authentik's restored DB. Live client_id
+ client_secret are in cluster-secrets (rotated 2026-05-05 — the
original 128-char client_secret carried over from swarm-01 had
already drifted from authentik's DB row, then the post-3d values
landed cleartext in templates/overrides/.../cluster-secrets.sops.yaml.j2
for ~48h before that file was SOPS-encrypted, prompting the
rotation). The values that matter live in cluster-secrets:

```
MATRIX_REGISTRATION_SHARED_SECRET = (carried over from swarm-01)
MATRIX_OIDC_CLIENT_ID             = (matches authentik DB)
MATRIX_OIDC_CLIENT_SECRET         = (matches authentik DB, NOT the
                                     stale swarm-01 manifest value)
```

### 5. Layout

```
kubernetes/apps/collaboration/
├── namespace.yaml
├── kustomization.yaml
└── matrix/
    ├── ks.yaml              # flux Kustomization, dependsOn: authentik
    └── app/
        ├── kustomization.yaml
        ├── pg-cluster.yaml      # CNPG, PG 15.4, instances=3, longhorn-r3
        ├── pg-secret.sops.yaml  # CNPG superuser + app passwords
        ├── media-pvc.yaml       # 20Gi for /data (signing key + media)
        ├── ocirepository.yaml   # synapse chart on LAN zot
        ├── helmrelease.yaml     # synapse, postgres.enabled=false → CNPG
        ├── secret.sops.yaml     # redis-password (chart-local)
        ├── element.yaml         # element-web Deployment + Service
        └── httproute.yaml       # matrix.X / X/.well-known / chat.X
```

### 6. Restore plan

Same shape as authentik (ADR 0008), with two differences:

- **Media**: `kubectl cp` the swarm-01 `matrix-media.tar.gz` into the
  `matrix-synapse-media` PVC via a busybox helper pod (vaultwarden
  pattern — the synapse pod is scaled to zero during the copy).
- **Signing key**: not in the swarm-01 export. Generated fresh by the
  chart's signing-key Job. Old room events will show "unable to verify
  signature" on the sender side, but federation is disabled so this
  only matters for replays of historical events from federated peers
  (none, in our case). Acceptable for a barely-used homeserver.

Detailed runbook: [operations/matrix-restore.md](../../operations/matrix-restore.md).

## Consequences

Positive:

- Second proof of the CNPG path; locale-pinning pattern documented
  for matrix-grade workloads
- Fresh signing key cleanly cuts ties with swarm-01's
  homeserver-identity history (no "two homeservers claiming to be
  beaco.works" confusion)

Negative / accepted trade-offs:

- Pinning PG 15 means we'll need a separate ADR + window when the
  cluster justifies upgrading
- Bitnami redis adds two more pods to the `collaboration` namespace
  that we don't directly own; bump-by-renovate should be safe but
  needs occasional eyeballing
- Old room-event signatures are unverifiable post-restore; mitigated
  by federation being off (all rooms are local)

## Related

- [ADR 0007](0007-cloudnative-pg-operator.md) — CNPG operator decision
- [ADR 0008](0008-authentik-cnpg-restore.md) — same restore-via-`psql`
  pattern, different PG major
- [Operations runbook](../../operations/matrix-restore.md)
