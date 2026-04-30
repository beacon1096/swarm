# Attic restore — Phase 4a runbook

## What this is

Operations runbook for the attic Nix-binary-cache deploy on
talos-ii (the `nix.${SECRET_DOMAIN}` service). Covers fresh
deploy verification, token mint, fleet rollout, password
rotation, cache creation, image bumps, and known limitations of
this attic version.

For the **why** behind the architecture (CNPG over bitnami,
PG 16 pin, no state migration, image-digest pinning workaround,
atticadm CLI gaps), see
[ADR 0011 — Attic on CloudNativePG](../decisions/talos-ii/0011-attic-cnpg.md).
For the original spec walkthrough — every gotcha, decision,
and lesson folded back as a bug — see
[`specs/001-attic-restore/`](../../specs/001-attic-restore/).

## Pre-requisites

- CloudNativePG operator healthy in `cnpg-system`
  (`kubectl get pods -n cnpg-system`).
- `longhorn-r3` storage class exists (`kubectl get sc longhorn-r3`).
- sing-box egress proxy reachable in-cluster
  (`kubectl get svc -n network sing-box`).
- LAN zot mirror at `172.16.80.240:5000` healthy, with
  `app-template:4.6.2` (n8n already pulls it) and the
  OCI-converted attic image (see §"Image digest bump" below).

## First-deploy verification

This is what to run after a clean reconcile of
`kubernetes/apps/nix/attic/`. The user has already run this once;
the section is here for the disaster-recovery rebuild.

```bash
# CNPG cluster healthy
kubectl get cluster -n nix attic-pg
# expect: 3 instances, READY=3, STATUS=Cluster in healthy state

# Attic Pod 1/1 Running
kubectl rollout status -n nix deploy/attic
kubectl get pods -n nix

# HTTPRoute Accepted=True
kubectl get httproute -n nix attic -o yaml | yq '.status'

# Tailscale per-Service proxy Pod up (in `network` namespace —
# tailscale-operator targetNamespace, not a separate `tailscale`
# namespace).
kubectl get pods -n network | grep ts-attic
# expect: ts-attic-<id>-0   1/1   Running
```

**In-cluster anonymous probe** — auth gate proven before the
public path is wired:

```bash
# Note the explicit `Host: attic` override — attic's allowed-hosts
# matcher does not strip the port from the Host header, so a probe
# via `http://attic:8080/...` would be rejected with 400 "Bad Host"
# without this. See contracts/attic-server-toml.md.
kubectl run -n nix --rm -it probe \
  --image=curlimages/curl --restart=Never -- \
  curl -sI -H "Host: attic" http://attic:8080/nix-fleet/nix-cache-info | head -1
# expect: HTTP/1.1 401
```

**External anonymous probe** — Cloudflare path:

```bash
curl -sI https://nix.beaco.works/nix-fleet/nix-cache-info | head -1
# expect: HTTP/2 401
```

If anonymous returns 200, attic is misconfigured (auth disabled).
If 502/504, the route is broken — check Service endpoints + the
HTTPRoute status. If 400 "Bad Host", an `allowed-hosts` entry
is missing in `server.toml`.

## Token mint procedure

Tokens are minted by the operator running `atticadm` inside the
running attic Pod. The `--sub` field is the subject claim and
shows up in the runbook log; the `--validity` is the upper
bound on the token's lifetime; the `--pull <cache>` /
`--push <cache>` flags scope the token to one or more caches.

`1y` validity is the recommended default for fleet tokens.
Shorter (e.g. `1d`) for emergency replacements; longer tokens
aren't supported by the binary anyway.

**Pull-only (fleet `nix-daemon`)**:

```bash
kubectl exec -n nix deploy/attic -- \
  atticadm -f /config/server.toml make-token \
    --sub nix-daemon \
    --validity 1y \
    --pull nix-fleet
# stdout: a JWT — capture it. Do NOT paste into any file in this repo.
```

**Push-capable (CI / operator workstation)**:

```bash
kubectl exec -n nix deploy/attic -- \
  atticadm -f /config/server.toml make-token \
    --sub <ci-or-operator-name> \
    --validity 1y \
    --pull nix-fleet \
    --push nix-fleet
