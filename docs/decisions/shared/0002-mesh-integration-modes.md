# ADR shared/0002 — Mesh integration modes for K8s clusters

**Scope:** shared — applies to talos-ii and talos-i (when adopted).
**Status:** accepted (2026-05-04)
**Date:** 2026-05-03 (proposed) / 2026-05-04 (accepted)

## Context

We use Tailscale to (a) expose selected in-cluster Services on the
tailnet for tailnet-member humans/laptops, and (b) provide a private
path between hosts that don't share an L2/L3 network. Today this is
implemented via `tailscale-operator` v1.96+ on talos-ii (and previously
on swarm-01 / will be on talos-i).

The 2026-05-03 forgejo-runner CI incident exposed a class of problem
the current setup doesn't solve: a **pod in cluster A** trying to
reach a **tailnet-exposed Service from cluster B**. Specifically,
forgejo-runner on talos-i tried `http://attic.tail5d550.ts.net/...`
and failed with `Could not resolve host: attic.tail5d550.ts.net` —
because:

1. talos-i pods are not tailnet members (they live in Cilium pod
   CIDR `10.42.0.0/16`)
2. talos-i CoreDNS has no forward rule for `*.ts.net`
3. Even if DNS resolved, talos-i pods have no route to the Tailscale
   CGNAT range `100.64.0.0/10`

The provisional workaround (use the public HTTPRoute URL
`https://nix.${SECRET_DOMAIN}/...`) puts large NAR uploads through
Cloudflare, hitting the 100MB body-size limit on the free tier and
defeating the original intent of "keep CI traffic on the tailnet."

