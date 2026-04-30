# Contract — zot `config.json`

The minimal, working `config.json` shape that the in-cluster zot expects. Rendered by the official chart from `configFiles.config.json` in HelmRelease values, mounted at `/etc/zot/config.json`.

This contract is the source-of-truth for the `extensions.sync.registries[]` entries (FR-005, FR-006), the auth shape (FR-007, FR-008), the storage layout (FR-010), and the GC schedule (operator-facing).

## Top-level structure

```jsonc
{
  "distSpecVersion": "1.1.1",            // OCI Distribution Spec version zot speaks
  "storage": { ... },                    // where blobs live, GC, dedupe
  "http":    { ... },                    // listener, auth, accessControl
  "log":     { ... },                    // logging
  "extensions": {
    "search":  { ... },                  // optional; enables /v2/_catalog richer queries
    "sync":    { ... },                  // pull-through cache: this is the core feature
    "scrub":   { ... },                  // optional; periodic integrity scrub
    "metrics": { ... }                   // optional; Prometheus endpoint
  }
}
```

## Required keys

### `storage`

```jsonc
{
  "rootDirectory": "/var/lib/registry",
  "dedupe": true,                        // hardlink dedupe across blobs (cheap, big win for layered images)
  "gc": true,                            // mark + sweep
  "gcDelay": "1h",                       // grace period before unreferenced blobs are deletable
  "gcInterval": "24h",                   // GC pass cadence
  "commit": false                        // don't fsync each write — Longhorn-r2 already replicates
}
```

- `rootDirectory`: must match the PVC's mountPath (300 Gi longhorn-r2 PVC `zot-store` mounted at `/var/lib/registry`).
- `dedupe: true`: critical for cache-cost. Multi-image overlays often share base layers; dedupe collapses identical blobs.
- `gc: true` + `gcInterval: "24h"`: keeps the PVC from ballooning indefinitely. `gcDelay: "1h"` means a blob unreferenced for 1 h becomes a GC candidate; this is enough headroom that an in-progress upload won't get GC'd mid-flight.
- `commit: false`: zot's per-write fsync is redundant when Longhorn replication is the durability boundary.

### `http`

```jsonc
{
  "address": "0.0.0.0",
  "port": "5000",
  "realm": "zot",
  "auth": {
    "htpasswd": {
      "path": "/secret/htpasswd"         // injected from zot-secret SOPS Secret
    },
    "failDelay": 1                        // seconds; throttles bad-credential probing
  },
  "accessControl": {
    "repositories": {
      "**": {
        "anonymousPolicy": ["read"],     // FR-007: anonymous read for talos containerd
        "policies": [
          {
            "users":   ["admin"],
            "actions": ["read", "create", "update", "delete"]   // FR-008: admin push
          }
        ],
        "defaultPolicy": []              // authenticated-non-admin = no extra grant; falls through to anonymousPolicy
      }
    }
  }
}
```

- `accessControl.repositories["**"]`: glob match on every repo. Two policies cohabit: anonymous read (for containerd, no creds), admin read+write (for operator pushes).
- `defaultPolicy: []` means "any authenticated user that isn't admin gets no extra rights beyond anonymousPolicy". Since the only authenticated user is `admin` (single htpasswd entry per FR-008), this is effectively: anonymous = read, admin = read+write.
- `realm: "zot"`: shows up in 401 responses' `WWW-Authenticate` header. Cosmetic.

### `log`

```jsonc
{
  "level": "info",
  "output": "stdout"
}
```

`info` is the zot default and matches what the LAN host runs; `stdout` lets `kubectl logs` work natively. No file rotation needed inside the pod.

### `extensions.sync`

This is the core of the pull-through cache.

```jsonc
{
  "enable": true,
  "credentialsFile": "",
  "registries": [
    {
      "urls": ["https://registry-1.docker.io"],
      "onDemand": true,
      "pollInterval": "0",               // no scheduled mirror — only on-demand
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://ghcr.io"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://quay.io"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://mirror.gcr.io"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://gcr.io"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://registry.k8s.io"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://docker.elastic.co"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://code.forgejo.org"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    },
    {
      "urls": ["https://docker.n8n.io"],
      "onDemand": true,
      "pollInterval": "0",
      "tlsVerify": true,
      "content": [
        { "prefix": "**", "destination": "/", "stripPrefix": false }
      ]
    }
  ]
}
```

**Per-entry semantics**:

