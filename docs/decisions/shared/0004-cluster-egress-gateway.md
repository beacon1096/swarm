# ADR shared/0004 — Cluster egress gateway: transparent proxy via Cilium + sing-box

**Scope:** shared — primary target talos-ii; talos-i adopts the
same pattern at adoption time.
**Status:** accepted (Option C, Phases 1-2). Phases 3-4 amended
2026-05-05 — see "Amendment — 2026-05-05" section.
**Date:** 2026-05-04 (amended 2026-05-05)

## Context

This repo currently exposes its egress proxy (`sing-box` in the
`network` namespace) at a ClusterIP service URL
`http://sing-box.network.svc.cluster.local:7890`. Apps that need
to reach the public internet are expected to set `HTTP_PROXY` /
`HTTPS_PROXY` environment variables pointing at it. This works
when the application honors those variables — most curl / wget /
shell users / Bitbucket-style HTTP clients do.

It **fails** when the application doesn't honor the env. We've
hit two distinct cases:

1. **2026-05-03 nix CI failure** — Determinate Nix's daemon ran
   inside an `act` job container with `HTTPS_PROXY` set, but the
   daemon process did not inherit the variable when it spawned
   substituter downloads, fell back to direct DNS resolution,
   and got GFW-poisoned NXDOMAIN for `cache.nixos.org`. Workflow
   failed across all `nix build` substituter fetches.
2. **Prior Go-binary CI episode** — a Go-built tool inside a
   workflow ignored the proxy env entirely (Go's `net/http` only
   honors `HTTP_PROXY` for Go's own client, not for syscall-level
   dial paths used by some libraries), with the same symptom
   class.

Each case prompted a one-off workflow patch (set env at the
specific step, also pass `--option http-proxy ...` to the tool).
This pattern is structurally fragile: it requires every new
workflow / image / language ecosystem to re-prove env-honoring,
and forgetting to wire env breaks silently with poisoned-DNS
errors that look like ordinary network blips.

This ADR proposes replacing the **per-app env contract** with a
**cluster-level transparent egress gateway**: pods don't know a
proxy exists; the platform routes their outbound packets through
sing-box on dedicated egress nodes.

## Decision drivers

1. **Eliminate per-app proxy contract** — any image, any binary,
   any language. The platform should make `connect()` to the
   public internet "just work" without app cooperation.
2. **Solve GFW DNS poisoning at the platform layer** — currently
   every pod's CoreDNS query for `cache.nixos.org` /
   `googleapis.com` / etc. transits a poisoned upstream. Centralize
   DNS at sing-box (it already implements bypass strategies via
   geosite/SNI rules) so pods can't see poisoned answers.
3. **Per-namespace opt-in** — observability shouldn't accidentally
   route its scrape traffic through the egress gateway and
   self-deadlock when the gateway is down. Need granular control.
4. **Bounded blast radius** — the egress gateway becomes a Tier 0
   platform component (alongside CoreDNS, Cilium). HA, monitoring,
   and runbooks are non-optional.
5. **Talos-friendly** — implementation must not require unusual
   schematic extensions; ideally re-uses kernel features Talos
   already ships (TPROXY, conntrack, tun module).

## Options considered

### Option A — status quo: per-app `HTTPS_PROXY` env

How: every Deployment/HelmRelease values block sets
`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`. Apps that honor these
work. Apps that don't fail in a confusing way.

Cost to keep: low day-to-day; high tail-cost on every new
workflow/image (silent breakage, debug rounds). The 2026-05-03
nix incident is exactly this.

Verdict: **does not solve the problem** — it's the problem.

### Option B — per-pod sidecar (TUN or TPROXY) injected by webhook

How: a mutating admission webhook injects a sing-box sidecar +
init container that sets up TUN device or iptables REDIRECT
rules in the pod's netns. App container shares netns and routes
through the sidecar.

Pros: per-pod isolation; sidecar lifecycle tied to pod lifecycle;
no node-level shared state.

Cons:
- Mutating webhook is a new platform component with availability
  implications (webhook down = no new pods).
- TUN requires `/dev/net/tun` exposed (device plugin) and
  CAP_NET_ADMIN per pod.
- For the **forgejo-runner DinD case specifically**, the
  workflow containers are spawned **inside the dind container's
  netns**, not the runner pod's netns. A sidecar at the runner
  pod level doesn't help. The TUN/TPROXY would have to live
  inside dind, which means a custom dind image or invasive
  startup hooks. **This case alone is enough to rule out B.**
