# Feature Specification: talos-ii mesh implementation (siderolabs/tailscale + 3-node subnet router)

**Feature Branch**: `004-talos-ii-mesh-implementation`
**Created**: 2026-05-04
**Status**: Draft
**Input**: User description: "Implement shared/0002 Option C on talos-ii: add `siderolabs/tailscale` Talos system extension to all 3 ms01-* nodes, configure each as a Tailscale subnet router advertising the cluster's PodCIDR + ServiceCIDR, in HA 3-node configuration. Authentication via OAuth client + tag (`tag:talos-ii-node`), zero manual key rotation."

## Scope

**Target cluster: `[talos-ii]` only.** This feature lands the host-level Tailscale integration on talos-ii (3× MS-01 nodes). It MUST NOT touch talos-i in any way: talos-i is still in `swarm-01` and its eventual adoption + offsite move is the separate work tracked under shared/0003. When talos-i is later adopted, it will get its own analogous spec with its own tag (`tag:talos-i-node`); this spec deliberately does not pre-stage talos-i config.

This is the **last layer-3 ADR pending implementation** before talos-i hardware repositioning can begin. ADR shared/0002 was accepted 2026-05-04; gating ADRs shared/0003 (talos-i positioning) and shared/0004 (egress gateway, Phase 2 in flight) are settled. With this spec implemented, the cluster fabric is in place for cross-cluster pod-to-tailnet reachability.

## Decisions Resolved

The three open questions from the parent ADR (shared/0002 §"Open questions deferred") are resolved here for the talos-ii implementation. One-line summary; full rationale lives inside the FR / Edge Case sections.

