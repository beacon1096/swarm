# ADR shared/0003 — talos-i positioning: offsite observability + backup

**Scope:** shared — affects both talos-ii (primary) and talos-i.
**Status:** proposed (open sub-decisions noted; accept after answering them)
**Date:** 2026-05-04

## Context

Until 2026-05-04 the working assumption in this repo was: talos-i
gets adopted into the same repo, runs on the same LAN as talos-ii,
and both clusters share VLAN 87 with mutual L2 reachability. ADRs
shared/0002 (mesh) and the pending VLAN-LB exemption ADR were
written under that assumption.

A 2026-05-04 conversation re-framed talos-i's role:

> "以后的定位的话 预计主力集群是 Talos-ii，而 Talos-i 可以做观测和异地备份。
> 不一定会再和 Talos-ii 放在一个局域网下了."

This ADR fixes that re-framing as the canonical posture, so that
downstream decisions (mesh implementation, VLAN-LB rewrite,
backup/DR strategy, egress-gateway scope) can build on a stable
premise.

## Decision drivers

1. **Primary/secondary asymmetry**: talos-ii (3× MS-01 bare-metal
   on VLAN 87) is the primary workload home. It already runs the
   migrated identity / collaboration / nix / development /
   registry stacks (Phase 3a–4b complete) and is where future
   user-facing services land.
2. **Offsite resilience**: a second cluster in a different
   physical location decouples blast radius. A residential network
   outage, ISP issue, or hardware loss at site A no longer takes
   the backups with it.
