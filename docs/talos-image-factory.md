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

## Active schematic — `<TBD-record-after-first-build>`

**Status:** *initial — not yet built*
**Created:** *placeholder*
**Used by:** `ms01-a`, `ms01-b`, `ms01-c` (after rebuild)
**Talos version:** v1.12.6 (planned)
**Image factory URL pattern:** `https://factory.talos.dev/image/<schematic-id>/v1.12.6/metal-amd64.iso` (or `.raw.xz` / `.installer.tar.gz`)

### Schematic YAML

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
      - siderolabs/intel-ucode
```

### Why each extension

| extension | reason | drop-when |
|---|---|---|
| `siderolabs/iscsi-tools` | Longhorn replicas mount via iSCSI; without this, no PVCs work | never (as long as Longhorn is the CSI) |
| `siderolabs/util-linux-tools` | Longhorn `mountpoint` / standard util-linux helpers | never |
| `siderolabs/intel-ucode` | Intel CPU microcode updates | when CPU vendor changes |

### What is NOT in this schematic, and why

| candidate | rejected reason |
|---|---|
| `siderolabs/util-linux-mountpoint` (custom from `ghcr.io/beacon1096/...`) | Was a Harvester-CSI workaround; required only on talos-i. Bare-metal Longhorn doesn't trigger that code path. |
| `siderolabs/i915-ucode` / `siderolabs/xe-firmware` | Intel iGPU not yet enabled for any workload. See [Open questions in `index.md`](index.md#open-questions--known-unknowns). Decision still TBD between i915 (mature, Gen 12 ready) and xe (newer, currently rough on Gen 12). |
| `siderolabs/qemu-guest-agent` | Not a VM. |
| `siderolabs/nvidia-*` | No NVIDIA GPU on MS-01. |

### How to update (talos-ii)

1. Open ADR in `docs/decisions/talos-ii/` documenting the trigger
2. Submit new schematic to https://factory.talos.dev/ — yields new schematic ID
3. **Same commit** updates:
   - This file (move current schematic to "Historical talos-ii", create new active section)
   - The schematic ID pinned in `talos/clusters/talos-ii/talenv.yaml` (or equivalent)
   - Any node config patches that depend on the new extensions
4. Roll nodes one at a time using `task talos:upgrade-node IP=...`

## Historical schematics — talos-ii

*(none yet — populate as schematics are superseded)*

<!--
Template:

### `<schematic-id>`
**Status:** superseded by `<new-id>` on YYYY-MM-DD
**Used by:** ...
**Schematic YAML:**
```yaml
...
```
**Reason for retirement:** ...

-->

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
