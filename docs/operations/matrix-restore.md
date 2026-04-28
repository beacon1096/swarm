# Restoring matrix-synapse from the swarm-01 export

Combines two restores:

- **Synapse PG dump** (`matrix-synapse-pg.sql.gz`, ~208 KB → ~few MB
  SQL) loaded into the CNPG cluster (same `kubectl cp` + `psql -f`
  pattern as [authentik-restore.md](authentik-restore.md)).
- **Media tarball** (`matrix-media.tar.gz`, ~208 KB → ~few MB media
  + thumbnails) untarred into the `matrix-synapse-media` PVC via a
  busybox helper pod (same pattern as
  [vaultwarden-restore.md](vaultwarden-restore.md)).

The synapse signing key is **not** in the export. The chart's
signing-key Job generates a fresh one on first install. Old room-event
signatures will show as unverifiable on replay; that's accepted —
federation is disabled, so no peer cares.

## Prerequisites

1. Authentik fully restored ([authentik-restore.md](authentik-restore.md))
   so the `Matrix @ Beacoworks` OAuth provider is queryable.
2. Flux has reconciled `kubernetes/apps/collaboration/matrix/`. The
   CNPG cluster `matrix-pg` reports
   `STATUS=Cluster in healthy state, INSTANCES=3, READY=3`. The
   synapse pod is up but the database is empty (chart's first-run
   migrations created the schema).

## Step 1 — pause writers

```bash
# Synapse — both server pod and the chart's signing-key job's leftover
kubectl -n collaboration scale deploy/matrix-synapse --replicas=0

# Wait for shutdown
kubectl -n collaboration wait --for=delete pod -l app.kubernetes.io/name=matrix-synapse --timeout=60s
```

## Step 2 — load the PG dump

```bash
PRIMARY=$(kubectl -n collaboration get pod \
  -l 'cnpg.io/cluster=matrix-pg,role=primary' \
  -o jsonpath='{.items[0].metadata.name}')

# Drop + recreate empty
kubectl -n collaboration exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'DROP DATABASE IF EXISTS synapse;'
kubectl -n collaboration exec -i $PRIMARY -c postgres -- \
  psql -U postgres -c 'CREATE DATABASE synapse OWNER synapse LC_COLLATE "C" LC_CTYPE "C" TEMPLATE template0;'

# Stage + load via PG data dir (kubectl exec stdin truncates >~100MB —
# matrix dump is small, but the pattern is consistent with authentik)
gunzip -c .private/talos-ii-export-20260426/matrix-synapse-pg.sql.gz > /tmp/synapse.sql
kubectl -n collaboration cp /tmp/synapse.sql $PRIMARY:/var/lib/postgresql/data/synapse.sql -c postgres
kubectl -n collaboration exec $PRIMARY -c postgres -- \
  psql -U postgres -v ON_ERROR_STOP=1 -d synapse -f /var/lib/postgresql/data/synapse.sql
kubectl -n collaboration exec $PRIMARY -c postgres -- rm -f /var/lib/postgresql/data/synapse.sql

# Reassign ownership (pg_dump preserves owner=postgres) — same trick
# as authentik. tables, sequences, views, matviews, functions.
kubectl -n collaboration exec $PRIMARY -c postgres -- psql -U postgres -d synapse -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO synapse', r.tablename);
  END LOOP;
  FOR r IN SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO synapse', r.sequence_name);
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO synapse', r.viewname);
  END LOOP;
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO synapse', r.matviewname);
  END LOOP;
  FOR r IN
    SELECT p.proname AS name, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
    WHERE n.nspname='public' AND p.proowner=(SELECT oid FROM pg_roles WHERE rolname='postgres')
  LOOP
    EXECUTE format('ALTER FUNCTION public.%I(%s) OWNER TO synapse', r.name, r.args);
  END LOOP;
END \$\$;
"

# REFRESH any matviews (synapse doesn't ship any in the public
# schema today, but be defensive)
kubectl -n collaboration exec $PRIMARY -c postgres -- psql -U postgres -d synapse -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT matviewname FROM pg_matviews WHERE schemaname='public' LOOP
    EXECUTE format('REFRESH MATERIALIZED VIEW public.%I', r.matviewname);
  END LOOP;
END \$\$;
"
```

## Step 3 — load the media tarball

```bash
# Helper pod with the media PVC mounted (synapse is scaled to zero,
# so the RWO PVC is detachable)
cat <<EOF | kubectl -n collaboration apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: matrix-restore
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
        claimName: matrix-synapse-media
EOF
kubectl -n collaboration wait --for=condition=ready pod/matrix-restore --timeout=120s

# Untar; the tarball was made with `tar czf -C /data .`, top-level
# entries are `./media/...`. The synapse signing key is NOT in this
# tarball — chart will generate a fresh one when scaled back up.
gunzip -c .private/talos-ii-export-20260426/matrix-media.tar.gz | \
  kubectl -n collaboration exec -i matrix-restore -- \
  tar -xv -C /data --exclude='lost+found' -f -

# Sanity
kubectl -n collaboration exec matrix-restore -- ls /data
kubectl -n collaboration exec matrix-restore -- ls -la /data/media/local_content | head

# Tear down
kubectl -n collaboration delete pod matrix-restore
```

## Step 4 — bring synapse back up

```bash
kubectl -n collaboration scale deploy/matrix-synapse --replicas=1
kubectl -n collaboration wait --for=condition=available deploy/matrix-synapse --timeout=300s
kubectl -n collaboration logs deploy/matrix-synapse --tail=30
# Look for: "Synapse now listening on TCP port 8008"
# and absence of: "no such table" / "permission denied for"
```

If the signing-key Job hasn't already run, scaling up triggers it.
A fresh `${SECRET_DOMAIN}.signing.key` lands in the synapse PVC.

## Step 5 — verify SSO + a known room

1. Browse to `https://chat.beaco.works/` (element-web).
2. "Sign In" → "Continue with authentik" → log in at id.beaco.works.
3. Confirm element loads with your existing user shown
   (`@beacon1096:beaco.works` or whichever localpart).
4. Open one of the rooms that had history. Old messages render but
   show "Unable to verify signature" on hover — that's the fresh
   signing key talking; ignore unless we ever need to re-federate
   those events (federation is off).

## Notes

- The PG dump is PG 15.4; the CNPG cluster image is also
  `cloudnative-pg/postgresql:15.4`. Major-version mismatch would
  silently corrupt; if a future restore hits "incompatible PG
  version" the fix is to bump `pg-cluster.yaml`'s `imageName`.
- `lc_collate=C` is enforced both by the CNPG `bootstrap.initdb`
  defaults and by the explicit `LC_COLLATE "C"` in the recreate
  step. Either alone is sufficient; both is belt-and-suspenders.
- This procedure leaves `/data/keys` empty — a fresh signing key is
  generated on first synapse start. To preserve identity across the
  swarm-01 → talos-ii migration, we'd have needed `/data/*.signing.key`
  in the export. That ship has sailed; if it ever matters, restore
  from a fresh swarm-01 backup that includes the signing key.

## Status

- 2026-04-28: Written, not yet executed against talos-ii.