- Memory/CPU overhead per pod (sing-box sidecar ~30-60 MB).

Verdict: **rejected** — fails the dind-nesting case that
motivated this ADR.

### Option C — Cilium egress-gateway + sing-box DaemonSet on egress nodes

How:

```
[ pod (any namespace, no proxy env) ]
            ↓ default route
[ Cilium ]── CiliumEgressGatewayPolicy ──→ [ designated egress nodes ]
                                                       ↓ tc-bpf or
                                                       ↓ iptables NAT/TPROXY
                                              [ host-network sing-box DaemonSet ]
                                                       ↓ outbound rules
                                                       ↓ (geosite/SNI/dst-IP based)
                                              [ direct / cn-DERP / clash subscriptions / ... ]
```

Components:
- **sing-box DaemonSet** in `network` namespace, host network,
  `nodeSelector: egress=true`, with CAP_NET_ADMIN. 2-3 replicas
  on labeled nodes for HA.
- **CiliumEgressGatewayPolicy** CRs per namespace (or per
  `Selectors.PodSelector`) routing matched egress to the
  egress nodes' IPs. Cilium handles SNAT and routing.
- **DNS**: sing-box exposes a DNS server on the egress nodes;
  CoreDNS forwards external zones to it. On-cluster resolution
  (`*.svc.cluster.local`) stays unchanged — only public DNS
  queries go through sing-box. Avoids fakeip complexity in v1.
- **NetworkPolicy / safety**: explicit allowlist namespaces
  (`development`, `ai`, `media`, `nix`, `home` — whatever needs
  outbound). Observability and platform namespaces are NOT in
  the policy → they egress directly via cluster default route.

Pros:
- App-agnostic — no env, no sidecar, no awareness.
- Solves dind nesting trivially: Cilium intercepts at pod →
  cluster boundary, before any nested netns starts. dind's
  workflow containers see the same egress.
- Talos kernel already supports tc-bpf, TPROXY, conntrack —
  no schematic changes required.
- One platform component, not N sidecar instances.
- Namespace-scoped opt-in keeps blast radius bounded.

Cons:
- **Cilium egress-gateway redirects at IP/interface granularity
  only**, not at port. A `CiliumEgressGatewayPolicy` chooses an
  egress node + egress IP + outbound interface; the gateway node
  then SNATs and forwards onto the wire as ordinary IP traffic.
  It does **not** redirect packets to a specific local port on
  the gateway node. To deliver intercepted traffic into a
  sing-box listener (whatever the inbound type), the gateway
  node needs an additional layer of nftables rules in PREROUTING
  to capture the SNATted-but-not-yet-out packets and steer them
  to the local sing-box socket. The remaining design choice is
  **who writes those nftables rules** — see "Sing-box inbound
  selection for Stage 1b" below.
- **Cilium egress-gateway is a feature flag we haven't validated.**
  ~~Need PoC~~ Stage 1a passed 2026-05-04 (see below).
- New Tier 0 dependency. Egress-node hardware failures, sing-box
  daemon bugs, or Cilium policy misconfigurations now break
  outbound for matched namespaces.
- Debugging shifts from "app-level proxy logs" to "node-level
  sing-box logs + Cilium policy state + nftables rule state."
  Operators need new mental model + runbook.
- DaemonSet on egress nodes only (not all nodes) — node-affinity
  must be carefully kept in sync with the EgressGatewayPolicy
  (mismatch = blackhole).

Verdict: **recommended.**

### Option D — node-level sing-box DaemonSet without Cilium egress-gateway

How: sing-box on every node (not designated egress nodes), each
node iptables-redirects matching traffic to the local sing-box.
No Cilium policy involvement; pure node-level config.

Pros: simpler than Option C in concept; no Cilium feature flag
dependency.

Cons:
- iptables rules per-node need lifecycle management — what
  installs them, what cleans them up on rollout? An init
  privileged container is brittle on Talos.
- Per-namespace opt-in becomes hard — routing is at packet
  level, not at policy level. Either everything goes through
  sing-box (over-broad) or you re-implement Cilium's policy
  layer manually.
- HA story is "every node has its own sing-box" which means
  sing-box config sync across nodes (via flux), config drift
  risk, more moving parts.

