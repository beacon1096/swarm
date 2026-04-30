# zot — multi-registry pull-through cache

> **NOTE (2026-04-30)**: As of [Phase 4b](../decisions/talos-ii/0012-zot-on-talos-ii.md),
> talos-ii's primary registry mirror is the **in-cluster** zot at
> `172.16.87.51:5000` ([runbook](zot-restore.md)). The LAN host
> `172.16.80.240:5000` documented below is **fallback** for
> talos-ii (still active during the 7-day burn-in) and **primary**
> for any consumer not yet migrated — notably talos-i in the
> `swarm-01` repo, plus ad-hoc operator tools (`skopeo` /
> `helm push` / pre-pushed Talos installer images). When/if
> talos-i is adopted into this repo, plan a parallel cutover for
> it (it'll consume the in-cluster zot via
> `zot.tail5d550.ts.net:5000`, not the LAN host).

The cluster's escape hatch for image pulls. Cluster nodes don't talk
to `docker.io` / `ghcr.io` / `quay.io` directly — they talk to the
`zot` instance on `172.16.80.240:5000`, which fetches and caches on
demand. Combined with the [in-cluster sing-box](sing-box-egress.md),
this means GFW-affected egress is centralized to one well-understood
path instead of N ad-hoc failures across N namespaces.

## Where it runs

| component | location | notes |
|---|---|---|
| `zot` v2.1.5 binary | `/usr/local/bin/zot` on `172.16.80.240` | not in NixOS, just a downloaded binary |
| systemd unit | `/etc/systemd/system/talos-mirror.service` | `Description=zot OCI mirror for factory.talos.dev` (name is historical — it serves all upstreams now) |
| config | `/etc/talos-mirror/zot.json` | sync extension lists the upstreams |
| storage | `/var/lib/talos-mirror/` | OCI layout on local disk |
| proxy drop-in | `/etc/systemd/system/talos-mirror.service.d/proxy.conf` | sets `HTTPS_PROXY=http://172.16.87.41:7890` (in-cluster sing-box) |
| listener | `:5000`, plain HTTP, no auth | LAN-only — never exposed beyond the management VLAN |

## What gets cached

`extensions.sync.registries[]` in `zot.json`, all `onDemand: true`:

- `https://registry-1.docker.io` (covers `docker.io`)
- `https://ghcr.io`
- `https://quay.io`
- `https://code.forgejo.org`
- `https://mirror.gcr.io`

`factory.talos.dev` is **deliberately not in sync**: the Talos
secureboot installer image is amd64-only and pre-pushed (see
[Talos image factory](../talos-image-factory.md)), and adding sync
would trigger digest-mismatch loops between the on-demand fetch and
the curated push.

## How cluster nodes use it

Talos `machine.registries.mirrors` (rendered from
[`templates/config/talos/patches/global/machine-registries.yaml.j2`](../../templates/config/talos/patches/global/machine-registries.yaml.j2))
points each upstream at the zot URL:

```yaml
machine:
  registries:
    mirrors:
      docker.io:        { endpoints: ["http://172.16.80.240:5000"] }
      ghcr.io:          { endpoints: ["http://172.16.80.240:5000"] }
      quay.io:          { endpoints: ["http://172.16.80.240:5000"] }
      mirror.gcr.io:    { endpoints: ["http://172.16.80.240:5000"] }
      code.forgejo.org: { endpoints: ["http://172.16.80.240:5000"] }
      factory.talos.dev: { endpoints: ["http://172.16.80.240:5000"] }
      "172.16.80.240:5000": { endpoints: ["http://172.16.80.240:5000"] }
```

The last entry is self-referential — it tells containerd that pulls
of `172.16.80.240:5000/foo:bar` (HelmRelease references) are plain
HTTP, not the default HTTPS.

Containerd renders these into `/etc/cri/conf.d/hosts/<registry>/hosts.toml`
on each node. Verify with:

```bash
talosctl --nodes=172.16.87.202 read /etc/cri/conf.d/hosts/docker.io/hosts.toml
```

