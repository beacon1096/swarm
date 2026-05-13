# Phase 1 — Data Model

## Entity 1 — Baseline snapshot

**Type**: Evidence record collected before each lab/prod run.
**Fields**: cluster name, timestamp, Cilium chart/version, `routingMode`, `bpf.masquerade`, `bpf.hostLegacyRouting`, `kubeProxyReplacement`, `egressGateway.enabled`, Cilium health, CoreDNS health, sing-box health, production proxy-env workload health, private routing health.
**Validation**: Missing or unhealthy baseline blocks the canary.

## Entity 2 — Candidate Cilium value set

**Type**: Reversible Cilium values diff.
**Fields**: baseline value, candidate value, source path, apply command, expected effect, rollback command, rollback value.
**Required comparison**: current `bpf.masquerade=true` versus candidate `bpf.masquerade=false`.
**Validation**: The rollback value must be recorded before applying the candidate value.

## Entity 3 — Canary workload

**Type**: Ordinary PodCIDR pod in a dedicated canary namespace.
**Fields**: namespace, labels used by `CiliumEgressGatewayPolicy`, node placement, image, commands, environment.
**Validation**: Must not be `hostNetwork`; must not contain `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, or `https_proxy`.

## Entity 4 — `CiliumEgressGatewayPolicy`

**Type**: Canary-scoped Cilium policy object.
**Fields**: endpoint selector, destination CIDRs, excluded CIDRs, egress gateway node/interface selection, expected gateway node.
**Validation**: Must select only canary workloads; must exclude RFC1918, PodCIDR `10.44.0.0/16`, ServiceCIDR `10.55.0.0/16`, tailnet/CGNAT `100.64.0.0/10`, loopback, link-local, multicast, and documented talos-ii LAN subnets.

## Entity 5 — Destination matrix row

**Type**: One validation target.
**Fields**: destination, class, protocol, expected route, expected DNS behavior, command, sing-box evidence, Cilium evidence, leak evidence, result.
**Required classes**: GitHub, Matrix, `cache.nixos.org`, public DNS names, cluster DNS, Kubernetes Service, Pod IP, LAN endpoint, tailnet endpoint, direct leak endpoint.
**Result values**: proxied, private-direct, failed-closed, leaked-direct, DNS-polluted, regression, inconclusive.

## Entity 6 — Rollback gate

**Type**: Stop-the-line condition.
**Fields**: gate name, trigger, operator action, rollback command, verification command, required final state.
**Required gates**: Cilium instability, node NotReady, CoreDNS regression, ServiceCIDR/PodCIDR regression, LAN/tailnet regression, public direct leak, production workload egress regression, sing-box capture mismatch, AMT/emergency unavailable.

## Entity 7 — Canary report

**Type**: Final evidence record.
**Fields**: baseline snapshot, lab results, production canary results if run, Cilium values compared, policy identity, destination matrix, DNS matrix, sing-box/netfilter evidence, direct leak results, rollback evidence, go/no-go recommendation.
**Validation**: Must state that production proxy env remains in place regardless of result.
