# Phase 0 — Research

## Decision 1 — Lab before production

**Decision**: The first executable phase is a local QEMU Talos lab created with `talosctl cluster create qemu`.

**Rationale**: Cilium datapath changes can affect all packets handled by the CNI. A local lab proves the Cilium value toggles, egress policy shape, capture method, DNS checks, and rollback commands before talos-ii is touched.

**Alternatives considered**: A direct talos-ii canary was rejected because even canary-labeled workloads cannot fully isolate Cilium agent restarts or datapath-wide behavior.

## Decision 2 — Production is a later maintenance-window canary only

**Decision**: talos-ii is tested only after Phase 0 passes, during a maintenance window, with pre-collected rollback values and AMT/emergency access confirmed.

**Rationale**: `bpf.masquerade` is a datapath-level setting. The production exercise is therefore bounded by stop-the-line gates rather than treated like an ordinary workload rollout.

**Alternatives considered**: A normal Flux rollout without an operator present was rejected because rollback may require direct Cilium/Talos intervention.

## Decision 3 — Compare `bpf.masquerade=true` and `false`

**Decision**: The experiment must run the same no-proxy-env canary matrix under the current `bpf.masquerade=true` baseline and the candidate `bpf.masquerade=false` setting.

**Rationale**: ADR `shared/0004` identified BPF masquerade bypassing host netfilter as the likely blocker. A paired comparison is needed to distinguish application behavior from datapath behavior.

**Alternatives considered**: Testing only `false` was rejected because it would not prove whether behavior changed from the production baseline.

## Decision 4 — `CiliumEgressGatewayPolicy` is part of the test

**Decision**: A canary-scoped `CiliumEgressGatewayPolicy` must be tested in lab and production canary.

**Rationale**: The current architecture uses Cilium egress-gateway semantics plus host-network sing-box. The experiment must verify whether policy-selected PodCIDR packets reach the intended gateway path and whether sing-box/netfilter observes them.

**Alternatives considered**: Raw default-route testing was rejected because it would not validate the production-intended selection mechanism.

## Decision 5 — Direct leak is failure, not partial success

**Decision**: Public egress from selected canary pods must be classified as proxied-through-sing-box, failed-closed, or leaked-direct. Leaked-direct fails the canary.

**Rationale**: The platform goal is controlled transparent egress, not merely internet reachability.

**Alternatives considered**: Accepting direct success as a fallback was rejected because it weakens the egress contract and hides DNS/geographic pollution issues.

## Decision 6 — DNS is tested separately from TCP/HTTPS

**Decision**: DNS checks are first-class validation steps for cluster-local and public names.

**Rationale**: HTTPS success can mask polluted DNS, cached answers, or resolver path drift. Cluster DNS and public DNS have different correctness criteria.

**Alternatives considered**: Inferring DNS health from `curl` was rejected as ambiguous.

## Decision 7 — dae/BPF-native proxy is lab-eligible, production-blocked

**Decision**: dae or another BPF-native proxy candidate is a separate track that may progress from documentation/source review to a local QEMU Talos lab experiment. It must not be deployed on talos-ii by this spec unless a later explicit amendment or spec accepts that risk.

**Rationale**: If Cilium SNAT runs on the BPF datapath, a BPF-native proxy may match the actual packet path better than forcing traffic back through netfilter. But dae may contend with Cilium for BPF hook ownership, routing marks, conntrack expectations, DNS interception, and fail-closed behavior. A disposable lab is the right place to test coexistence and cleanup.

**Alternatives considered**: Deploying dae directly to talos-ii was rejected because BPF hook conflicts or cleanup failures can affect node networking. Keeping dae as documentation-only was rejected because the operator explicitly wants to compare both routes while the lab exists.
