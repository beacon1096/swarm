# Findings — Tailscale `--accept-routes` + same-LAN advertise = wedged subnet router

**Date observed:** 2026-05-05 (Phase 5 ms01-a rollout, with two cycles of
  reproduction once the wrong root cause was eliminated).
**Status:** working notes; fold into ADR talos-ii/0014 + the operations
  runbook. Also relevant to a future Netbird migration evaluation —
  same class of subnet-router-on-host-netns issue.

## Symptom

After `siderolabs/tailscale` extension successfully joined the tailnet on
ms01-a (subnet routes 10.44/16+10.55/16 advertised, tag `tag:talos-ii-node`,
Connected), **anything LAN-side talking to ms01-a's host services hung**:

| Path                                                    | Result                                                     |
| ------------------------------------------------------- | ---------------------------------------------------------- |
| `nc -zv 172.16.87.201 50000` (apid TCP)                 | 3-way handshake succeeds                                   |
| `talosctl -n 172.16.87.201 version`                     | gRPC `read tcp …→172.16.87.201:50000: read: timeout`       |
| `kubectl exec` to any pod on ms01-a                     | `dial tcp 172.16.87.201:10250: i/o timeout`, hang          |
| Cluster control-plane → ms01-a kubelet                  | hung; eventually NodeNotReady (kubelet's outbound also wedged) |
| `talosctl -e 100.66.227.11 -n 100.66.227.11 version`    | works (tailnet path returned server version v1.12.7)       |

Three-way handshake succeeds means the kernel accepts the SYN; only the
ESTABLISHED stream's reply leg goes elsewhere. Cluster-internal pods on
ms01-a continued running fine — the issue was specifically host-service
egress hitting LAN destinations.

## Root cause

A peer on the same tailnet (UCG-Pro acting as a subnet router for
the home LAN) advertised the subnet `172.16.87.0/24`. With ms01-a
running `tailscale up --accept-routes`, that prefix landed in the host
kernel as:

```
ip route add 172.16.87.0/24 dev tailscale0 table 52
```

Tailscale also installs the policy rule:

```
ip rule add priority 5270 lookup 52
```

Priority 5270 is **above** the main table's 32766. So any packet whose
destination matches table 52 is sent to `tailscale0` *before* the main
table is consulted — even when the destination prefix is the host's
own LAN subnet, even when the packet is the reply leg of a TCP
connection that arrived via `bond0.87`.

Concretely:

```
LAN client (172.16.87.x) → ms01-a:50000  ← arrived via bond0.87
ms01-a kernel → reply src=ms01-a:50000, dst=172.16.87.x
              → ip rule 5270 match → table 52 → tailscale0
              → encrypted, sent over wireguard / DERP
              → arrives at client with src tagged as ms01-a's tailnet
                IP, asymmetric path → conntrack rejects → read timeout.
```

This also broke ms01-a's *own* outbound to the LAN gateway
`172.16.87.254`, which is how kubelet pushes its status to the Talos
apiserver VIP — once that started failing, the controller marked the
node `NodeNotReady`.

The wedge is fully deterministic: it activates the moment any peer
advertises a route covering ms01-a's LAN, and clears the moment that
advertisement is withdrawn (verified empirically by toggling the UCG
advertisement on/off).

## What we ruled out before getting to the right cause

A few hours of misdiagnosis went into this; recording the dead ends so
future-us doesn't repeat them.

- **Tailscale's nft chains (`ts-input`/`ts-forward`/`ts-postrouting`)**.
  I initially hypothesised that Tailscale's iptables/nft management was
  fighting Cilium's BPF kube-proxy-replacement and breaking the return
  leg via netfilter. We applied `--netfilter-mode=off` to confirm —
  the wedge persisted with iptables/nft entirely disabled. Netfilter
  was not the cause. (We kept `--netfilter-mode=off` anyway for
  unrelated good reasons; see "What we kept" below.)
- **DNS / bootstrapDNS reachability**. The first boot showed
  `controlplane.tailscale.com` lookups failing because the in-cluster
  sing-box DS hadn't finished starting yet on the freshly-rebooted
  node. Real, but transient and orthogonal — once sing-box came up,
  tailscaled retried successfully and authenticated.
- **Stale `/var/lib/tailscale/tailscaled.state` causing prefs not to
  apply on restart.** Real, but a subset of the next bullet — siderolabs's
  containerboot wrapper runs `tailscale set` on subsequent service
  restarts (not `tailscale up`), and `set` doesn't honour the full
  `TS_EXTRA_ARGS` set. Forcing a fresh `tailscale up` requires
  removing tailscaled's state directory between restarts. We
  productised that into a one-shot privileged hostPath pod
  (`forgejo-runner` namespace, hostPath `/var/lib/tailscale`) since
  Talos doesn't expose a shell or arbitrary `rm` over its API.
- **My workstation's own routing.** During later attempts I observed
  LAN failures from my sandbox shell that turned out to be sing-box
  on my workstation's own uid policy — not anything happening on
  ms01-a. Verifying via `kubectl --server=https://<tailnet-ip>:6443`
  (apiserver tailnet endpoint) plus tailnet-direct talosctl is the
  only reliable way to diagnose ms01-a's actual state when the
  workstation ↔ LAN-VLAN path is also affected.

## Decision

Ship `--accept-routes=false` on `tag:talos-ii-node` as an interim
stop-gap while the only same-LAN advertiser to worry about is the
LAN's own gateway (UCG-Pro). Trade-off summary:

| Capability                                                      | With `--accept-routes` (default) | Without (this rollout) |
| --------------------------------------------------------------- | -------------------------------- | ---------------------- |
| ms01-a survives a peer advertising its own LAN subnet           | ✗ (this wedge)                   | ✓                       |
| Pod → tailnet device's MagicDNS hostname                        | ✓                                | ✓ (verified — uses 100.64/10 baseline route, not accepted-routes table) |
| Pod → tailnet peer that exposes a non-tailnet subnet            | ✓                                | ✗ (peer's advertised prefix not installed in table 52) |
| Cross-cluster pod-to-pod once talos-i is up (spec 004 D3)       | ✓                                | ✗ until we revisit     |

For the talos-ii-only present, the negative column is empty. The
cross-cluster line item is on hold until talos-i is adopted, at which
point the cleanest fix is **server-side filtering via Tailscale ACL
`routes` allowlist** rather than `accept-routes` flipped back to true:

```jsonc
"routes": {
  "tag:talos-ii-node": [
    "10.42.0.0/16",      // talos-i podCIDR
    "10.43.0.0/16",      // talos-i svcCIDR
    "100.64.0.0/10"      // tailnet baseline (always)
  ]
}
```

That way `tag:talos-ii-node` accepts only the prefixes it actually
needs from talos-i nodes, and a future overlapping advertisement (UCG
or anyone else) can never wedge the cluster again — the route never
gets installed in the first place.

## What we kept (and why)

- **`--netfilter-mode=off`** on `TS_EXTRA_ARGS`. Cilium
  kube-proxy-replacement is the sole owner of host nft on Talos;
  there's no benefit to Tailscale also managing iptables. Cost is
  losing SNAT for advertise-routes (other tailnet devices see source
  podIPs unmasqueraded), which only matters for tailnet peers that
  don't `accept-routes`. In our private tailnet every peer either
  accepts routes or shouldn't be receiving traffic from cluster
  pods anyway.
- **Single OAuth-issued ephemeral auth-key shared across all 3 nodes**
  via a single SOPS-encrypted ESC env patch
  (`talos/patches/global/extension-tailscale-authkey.sops.yaml`).
  Talhelper merges by `kind+name` into each per-node
  ExtensionServiceConfig, so all 3 nodes get the merged 6-entry env
  without any duplication.
- **State-reset choreography for ms01-a** is one-time. ms01-a was
  upgraded under the (since-corrected) belief that
  `--netfilter-mode=off` was the wedge fix; siderolabs's containerboot
  doesn't propagate `TS_EXTRA_ARGS` changes via `tailscale set` on
  restart, so we needed the privileged hostPath `rm` of
  `tailscaled.state`. ms01-b and ms01-c were configured correctly on
  their first apply-config, and no state-reset was needed there —
  containerboot ran `tailscale up` directly with the right args.

## Netbird migration reference

When evaluating Netbird as a tailscale alternative, evaluate the same
axis:

1. **Can Netbird agents accept-routes selectively per-route?** This is
   the underlying property we want — being able to tell ms01-a "ignore
   any advertisement that overlaps your own LAN." Tailscale lacks
   per-route filtering on the client; you have to do it in the
   centralised ACL.
2. **Does Netbird's agent install policy routing (`ip rule`) when
   acting as a subnet router?** Tailscale does (priority 5270),
   above main, with no client-side knob to disable just that
   behaviour without disabling everything.
3. **Does Netbird's "accept advertised routes" default for
   non-overlapping prefixes still install a kernel route via the
   tunnel device, or does it use a separate routing scope?** If
   it's a separate scope/table that respects local routes, the
   wedge class doesn't apply.
4. **How does Netbird's data plane interact with Cilium
   kube-proxy-replacement?** Same question we'd ask of any
   alternative — host nft co-tenancy is the key compatibility
   axis.
5. **OAuth + ephemeral key issuance + tag-based ACL parity?**
   We rely on tags driving auto-approval and routes-allowlist;
   Netbird needs equivalents.

The high-level architecture (mesh integration mode per ADR
shared/0002) is portable; the specific landmines (route-overlap
self-isolation, containerboot's `tailscale set` not honouring all
flags) are tailscale-specific, and we'd be re-evaluating per agent.

## Open items to fold into ADR talos-ii/0014

- [ ] Re-enable `accept-routes` after talos-i adoption + ACL `routes`
      allowlist landing — the path that lets us cross-cluster while
      keeping the wedge guard.
- [ ] Confirm `--netfilter-mode=off` is harmless under the cross-cluster
      load profile (currently nothing exercises advertise-route SNAT
      since no third-party tailnet peer sends traffic to talos-ii pods).
- [ ] Possibly contribute upstream to siderolabs/extensions/network/tailscale
      a `TS_FORCE_REUP=true` env knob that runs `tailscale up` (not `set`)
      every restart, so future flag changes don't need state-delete
      gymnastics.
