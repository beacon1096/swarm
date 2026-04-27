# ADR talos-ii/0001 — Ditch Harvester / KubeVirt, go bare-metal Talos on MS-01

**Scope:** talos-ii only. talos-i (NEC8) keeps Harvester for hardware reasons — see [Constitution §I](../../../.specify/memory/constitution.md#i-hypervisor-stance).
**Status:** accepted
**Date:** 2026-04-27
**Supersedes:** *(initial)*

## Context

Previous talos-ii architecture: Talos VMs on top of Harvester (KubeVirt) on three MS-01 hosts. The Harvester layer was supposed to give us a virtual BMC equivalent — Harvester's UI / kubectl could rescue a stuck Talos VM.

In April 2026 we hit a cascading set of failures:

1. **OVN raft death-loop** — All three `ovn-central` pods stuck in a startup race; NB / SB databases on ms01-a and ms01-c got wiped, only ms01-b retained data. Cluster ran on cached OVS flows on the surviving nodes.
2. **ms01-c reboot loop** — `kube-ovn-cni` couldn't ever pass `wait ovn0 gw ready` because OVS in-memory flows had been cleared by an earlier host reboot, and the SB DB to repopulate them was offline. `harvester-node-manager` interpreted NetworkUnavailable=True as "node unhealthy" and triggered ~15 reboots in 8 days, each making the cache state worse.
3. **Harvester CSI hot-plug bugs** — `ControllerPublishVolume` and `ControllerUnpublishVolume` are not idempotent: KubeVirt returning "volume already exists" / "volume does not exist" became `Internal` errors that the external-attacher kept retrying forever. Saw the same bugs in talos-i, suggesting it's architectural rather than environment-specific.
4. **A 5-second status-settle timeout** in Harvester CSI is too tight when Longhorn is busy.

We patched #1 by lifting Apr 16 NB/SB DBs off ms01-b, converting cluster→standalone, and running ovn-central single-replica. That is the "single point of truth" mode — ms01-b reboot = total OVN data loss.

## Decision

Take the OVN failure as the trigger to move talos-ii to bare-metal Talos on the MS-01 hosts. Stop nesting.

The justification is *not* "OVN is bad" — it's that **MS-01 doesn't need the virtual BMC story** (vPro + iGPU give equivalent remote rescue), and once you remove that motivation, the entire Harvester / KubeVirt / OVN / Harvester-CSI stack is pure overhead.

NEC8 (which hosts talos-i) keeps Harvester because its CC150 / M720q hardware lacks vPro and iGPU; without those, "boot a USB" requires being physically present, so the virtual BMC value remains.

## Alternatives considered

- **Recover OVN raft to 3-node HA in place** — ~2 weeks of careful work (cluster→standalone is reversible only one direction; full re-bootstrap risks losing the Apr 16 state we just rescued). Doesn't address #3 / #4 at all.
- **Stay on KubeVirt but uninstall Harvester CSI, use Longhorn inside Talos VMs** — fixes #3 / #4. Doesn't fix #1 (OVN). Doesn't avoid the KubeVirt nesting tax.
- **Stay on Harvester, drop OVN, use VLAN bridge for VMs** — fixes #1 only. Still pays for nesting.

Each partial fix is more work than starting over once the data is exported.

## Consequences

Positive:
- Closes #1 / #2 / #3 / #4 in one move
- Removes about half the operational complexity (kube-ovn, Harvester CSI driver, KubeVirt VM definitions, Harvester management cluster, image-factory custom build for `util-linux-mountpoint` workaround)
- Direct NVMe / 10 GbE — better latency, simpler perf reasoning
- vPro + iGPU now usable directly (iGPU work is a follow-up, see open questions)

Negative:
- Lose Harvester's UI for VM browsing / web console (compensated by vPro AMT KVM-over-IP)
- Talos = no SSH; debugging via `talosctl` only. We've seen this is sometimes painful (today's OVN incident needed SSH into Harvester host, which won't be possible on Talos hosts directly — though Talos's `talosctl` covers the equivalent inspections)
- Lose the option to run **other** VMs (e.g., the Windows `w11-kso` VM that lives in Harvester `hosts/` namespace). To be migrated to NEC8 Harvester or HPE EC200a, separately.
- ms01-b's existing OVN DB tarball (`.private/ovn-backup-20260426-0703/`) becomes archive-only — the new cluster doesn't need it.

## How to revert

Reinstall Harvester on the three MS-01 hosts. ~1 hour per host, plus VM definitions need to be reapplied. Practical only as an emergency revert in the first week or two.
