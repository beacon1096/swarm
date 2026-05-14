# Feature Specification: Canary-only Cilium datapath experiment for transparent sing-box egress

**Feature Branch**: `005-cilium-datapath-canary`
**Created**: 2026-05-13
**Status**: Concluded - no production Cilium datapath rollout
**Input**: User description: "Investigate a canary-only Cilium datapath experiment for talos-ii to determine whether ordinary PodCIDR workloads can use transparent sing-box egress without HTTP_PROXY/HTTPS_PROXY environment variables. Context: ADR shared/0004 established Cilium egress-gateway plus host-network sing-box, but the 2026-05-05 amendment found PodCIDR traffic bypasses host netfilter while Cilium BPF masquerade is enabled. Current Cilium values include routingMode native, bpf.masquerade true, bpf.hostLegacyRouting true, kubeProxyReplacement true, egressGateway enabled true. Recent n8n and Forgejo failures were fixed with explicit proxy env, but we want to research whether changing the Cilium datapath, especially disabling bpf.masquerade, can safely restore transparent PodCIDR egress. This is investigation/canary only, not production rollout. Must include rollback gates, fail-closed/leak decision, private CIDR exclusions, DNS considerations, and verification against GitHub, Matrix, cache.nixos.org, cluster DNS, service/pod/LAN/tailnet traffic. Do not remove existing proxy env from production workloads in this spec."

## Scope

**Target cluster: `[talos-ii]` only.** This feature is an investigation and canary exercise to determine whether ordinary PodCIDR workloads can use transparent sing-box egress without `HTTP_PROXY` / `HTTPS_PROXY` environment variables when the Cilium datapath is changed from the current production shape.

This feature MUST NOT roll the datapath change out cluster-wide as a new steady state. It MUST NOT remove existing proxy environment variables from production workloads such as n8n, Forgejo, Forgejo runner, Matrix, attic, zot, Flux, or any other reconciled workload. Any production env cleanup, if justified by this investigation, requires a later ADR/spec. The long-term platform goal is to remove ordinary PodCIDR dependence on proxy env because some applications, build tools, subprocesses, and sandboxes do not reliably honor or inherit those variables.

Final recommendation after Phase 0 evidence: do not proceed with the talos-ii
Cilium datapath canary. Prefer a later boundary-egress ADR/spec, and keep
explicit proxy env as the interim production workaround for PodCIDR workloads.

The current forgejo-runner `hostNetwork: true` transparent egress path is a workload-specific workaround for CI/build executor needs, not the desired general application model.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator can run a bounded canary and prove whether PodCIDR transparent egress works (Priority: P1)

The platform operator runs a canary-only datapath experiment on talos-ii using non-production test workloads. The experiment answers one question: can ordinary PodCIDR pods reach required public destinations through sing-box transparently, without proxy env, after the candidate datapath change?

**Why this priority**: This is the purpose of the feature. The current accepted contract says PodCIDR workloads need explicit proxy env while BPF masquerade bypasses host netfilter. The investigation is only useful if it produces direct evidence for or against changing that contract.

