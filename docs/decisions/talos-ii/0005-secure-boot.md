# ADR talos-ii/0005 — Enable UEFI Secure Boot with sd-boot

**Scope:** talos-ii only. talos-i (Harvester KubeVirt VMs) historically requires Secure Boot **disabled** for KubeVirt to upgrade Talos cleanly — that constraint is documented in `swarm-01/talos-ii/README.md` and predates this repo.
**Status:** accepted
**Date:** 2026-04-27

## Context

Choices when generating the talos-ii image at `factory.talos.dev`:

- **Bootloader:** `grub` (legacy, BIOS + UEFI) **or** `sd-boot` (systemd-boot, UEFI-only, required for Secure Boot)
- **Secure Boot:** off **or** on (only with `sd-boot`)

These choices are baked into the schematic ID (hash). Changing either one later requires a full reinstall of every node — there is no in-place migration path.

MS-01 hardware:

- UEFI firmware with Secure Boot capability
- Intel firmware TPM (fTPM) — provides TPM 2.0 to the OS
- vPro / AMT — works at firmware level, independent of OS Secure Boot state

Threats this protects against:

- Persistent rootkit at the boot chain (replaces kernel or initramfs and signs nothing)
- Tampering with on-disk Talos artifacts between reboots (someone gains physical access to NVMe)
- "Evil maid" against an unattended host

Threats this does **not** address:

- Compromise *after* the kernel is running (use Talos's API security model, RBAC, NetworkPolicy)
- TPM-state-replay attacks (mitigated separately by sealing PCRs)
- Supply-chain compromise of the Talos image itself (sidero signs the image; if their signing key is compromised, this defense fails)

## Decision

**Enable Secure Boot on talos-ii from the very first install.**

Concrete configuration:

- `bootloader: sd-boot`
- Secure Boot: enabled
- Talos version: v1.12.7
- Resulting schematic ID: `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`

This is set in the schematic at `factory.talos.dev` and pinned in [docs/talos-image-factory.md → talos-ii](../../talos-image-factory.md#talos-ii).

## Why now and not later

Switching `secureboot=false` → `secureboot=true` later requires reinstalling every node from a new schematic ID. Doing it on day one costs nothing extra (we're installing from scratch anyway). Doing it later means a planned-maintenance reinstall.

## BIOS prerequisites (one-time, per host)

For Secure Boot to work with Talos's signed sd-boot, the UEFI firmware must trust the keys Talos uses. Two paths:

1. **Setup Mode (recommended for first install):** wipe the platform's existing Secure Boot keys (PK / KEK / db / dbx). The UEFI is then in "Setup Mode" and accepts the keys that Talos's installer enrolls automatically on first boot. This is the cleanest path for a homelab where we don't need to also boot Windows or other OSes from the same firmware.
2. **Custom Mode (manual key enrollment):** keep the Microsoft keys present (so dual-boot to Windows installer media still works) and import Talos's PK / KEK / db keys via the BIOS UI. More steps, more failure modes, no benefit for our use case.

We use **Setup Mode**. After Talos installs and enrolls its keys, Secure Boot enforces.

### MS-01 (AMI BIOS) actual procedure — verified 2026-04-28

The MS-01's AMI BIOS does **not** behave like a textbook "Setup Mode". Specifically: if you clear the keys and reboot back into the BIOS, the Setup-Mode state does not persist correctly, and Talos's auto-enroll path does not fire on the next boot. The procedure that actually works:

1. **Security → Secure Boot → Secure Boot = Disabled**, F10 save → reboot. (AMI requires Secure Boot OFF before it lets you delete keys.)
2. Re-enter BIOS → **Security → Secure Boot → Key Management** → execute the key-deletion action (label varies: `Reset to Setup Mode` / `Erase All Secure Boot Settings` / `Delete all Secure Boot variables`).
3. **Do NOT reboot here.** Instead, F10 save and from the BIOS boot menu (F11 / similar), boot directly into the Talos installer ISO on USB while still on the same firmware session. **This is the load-bearing step** — rebooting between clearing keys and booting Talos resets the Setup-Mode flag and Talos's enroll never runs.
4. The Talos installer ISO presents an "Install Keys" option (sd-boot's enroll-keys path). Select it. The system auto-reboots after enrollment.
5. Re-enter BIOS → **Secure Boot = Enabled** (Custom mode if AMI offers Standard/Custom — Custom is what trusts our newly-enrolled PK/KEK/db). F10 save → reboot.
6. Subsequent boots: Secure Boot enforces against Talos's enrolled keys, sd-boot loads, Talos installer runs the OS install.

**Why this matters:** if you reboot at step 3 instead of going straight into the Talos ISO, you'll spend 30+ minutes confused about why Talos installer logs `failed to enroll secureboot keys` and then the install fails or boots into a no-keys-enrolled state. (We did exactly this on the first three install attempts of ms01-a.)

## TPM 2.0 prerequisites

- BIOS → Security → ensure **fTPM is enabled** (Intel PTT on MS-01 BIOS).
- Talos sd-boot can seal disk-encryption keys to TPM PCR values. We use this for the STATE partition (LUKS-encrypted, key bound to specific firmware + boot chain measurements). Tampering with the boot chain breaks decryption.

This is *not* the same as user-data PVC encryption (Longhorn handles that separately if desired).

## Operational consequences

### Image reuse across nodes

The same schematic ID + same Talos version produces the same boot artifact. All three MS-01 hosts use the same `metal-amd64.iso`. Per-node config (IPs, hostname) is applied via Talos `MachineConfig`, not via different images.

### Recovery from a corrupted node

If a node's STATE partition gets stuck (TPM PCR mismatch, e.g. firmware update changed UEFI keys), normal recovery path:

1. Boot from rescue media (the Talos ISO of the same schematic ID)
2. Wipe the node's STATE partition
3. Reapply `MachineConfig` via `talosctl apply-config`
4. Talos resilvers from etcd / cluster state

For this reason: keep the Talos ISO (`metal-amd64.iso` for the active schematic ID) on a USB stick stored physically near the cluster. Don't rely on factory.talos.dev being reachable during recovery.

### Talos upgrades

`task talos:upgrade-node IP=...` flow continues to work, but the *new* image must use:

- The **same schematic ID** (no extension changes), or a new schematic ID recorded via the [`docs/talos-image-factory.md` update process](../../talos-image-factory.md#how-to-update-talos-ii)
- A Talos version that hasn't rotated Secure Boot signing keys (sidero rotates rarely; major version bumps may require BIOS to re-trust the new keys)

### vPro KVM independence

vPro AMT KVM-over-IP is a firmware-level feature. It works regardless of Secure Boot state. Remote rescue is unaffected.

## Alternatives considered

- **Secure Boot off + grub** — what swarm-01 / talos-i historically used (KubeVirt limitation). Less surface area, but loses defense against boot-chain tampering. We don't have the KubeVirt limitation on talos-ii.
- **Secure Boot off + sd-boot** — possible but pointless (sd-boot's main draw on Talos is its Secure Boot integration; without Secure Boot, grub is the more battle-tested path).
- **Secure Boot on + custom enrolled MS keys + Talos signing** — overkill for a homelab without a dual-boot story.

## Consequences

Positive:

- Tampering with on-disk kernel / initramfs / sd-boot is detected at boot
- TPM-bound STATE partition encryption (anti-physical-theft)
- One-time BIOS setup per host, no ongoing cost
- vPro / AMT continues to work for remote rescue

Negative:

- Initial install requires a BIOS Setup-Mode toggle on each host (~3 minutes per host)
- Recovery requires a USB stick with the same schematic ID's image (mitigation: keep one)
- Schematic ID is now sensitive to Secure Boot state; flipping it later is a full reinstall

## Verification (after first install)

```bash
# Verify Secure Boot enforced and TPM bound
talosctl --talosconfig=... -n <node-ip> get securitystates
talosctl --talosconfig=... -n <node-ip> get diskconfig

# Expected: secureboot=true, state partition encrypted with TPM2 binding
```
