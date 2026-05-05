# ADR talos-ii/0014 — Tailscale subnet router via `siderolabs/tailscale` host extension

**Scope:** talos-ii. Adds a host-mode tailscaled to all 3 control-plane
nodes alongside the existing in-cluster `tailscale-operator`. Talos-i
will follow the same pattern when it onboards (different node tag,
different advertised CIDRs).
**Status:** accepted
**Date:** 2026-05-05

## Context

[shared/0002](../shared/0002-mesh-integration-modes.md) (accepted
2026-05-04) selected **Option C** for our cluster mesh: a host-mode
tailscaled subnet router on each Talos node alongside the in-cluster
`tailscale-operator`. The two layers play different roles:

| layer | what it does | identity per node |
|---|---|---|
| Host extension (this ADR) | one tailscaled per node, advertises podCIDR + svcCIDR onto the tailnet, runs in the host network namespace | `talos-ii-ms01-{a,b,c}` (one per node, ephemeral) |
| In-cluster operator | watches Services with `tailscale.com/expose: "true"` and provisions per-Service `ts-*` proxy pods | `tailscale-operator-talos-ii` (the operator's own node) plus a `ts-<svc>-<id>-0` per exposed Service |

Spec 004 (`specs/004-talos-ii-mesh-implementation/`) is the
implementation vehicle. This ADR records what we landed and the
non-obvious decisions we had to make along the way. Sub-decisions
addressed:

1. Which extension package (custom vs. siderolabs/tailscale).
2. How many subnet routers (HA shape).
3. Auth-key issuance + rotation lifecycle.
4. Per-node identity (`TS_HOSTNAME`) vs. shared identity.
5. Auth-key delivery mechanism (machine.files vs. ESC env, single
   global vs. per-node).
6. `--accept-routes` behaviour given local-LAN advertise overlaps
   from peers.
7. `--netfilter-mode=off` co-tenancy with Cilium kube-proxy-replacement.
8. CoreDNS forwarding for `*.ts.net` to MagicDNS (100.100.100.100).

## Decision

### 1. Use `siderolabs/tailscale` (the official Talos extension)

The Talos image factory ships an official `siderolabs/tailscale`
system extension that wraps containerboot. Picking the official
extension over a custom build keeps us inside ADR
[talos-ii/0004](0004-official-image-factory.md) ("Official Talos
image factory only, no custom extensions").

Schematic ID `012427dcde4d2c4eff11f55adf2f20679292fcdffb76b5700dd022c813908b07`
combines `siderolabs/tailscale` with our existing extension set
(intel-ucode, iscsi-tools, util-linux-tools).
[`docs/talos-image-factory.md`](../../talos-image-factory.md) is the
authoritative ID-to-extension reverse map; it's updated in the same
commit as the schematic change.

The extension exposes its config through the
`v1alpha1` `ExtensionServiceConfig` resource (`name: tailscale`),
not through arbitrary daemon flags. Anything that isn't in the
documented `environment` / `configFiles` contract isn't reachable
from a Talos machine config; this constraint matters for sub-decisions
5 and 6 below.

### 2. Three subnet routers, one per control-plane node

Tailscale subnet routing is **primary-with-failover** (control-plane
elects one of the advertising routers as primary; remaining routers
take over within ~30 s on primary loss). It's *not* load-balanced
across all routers. So three routers gives:

- HA against any single node going offline (rolling reboots, hardware,
  Talos upgrades),
- no per-flow load distribution — the primary gets all the traffic.

Three is also the minimum that survives a 1-of-N node loss without
falling to a single point of failure, which is what we already have
for etcd / control-plane. There's no benefit to running this on more
nodes than there are control-plane nodes; if talos-ii grows workers in
the future, we'd revisit only if a worker-side advertise becomes
necessary (currently no use case — workers can route to the
control-plane subnet routers via the cluster network).

### 3. OAuth client + ephemeral, tag-based ACL

Auth keys are issued via an OAuth client (Tailscale admin → Settings →
OAuth) with scope `auth_keys:write`, tagged `tag:talos-ii-node`. Each
node-issued key carries `?ephemeral=true&preauthorized=true`:

- **Ephemeral**: the node device auto-cleans from the tailnet when it
  disconnects (Talos shutdown / extension stop). Avoids zombie
  devices accumulating across reboots.
- **Preauthorized**: skips the manual approval step for new devices
  joining under this tag — `autoApprovers.routes[tag:talos-ii-node]`
  in the ACL JSON makes the advertised subnet routes auto-approve
  too, so nothing about a Talos node coming up needs an admin click.

The OAuth client is **separate** from the operator's OAuth client
(rotation 2026-05-05 split them). They use different scopes and tags:

| client | tag | scopes | used by |
|---|---|---|---|
| `kp8zGBZ91f11CNTRL` | `tag:talos-ii-node` | `auth_keys:write` | siderolabs/tailscale extension on each Talos node |
| `kJwBAM4ZsS11CNTRL` | `tag:talos-ii-operator` (operator self) + `tag:talos-ii-svc` (per-Service proxies) | `auth_keys:write`, `services:write` | in-cluster `tailscale-operator` |

The split followed an incident where an earlier shared-OAuth client
key (`kjnW4ZGxQi11CNTRL`) was scanned + flagged by GitHub for
landing as cleartext in `templates/overrides/.../cluster-secrets.sops.yaml.j2`
before that file was SOPS-encrypted. The key was revoked. See
`fix(security)!: rotate Tailscale OAuth client …` (commit `c60b680`)
for the rotation; cluster-secrets template is now `#{ var }#`-only,
no inline literals possible.

### 4. Per-node `TS_HOSTNAME`, no `${HOSTNAME}` substitution

Talos's machine config doesn't expand shell-style variables in
`ExtensionServiceConfig.environment[]`. So we ship three concrete
patches (`talos/patches/ms01-{a,b,c}/machine-tailscale.yaml`), one
per node, each with `TS_HOSTNAME=talos-ii-ms01-<a|b|c>` literal. The
choice was per spec 004 D4 — empirical confirmation that talhelper /
talos config parser don't templatize the value at apply time.

### 5. Auth-key delivery via a single SOPS-encrypted ESC env patch

`TS_AUTHKEY` lives in
`talos/patches/global/extension-tailscale-authkey.sops.yaml`,
SOPS-encrypted whole-file (matches the `talos/.*\.sops\.ya?ml`
creation_rule, `mac_only_encrypted: true`). Talhelper merges this
single global ExtensionServiceConfig fragment with the three per-node
fragments by `kind+name`, so each rendered `kubernetes-ms01-<x>.yaml`
ends up with all 6 env entries (`TS_HOSTNAME`, `TS_ROUTES`,
`TS_EXTRA_ARGS`, `TS_ACCEPT_DNS`, `TS_AUTH_ONCE`, `TS_AUTHKEY`).

The earlier attempt to deliver `TS_AUTHKEY` via `machine.files`
(writing `/var/etc/tailscale/auth.env`) was a misread of the
extension contract. The siderolabs/tailscale wrapper sources
`TS_AUTHKEY` from the service container's process env, not from a
host file. The file landed on disk but was never read; tailscaled
went into `NeedsLogin` until we moved the value into ESC env.
Documented so the next operator doesn't repeat the mistake.

### 6. `--accept-routes=false` (interim) — local-LAN advertise overlap is fatal

This is the load-bearing decision and the one the rollout actually
got tripped up by. Detailed mechanics live in
[`specs/004-talos-ii-mesh-implementation/findings-tailscale-lan-wedge.md`](../../../specs/004-talos-ii-mesh-implementation/findings-tailscale-lan-wedge.md).
Short version:

The home LAN's gateway (UCG-Pro) advertises `172.16.87.0/24` (the
LAN ms01-a/b/c are on) onto the tailnet so off-LAN tailnet devices
can reach LAN hosts directly. With `tailscale up --accept-routes`,
each ms01-* node *also* installed `172.16.87.0/24 dev tailscale0
table 52`. Tailscale's policy rule
`ip rule add priority 5270 lookup 52` runs **above** main table
priority 32766, so any ms01-* outbound to its own LAN was sent over
wireguard instead of bond0.87 — including kubelet's status push,
which immediately flipped the node `NodeNotReady`.

`--netfilter-mode=off` does **not** fix this — the route lives in
the kernel routing table, set via netlink, not in netfilter.
Disabling netfilter is independent and orthogonal (kept for sub-
decision 7; see below).

The interim fix is `--accept-routes=false` on `tag:talos-ii-node`.
Cost is that pod-to-tailnet still works for tailnet-CGNAT (`100.64/10`,
which is a baseline route tailscaled installs regardless of
accept-routes) but **not** for tailnet peers' advertised non-tailnet
subnets — i.e. cross-cluster pod-to-pod with talos-i won't work via
tailnet until we revisit. That's the spec 004 D3 use case, which is
on hold until talos-i is adopted (no actual loss today).

The targeted fix when talos-i lands is **server-side filtering via
ACL `routes` allowlist**:

```jsonc
"routes": {
  "tag:talos-ii-node": [
    "10.42.0.0/16",      // talos-i podCIDR
    "10.43.0.0/16",      // talos-i svcCIDR
    "100.64.0.0/10"      // tailnet baseline (always)
  ]
}
```

Then `tag:talos-ii-node` accepts only the prefixes it actually needs
and a future overlapping advertisement (UCG or anyone else) cannot
re-trigger the wedge. Reflipping `--accept-routes=true` on the node
side becomes safe in that regime. Tracked as an open item under spec
004 (Phase 8 / talos-i onboarding).

### 7. `--netfilter-mode=off`

Tailscale's default behaviour is to manage iptables/nft on the host
(`ts-input` / `ts-forward` / `ts-postrouting` chains, fwmark policy
routing). Cilium kube-proxy-replacement is the sole owner of host
nft on Talos in our setup; there's no value in tailscale also
trying. We pass `--netfilter-mode=off` and tailscale stays out of
nft entirely.

The cost is losing SNAT for advertised subnet routes — packets
egressing from podCIDR via tailscale0 keep the pod's `10.44.x.x`
source IP rather than being masqueraded to the node's tailnet IP.
This only matters for tailnet peers that don't `accept-routes`
(then the peer wouldn't have a return route to `10.44/16` and
replies would black-hole). In our private tailnet every peer is
either a controlled cluster node or a managed tailscale-operator
proxy pod, and they all accept routes, so the lost SNAT is
harmless today.

This decision is independent of #6: even with `--accept-routes=true`
in a later phase, we'd keep `--netfilter-mode=off`.

### 8. CoreDNS `ts.net` zone forwarding to MagicDNS

A pod that resolves `talos-ii-ms01-c.tail5d550.ts.net` (or any
tailnet MagicDNS hostname) should hit `100.100.100.100` (MagicDNS),
not the cluster's normal `forward . /etc/resolv.conf` upstream.
We added a separate server entry to the CoreDNS HelmRelease values:

```yaml
- zones:
    - zone: ts.net
      scheme: dns://
  port: 53
  plugins:
    - name: errors
    - name: cache
      configBlock: |-
        prefetch 5
    - name: forward
      parameters: . 100.100.100.100
      configBlock: |-
        policy sequential
```

`100.100.100.100` is reachable from each ms01-* node's host
network namespace (tailscaled installs the baseline `100.64/10`
route on tailscale0 regardless of accept-routes), and from podCIDR
via the same tailscale0 path through the host. We empirically
verified this end-to-end (pod 10.44.0.74 → MagicDNS lookup →
ping ms01-c tailnet IP, 1.7 ms RTT — see V5 in spec 004 Phase 6).

### 9. Documentation set

- This ADR.
- `docs/operations/tailscale-subnet-router.md` — the operations runbook
  for the host extension layer (sibling to `tailscale-operator.md`,
  which covers the in-cluster operator).
- `docs/cluster-definition.md` — schematic ID bumped, mesh row updated.
- `docs/talos-image-factory.md` — schematic ID + extension list updated
  in the same commit as the bump.
- `docs/index.md` — TOC entry for both new docs.
- `specs/004-talos-ii-mesh-implementation/findings-tailscale-lan-wedge.md`
  — kept as the long-form post-mortem of the wedge investigation;
  this ADR cross-links it for detail.

## Consequences

### Good

- One fewer chicken-and-egg path: the host subnet router is up before
  any pod runs, so the in-cluster `tailscale-operator` can come up
  with tailnet egress already in place. Previously the operator's
  `controlplane.tailscale.com` reach depended on cluster sing-box
  being ready, which depends on Cilium being ready, etc.; the host
  extension lives below all that.
- Cross-cluster reach (when talos-i comes up) doesn't need per-Service
  proxies — pods on either cluster see each other's podCIDR via
  tailnet, subnet-router-routed.
- Each Talos node is an independently-failover-capable subnet router;
  a single node loss is invisible to the tailnet within ~30 s.
- The OAuth-issued ephemeral key + autoApprovers pattern means rolling
  Talos nodes (reboot, reinstall, hardware swap) requires zero
  Tailscale admin clicks — node comes up, registers, advertises,
  approved. (The OAuth client must remain valid; OAuth client keys
  rotate per Tailscale's OAuth lifecycle, currently no expiry
  configured.)

### Bad / accepted trade-offs

- `--accept-routes=false` blocks cross-cluster pod-to-pod via tailnet
  until ACL `routes` allowlist work lands (sub-decision 6). No
  active workloads need this today; tracked as future work.
- `--netfilter-mode=off` loses SNAT for advertise-routes (sub-decision
  7); harmless today, becomes relevant only if a non-accept-routes
  tailnet peer ever talks to talos-ii pods directly — that scenario
  shouldn't arise in our private tailnet.
- siderolabs/tailscale's containerboot uses `tailscale set` (not
  `tailscale up`) on subsequent service restarts. `set` doesn't
  honour the full `TS_EXTRA_ARGS` set, so a flag change doesn't
  propagate without removing `/var/lib/tailscale/tailscaled.state`.
  We productised a one-shot privileged hostPath pod for that
  (documented in the runbook). Future-us could contribute a
  `TS_FORCE_REUP` knob upstream.
