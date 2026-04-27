# ADR talos-ii/0006 — Disable PCIe ASPM in MS-01 BIOS (both PCH and SA groups)

**Scope:** talos-ii only. (talos-i is on NEC8 / M720q with different BIOS layout — not load-bearing here.)
**Status:** accepted
**Date:** 2026-04-28

## Context

During the bootstrap of ms01-a we hit two distinct symptoms whose root cause turned out to be the same:

1. **Talos install repeatedly fails with `volume STATE phase failed / no such attributes system_disk`.** The 4 TB Kioxia NVMe (`/dev/nvme0n1`) intermittently disappears from `talosctl get disks` mid-install. We initially blamed thermal (the CPU fan plug had also worked loose, separate issue), but it persisted with the fan secured.
2. **Single-node etcd is healthy on `etcd status` but gives 13–14 second `apply request took too long` warnings on every range query**, and `talosctl etcd members` times out. Single-node raft consensus is just self-fsync — the only thing that explains 14 s consensus is fsync to NVMe stalling.

Both symptoms are PCIe link-state-recovery delays from aggressive ASPM (Active State Power Management): the NVMe controller drops into L1.x sub-states under low load, then takes hundreds of ms to seconds to wake (and sometimes fails to wake at all under load spikes from Talos install / etcd fsync).

## The MS-01 BIOS PCIe grouping (load-bearing, easy to miss)

The MS-01's AMI BIOS splits PCIe into **two independent groups** for ASPM/power-saving controls:

| group | what's behind it | ASPM control location in BIOS |
|---|---|---|
| **SA-PCIE** (System Agent — CPU root complex) | PCIe 4.0 x4 SSD slot (the 4 TB Kioxia NVMe), Intel X710 dual-SFP+ NIC, the user-accessible PCIe slot | `Advanced → SA Configuration` (or similar) |
| **PCH-PCIE** (Platform Controller Hub) | I226-V 2.5 G NIC, PCIe 3.0 x4 SSD slot, PCIe 3.0 x2 SSD slot, I226-LM 2.5 G NIC, WiFi card | `Advanced → PCH Configuration` (or similar) |

**Both groups have ASPM toggles, and both must be set to `Disabled` independently.** Only changing one group is the easy mistake we made (ms01-a / ms01-c had only PCH-PCIE disabled while their NVMe sits behind SA-PCIE — install kept failing). Caught when comparing ms01-b's BIOS against the others on 2026-04-28.

## Decision

On every MS-01 host in talos-ii, in BIOS:

- **SA-PCIE → ASPM = `Disabled`**
- **PCH-PCIE → ASPM = `Disabled`**
- All `L1 Substates` / `L1.1` / `L1.2` toggles in either group → `Disabled`

These are one-time per-host BIOS settings; they survive firmware updates as long as the user doesn't reset to defaults.

### What we tried for belt-and-suspenders, and why it doesn't work

We attempted to set `pcie_aspm=off` as a kernel cmdline arg via Talos's
`machine.install.extraKernelArgs`. talhelper rejected the config:

> `install.extraKernelArgs and install.grubUseUKICmdline can't be used together`

Reason: we use Secure Boot + sd-boot + a UKI (Unified Kernel Image; see ADR
talos-ii/0005). The kernel cmdline is **baked into the signed UKI** at the
factory.talos.dev schematic build time. Adding kernel args at apply-time
would require modifying the boot chain after signature, which Secure Boot
forbids by design.

**The only way to get `pcie_aspm=off` baked in** is to build a new schematic
at factory.talos.dev with `customization.extraKernelArgs: [pcie_aspm=off]`,
get a new schematic ID, and reinstall every node onto the new image. That
is a deliberate migration (schematic ID change is one-way; see ADR 0005)
and not worth doing just for this.

**Therefore: BIOS is the only enforcement point.** If the BIOS gets reset
(CMOS battery, firmware update that resets to defaults), ASPM will come
back and the cluster will degrade. Mitigation:

1. Document the SA-PCIE + PCH-PCIE settings in the per-host runbook
   (`docs/operations/` — TBD)
2. Periodic check (manual): `talosctl etcd status` should consistently
   return in well under a second on a healthy cluster. If it ever climbs
   to multi-second, ASPM is the first thing to check.
3. If we ever rebuild the schematic for any other reason (e.g. iGPU
   support), bundle `pcie_aspm=off` into the new schematic at the same
   time.

### Why we didn't see this on talos-ii's previous Harvester install

Harvester was on Talos's older 1.7.x kernel with conservative ASPM defaults. Talos 1.12.7's kernel honours BIOS ASPM more aggressively, so the same hardware that worked under Harvester now fails the install on bare-metal Talos. (Confirmed by reading the Sidero changelog around 1.10 → 1.12 power-management commits.)

## Operational consequences

Positive:
- Stable NVMe under install / etcd fsync / heavy I/O
- Stable X710 LACP — ASPM-induced link blips on the SFP+ ports were also a candidate cause for some of the LACP renegotiation we observed (not isolated; but not contradicted either)
- One-time per-host fix, then permanent

Negative:
- ~2–4 W extra idle draw per host (NVMe, NIC stay in L0 instead of L1.x). Acceptable for a homelab.
- Future BIOS resets (e.g. CMOS battery dies) require redoing both groups. Logged in `docs/operations/` runbooks (TBD) and partly mitigated by `pcie_aspm=off` kernel arg.

## Verification

Symptomatic check (most reliable):

```bash
# Should return in well under 1s on a healthy single-node etcd; multi-second
# = NVMe fsync stalls = ASPM (or thermal, or hardware fault).
talosctl --talosconfig=... -n <ip> -e <ip> etcd status
```

State check (read PCIe link state via /sys):

```bash
# l1_aspm == 0 means L1 ASPM disabled on this PCIe device. If it's 1 and we
# see slowness, BIOS settings haven't taken effect.
talosctl --talosconfig=... -n <ip> read /sys/bus/pci/devices/<nvme-bdf>/link/l1_aspm

# Find the BDF first:
talosctl --talosconfig=... -n <ip> read /sys/bus/pci/devices/ | grep -i nvme
```

## Related

- ADR talos-ii/0001 (bare-metal Talos): the move from Harvester to bare-metal exposed this hardware quirk
- ADR talos-ii/0005 (secure boot): the AMI BIOS Setup-Mode procedure has its own MS-01-specific gotcha; this ADR is the second BIOS-quirk we hit on the same hosts
- The talos-i hosts (NEC8 / M720q) have a different BIOS layout; this decision is talos-ii-specific
