# Restoring n8n from the swarm-01 dump + state tarball

Two restore steps:

- **PG dump** (`n8n-pg.sql.gz`, 636 KB) loaded into the CNPG cluster.
  Holds workflows, executions, credentials (encrypted), users.
- **State tarball** (`n8n-state.tar.gz`, 190 KB → ~1 MB) untarred
  into `/home/node/.n8n` PVC. Holds custom nodes, encryption-key
  checksum, event logs, queue state.

The encryption key (`N8N_ENCRYPTION_KEY` in the helmrelease) is
already carried over from swarm-01 in `n8n-secret`; without that
match the credentials in the DB are unreadable.

## Prerequisites

1. Flux has reconciled `kubernetes/apps/development/n8n/`. CNPG
   cluster `n8n-pg` is healthy, n8n pod is running with empty data.

## Step 1 — pause writers

```bash
kubectl -n development scale deploy/n8n --replicas=0
kubectl -n development wait --for=delete pod -l app.kubernetes.io/name=n8n --timeout=60s
```

## Step 2 — load the PG dump

```bash
PRIMARY=$(kubectl -n development get pod \
  -l 'cnpg.io/cluster=n8n-pg,role=primary' \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n development exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'DROP DATABASE IF EXISTS n8n;'
kubectl -n development exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'CREATE DATABASE n8n OWNER n8n;'

gunzip -c .private/talos-ii-export-20260426/n8n-pg.sql.gz > /tmp/n8n.sql
kubectl -n development cp /tmp/n8n.sql $PRIMARY:/var/lib/postgresql/data/n8n.sql -c postgres
kubectl -n development exec $PRIMARY -c postgres -- \
  psql -U postgres -v ON_ERROR_STOP=1 -d n8n -f /var/lib/postgresql/data/n8n.sql
kubectl -n development exec $PRIMARY -c postgres -- rm -f /var/lib/postgresql/data/n8n.sql

# Reassign ownership.
kubectl -n development exec $PRIMARY -c postgres -- psql -U postgres -d n8n -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO n8n', r.tablename);
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO n8n', r.sequence_name);
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO n8n', r.viewname);
  END LOOP;
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO n8n', r.matviewname);
  END LOOP;
  FOR r IN SELECT p.proname AS name, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='public' AND p.proowner=(SELECT oid FROM pg_roles WHERE rolname='postgres') LOOP
    EXECUTE format('ALTER FUNCTION public.%I(%s) OWNER TO n8n', r.name, r.args);
  END LOOP;
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I', r.matviewname);
  END LOOP;
END \$\$;
"

# Sanity
kubectl -n development exec $PRIMARY -c postgres -- psql -U postgres -d n8n -c "
SELECT 'workflow_entity' AS t, count(*) FROM workflow_entity
UNION ALL SELECT 'credentials_entity', count(*) FROM credentials_entity
UNION ALL SELECT 'user', count(*) FROM \"user\";
"
```

## Step 3 — load state tarball into the data PVC

```bash
cat <<EOF | kubectl -n development apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: n8n-restore
spec:
  restartPolicy: Never
  containers:
    - name: shell
      image: docker.io/library/busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: n8n-data
EOF
kubectl -n development wait --for=condition=ready pod/n8n-restore --timeout=120s

gunzip -c .private/talos-ii-export-20260426/n8n-state.tar.gz | \
  kubectl -n development exec -i n8n-restore -- \
  tar -xv -C /data --exclude='lost+found' -f -

# n8n runs as uid 1000 — make sure the new files are owned by that
# uid (busybox unpacks as root by default).
kubectl -n development exec n8n-restore -- chown -R 1000:1000 /data

kubectl -n development exec n8n-restore -- ls -la /data | head
kubectl -n development delete pod n8n-restore
```

## Step 4 — bring n8n back up

```bash
kubectl -n development scale deploy/n8n --replicas=1
kubectl -n development wait --for=condition=available deploy/n8n --timeout=180s
kubectl -n development logs deploy/n8n --tail=20
# Look for "Editor is now accessible" / "n8n ready on port 5678"
# and absence of "encryption key mismatch" — the latter would mean
# n8n-encryption-key got rotated.
```

## Step 5 — verify

1. `https://automaton.beaco.works/` → n8n UI loads.
2. Log in as the existing user.
3. Open one of the swarm-01 workflows. Verify a credential
   (e.g. open a "Set" or "HTTP Request" node that uses an API
   key) — the masked secret should show without "Decryption
   failed" errors.
4. Run-once a small workflow that doesn't have external side
   effects to confirm the runner works.

## Notes

- N8N_ENCRYPTION_KEY rotation: if you ever rotate this key
  intentionally, plan it like a DB migration — n8n has a CLI
  command to re-encrypt all credentials with a new key. Do NOT
  just change the env var.
- The state tarball includes `n8nEventLog-N.log` files. Those are
  internal audit trails; safe to overwrite with the swarm-01
  copies, n8n will continue from them.

## Status

- 2026-04-28: Procedure written, not yet executed against talos-ii.
