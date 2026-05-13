# Contract — Cilium canary values

## Baseline values to record

| Value | Required baseline action |
|---|---|
| `routingMode` | Record current value before lab/prod run. |
| `bpf.masquerade` | Record current value; expected production baseline is `true`. |
| `bpf.hostLegacyRouting` | Record current value; expected production baseline is `true`. |
| `kubeProxyReplacement` | Record current value; expected production baseline is `true`. |
| `egressGateway.enabled` | Record current value; expected production baseline is `true`. |

## Required comparison

Run the same validation matrix twice:

1. Baseline: `bpf.masquerade=true`.
2. Candidate: `bpf.masquerade=false`.

No other Cilium value may change in the same comparison unless it is documented with expected effect, risk, and rollback.

## Rollback contract

Before applying the candidate value, record:

1. The authoritative source path for the Cilium values.
2. The exact baseline values.
3. The apply command.
4. The rollback command.
5. The post-rollback verification command.

Rollback is mandatory if Cilium health, node readiness, CoreDNS, ServiceCIDR, PodCIDR, LAN, tailnet, sing-box capture, production proxy-env egress, or leak detection fails.