- **D1 — HA topology: 3 subnet routers (one per node).** Every ms01-* node advertises the same routes; Tailscale picks one for any given dst (failover free). Tradeoff accepted: tailnet shows 3 devices for talos-ii instead of 1; ACLs key off `tag:talos-ii-node` so multiplicity is invisible at policy level. Rejected: dedicated 1-2 subnet-router nodes (the "talos-ii dedicated routers" sketch in shared/0002's open questions) — full mesh on a 3-node cluster has lower coordination cost than carving out a subset, especially since tailscaled on the host costs ~30 MB RSS per node.
- **D2 — Auth: OAuth client + tag `tag:talos-ii-node`.** One Tailscale OAuth client (scope `auth_keys:write`, owns tag `tag:talos-ii-node`) is created in the Tailscale admin console once. Its `client_id` + `client_secret` are SOPS-encrypted into a Talos machine config patch. On each node boot, local `tailscaled` uses the OAuth client to mint a short-lived ephemeral auth key and registers itself under `tag:talos-ii-node`. Zero manual long-lived auth-key rotation; OAuth client itself is configured once and runs indefinitely. Rejected: classic pre-shared auth keys (annual rotation overhead; ephemeral-key handling on Talos is awkward without OAuth).
- **D3 — Routes advertised: PodCIDR `10.44.0.0/16` + ServiceCIDR `10.55.0.0/16`.** Both are non-overlapping with talos-i (`10.42.0.0/16` / `10.43.0.0/16` per Constitution III), so cross-cluster routing is unambiguous when talos-i adopts. `--accept-routes` is also set so talos-ii nodes receive talos-i's advertised CIDRs once talos-i is online. Rejected: advertising only PodCIDR (would force an extra ClusterIP→Pod hop for tailnet→Service traffic via kube-proxy on a non-router node — ServiceCIDR makes the path symmetric).

This is the **first cluster-fabric consumer** of shared/0002 Option C. Operator (per-Service ingress) + extension (subnet router + cross-cluster) are **complementary**, not competing — the host extension handles cross-cluster pod-to-tailnet egress and tailnet-to-pod ingress for any IP in the advertised CIDRs; the operator continues to handle per-Service named tailnet ingress (`attic.tail5d550.ts.net` → operator proxy → Service).

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Pod-to-tailnet outbound succeeds without per-pod tailscale config (Priority: P1)

From any pod on talos-ii's PodCIDR (`10.44.0.0/16`), a request to a tailnet hostname or 100.x address resolves and routes through the local node's `tailscaled` to the target. No tailscale-operator egress Service, no annotation, no sidecar.

Concrete example: a `kubectl exec`-shell into a generic pod (e.g. `curl-bench`) runs `curl http://attic.tail5d550.ts.net/` and gets a normal HTTP 200/302 response, with packet path `pod → cluster CoreDNS (ts.net forward → 100.100.100.100) → DNS resolved → pod default route → node netfilter → host tailscaled → tailnet → tailnet-side target`.

**Why this priority**: This is the entire reason for the deployment. The 2026-05-03 forgejo-runner CI incident (logged in shared/0002 context) was triggered by exactly this case failing on talos-i. talos-i adoption (shared/0003) blocks until the fabric works on at least one cluster. talos-ii is the canary.

**Independent Test**: Deploy a `curl`-capable test pod in any namespace. Run a curated curl matrix: `100.x.y.z` direct IP, `*.tail5d550.ts.net` hostname, a tailnet-exposed Service like attic. Verify each succeeds, and that the request appears in the target's logs sourced from a 100.x address belonging to one of the three ms01-* subnet routers.

**Acceptance Scenarios**:

1. **Given** the 3-node subnet router is online and CoreDNS has the `ts.net:53` forward block, **When** any pod on talos-ii runs `getent hosts attic.tail5d550.ts.net`, **Then** it resolves to a 100.x address (Magic DNS) without error.
2. **Given** the same setup, **When** any pod runs `curl -fsS http://attic.tail5d550.ts.net/`, **Then** the request reaches attic and returns HTTP 2xx; attic's logs show the source address as one of the three ms01-* subnet routers' 100.x addresses.
3. **Given** the same setup, **When** `tcpdump` runs on the egress node's tailscale0 (or the equivalent host interface), **Then** the request packet is observed leaving via tailscaled's TUN, **NOT** via the public-egress sing-box path.

---

### User Story 2 — Tailnet-to-pod inbound succeeds via subnet router (Priority: P1)

From a tailnet client (e.g. operator laptop with `tailscaled` running and route accept enabled), a request to a PodCIDR or ServiceCIDR IP on talos-ii routes via one of the three subnet routers, hits node netfilter, kube-proxy forwards to the actual pod.

Concrete example: with the laptop on the tailnet, `curl http://10.44.x.y:8080/` (where 10.44.x.y is a real Pod IP) succeeds; `curl http://10.55.a.b:80/` (a Service ClusterIP) likewise succeeds.

**Why this priority**: Symmetric counterpart to Story 1. This is also the path future cross-cluster pod-to-pod traffic will take (talos-i pod → mesh → talos-ii subnet router → talos-ii Pod). If this story is broken, observability scrape from talos-i (post adoption) won't reach talos-ii's metrics endpoints, and the offsite cluster's primary purpose is defeated.

**Independent Test**: From a tailnet-member laptop, run `tailscale status` and confirm `talos-ii-ms01-{a,b,c}` are listed with `tag:talos-ii-node` and advertise `10.44.0.0/16 10.55.0.0/16`. Then `curl` directly to a known Pod IP and a known Service ClusterIP. Both succeed.

**Acceptance Scenarios**:

1. **Given** the 3 subnet routers are online and the laptop's `tailscaled` has accepted routes, **When** the operator runs `tailscale status`, **Then** the three node devices are visible with the correct tag and the two CIDRs as advertised routes (subnet router status `active`).
2. **Given** the same state, **When** the operator runs `curl -fsS http://<pod-ip>:<port>/` from the laptop, **Then** the response is the pod's response (verified by Pod-side logs showing the request).
3. **Given** the same state, **When** the operator runs `curl -fsS http://<service-cluster-ip>:<port>/` from the laptop, **Then** kube-proxy on the entered node correctly DNATs to a backing pod (which may live on a different ms01-* node — Cilium handles inter-node forwarding).

---

### User Story 3 — One node out, mesh path remains (Priority: P1)

Any one of `ms01-{a,b,c}` can be cordoned + drained + rebooted (or unplanned outage) and the tailnet ↔ talos-ii reachability paths from Stories 1 and 2 remain functional within Tailscale's standard reconvergence window (under 30 seconds typical; under 60 seconds worst-case).

**Why this priority**: HA was the explicit reason for choosing the 3-router topology over a single-router design. If failover doesn't actually work, we've taken on the multiplicity tradeoff (3 tailnet devices instead of 1) for nothing.

**Independent Test**: With a sustained pod-to-tailnet `curl` loop running (Story 1 setup), `task talos:upgrade-node IP=<ms01-a>` (or a graceful reboot equivalent). Observe that some requests may time out for ≤ 30s during the failover window, then resume. Repeat for the other two nodes. Total disruption is bounded by Tailscale's route-advertisement TTL, not by application restart.

**Acceptance Scenarios**:

1. **Given** the 3 routers are healthy and a sustained outbound curl loop is running from a talos-ii pod, **When** `ms01-a` is rebooted (planned), **Then** the curl loop has at most a brief failure window (<30s typical) before resuming via `ms01-b` or `ms01-c`.
2. **Given** the same setup, **When** the same is repeated for `ms01-b` and `ms01-c` in turn (one at a time), **Then** the curl loop survives each reboot with the same characteristics.
3. **Given** all 3 nodes have rebooted into the new schematic with the extension active, **When** `tailscale status` is run from a tailnet client, **Then** all three are listed as online with subnet routes active and `tag:talos-ii-node`.

---

### User Story 4 — Existing tailscale-operator continues to work for per-Service named ingress (Priority: P2)

After the host extension lands, the in-cluster `tailscale-operator` (kube-system) still serves its existing role: each `tailscale.com/expose: "true"` Service still gets a `ts-<svc>-<hash>` operator-managed proxy StatefulSet, and `<svc>.tail5d550.ts.net` continues to resolve to that proxy's tailnet IP (not to a subnet-router node).

**Why this priority**: Operator + extension are **complementary** (per shared/0002 acceptance rationale). The operator's per-Service narrow responsibility is the right tool for "give this Service its own tailnet hostname"; the extension is the right tool for "give all pods a generic path to the tailnet." Neither replaces the other. Verifying both work side-by-side is mandatory; if the operator regresses, we accidentally created a cluster-fabric dependency on the extension for things that should still be per-Service.

**Independent Test**: After deploy, list all operator-managed `ts-*` StatefulSets in `network` (or wherever the operator reconciles to); confirm count and Ready state are unchanged from pre-deploy. Resolve `attic.tail5d550.ts.net` from a tailnet laptop — the resolved IP should still be the **operator proxy**'s tailnet IP, not a subnet-router node IP. The path from a tailnet client to that hostname goes via the operator proxy as before; the path from a talos-ii pod to that same hostname now goes via the local subnet router (Story 1) — both paths exist concurrently.

**Acceptance Scenarios**:

1. **Given** tailscale-operator was healthy pre-deploy, **When** the host extension is rolled out across the 3 nodes, **Then** the operator's reconcile loop reports no errors and all `ts-*` StatefulSets remain Ready with unchanged tailnet IPs.
2. **Given** both are healthy post-deploy, **When** a tailnet laptop resolves `attic.tail5d550.ts.net`, **Then** the IP returned is the operator proxy's IP (existing 100.x address), not a router-node IP. Subnet routers are visible separately as `tag:talos-ii-node` devices.
3. **Given** both are healthy, **When** a talos-ii pod resolves the same hostname, **Then** Magic DNS via `100.100.100.100` returns the same operator-proxy IP, and the pod reaches it via the local node's subnet router → tailnet → operator proxy → Service path.

---

### User Story 5 — Tailnet device ephemerality on node reboot (Priority: P3)

Because OAuth + ephemeral-key auth (D2) is used, a node reboot triggers the OAuth client to mint a fresh ephemeral key on next boot, register a fresh device, and deregister cleanly when the previous device's session times out. There is no manual deregistration and no orphaned device lingering in the admin UI for the wrong node identity.

**Why this priority**: Operational hygiene, not functional correctness. Story 3 already proves traffic continues; this story is about ensuring the admin UI doesn't fill with stale device records over months of reboots, and that ACLs based on `tag:talos-ii-node` don't accidentally include long-dead session identities.

**Independent Test**: Inspect the Tailscale admin device list. Reboot one node. Wait for the ephemeral session timeout (default ~5 min). Confirm: (a) the post-boot device appears immediately on boot, (b) the pre-reboot device's record disappears within the timeout (or is marked `Expired`), (c) total device count for `tag:talos-ii-node` remains 3 in steady state.

**Acceptance Scenarios**:

1. **Given** ephemeral OAuth-minted keys are in use, **When** `ms01-a` reboots, **Then** a new device under `tag:talos-ii-node` appears within seconds of boot, and the prior device's record is removed within the ephemeral session timeout.
2. **Given** post-reboot steady state, **When** the operator audits the Tailscale admin UI, **Then** exactly 3 devices carry `tag:talos-ii-node` with route advertisement `10.44.0.0/16,10.55.0.0/16`, and there are no stale `Expired` devices for talos-ii.

---

### Edge Cases

- **Cilium BPF masquerade vs. tailscaled host-level routing**: Cilium uses BPF for SNAT on egress from PodCIDR to outside. tailscaled runs in the host network namespace, owns its own TUN device (`tailscale0`), and its routing rules live alongside Cilium's. The expected packet flow for pod-to-tailnet is: pod → cluster default route → host net ns → routing decision sends to `tailscale0` (because dst is in `100.64.0.0/10` after DNS resolution, or in an advertised tailnet route) → tailscaled TUN → upstream. Cilium's BPF should NOT intercept this path because the destination is outside both PodCIDR and ServiceCIDR. Verifiable by `ip route get 100.x.y.z` on a node showing `dev tailscale0`. If the route isn't picked up, Cilium's masquerade-all option could be the cause; check `cilium config view | grep -i masquerade` and any `ipMasqAgent.nonMasqueradeCIDRs` for explicit `100.64.0.0/10` exclusion.
- **sing-box auto_redirect ↔ tailnet 100.x destinations**: shared/0004 Phase 2 sing-box DaemonSet uses `auto_redirect: true` and TUN to capture pod egress to public destinations. Without explicit handling, sing-box's nftables interception could capture pod-to-tailnet packets too, sending tailnet traffic out via the public proxy by mistake. Mitigation: sing-box config's `route_exclude_address` MUST include `100.64.0.0/10` (CGNAT range). Per the forgejo-runner spec (003) Acceptance Scenario 3.3, the existing exclude already covers `100.64.0.0/10`; this spec MUST verify (and add if absent) before the tailscale extension lands. If the exclusion is present, no sing-box change is required; if not, the exclusion is added in the same commit chain.
- **Schematic re-submission for Secure Boot**: ADR talos-ii/0005 enabled Secure Boot via `secureboot=true` factory parameter. The new schematic with `siderolabs/tailscale` MUST also be submitted with `secureboot=true`. The resulting schematic ID will be different from the current `5456009e...` — this is expected and not a regression. The new schematic ID MUST be verified to boot under the existing PCR-bound Secure Boot keys before rolling production nodes (test on one node first; rollback path is to re-flash with the prior schematic ID URL since the installer image is content-addressable).
- **Ephemeral device record vs. session continuity during 30s failover**: Story 3 specifies <30s failover window. If a node is rebooted, its OAuth-minted ephemeral key is invalidated and a new device record is created post-boot. Tailscale's route reconvergence picks an alternate router for the brief gap; this is independent of how fast the rebooted node re-registers. The "30s" window is dictated by Tailscale's route TTL, not by registration speed.
- **Tailnet control plane outage**: If Tailscale's coordination server is unreachable (rare; commercial SaaS), existing peer connections persist on cached routes for ~30 minutes (DERP heartbeat dependent). New peer connections fail. Pods that hard-coded a 100.x address will continue working; pods that need to resolve a fresh `*.tail5d550.ts.net` hostname will fail to resolve. Cluster-internal Services are unaffected (CoreDNS only forwards `ts.net:53` to MagicDNS, not the cluster zone). This is a known SaaS-tailnet failure mode; mitigation is the planned migration to a self-hosted control plane per shared/0003 sub-decision (2), tracked in the future Headscale/NetBird ADR (out of scope here).
- **kube-proxy on entry node + Cilium inter-node forwarding**: When a tailnet client connects to a Pod IP via the subnet router, the packet enters whichever ms01-* node Tailscale picked. That node's kube-proxy (or Cilium replacement) forwards to the actual pod, which may live on a different ms01-* node. Cilium handles the inter-node hop via VXLAN/native routing per its configured datapath. Reverse-path filtering on the entry node MUST allow this asymmetric flow. Verifiable by `sysctl net.ipv4.conf.all.rp_filter` on a Talos node — Talos default is `2` (loose), which permits this. If a future Talos default changes to `1` (strict), this spec's path could break; flag in the runbook.
- **Node clock skew and OAuth client token validity**: OAuth-minted ephemeral keys have a short TTL. If a node's clock is skewed by more than the TTL (e.g. NTP fails on first boot), authentication fails. Talos has chrony built-in; verify NTP sync before the tailscale ExtensionService starts (or, if Talos's extension start order makes that hard, document the symptom in the runbook so a "tailscale won't start" failure mode is recognizable).
- **Rolling upgrade order**: All three nodes must end up on the new schematic ID; rolling is one node at a time per existing Talos upgrade convention. During the partial state (1-of-3 or 2-of-3 nodes upgraded), the tailnet sees fewer than 3 routers but the routes are still advertised by whichever nodes are upgraded. Story 3's HA characteristic kicks in early — i.e., once the first node is upgraded and joined the tailnet, Story 1's pod-to-tailnet path works for pods scheduled on that node, but pods on the other two nodes still don't have a host tailscaled. Pods can be drained + rescheduled, or operators can accept the partial state until the rollout completes. Roll the third node only after the second is verified healthy.
- **Operator doubling: `tailscale-operator` Service exposure → operator proxy IP vs. router IP confusion**: A common mistake during deploy verification is to look up `attic.tail5d550.ts.net` from a router node's host shell (where one might expect the local tailscaled to short-circuit). The hostname resolves to the **operator proxy's tailnet IP**, not a router IP — that's correct per Story 4. Don't mistake "this resolves to a different IP than the router" for a misconfiguration.
- **DNS forward block on a CoreDNS configured with broader `forward .` patterns**: If CoreDNS's Corefile already has a catch-all `forward . <upstream>` block that resolves anything ending in `.ts.net`, the new `ts.net:53 forward . 100.100.100.100` block must come **before** the catch-all (CoreDNS evaluates in plugin order with first-match). Verify by `dig` from a pod for both `<service>.tail5d550.ts.net` (must hit MagicDNS) and `example.com` (must hit upstream). Both should succeed with the new config.

