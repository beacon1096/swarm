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

## Implementation (verified 2026-04-28)

What's actually deployed at `kubernetes/apps/storage/longhorn/`:

- **Chart:** `longhorn` v1.11.1 from the official upstream **HTTP** Helm repo
  (`https://charts.longhorn.io`). This is a documented exception to our
  OCIRepository-everywhere convention — Longhorn does not publish to OCI
  registries. See `helmrepository.yaml` in the same dir.
- **Namespace:** `storage` (not the upstream-default `longhorn-system`,
  to keep cluster-template's "namespace = parent dir name" convention).
- **Two StorageClasses:**
  - `longhorn` (cluster default, `replicaCount=2`) — for everything that's
    not in the critical list.
  - `longhorn-r3` (`replicaCount=3`) — used by the critical list above
    (forgejo / authentik / vaultwarden / matrix-synapse). Apps opt in by
    setting `storageClassName: longhorn-r3` on their PVC.
- **Data path:** `/var/lib/longhorn` (Talos partitions ~3.5 TB to this
  mount per disk layout in `docs/cluster-definition.md`).
- **`replicaSoftAntiAffinity: false`** — replicas must land on different
  nodes. With exactly 3 nodes a 2-replica volume must keep 1 healthy
  copy on a different host.
- **`v2DataEngine: false`** — stable v1 only. v2 (SPDK-based) needs its
  own kernel modules + a schematic update; not worth it yet.
- **Backups disabled** (`backupTarget: ""`). Tracked under "Open
  questions: Backup strategy" in `docs/index.md`. The chart still
  supports manual snapshots locally regardless.

UI exposure: internal only, `longhorn.${SECRET_DOMAIN}` via the
`envoy-internal` Gateway. **Never** expose on `envoy-external` —
the chart has no first-party auth and the UI can wipe volumes.

### Talos-specific gotcha: `csi.kubeletRootDir`

Longhorn auto-detects the kubelet's `--root-dir` flag by spawning a
privileged pod that reads `/proc/<kubelet>/cmdline`. Talos isolates
that path. Without an explicit override, the discovery pod fires
repeatedly and the driver-deployer crash-loops with:

> `failed to get arg root-dir … --kubelet-root-dir`

Fix: set `csi.kubeletRootDir: /var/lib/kubelet` in the chart values.
Documented in our HelmRelease + in
[operations/talos-ii-bootstrap-lessons.md](../../operations/talos-ii-bootstrap-lessons.md).
Apply the same flag if we ever bring up Longhorn on talos-i (also
Talos-based).