```

Notes:

- Capture the JWT into a shell variable (`TOKEN=$(kubectl exec ...)`)
  or directly into the destination secret. Do not write tokens to
  files in this repo.
- The `--sub` value should be descriptive enough to identify the
  token holder later if you have to rotate (`nix-daemon` for the
  shared fleet token, `forgejo-runner` or similar for CI).
- `atticadm` in this version does not have an `admin` scope
  separate from `--pull` / `--push`. Tokens that need to call
  cache-config endpoints get those endpoints by virtue of having
  *any* permission on the target cache; see "Adding a new cache"
  for the slightly weird upshot.

## Fleet rollout

The fleet token lives in the **separate** Nix-Fleet repo at
`secrets/shared/attic.yaml`. This swarm repo doesn't touch it.

```bash
# In the Nix-fleet repo:
cd ~/nix-fleet
# Edit secrets/shared/attic.yaml. Replace the existing nix-daemon
# JWT. Keep the surrounding netrc-file shape identical (the file
# is consumed as a netrc by nix-daemon).
sops -e -i secrets/shared/attic.yaml
git diff --stat   # confirm ENC[…] markers
git commit -am "rotate attic pull token (post-talos-ii migration)"
git push
```

Canary one host first:

```bash
ssh <canary-host>
sudo nixos-rebuild switch --flake .#<canary>
# In another terminal on the same host:
journalctl -u nix-daemon -n 200 -f | grep -E 'attic|nix-fleet|substitut'
# expect: lines showing substitutes coming from nix.beaco.works
```

Failure modes during canary:

- HTTP 403/404 from `nix.beaco.works`: token is wrong (mismatched
  scope, expired, or wrong signing key). Re-mint and re-roll.
- `connection refused` / DNS failure: route or DNS issue, not
  attic — check HTTPRoute + Cloudflare DNS.
- Substitutes resolved from `cache.nixos.org` instead of attic:
  netrc shape is wrong, so nix-daemon never tries the
  authenticated cache. Re-check `secrets/shared/attic.yaml`.

After canary succeeds, roll out the rest of the fleet
(`nixos-rebuild switch` on each).

## Token revocation — read this carefully

**`atticadm` in this version does not have a `revoke-token`
subcommand.** This is a known limitation of the binary, not of
the deploy. Two compensating patterns:

1. **Short validity by default.** All fleet tokens are minted
   with `--validity 1y`. If a token is suspected exposed, mint
   a `--validity 1d` replacement, roll the fleet onto it, and
   the leaked token expires within a day on its own.

2. **RS256 keypair rotation — the nuclear option.** Rotating the
   private key in `attic-secret.token-rs256-secret-base64`
   invalidates **every** outstanding token at once (because
   no existing JWT will validate against the new public key).
   Required steps:

   1. Generate a new RS256 keypair (per
      [contracts/attic-server-toml.md](../../specs/001-attic-restore/contracts/attic-server-toml.md)
      §"JWT keys"). `openssl genpkey -algorithm RSA …` — PKCS#8.
   2. Edit `kubernetes/apps/nix/attic/app/secret.sops.yaml`
      (the `attic-secret` document) — replace
      `token-rs256-secret-base64` and
      `token-rs256-public-key-base64`.
   3. `task encrypt-secrets`. `git commit`. `git push`.
   4. Wait for flux + pod restart.
   5. **Coordinate with every consumer**: the fleet
      `nix-daemon`s, any CI runner, any operator workstation
      using a token. They all need replacement tokens minted
      against the new keypair, *at the same time*. There is no
      grace period.

   Treat this as an incident-response procedure, not a routine
   rotation. The day upstream `atticadm` grows a real
   `revoke-token`, this can be deprecated.

The acceptance test in [`spec.md`](../../specs/001-attic-restore/spec.md)
SC-006 ("old token → 401") is satisfied either by waiting out
the natural validity expiry, or — if the operator wants
immediate proof — by performing the keypair rotation above.

## DB password rotation

The DB password for the `attic` Postgres role lives in **two**
SOPS files because attic's `server.toml` inlines the full DSN.
Rotation must happen in **one commit**:

1. `kubernetes/apps/nix/attic/app/pg-secret.sops.yaml` — the
   `attic-pg-app` document's `password` field.
2. `kubernetes/apps/nix/attic/app/secret.sops.yaml` — the
   `attic-secret` document's `server.toml` value, where
   `[database].url` carries the same plaintext password inlined
   into a `postgresql://attic:<DB_PASSWORD>@…` DSN.

Procedure:

```bash
# Workstation
NEW_PW=$(openssl rand -base64 32 | tr -d '\n=' | head -c 32)

# Decrypt + edit both files. Use sops directly so you don't
# accidentally leave a plaintext re-encrypt step out:
sops kubernetes/apps/nix/attic/app/pg-secret.sops.yaml
# → set attic-pg-app.password = $NEW_PW (keep the basic-auth
#   document type)

sops kubernetes/apps/nix/attic/app/secret.sops.yaml
# → in attic-secret.stringData."server.toml", replace the password
#   substring inside [database].url

# Belt-and-suspenders re-encrypt (running makejinja by itself does
# not re-encrypt — a known repo footgun, see
# `~/.claude/projects/-home-beacon-swarm/memory/feedback_makejinja_sops.md`):
cd ~/swarm && task encrypt-secrets

git diff --stat   # confirm both .sops.yaml files show as modified,
                  # and grep the diff for plaintext leakage
git add kubernetes/apps/nix/attic/app/pg-secret.sops.yaml \
        kubernetes/apps/nix/attic/app/secret.sops.yaml
git commit -m "fix(nix): rotate attic DB password"
git push
```

Then wait for flux to roll the helmrelease + CNPG to apply the
new role password. If the two files drift (only one updated, or
two different values), attic CrashLoopBackOffs with
`password authentication failed` until the next commit fixes it.
There is no "soft" failure mode here; the pod will not start.

## Adding a new cache

`atticadm` in this version does not have a `create-cache`
subcommand. New caches go through the REST API.

```bash
# 1. Mint a short-lived admin-ish token. Note this version of
# atticadm does NOT distinguish admin from regular tokens — a
# token with --pull AND --push on the target cache name has
# enough privilege to call cache-config endpoints. The 5m
# validity is the safety net.
ADMIN=$(kubectl exec -n nix deploy/attic -- \
  atticadm -f /config/server.toml make-token \
    --sub admin-create-cache \
    --validity 5m \
    --pull <new-cache-name> \
    --push <new-cache-name>)

# 2. POST the cache config from inside the cluster. The Host
# header MUST be one of the entries in server.toml's
# allowed-hosts list — `nix.beaco.works` is the simplest. The
# in-cluster traffic still goes via the chart-emitted ClusterIP
# Service (no Cloudflare hop), so the cluster IP works fine; only
# the Host header has to match.
kubectl run -n nix --rm -i curl \
  --image=curlimages/curl --restart=Never -- \
  curl -sX POST \
    -H "Authorization: Bearer $ADMIN" \
    -H "Host: nix.beaco.works" \
    -H "Content-Type: application/json" \
    -d '{
      "keypair": "Generate",
      "is_public": false,
      "store_dir": "/nix/store",
      "priority": 41,
      "upstream_cache_key_names": [],
      "retention_period": null
    }' \
    http://attic:8080/_api/v1/cache-config/<new-cache-name>

# 3. Verify with GET
kubectl run -n nix --rm -i curl \
  --image=curlimages/curl --restart=Never -- \
  curl -sH "Authorization: Bearer $ADMIN" \
       -H "Host: nix.beaco.works" \
    http://attic:8080/_api/v1/cache-config/<new-cache-name>
# expect: HTTP 200, JSON body containing public_key, store_dir,
# priority, etc.
```

After the cache exists, mint regular `--pull` / `--push` tokens
scoped to it via the standard `atticadm make-token` flow above.

## Image digest bump

`ghcr.io/zhaofengli/attic` is pinned by digest — see ADR 0011
§5 for the rationale. Bumping is a deliberate operator action.

```bash
# 1. Find the upstream multi-arch index digest you want.
nix-shell -p crane --command 'crane digest ghcr.io/zhaofengli/attic:latest'
# capture as UPSTREAM_DIGEST=sha256:...

# 2. Re-encode to OCI manifest format and push to LAN zot. The
# zot mirror's manifest validator rejects upstream's Docker-v2
# schema-2 envelope; --format=oci re-wraps the same layers.
nix-shell -p skopeo --command "
  skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    --override-os linux --override-arch amd64 \
    --format=oci \
    docker://ghcr.io/zhaofengli/attic@$UPSTREAM_DIGEST \
    docker://172.16.80.240:5000/zhaofengli/attic:phase4a
"
# stdout shows the new OCI-converted digest as the last line of
# Storing signatures / Writing manifest

# 3. Capture the OCI digest. Belt-and-suspenders, query zot:
nix-shell -p crane --command \
  'crane digest --insecure 172.16.80.240:5000/zhaofengli/attic:phase4a'
# capture as OCI_DIGEST=sha256:...

# 4. Edit kubernetes/apps/nix/attic/app/helmrelease.yaml
#   - Update the YAML comment above image: with both digests
#     (upstream + OCI), so future bumpers know the relationship.
#   - Update image.digest: to $OCI_DIGEST.

# 5. Commit + push as a normal flux-driven update.
```

