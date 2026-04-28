# Restoring coder from the swarm-01 dump

Loads the `coder-pg.sql.gz` PG dump into the new CNPG cluster.
Workspace filesystem (`coder-workspace.tar.gz`) is **deliberately not
restored** — see [ADR 0010](../decisions/talos-ii/0010-coder-n8n-cnpg.md#3-skip-restoring-the-coder-workspace-tarball)
for the rationale.

## Prerequisites

1. Authentik fully restored — the OIDC handshake at first login
   needs the `Coder @ Beacoworks` provider to exist.
2. Flux has reconciled `kubernetes/apps/development/coder/`. The
   CNPG cluster `coder-pg` is `Cluster in healthy state`. The coder
   pod is running but the DB is empty (Django-style coder
   migrations have created the schema).

## Step 1 — pause the writer

```bash
kubectl -n development scale deploy/coder --replicas=0
kubectl -n development wait --for=delete pod -l app.kubernetes.io/name=coder --timeout=60s
```

## Step 2 — load the PG dump

```bash
PRIMARY=$(kubectl -n development get pod \
  -l 'cnpg.io/cluster=coder-pg,role=primary' \
  -o jsonpath='{.items[0].metadata.name}')

# The coder dump is plain pg_dump (not pg_dumpall), so the unified
# authentik-style flow works directly: drop, recreate, load,
# reassign owner, REFRESH matviews.
kubectl -n development exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'DROP DATABASE IF EXISTS coder;'
kubectl -n development exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'CREATE DATABASE coder OWNER coder;'

gunzip -c .private/talos-ii-export-20260426/coder-pg.sql.gz > /tmp/coder.sql
kubectl -n development cp /tmp/coder.sql $PRIMARY:/var/lib/postgresql/data/coder.sql -c postgres
kubectl -n development exec $PRIMARY -c postgres -- \
  psql -U postgres -v ON_ERROR_STOP=1 -d coder -f /var/lib/postgresql/data/coder.sql
kubectl -n development exec $PRIMARY -c postgres -- rm -f /var/lib/postgresql/data/coder.sql

# Reassign ownership + refresh matviews — same loop as authentik.
kubectl -n development exec $PRIMARY -c postgres -- psql -U postgres -d coder -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO coder', r.tablename);
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO coder', r.sequence_name);
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO coder', r.viewname);
  END LOOP;
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO coder', r.matviewname);
  END LOOP;
  FOR r IN SELECT p.proname AS name, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='public' AND p.proowner=(SELECT oid FROM pg_roles WHERE rolname='postgres') LOOP
    EXECUTE format('ALTER FUNCTION public.%I(%s) OWNER TO coder', r.name, r.args);
  END LOOP;
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I', r.matviewname);
  END LOOP;
END \$\$;
"

# Sanity
kubectl -n development exec $PRIMARY -c postgres -- psql -U postgres -d coder -c "
SELECT 'users' AS t, count(*) FROM users
UNION ALL SELECT 'workspaces', count(*) FROM workspaces
UNION ALL SELECT 'templates', count(*) FROM templates;
"
```

## Step 3 — bring coder back up

```bash
kubectl -n development scale deploy/coder --replicas=1
kubectl -n development wait --for=condition=available deploy/coder --timeout=180s
kubectl -n development logs deploy/coder --tail=20
# Look for "started HTTP server" / "primary user found" / similar
```

## Step 4 — verify

1. `https://code.beaco.works/` → 200, redirect to OIDC login.
2. "Sign in with OpenID Connect" → authentik → log in as the
   user who exists in coder's restored DB.
3. Workspaces list shows the swarm-01 workspaces (likely as
   "stopped" — their backing pods don't exist on this cluster).
4. Reconcile any workspace by clicking "Start" — coder will
   re-provision the workspace pod from its Terraform template
   (`templates/kubernetes/main.tf` carried over in the repo).

## Workspace tarball — when you actually want it

If a specific workspace's filesystem state is critical (i.e. the
user has uncommitted code in `/home/coder/`), the manual path:

```bash
# Identify which workspace the tarball was from (the swarm-01
# operator wrote its name in the export manifest if at all)
tar tzf .private/talos-ii-export-20260426/coder-workspace.tar.gz | head

# Provision the workspace from its template (start it from the UI),
# wait until the pod is up, scale to 0:
kubectl -n development scale sts/coder-<workspace-name> --replicas=0

# Untar into the PVC via a busybox helper pod, mounting the workspace's
# PVC at /data — same pattern as vaultwarden / matrix media.

# Scale back up; coder reconnects.
```

In practice, no one's done this yet — workspaces have all been
treated as fresh clones from git. Update this section if/when we
actually do a workspace-tarball restore.

## Status

- 2026-04-28: Procedure written, not yet executed against talos-ii.
