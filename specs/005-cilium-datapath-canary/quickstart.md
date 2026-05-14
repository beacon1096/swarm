# Operator quickstart — Cilium datapath canary

This runbook is ordered to prevent production experimentation before the lab harness is proven.

## P0 — Local QEMU Talos lab

Status as of 2026-05-13: executed once locally. The lab proved that the
measurement harness can distinguish hostNetwork capture from PodCIDR direct
leak, and it blocked the planned production canary path.

1. Create the lab:

```sh
talosctl cluster create qemu
```

2. Install Cilium with talos-ii-like values: native routing, kube-proxy replacement, egress gateway enabled, `bpf.hostLegacyRouting=true`, and baseline `bpf.masquerade=true`.
3. Deploy a host-network sing-box stand-in or netfilter capture target.
4. Deploy canary pods with no proxy env and not using `hostNetwork`.
5. Run the validation contract with `bpf.masquerade=true`.
6. Change only the candidate Cilium value to `bpf.masquerade=false`.
7. Re-run the same validation contract.
8. Tear down the lab after evidence is saved.

Phase 0 blocks production if results are inconclusive, leak detection cannot distinguish direct from proxied egress, or private/DNS checks regress.

Current Phase 0 outcome: production is blocked for the
`bpf.masquerade=false + CiliumEgressGatewayPolicy + sing-box auto_redirect`
route. In lab, hostNetwork traffic entered sing-box, but ordinary PodCIDR
traffic did not enter sing-box userspace, and egress-gateway-selected traffic
succeeded as direct egress without sing-box evidence.

## P0b — Optional local dae/BPF-native proxy lab

Run only inside the disposable QEMU Talos lab. Do not run this on talos-ii
under this spec.

Status as of 2026-05-13: executed once locally. The lab proved dae can start
privileged on Talos and attach TC programs, but it did not enforce a block rule
for hostNetwork or ordinary Pod traffic in the current Cilium TCX datapath.
This path is not ready for production canary.

1. Complete the dae research contract: hook ownership, privileges,
   cleanup, CIDR exclusions, DNS behavior, and fail-closed expectations.
2. Deploy dae or another BPF-native proxy in the lab only.
3. Run the same no-proxy-env public/private/DNS validation matrix.
4. Compare results with the Cilium `bpf.masquerade=false` + sing-box path.
5. Remove dae and verify BPF programs/maps/hooks are cleaned up or the lab
   can be safely destroyed without touching production.

P0b output is comparative evidence. It does not authorize dae on talos-ii.

## P0c — Optional Cilium Local Redirect Policy lab

Status as of 2026-05-14: executed once locally. LRP successfully redirected a
fixed `1.1.1.1:80/TCP` tuple to a node-local backend, but it did not preserve
original-destination semantics and leaked direct when the backend was absent.
It is not a complete transparent public egress path.

Run only inside the disposable QEMU Talos lab unless a later spec accepts a new
LRP design.

## P0d — Optional Cilium L7 egress policy lab

Status as of 2026-05-14: executed once locally. Cilium L7 egress policy sent
selected HTTP traffic through embedded Envoy, allowed the configured path,
returned Envoy `403` for a denied path, and failed closed for unallowed
destinations/ports. This is useful for HTTP egress enforcement but is not a
general transparent TCP/HTTPS proxy replacement.

Run only inside the disposable QEMU Talos lab unless a later spec narrows the
target from transparent public egress to Cilium-native L7 egress enforcement.

## P0e — Optional Cilium DNS/FQDN policy lab

Status as of 2026-05-14: executed once locally. Cilium DNS/FQDN policy sent
selected DNS traffic through the Cilium DNS proxy, allowed only the configured
domain, and failed closed for a denied domain and direct public IP. This is
useful for selected domain allowlisting but is not a transparent outbound proxy
replacement because allowed traffic still goes direct to the resolved public IP.

Run only inside the disposable QEMU Talos lab unless a later spec narrows the
target from transparent public egress to domain-scoped policy enforcement.

## P1 — talos-ii production pre-flight

Run only after P0 passes.

1. Schedule a maintenance window.
2. Confirm vPro AMT or equivalent emergency access for every MS-01 node.
3. Confirm no data-destructive operations are planned: no PVC deletion, no Longhorn mutation, no Talos reset, no disk wipe.
4. Capture exact current Cilium values and save rollback commands.
5. Verify Cilium, CoreDNS, sing-box, production proxy-env workloads, ServiceCIDR, PodCIDR, LAN, and tailnet routes are healthy.
6. Confirm production proxy env will not be removed or changed.

## P2 — talos-ii maintenance-window canary

1. Apply only the canary namespace/workloads and canary `CiliumEgressGatewayPolicy`.
2. Run the baseline `bpf.masquerade=true` matrix.
3. Apply candidate `bpf.masquerade=false` using the documented Cilium source of truth.
4. Wait for Cilium health to return to green.
5. Run the same matrix.
6. Classify every public result as proxied, failed-closed, or leaked-direct.
7. Roll back immediately on any stop-the-line gate.

## P3 — Rollback

1. Restore exact pre-canary Cilium values.
2. Remove or disable canary-only workloads and policies.
3. Verify Cilium, CoreDNS, sing-box, production proxy-env workloads, ServiceCIDR, PodCIDR, LAN, and tailnet routes match baseline.
4. Record rollback status in the canary report.

## P4 — Report

Recommendation must be one of:

1. Keep explicit proxy env for production workloads.
2. Pursue a later production datapath rollout spec/ADR.
3. Reject or defer this Cilium datapath approach.

The report must state that existing production proxy env remains in place after this spec.