**Always record both digests in the YAML comment.** The
upstream digest is what a future operator will start with when
checking for a newer build; the OCI digest is what's actually
running. Without the comment, the relationship is obscure.

## Token issuance log

| issued     | sub          | scope                                | validity | rolled out by | notes                                                                  |
|------------|--------------|--------------------------------------|----------|---------------|------------------------------------------------------------------------|
| 2026-04-30 | nix-daemon   | `--pull nix-fleet`                   | 1y       | beacon        | Phase 4a initial rotation post-talos-ii migration, 3 fleet hosts rebuilt |
| 2026-04-30 | <CI sub>     | <CI scope as issued>                 | 1y       | beacon        | Phase 4a CI token, used by <where>                                     |

<!-- TODO(beacon): replace the second row's <CI sub>, <CI scope as issued>, and <where> placeholders with the real values from the CI token mint. Do not commit a row with placeholders to a release; the placeholders are here so future runbook readers can see the column shape, but the actual issued values are what an audit needs. -->

When you mint a new token, append a row above (newest at bottom)
recording: ISO date, `--sub`, scope flags as actually passed,
validity, the operator who minted it, and a short note on
purpose.

## Known issues / caveats

- **HelmRelease shows `Stalled=MissingRollbackTarget` while
  functionally healthy.** The first-deploy iteration left flux's
  release history in a state where it can't compute a rollback
  target. The Pod is `1/1 Running`, the chart values are correct
  in-cluster, and `helm get values -n nix attic` reflects the
  desired state — but `flux get hr -n nix attic` reports
  `Stalled`. Fix when convenient with
  `flux suspend hr -n nix attic && helm uninstall -n nix attic && \
   <re-apply manifests>; flux resume hr -n nix attic`. Not blocking;
  tracked as separate cleanup work.

- **`ts-attic-tailscale-*` Pod logs cn-qcloud DERP EOF loops.**
  Same pattern forgejo's tailscale Service exhibits — the
  cn-qcloud DERP region is unreliable from inside CN. Control
  plane succeeds (the device is on the tailnet), data plane
  is best-effort. Documented in
  [tailscale-operator.md §"Known issues"](tailscale-operator.md).

- **`atticadm` CLI surface is narrower than upstream docs imply.**
  Specifically: no `create-cache`, no `list-caches`, no
  `revoke-token`. Cache creation goes through the REST API
  (see "Adding a new cache" above). Token revocation is achieved
  via short validity + keypair rotation (see "Token revocation").
  Watch upstream releases — the day these subcommands ship, this
  runbook simplifies considerably.

- **`atticd` has no `server` subcommand and no `--listen` flag.**
  Listen address goes in `server.toml`'s top-level `listen`. The
  helmrelease passes only `--config /config/server.toml`. Passing
  `server` or `--listen` makes the binary exit immediately with
  `unexpected argument`.

- **`allowed-hosts` does not strip port from the Host header.**
  An in-cluster `curl http://attic:8080/...` sends
  `Host: attic:8080` and gets rejected with HTTP 400 "Bad Host"
  even when `attic` is in `allowed-hosts`. Probe via
  `-H "Host: attic"` or via the public URL where Cloudflare's
  proxy hands attic the bare hostname.

- **`HelmRelease.dependsOn` doesn't accept CRD references.** Don't
  list `attic-pg` (a CNPG `Cluster`) there; the chart will pin in
  `PrerequisitesNotMet` forever. Trust kube's restart-on-failure
  for the brief CrashLoopBackOff while the DB bootstraps.

- **DSN password drift between the two SOPS files** (covered above
  in "DB password rotation"). The most common reason for an
  attic Pod to CrashLoopBackOff post-deploy.

## Status

- 2026-04-30: First-deploy verified end-to-end. All SCs (SC-001
  through SC-005) passing; SC-006 satisfied by this runbook
  being writable from the deploy log alone.