- `urls[]`: zot's upstream(s) for this entry. Single-element in our case; multi-URL is for HA upstreams.
- `onDemand: true`: fetch only on first client request. **Required**. The alternative (`onDemand: false` with `pollInterval`) would scheduled-mirror every tag of every repo from the upstream, which is unbounded and pointless for our workload.
- `pollInterval: "0"`: no scheduled refresh. Combined with `onDemand: true`, this is "fetch on miss, cache forever, no background work".
- `tlsVerify: true`: validate upstream certs via the in-pod CA bundle. Required because the upstream URLs are HTTPS.
- `content[].prefix: "**"`: match every repo path under the upstream's namespace.
- `content[].destination: "/"`: store at the same path. So `docker.io/library/nginx:1.27` lands at `/var/lib/registry/library/nginx/...` on the PVC.
- `content[].stripPrefix: false`: don't trim the upstream's path.

**`registry-1.docker.io` covers `docker.io`** — the same trick the LAN host uses (per [`docs/operations/zot-mirror.md`](../../docs/operations/zot-mirror.md)). Containerd and skopeo both treat `docker.io` as an alias that resolves to `registry-1.docker.io`; zot's mirror handler accepts either.

**`factory.talos.dev` is deliberately omitted** — see [`research.md` Q1](../research.md#q1--fr-006-enumerate-the-lan-zot-upstream-registries).

**`cache.nixos.org` is deliberately omitted** — it's a Nix binary cache, not an OCI registry. attic and `nix-daemon` reach it via `HTTP_PROXY` to sing-box directly. Listing it here would be inert.

### `extensions.search`

```jsonc
{
  "enable": true,
  "cve": {
    "updateInterval": "24h"             // optional CVE feed refresh
  }
}
```

Optional but useful — enables richer `/v2/_catalog?n=…` queries. Operator can query the registry's repository list during runbook checks. CVE feed is benign.

### `extensions.scrub`

```jsonc
{
  "enable": true,
  "interval": "168h"                    // weekly
}
```

Periodic blob integrity scrub. Catches Longhorn-detected silent corruption before a pull surfaces it. Weekly is the zot default.

### `extensions.metrics`

```jsonc
{
  "enable": true,
  "prometheus": {
    "path": "/metrics"
  }
}
```

Prometheus scrape endpoint at `/metrics`. Not consumed today (no Prometheus stack in this repo yet) but cheap to enable for future.

## Optional sections (not in v1)

The following zot config sections are **not** included in v1:

- `extensions.lint`: image-build-time concern, not a mirror concern.
- `extensions.mgmt`: the management UI. Could be added later behind authentik OIDC; out of scope for Phase 4b.
- `extensions.userprefs`: requires a per-user store; multi-user feature, not relevant for single-admin model.
- `extensions.trust` / cosign verification: future.
- `extensions.ui`: the web UI. Optional and harmless to enable; v1 leaves it off to minimize surface area (the tailnet hostname is not for human browsing, it's for talos-i containerd).

## File-level invariants

- The whole file is rendered by the chart from values; the implementer does **not** hand-edit a ConfigMap.
- The chart's JSON schema (in upstream `zot/zot/values.schema.json`) catches mistakes like `onDemand: "true"` (string instead of bool), missing `urls[]`, mistyped extension names. This validation is half the reason we picked the official chart over `bjw-s app-template` (see [`research.md` Q4](../research.md#q4--helm-chart-selection-official-zot-vs-bjw-s-app-template)).
- The file is mounted **read-only** at `/etc/zot/config.json`. zot does **not** support runtime reload of `config.json` — adding a new upstream requires the Pod to restart. Flux + Recreate strategy handles this automatically when the ConfigMap content changes.

## Verification commands

After deploy, the operator can sanity-check the running config:

```bash
# 1. Confirm the Pod loaded the right config.
kubectl exec -n registry deploy/zot -- cat /etc/zot/config.json | jq '.extensions.sync.registries | length'
# Expected: 9 (the 9 registries above).

# 2. Confirm anonymous read works (FR-007).
curl -s -o /dev/null -w '%{http_code}\n' http://172.16.87.51:5000/v2/
# Expected: 200.

# 3. Confirm push requires auth (FR-008).
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://172.16.87.51:5000/v2/test/blobs/uploads/
# Expected: 401.

# 4. Confirm authenticated push works.
curl -s -o /dev/null -w '%{http_code}\n' -u admin:<password> -X POST http://172.16.87.51:5000/v2/test/blobs/uploads/
# Expected: 202 (upload session created) or 401 only if creds are wrong.

# 5. Confirm a fresh upstream sync works.
curl -s http://172.16.87.51:5000/v2/library/alpine/manifests/3.20 \
     -H 'Accept: application/vnd.oci.image.manifest.v1+json' | jq .
# Expected: a valid OCI image manifest body, fetched on-demand from docker.io.
```

Each check maps to one or more spec FRs and gives the operator a fast-path signal during cutover.
