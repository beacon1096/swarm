# Contract — dae/BPF-native proxy research and lab experiment

This track has two allowed stages:

1. **Research stage**: read documentation, inspect source, and produce notes.
2. **Local lab stage**: deploy dae or another BPF-native proxy only inside the disposable QEMU Talos lab created for this feature.

This track must not deploy dae, attach dae BPF programs, change Cilium, or modify talos-ii. Any talos-ii dae test requires a later explicit spec/ADR decision.

Research must answer:

1. Which BPF hooks dae uses and whether they conflict with Cilium's datapath hooks.
2. Whether dae can coexist with Cilium kube-proxy replacement, egress gateway, BPF masquerade, and host legacy routing.
3. How Kubernetes pod selection would be scoped without affecting production workloads.
4. How RFC1918, PodCIDR, ServiceCIDR, tailnet/CGNAT, loopback, link-local, multicast, and talos-ii LAN exclusions are expressed.
5. Whether dae can fail closed for selected public egress without leaking direct.
6. How DNS interception/resolution works and how DNS pollution is avoided.
7. What cleanup fully detaches BPF programs and restores pre-test state.
8. What observability proves proxied versus direct-leaked traffic.

Before any local lab deployment, the operator must record:

1. The dae deployment shape and required privileges.
2. The exact Cilium lab settings it is tested against.
3. The BPF hooks/maps/programs expected to be attached.
4. The cleanup command sequence and expected empty/clean post-state.

The local lab experiment must answer the same traffic classes as the Cilium/sing-box path: public proxied success, fail-closed, direct leak, private direct routing, and DNS behavior.

Any future dae test on talos-ii requires a new spec or an explicit amendment to this one.