Verdict: **rejected** — Option C's policy-driven approach is
materially better for the per-namespace opt-in requirement.

### Option E — service-mesh-driven (Istio/Cilium ServiceMesh L7)

Out of scope. Service mesh is a much larger commitment than is
warranted for the egress problem alone. If a mesh lands later
for other reasons, this ADR may be revisited.

## Comparison matrix

| Dimension                                     | A (env)        | B (sidecar)              | C (egress-gw)            | D (per-node) |
|-----------------------------------------------|----------------|--------------------------|--------------------------|--------------|
| Solves "app ignores proxy env"                | **no**         | yes                      | yes                      | yes          |
| Solves dind-nesting                           | partial        | **no**                   | yes                      | yes          |
| Per-namespace opt-in                          | per-app yaml   | per-pod annotation       | **yes (CRD)**            | hard         |
| New platform component(s)                     | none           | webhook + sidecar image  | egress nodes + DaemonSet | DaemonSet + iptables glue |
| Talos schematic change                        | no             | maybe (device plugin)    | **no**                   | no           |
| Existing tail-cost                            | high (silent)  | medium                   | low (centralized log)    | medium       |
| Debugging surface                             | every app      | every pod                | egress node logs         | every node   |
| Failure mode if egress component down         | apps just work | matched pods can't egress | matched ns can't egress  | every ns can't egress |

## Decision (proposed)

**Adopt Option C: Cilium egress-gateway + sing-box DaemonSet on
designated egress nodes.** Replace the per-app `HTTPS_PROXY` env
contract over time. Keep env-based path as a deprecated fallback
for one cycle to allow rollback during PoC.

Per-namespace opt-in. Initial allowlist (talos-ii):
`development`, `nix`, `ai`, `media`, `home`. Out: `kube-system`,
`flux-system`, `cert-manager`, `network`, `observability`,
`identity`, `collaboration`, `registry`, `default`.

DNS strategy: forward (CoreDNS → sing-box DNS), not fakeip, in
v1. Re-evaluate fakeip if SNI-only routing proves insufficient.

Egress nodes on talos-ii: **superseded by Stage 1a finding** —
talos-ii is 3-node hyperconverged (all control-plane). Initial
PoC labels `ms01-a` only as `role=egress`. Phase 2 decides
final HA labeling (likely all 3 nodes for symmetric HA, or 2 of
3 for some isolation buffer). CP co-tenancy with sing-box
DaemonSet is accepted (no workers exist on current hardware).

