# Talos image factory — schematic registry

**This file is the human-readable reverse map for our Talos schematic IDs.**
A schematic ID is a SHA256 hash; you cannot recover the extension list from it.
If this file is ever out of sync with the actual deployed image, **trust this file** and rebuild the schematic to match — never the other way around.

The repo manages multiple clusters with different factory strategies:

| cluster | factory | custom extensions allowed? |
|---|---|---|
| talos-ii | `factory.talos.dev` (sidero official) | **no** (per [ADR talos-ii/0004](decisions/talos-ii/0004-official-image-factory.md)) |
| talos-i | self-hosted image factory (Harvester CSI workaround) | **yes** (`util-linux-mountpoint` is required) |

---

# talos-ii

## Active schematic — `012427dcde4d2c4eff11f55adf2f20679292fcdffb76b5700dd022c813908b07`

**Status:** active (since 2026-05-05)
**Supersedes:** `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4` (initial; see Historical section below)
**Used by:** `ms01-a`, `ms01-b`, `ms01-c`
**Talos version:** v1.12.7
**Bootloader:** `sd-boot` (systemd-boot — required for Secure Boot)
**Secure Boot:** **enabled** — see [ADR talos-ii/0005](decisions/talos-ii/0005-secure-boot.md)
**Image factory URL pattern:** `https://factory.talos.dev/image/012427dcde4d2c4eff11f55adf2f20679292fcdffb76b5700dd022c813908b07/v1.12.7/metal-amd64.iso` (or `.raw.xz` / `.installer.tar.gz`)

### Schematic YAML

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
      - siderolabs/iscsi-tools
      - siderolabs/tailscale
      - siderolabs/util-linux-tools