**Independent Test**: Launch canary pods with no `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, or `https_proxy` variables, exercise the required destination matrix, and compare pod results with sing-box logs/counters and direct-egress leak checks.

**Acceptance Scenarios**:

1. **Given** the canary namespace and canary workloads have no proxy env, **When** the operator applies the candidate datapath setting to the canary scope, **Then** GitHub, Matrix federation endpoints, and `cache.nixos.org` requests succeed and are visible in sing-box capture/route logs.
2. **Given** the same canary pods, **When** they reach cluster DNS, Kubernetes Services, Pod IPs, LAN addresses, and tailnet addresses, **Then** those private destinations remain direct and are not sent through the public egress proxy path.
3. **Given** any public destination succeeds from a canary pod, **When** sing-box logs and leak probes are inspected, **Then** the result identifies whether the request was proxied, leaked direct, or failed closed.

---

### User Story 2 - Operator can roll back immediately if the canary causes connectivity risk (Priority: P1)

The operator has explicit rollback gates before, during, and after the canary. If any gate fails, the canary is stopped and the cluster returns to the pre-test datapath and proxy-contract state.

**Why this priority**: Cilium datapath changes affect cluster-wide packet handling. Even a canary investigation must be reversible, must avoid surprise production impact, and must not leave the cluster in a partially changed networking state.

**Independent Test**: Intentionally fail a non-destructive canary gate, then execute the rollback procedure and verify production workloads, cluster DNS, service routing, LAN routing, and tailnet routing return to baseline.

**Acceptance Scenarios**:

1. **Given** pre-flight baselines have not been collected or are already unhealthy, **When** the operator reaches the canary start gate, **Then** the datapath change is not attempted.
2. **Given** a canary test shows public egress leaking directly instead of using sing-box, **When** the leak decision gate is evaluated, **Then** the canary is treated as failed and rollback begins immediately.
3. **Given** rollback has completed, **When** the operator repeats the baseline checks, **Then** production proxy-env workloads still work and the cluster's Cilium values match the pre-canary state.

---

### User Story 3 - Operator can preserve private routing and DNS behavior during the experiment (Priority: P1)

The canary must prove that transparent public egress, if achievable, does not steal cluster-local, pod-local, LAN, or tailnet traffic, and does not regress DNS resolution paths.

**Why this priority**: A transparent egress mechanism that proxies private traffic would break service discovery, in-cluster dependencies, LAN registries, and the talos-ii mesh assumptions. DNS poisoning avoidance is part of the original problem, so DNS must be validated explicitly.

**Independent Test**: From no-proxy-env canary pods, run a DNS and connectivity matrix for `*.svc.cluster.local`, ServiceCIDR, PodCIDR, RFC1918 LAN, tailnet `100.64.0.0/10`, GitHub, Matrix, and `cache.nixos.org`; confirm each path matches its expected route class.

**Acceptance Scenarios**:

1. **Given** the canary pods query cluster-local names, **When** CoreDNS answers `*.svc.cluster.local`, **Then** results match baseline and queries do not depend on sing-box public DNS behavior.
2. **Given** the canary pods query public names affected by poisoned upstreams, **When** they resolve GitHub, Matrix homeservers, and `cache.nixos.org`, **Then** DNS results support the intended proxied egress path and do not return known-poisoned failures.
3. **Given** private destinations are tested, **When** the operator inspects sing-box logs/counters, **Then** private CIDR traffic is absent from the public proxy route while still succeeding directly.

---

### User Story 4 - Operator can make a documented go/no-go recommendation without changing production contracts (Priority: P2)

After the canary, the operator records evidence and recommends one of: keep the current explicit-proxy-env contract, pursue a later production datapath change, or abandon this approach.

**Why this priority**: The output of this feature is research evidence, not rollout. The result must be actionable for a future ADR while preserving the current production safety posture.

**Independent Test**: Review the canary report and confirm it includes baseline values, changed values, pass/fail matrix, leak/fail-closed results, DNS results, rollback evidence, and a recommendation.

**Acceptance Scenarios**:

1. **Given** the canary completed successfully, **When** the operator reviews the report, **Then** it states whether PodCIDR transparent egress is technically viable and what additional production-risk work remains.
2. **Given** the canary failed or leaked, **When** the report is published, **Then** it states that production workloads must keep explicit proxy env and explains why the datapath option is rejected or deferred.
3. **Given** the report recommends later production adoption, **When** the recommendation is read, **Then** it explicitly says proxy env removal is out of scope for this spec and requires a new rollout spec.

### Edge Cases

- **Direct public leak**: If a canary pod reaches a public IP without sing-box capture, the result is failure, not partial success. The default decision for selected public egress is fail-closed over leak-open.
- **Private traffic capture**: If ServiceCIDR, PodCIDR, LAN, or tailnet traffic is captured by sing-box public egress, the canary fails even if public internet tests pass.
- **DNS split behavior**: If public DNS works only because the pod used a direct poisoned-prone resolver, the canary fails. If cluster-local DNS regresses, rollback is mandatory.
- **Egress gateway mismatch**: If Cilium egress-gateway routes packets to a gateway node but sing-box still does not see them, the result must be recorded as a datapath mismatch, not as an application failure.
- **Node-specific success**: If only pods scheduled on a specific node pass, the canary is not production-ready; the report must identify node placement as a limiting factor.
- **Existing proxy env masks the result**: Any workload containing proxy env is invalid as evidence for transparent PodCIDR egress.
- **Production workload disturbance**: Any regression in existing proxy-env workloads, cluster DNS, Cilium health, or kube-proxy replacement behavior triggers rollback.

## Requirements *(mandatory)*

### Functional Requirements

#### Investigation boundaries

- **FR-001**: The investigation MUST target talos-ii only and MUST NOT alter talos-i or `swarm-01`.
- **FR-002**: The investigation MUST be canary-only. It MUST use dedicated non-production canary workloads and MUST NOT remove, disable, or rely on removing proxy env from production workloads.
- **FR-003**: The canary MUST document the pre-test Cilium datapath values, including at minimum `routingMode`, `bpf.masquerade`, `bpf.hostLegacyRouting`, `kubeProxyReplacement`, and `egressGateway.enabled`.
- **FR-004**: The canary MUST evaluate disabling Cilium BPF masquerade as the primary candidate datapath change, because ADR `shared/0004` identified BPF masquerade bypassing host netfilter as the load-bearing blocker.
- **FR-005**: The canary MAY evaluate additional datapath toggles only if they are explicitly documented with their expected effect, risk, and rollback path before execution.
- **FR-005a**: The investigation MAY include a BPF-native proxy candidate such as `dae`. It MAY be deployed only in the disposable local QEMU Talos lab after documenting Cilium co-existence, BPF hook ownership, Kubernetes scoping, private CIDR exclusion, DNS, fail-closed behavior, and cleanup/rollback questions. It MUST NOT be deployed on talos-ii by this spec.
- **FR-006**: The canary MUST NOT create a new production steady-state contract. Any permanent datapath change or production proxy-env cleanup is out of scope.

#### Safety gates and rollback

- **FR-007**: The canary MUST define pre-flight gates for cluster health, Cilium health, CoreDNS health, sing-box health, current production egress health, and current private-routing health.
- **FR-008**: The canary MUST define stop-the-line rollback gates for Cilium agent instability, node readiness loss, CoreDNS regression, ServiceCIDR or PodCIDR routing regression, LAN or tailnet routing regression, public direct leak, and production workload egress regression.
- **FR-009**: The canary MUST define the fail-closed/leak decision as: public egress from selected canary pods must fail closed if sing-box is unavailable or not capturing; direct public leakage is a failed canary even if the application request succeeds.
- **FR-010**: The canary MUST include an operator-executable rollback procedure that restores the exact pre-canary Cilium values and removes or disables canary-only workloads/policies.
- **FR-011**: The rollback verification MUST repeat the same baseline checks collected before the canary and confirm production proxy-env workloads still function.

#### Traffic and DNS validation

- **FR-012**: The canary workloads MUST be ordinary PodCIDR pods, not `hostNetwork` pods, and MUST have no `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, or `https_proxy` variables.
- **FR-013**: The canary MUST verify public HTTPS egress to GitHub and `cache.nixos.org` without proxy env.
- **FR-014**: The canary MUST verify Matrix-related egress without proxy env using a representative homeserver or federation endpoint selected during planning.
- **FR-015**: The canary MUST verify cluster DNS resolution for `*.svc.cluster.local` and at least one known in-cluster Service.
- **FR-016**: The canary MUST verify ServiceCIDR traffic, PodCIDR traffic, LAN traffic, and tailnet traffic remain reachable by their expected direct paths.
- **FR-017**: The canary MUST treat the following destination classes as private exclusions that must not traverse public sing-box proxy routing: RFC1918 ranges, PodCIDR `10.44.0.0/16`, ServiceCIDR `10.55.0.0/16`, tailnet/CGNAT `100.64.0.0/10`, loopback, link-local, multicast, and any documented talos-ii LAN subnets.
- **FR-018**: The canary MUST verify DNS behavior separately from TCP/HTTPS behavior, including public-name resolution for GitHub, Matrix, container registries, and `cache.nixos.org`, and cluster-local resolution for Kubernetes Services. Public DNS must be evaluated because domestic resolvers may poison registry and source-control domains.
- **FR-019**: The canary MUST correlate successful public egress with sing-box evidence, such as logs, counters, or connection records, so success cannot be confused with direct leakage.

