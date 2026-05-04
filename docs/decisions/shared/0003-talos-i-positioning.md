# ADR shared/0003 — talos-i positioning: offsite observability + backup

**Scope:** shared — affects both talos-ii (primary) and talos-i.
**Status:** accepted (2026-05-04)
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

## Sub-decisions (resolved 2026-05-04)

1. **Physical location** — residential, at a separate home (not
   colo, not VPS). **No public IPv4.** IPv6 may be available but
   only treated as hole-punching aid for the mesh, not as
   advertised endpoint. All inbound to talos-i passes through the
   mesh.

2. **Mesh control-plane** — **Tailscale (managed) for now**, with
   a planned migration to a self-hosted control plane on a VPS
   later. The self-hosted control plane (likely Headscale or
   NetBird) will be managed by a separate NixOS-flake repo at
   `/etc/nixos`, **not** by this `swarm` repo. This `swarm`
   repository's mesh integration (shared/0002 Option C, the
   `siderolabs/tailscale` extension + subnet router) is
   designed to be control-plane-agnostic at the protocol level,
   so the future swap is a config change at install time, not
   an architectural rewrite.

3. **Hardware retention** — NEC8 hardware **stays**. The hypervisor
   software layer (currently Harvester KubeVirt nesting Talos VMs)
   is **not yet decided** — alternatives like ESXi + vCenter or
   another small-cluster hypervisor are on the table. Constraint:
   virtualization is **required** for manageability (snapshots,
   migration, console access, lifecycle). This sub-decision is
   carried forward as the only remaining open item — see "Remaining
   open follow-up" below.

4. **Talos image factory** — **conditional on (3).** If Harvester
   stays and the `util-linux-mountpoint` extension patch is still
   required, **self-hosted image factory continues**. If the
   hypervisor changes such that the extension is no longer needed,
   re-evaluate against the official factory. Until (3) is decided,
   the operating assumption is "self-hosted continues."

5. **Timing** — talos-i adoption + offsite move happens **after**
   the talos-ii-side architectural changes land and bake:
   - shared/0004 egress-gateway (sing-box transparent proxy via
     Cilium egress-gateway) implemented and stable on talos-ii
   - workload migrations from swarm-01 → talos-ii complete
     (home/media/ai/* — see workload disposition above)
   - VLAN-LB rewrite ADR landed
   - Backup/DR ADR landed
   No calendar date committed; gating is event-driven.

6. **Inbound exposure on talos-i** — **tailnet-only.** No
   Cloudflare Tunnel, no public dashboards. Observability UIs
   (Grafana / VictoriaMetrics / VictoriaLogs / uptime-kuma) are
   accessed via the tailnet from operator laptops. Removes the
   need for a `cloudflare-tunnel` workload on talos-i; the
   currently-running one becomes part of the decommission list.

7. **Storage** — **stays at current 3× 1TB NVMe** through Harvester-
   CSI. Hot observability data fits comfortably; backup landing
   zone sizing is the implicit concern but is deferred to the
   Backup/DR ADR. Storage upgrade is acknowledged as a future
   item, not part of this ADR.

## Remaining open follow-up

**Hypervisor software platform on talos-i** — keep Harvester
KubeVirt, switch to ESXi + vCenter, or evaluate a third option
(Proxmox, raw libvirt, Talos-on-Talos via KubeVirt 1.4+). The
hardware (NEC8) and posture (offsite observability + backup) are
both fixed; only the virtualization layer is undetermined. This
becomes its own ADR (`shared/0005-talos-i-hypervisor.md` or
`talos-i/0001-hypervisor.md` depending on scope at adoption time)
when:

- ESXi/vCenter licensing situation is researched (Broadcom
  changes since 2024 affect cost/availability)
- KubeVirt 1.4+ "VM as Pod" features are evaluated for whether
  they meet the manageability bar
- Confirmation whether the `util-linux-mountpoint` patch is
  still required under the chosen hypervisor

This single follow-up does **not** block accepting this ADR — the
strategic posture (offsite observability + backup, Tailscale-now
NetBird-later, residential, tailnet-only inbound) is locked.

## Decision

**talos-i becomes the offsite observability + backup-landing
cluster**, distinct from talos-ii (primary). Cross-LAN by default.
Mesh per shared/0002 Option C is the cluster fabric. Inbound
restricted to tailnet. Hardware stays; hypervisor TBD per
follow-up.

This ADR fixes the strategic posture so downstream ADRs
(shared/0004 egress-gateway, VLAN-LB rewrite, Backup/DR) can be
written against a stable premise.

## Implementation impact

- talos-i adoption into this repo: adds `docs/decisions/talos-i/`,
  `talos/clusters/talos-i/`, `kubernetes/clusters/talos-i/` per
  the index.md "new cluster" convention. Gated on the timing
  conditions in resolved sub-decision (5).
- Decommission `network/cloudflare-tunnel` on talos-i (per
  resolved sub-decision 6 — tailnet-only inbound).
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