We also anticipate **migrating off Tailscale to NetBird** (or another
WireGuard-based mesh) at some point — Tailscale's commercial pricing,
the cn-qcloud DERP fragility documented in the
[Tailscale ACL DERPMap memory](#), and the desire to self-host the
control plane all push that direction. The choice we make for
"how mesh integrates with K8s" determines how painful that migration
will be.

This ADR captures the three modes available, their migration surface,
and a proposed default — but defers the actual commitment until
talos-i is formally adopted into this repo (at which point we'll have
two clusters needing the same answer, making the decision real
rather than hypothetical).

## Decision drivers

1. **Cross-cluster pod-to-service reachability** — talos-i pods must
   reach talos-ii tailnet-exposed Services without per-app workarounds.
2. **Mesh-implementation portability** — switching tailscale → NetBird
   should not force a rewrite of every app that uses the mesh.
3. **Per-app friction** — adding a new tailnet-exposed service or a
   new consumer should not require bespoke YAML.
4. **Talos schematic discipline** — any node-level capability change
   touches `talos/clusters/<cluster>/talenv.yaml` and must update
   [`docs/talos-image-factory.md`](../../talos-image-factory.md) in
   the same commit (per the [conventions in `docs/index.md`](../../index.md#conventions)).
5. **Operational complexity at steady state** — we already maintain
   custom ProxyClass + sing-box NO_PROXY entries for cn-qcloud DERP;
   adding more controllers should be justified.

## Options considered

### Option A — `tailscale-operator` per-Service ingress + egress

How it works:

- **Ingress**: Service has `tailscale.com/expose: "true"` →
  operator spawns a `ts-<svc>-<hash>` StatefulSet in `network` ns
  running `tailscaled` userspace; the proxy joins the tailnet under
  hostname from `tailscale.com/hostname` and forwards inbound traffic
  to the backing Service. **This is what we use today** for attic,
  zot, forgejo on talos-ii.
- **Egress**: a placeholder Service with
  `tailscale.com/tailnet-fqdn: "attic.tail5d550.ts.net"` (no selector)
  → operator spawns an egress proxy pod, gives the Service a normal
  ClusterIP, makes `<svc>.<ns>.svc.cluster.local` resolve and route
  to that tailnet FQDN. **Not yet used** — would solve the
  forgejo-runner case if added on talos-i.

K8s surface: per-Service annotations only; operator owns the
StatefulSet/pod lifecycle.

NetBird migration cost: **high**. NetBird has no operator with this
feature surface (as of 2026 Q2 to my knowledge). Migrating means
removing all per-Service annotations and re-implementing exposure
via either (a) a hand-rolled NetBird DaemonSet/sidecar pattern, or
(b) one of the modes below. Each app's ks/HelmRelease changes.

### Option B — Pod as tailnet member via operator-injected sidecar

How it works:

- Add `tailscale.com/proxy-class: <name>` + a ProxyClass CR to
  Deployments that should join the tailnet directly. Operator
  injects a `tailscaled` sidecar; pod gets a 100.x.y.z address;
  pod's resolv.conf is rewritten to use `100.100.100.100`.
- This is **available** in tailscale-operator v1.96+ but explicitly
  marked experimental for non-Service workloads.

K8s surface: ProxyClass CR + per-Deployment annotation. Pod runs
`tailscaled` alongside the application container.

Pod-image requirement: none — sidecar is injected.

NetBird migration cost: **medium**. NetBird agent can run as a
sidecar with a wireguard interface; the pattern is the same shape
but the YAML is bespoke (no operator). Each Deployment needs a
small rewrite from "annotation" to "explicit sidecar spec."

### Option C — Talos system extension `siderolabs/tailscale` + subnet router

How it works:

- Add `siderolabs/tailscale` to the Talos schematic per cluster.
  `tailscaled` runs in the host network namespace on every node.
- One node (or all nodes, with HA via NodePool / multi-router) runs
  `tailscale up --advertise-routes=<pod-cidr>,<svc-cidr>
  --accept-routes` — the **subnet router** pattern.
- Effects:
  - Nodes are tailnet members (with 100.x.y.z addresses)
  - Pod-to-tailnet outbound: pod default route → node → host
    `tailscaled` → tailnet
  - Tailnet-to-pod inbound: tailnet client knows route to
    `10.42.0.0/16` via the subnet router, hits node IP → kube-proxy
    forwards to pod
- DNS: a single CoreDNS forward block per cluster:
  ```
  ts.net:53 {
      forward . 100.100.100.100
  }
  ```
  Pods can then resolve `*.tail5d550.ts.net` directly.

K8s surface: **zero per-app YAML.** Adding a new tailnet-exposed
service still uses Option A on the *exposing* side, but the
*consuming* side is just `curl http://attic.tail5d550.ts.net/...`
from any pod, no annotations.

Talos surface: per-cluster schematic ID changes.
[`docs/talos-image-factory.md`](../../talos-image-factory.md) MUST
update in the same commit. Constitution principle.

NetBird migration cost: **low**. The replacement is the equivalent
NetBird system extension or a NetBird agent DaemonSet. The
"subnet router" abstraction is identical between mesh
implementations — both are just WireGuard with a routing
announcement. Pod-side code (URLs, DNS) stays unchanged. One
per-cluster knob.

## Comparison matrix

| Dimension                                  | A (op ingress+egress) | B (pod-sidecar)        | C (Talos ext + subnet router) |
|--------------------------------------------|-----------------------|------------------------|-------------------------------|
| Touches Talos schematic                    | no                    | no                     | **yes** (per cluster)         |
| Per-app YAML for new consumer              | yes (egress Service)  | yes (annotation)       | **no**                        |
| Per-app YAML for new exposed Service       | yes                   | yes                    | yes (for inbound this is unchanged across options — A's ingress reconciler is still required) |
| Pod sees tailnet IPs directly              | no (proxied)          | yes                    | yes                           |
| NetBird migration cost                     | high                  | medium                 | **low**                       |
| Steady-state operator complexity           | medium                | medium-high (sidecar per pod) | low (one DaemonSet) |
| Affected by tailscale-operator outages     | yes                   | yes                    | partial (only ingress side)   |
| HA story                                   | per-Service ts pod    | per-Pod sidecar        | needs multi-node subnet router or per-node tailscaled |

Note: Option C does **not** replace Option A's *ingress* role —
something must still terminate inbound tailnet connections at the
right Service. If we adopt C cluster-wide, the natural follow-up is
to drop A's egress side (replaced by C's pod routes) but keep A's
ingress side for `tailscale.com/expose` semantics. Or: replace A
ingress with `tailscale serve` running on the subnet router node,
mapping tailnet hostname → node port. That's an additional decision,
not made here.

## Decision

**Adopt Option C as the default for cross-cluster pod-to-tailnet
reachability.** Keep Option A for inbound (tailnet-to-Service)
exposure. Don't use Option B unless a specific app needs its own
tailnet identity (rare).

### Acceptance context (added 2026-05-04)

Originally proposed 2026-05-03 with status "defer until talos-i
adoption". Two events made the decision load-bearing earlier than
expected:

1. **talos-i positioning shifted** to "observability + offsite
   backup, not necessarily co-LAN with talos-ii" (2026-05-04
   conversation). Cross-LAN means the mesh is no longer optional
   tooling — it is the cluster fabric. Pod-to-pod cross-cluster,
   observability scrape, backup replication all depend on it.
2. **Repeated proxy-env-fragility incidents** (2026-05-03 nix
   cache.nixos.org DNS poisoning under `HTTPS_PROXY` not honored by
   the nix-daemon; prior similar incident with Go binaries ignoring
   proxy env on a successful CI run). The proxy-via-env model is
   structurally fragile and motivates a separate egress-gateway
   ADR (shared/0003, in draft) — but that egress design assumes
   the mesh decision below is settled.

Status moved from `proposed` to `accepted` 2026-05-04. Subsequent
ADRs (talos-i positioning, egress-gateway, VLAN-LB rewrite) build
on top of this one.

Rationale:

- Solves the 2026-05-03 forgejo-runner case with zero per-app YAML
- Lowest NetBird migration cost — the part most likely to change
  in the next 12-18 months should be the cheapest to swap
- Keeps tailscale-operator's narrow responsibility to ingress
  reconciliation, where it earns its keep
- Constitutionally clean: schematic + image-factory update is a
  one-line per-cluster change

Trade-offs accepted:

- Subnet router becomes a SPOF unless we pick multi-node HA. Likely
  acceptable: tailnet outbound from pods is a CI/development concern,
  not on the user data path
- All pods can now reach all tailnet IPs unless we add NetworkPolicy.
  Default-deny posture would shift this to opt-in; not required for
  current threat model but worth noting

## Implementation impact

- Per cluster: edit `talos/clusters/<cluster>/talenv.yaml` schematic
  to add `siderolabs/tailscale` extension. Same commit MUST update
  `docs/talos-image-factory.md` (constitution requirement).
- Per cluster: choose subnet-router node(s) — likely a worker, not a
  control-plane, to avoid co-tenancy with etcd. Document in
  `docs/cluster-definition.md`.
- Per cluster: ExtensionServiceConfig or machine-config patch with
  `tailscaled` auth key (SOPS-managed).
- CoreDNS: forward `ts.net` → `100.100.100.100` (one Corefile patch
  per cluster).
- (Optional cleanup) Audit existing `tailscale.com/tailnet-fqdn`
  egress Services if any get added before this is accepted; remove
  them after C is in place.

## Migration cost estimate (Tailscale → NetBird)

| Option | Per-cluster work | Per-app work | Total touched files (rough) |
|--------|------------------|--------------|-----------------------------|
| A      | replace operator | rewrite every Service annotation; rewrite egress Services | ~30+ |
| B      | replace operator | rewrite every Deployment with NetBird sidecar spec | ~10 |
| C      | replace extension + DaemonSet/agent; CoreDNS forward swap | none | ~5 |

This is the strongest argument for C. Implementation cost of A and
C is comparable today; migration cost is not.

## Open questions (deferred)

- Whether to run subnet routers on every node (full mesh, more
  resilient, more tailnet noise) vs. dedicated 1-2 nodes. Likely
  per-cluster answer: talos-i full mesh (3 small nodes anyway),
  talos-ii dedicated routers (3 MS-01 + workload mix).
- Whether to keep Option A ingress reconciler, or replace with
  `tailscale serve` running on subnet router nodes. Decide when
  the friction of A becomes visible.
- NetBird control-plane self-hosting choice — affects whether the
  C migration also requires running netbird-management. Not in
  scope here.

## References

- [Tailscale operator docs](https://tailscale.com/kb/1185/kubernetes-operator) — ingress + egress + pod-sidecar modes
- [siderolabs/extensions](https://github.com/siderolabs/extensions) — the `tailscale` extension and its limitations
- [NetBird K8s integration](https://docs.netbird.io/) — current state, no operator
- 2026-05-03 forgejo-runner CI incident — trigger for this ADR (no separate write-up; conversation log only)
- [`docs/operations/tailscale-operator.md`](../../operations/tailscale-operator.md) — current per-Service exposure pattern
- [`docs/talos-image-factory.md`](../../talos-image-factory.md) — schematic discipline