#### Reporting and decision output

- **FR-020**: The canary report MUST include baseline state, candidate changes, test workload identity, destination matrix, expected route class, observed result, sing-box evidence, Cilium evidence, and rollback status.
- **FR-021**: The canary report MUST produce a go/no-go recommendation for a future ADR/spec: keep explicit proxy env, pursue a production datapath rollout, or reject/defer this approach.
- **FR-022**: The canary report MUST explicitly state that existing production proxy env remains in place after this spec, regardless of result.

### Key Entities

- **Canary workload**: A non-production PodCIDR workload with no proxy env, used only to test transparent egress behavior.
- **Candidate datapath change**: A documented Cilium setting change under investigation, primarily disabling BPF masquerade, with known baseline value and rollback value.
- **Destination matrix**: The required set of public, cluster-local, pod-local, LAN, and tailnet destinations used to classify pass/fail behavior.
- **Private CIDR exclusion set**: The destination ranges that must remain direct and must not be routed through public sing-box egress.
- **Leak decision**: The canary policy that public direct egress is a failure; selected public egress must either go through sing-box or fail closed.
- **Canary report**: The evidence record that supports the final go/no-go recommendation without changing production workload contracts.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of required public-destination tests from no-proxy-env canary pods are classified as proxied-through-sing-box, failed-closed, or leaked-direct; no result is left ambiguous.
- **SC-002**: 0 public direct leaks are accepted as successful outcomes; any leak produces a failed canary and rollback.
- **SC-003**: 100% of required private-destination tests for cluster DNS, ServiceCIDR, PodCIDR, LAN, and tailnet traffic match the expected direct route class before any future rollout can be recommended.
- **SC-004**: Rollback restores pre-canary datapath values and passes the baseline health matrix within one operator maintenance window.
- **SC-005**: The final report includes a complete destination matrix covering GitHub, Matrix, `cache.nixos.org`, cluster DNS, at least one Service, at least one Pod IP, at least one LAN endpoint, and at least one tailnet endpoint.
- **SC-006**: No production workload loses its existing proxy env, and no production workload's egress contract is changed by this spec.

## Assumptions

- The current accepted production contract from ADR `shared/0004` remains valid until a later ADR/spec supersedes it: hostNetwork pods may use kernel transparent egress, while ordinary PodCIDR workloads keep explicit proxy env.
- talos-ii currently uses Cilium native routing with BPF masquerade enabled, host legacy routing enabled, kube-proxy replacement enabled, and egress gateway enabled.
- sing-box remains the existing host-network egress component and is not replaced by this investigation.
- The canary can be scheduled during an operator-controlled maintenance window because Cilium datapath changes may restart agents or transiently affect node networking.
- The planning phase will choose exact test endpoints for Matrix, LAN, and tailnet based on currently healthy services, but the destination classes are fixed by this spec.