## Egress chain

```
node containerd → zot (172.16.80.240:5000)
                     ↓
                  cache hit?  yes → serve from /var/lib/talos-mirror/
                     ↓ no
                  HTTPS_PROXY=http://172.16.87.41:7890
                     ↓
                  in-cluster sing-box-lb (network/sing-box)
                     ↓
                  upstream registry
```

The in-cluster sing-box is reached via Cilium's L2-announced LB IP
on the management VLAN; the UDR routes 172.16.80.0/24 ↔ 172.16.87.0/24.
The zot host has its own sing-box at 127.0.0.1:7890 (for BIRD/OSPF
route advertisement of non-CN ranges) but **zot itself no longer
uses it** — that local sing-box stays only because `bird` needs it.

## Performance characteristics

- **Cache hit**: ~0.4 s (LAN, no auth)
- **Cache miss, sole-source upstream**: 5–10 s (proxy hop + registry)
- **Cache miss, ambiguous upstream**: 35–80 s. zot's onDemand sync
  with multiple registries iterates them in order; each non-matching
  registry returns `401` (ghcr.io, quay.io) or `404` (code.forgejo.org)
  before the right one resolves. Annoying but acceptable for first-pull.
  Optimization (per-registry path prefix routing with `overridePath`)
  is possible but not done.

## Adding a new upstream

1. Edit `/etc/talos-mirror/zot.json` on the proxy host, add to
   `extensions.sync.registries[]`. Restart: `systemctl restart talos-mirror`.
2. Add an entry under `machine.registries.mirrors` in
   [`templates/config/talos/patches/global/machine-registries.yaml.j2`](../../templates/config/talos/patches/global/machine-registries.yaml.j2).
3. Re-render: `task configure` (or `makejinja` directly — but if you
   bypass `task configure` you must also re-encrypt SOPS files).
4. Apply per-node: `task talos:apply-node IP=172.16.87.20{1,2,3}` —
   no reboot needed for registries-only changes.

## Pre-pushed images (no sync involved)

Some images are pushed by hand and intentionally bypass sync:

- `infrastructure/nix-fleet/sing-box:init` — bootstrap sing-box image
  built from `/etc/nixos`'s `k8s-sing-box-oci` derivation. Pushed once
  before sing-box can run, used to bring it up.
- `charts/tailscale-operator:1.96.5` — chart pulled with
  `helm pull tailscale/tailscale-operator --version X` and pushed via
  `helm push <chart>.tgz oci://172.16.80.240:5000/charts --plain-http`.
- `installer-secureboot/<schematic>:v1.12.7` — Talos installer image
  (amd64-only).

These live under their own paths in `/var/lib/talos-mirror/` and aren't
namespaced by upstream registry.

## Troubleshooting

| symptom | likely cause | fix |
|---|---|---|
| `dial tcp 172.16.80.240:5000: i/o timeout` from containerd | zot down or LAN unreachable | `ssh root@172.16.80.240 systemctl status talos-mirror` |
| zot logs show `TLS handshake timeout` to upstream | `HTTPS_PROXY` not in effect (drop-in not loaded) | `systemctl show talos-mirror -p Environment` should include the proxy URL |
| zot logs show `unauthorized` for ghcr.io / quay.io on `library/<name>` paths | expected — those paths don't exist on those registries; zot iterates and finds the right one | ignore unless **all** registries 401 |
| `digest mismatch` on factory.talos.dev pulls | `factory.talos.dev` accidentally added to sync registries | remove from `extensions.sync.registries[]`, restart zot |
| `failed to read index.json` errors after pull failure | benign — zot looks for a partial cache before trying upstream; happens on every miss | ignore |

## Status as of 2026-04-28

- All 3 nodes (ms01-a/b/c) configured with the 5-registry mirror set
- Verified end-to-end: `library/nginx`, `library/alpine`, `library/redis`,
  `library/busybox`, `tailscale/k8s-operator` all cached and re-served
- zot egress confirmed routing through in-cluster sing-box LB
