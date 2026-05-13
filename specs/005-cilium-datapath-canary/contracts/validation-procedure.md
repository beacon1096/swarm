# Contract — Validation procedure

## Matrix

| Class | Example target | Expected result |
|---|---|---|
| GitHub HTTPS | `github.com` | Proxied through sing-box or failed closed; never direct leak. |
| Matrix HTTPS/federation | Selected during planning | Proxied through sing-box or failed closed; never direct leak. |
| Nix cache HTTPS | `cache.nixos.org` | Proxied through sing-box or failed closed; never direct leak. |
| Public DNS | GitHub, Matrix, registry/cache names | No poisoned answer; resolver path recorded. |
| Cluster DNS | `*.svc.cluster.local` | Resolved by CoreDNS; no dependency on public DNS. |
| ServiceCIDR | `10.55.0.0/16` target | Private-direct; absent from public sing-box route. |
| PodCIDR | `10.44.0.0/16` target | Private-direct; absent from public sing-box route. |
| LAN | talos-ii LAN endpoint | Private-direct; absent from public sing-box route. |
| Tailnet/CGNAT | `100.64.0.0/10` endpoint | Private-direct; absent from public sing-box route. |
| Leak probe | External source-IP service | Source path must match sing-box/proxy path or fail closed. |

## Evidence required per row

Each row must record:

1. Pod identity and node placement.
2. Absence of proxy env.
3. DNS command output, if DNS is involved.
4. TCP/HTTPS command output.
5. sing-box logs, counters, or connection records.
6. Cilium policy/monitor evidence where applicable.
7. Direct leak evidence.
8. Result classification.

## Stop-the-line gates

Rollback starts immediately on any of:

1. Cilium agent instability.
2. Node NotReady.
3. CoreDNS regression.
4. ServiceCIDR or PodCIDR routing regression.
5. LAN or tailnet routing regression.
6. Public direct leak.
7. Production proxy-env workload egress regression.
8. Private traffic captured by public sing-box route.
9. Inability to access AMT/emergency recovery path during talos-ii maintenance.
