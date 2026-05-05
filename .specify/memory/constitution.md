# Constitution — swarm

This repository will eventually manage **two** Talos clusters:

| cluster | role | hardware | hypervisor |
|---|---|---|---|
| **talos-ii** | primary production workloads | 3× MS-01 | bare metal (this is the cluster we're building first) |
| **talos-i** | shared services kept on existing hardware | 3× NEC8 (CC150) / M720q | Harvester KubeVirt VMs |

Each principle below is tagged:

- **[both]** — applies to every cluster the repo manages
- **[talos-ii]** — applies only to the bare-metal MS-01 cluster
- **[talos-i]** — applies only to the Harvester-hosted cluster (added when talos-i is brought into this repo)

Update this constitution only by ratifying a new ADR in `docs/decisions/` and bumping the version below.

---

## I. Hypervisor stance

### [talos-ii] Bare metal, no nesting

Talos runs **directly on MS-01 hardware**. No KubeVirt, no Harvester, no other hypervisor between Talos and metal.

> *Why:* MS-01 has vPro / iGPU / direct NVMe — sufficient for remote rescue and full performance without a virtualization layer. Eliminates entire classes of bugs (KubeVirt hot-plug, Harvester CSI nsenter, OVN raft, etc.) we previously had to work around.

### [talos-i] Continue Harvester KubeVirt

Talos runs as VMs on Harvester. The CC150 / M720q hardware lacks vPro and iGPU; Harvester provides the "virtual BMC" we need for remote rescue.

> *Why:* see ADR 0001 — the bare-metal decision was specifically for MS-01.

## II. Storage [both]

- Each cluster uses **Longhorn** as the only CSI in-cluster.
- For talos-ii: Longhorn runs directly on the host's NVMe partition (`/var/lib/longhorn`).
- For talos-i: Longhorn runs *inside* the Talos VMs on disks Harvester exposes; Harvester's own Longhorn (the underlying VM storage) is a separate layer that this repo does not touch.
- **No** LVM, **no** ZFS, **no** btrfs at the layer this repo controls. Longhorn handles redundancy; another indirection adds failure modes without adding redundancy.
- Replication: default `replicaCount: 2`, lift to `3` per-app for irreplaceable data (forgejo, authentik, vaultwarden, matrix, etc.).

## III. Network

### [talos-ii] Direct VLAN on UDM-Pro

- Cluster nodes attach to **VLAN 87 / 172.16.87.0/24** via the LACP bond on the two 10 GbE SFP+ ports.
- The bond is named via Talos's machine config — choose a neutral name (e.g. `bond0`), **not** the Harvester convention `mgmt-bo` (that's a Harvester-specific name from the previous architecture).
- No OVN, no overlay at the host layer. Cilium provides Pod / Service networking inside the cluster (PodCIDR `10.44.0.0/16`, ServiceCIDR `10.55.0.0/16`).
- The two i226 2.5 GbE ports remain unbonded as **rescue NICs** (one carries vPro AMT per BIOS default).

### [talos-i] Existing topology

- Whatever the Harvester host network already is. The talos-i Talos VMs sit on `172.16.107.0/24` via the Harvester management network.
- This repo does not redefine talos-i's underlying network when it's adopted.

## IV. Image factory

### [talos-ii] Official factory only

Use **`https://factory.talos.dev`** (sidero official) for talos-ii images. **No** custom extensions for talos-ii.

> *Why:* the original custom extension (`util-linux-mountpoint`) was a Harvester-CSI workaround; bare-metal Longhorn doesn't need it.

### [talos-i] Self-hosted factory permitted

talos-i continues to need at least one custom Talos extension (the `util-linux-mountpoint` workaround for Harvester CSI). That requires a self-hosted image factory.

When talos-i comes into this repo:

- The self-hosted factory configuration lives in `kubernetes/<talos-i-or-shared>/registry/talos-image-factory/`
- Custom extension Dockerfiles live in `containers/` or similar
- All non-public schematics (custom or self-hosted-factory-generated) **must** be reverse-mapped in [docs/talos-image-factory.md](../../docs/talos-image-factory.md) under the per-cluster section

### [both] Schematic transparency

A schematic ID is an opaque hash. Every active schematic ID must have a corresponding entry in `docs/talos-image-factory.md` listing the extensions and rationale. **Same commit** that changes the schematic ID must update the doc.

## V. Secrets [both]

- All cluster secrets encrypted with `age`. Recipient list in `.sops.yaml`.
- The age private key (`age.key`) is **gitignored** and lives only on operator machines.
- `kubeconfig` / `talosconfig` files are gitignored.
- Harvester admin kubeconfigs (`*-hvst.yaml`, `harvester_kubeconfig`) are gitignored.

## VI. Public exposure [both]

Default path:

- Public hostnames (`*.beaco.works` etc.) terminate at the in-cluster `envoy-external` Gateway, fronted by a **Cloudflare Tunnel** running in the cluster.
- This is the **default** for any new public-facing HTTP service.

Exception path (Cloudflare bandwidth / upload limits):

