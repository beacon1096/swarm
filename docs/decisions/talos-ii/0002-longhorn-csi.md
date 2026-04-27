# ADR talos-ii/0002 — Longhorn as the single in-cluster CSI

**Scope:** talos-ii only. talos-i also runs Longhorn inside Talos VMs but layers it on Harvester's underlying Longhorn — that's a separate question this ADR doesn't answer.
**Status:** accepted
**Date:** 2026-04-27

## Context

Bare-metal Talos on three MS-01 hosts, each with one 4 TB NVMe. Need a CSI that:

- Provides RWO PVCs across nodes (so Pods can move)
- Replicates data so a single host failure doesn't lose data
- Doesn't require additional hardware (no extra NICs for storage network, no RDMA)
- Is operable by one person at homelab scale

## Decision

Use **Longhorn** as the only CSI.

- One node = one disk = one Longhorn data partition (`/var/lib/longhorn`)
- Default `replicaCount: 2` (tolerates 1 node failure for typical workloads)
- Lifted to 3 for: forgejo, authentik, vaultwarden, matrix-synapse (the "really cannot lose" list)

Block device given to Longhorn directly — **no LVM / ZFS / btrfs at the host level**. Longhorn already replicates; another redundancy layer adds failure modes without adding redundancy.

## Alternatives considered

- **OpenEBS Mayastor** — better raw NVMe perf via NVMe-oF, but requires huge pages config and a dedicated control plane that's new ops surface. We don't have a perf problem worth that complexity.
- **Rook-Ceph** — more flexible (block / file / object), but 3 nodes is the minimum and the resource cost (CPU, RAM, OSD overhead) is meaningful on a homelab.
- **Local PV / TopoLVM** — no replication. Requires app-level redundancy or rigorous backup discipline, which we don't currently have.
- **Harvester CSI** — explicitly rejected per [ADR talos-ii/0001](0001-bare-metal-talos.md).

## How to add capacity later

Per the design in `docs/cluster-definition.md`:

1. Insert a second NVMe in any MS-01 (the M.2 slot is open)
2. Format and mount under `/var/lib/longhorn-disk2`
3. Add Longhorn disk annotation on the node
4. Longhorn auto-rebalances replicas — no Pod restart needed

This is why we don't use LVM: a second physical disk should not be hidden inside a single VG that fails as a unit.

## Consequences

Positive:
- Single source of truth for block storage
- Built-in UI, snapshots, backup-to-S3
- We've already debugged Longhorn behavior in talos-i / Harvester context

Negative:
- Longhorn engine processes consume CPU even when idle (acceptable on these CPUs)
- iSCSI dependency (handled by `siderolabs/iscsi-tools` extension — see `docs/talos-image-factory.md`)
- Cross-node replica sync uses cluster network. Plan for ~1 GiB Pod traffic per write doubling (replica=2 means each write travels once to a peer).
