# Incident 2026-05-04 — sing-box auto_redirect rollout took out talos-ii

Post-mortem of the Phase 2 attempt for ADR
[`shared/0004 — Cluster egress gateway`](../decisions/shared/0004-cluster-egress-gateway.md).
Cluster outage of ~30 min on talos-ii, recovered without data loss.
This doc exists so we don't repeat the mistakes.

## Timeline (UTC)

| time     | event |
|----------|-------|
| 07:14:30 | Phase 2 HR refactor committed (`63b4f26`) — image tag bumped to `tproxy-2026-05-04b`, controller type Deployment → DaemonSet, `hostNetwork: true`, `nodeSelector: role=egress`, age-key Secret mount, `/dev/net/tun` hostPath, drop config Secret mount + command override. |
| 07:15:46 | sing-box.service starts on the new DS pod on `ms01-a`. NixOS systemd, sops-nix activates, sing-box.service runs with k8s-mode config (`tun-in` with `auto_route=true, auto_redirect=true`, `route_exclude_address_set: ["geoip-cn"]`, plus `mixed-in:7890` retained). |
| 07:15–07:24 | sing-box journal shows TUN actively intercepting traffic from `172.16.87.201` (host) and from cluster pod CIDR `10.44.0.0/16`. `outbound/direct` to `10.44.0.x:8000/8181/19002` — i/o timeouts. Cluster-internal connections through ms01-a's net stack drop. |
| 07:18+   | flux source-controller (HTTPS_PROXY env points at sing-box) fails OCI/git fetches: `lookup ... on 10.55.0.10:53: read udp ...: read: connection refused` — DNS to CoreDNS Service IP refused because traffic crossing ms01-a is sinkholed. Cascades to longhorn HelmRepository, several OCIRepository fetches. |
| 07:25    | Diagnosed: `route_exclude_address_set: ["geoip-cn"]` excludes only China-IP destinations. RFC1918 / cluster-CIDR / loopback all enter sing-box, sent to `direct` outbound from host network → can't reach pod CIDR → timeout. |
| 07:25:30 | `kubectl label node ms01-a role-` to evict the DS pod. |
| 07:26    | DS pod terminating. **nftables rules and `ip rule` entries from `auto_redirect` orphaned on ms01-a** because pod termination via SIGKILL skipped systemd shutdown / sing-box deactivation hook. |
| 07:26+   | Cluster traffic still partially broken because the orphaned `ip rule fwmark 0x2023 lookup 2022` plus orphaned `ip route default dev tun0 table 2022` redirected packets to a TUN device that no longer exists → silent drops on any traffic crossing ms01-a's net stack. |
| 07:27    | `git revert 63b4f26` pushed. flux can't reconcile: source-controller's outbound is itself broken by the orphaned rules → chicken-and-egg. |
| 07:35    | Render the reverted HR via `helm template ... | kubectl -n network apply -f -`, bypassing helm-controller. New `init`-tag Deployment pods schedule on `ms01-b` and `ms01-c` — neither node has orphan rules → mixed-in:7890 serves cleanly from those endpoints. The 5 in-cluster proxy consumers (flux-instance, tailscale, matrix, attic, zot) recover. |
| 07:40    | `ip rule del` from a privileged hostNetwork+hostPID pod fails to delete the orphan rules (syntax mismatch on the unspec table identifier). |
| 07:42    | `talosctl reboot` of `ms01-a` — clean reboot wipes all orphaned netfilter / ip-rule state. |
| 07:48    | ms01-a back Ready. flux source-controller recovers, fetches `d53e88d` (revert commit). cluster fully healthy. |
| 07:55    | Failing pod on ms01-a (3rd `init`-image replica that crashed during reboot) deleted; Deployment converges to 2/2 on ms01-b + ms01-c. |

## Root causes (in causal order)

### RC1 — `route_exclude_address_set` was too narrow

Original config had `route_exclude_address_set: ["geoip-cn"]`. The
`geoip-cn` rule-set contains only China public-IP allocations; it
does **not** include RFC1918 (`10/8`, `172.16/12`, `192.168/16`),
loopback (`127/8`), or link-local (`169.254/16`). With
`auto_route: true` + `auto_redirect: true`, sing-box's nftables
marks **everything not in `geoip-cn`** with fwmark 0x2023, and the
ip rule sends marked packets to TUN's routing table.

On a hostNetwork DaemonSet, that means:
- ms01-a's host outbound to 10.44.0.x (cluster pod CIDR) → marked → TUN
- ms01-a's host outbound to 10.55.0.10 (cluster service CIDR / kube-dns) → marked → TUN
- ms01-a's hostNetwork pods' outbound → marked → TUN

sing-box's `direct` outbound from host network can't reach pod CIDR
(those are local routes via Cilium's `lxc*` veths, only available
to pod-network pods). Result: timeouts and broken intra-cluster
DNS for anything routed through ms01-a.

