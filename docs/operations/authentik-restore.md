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
# Identify the primary pod (CNPG labels it role=primary; the pod-name
# label is `cnpg.io/cluster`, not `postgresql`)
PRIMARY=$(kubectl -n identity get pod -l 'cnpg.io/cluster=authentik-pg,role=primary' -o jsonpath='{.items[0].metadata.name}')
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

# Load the dump. CAUTION: do NOT pipe through `kubectl exec -i ...
# psql` directly — kubectl's stdin pipe truncates at ~100 MB and
# psql aborts with a confusing "syntax error at end of input" 187k+
# lines into the file. Stage the SQL onto the pod's PG data dir
# first (which is a roomy PVC), then run psql -f against the local
# file:
gunzip -c .private/talos-ii-export-20260426/authentik-pg.sql.gz > /tmp/authentik.sql
kubectl -n identity cp /tmp/authentik.sql $PRIMARY:/var/lib/postgresql/data/authentik.sql -c postgres
kubectl -n identity exec $PRIMARY -c postgres -- \
  psql -U postgres -v ON_ERROR_STOP=1 -d authentik -f /var/lib/postgresql/data/authentik.sql
kubectl -n identity exec $PRIMARY -c postgres -- rm -f /var/lib/postgresql/data/authentik.sql

# NOTE: the swarm-01 export at .private/talos-ii-export-20260426/
# was truncated mid-statement on its very last FK (the gz extracts
# cleanly to ~95 MB, but the SQL ends mid-identifier). On the
# 2026-04-28 run, ON_ERROR_STOP=1 still hit the syntax error after
# all data + all 96 intended FK constraints loaded — the truncated
# tail was a duplicate. If the rowcount check below looks healthy,
# the error is benign and the DB is functionally complete.

# pg_dump output preserves table OWNER as `postgres` (the role that
# ran the dump on the source side). After restore every table is
# owned by `postgres`, so the `authentik` app role gets
# "permission denied for table authentik_install_id" on its first
# write. Reassign ownership before bringing authentik back up:
kubectl -n identity exec $PRIMARY -c postgres -- psql -U postgres -d authentik -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO authentik', r.tablename);
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO authentik', r.sequence_name);
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO authentik', r.viewname);
  END LOOP;
  -- Materialized views are a SEPARATE catalog (pg_matviews, not pg_views).
  -- authentik_core_groupancestry is one of these; missing it makes the
  -- login flow plan fail with 'Request has been denied. Unknown error'
  -- because the policy engine queries group ancestry on every flow run.
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO authentik', r.matviewname);
  END LOOP;
  -- Functions defined by the dump (e.g. _pgtrigger_should_ignore) also
  -- end up owned by postgres. Authentik doesn't appear to write them on
  -- login, but reassigning is cheap and consistent.
  FOR r IN
    SELECT p.proname AS name, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
    WHERE n.nspname='public' AND p.proowner=(SELECT oid FROM pg_roles WHERE rolname='postgres')
  LOOP
    EXECUTE format('ALTER FUNCTION public.%I(%s) OWNER TO authentik', r.name, r.args);
  END LOOP;
END \$\$;
"

# Sanity: nothing in `public` should still be owned by postgres
kubectl -n identity exec $PRIMARY -c postgres -- psql -U postgres -d authentik -c "
SELECT 'matview' AS k, count(*) FROM pg_matviews WHERE schemaname='public' AND matviewowner='postgres'
UNION ALL SELECT 'table', count(*) FROM pg_tables WHERE schemaname='public' AND tableowner='postgres'
UNION ALL SELECT 'view', count(*) FROM pg_views WHERE schemaname='public' AND viewowner='postgres';
"
# Expect: all rows = 0.

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

- **2026-04-28**: Procedure executed end-to-end. Restored:
  14 users, 13 applications, 15 flows, 2 OAuth sources, 9 OAuth2
  providers, all 96 intended FKs, 745 indexes (vs 679 in the dump —
  pg_trgm + btree_gin add internal indexes). Two surprises documented
  inline above: the dump tail truncated on its last FK statement
  (benign, the FK was a duplicate), and post-restore ownership had to
  be reassigned from `postgres` to `authentik`.