Subject to a PoC validating:
1. Cilium egress-gateway is enabled / enable-able in our
   `kube-system/cilium` HelmRelease values (v1.18+ or whichever
   we're on)
2. CiliumEgressGatewayPolicy CR is recognized
3. Test pod in `default` namespace egresses through the labeled
   node and reaches `https://cache.nixos.org/nix-cache-info`
   without env vars
4. Same test from inside DinD spawned in a forgejo-runner-style
   pod also works
5. Failure mode: when sing-box DaemonSet is paused, matched
   namespaces fail closed (no leak to direct egress)

## Implementation impact

Sequenced phases. Each is a separate PR.

**Phase 1 — PoC** (pre-acceptance):
- Identify our Cilium version + whether `egressGateway.enabled`
  is set. Edit `kubernetes/apps/kube-system/cilium/` if needed.
- Label two MS-01 workers `role=egress`.
- Apply a single `CiliumEgressGatewayPolicy` matching a temp
  namespace `egress-test`.
- Run a curl-from-pod check; tear down.

### Stage 1a result (2026-05-04)

Executed and **passed**, with two amendments to original assumptions:

1. **Cluster shape correction**: talos-ii is 3-node hyperconverged
   (all `control-plane`); there are no dedicated worker nodes.
   The original ADR assumption "label 2 dedicated workers" is
   superseded — labeling control-plane nodes as `role=egress` is
   the only realistic path on current hardware. CP co-tenancy
   accepted (operator decision 2026-05-04). Stage 1a labeled
   `ms01-a` only; Phase 2 will need to decide HA replica count.

2. **Cilium helm key correction**: the working values key is
   `egressGateway.enabled` (not `enable-ipv4-egress-gateway`,
   which is what the rendered cilium-config key looks like). The
   chart sets the cilium-config key as `enable-egress-gateway`.
   PR `cb88ec3` flipped this on; CRD
   `ciliumegressgatewaypolicies.cilium.io` installed cleanly.

3. **CiliumEgressGatewayPolicy spec needed `egressIP` and
   `interface` explicitly**: with only `nodeSelector`, the BPF
   egress map shows `Egress IP: 0.0.0.0` and SNAT does not apply
   correctly. Setting `egressIP: 172.16.87.201` and
   `interface: bond0.87` (the VLAN-tagged bond on talos-ii MS-01
   nodes) made the BPF map populate fully. Phase 2 policies must
   include both fields.

**Verification evidence:**

- BPF egress map on source node (`ms01-b`) shows source pod IP
  `10.44.2.85` → destination `0.0.0.0/0` → Egress IP
  `172.16.87.201`, Gateway IP `172.16.87.201` (= ms01-a). ✓
- `curlbox` pod (in `egress-test` ns, scheduled on `ms01-b`) →
  `http://223.5.5.5/`: HTTP 404 received (TCP/HTTP path works
  end-to-end through the egress-gateway). ✓
- `echo` pod (in `default` ns, no egress-gateway policy match)
  → `http://223.5.5.5/`: HTTP 404 received (control: default
  cluster routing also works for China-reachable destinations). ✓
- `1.1.1.1` was unreachable from any pod regardless of policy
  or protocol — both `http://1.1.1.1/` and `https://1.1.1.1/`
  timed out from a non-policy pod. Diagnosed as IP-level
  blocking somewhere on the upstream path (home router or ISP),
  not an egress-gateway issue. **Note for future PoC work:**
  1.1.1.1 (and likely 8.8.8.8) is **not** a viable end-to-end
  test target on this network; use `https://www.cloudflare.com/cdn-cgi/trace`
  or whatever the matching outbound proxy can actually reach.
  Logged for later investigation but does not affect ADR
  conclusions.

Stage 1a teardown complete: `egress-test` namespace and the
test policy were deleted before commit. The Cilium HelmRelease
change (`egressGateway: enabled: true` in
`kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`)
remains — the CRD is installed and ready for Phase 2.

### Sing-box inbound selection for Stage 1b

The four sing-box transparent-proxy inbound types were
evaluated against our constraints (host-network DaemonSet on a
gateway node that must keep its own egress functional):

| inbound | UDP | host-route impact | who writes nftables | verdict |
|---|---|---|---|---|
| `tun` + `auto_route: true` | yes | **steals host default route → bricks node** | sing-box | **rejected** |
| `tun` + `auto_route: false` | yes | none | operator (manual) | possible but no advantage over tproxy |
| `tun` + `auto_redirect: true` | yes | none | **sing-box (auto-generated nftables)** | **primary candidate** |
| `tproxy` | yes | none | operator (manual) | **fallback baseline** |
| `redirect` | **no** (TCP only) | none | operator (manual) | rejected (need UDP for DNS) |

**Primary candidate: `tun` + `auto_redirect: true`** — sing-box
generates the nftables rules itself. Per upstream docs the
mechanism is generic Linux nftables; the OpenWrt fw4 hook is
*additional* compatibility, not the only target. Configuration
shape:

- `tun.auto_redirect: true`
- `tun.route_address_set` / `tun.route_exclude_address_set`
  point at sing-box rule-sets (e.g. geosite-cn excluded,
  everything-else captured)
- `tun.auto_redirect_input_mark` / `auto_redirect_output_mark`
  default to `0x2023` / `0x2024` — verify no collision with
  Cilium's own fwmarks during PoC
- DaemonSet must mount `/dev/net/tun` (device plugin or
  `hostPath`) and have CAP_NET_ADMIN

**Fallback baseline: `tproxy` + manual nftables.** If
`auto_redirect` PoC reveals incompatibility with Talos /
Cilium / our specific routing topology, fall back to writing
the nftables rules ourselves. The rule shape is roughly:
`PREROUTING ... ip saddr <pod-CIDR> ip daddr != <cluster-CIDRs>
meta mark set 0x... ip rule lookup <table> + ip route ... lo
table <table> + nft TPROXY :<port>`. More fragile, more
operator-owned, fully predictable.

**Decision sequencing for Stage 1b:**

1. **30-90 minute spike**: rebuild sing-box k8s OCI image with
   `tun.auto_redirect: true` and a minimal rule set. Deploy
   to a single labeled node. Inspect `nft list ruleset` after
   sing-box starts; confirm: (a) rules generated as expected;
   (b) host's own egress unaffected; (c) Cilium-forwarded
   packets get steered into TUN; (d) no fwmark collision with
   Cilium.
2. **If spike succeeds**: Phase 2 proper goes with the TUN
   `auto_redirect` design. Document `nft list ruleset` baseline
   so future drift is detectable.
3. **If spike reveals problems**: Phase 2 falls back to TPROXY
   inbound + operator-written nftables rules. Capture root
   cause in a follow-up section here.

### Stage 1b spike result (2026-05-04, ad-hoc — without image rebuild)

A lighter-weight spike was run **without** rebuilding the k8s
sing-box OCI image: a `hostNetwork` Pod scheduled on `ms01-a`
ran the existing `init`-tag sing-box binary against an inline
ConfigMap config containing only `tun.auto_redirect: true`,
`auto_route: true`, no `route_address_set` (i.e. default scope).
`/dev/net/tun` was made available via `hostPath` mount — Talos
exposes the device with mode `0666`, no schematic changes
required. Findings:

1. **`auto_route` is a hard prerequisite for `auto_redirect`**.
   sing-box exits with `FATAL ... auto_route is required by
   auto_redirect` if it isn't set. The two flags work together,
   not as alternatives.

2. **The selective-routing design works as hypothesized**.
   sing-box installs:
   - `ip rule add fwmark 0x2023 lookup 2022` (priority 9001)
   - `ip rule add fwmark 0x2024 lookup unspec local` (9000)
   - `ip rule add lookup 2022` at priority 32768 (after main
     and default tables)
   - default route in table 2022 via the TUN device

   The host's main table default route (`default via
   172.16.87.254 dev bond0.87`) is **preserved**. Only marked
   packets get steered into table 2022. Host's own egress
   verified working during the spike (`wget http://223.5.5.5/`
   from a sidecar in the same Pod returned HTTP 404).

