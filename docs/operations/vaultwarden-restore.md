# Restoring vaultwarden from the swarm-01 tarball

One-time runbook for loading the existing vaultwarden data
(`db.sqlite3` + `icon_cache/`) into the new talos-ii deployment.
After this, every saved password / passkey / 2FA seed is back, and
the existing Bitwarden client devices keep working without re-pair.

If you're rebuilding fresh and don't have the tarball, skip — flux
brings up an empty vaultwarden behind the same SSO flow and you start
clean.

## Prerequisites

1. Authentik is fully restored (the OAuth provider `Vault @ Beacoworks`
   with slug `vaultwarden` must be in its DB — see
   [authentik-restore.md](authentik-restore.md)).
2. Flux has reconciled `kubernetes/apps/identity/vaultwarden/` and
   the deployment is up. The vaultwarden pod will be running and
   serving an empty store; that's fine — we'll overwrite its `/data`.
3. The tarball is at
   [`.private/talos-ii-export-20260426/vaultwarden.tar.gz`](../../.private/talos-ii-export-20260426/vaultwarden.tar.gz).
   ~239 KB compressed, ~10 MB unpacked.

## Step 1 — pause the writer

Vaultwarden uses sqlite WAL mode; copying `db.sqlite3` while the pod
is writing risks corruption. The chart deploys vaultwarden as a
StatefulSet (`vaultwarden-0`), so the scale target is `sts/`:

```bash
kubectl -n identity scale sts/vaultwarden --replicas=0
kubectl -n identity wait --for=delete pod/vaultwarden-0 --timeout=60s
```

## Step 2 — copy the tarball into the PVC

The PVC `vaultwarden-data` is RWO; we attach it to a one-shot
busybox pod that has the chart's data path layout, untar in place,
then dispose. Easiest mount-and-go pattern — no waiting for the
chart's pod to come up because we just scaled it down.

```bash
# Spin up a throwaway pod with the PVC mounted on /data. busybox
# image is fetched via the LAN zot (docker.io mirror), so this is
# instant on a warm cache.
cat <<EOF | kubectl -n identity apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: vaultwarden-restore
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
        claimName: vaultwarden-data
EOF
kubectl -n identity wait --for=condition=ready pod/vaultwarden-restore --timeout=120s

# Untar straight into /data. The tarball was built with `tar czf
# vaultwarden.tar.gz -C /data .`, so its top-level entries are
# `./db.sqlite3`, `./icon_cache/`, etc. Strip leading `./` and the
# (defunct) `lost+found/` entry as we go.
gunzip -c .private/talos-ii-export-20260426/vaultwarden.tar.gz | \
  kubectl -n identity exec -i vaultwarden-restore -- \
  tar -xv -C /data --exclude='lost+found' -f -

# Verify
kubectl -n identity exec vaultwarden-restore -- ls -la /data | head
kubectl -n identity exec vaultwarden-restore -- sh -c 'sqlite3 /data/db.sqlite3 "SELECT count(*) FROM users;" 2>/dev/null || stat /data/db.sqlite3'

# Tear down the helper
kubectl -n identity delete pod vaultwarden-restore
```

If `sqlite3` isn't in busybox (it isn't — busybox's CLI is curated),
fall back to `stat /data/db.sqlite3` — a non-zero size proves the
file landed.

## Step 3 — bring vaultwarden back up

```bash
kubectl -n identity scale sts/vaultwarden --replicas=1
kubectl -n identity wait --for=condition=ready pod/vaultwarden-0 --timeout=120s
kubectl -n identity logs sts/vaultwarden --tail=20
# Look for the "Rocket has launched from https://0.0.0.0:80" line
# and absence of "no such table" / "database is locked" errors.
```

Hit `https://vault.beaco.works/` from a browser. Click "Continue with
SSO", enter the org identifier (whatever swarm-01 was using —
typically `Vault @ Beacoworks`), authenticate at id.beaco.works,
and the existing vault should unlock with the same master password.

## Step 4 — verify a few critical entries

After unlock:

- Pick 2–3 representative entries (e.g. forgejo admin password, a
  passkey, a TOTP-bearing entry) and confirm the secret/code matches
  what you remember.
- The icon cache should populate quickly because it was carried
  over verbatim — no re-fetch needed for already-cached domains.
- Bitwarden CLI session: `bw login --apikey` should accept the
  existing `BW_CLIENTID` / `BW_CLIENTSECRET` if you've saved them
  somewhere outside the vault.

## Notes

- The chart's `signupsAllowed: false` keeps the SSO flow as the only
  enrollment path. Existing users are present in the restored DB;
  new users register through authentik invitations.
- `ADMIN_TOKEN` (in `vaultwarden-secret`) gates the `/admin` panel
  — useful for purging stale icon-cache entries after a few weeks.
- If `db.sqlite3` ever shows up corrupt (rare; sqlite is robust to
  WAL crashes but power-cuts during `VACUUM` can wedge the file),
  fall back to the offsite backup once that's set up. Until then,
  this tarball is the only copy.
- Tarball top-level entries are not just `db.sqlite3 / icon_cache /
  lost+found`. It also carries `rsa_key.pem` (the swarm-01 JWT
  signing key, mtime 2026-03-05), `db.sqlite3-wal`, `db.sqlite3-shm`,
  and `tmp/`. Restoring these alongside the db has a useful side
  effect: refresh tokens issued by the old swarm-01 vaultwarden
  verify against this `rsa_key.pem`, so existing browser/desktop
  sessions keep working without forcing a re-login.

## Status

- 2026-04-28: Procedure written, not yet executed. First execution
  updates this section with whatever shakes out (it usually does).
- 2026-05-04: Executed for real (recovery, not first-time restore —
  see `docs/operations/flux-helm-recovery.md` cases). Worked as
  written. Step 2's `gunzip | kubectl exec -i tar` path was fine for
  this ~239 KB tarball (well under the `kubectl exec -i` truncation
  threshold).