3. **Observability separation of concerns**: monitoring talos-ii
   from talos-ii itself is a known anti-pattern (the observability
   stack goes down with the thing it's observing). Hosting
   victoria-metrics / victoria-logs on a separate cluster, ideally
   off-network, is a meaningful reliability win.
4. **Hardware reality**: talos-i runs as Harvester KubeVirt VMs on
   a NEC8 mini-PC. Lower-spec, KubeVirt-nested, and not suited for
   primary user workloads — but well-suited for low-throughput
   observability and async backup landing.
5. **Network reality (China)**: cross-LAN over residential ISP
   (or to a VPS) means GFW transit. The mesh fabric (already
   accepted in shared/0002 as Option C) carries cross-cluster
   traffic; this ADR commits to using it as the cluster fabric,
   not as an optional convenience.

## What changes vs the previous assumption

| Dimension                          | Previous (co-LAN talos-i)               | New (offsite talos-i)                                  |
|------------------------------------|------------------------------------------|---------------------------------------------------------|
| Physical location                  | Same LAN as talos-ii (VLAN 87)           | Different network — TBD residential / colo / VPS        |
| L2 reachability between clusters   | Yes (shared VLAN)                        | **No** — mesh is the only path                          |
| VLAN-LB exemption ADR (pending)    | "talos-i consumes some VLAN 87 IPs"      | talos-i is **not** a same-LAN consumer — needs rewrite  |
| Cross-cluster pod traffic          | Optional, mostly local                   | **Required** for observability scrape and backup        |
| Mesh role                          | Convenience for tools/humans             | **Cluster fabric** — pod-level dependency               |
| Talos image factory                | Self-hosted on talos-i (per index.md)    | Continues, but talos-ii reads via tailnet, not LAN URL  |
| Backup direction                   | Undefined                                 | **talos-ii → talos-i** (offsite)                        |
| API access from operator laptop    | Direct LAN to either                     | Via mesh to talos-i; may stay direct LAN to talos-ii    |

## Workload disposition (talos-i current → future)

Snapshot of `kubectl get pod -A` on talos-i 2026-05-04 + repo
manifests in `swarm-01/kubernetes/apps/`:

**Stay on talos-i (the reason this cluster continues to exist):**

- `observability/` — victoria-metrics, victoria-logs,
  victoria-logs-collector, uptime-kuma. Future scrape targets
  include talos-ii via mesh.
- `kube-system` baseline (cilium, coredns, metrics-server,
  reloader, spegel) — required for any cluster.
- `cert-manager`, `flux-system`, `flux-instance`, `flux-operator`
  — required for GitOps.
- `network/` mesh + DNS-front pieces (tailscale or NetBird subnet
  router, k8s-gateway, cloudflare-dns, cloudflare-tunnel for any
  public observability page) — exact set depends on the mesh
  control-plane decision below.

**Migrate to talos-ii:**

- `home/home-assistant`
- `media/immich`, `media/navidrome`
- `ai/*` — memoh, openviking, tabby, tigerfs, zeroclaw-{binah,
  chokmah, kether, malkuth, yesod} (9 deployments)
- `development/forgejo-runner` — already under discussion as part
  of the egress-gateway / CI-runner consolidation thread

**Decommission entirely:**

- `registry/zot` (talos-i in-cluster) — talos-ii has its own
  in-cluster zot (Phase 4b accepted ADR talos-ii/0012); the LAN
  host zot at `172.16.80.240` retires as part of Phase 5; offsite
  talos-i has no LAN consumers to serve, so this layer collapses
- `default/echo` — test residue
- `registry/talos-image-factory` — **open sub-decision** (see below)

**GitOps cleanup:**

`swarm-01/kubernetes/apps/` retains manifests for already-migrated
services (identity/{authentik,vaultwarden}, collaboration/matrix,
nix/attic, development/{atuin,coder,forgejo,n8n}). Implementation
of this ADR includes suspending or deleting those entries to
match cluster reality.

## Open sub-decisions (must be answered before this ADR is accepted)

1. **Physical location of talos-i offsite host** — residential
   ISP at a different home, friend's location, dedicated colo,
   or a VPS-hosted Harvester. Affects bandwidth / latency / cost
   / control. No default proposed; user input needed.

2. **Mesh control-plane choice** — interacts with
   shared/0002.OpenQuestions:
   - **Tailscale (managed)**: simplest; commercial pricing
     concerns; cn-qcloud DERP fragility per Tailscale ACL DERPMap
     memory; control plane in vendor's hands.
   - **NetBird self-hosted**: matches the migration intent
     embedded in shared/0002's Option C rationale; control plane
     placement becomes its own decision (talos-ii? talos-i?
     third VPS?).
   - **Raw WireGuard + manual config**: low-overhead but
     human-effort heavy; rules out auto-discovery for ad-hoc
     human laptops on the mesh.

3. **Hardware retention or replacement** — keep NEC8 + Harvester
   KubeVirt as-is, or rebuild on a different small SFF box without
   KubeVirt nesting. KubeVirt nesting is currently load-bearing
   for the `util-linux-mountpoint` extension story (see expected
   talos-i/0001 placeholder in docs/index.md). Removing KubeVirt
   simplifies but loses the ability to host nested test VMs.

4. **Talos image factory: self-hosted or official?** — talos-i
   currently runs a self-hosted image factory because of cn-network
   constraints. If talos-i moves to a non-China network, the
   official factory may suffice; if stays in China, self-hosted
   stays. Affects `docs/talos-image-factory.md` per cluster.

5. **Timing** — when does the move happen? Constrained by:
   migrate workloads off talos-i first (home/media/ai/* land on
   talos-ii); accept downstream ADRs (shared/0004 egress-gateway,
   VLAN-LB rewrite, backup/DR); confirm offsite hardware + network.
   No dates committed in this ADR.

6. **Inbound exposure on talos-i** — observability dashboards
   (Grafana / VictoriaMetrics UI) are accessed by humans. Offsite
   has options: tailnet-only (already the convention), Cloudflare
   Tunnel (works through any uplink), public IP at the offsite
   site (rare for residential). Default: tailnet-only with
   optional Cloudflare Tunnel for read-only public dashboards.

7. **Storage on talos-i** — current Harvester-CSI is fine for
   observability hot data. Backup landing zone (for talos-ii
   Longhorn snapshot replication or restic-style object storage)
   needs separate sizing — likely external NAS or cloud object
   store, not local cluster CSI.

## Decision (proposed, pending sub-decisions)

**talos-i becomes the offsite observability + backup-landing
cluster**, distinct from talos-ii (primary). Cross-LAN by default.
Mesh per shared/0002 Option C is the cluster fabric.

This ADR does **not** answer the open sub-decisions above. It
fixes the strategic posture so downstream ADRs (shared/0004
egress-gateway, VLAN-LB rewrite, backup/DR) can be written against
a stable premise. Sub-decisions 1–7 each become their own decision
record (or dedicated section here once answered) before this ADR
moves from `proposed` to `accepted`.

## Implementation impact (deferred until accepted)

- talos-i adoption into this repo: adds `docs/decisions/talos-i/`,
  `talos/clusters/talos-i/`, `kubernetes/clusters/talos-i/` per
  the index.md "new cluster" convention.
- VLAN-LB exemption ADR (pending memory item): rewrite to drop
  "same-LAN talos-i consumers"; remaining consumers are LAN
  humans + on-LAN devices only.
- Backup/DR ADR: separate document, defines what data flows
  talos-ii → talos-i, on what cadence, with what RTO/RPO targets.
- swarm-01 repo retirement: once talos-i is adopted into `swarm`,
  the `swarm-01` repository goes read-only; cluster definitions
  move under `swarm/`. Existing references and the still-active
  swarm-01 GitOps must be cut over carefully (this is its own
  runbook, not part of this ADR).
- Constitution review: Principle VII (VLAN-internal LB) language
  may need amending once VLAN-LB rewrite ADR lands, since "talos-i
  on the same VLAN" was implicit context.

## References

- [shared/0002 — Mesh integration modes](0002-mesh-integration-modes.md) — accepted; Option C is the cluster fabric this ADR depends on
- [shared/0001 — Spec-Driven Development](0001-spec-driven-development.md) — applies to the implementation work this ADR queues up
- [`docs/index.md`](../../index.md) — current cluster table; "talos-i not yet adopted" line will update when this ADR + adoption land
- [`docs/cluster-definition.md`](../../cluster-definition.md) — current truth on talos-ii; talos-i section to be added at adoption time
- 2026-05-04 conversation — origin of this re-framing; recorded in session log only