- Tailscale subnet routing is primary-with-failover, not
  load-balanced. Three nodes don't triple bandwidth; they buy us HA.
  This matches our needs (control-plane traffic, not bulk egress)
  but documenting so future-us doesn't expect otherwise.

## Alternatives considered

- **In-cluster tailscale-operator advertising the routes** (no host
  extension). Rejected because the operator is itself a pod, gated
  on Cilium + cluster DNS + sing-box; bringing tailnet up before any
  of those is what unwedges the bootstrap chicken-and-egg.
- **One subnet router on a single node** (no HA). Rejected for the
  obvious reason — node loss == cross-cluster pod-to-pod outage, and
  we already paid the cost of running tailscaled on all three to get
  HA.
- **siderolabs/tailscale on workers only**. Doesn't apply yet (no
  workers), but if we add workers later we'd keep subnet routing on
  control-plane nodes for the same reason etcd lives there.
- **Custom Talos image factory with our own extension build**.
  Rejected per ADR talos-ii/0004 (official factory only on talos-ii).

## Out of scope

- talos-i adoption flow (different schematic, different tag, ACL
  `routes` allowlist work) — covered when talos-i lands.
- Replacing tailscale with Netbird or similar — `findings-tailscale-lan-wedge.md`
  records the evaluation axis we'd use; no current intent to migrate.
- Re-enabling `--accept-routes` on `tag:talos-ii-node`. Tracked as a
  prerequisite for cross-cluster pod-to-pod via tailnet; decision
  block is the ACL `routes` allowlist work which is itself blocked
  on talos-i adoption.

## Status as of 2026-05-05

- 3/3 ms01-* nodes upgraded to schematic `012427dc…:v1.12.7`,
  ext-tailscale Running, advertising 10.44/16+10.55/16, tagged
  `tag:talos-ii-node`, online with new ephemeral identities
  (100.66.227.11, 100.113.40.40, 100.90.235.128).
- LAN wedge fully resolved with `--accept-routes=false`; verified
  by toggling UCG advertise on/off (no recurrence with accept-routes
  off).
- V5 (pod → tailnet end-to-end) verified: a podCIDR pod on ms01-a
  resolves a MagicDNS hostname for ms01-c and pings the tailnet IP
  with RTT ~1.7 ms (same-LAN path).
- `--netfilter-mode=off` confirmed harmless under current load
  profile.