3. **No fwmark collision with Cilium**. Cilium's BPF SNAT uses
   the mask `0x200/0xf00`; sing-box uses `0x2023` / `0x2024`.
   Non-overlapping. Adjacent `ip rule` priorities did not
   conflict. ✓

4. **Default scope (empty `route_address_set`) is "capture
   everything"**. sing-box's `auto_redirect` nftables rules
   without an explicit scope marked all forwarded and locally
   originated traffic — host-LAN, intra-cluster pod-to-pod,
   DNS, etc. — all visible in sing-box logs as `inbound/tun
   redirect connection from 172.16.87.201:...` etc. With
   `direct` outbound, packets passed through correctly, but
   the selectivity we want for Phase 2 is absent.

   **Implication**: Phase 2's image rebuild MUST include
   `route_address_set` referencing scoped rule-sets (likely
   `geosite-cn` excluded with everything else captured, or
   the inverse). Without the scoping clause we'd unnecessarily
   intercept and re-emit half the cluster's traffic.

5. **`/dev/net/tun` available via `hostPath`** with mode 0666
   — no Talos schematic change, no device plugin needed for
   v1. Could revisit with a device plugin (`squat/generic-device-plugin`)
   if multi-pod sharing or non-privileged access becomes a
   concern.

**Spike verdict**: TUN + `auto_redirect` is the right choice.
The mechanism functions correctly on Talos with Cilium. The
remaining work for Phase 2 is bounded:

- Rebuild k8s OCI image with proper `route_address_set` scoped
  via the existing rule-set bundle (already baked into the
  shared `modules/common/sing-box.nix`), plus `auto_route: true`
  + `auto_redirect: true` swapped in for the current
  `mixed-in:7890`-only config.
- HelmRelease changes: Deployment → DaemonSet,
  `nodeSelector: role=egress`, `hostNetwork: true`,
  `CAP_NET_ADMIN`, `/dev/net/tun` hostPath mount.
- DNS strategy unchanged from earlier ADR text — CoreDNS
  forwards external zones to sing-box; fakeip remains a
  Stage 1c possibility.

TPROXY fallback remains documented as Plan B but is not
expected to be needed.

**Phase 2 — Egress node + DaemonSet** (after spike):
- Move sing-box from a single Deployment in `network` ns to
  a DaemonSet on `role=egress` nodes. Existing
  `sing-box.network.svc.cluster.local:7890` Service stays for
  the deprecation cycle (point at the DaemonSet pods).