- Services that need **larger throughput** or **long-running uploads** (Cloudflare Free has a ~100 MB request body cap and bandwidth ToS concerns for media-heavy / large-file workloads) are exposed through a **separately managed cloud VPS**:
  - The VPS runs **NixOS** with `/etc/nixos/` configuration (see Nix fleet repo)
  - Tailscale connects the VPS to the in-cluster `tailscale` operator endpoint
  - **Caddy** on the VPS terminates TLS and reverse-proxies to the Tailscale-side service
- This decision is made per-service. Default is Cloudflare; flip to VPS-Caddy only when there's a concrete need (recorded as part of the spec for that service).

## VII. Private (LAN / cross-cluster) exposure [both]

Two complementary mechanisms, both built on Tailscale, with distinct roles. Per ADR `shared/0002` (accepted 2026-05-04, Option C):

### Per-Service ingress: in-cluster `tailscale` operator

- Default for new private exposure. Wrap individual ClusterIPs as Tailscale-only endpoints with `tailscale.com/expose` annotations.
- Granular ACLs per Service. Auth-key blast radius isolated to the wrapped Service.
- No NodePort exposure to the LAN by default.

### Cross-cluster mesh + node-level egress: `siderolabs/tailscale` host extension

- Allowed and expected in each cluster's Talos schematic. `tailscaled` runs in host network namespace on every node; selected nodes (or all, for HA) advertise `--advertise-routes=<pod-cidr>,<svc-cidr>` as **subnet routers**.
- Effects:
  - Tailnet clients reach cluster pods directly via PodCIDR (kube-proxy / Cilium forwards) — no per-Service operator wrapping needed on the consume side.
  - Cross-cluster reachability between talos-i and talos-ii goes via L3 routing through subnet routers. PodCIDRs and ServiceCIDRs are non-overlapping by design (talos-ii: `10.44/16` + `10.55/16`; talos-i: `10.42/16` + `10.43/16`).
  - DNS: each cluster's CoreDNS adds a `ts.net:53 forward 100.100.100.100` block so pods resolve `*.tail5d550.ts.net` directly.
- Auth: OAuth client + tag-based ACLs (e.g. `tag:talos-ii-node`); no manually-rotated long-lived auth keys.
- The host extension does **not** replace the operator's per-Service ingress role. Both are deployed.

> *Why both:* Operator wraps individual Services with Tailscale identity (good for ingress + per-Service ACL). Subnet router exposes the entire cluster's pod-network at L3 (good for cross-cluster mesh and avoiding per-pod tailscale config for egress). Earlier framing of these as competing was wrong; ADR shared/0002 accepts them as complementary layers.

## VIII. GitOps [both]

- `flux-operator` + `flux-instance` deployed at bootstrap.
- All `kubernetes/apps/*` are reconciled by Flux.
- `kubectl apply` directly is reserved for **bootstrap** and **incident response**; it must be followed by either bringing the change into git or reverting.

## IX. Spec-Driven Development [both]

Any change touching:

- Cluster topology (nodes, network segments, storage classes)
- Application architecture (new app, breaking version bump, data model change)
- Security boundaries (auth, secrets, exposure)
- Schematic / Talos OS configuration

…must go through:

1. `/specify` — feature description + acceptance criteria
2. `/plan` — technical approach + research
3. `/tasks` — discrete actionable steps
4. `/implement`

Trivial bumps (`renovate`-class dep updates), routine ops, and emergency hotfixes are exempt.

## X. Documentation [both]

- `docs/decisions/<cluster>/NNNN-title.md` — Architecture Decision Records, sequential per cluster directory:
  - `docs/decisions/talos-ii/` for talos-ii-specific decisions
  - `docs/decisions/talos-i/` for talos-i-specific decisions (created when talos-i is adopted)
  - `docs/decisions/shared/` for decisions that apply to both
- `docs/talos-image-factory.md` — schematic ID ↔ extension reverse map, sectioned per cluster
- `docs/cluster-definition.md` — what runs where, sectioned per cluster
- `docs/operations/` — runbooks (split per cluster when behavior diverges)
- `docs/index.md` — table of contents

## XI. No surprise reboots, no destructive shortcuts [both]

- Don't reboot a sole-source-of-truth node without first proving the data is replicated elsewhere.
- Don't run `kubectl delete pvc` without proving the Pod is stopped and the data is backed up.
- Don't skip git hooks, gpg signing, or hard-reset published commits, except in emergencies and with explicit acknowledgment.

---

## Amendment process

To amend this constitution:

1. Open an ADR under the relevant `docs/decisions/<cluster|shared>/` directory describing the proposed change
2. Update the relevant section here in the same commit
3. Bump the version below

**Version:** 1.2.0
**Last ratified:** 2026-05-05 — §VII rewritten to formalize the operator + subnet-router two-tier model from ADR `shared/0002` Option C (accepted 2026-05-04). Earlier wording read literally as "operator only", which contradicted the ADR; this rewrite states the complementary layering explicitly.

**Previous ratifications:**
- 1.1.0 — 2026-04-27 — split principles by cluster scope, add Cloudflare-vs-VPS exposure rule, separate self-hosted factory permission for talos-i.
