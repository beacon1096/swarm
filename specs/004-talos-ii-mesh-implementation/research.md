# Phase 0 — Research

Resolutions for the eight open questions flagged at spec-stage. Each item follows the Decision / Rationale / Alternatives shape.

---

## Q1 — `ExtensionServiceConfig` YAML shape for OAuth client wiring

**Decision**: Use a single `ExtensionServiceConfig` document with `name: tailscale` for all non-secret env, plus a separate `machine.files` patch that drops the OAuth secret as `TS_AUTHKEY=…` into `/var/etc/tailscale/auth.env`. The extension's `containerboot` wrapper reads both at start time (per upstream README: "Extra tailscale specific environment vars can be configured as needed in `/var/etc/tailscale/auth.env`").

The OAuth wire format is the OAuth client secret string (`tskey-client-<id>-<rand>`) passed verbatim as `TS_AUTHKEY`, with URL query params appended:

```
TS_AUTHKEY=tskey-client-XXXXXXXXXXXXXX?ephemeral=true&preauthorized=true
```

`?ephemeral=true` makes every minted key ephemeral (device record auto-expires ~5 min after heartbeat loss). `preauthorized=true` skips manual approval in the admin UI. This is the documented OAuth wire format per Tailscale KB 1215; `tailscale up --auth-key` (which is what containerboot calls under the hood) accepts it directly.

The two-file split is forced by the schema:
- `ExtensionServiceConfig` is a top-level Talos document (apiVersion `v1alpha1`, kind `ExtensionServiceConfig`), separate from `machine.*` config. talhelper passes it through.
- `machine.files` is a field under the `machine` document. SOPS encrypt-at-rest naturally lives here because the `.sops.yaml` rule for `talos/.*\.sops\.ya?ml` is whole-file (`mac_only_encrypted: true`), unlike the `kubernetes/` rule which is `data|stringData` only.

The extension config (Q1 final form):

```yaml
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_HOSTNAME=talos-ii-${HOSTNAME}
  - TS_ROUTES=10.44.0.0/16,10.55.0.0/16
  - TS_EXTRA_ARGS=--advertise-tags=tag:talos-ii-node --accept-routes
  - TS_ACCEPT_DNS=false
  - TS_AUTH_ONCE=true
```

The secret patch (pre-encryption):

```yaml
---
machine:
  files:
    - op: create
      path: /var/etc/tailscale/auth.env
      permissions: 0o600
      content: |
        TS_AUTHKEY=tskey-client-XXXXXXXXXXXXXX?ephemeral=true&preauthorized=true
```

**Rationale**:
- Splits secret material from non-secret config. Reviewers can read the non-secret patch in cleartext to audit the route / hostname / tag intent, while the secret stays SOPS-encrypted.
- Matches the upstream extension's documented configuration channel (`/var/etc/tailscale/auth.env` is explicitly the extra-envs file in the README).
- Avoids needing a Kubernetes Secret for what is a Talos-host-level credential — Talos `machine.files` is the right primitive.
- `TS_AUTH_ONCE=true` prevents repeated `tailscale up` calls on container restart (default for containerboot is to re-up every start, which is wrong for a long-lived host service).
- `TS_ACCEPT_DNS=false` keeps host `/etc/resolv.conf` clean — pods resolve `*.tail5d550.ts.net` via the cluster CoreDNS forward block (Q2), not via host magic-DNS leak-through.

**Alternatives considered**:
- *Inline `TS_AUTHKEY` in `ExtensionServiceConfig.environment[]`*. Rejected: would put plaintext secret in the same patch file as the route/tag config; harder to make SOPS-encryption granular and risks accidental commit of plaintext.
- *Use a Kubernetes Secret + project into a hostPath mount*. Rejected: tailscaled is not a Pod, it's a Talos host service. Cluster-side Secret has no path to the host extension at boot time.
- *Pre-mint a long-lived auth key (no OAuth)*. Rejected by spec D2: zero manual rotation is a goal. OAuth client + tag is the future-proof path.

---

## Q2 — CoreDNS source-of-truth identification

**Decision**: The cluster CoreDNS is managed by the upstream `coredns` Helm chart via `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`. The Corefile is generated from the chart's `servers[]` values structure (zones / port / plugins). The `ts.net:53` forward block is added as a NEW `servers[]` entry, NOT as a plugin inside the existing `.` server.

The current `servers` list has one entry (zone `.`, port 53, full plugin chain). The new entry adds zone `ts.net`, port 53, with the forward plugin.