- Add CoreDNS forward block for public zones → sing-box
  internal DNS service. Keep cluster-local zones unchanged.
- DaemonSet container needs `/dev/net/tun` (device plugin or
  hostPath) regardless of which inbound (tun) — TPROXY does not
  need `/dev/net/tun` but adding the device plugin DaemonSet
  once costs little and keeps the door open.

**Image tag convention** for the rebuilt sing-box OCI image
during Stage 1b (and any subsequent manual rebuilds before CI
takes over):

- Use `tproxy-YYYY-MM-DD` for manual builds during the
  transparent-proxy bring-up period (e.g. `tproxy-2026-05-04`),
  regardless of whether the inbound ends up being tun-redirect
  or tproxy. The prefix marks "this image has transparent-proxy
  config" and disambiguates from any legacy date-only tags.
- Once CI takes over the image build (post-Phase 4 stability),
  drop the prefix and use plain `YYYY-MM-DD` (or whatever
  CI-driven tag scheme lands at that time).

**Phase 3 — Per-namespace policies**:
- Add `CiliumEgressGatewayPolicy` resources, one per allowlisted
  namespace.
- Verify each app in those namespaces still works (they should,
  since direct egress now transparently routes through sing-box).

**Phase 4 — Workflow patch removal**:
- Remove `HTTP_PROXY`/`HTTPS_PROXY` env from forgejo-runner's
  `container.envs`, app HelmReleases, etc. — but only after
  a stability burn-in (≥1 week post Phase 3).
- Specifically: the `/etc/nixos/.forgejo/workflows/build-and-push.yaml`
  step env we'd otherwise patch in this session can stay
  un-patched if Phase 3 lands first.

**Phase 5 — talos-i adoption**:
- Per shared/0003, talos-i adopts the same pattern at offsite-
  move time. Same DaemonSet, same egress-node labeling
  (with smaller node pool given NEC8 constraints — likely 1
  egress node, not HA, acceptable for offsite observability).

**Talos schematic**: no changes. tc-bpf, TPROXY, conntrack
are already in the kernel. `siderolabs/tailscale` extension
(per shared/0002) is independent of this ADR.

**`docs/talos-image-factory.md`**: no changes (no schematic
delta).

**Constitution interaction**: Principle VII (VLAN-internal
LB) is unaffected — the egress gateway is for outbound to
public internet, not inbound from VLAN.

## Trade-offs accepted

- **New Tier 0 component**. sing-box DaemonSet outage means
  matched namespaces can't egress. Mitigation: 2-replica
  DaemonSet, egress-node redundancy, monitoring (sing-box
  exposes prometheus metrics, easy to scrape).
- **Operator learning curve**. Debugging "why can't pod X
  reach the internet" now involves Cilium policy + sing-box
  config. Mitigation: runbook in `docs/operations/egress-gateway.md`
  written as part of Phase 2.
- **Dual-write window during deprecation**. Phases 2-4 mean
  some apps see both env-based and gateway-based egress paths
  simultaneously. Acceptable; sing-box is idempotent in this
  role.
- **Future fakeip migration risk**. v1 uses DNS forward; if
  geosite-by-SNI routing is too coarse for some destinations,
  fakeip becomes necessary. Migration is non-trivial. Flagged
  as a known unknown.

## Open follow-up (not blocking)

1. **Egress-node count and HA**: 2 nodes for talos-ii is a
   guess. Validate against measured throughput during Phase 2.
2. **Fakeip vs forward DNS** decision deferred to Phase 3 or
   later, once we have empirical data on routing failures
   under SNI-only.
3. **Outbound traffic from the egress nodes themselves**: the
   sing-box DaemonSet pods are host-network. Their outbound
   isn't intercepted by Cilium egress-gateway (it's already
   on the wire). DNS for sing-box itself uses host resolv.conf
   — needs sane host-level DNS config (likely the cluster's
   external resolver).
4. **Interaction with shared/0002 mesh**: pods exposed to the
   tailnet via tailscale-operator's ingress reconciler are not
   affected (those use a separate proxy pod). Pods that
   *consume* tailnet services (per shared/0002 Option C subnet
   router) get a 100.x.y.z route in their pod table; that
   traffic should NOT be intercepted by egress-gateway —
   `NO_PROXY`-equivalent for tailnet IPs needs a CiliumEgressGatewayPolicy
   exception or destination-CIDR carve-out. PoC must validate.