# Note: secureboot=true + bootloader=sd-boot are set as factory parameters,
# not YAML fields. They are reflected in the schematic ID hash (changing
# them produces a different ID).
```

### Why each extension

| extension | reason | drop-when |
|---|---|---|
| `siderolabs/iscsi-tools` | Longhorn replicas mount via iSCSI; without this, no PVCs work | never (as long as Longhorn is the CSI) |
| `siderolabs/util-linux-tools` | Longhorn `mountpoint` / standard util-linux helpers | never |
| `siderolabs/intel-ucode` | Intel CPU microcode updates | when CPU vendor changes |
| `siderolabs/tailscale` | Subnet-router pattern per ADR `shared/0002` Option C — `tailscaled` runs on host net ns; nodes advertise PodCIDR + ServiceCIDR for cross-cluster mesh + tailnet-to-pod direct routing. Constitution §VII (v1.2.0) authorizes this as complementary to the in-cluster `tailscale-operator`. See [ADR talos-ii/0014](decisions/talos-ii/0014-tailscale-host-extension.md). | when mesh role is fulfilled by another mechanism (e.g. NetBird migration per shared/0002 follow-up) |

### What is NOT in this schematic, and why

Categorized for skim-reading. The full sidero catalog is at [github.com/siderolabs/extensions](https://github.com/siderolabs/extensions); below are extensions we've explicitly considered.

#### Custom / talos-i-specific

| candidate | rejected reason |
|---|---|
| `siderolabs/util-linux-mountpoint` (custom from `ghcr.io/beacon1096/...`) | Harvester-CSI workaround; required only on talos-i. Bare-metal Longhorn doesn't trigger that code path. |

#### Hardware not present on MS-01

| candidate | rejected reason |
|---|---|
| `siderolabs/amd-ucode` | Intel CPU |
| `siderolabs/amdgpu`, all `siderolabs/nonfree-kmod-nvidia-*`, `siderolabs/nvidia-*` | No AMD / NVIDIA GPU |
| `siderolabs/amazon-ena`, `siderolabs/ecr-credential-provider`, `siderolabs/soci-snapshotter` | AWS-specific, we run on-prem |
| `siderolabs/realtek-firmware`, `siderolabs/qlogic-firmware`, `siderolabs/bnx2-bnx2x`, `siderolabs/chelsio-*`, `siderolabs/mellanox-mstflint` | Not the NICs we have (MS-01 is Intel X710 + i226) |
| `siderolabs/intel-ice-firmware` | `ice` driver is for Intel E810/E823. MS-01 X710 uses `i40e`, kernel-builtin, no extension needed |
| `siderolabs/qemu-guest-agent`, `siderolabs/vmtoolsd-guest-agent`, `siderolabs/xen-guest-agent` | Bare metal, not a VM |
| `siderolabs/metal-agent` | Sidero Omni / Sidero Metal management — we don't use either |
| `siderolabs/revpi-firmware`, `siderolabs/panfrost`, `siderolabs/vc4`, `siderolabs/rockchip-rknn`, `siderolabs/gpio-pinctrl` | Not Pi / Rockchip / Apollo Lake hardware |
| All `dvb/*` | No TV tuner |

#### Forbidden by Constitution §II (no LVM/ZFS/btrfs/multi-CSI)

| candidate | rejected reason |
|---|---|
| `siderolabs/btrfs`, `siderolabs/zfs`, `siderolabs/mdadm`, `siderolabs/drbd` | Constitution §II — Longhorn is the only CSI, no host-level redundancy layers |
| `siderolabs/multipath-tools`, `siderolabs/px-fuse`, `siderolabs/trident-iscsi-tools` | Other CSI vendors (SAN multipath / Portworx / NetApp Trident) |

#### Overlap with our chosen in-cluster solutions

| candidate | rejected reason |
|---|---|
| `siderolabs/cloudflared` | Cloudflare Tunnel runs as in-cluster Deployment, not a host service |
| `siderolabs/bird2`, `siderolabs/nebula`, `siderolabs/netbird`, `siderolabs/newt`, `siderolabs/zerotier` | Alternative VPNs / overlay networks; we use Tailscale exclusively |

#### Alternative container runtimes (not currently needed)

| candidate | what it does | why not now |
|---|---|---|
| `siderolabs/gvisor` | User-space sandbox kernel (Sentry) intercepts syscalls — strong isolation against kernel exploits, ~30–50% syscall cost | Single-tenant homelab; we trust the workloads we run. Reconsider if `coder` workspaces are ever opened to outside users (running others' code = needs gVisor). |
| `siderolabs/kata-containers` | Per-pod micro-VM (QEMU + tiny kernel) for VM-grade isolation | Same reason as gVisor + higher overhead |
| `siderolabs/wasmedge`, `siderolabs/spin` | WebAssembly runtimes: pods run `.wasm` modules instead of Linux ELF; ~1ms cold start, MB-sized images | No wasm-targeted workload; our apps are conventional Linux web services |
| `siderolabs/crun`, `siderolabs/youki` | Drop-in `runc` replacements (C / Rust); marginally faster start, smaller RAM | Default `runc` performance is not a bottleneck for us |
| `siderolabs/stargz-snapshotter` | Lazy-load container image layers (start before full pull) | Spegel + Longhorn handle our pull latency well enough |

#### Peripherals / accelerators not on this hardware

| candidate | rejected reason |
|---|---|
| `siderolabs/joydev`, `siderolabs/uhid`, `siderolabs/uinput`, `siderolabs/usb-audio-drivers`, `siderolabs/usb-modem-drivers`, `siderolabs/v4l-uvc-drivers` | No game streaming / USB peripherals attached |
| `siderolabs/thunderbolt` | No Thunderbolt-attached storage / NICs |
| `siderolabs/hailort`, `siderolabs/gasket-driver`, `siderolabs/tenstorrent`, `siderolabs/xdma-driver` | No AI accelerator cards (Hailo / Coral TPU / Tenstorrent / Xilinx FPGA) |

#### Possibly useful in the future — not added until concrete trigger

| candidate | what it gives us | trigger to add |
|---|---|---|
| `siderolabs/i915` | Intel GPU drivers + microcode (mature path for Iris Xe Gen 12) | Enable iGPU for `immich` face recognition, transcoding, etc. — see [Open questions in `index.md`](index.md#open-questions--known-unknowns) |
| `siderolabs/xe` | Newer Intel GPU driver (designed for Arc / Battlemage) | Only if `i915` proves inadequate on Gen 12 — not the default choice |
| `siderolabs/mei` | Intel Management Engine host driver | Required for Intel Arc discrete GPUs (we have none); **not** required for vPro KVM (which works at BIOS layer without OS cooperation) |
| `siderolabs/intel-npu` | Intel NPU firmware + driver | If we add a workload that uses 13/14-gen Core's NPU |
| `siderolabs/binfmt-misc` | `binfmt_misc.ko` kernel module to register cross-arch ELF interpreters (required by `tonistiigi/binfmt` + `buildx --platform` + Nix `--option system`) | **talos-ii does not need this — `forgejo-runner` runs on talos-i.** When talos-i adopts arm64 / loongarch64 builds, add to talos-i's schematic, not here. See [Open questions in `index.md`](index.md#open-questions--known-unknowns). |
| `siderolabs/nfs-utils`, `siderolabs/nfsd`, `siderolabs/nfsrahead` | NFSv3 client / server / readahead | If we add a backup target / storage that requires NFS host-level support |
| `siderolabs/nvme-cli` | NVMe SMART / namespace tools | NVMe disk health debugging — currently `talosctl get disks` covers the basics |
| `siderolabs/lldpd` | LLDP daemon for switch-side topology discovery | If we run into switching issues that need link-level visibility |
| `siderolabs/fuse3` | FUSE filesystem support | If a Pod needs a FUSE filesystem (s3fs, sshfs, etc.) |
| `siderolabs/glibc` | glibc on host | If another extension or workload host-binary needs glibc |
| `siderolabs/ctr` | `ctr` containerd CLI | `talosctl` covers most container-debug needs; add if specifically wanted |
| `siderolabs/nut-client` | Network UPS Tools client | When we attach a UPS |

### How to update (talos-ii)

1. Open ADR in `docs/decisions/talos-ii/` documenting the trigger
2. Submit new schematic to https://factory.talos.dev/ — yields new schematic ID
3. **Same commit** updates:
   - This file (move current schematic to "Historical talos-ii", create new active section)
   - The schematic ID pinned in `talos/clusters/talos-ii/talenv.yaml` (or equivalent)
   - Any node config patches that depend on the new extensions
4. Roll nodes one at a time using `task talos:upgrade-node IP=...`

### Tailscale: host extension AND in-cluster operator (complementary)

Both ways to integrate Tailscale are deployed on talos-ii, in **complementary** roles per ADR `shared/0002` Option C (accepted 2026-05-04) and Constitution §VII v1.2.0 (ratified 2026-05-05). Earlier framing of these as competing was wrong; the matrix below contrasts their distinct concerns:

| | `siderolabs/tailscale` (host extension) | `tailscale-operator` (in-cluster Helm chart) |
|---|---|---|
| Who joins the tailnet | The Talos node itself (one device per node — `talos-ii-ms01-{a,b,c}` with `tag:talos-ii-node`) | Each Service / Ingress wrapped by the operator (one device per exposed service, e.g. `attic.tail5d550.ts.net`) |
| Role | **Subnet router**: advertises cluster PodCIDR (`10.44/16`) + ServiceCIDR (`10.55/16`) to tailnet. Plus node-level egress to tailnet hosts. | **Per-Service ingress**: terminates tailnet inbound at a specific cluster Service (with per-Service ACLs). |
| Granularity of ACLs | Whole node (subnet routes admin-approved by tag via `autoApprovers`) | Per-Service (each wrapped Service is a distinct tailnet device) |
| Auth model | OAuth client + tag (`tag:talos-ii-node`); zero long-lived auth-key rotation | Operator-managed auth keys per wrapped Service |
| Failure mode | Node reboot drops one router; HA via Tailscale primary-with-failover across the 3 routers | Operator pod restart only affects that one Service's proxy |
| Best fit | Cross-cluster mesh (talos-ii ↔ talos-i once adopted), tailnet→pod-CIDR direct routing, host-net consumers needing tailnet outbound | Selective service exposure with per-Service identity / ACL |

**Adopted on talos-ii since 2026-05-05** (spec 004). HA = 3 nodes all advertise routes (Tailscale picks primary; failover automatic). See ADR [`talos-ii/0014`](decisions/talos-ii/0014-tailscale-host-extension.md) for talos-ii-specific decisions, and [`shared/0002`](decisions/shared/0002-mesh-integration-modes.md) for the canonical two-tier mesh-mode decision.

## Historical schematics — talos-ii

### `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`

**Status:** superseded by `012427dcde4d2c4eff11f55adf2f20679292fcdffb76b5700dd022c813908b07` on 2026-05-05
**Used by:** `ms01-a`, `ms01-b`, `ms01-c` (initial bootstrap 2026-04-27 → 2026-05-05)
**Talos version:** v1.12.7
**Bootloader:** `sd-boot` / Secure Boot enabled

**Schematic YAML:**
```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

**Reason for retirement:** added `siderolabs/tailscale` to support Subnet-router pattern per ADR `shared/0002` Option C / `talos-ii/0014`. New schematic ID is the SHA256 of the 4-extension list (Secure Boot key bundle preserved — same factory `secureboot=true` parameter).

---

# talos-i

> **This section is a placeholder.** talos-i lives in the legacy `swarm-01` repo today. When it's adopted into this repo, fill in the active schematic from `swarm-01/talos-i/talenv.yaml` and document the self-hosted factory build pipeline.

## Active schematic — `<adopt-from-swarm-01>`

**Status:** *not yet adopted into this repo*
**Used by:** `virt-01`, `virt-02`, `virt-03` (Talos VMs on Harvester / NEC8)
**Talos version:** v1.12.6 (current at time of writing)
**Image factory URL:** `<self-hosted-factory>/image/<schematic-id>/v1.12.6/...`
**Self-hosted factory:** `kubernetes/<TBD>/registry/talos-image-factory/` (planned location after adoption)

### Expected schematic YAML (carry over from swarm-01)

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
      - siderolabs/intel-ucode
      - siderolabs/qemu-guest-agent
      # (verify against swarm-01 talenv.yaml + image-factory build manifest)
    # Custom extensions built by self-hosted factory:
    customExtensions:
      - util-linux-mountpoint  # ghcr.io/beacon1096/util-linux-mountpoint:<ver>-talos<ver>
```

### Why each extension (talos-i specifics)

| extension | reason | drop-when |
|---|---|---|
| `siderolabs/iscsi-tools` | same as talos-ii — Longhorn | never |
| `siderolabs/util-linux-tools` | same as talos-ii | never |
| `siderolabs/intel-ucode` | same as talos-ii | when CPU changes |
| `siderolabs/qemu-guest-agent` | required for KubeVirt VM management (graceful shutdown, mem ballooning) | when talos-i moves off Harvester |
| `util-linux-mountpoint` (custom) | Harvester CSI's `NodeUnstageVolume` runs `nsenter ... mountpoint ...`. Talos's stock image doesn't ship `mountpoint`. Without this, all PVC unmount fails. | when Harvester CSI is no longer used (ADR for talos-i CSI migration) |

### How to update (talos-i)

1. Open ADR in `docs/decisions/talos-i/` documenting the trigger
2. If updating the custom `util-linux-mountpoint` extension: rebuild via the self-hosted factory pipeline (CI workflow / Forgejo Action / manual `docker buildx`)
3. If updating sidero official extensions only: submit a new schematic via the self-hosted factory pointing at `factory.talos.dev` upstream
4. **Same commit** updates:
   - This file (talos-i section)
   - `talos/clusters/talos-i/talenv.yaml` schematic ID
   - The custom extension Dockerfile / build manifest (if changed)
5. Roll nodes one at a time

## Historical schematics — talos-i

*(populate after adoption from swarm-01)*

---

## Quick reference: when do I need to touch this file?

- Adding any `systemExtension` (either cluster) → yes
- Changing Talos version (e.g. v1.12.6 → v1.13.x) → yes (image is regenerated)
- Changing kernel parameters via image factory → yes
- Rebuilding a custom extension (talos-i only) → yes if the version changes
- Changing `nodes.yaml` IP / hostname only → no
- Changing flux apps / k8s resources → no
- Tuning Longhorn / Cilium settings → no