## Requirements *(mandatory)*

### Functional Requirements

#### Schematic and image factory

- **FR-001**: A new Talos image factory schematic for talos-ii MUST be submitted to `factory.talos.dev` adding `siderolabs/tailscale` to the existing official-extension list (`siderolabs/intel-ucode`, `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`, `siderolabs/tailscale`). The schematic MUST be submitted with `secureboot=true` per ADR talos-ii/0005, and MUST keep `bootloader=sd-boot`. The resulting schematic ID is a new SHA256 distinct from the current `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`.
- **FR-002**: The new schematic ID MUST be pinned in `talos/talconfig.yaml` at all three node `talosImageURL` references (currently three identical occurrences at lines ~33, ~83, ~133). It MUST replace the prior schematic ID, not be added alongside.
- **FR-003**: `docs/talos-image-factory.md` MUST be updated in the same commit chain that lands the schematic change, per Constitution §IV/§X. Specifically: (a) the active-schematic section is updated with the new ID, (b) the prior schematic is moved to "Historical schematics — talos-ii" with `superseded by <new-id> on 2026-MM-DD`, (c) `siderolabs/tailscale` is added to the "Why each extension" table with `reason: subnet router for cross-cluster mesh fabric per shared/0002 Option C` and `drop-when: when mesh control plane changes (re-evaluate)`, (d) the "Tailscale: host extension vs in-cluster operator" footnote is rewritten to reflect that both are now in use, complementarily — operator for per-Service named ingress, extension for cluster-fabric subnet routing — with cross-link to shared/0002.