## Amendment — 2026-05-05

**Status of this amendment**: accepted, supersedes the original
"Phase 3" and "Phase 4" descriptions in the rolled-out plan. The
Decision (Option C) and Phases 1-2 are unaffected; the original
2026-05-04 PoC sections above are preserved as history.

### What changed empirically

During spec 003 (forgejo-runner on talos-ii) implementation on
2026-05-05, we attempted the originally documented Phase 3 path —
attach a `CiliumEgressGatewayPolicy` to a workload namespace, expect
the egress node's sing-box `auto_redirect` to transparently capture
the egress, no env required. It did not work, and the failure is
structural rather than a configuration issue.

The cluster runs Cilium with `enable-bpf-masquerade: true`. PodCIDR
egress masquerade goes through Cilium's BPF datapath (TC ingress/
egress on the veth), which **bypasses the host's netfilter
prerouting chain entirely**. sing-box `auto_redirect` registers a
netfilter prerouting hook (table `inet sing-box`) and depends on
packets traversing that chain to capture them. Cilium egress-gateway
chooses *which node* SNATs pod egress and *which IP* it SNATs to —
it does not insert the packet into netfilter prerouting on the
egress node. The two mechanisms run on disjoint datapaths.

The pattern that does work is **`hostNetwork: true` on the consumer
Pod**: the Pod sits in the host network namespace, so its egress
traverses host netfilter prerouting just like the sing-box DS Pod's
own traffic does. auto_redirect's prerouting hook fires, the in-
config `route` rules decide direct vs vmess, no env propagation, no
sidecar, no per-pod tailscaled. The forgejo-runner deployed
2026-05-05 (commit `6a997e1`) verifies this end-to-end: a no-proxy-
env `wget http://example.com/` from inside the runner Pod returns
HTTP 200 and the sing-box DS journal records the inbound capture,
for both 境外 (vmess outbound) and CN (direct via sing-box userspace).

A related sing-box config bug surfaced in the same investigation.
The Phase 2 image (`tproxy-2026-05-04g`) carried
`route_exclude_address_set: [geoip-cn]` in the K8s build (copy-paste
from the desktop sing-box config, where it makes sense). For host-
mode K8s consumers this excluded all CN-IP destinations from
auto_redirect *capture*, so even hostNetwork pods could not
transparently reach CN CDNs through sing-box's userspace direct
outbound — the packets never entered sing-box's routing engine at
all. The K8s image was rebumped to `tproxy-2026-05-05a` (commits
`/etc/nixos` `6f27ceb`, swarm `541d79f`) which drops that line. All
non-private destinations now enter sing-box userspace; sing-box's
in-config `route.rules` (geoip-cn → direct, else → vmess) decide
the outbound. The UID-based exclude in sing-tun's auto_redirect
prevents the loop concern.

### Phase 3 status: STRUCTURALLY UNREACHABLE in current cluster

The original Phase 3 — "per-namespace `CiliumEgressGatewayPolicy` +
sing-box auto_redirect on egress node = transparent intercept for
that namespace's PodCIDR pod traffic" — **cannot be reached** while
`enable-bpf-masquerade: true` is set on Cilium. Verified
2026-05-05: with a policy in place selecting the forgejo-runner
namespace and ms01-a as gateway, a no-env `wget http://example.com/`
from a PodCIDR pod in that namespace timed out, and the sing-box
journal had no record of the connection. Removing the policy did
not change behavior. The egress-gateway is doing its SNAT job
correctly; the packets are simply never offered to netfilter
prerouting on the gateway node.

Three options exist to unblock Phase 3 as originally framed; none
are taken in this amendment:

1. **Disable BPF masquerade cluster-wide.** Large blast radius —
   affects Cilium's connectivity behavior for all nodes and pods,
   not just egress consumers. Requires its own ADR.
2. **Different intercept mechanism on the BPF datapath.** Cilium
   L7 proxy operates at L7, not transparent at L3, and is out of
   scope for the egress problem alone (overlaps with Option E).
3. **Per-pod tailscaled / sing-box sidecar pattern.** Possible but
   complex; effectively re-opens Option B which this ADR already
   rejected for the dind-nesting case.

