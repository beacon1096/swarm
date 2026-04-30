# Quickstart — Attic restore (Phase 4a)

Operator playbook to take this feature from "merged" to "fleet hosts pulling cache hits". Assumes the manifests under `kubernetes/apps/nix/attic/` already exist (they're created during `/implement`).

## 0. Prerequisites

- CNPG operator healthy in `cnpg-system` (Phase 3b stood it up)
- `longhorn-r3` storage class exists
- sing-box at `network/sing-box` reachable (`kubectl get svc -n network sing-box`)
- LAN zot at `172.16.80.240:5000` healthy + has `app-template:4.6.2` already pushed (n8n uses it)
- bjw-s app-template v4.6.2 OCI artifact at `oci://172.16.80.240:5000/charts/app-template:4.6.2` (pre-pushed)
- Operator has SOPS + age key locally; `task encrypt-secrets` works

## 1. Prepare secret material on the operator workstation

```bash
# DB password (same value goes into BOTH SOPS files)
DB_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | head -c 32)

# Superuser password (independent)
SU_PASSWORD=$(openssl rand -base64 32 | tr -d '\n=' | head -c 32)

# JWT RS256 keypair
openssl genpkey -algorithm RSA -out /tmp/attic-priv.pem -pkeyopt rsa_keygen_bits:4096
openssl rsa -in /tmp/attic-priv.pem -pubout -out /tmp/attic-pub.pem 2>/dev/null
PRIV_B64=$(base64 -w0 /tmp/attic-priv.pem)
PUB_B64=$(base64 -w0 /tmp/attic-pub.pem)

echo "DB_PASSWORD: $DB_PASSWORD"
echo "SU_PASSWORD: $SU_PASSWORD"
echo "(write these into the SOPS files now; then shred /tmp/attic-*.pem)"
```

Shred temp files: `shred -u /tmp/attic-priv.pem /tmp/attic-pub.pem`.

## 2. Populate the SOPS files

`kubernetes/apps/nix/attic/app/pg-secret.sops.yaml` — two YAML documents:

```yaml
# attic-pg-app: username=attic, password=$DB_PASSWORD
# attic-pg-superuser: username=postgres, password=$SU_PASSWORD
```

`kubernetes/apps/nix/attic/app/secret.sops.yaml` — one document:

```yaml
# attic-secret with:
#   server.toml: full contents per contracts/attic-server-toml.md, with
#                database.url containing the SAME $DB_PASSWORD plaintext
#   token-rs256-secret-base64: $PRIV_B64
#   token-rs256-public-key-base64: $PUB_B64
```

Then encrypt:

```bash
cd ~/swarm
task encrypt-secrets   # or: sops -e -i kubernetes/apps/nix/attic/app/*.sops.yaml
git diff --stat        # confirm ENC[…] markers present
```

## 3. Commit, push, wait for flux

```bash
git add kubernetes/apps/nix docs/decisions/talos-ii/0011-attic-cnpg.md docs/operations/attic-restore.md docs/index.md
git commit -m "feat(nix): attic on CNPG (Phase 4a)"
git push
```

Watch reconcile:

```bash
flux reconcile source git flux-system
flux reconcile kustomization apps -n flux-system
flux get kustomizations -n flux-system | grep -E 'apps|attic'
flux get hr -n nix attic
kubectl get cluster -n nix attic-pg -w   # wait for "Ready=True"
kubectl get pvc -n nix
kubectl get pod -n nix
kubectl logs -n nix deploy/attic --tail=100
```

Common stalls:

- `attic-store` PVC `Pending` → check Longhorn UI for r3-replica capacity.
- `attic-pg-1` `Init:Error` → bootstrap secret missing (`attic-pg-app` — confirm SOPS decrypted).
- attic Pod `CrashLoopBackOff` with `password authentication failed` → DSN password drift between `pg-secret.sops.yaml` and `server.toml` in `secret.sops.yaml`. Fix in one commit.

## 4. Verify reachability before tokens

Anonymous probe should be 401:

```bash
curl -sI https://nix.beaco.works/nix-fleet/nix-cache-info | head -1
# expect: HTTP/2 401
```

If you get 502/504, it's the route — check HTTPRoute status and the `attic` Service has endpoints. If you get 200 anonymously, attic is misconfigured (auth disabled) — read the pod logs for `[require-auth]`-style warnings.

## 5. Mint the `nix-fleet` pull token

```bash
kubectl exec -n nix deploy/attic -- \
  atticadm -f /config/server.toml make-token \
    --sub nix-daemon \
    --validity 1y \
    --pull nix-fleet
# stdout: a JWT — copy it
```

(If atticadm complains the cache doesn't exist, create it first:
`kubectl exec -n nix deploy/attic -- atticadm -f /config/server.toml create-cache nix-fleet --public false`)

## 6. Authenticated probe should be 200

```bash
TOKEN=<the JWT from step 5>
curl -sI -H "Authorization: Bearer $TOKEN" \
  https://nix.beaco.works/_api/v1/cache-config/nix-fleet | head -1
# expect: HTTP/2 200
```

## 7. Roll the token out to the NixOS fleet

In the **separate** Nix-fleet repo (not this swarm repo):

```bash
cd ~/nix-fleet
# Edit secrets/shared/attic.yaml — paste the JWT next to the existing
# nix-daemon entry. Keep the netrc-file shape identical.
sops -e -i secrets/shared/attic.yaml
git diff --stat
git commit -am "rotate attic pull token (post-talos-ii migration)"
git push
```

On one fleet host (canary):

```bash
ssh <canary>
sudo nixos-rebuild switch --flake .#<canary>
journalctl -u nix-daemon -n 200 | grep -E 'attic|nix-fleet|substitut'
# expect: substitutions sourced from nix.beaco.works
```

If that goes through, rebuild the rest of the fleet.

## 8. Push a path to validate write path

From a NixOS workstation that has a push-capable token (mint a separate `--push nix-fleet` token):

```bash
nix copy --to "https://nix.beaco.works/nix-fleet?compression=zstd" \
  /nix/store/<some-derivation-hash>-hello-2.12.1
```

Then on a different fleet host with a pull-only token, request a rebuild that depends on that exact path and verify it resolves as a cache hit.

## 9. Verify durability (SC-004)

```bash
# Force a pod restart
kubectl delete pod -n nix -l app.kubernetes.io/name=attic
# Wait for the new Pod to come up
kubectl rollout status -n nix deploy/attic
# Re-pull the path you pushed in step 8 — should still resolve as a hit
```

## 10. Verify CNPG failover (SC-005)

```bash
# Identify the current primary
kubectl get cluster -n nix attic-pg -o jsonpath='{.status.currentPrimary}'

# Force a failover
kubectl cnpg promote -n nix attic-pg <new-primary-pod>

# attic should reconnect within seconds; pulls should resume
```

## Acceptance checklist (mirrors spec.md SCs)

- [ ] SC-002 — `curl https://nix.beaco.works/nix-fleet/nix-cache-info` → 401 anonymously
- [ ] SC-003 — `curl … /_api/v1/cache-config/nix-fleet` → 200 authenticated
- [ ] SC-004 — pod restart, paths still resolve
- [ ] SC-005 — CNPG failover, service resumes within ~30s
- [ ] SC-001 — fleet host rebuild substitutes from cluster cache (manual smoke test)
- [ ] SC-006 — entire run completed from this runbook with no out-of-band info
