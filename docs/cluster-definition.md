# Cluster definitions — swarm

This repository will manage **two** Talos clusters. This document is the authoritative description of what each cluster **is**. When the cluster diverges from this, either the cluster or this file is wrong; reconcile in the same PR.

> **Repo state today:** `talos-ii` is being newly built (bare metal MS-01) and is the only cluster in this repo. `talos-i` (Harvester / NEC8) lives in the legacy `swarm-01` repo today; the section below is a placeholder describing where it'll land when it's brought in.

| cluster | hardware | hypervisor | repo path |
|---|---|---|---|
| `talos-ii` | 3× MS-01 | bare metal | `talos/clusters/talos-ii/` (planned) |
| `talos-i` | 3× NEC8 / M720q | Harvester KubeVirt | `talos/clusters/talos-i/` (planned, currently in `swarm-01` repo) |

---

# talos-ii — primary, bare metal

**Status:** under bootstrap (2026-04-27).

## Identity

- **Cluster name:** `talos-ii`
- **Purpose:** primary production workload cluster — identity, collaboration, dev tooling, AI assistants, media library
- **Operator:** [@beacon1096](https://github.com/beacon1096)

## Hardware

Three Minisforum MS-01 hosts:

| host | CPU | RAM | NVMe | NICs | iGPU | vPro |
|---|---|---|---|---|---|---|
| `ms01-a` | Intel Core (13/14 gen, TBD verify SKU) | (TBD verify) | 1× 4 TB | 2× 10 GbE SFP+ + 2× 2.5 GbE | Iris Xe | yes |
| `ms01-b` | same | same | 1× 4 TB | same | same | yes |
| `ms01-c` | same | same | 1× 4 TB | same | same | yes |

**iGPU not currently enabled** in Talos schematic — see [Open questions in docs index](index.md#open-questions--known-unknowns).

## Network

| | |
|---|---|
| Upstream router | UDM-Pro at `172.16.80.254` |
| Cluster VLAN | 87 |
| Cluster subnet | 172.16.87.0/24 (gateway .254) |
| Node IPs | `ms01-a` 172.16.87.11 · `ms01-b` 172.16.87.12 · `ms01-c` 172.16.87.13 |
| Cluster API VIP | 172.16.87.10 |
| PodCIDR | 10.44.0.0/16 (Cilium) |
| ServiceCIDR | 10.55.0.0/16 |
| Bond | `bond0` LACP 802.3ad on the two 10 GbE SFP+ ports, MTU 9000 |
| Rescue NICs | the two i226 2.5G ports remain unbonded; one carries vPro AMT (BIOS default) |

> Naming note: previous architecture used `mgmt-bo` (Harvester convention). The new build uses a neutral `bond0` to make clear this is a Talos-managed bond, not a Harvester-managed one.

LB IP allocations (Cilium IPAM out of `172.16.87.0/24`):

| service | IP |
|---|---|
| envoy-external | 172.16.87.200 |
| envoy-internal | 172.16.87.201 |
| k8s-gateway | 172.16.87.202 |
| zot (private registry, if reintroduced) | 172.16.87.203 |

## Operating system

| | |
|---|---|
| OS | Talos Linux v1.12.6 |
| Image source | `factory.talos.dev` (official, no custom factory) |
| Schematic | see [docs/talos-image-factory.md → talos-ii section](talos-image-factory.md#talos-ii) |
| Disk layout | `/dev/nvme0n1` partitioned: EFI 512 MB · `/` ~50 GB · `/var/lib/longhorn` ~3.5 TB |
| Bootstrap | `talhelper` configs in `talos/clusters/talos-ii/`, `task bootstrap:talos` |

## Cluster networking & ingress

| | |
|---|---|
| CNI | Cilium |
| In-cluster DNS | CoreDNS |
| Image mirror | Spegel (peer-to-peer, with `prependExisting: true` and per-registry mirror config) |
| Ingress | Envoy Gateway (`network/envoy-external` + `network/envoy-internal`) |
| Public exposure (default) | Cloudflare Tunnel → `envoy-external` |
| Public exposure (high-bandwidth / large-upload) | NixOS VPS + Tailscale + Caddy (per-service decision; see [Constitution §VI](../.specify/memory/constitution.md#vi-public-exposure-both)) |
| Private / cross-cluster | Tailscale operator, per-service ClusterIP wrap |
| External DNS | `cloudflare-dns` updates Cloudflare zone `beaco.works` for HTTPRoute hostnames |

## Storage

| | |
|---|---|
| CSI | Longhorn |
| Default `replicaCount` | 2 |
| Lifted to 3 for | forgejo, authentik, vaultwarden, matrix-synapse |
| StorageClass `longhorn` | the default for new PVCs |
| Backups | (TBD) Longhorn Volume Backup → external NFS / S3 — runbook pending |

## Workloads (planned post-bootstrap)

Imported from the talos-ii export of 2026-04-27 (`.private/talos-ii-export-20260426/` in operator workspace, **not in git**):

| ns | app | data origin | replicas |
|---|---|---|---|
| `identity` | authentik | restored from `authentik-pg.sql.gz` | 2 |
| `identity` | vaultwarden | restored from `vaultwarden.tar.gz` | 1 (RWO sqlite) |
| `collaboration` | matrix-synapse | restored from `matrix-synapse-pg.sql.gz` + `matrix-media.tar.gz` | 1 |
| `collaboration` | element-web | stateless | 2 |
| `development` | coder | restored from `coder-pg.sql.gz` + `coder-workspace.tar.gz` | 1 (workspace pod RWO) |
| `development` | n8n | restored from `n8n-pg.sql.gz` + `n8n-state.tar.gz` | 1 |
| `development` | forgejo | restored from `forgejo-dump.zip` (logical) + `forgejo-pvc.tar.gz` (filesystem) | 1 |

Other apps from old talos-ii (`atuin`, `mem0`, `tabby`, `tigerfs`, `openviking`, `zeroclaw-*`, `home-assistant`, `immich`, `navidrome`, `attic`, `zot`) are **not in scope for the rebuild**; whether to reintroduce them is per-app, post-restore.

## Things this cluster intentionally does not have

- KubeVirt / Harvester
- OVN
- Self-hosted Talos image factory (uses sidero official only)
- Custom Talos system extensions
- Helm-managed kube-ovn or any OVN component
- Multus / SR-IOV / hardware-offload networking
- ZFS / btrfs / LVM at the host level

---

# talos-i — secondary, Harvester KubeVirt

**Status:** *not yet adopted into this repo. Currently lives in the [`swarm-01`](https://github.com/beacon1096/swarm-01) repo. This section is a placeholder describing where it'll land when it's brought in.*

## Identity

- **Cluster name:** `talos-i`
- **Purpose:** observability + shared services that don't justify rebuilding NEC8 hardware
  - victoria-metrics / victoria-logs / vmsingle / vmagent / vmalert
  - uptime-kuma
  - forgejo-runner (CI runner reaching across to talos-ii forgejo via Tailscale)
  - spegel (per-cluster)
- **Hardware:** 3× NEC8 (CC150) / M720q. No vPro, no iGPU — Harvester KubeVirt provides the virtual BMC.

## Why this cluster keeps Harvester

CC150 + M720q lack vPro / iGPU. "Boot a USB to recover" requires being physically at the box. Harvester's web UI + KubeVirt VM rescue path is the practical alternative. [ADR talos-ii/0001](decisions/talos-ii/0001-bare-metal-talos.md) documents this asymmetry in detail.

## Network (existing)

| | |
|---|---|
| Cluster subnet | 172.16.107.0/24 |
| Cluster API | 172.16.107.1 |
| Harvester host network | 172.16.100.0/24 (Harvester management subnet) |

## Storage (existing)

- Harvester CSI driver inside Talos VMs (Longhorn-backed at the Harvester layer)
- Known issues: Harvester CSI hot-plug bugs (see [ADR talos-ii/0001](decisions/talos-ii/0001-bare-metal-talos.md) for details — that ADR was about *not* paying this cost on talos-ii; talos-i still does) — mitigated by RWO `nodeSelector` pins on victoria-metrics / vmsingle / grafana / victoria-logs / uptime-kuma
- The `siderolabs/util-linux-mountpoint` custom system extension is **required** here (Harvester CSI's `nsenter mountpoint` path)

## Image factory (existing)

talos-i uses a self-hosted Talos image factory (`registry.beaco.works/.../talos-image-factory`) to build images including the `util-linux-mountpoint` extension. See [docs/talos-image-factory.md → talos-i section](talos-image-factory.md#talos-i) (placeholder until adopted).

## Adoption plan (rough)

When talos-i is brought into this repo:

1. Create `talos/clusters/talos-i/` with talconfig pulled from swarm-01
2. Create `kubernetes/clusters/talos-i/` with cluster-specific Flux structure
3. Move the self-hosted image factory into a path under `kubernetes/` that's clearly scoped to talos-i
4. Create `docs/decisions/talos-i/` and start ADRs there for any future talos-i-specific decisions
5. Retire the swarm-01 repo (or keep it read-only as historical record)

This will happen **after** talos-ii is fully bootstrapped and stable. Not in scope right now.

---

## Last verified

2026-04-27 — initial cluster definitions written ahead of talos-ii bootstrap. Re-verify after first successful Flux reconcile.