Until one of those is taken, PodCIDR workloads cannot use kernel-
level transparent egress. They must continue to rely on the env-
based proxy contract (with the hostNetwork escape hatch available
for workloads that justify it).

### Phase 4 re-framing: two-tier proxy contract

The original Phase 4 ("HTTPS_PROXY env retirement") is restated as
a two-tier contract:

- **hostNetwork pods** (sing-box DS itself, forgejo-runner, future
  CI executors / build agents): env not required. Kernel-level
  transparent egress via auto_redirect. HTTP_PROXY env may remain
  for tools that honor it but is no longer load-bearing.
- **PodCIDR pods** (most workloads: flux-instance, tailscale,
  matrix, attic, zot, future apps): the env-based proxy contract
  is retained **indefinitely** — until and unless a future ADR
  takes one of the three options above. This is not a temporary
  state; it is the steady-state contract for PodCIDR workloads
  on the current Cilium configuration.

Workloads choose their tier explicitly: `hostNetwork: true` is a
deliberate decision (PSA-privileged namespace, port-collision
discipline), not a default. Most apps stay on PodCIDR with env;
CI / build / sandbox workloads that need kernel-level intercept
opt into hostNetwork.

### Implementation deltas already landed

- 2026-05-05: sing-box DS image `tproxy-2026-05-05a` drops
  `route_exclude_address_set: [geoip-cn]` from the K8s build
  (commits: `/etc/nixos` `6f27ceb`, swarm `541d79f`).
- 2026-05-05: forgejo-runner Pod runs `hostNetwork: true` with
  `dnsPolicy: ClusterFirstWithHostNet` (commit swarm `6a997e1`).
  See ADR [talos-ii/0013](../talos-ii/0013-forgejo-runner-talos-ii.md)
  §2 and spec `003-forgejo-runner-talos-ii` for the full rationale
  including the parallel `act_runner` env-propagation finding.

No `CiliumEgressGatewayPolicy` resources are deployed in production
namespaces. The PoC policy from Stage 1a (`egress-test`) was torn
down at the end of that stage and was never replaced.

### Lessons for future ADRs / specs

- **Cilium BPF masquerade ↔ netfilter is the load-bearing fact** for
  this whole topic. Whenever a future design proposes kernel-level
  intercept of PodCIDR egress, the first question is "does this run
  on the BPF datapath or on netfilter, and which side does the
  intercept sit on?" Designs that assume the two interoperate
  transparently are wrong on this cluster.
- **sing-tun upstream bugs** in the auto_redirect rule-set pipeline
  forced workarounds during Phase 2 rollout: (a) `nftablesCreateAddressSets`
  EEXIST when `route_exclude_address_set` had ≥2 rule-set entries;
  (b) `setupNFTables` final-flush EEXIST when `route_exclude_address`
  contained `224.0.0.0/3`. Both reproduce on sing-box 1.13.9 and
  1.13.11. Workaround: static `route_exclude_address` without 224/3
  and at most one entry in `route_exclude_address_set` — and as of
  `tproxy-2026-05-05a`, no rule-set in that field at all.
- **Spegel `_default` registry mirror** in talos containerd config
  catches docker.io / `code.forgejo.org` pulls with `resolve`
  capability and returns 404 for un-cached images, treating that
  404 as definitive (no fallthrough to upstream). Any new chart
  that pulls from those registries must either pre-cache via
  `talosctl image pull` or pin the image to LAN zot directly at the
  HelmRelease level.
- **`hostNetwork: true` is the explicit opt-in tier for kernel-
  level intercept**; it should not be defaulted, and it carries its
  own constraints (PSA-privileged namespace, port-collision
  discipline, DNS via `ClusterFirstWithHostNet`). Specs that need
  it should call it out as a Decision item, not as an
  implementation footnote.

## References

- [shared/0002 — Mesh integration modes (accepted)](0002-mesh-integration-modes.md) — independent decision, both can ship in parallel
- [shared/0003 — talos-i positioning (accepted)](0003-talos-i-positioning.md) — gates talos-i adoption of this pattern
- [`docs/operations/sing-box-egress.md`](../../operations/sing-box-egress.md) — current sing-box deployment; will be updated when Phase 2 lands
- [`docs/operations/tailscale-operator.md`](../../operations/tailscale-operator.md) — adjacent egress-related operator
- 2026-05-03 nix `cache.nixos.org` failure — trigger
- prior Go-binary CI episode — second data point