**Rationale**:
- Single source of truth (Constitution VIII). The HelmRelease is the only place CoreDNS config is git-tracked.
- Two server blocks is the chart's idiomatic way to handle distinct zones with distinct upstreams. CoreDNS evaluates by zone match: `*.ts.net` queries match the new block; everything else matches `.`.
- No plugin-order-within-block subtlety — they are different blocks, so the "ts.net before catch-all" concern in spec edge cases does not apply.
- Cilium 1.19+ has a "bundled CoreDNS" option but this cluster does NOT use it (verified by the standalone `kubernetes/apps/kube-system/coredns/` directory existence and absence of any `coredns:` stanza in Cilium's HelmRelease values).

**Alternatives considered**:
- *Edit the resulting ConfigMap directly*. Rejected: GitOps drift; Flux would revert it on next reconcile.
- *Add a `forward .` plugin to the `.` server with a zone qualifier*. Rejected: CoreDNS forward plugin's first arg is the zone match — putting `forward ts.net 100.100.100.100` inside the `.` block works syntactically but conflicts with the existing `forward . /etc/resolv.conf`; ordering becomes load-bearing.
- *Cluster Cilium bundled CoreDNS*. N/A — not in use.

---

## Q3 — sing-box `route_exclude_address` audit (CGNAT 100.64.0.0/10)

**Decision**: Resolved as already-handled at the upstream Nix source (`/etc/nixos modules/common/sing-box.nix`, k8s branch). Per parent context, `route_exclude_address` already includes `100.64.0.0/10`. The in-repo HelmRelease comment at `kubernetes/apps/network/sing-box/app/helmrelease.yaml` line 15 mentions only `geoip-private + geoip-cn`, which DOES NOT include CGNAT — the explicit `100.64.0.0/10` line is in the Nix source, rendered into the running pod's `/etc/sing-box/config.json` via `sops.templates`. The Helm values do not show it because the config is built in the Nix flake, not in the HelmRelease.

Plan-stage verification step (in quickstart P0 step 3): `kubectl exec -n network ds/sing-box -- jq '.route' /etc/sing-box/config.json | grep -A3 route_exclude_address`. Expected: a list containing `100.64.0.0/10`. If absent, BLOCK and fix `/etc/nixos` source first.

**Rationale**:
- Eliminates the spec edge-case concern: with `100.64.0.0/10` excluded from sing-box's `auto_redirect`, host kernel's standard route table picks `tailscale0` for tailnet destinations after CoreDNS resolves `*.tail5d550.ts.net` to a 100.x address. Sing-box and tailscaled don't fight over the same packets.
- The /etc/nixos memory note (`feedback_sops_cross_repo_cwd.md`) reminds us that round-trip-decrypt is the only reliable check; here we round-trip by reading the live pod's config.

**Alternatives considered**:
- *Add a redundant local exclusion at this repo's layer*. Rejected: single source of truth principle. The Nix flake owns sing-box config. Duplicating creates drift risk.
- *Skip the verification (trust the comment)*. Rejected: the in-repo comment is misleading (geoip-private excludes RFC1918 only, not CGNAT). Verifying once is cheap.

---

## Q4 — `tag:talos-ii-node` ↔ `tag:talos-i-node` cross-cluster ACL

**Decision**: Deferred to talos-i adoption. This spec only declares `tag:talos-ii-node` and grants it subnet-router permission for its own routes. Cross-cluster ACL rules between the two tags are out of scope per spec FR-005 and Out of Scope section.

**Rationale**:
- `tag:talos-i-node` does not yet exist (talos-i is still in `swarm-01`, per project memory `project_pending_migration_services.md`).
- Adding a placeholder ACL rule for a tag with no devices is harmless but pollutes the ACL with config-without-effect.
- The talos-i adoption spec (future, under shared/0003) is the natural place to declare both tags' interaction, in the same change that adds the second cluster's tag.

**Alternatives considered**:
- *Pre-stage `tag:talos-i-node` in the ACL now with no granted permissions*. Rejected: cosmetic, adds no value, two-step decision (now + future) is uglier than one-step at adoption time.

---

## Q5 — HA semantics: 3 nodes advertising the same routes

**Decision**: Tailscale's subnet-router redundancy is **primary-with-failover**, not load-balancing. When N devices advertise overlapping routes, the control plane picks one as the active primary for any given destination; on heartbeat timeout (~30 s default), reconvergence picks a remaining advertising router. Hostname pattern `talos-ii-${HOSTNAME}` makes the three devices distinguishable in the admin UI for operator inspection.

This matches the spec's User Story 3 (one node out, mesh remains) and SC-005 (≤30 s disruption window).

**Rationale**:
- Documented Tailscale behavior; no special config required to enable HA — it's automatic when multiple devices advertise overlapping routes with the same tag.
- Acceptable failover window for the canary use cases (CI runs, periodic Prometheus scrapes from talos-i once adopted).
- Consistent identity at policy level (`tag:talos-ii-node`) regardless of which physical device is active.

**Alternatives considered**:
- *Designated 1- or 2-node subnet-routers (the "carve out a subset" sketch in shared/0002)*. Rejected per spec D1: full-mesh on 3 nodes is simpler and tailscaled's per-node cost is ~30 MB RSS — negligible on 64 GB MS-01.
- *Manual primary designation via Tailscale UI*. Rejected: defeats HA automation.

---

## Q6 — `ExtensionServiceConfig` placement precedence

**Decision**: Place as a global Talos patch at `talos/patches/global/machine-tailscale.yaml`. talhelper merges global patches into every node's machineconfig in deterministic order. `ExtensionServiceConfig` is a separate document (not a `machine.*` field), so it appears as an additional document in the rendered output — talhelper passes through extra documents transparently.

Same applies to the SOPS secret patch at `talos/patches/global/machine-files-tailscale-secret.sops.yaml` — `machine.files` IS under `machine.*`, so it strategic-merges with other `machine.files` lists in adjacent patches (e.g. `machine-files.yaml` containerd customization). talhelper handles list-append for `machine.files` correctly.

**Rationale**:
- All three nodes need identical config (HA via redundancy, not differentiation).
- Existing convention `talos/patches/global/machine-*.yaml` is well-established (7 files already there).
- Per-node patch placement (`talos/patches/<node>/`) is reserved for cases where nodes diverge — none here.

**Alternatives considered**:
- *Per-node patches*. Rejected: triplicated near-identical YAML; future modifications must touch three files.
- *Inline under `nodes[].patches` in `talconfig.yaml`*. Rejected: inflates the already-long talconfig.yaml; existing convention is to factor `machine-*` patches into `talos/patches/global/`.

---

## Q7 — Subnet-router opt-out at plan stage

**Decision**: All three nodes are subnet routers. The global patch applies uniformly. No per-node opt-out at this plan stage. If a future operator wants to demote one node to non-router (e.g. for a maintenance experiment), they place a per-node `talos/patches/<node>/machine-tailscale-noroute.yaml` overriding `TS_ROUTES=` to empty — out of scope here.

**Rationale**:
- Spec D1 is unambiguous: HA via 3 routers.
- Uniform config minimizes ops surface area; every node is interchangeable from a mesh perspective.

**Alternatives considered**:
- *Two routers, one host-membership-only node*. Rejected per spec D1.

---

## Q8 — Rollback path

**Decision**: Three-tier rollback ladder, used in escalation order:

1. **Schematic re-pin (planned rollback, fast)**: replace the new schematic ID with `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4` at all three sites in `talos/talconfig.yaml`. Run `task talos:upgrade-node IP=...` per node sequentially. Installer image is content-addressable; re-flash is mechanical. No data loss; node returns to pre-tailscale state. Tailscale device records orphan (cleanup is one operator click in admin UI per device; ephemeral keys auto-expire ~5 min).

2. **Live config-only revert (no reflash)**: if the schematic is fine but the ExtensionServiceConfig is broken (e.g. typo in TS_ROUTES), `talosctl edit mc --nodes <ip>` and remove the ExtensionServiceConfig document; Talos restarts the extension with no config, which transitions tailscaled to logged-out state. Node remains otherwise healthy. Then fix the patch in git and re-apply.

3. **Catastrophic boot failure (rare)**: if the new schematic image fails Secure Boot verification on first node (canary), recover via `talosctl reset --graceful=false --reboot`. This brings the node back without applying the bad config; node is then re-flashed with prior schematic ISO via the rescue procedure (vPro AMT KVM + USB ISO from the i226 NIC subnet). The kubectl-stdin-truncation memory note (`feedback_kubectl_exec_stdin.md`) is irrelevant here because Talos rescue uses `talosctl`, not `kubectl exec`.

**OAuth client cleanup**: not part of rollback. Client stays valid until next attempt; no rotation needed. Revocation is a separate operation triggered only by detected secret leak.

**Rationale**:
- Tier 1 is the standard reversibility path for any Talos schematic change. The rest of the repo's history (e.g. talos-ii initial bootstrap) follows this pattern.
- Tier 2 covers the most likely failure mode (typo in non-secret config).
- Tier 3 covers the rare Secure Boot key mismatch — addressed in Plan §Risks #1.

**Alternatives considered**:
- *Maintain dual-schematic fleet (some nodes on new, some on old)*. Rejected: violates the "uniform schematic per cluster" convention; no operational value.
