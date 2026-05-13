# Implementation Plan: Cilium datapath canary for transparent sing-box egress

**Branch**: `005-cilium-datapath-canary` | **Date**: 2026-05-13 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/005-cilium-datapath-canary/spec.md`

## Summary

Run this as an investigation, not a rollout. Phase 0 builds a local QEMU Talos lab with `talosctl cluster create qemu` and proves the measurement harness before any contact with production talos-ii. Only after lab gates pass may the operator run a later maintenance-window canary on talos-ii, using dedicated no-proxy-env PodCIDR workloads and restoring the exact pre-canary Cilium values afterward.

The experiment compares current Cilium `bpf.masquerade=true` behavior with candidate `bpf.masquerade=false` behavior, validates `CiliumEgressGatewayPolicy` behavior, correlates public egress with sing-box/netfilter capture evidence, checks DNS pollution and private-route preservation, and treats direct public leakage as a failed canary. It also allows an optional local-only dae/BPF-native proxy lab so both architectural routes can be compared before any production choice. Existing production proxy environment variables remain in place throughout and are not modified by this spec.

## Technical Context

**Workload type**: Documentation-only planning artifacts for a cluster-networking canary. Implementation later creates temporary lab/prod canary manifests, Cilium values diffs, and validation scripts/runbooks.
**Primary systems**: Talos Linux, Kubernetes, Cilium CNI, Cilium Egress Gateway, host-network sing-box, CoreDNS, Flux-managed cluster manifests.
**Target platforms**: Phase 0 local QEMU Talos lab first; Phase 1+ talos-ii only during an operator maintenance window.
**Storage**: N/A. No PVC creation/deletion, Longhorn operations, database mutation, or data-destructive operation is permitted.
**Testing**: Operator-run command matrix documented in [quickstart.md](./quickstart.md) and pass/fail contracts in [contracts/validation-procedure.md](./contracts/validation-procedure.md).
**Constraints**: No production proxy env removal; no talos-i or `swarm-01` changes; fail-closed over leak-open; private CIDRs must remain direct; rollback must restore exact pre-canary values; AMT/rescue access must be available before talos-ii maintenance.
**Scale/scope**: One local disposable lab cluster, then one bounded talos-ii maintenance-window canary using non-production test workloads only.

## Constitution Check

Cross-checked against [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.2.0:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] | PASS | Phase 0 QEMU is local lab only. Production talos-ii remains bare metal. |
| **II. Storage** [both] | PASS | No storage changes, no PVC deletion, no destructive data operations. |
| **III. Network** [talos-ii] | PASS-with-gate | Cilium remains the CNI. Datapath settings are tested only in lab first and then as a bounded talos-ii canary with rollback gates. |
| **IV. Image factory** [talos-ii] | N/A | No Talos schematic/image change. |
| **V. Secrets** [both] | PASS | No new secrets planned; kubeconfig/talosconfig paths are referenced only, never embedded. |
| **VI. Public exposure** [both] | N/A | No service exposure. |
| **VII. Private exposure** [both] | PASS | Existing Tailscale/sing-box/private routing assumptions are validation targets, not changed contracts. |
| **VIII. GitOps** [both] | PASS | Any production manifest/settings changes produced by later `/tasks` must be GitOps-authored or reverted after incident-response testing. |
| **IX. Spec-Driven Development** [both] | PASS | This plan plus Phase 1 artifacts satisfy `/plan`; `/tasks` must decompose implementation. |
| **X. Documentation** [both] | PASS | Final canary report/ADR recommendation is required before any production adoption. |
| **XI. No surprise reboots / destructive shortcuts** [both] | PASS | Maintenance window, AMT/emergency note, no destructive operations, and rollback gates are mandatory. |

**Result: PASS — no Constitution violations. No Complexity Tracking entries required.**

## Project Structure

### Documentation (this feature)

```text
specs/005-cilium-datapath-canary/
├── plan.md                         # This file
├── research.md                     # Phase 0 decisions and dae/BPF-native research track
├── data-model.md                   # Canary objects, value snapshots, matrices, reports
├── quickstart.md                   # Operator runbook: lab first, production later
├── contracts/
│   ├── canary-values.md            # Cilium value comparison and rollback contract
│   ├── validation-procedure.md     # Required pass/fail matrix
│   └── dae-research.md             # Non-invasive BPF-native proxy coexistence questions
└── tasks.md                        # Phase 2, written by /tasks, not /plan
```

### Source code / repo layout (anticipated later tasks)

```text
kubernetes/
└── apps/
    └── network/
        ├── cilium/                 # TEMPORARY or maintenance-window values change only; restore exact baseline
        └── cilium-canary/          # NEW temporary namespace/app for no-proxy-env test pods and policies, if implemented

