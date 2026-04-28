# Restoring authentik from the swarm-01 dump

This is the one-time runbook for getting the existing authentik data
loaded into the new talos-ii CloudNativePG cluster. After this
completes, authentik is fully restored — users, applications, OAuth
clients, MFA tokens, recovery codes, and all encrypted columns
re-readable because the chart's `secret_key` was carried over (see
[ADR talos-ii/0008](../decisions/talos-ii/0008-authentik-cnpg-restore.md)).

If you're rebuilding fresh and don't have a dump, skip this — flux
will bring up an empty authentik with the default initial-password
flow.

## Prerequisites

1. Flux has reconciled `kubernetes/apps/identity/authentik/` and the
   `authentik-pg` `Cluster` is healthy:

   ```bash
   kubectl -n identity get cluster.postgresql.cnpg.io authentik-pg
   # PHASE = "Cluster in healthy state"
   # INSTANCES = 3, READY = 3
   ```

2. The authentik server pod is in `CrashLoopBackOff` or
   `Running but unauthenticated` — both are expected. The DB is
   empty: there's no admin user yet, and any session reaching
   authentik returns the bootstrap setup screen.

3. The dump file is at
   [`.private/talos-ii-export-20260426/authentik-pg.sql.gz`](../../.private/talos-ii-export-20260426/authentik-pg.sql.gz)
   on the operator machine. It's 9.8 MB gzipped, ~100 MB SQL.

## Step 1 — stop the authentik writers

While we load the dump, the authentik server / worker must not be
writing. Scale them to zero:

```bash
kubectl -n identity scale deploy/authentik-server --replicas=0
kubectl -n identity scale deploy/authentik-worker --replicas=0

# Wait for pods to terminate
kubectl -n identity wait --for=delete pod -l app.kubernetes.io/name=authentik --timeout=60s
```

## Step 2 — drop the empty database, recreate it, load the dump

The flux-applied bootstrap creates an empty `authentik` database.
The dump expects to start from a database with the authentik schema
already present and, importantly, with all the same role/extension
preconditions. The cleanest path: drop, recreate, restore.

```bash
# Identify the primary pod (CNPG marks it with role=primary)
PRIMARY=$(kubectl -n identity get pod -l postgresql=authentik-pg,role=primary -o jsonpath='{.items[0].metadata.name}')
echo "primary: $PRIMARY"

# Drop and recreate
kubectl -n identity exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'DROP DATABASE IF EXISTS authentik;'
kubectl -n identity exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'CREATE DATABASE authentik OWNER authentik;'

# Pre-create extensions the dump assumes are already present.
# These match pg-cluster.yaml's postInitApplicationSQL.
kubectl -n identity exec -i $PRIMARY -c postgres -- \
  psql -U postgres -d authentik -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS btree_gin;'

# Load the dump. ON_ERROR_STOP=1 makes psql bail on the first error
# rather than chugging through 100 MB of cascading failures.
gunzip -c .private/talos-ii-export-20260426/authentik-pg.sql.gz | \
  kubectl -n identity exec -i $PRIMARY -c postgres -- \
  psql -U postgres -v ON_ERROR_STOP=1 -d authentik

# Verify rowcounts roughly match expectation (compare against
# swarm-01 if needed)
kubectl -n identity exec -i $PRIMARY -c postgres -- \
  psql -U postgres -d authentik \
  -c 'SELECT count(*) FROM authentik_core_user;' \
  -c 'SELECT count(*) FROM authentik_core_application;' \
  -c 'SELECT count(*) FROM authentik_flows_flow;'
```

Expected: non-zero on `authentik_core_user`, dozens on
`authentik_core_application`, ~tens on `authentik_flows_flow`.

## Step 3 — let CNPG re-sync the replicas

After loading the dump on the primary, CNPG's WAL streaming pulls the
new state to replicas automatically. Wait until the cluster reports
all three instances healthy again:

```bash
kubectl -n identity wait --for=jsonpath='{.status.readyInstances}'=3 \
  cluster.postgresql.cnpg.io/authentik-pg --timeout=300s
```

## Step 4 — bring authentik back up

```bash
kubectl -n identity scale deploy/authentik-server --replicas=2
kubectl -n identity scale deploy/authentik-worker --replicas=1
kubectl -n identity wait --for=condition=available deploy -l app.kubernetes.io/name=authentik --timeout=180s
```

Hit `https://id.beaco.works/` from a browser. Log in with one of the
swarm-01 users (your own admin account). MFA tokens, recovery codes,
and OAuth clients should all work — `secret_key` was preserved, so
nothing's been re-encrypted.

## Step 5 — re-pair downstream OAuth/SAML clients

Each app that uses authentik for SSO has a callback URL configured
on swarm-01's hostnames. talos-ii uses the same `*.beaco.works`
domain, so most clients keep working without change. Verify the
following while you're still freshly logged in:

- Forgejo (`forgejo.beaco.works/-/sso/oauth2/...`)
- (future: vaultwarden, coder, n8n, matrix-synapse, element-web —
  add to this list as those services land)

If any redirect loops or shows "Invalid Client", the client secret
was rotated when authentik was redeployed. Either rotate it back via
the authentik admin UI, or update the downstream's secret to match.

## Notes

- This procedure does **not** restore authentik blueprints or
  certificates from the filesystem. Authentik 2026.2 stores those in
  the database, so the SQL restore covers them. If we ever revert to
  filesystem-backed blueprints (config maps), update this doc.
- Don't try to use `bootstrap.recovery` on the CNPG `Cluster` for
  this — that requires the source to be a barman-cloud archive, not
  a `pg_dump`. See ADR 0008 for the rationale.
- If the `psql` step errors on `ALTER ... OWNER TO authentik`, the
  app role wasn't created yet. CNPG creates the role from
  `pg-secret.sops.yaml` during cluster bootstrap; if it isn't there,
  inspect `kubectl -n identity logs cnpg-cluster-init-...` for clues.

## Status

- 2026-04-28: Procedure written, not yet executed against talos-ii
  (cluster bring-up in progress). First execution updates this section
  with actual rowcount + any deviations from the script above.