#### OAuth client and authentication

- **FR-004**: A Tailscale OAuth client MUST be created in the Tailscale admin console (Settings → OAuth clients) with: scope `auth_keys:write`, owner tag `tag:talos-ii-node`, no expiry. The client_id and client_secret MUST be SOPS-encrypted in this repo.
- **FR-005**: The Tailscale ACL file MUST declare `tag:talos-ii-node` as a tag, with the OAuth client (FR-004) as an authorized owner. The ACL change is operator-applied via the Tailscale admin console (or Terraform if/when ACL-as-code is adopted — out of scope here). The ACL MUST permit `tag:talos-ii-node` to act as a subnet router (i.e., advertise routes for `10.44.0.0/16` and `10.55.0.0/16`). Cross-cluster ACL rules between `tag:talos-ii-node` and `tag:talos-i-node` are NOT in scope for this spec — they are added when talos-i adopts.
- **FR-006**: Each ms01-* node MUST authenticate to the tailnet using the OAuth client to mint a short-lived ephemeral key on boot. There MUST NOT be any pre-shared long-lived auth key checked into the repo or stored on nodes. The OAuth client itself is the long-lived secret; node-level auth keys are ephemeral and derived per-boot.

#### Talos machine config patch

- **FR-007**: A new Talos machine-config patch (location: `talos/patches/global/machine-tailscale.yaml` or analogous; final path is a Plan-stage decision but MUST follow existing `talos/patches/global/machine-*.yaml` convention) MUST configure the `siderolabs/tailscale` extension service with: (a) the SOPS-decrypted OAuth client credentials, (b) `--advertise-routes=10.44.0.0/16,10.55.0.0/16`, (c) `--accept-routes`, (d) the hostname pattern (e.g. `talos-ii-${HOSTNAME}` so each node is identifiable), (e) `--advertise-tags=tag:talos-ii-node`.
- **FR-008**: The patch MUST apply to all three ms01-* nodes (i.e., a global patch, not a per-node patch). All three nodes advertise the same routes (HA via Tailscale's built-in subnet-router redundancy).
- **FR-009**: SOPS-encrypted material (the OAuth client credentials in particular) MUST be wired through Talos's machine config in a way that decrypts at apply time, not at boot time. The decrypted credentials MUST land in the `tailscaled` extension's runtime config but MUST NOT be readable from any pod. (Plan stage decides exact mechanism: machine-files patch with SOPS pre-decryption in CI, or Talos's `extensionsServiceConfigs` env-var-from-secret pattern.)

#### CoreDNS forward block

- **FR-010**: The cluster CoreDNS Corefile MUST be extended with a `ts.net:53` block that forwards to MagicDNS at `100.100.100.100`:
  ```
  ts.net:53 {
      forward . 100.100.100.100
  }
  ```
  This block MUST appear **before** any catch-all `forward .` block in the Corefile. The change is reconciled by Flux through whatever mechanism currently manages the CoreDNS ConfigMap (verify via `kubectl get cm -n kube-system coredns -o yaml`).
- **FR-011**: After the CoreDNS change lands, any pod's `getent hosts <name>.tail5d550.ts.net` MUST return the correct MagicDNS-provided 100.x address. Verifiable from a generic curl-capable test pod.

#### Rolling upgrade procedure

- **FR-012**: Node upgrade to the new schematic MUST be **one node at a time**, in a deterministic order (e.g. `ms01-a` → wait for healthy → `ms01-b` → wait for healthy → `ms01-c`). Concurrent upgrades MUST NOT happen.
- **FR-013**: After each node's upgrade, the operator MUST verify (a) `tailscale status` from a tailnet client shows the upgraded node online with `tag:talos-ii-node` and the two advertised routes, (b) at least one pod-to-tailnet curl from a pod scheduled on the upgraded node succeeds, (c) `kubectl get nodes` shows the upgraded node `Ready`, (d) no pods are stuck in `Pending` or `CrashLoopBackOff` due to the upgrade.
- **FR-014**: A rollback procedure MUST be documented: re-pin the prior schematic ID (`5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`) in `talos/talconfig.yaml` and re-apply. Because the installer image is content-addressable, this is mechanically straightforward; the operator MUST also be aware that the OAuth-minted device records will be orphaned in the Tailscale admin UI (cleanup is operator-deletion, low-stakes).

#### Validation

- **FR-015**: Validation procedure MUST cover, in order: (1) `tailscale status` from a tailnet client shows 3 nodes with `tag:talos-ii-node` and advertised routes `10.44.0.0/16,10.55.0.0/16` (subnet route status `active`), (2) `getent hosts attic.tail5d550.ts.net` from a generic test pod resolves correctly, (3) `curl http://attic.tail5d550.ts.net/` from a generic test pod succeeds, (4) `curl http://<pod-ip-on-ms01-c>:<port>/` from a tailnet laptop succeeds via subnet router on ms01-a (verifiable by entry-node's tailscaled logs), (5) reboot ms01-a; observe failover within <30s; reboot ms01-b; same; reboot ms01-c; same.
- **FR-016**: All five validation steps (FR-015) MUST be runbook-tracked. They are NOT optional smoke tests; any failure aborts the rollout and triggers FR-014's rollback.

#### Documentation

- **FR-017**: The same commit chain MUST land:
  - The new ADR `docs/decisions/talos-ii/0014-tailscale-subnet-router.md` recording the implementation choice (HA 3-node, OAuth+tag, advertise both CIDRs) with cross-link to shared/0002 acceptance.
  - An operator runbook section under `docs/operations/` (new file or extension to existing) covering deploy / verify / rollback / decommission.
  - Update to `docs/cluster-definition.md` recording the new node-level Tailscale capability and the `tag:talos-ii-node` identity.
  - Update to `docs/talos-image-factory.md` per FR-003.
- **FR-018**: The new ADR MUST cross-link to:
  - `shared/0002` (mesh integration modes, accepted) — the parent ADR.
  - `shared/0003` (talos-i positioning) — explains why mesh becomes cluster fabric.
  - `shared/0004` (cluster egress gateway) — explains the `route_exclude_address` interaction documented in Edge Cases.
  - `talos-ii/0004` (official factory) — the constitutional basis for which extension catalog is permitted.
  - `talos-ii/0005` (Secure Boot) — the boot-mode constraint that determines schematic submission parameters.

#### Non-goals (negative requirements)

- **FR-019**: This spec MUST NOT modify or remove the existing `tailscale-operator` deployment in `kube-system` (or wherever it currently lives). The operator continues serving per-Service named ingress; the extension is additive.
- **FR-020**: This spec MUST NOT touch talos-i, swarm-01, or any artifact under `/home/beacon/swarm-01/`. talos-i adoption is the separate work tracked under shared/0003.
- **FR-021**: This spec MUST NOT propose Constitution §VII amendment in this commit. The operator-vs-extension complementarity is captured in shared/0002's accepted ADR; the cross-link in FR-017's ADR is sufficient. If a future operator concludes §VII's wording needs tightening, that is a separate Constitution-amendment ADR. (The stale "rejected for talos-ii" footnote in `docs/talos-image-factory.md` IS in scope, per FR-003.)

### Key Entities

- **Talos schematic (talos-ii)**: The image-factory recipe. Currently `5456009e...` with three sidero extensions; this spec adds `siderolabs/tailscale` to that list, producing a new SHA256 schematic ID.
- **`siderolabs/tailscale` system extension**: An official sidero Talos extension that ships `tailscaled` as a host-level service. Runs in the Talos host network namespace; provides node-level tailnet membership.
- **Subnet router**: The role each ms01-* node plays in the tailnet. Subnet routers advertise routes to non-tailnet CIDRs (here, the cluster's PodCIDR + ServiceCIDR) so tailnet members can reach those CIDRs via the router. With three routers advertising the same routes, Tailscale picks one for any given destination (failover free).
- **Tailscale OAuth client**: A long-lived credential created once in the Tailscale admin console with scope `auth_keys:write` and tag `tag:talos-ii-node`. The client_id + client_secret are SOPS-encrypted in this repo. Node-side `tailscaled` uses these to mint short-lived ephemeral auth keys at boot, registering itself under the tag.
- **`tag:talos-ii-node`**: The Tailscale tag identifying every ms01-* node device in the tailnet. ACLs key off this tag; multiplicity (3 devices vs. 1) is invisible at policy level. Future `tag:talos-i-node` is the analog for talos-i, distinct so per-cluster ACL rules are clean.
- **CoreDNS `ts.net:53` forward block**: The Corefile addition that makes `*.tail5d550.ts.net` (and any other `ts.net` zone if multi-tailnet were in scope, which it's not) resolve via MagicDNS at `100.100.100.100` from inside any pod.
- **Operator-managed `ts-*` proxy StatefulSets (existing)**: The in-cluster `tailscale-operator`'s per-Service ingress proxies. Continue running unchanged. Each gives a Service its own tailnet hostname (e.g. `attic.tail5d550.ts.net` → operator proxy → `attic` Service ClusterIP).
- **Talos machine-config patch (new)**: `talos/patches/global/machine-tailscale.yaml` (Plan stage confirms exact path). Configures the `siderolabs/tailscale` extension service with OAuth credentials, advertise-routes, accept-routes, hostname, and tag.
- **PodCIDR `10.44.0.0/16` / ServiceCIDR `10.55.0.0/16`**: Per Constitution III. These are the routes advertised by the subnet routers. Confirmed against `talos/talconfig.yaml` lines 20-21.
- **sing-box DaemonSet (existing, talos-ii)**: External dependency. Already running on all three ms01-* nodes (shared/0004 Phase 2). Its `route_exclude_address` configuration MUST cover `100.64.0.0/10` (CGNAT) so pod-to-tailnet packets are not captured by `auto_redirect`. NOT modified by this spec unless the exclusion is currently missing — then the spec includes the addition.
- **Tailscale tailnet `tail5d550.ts.net`**: The tailnet identity for this operator's Tailscale account. All hostnames resolved here are scoped to this tailnet.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `tailscale status` from a tailnet client shows exactly 3 devices with `tag:talos-ii-node`, all online, all advertising routes `10.44.0.0/16,10.55.0.0/16` with subnet-route status `active`.
- **SC-002**: `getent hosts attic.tail5d550.ts.net` from any pod on talos-ii returns a 100.x MagicDNS address with no error. The same lookup from a node host shell also succeeds (host extension's `tailscaled` provides identical resolution).
- **SC-003**: `curl -fsS http://attic.tail5d550.ts.net/` from any pod on talos-ii returns HTTP 2xx. attic-side request logs show the source as one of the three ms01-* subnet routers' 100.x addresses.
- **SC-004**: `curl -fsS http://<pod-ip-on-talos-ii>:<port>/` from a tailnet laptop returns the pod's response. The packet enters via one of the three subnet routers (verifiable by entry-node tailscaled logs or `tcpdump` on the entry node's tailscale0 interface).
- **SC-005**: A controlled reboot of any one ms01-* node disrupts an in-progress curl loop (Story 1 setup) for at most 30 seconds before the loop resumes via the remaining two routers. Repeated for all three nodes in turn, in separate runs, each meets the same characteristic.
- **SC-006**: After the deploy, the existing `tailscale-operator` deployment in kube-system has identical `ts-*` StatefulSet count and Ready state as pre-deploy. `attic.tail5d550.ts.net` (and any other operator-exposed Service) resolves to the operator proxy IP, NOT a router-node IP.
- **SC-007**: `docs/talos-image-factory.md` lists the new active schematic ID with `siderolabs/tailscale` in the extension list. The prior `5456009e...` is moved to "Historical schematics — talos-ii" with the supersession date. The "Tailscale: host extension vs in-cluster operator" footnote is rewritten to reflect both being in use complementarily.
- **SC-008**: ADR `docs/decisions/talos-ii/0014-tailscale-subnet-router.md` exists, is cross-linked to shared/0002, shared/0003, shared/0004, talos-ii/0004, talos-ii/0005, and is referenced from `docs/index.md` if the index uses an ADR list.
- **SC-009**: Constitution check (see section below) passes — no §VII rewrite is required, no §IV violation, no surprise reboot beyond the planned one-at-a-time roll. SC-010 enforces this.
- **SC-010**: The full deploy (3 nodes upgraded sequentially) introduces zero unplanned reboots. Each upgrade is pre-declared in the runbook; any reboot outside the runbook is a defect.

## Assumptions

- **shared/0002 acceptance is final**: The 2026-05-04 acceptance of Option C is the basis for this spec; no further ratification is needed.
- **shared/0004 Phase 2 (sing-box DS) is operational on all 3 nodes**: Otherwise the `route_exclude_address` precondition discussed in Edge Cases needs a different framing. If shared/0004 is partial at deploy time, the verification step expands to confirm `100.64.0.0/10` exclusion on all running sing-box instances at minimum.
- **Tailscale tenant `tail5d550.ts.net` is in good standing**: OAuth client creation, ACL editing, and Magic DNS all assume a working tailnet. This is an existing operator dependency, not a new risk.
- **`tailscale-operator` already healthy**: The in-cluster operator is currently reconciling per-Service ingress on talos-ii. This spec adds to it; if the operator is degraded pre-deploy, that's a separate troubleshooting task.
- **Talos PCR Secure Boot keys in use are stable**: The new schematic submitted with `secureboot=true` will be signed under the same key bundle as the current schematic. No SBKey rotation is part of this spec.
- **MS-01 hardware headroom for tailscaled**: Each node gets ~30-50 MB additional RSS for `tailscaled` and one TUN device. Negligible on 64GB-RAM MS-01 nodes; not a sizing concern.
- **CoreDNS Corefile is editable via the standard ConfigMap path**: If a different management mechanism is in place (e.g. Cilium DNS proxy intercepting), Plan stage adapts the FR-010 implementation accordingly without changing the spec's intent.
- **No NetworkPolicy default-deny is active on talos-ii**: A future opt-in default-deny would have to whitelist pod-to-100.64.0.0/10 explicitly. Not in scope; flagged for future awareness.
- **Operator workstation (laptop) is already a tailnet member**: Stories 2, 3, 4 verification require a tailnet-side client. If a laptop is not yet enrolled, that's an operator setup task, not part of this spec.

## Out of Scope

This phase does **not** do these things, deliberately:

- **talos-i adoption or any talos-i config changes.** Tracked under shared/0003. When talos-i adopts, it gets its own analogous spec, its own tag (`tag:talos-i-node`), its own OAuth client (or the same one with both tags — Plan stage of that future spec decides).
- **Cross-cluster ACL rules** between `tag:talos-ii-node` and (future) `tag:talos-i-node`. ACLs in this spec only declare `tag:talos-ii-node` and grant subnet-router permission for it. Cross-cluster opens up at talos-i adoption.
- **Migration to a self-hosted tailnet control plane** (Headscale or NetBird). shared/0003 sub-decision (2) defers this; implementation lives in `/etc/nixos`, not this repo. The OAuth-client-based registration in this spec is structurally compatible with both control planes (control-plane-agnostic at the protocol level).
- **NetworkPolicy default-deny rollout** with explicit pod-to-100.64.0.0/10 carve-outs.
- **Removal of the in-cluster `tailscale-operator`**. Operator stays. Period. Per FR-019.
- **Constitution §VII rewrite.** The cross-link to shared/0002 captures the operator-extension complementarity. A future operator may decide §VII wording needs tightening; that's a separate Constitution-amendment ADR, not bundled here.
- **`tailscale serve` on subnet-router nodes** as an alternative to operator-managed per-Service ingress. shared/0002's "Open questions deferred" lists this; not decided here. Operator stays the per-Service ingress mechanism.
- **`siderolabs/binfmt-misc` extension** (cross-arch CI builds). Mentioned in `docs/talos-image-factory.md` as a future trigger. Out of scope; would be its own spec when the cross-arch CI workload arrives.

## Open Questions

The three ADR-level open questions (HA topology / auth / routes) are resolved in "Decisions Resolved" near the top. The items below are residual Plan-stage refinements, not spec-stage blockers:

- **Exact Talos extension config syntax**: The `siderolabs/tailscale` extension takes its config via Talos's `extensionsServiceConfigs` (or equivalent) machine-config field. Plan stage confirms the exact YAML shape from sidero docs and produces the patch matching FR-007's content. The OAuth-client-credentials wiring in particular — env vars vs. file vs. machine-files patch — is the main detail to settle.
- **CoreDNS ConfigMap management mechanism**: Most likely the cluster's CoreDNS is managed by the Cilium-installed Corefile pattern or a Helm-chart values file under `kubernetes/apps/`. Plan stage identifies the exact source of truth and produces the FR-010 patch in the right place.
- **`route_exclude_address` audit on existing sing-box DS**: Per Edge Cases, sing-box's config MUST already exclude `100.64.0.0/10`. Plan stage verifies by reading the sing-box DaemonSet's ConfigMap on talos-ii. If missing, the addition lives alongside this spec's PR (or is a precursor PR if the operator wants strict separation).
- **Operator workstation tailnet enrollment status**: If not currently enrolled, that's an operator-setup precondition. Documented in the runbook (FR-017) but not blocking the spec.
- **Hostname pattern for node devices**: `talos-ii-${HOSTNAME}` (yielding `talos-ii-ms01-a` etc.) vs. just `${HOSTNAME}` (`ms01-a`). Plan stage decides; the prefix avoids collisions if future tailnet clients also include a generic `ms01-a`.
- **Whether to also configure `tailscale set --auto-update`** (or an equivalent) for unattended package updates of `tailscaled` itself. The sidero extension version is pinned via the schematic; updates to `tailscaled` come via schematic re-submission. Plan stage confirms this is the cleanest update path (it is, per Constitution §IV — schematic discipline).
- **Validation step automation**: FR-015 lists 5 validation steps; whether to script them as a `task` target (e.g. `task talos-ii:tailscale-validate`) for repeatability is a Plan-stage Quality of Life decision.
- **shared/0002's "Open questions deferred" item on `tailscale serve`**: Not a Plan-stage question for THIS spec, but worth noting that this spec's HA-3-router design does NOT preclude later switching to `tailscale serve` on those routers. If/when that decision is made, it's additive on top of this work.

## Constitution Check

Cross-reference of this spec against the project constitution (`/.specify/memory/constitution.md`, version 1.1.0):

- **Principle I (Hypervisor stance, [talos-ii])**: PASS — no hypervisor changes; bare-metal stance preserved.
- **Principle II (Storage, [both])**: N/A — no storage component in this spec.
- **Principle III (Network, [talos-ii])**: PASS — Cilium remains the in-cluster CNI for PodCIDR `10.44.0.0/16` / ServiceCIDR `10.55.0.0/16`. The host-level `tailscaled` adds an overlay for cross-cluster mesh but does NOT replace Cilium's BPF datapath. Pod traffic that doesn't egress to tailnet is unaffected. The bond / VLAN 87 underlay is unchanged.
- **Principle IV (Image factory, [talos-ii])**: PASS — `siderolabs/tailscale` is an **official sidero extension** (per ADR talos-ii/0004 only the official factory and only its catalog are permitted on talos-ii). FR-001's schematic submission keeps `factory.talos.dev` as the source. FR-003 mandates `docs/talos-image-factory.md` update in the same commit, satisfying the schematic-transparency rule.
- **Principle V (Secrets, [both])**: PASS — OAuth client credentials are SOPS-encrypted (FR-004). No plaintext at rest in git. Machine-config patch decryption flows through SOPS at apply time per FR-009.
- **Principle VI (Public exposure, [both])**: N/A — nothing publicly exposed by this spec.
- **Principle VII (Private exposure, [both])**: PASS-with-clarification — Constitution §VII says "Private services use the in-cluster `tailscale` operator..." but does not forbid the host extension as a complement. shared/0002's accepted decision text explicitly frames operator + extension as complementary (operator = per-Service named ingress; extension = subnet router for cluster fabric + cross-cluster). FR-019 keeps the operator running. FR-021 declines a §VII rewrite; the cross-link in the new ADR captures the rationale. If a future operator concludes §VII's wording needs tightening, that's a Constitution-amendment ADR separate from this spec.
- **Principle VIII (GitOps, [both])**: PASS — schematic ID change is reconciled via `talos/talconfig.yaml` + standard `task talos:upgrade-node` flow (matching how other Talos changes happen). CoreDNS Corefile change is reconciled by Flux. SOPS-encrypted OAuth credentials are committed alongside the patch.
- **Principle IX (Spec-Driven Development, [both])**: PASS by construction — this is the `/specify` artifact for the change.
- **Principle X (Documentation, [both])**: PASS by requirement — FR-003 mandates `docs/talos-image-factory.md` update, FR-017 mandates ADR + runbook + cluster-definition updates, all in the same commit chain.
- **Principle XI (No surprise reboots, [both])**: PASS — three planned reboots, one node at a time, each pre-declared in the runbook (FR-012, FR-016). SC-010 enforces zero unplanned reboots as an explicit acceptance gate. Rolling order is deterministic; rollback path (FR-014) is documented.
- **Per-cluster scoping rule** (project memory `feedback_per_cluster_scoping.md`): PASS — Scope section above explicitly tags `[talos-ii]` only. FR-020 is the negative requirement asserting no talos-i / swarm-01 changes. Future talos-i adoption (shared/0003) gets its own spec with `[talos-i]` scope; the cross-cluster ACL rules are deferred to that adoption.