docs/
├── operations/                     # MAY gain a production canary runbook/report after evidence exists
└── decisions/                      # MAY gain a later ADR only if production adoption is recommended
```

**Structure Decision**: Keep the plan artifacts under `specs/005-cilium-datapath-canary/`. Do not create production manifests during `/plan`. Later `/tasks` may create temporary canary manifests and documentation, but must avoid permanent production contract changes unless a future ADR/spec supersedes this investigation.

## Phase 0 — Local QEMU Talos Lab

Phase 0 is mandatory before touching talos-ii.

1. Create a disposable local Talos cluster with `talosctl cluster create qemu`.
2. Install a lab Cilium configuration matching talos-ii as closely as practical: native routing, kube-proxy replacement, egress gateway enabled, `bpf.hostLegacyRouting=true`, and a baseline `bpf.masquerade=true` run.
3. Deploy a host-network sing-box stand-in or equivalent netfilter capture target sufficient to prove whether PodCIDR traffic traverses host netfilter.
4. Deploy ordinary PodCIDR canary pods with no `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, or `https_proxy` variables.
5. Run the full destination and DNS matrix once with `bpf.masquerade=true` and once with `bpf.masquerade=false`.
6. Add a lab `CiliumEgressGatewayPolicy` matching the production-intended canary selector and verify selected public egress routing, private CIDR exclusions, and fail-closed/leak behavior.
7. Record sing-box/netfilter evidence, Cilium evidence, DNS results, and direct-leak probes for both settings.

Phase 0 exit gate: lab tests must prove the measurement method can distinguish proxied, direct-leaked, private-direct, DNS-polluted, and fail-closed outcomes. If the lab cannot make those distinctions, production talos-ii canary is blocked.

## Phase 1 — Design & Contracts

Design artifacts:

1. [research.md](./research.md): decisions, lab-first rationale, production canary constraints, and non-invasive dae/BPF-native proxy research track.
2. [data-model.md](./data-model.md): baseline snapshots, candidate value sets, canary workloads, destination matrix, rollback gates, and report schema.
3. [contracts/canary-values.md](./contracts/canary-values.md): exact Cilium value comparison and restoration contract.
4. [contracts/validation-procedure.md](./contracts/validation-procedure.md): command-level validation matrix for lab and talos-ii.
5. [contracts/dae-research.md](./contracts/dae-research.md): questions that must be answered before any dae deployment.
6. [quickstart.md](./quickstart.md): operator runbook with Phase 0 lab and later talos-ii maintenance canary.

## Phase 2 — Later Tasks Scope

`/tasks` should produce discrete tasks for:

1. Lab cluster creation, lab Cilium install, and lab teardown.
2. Canary pod and policy manifest authoring.
3. Baseline collection and result-report template.
4. `bpf.masquerade=true` versus `false` comparison.
5. `CiliumEgressGatewayPolicy` validation.
6. sing-box/netfilter capture and direct-leak probes.
7. DNS pollution checks.
8. talos-ii maintenance-window gate, rollback, AMT/emergency readiness, and post-rollback verification.
9. dae/BPF-native proxy coexistence research and optional local QEMU lab experiment, explicitly blocked from talos-ii.

## Key Risks

| Risk | Mitigation |
|---|---|
| Cilium datapath changes affect more than canary pods | Lab first; production only in maintenance window; immediate rollback on health or routing regression. |
| Public egress succeeds by direct leak | Require sing-box/netfilter evidence and external source-IP/leak probes; direct leak fails the canary. |
| DNS success masks polluted public resolution | Test DNS separately from HTTPS; compare cluster-local and public names; record resolver path. |
| Private routes are captured by public proxy path | Explicit private exclusion matrix for RFC1918, PodCIDR, ServiceCIDR, tailnet/CGNAT, link-local, loopback, multicast, and talos-ii LANs. |
| AMT or rescue path unavailable during production change | Block production canary until vPro AMT or equivalent emergency access is confirmed. |
| Existing proxy env masks test results | Only no-proxy-env canary pods are valid evidence; production proxy-env workloads remain unchanged. |

## Open Questions

1. What exact talos-ii LAN endpoint, tailnet endpoint, Matrix homeserver/federation endpoint, and public leak-test endpoint should be used in the final matrix?
2. Which exact Flux/Cilium values path is the authoritative production source for `bpf.masquerade` during the later canary?
3. What is the acceptable maintenance-window length for restarting/reconciling Cilium on talos-ii and completing rollback verification?
4. What local host resources are available for the QEMU Talos lab, and should the lab be single-node or multi-node to exercise egress gateway semantics?
