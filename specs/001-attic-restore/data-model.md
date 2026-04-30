# Data model — Attic restore (Phase 4a)

This is a GitOps feature, not an application code feature, so the "data model" is really the set of cluster resources we're declaring and the relationships among them. Each entity below corresponds to a manifest file under `kubernetes/apps/nix/attic/`.

## Namespace

- **`nix`** — single new namespace introduced by this feature. Plain `Namespace` resource at `kubernetes/apps/nix/namespace.yaml`. The `nix/` namespace tier also gets a `kustomization.yaml` listing `./attic` so the umbrella `kubernetes/flux/cluster/...` Kustomization picks it up via its directory walker.

## Secrets (3)

### `attic-pg-app` (basic-auth)

| Key | Source | Notes |
|---|---|---|
| `username` | hand-written | Always `attic`. |
| `password` | hand-generated, ≥ 32 chars random | **Same value as is inlined into `attic-secret.server.toml`'s `database.url`.** |

CNPG's `bootstrap.initdb.secret.name = attic-pg-app` causes the operator to create the PG role with this password.

### `attic-pg-superuser` (basic-auth)

| Key | Source | Notes |
|---|---|---|
| `username` | hand-written | Always `postgres`. |
| `password` | hand-generated, ≥ 32 chars random | Independent of the app password. Used only by the operator and for emergencies. |

CNPG's `superuserSecret.name = attic-pg-superuser` exposes this for `kubectl exec deploy/attic-pg-1 -- psql` flows.

### `attic-secret` (Opaque)

| Key | Source | Notes |
|---|---|---|
| `server.toml` | hand-written, contents below | Mounted at `/config/server.toml`. |
| `token-rs256-secret-base64` | `openssl genpkey -algorithm RSA …` then base64 | Mounted as env `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64`. |
| `token-rs256-public-key-base64` | derived from above | Mounted as env `ATTIC_SERVER_TOKEN_RS256_PUBLIC_KEY_BASE64`. (Optional — server can re-derive, but pinning is safer.) |

`server.toml` shape is documented in [contracts/attic-server-toml.md](./contracts/attic-server-toml.md).

All three secrets are SOPS-encrypted with the project's age key and live at:

- `kubernetes/apps/nix/attic/app/pg-secret.sops.yaml` (combines `attic-pg-app` + `attic-pg-superuser` as two YAML documents in one file — same shape as `coder/app/pg-secret.sops.yaml`)
- `kubernetes/apps/nix/attic/app/secret.sops.yaml` (`attic-secret` as one document)

## CNPG `Cluster` — `attic-pg`

```yaml
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4
  primaryUpdateStrategy: unsupervised
  storage:
    size: 8Gi
    storageClass: longhorn-r3
  bootstrap:
    initdb:
      database: attic
      owner: attic
      secret:
        name: attic-pg-app
      encoding: UTF8
  superuserSecret:
    name: attic-pg-superuser
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { memory: 384Mi }
  monitoring:
    enablePodMonitor: false
```

Exposed Services (auto-created by CNPG): `attic-pg-rw`, `attic-pg-ro`, `attic-pg-r`. attic uses `attic-pg-rw` only.

## PVC — `attic-store`

```yaml
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-r3
  resources:
    requests: { storage: 100Gi }
```

Mounted at `/var/lib/attic/store` in the attic pod via the bjw-s `persistence:` block (`existingClaim: attic-store`).

## HelmRelease — `attic`

`bjw-s/app-template` v4.6.2. Single container `app` running `atticd --config /config/server.toml` (no `server` subcommand, no `--listen` flag — listen address comes from `server.toml`). Ports: 8080 named `http`. Egress env: `HTTPS_PROXY` / `HTTP_PROXY` → `http://sing-box.network.svc.cluster.local:7890`; `NO_PROXY` per the cluster convention (with both trailing-dot variants). **No** `HelmRelease.dependsOn` — that field only resolves against other HelmReleases, and `attic-pg` is a CNPG `Cluster` CRD; let kube's restart-on-failure handle the brief CrashLoopBackOff while the DB bootstraps.

Volumes:

- `attic-secret` Secret → `/config/server.toml` via `subPath: server.toml`
- `attic-store` PVC → `/var/lib/attic/store`

The chart will emit a `Service/attic` (ClusterIP, port 8080).

## Services (2)

1. **`attic`** (chart-emitted): ClusterIP, port 8080 → 8080. Backend for the public HTTPRoute.
2. **`attic-tailscale`** (hand-written): ClusterIP, port 8080 → 8080, selector `app.kubernetes.io/name: attic`, with annotations:
   - `tailscale.com/expose: "true"`
   - `tailscale.com/hostname: "attic"`
   - `tailscale.com/proxy-class: "proxied"` ← **required** per `docs/operations/tailscale-operator.md`

## HTTPRoute — `attic`

```yaml
spec:
  hostnames: ["nix.${SECRET_DOMAIN}"]
  parentRefs:
    - { name: envoy-external, namespace: network, sectionName: https }
  rules:
    - backendRefs:
        - { name: attic, port: 8080 }
```

`${SECRET_DOMAIN}` is substituted by flux's `postBuild.substituteFrom: cluster-secrets`.

## Flux `Kustomization` — `attic` (the `ks.yaml`)

```yaml
spec:
  path: ./kubernetes/apps/nix/attic/app
  postBuild:
    substituteFrom:
      - { name: cluster-secrets, kind: Secret }
  prune: true
  sourceRef: { kind: GitRepository, name: flux-system, namespace: flux-system }
  targetNamespace: nix
  wait: false
  timeout: 10m
```

No `dependsOn` block — coder/n8n/matrix don't list cnpg or longhorn either; they trust the cluster baseline and let Flux retry until the Cluster CRD is reconciled. (If you ever want to add one: the CNPG Flux Kustomization is `cloudnative-pg` in **`flux-system`** namespace, not `cnpg-system` — the latter is the operator install ns, not where the Kustomization resource lives.) No authentik dep either (attic doesn't use OIDC).

## Relationships at a glance

```
                        cluster-secrets (Secret)
                                │
                                │ ${SECRET_DOMAIN}
                                ▼
                          HTTPRoute attic ─── envoy-external Gateway
                                │                    │
                                │ backendRef         │ Cloudflare Tunnel
                                ▼                    ▼
                          Service attic ──── (chart-emitted, port 8080)
                                │
                                │ selector
                                ▼
                          Pod  attic ─── attic-store PVC (100Gi longhorn-r3)
                                │           │
                                │           └─── /var/lib/attic/store
                                │
                                ├─── /config/server.toml ◀── Secret attic-secret
                                │                                 │ database.url
                                │                                 ▼
                                └─── network ◀──── Service attic-pg-rw
                                                       │
                                                       ▼
                                                  CNPG Cluster attic-pg (3× longhorn-r3)
                                                       │
                                                       └─── bootstrap.initdb.secret = Secret attic-pg-app

                          Service attic-tailscale (annotations) ─── tailscale-operator
                                │
                                ▼
                          ts-attic-<id>-0 (StatefulSet, ProxyClass=proxied)
                                │
                                ▼
                          tailscale device "attic"
```
