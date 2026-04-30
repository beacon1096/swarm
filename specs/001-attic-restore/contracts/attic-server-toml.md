# Contract — `server.toml`

This file documents the exact `server.toml` shape attic expects, plus the JWT key generation procedure. Both the helmrelease and the runbook reference this contract.

## Minimal correct shape

```toml
listen = "[::]:8080"

# Allowed Host headers. Public + tailnet FQDNs both belong here, plus
# the bare service name for in-cluster probing. attic does NOT strip
# port from the Host header before matching, so an in-cluster probe
# via `Host: attic:8080` will be rejected as "Bad Host" with HTTP 400 —
# probe with an explicit `-H "Host: attic"` override or hit the public
# URL via the HTTPRoute.
allowed-hosts = [
  "attic",
  "attic.tail5d550.ts.net",
  "nix.${SECRET_DOMAIN}",
]

api-endpoint = "https://nix.${SECRET_DOMAIN}/"

[database]
url = "postgresql://attic:<DB_PASSWORD>@attic-pg-rw.nix.svc.cluster.local:5432/attic"

[storage]
type = "local"
path = "/var/lib/attic/store"

[chunking]
nar-size-threshold = 65536        # 64 KiB — chunk anything larger than this
min-size           = 16384        # 16 KiB
avg-size           = 65536        # 64 KiB
max-size           = 262144       # 256 KiB

[compression]
type = "zstd"

[garbage-collection]
default-retention-period = "6 months"
```

**Do NOT** include `[jwt]` or `[require-proof-of-possession]` as TOML section headers. `[jwt]` would expect nested config keys we provide via env vars instead, and `require-proof-of-possession` is a top-level boolean — writing it as a section header gets parsed as a map and crashes attic with `invalid type: map, expected a boolean`. Both keys default to upstream defaults (proof-of-possession = `true`), which is what we want.

Notes:

- `listen = "[::]:8080"` so the pod accepts both v4 and v6 inside its netns.
- `allowed-hosts` is **required** in attic ≥ 0.2 — without it, all requests get rejected with "host not allowed" / `400 Bad Host` even when they hit the right Service.
- `api-endpoint` is the user-visible URL. Used for the `nix-cache-info` `URI` field returned to clients. If wrong, clients get a redirect loop. `${SECRET_DOMAIN}` is substituted by Flux's `postBuild.substituteFrom: cluster-secrets` against the YAML (Secret stringData) at apply time.
- `[chunking]` — must be present even with default values. Missing section silently breaks pushes.
- `[compression]` — `zstd` is the upstream default and works fine; explicit pin keeps the contract stable.
- `[garbage-collection]` — sets the *default* retention for newly-created caches. The `nix-fleet` cache itself has its own per-cache retention setting that the operator can tune via `atticadm`; this is just the boot default.

## Database URL pattern

`postgresql://attic:<DB_PASSWORD>@attic-pg-rw.nix.svc.cluster.local:5432/attic`

- Hostname is the CNPG-emitted `attic-pg-rw` Service. **Use the FQDN form** (`.nix.svc.cluster.local`), not the short form `attic-pg-rw`. The FQDN matches the trailing-dot domain in `NO_PROXY` and avoids any chance of the cluster's resolver attempting an upstream lookup.
- Password is the **same** plaintext value as `attic-pg-app.password`. See data-model.md for the dual-secret pattern.
- Database name `attic`, user `attic` — must match `bootstrap.initdb.{database, owner}` in `pg-cluster.yaml`.

## JWT keys

attic signs tokens with an RS256 keypair. Generate **once** on the operator workstation; do **not** re-run after deploy or every issued token becomes invalid.

```bash
# Private key — 4096-bit RSA in PKCS#8 PEM
openssl genpkey -algorithm RSA -out priv.pem -pkeyopt rsa_keygen_bits:4096

# Derive public key
openssl rsa -in priv.pem -pubout -out pub.pem

# Base64-encode for the Secret stringData (no line breaks)
base64 -w0 priv.pem > priv.b64
base64 -w0 pub.pem  > pub.b64
```

Then in `secret.sops.yaml`:

```yaml
stringData:
  token-rs256-secret-base64: <contents of priv.b64>
  token-rs256-public-key-base64: <contents of pub.b64>
```

attic reads them from the `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64` and `ATTIC_SERVER_TOKEN_RS256_PUBLIC_KEY_BASE64` env vars — wired up by the helmrelease's `envFrom: secretRef: attic-secret` block (or per-key `valueFrom.secretKeyRef`, equivalent).

**WARNING**: regenerating these keys after the cache is in use revokes every token in existence. Treat them as long-lived. If you need to rotate, plan for a coordinated fleet-token re-mint at the same time.

## What's in which Secret

| Field | Secret | Mount style |
|---|---|---|
| `server.toml` | `attic-secret` | file at `/config/server.toml` (subPath) |
| `token-rs256-secret-base64` | `attic-secret` | env `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64` |
| `token-rs256-public-key-base64` | `attic-secret` | env `ATTIC_SERVER_TOKEN_RS256_PUBLIC_KEY_BASE64` |
| `username` (= `attic`) | `attic-pg-app` | (not mounted into attic; CNPG reads it during bootstrap only) |
| `password` (DB password) | `attic-pg-app` | (not mounted into attic; the same plaintext is inlined into `server.toml.database.url`) |
| `username` (= `postgres`) | `attic-pg-superuser` | (not mounted; superuser exec only) |
| `password` (superuser password) | `attic-pg-superuser` | (not mounted; superuser exec only) |
