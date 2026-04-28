# swarm — documentation index

This repo manages **multiple Talos clusters**:

| cluster | role | status in this repo |
|---|---|---|
| **talos-ii** | bare-metal MS-01, primary workloads | **active build (2026-04-27)** |
| **talos-i** | Harvester KubeVirt on NEC8, observability + shared services | not yet adopted (lives in `swarm-01`) |

## Cluster definitions

- [Cluster definitions](cluster-definition.md) — current truth: nodes, network, storage, what runs where (sectioned per cluster)
- [Talos image factory](talos-image-factory.md) — **schematic ID ↔ extension reverse map** (sectioned per cluster — must update in same commit as any image change)

## Decisions (ADR-style, append-only, organized per cluster)

ADRs are organized by their scope:

- [`decisions/shared/`](decisions/shared/) — applies to both clusters (e.g. SDD process)
- [`decisions/talos-ii/`](decisions/talos-ii/) — talos-ii-specific
- [`decisions/talos-i/`](decisions/talos-i/) — talos-i-specific (populated after adoption)

### Currently in this repo

#### Shared

- [shared/0001 — Spec-Driven Development with spec-kit](decisions/shared/0001-spec-driven-development.md)

#### talos-ii

- [talos-ii/0001 — Bare-metal Talos on MS-01 (no Harvester / KubeVirt nesting)](decisions/talos-ii/0001-bare-metal-talos.md)
- [talos-ii/0002 — Longhorn as the single CSI](decisions/talos-ii/0002-longhorn-csi.md)
- [talos-ii/0003 — Direct VLAN 87 on UDM-Pro, no OVN](decisions/talos-ii/0003-vlan-87-direct-attach.md)
- [talos-ii/0004 — Official Talos image factory only, no custom extensions](decisions/talos-ii/0004-official-image-factory.md)
- [talos-ii/0005 — Enable UEFI Secure Boot with sd-boot](decisions/talos-ii/0005-secure-boot.md)
- [talos-ii/0006 — Disable PCIe ASPM in MS-01 BIOS (both PCH and SA groups)](decisions/talos-ii/0006-disable-pcie-aspm.md)
- [talos-ii/0007 — CloudNativePG as the postgres operator](decisions/talos-ii/0007-cloudnative-pg-operator.md)

#### talos-i

*(populated after talos-i is adopted — initial entries will likely cover: keep Harvester KubeVirt on NEC8, retain custom `util-linux-mountpoint` extension, retain self-hosted image factory.)*

## Operations

- [talos-ii bootstrap — lessons from the trenches](operations/talos-ii-bootstrap-lessons.md) — every gotcha we hit on day 1, organized by category (BIOS, networking, China-network, Talos quirks). Read this before any reinstall.
- [zot — multi-registry pull-through cache](operations/zot-mirror.md) — what the LAN registry on `172.16.80.240:5000` does, how nodes are configured to use it, performance characteristics, how to add an upstream.
- [sing-box — cluster egress proxy](operations/sing-box-egress.md) — the in-cluster `HTTPS_PROXY` endpoint, the on-host BIRD/OSPF instance it replaces, who uses it, NO_PROXY conventions.
- [Tailscale operator — exposing services on the tailnet](operations/tailscale-operator.md) — annotation-driven exposure, the two GFW workarounds (postRenderer + ProxyClass), why the chart is on local zot.
- (to be added: node replacement, data restore from `.private/talos-ii-export-20260426/`, Longhorn disk replacement, Talos upgrade)

## Open questions / known unknowns

- **Intel iGPU usage on talos-ii** — MS-01 has Iris Xe (Gen 12 IP). Want to enable for `immich` face recognition, transcoding, etc. Requires:
  - Decide between `i915` (mature, established for Gen 12) and `xe` (newer, designed for Arc / Battlemage; still rough on Gen 12)
  - Identify the right Talos system extension(s) — possibly firmware blobs (`guc`/`huc` for hardware accel) and userspace (`intel-vaapi-drivers` in pod images)
  - Currently **not** in the schematic; flip on later via constitution-conformant ADR + schematic update + this doc.
- **Cross-arch CI (arm64 / loongarch64) via Forgejo Runner on talos-i** — for Nix package builds and Docker `buildx --platform` multi-arch builds. The mechanism is `binfmt_misc` kernel module + `tonistiigi/binfmt` (or hand-written) registration of QEMU user-mode interpreters per architecture. Caveats:
  - This belongs to **talos-i** (where `forgejo-runner` runs), not talos-ii. The talos-ii forgejo *server* doesn't build anything.
  - Add `siderolabs/binfmt-misc` to talos-i's schematic when this is enabled
  - loongarch64 needs QEMU 7.0+ and `tonistiigi/binfmt` may not include the loongarch64 interpreter by default — may need a custom binfmt registration
  - For Nix, also need `boot.binfmt.emulatedSystems` analogue + `nix.settings.extra-platforms` so the Nix daemon accepts cross-arch derivations
- **High-bandwidth public exposure** — for any service hitting Cloudflare's body-size or fair-use limits (large media uploads), use the NixOS VPS + Tailscale + Caddy path described in [Constitution §VI](../.specify/memory/constitution.md#vi-public-exposure-both). The list of services on this path will grow over time; track in per-spec docs.
- **Backup strategy** beyond the one-shot 2026-04-27 local export
- **Multi-cluster mesh** between talos-i and talos-ii — not needed yet, but PodCIDRs are non-overlapping by design (10.42 vs 10.44)

## Conventions

- ADRs are numbered sequentially **per directory** (so `talos-ii/0001`, `talos-i/0001`, `shared/0001` can coexist). Never renumber. Status: `accepted` / `superseded by NNNN` / `rejected`.
- When `docs/talos-image-factory.md` changes, the **same commit** must update the schematic ID in `talos/clusters/<cluster>/talenv.yaml`. If splitting commits is unavoidable, the chain must merge atomically.
- This index file is the authoritative TOC. New docs land here in the same commit they're added.
- A new cluster joining the repo gets its own subdirectories under `decisions/`, `talos/clusters/`, and `kubernetes/clusters/`. The constitution stays single-file but is tagged per principle.