**Fix landed in /etc/nixos**: add `geoip-private` rule-set
(`https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/<rev>/geo/geoip/private.srs`)
to the bundle and to the k8s branch's
`route_exclude_address_set`. Now `["geoip-private", "geoip-cn"]`.

### RC2 — pod termination orphaned netfilter / ip-rule state

When the DS pod was force-deleted (`kubectl delete pod
--grace-period=0 --force` via label removal), Kubernetes sent
SIGKILL. sing-box.service had no chance to run its deactivation
hook (which would `nft delete table` the auto_redirect tables and
`ip rule del` the priorities 9000-9002 / 32768). The orphaned
rules continued to redirect traffic to a TUN device that no
longer existed → silent drops.

The cleanup mechanism currently relies on graceful shutdown.
Force-delete bypasses it. **Bridge that gap** — see "Mitigations"
below.

### RC3 — proxy consumers create chicken-and-egg recovery

Five in-cluster apps (`flux-instance`, `tailscale`, `matrix`,
`attic`, `zot`) have `HTTPS_PROXY=http://sing-box.network.svc.cluster.local:7890`.
When sing-box is unavailable, flux source-controller can't fetch
git/OCI artifacts → `flux reconcile` is a no-op → the GitOps
recovery path is unavailable.

Workaround used here: `helm template ... | kubectl apply` to
bypass helm-controller. This worked because the chart was already
locally pulled. Document this as the standard recovery for "flux
itself is sing-box-blocked."

### RC4 — flux source-controller's failure mode is opaque

The error message — `lookup ... on 10.55.0.10:53: read udp ...:
read: connection refused` — says "DNS broken" but the actual
cause was netfilter sinkhole. Took diagnosing
`outbound/direct ... i/o timeout` patterns in sing-box's own
journal to identify the cluster-CIDR capture as root cause.

## What we should have done differently

1. **PoC the `route_exclude_address_set` scope on a non-prod
   cluster first.** The Stage 1a/1b spike was on talos-ii
   directly; the failure mode wasn't observable until production
   workloads (CoreDNS, kube-apiserver lookups) crossed the
   gateway node. Ideally re-run Stage 1b on talos-i (offsite,
   per shared/0003) once it's adopted; until then, an out-of-band
   single-node test cluster is a worthwhile investment.
2. **Test the failure mode (DS pod force-deleted) before relying
   on graceful shutdown.** A 30-second `kubectl delete pod` while
   running `nft list ruleset` between commands would have caught
   the orphan-rule issue before production.
3. **Don't co-locate the egress gateway with platform-critical
   workloads on a 3-node CP-only cluster.** With ms01-a being
   both the labeled egress node AND a control-plane / etcd voter,
   any disruption affects the cluster control plane. shared/0003's
   "talos-i offsite as egress" plan is the long-term answer; in
   the interim, label two of three nodes as egress and accept
   reduced HA over no isolation.

## Mitigations now in place

- `/etc/nixos/modules/common/sing-box.nix` k8s branch:
  `route_exclude_address_set = ["geoip-private", "geoip-cn"]`.
  Awaiting image rebuild + push.
- swarm-side cluster restored to pre-incident state via revert
  (`d53e88d`). HR `init` tag, Deployment, mixed-in:7890 only.
  No nft/ip-rule/`/dev/net/tun` exposure.

## Mitigations still TODO

- **Cleanup hook on the sing-box.service unit** that runs on
  any termination path (graceful or force) — likely a Talos
  `services.sing-box.serviceConfig.ExecStopPost` running
  `nft flush ruleset` and `ip rule del` for the known
  priorities. Or wrap sing-box in a shell script that traps
  SIGTERM/SIGKILL and cleans up; SIGKILL can't be trapped, so
  **we also need a kubelet pre-stop hook** plus a
  `terminationGracePeriodSeconds` that's long enough for clean
  shutdown.
- **Init container that runs `nft flush ruleset`** before
  sing-box starts, so a force-deleted previous pod's orphans
  get wiped on the next pod's startup. Belt-and-suspenders.
- **Runbook entry** in
  [`flux-helm-recovery.md`](flux-helm-recovery.md) for "sing-box
  is down so flux can't fetch": render-helm-template → kubectl
  apply, bypass helm-controller.
- **Egress-node strategy** revisited per "What we should have
  done differently" item 3. Label 2-of-3 nodes? Wait for talos-i
  adoption? Captured as open follow-up in shared/0004.

## References

- ADR [`shared/0004 — Cluster egress gateway`](../decisions/shared/0004-cluster-egress-gateway.md) —
  primary design doc; this incident expands its "Trade-offs
  accepted" section
- `/etc/nixos/docs/k8s-sing-box-egress-gateway.md` — the
  rebuild plan whose first cut had the geoip-cn-only mistake
- `git log` 2026-05-04 commits in this repo — `63b4f26`
  (Phase 2 attempt), `d53e88d` (revert)
