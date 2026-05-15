# Implementation Plan: OpenStatus monitoring on talos-ii

**Branch**: `006-openstatus-monitoring` | **Date**: 2026-05-14 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/006-openstatus-monitoring/spec.md`

## Summary

Deploy self-hosted OpenStatus as the minimal uptime/status monitoring service for talos-ii, replacing the previously planned role of uptime-kuma without migrating any existing uptime-kuma state. The MVP is a Flux-managed, Gateway API-exposed OpenStatus stack with persistent datastore, persistent Tinybird-local analytics, SOPS-managed secrets, OAuth login, one private-location probe, and one smoke-test monitor. Advanced alerting, integrations, multi-region probes, historical import, and presentation polish are deferred. OpenStatus MCP support is a selection driver and should remain available as a post-MVP API-key workflow.

Upstream self-hosting is Docker Compose-oriented. It documents libSQL, Tinybird-local, workflows, server, dashboard, status-page, and private-location services. PostgreSQL is preferred only where upstream supports it; implementation must not swap libSQL for PostgreSQL unless verified. Upstream publishes pre-built GHCR images for the OpenStatus app services, and this cluster's zot registry already has ghcr.io pull-through caching enabled, so MVP manifests should consume those cached upstream images rather than adding an internal image build pipeline.

## Technical Context

**Workload type**: multi-service web application plus monitoring worker/probe.
**Primary systems**: Kubernetes, Flux, Gateway API HTTPRoute, SOPS, Longhorn, OpenStatus, libSQL or verified PostgreSQL support, optional Tinybird-local.
**Target platform**: talos-ii only.
**Storage**: persistent datastore required. Use upstream-supported libSQL on Longhorn unless PostgreSQL support is verified. Persist Tinybird-local for check history.
**Testing**: operator-run smoke tests from [quickstart.md](./quickstart.md), Kubernetes readiness checks, HTTPRoute probes, persistence restart test, private-location monitor result test.
**Constraints**: minimal MVP; no uptime-kuma migration; no Talos machine-config change; no node reboot; no NodePort; no plaintext secrets; no advanced alerting/integrations in MVP.
**Scale/scope**: one talos-ii deployment, one OpenStatus workspace, one private location, one initial monitor, one status page.

## Constitution Check

Cross-checked against [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.2.0:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] | PASS | Pure Kubernetes workload on existing bare-metal cluster. |
| **II. Storage** [both] | PASS-with-gate | Persistent datastore must use Longhorn-backed storage or existing cluster-managed database pattern. No PVC deletion in MVP. |
| **III. Network** [talos-ii] | PASS | Uses Cilium Pod/Service networking and Gateway API HTTPRoute. No overlay or NodePort. |
| **IV. Image factory** [talos-ii] | N/A | No Talos image or schematic change. |
| **V. Secrets** [both] | PASS | All app/auth/ingest/email/analytics tokens are SOPS-managed. |
| **VI. Public exposure** [both] | PASS | Uses default Gateway/Cloudflare Tunnel path for public HTTP service exposure. |
| **VII. Private exposure** [both] | PASS | Private-location probe is internal workload; no tailnet Service required for MVP. |
| **VIII. GitOps** [both] | PASS | All steady-state resources under `kubernetes/apps/*` and reconciled by Flux. |
| **IX. Spec-Driven Development** [both] | PASS | This spec, plan, contracts, and tasks prepare the implementation. |
| **X. Documentation** [both] | PASS-by-requirement | Implementation tasks require cluster-definition and operations docs updates. |
| **XI. No surprise reboots / destructive shortcuts** [both] | PASS | No machine-config change, no reboot, no destructive storage operations. |

**Result: PASS — no Constitution violations. No Complexity Tracking entries required.**

## Project Structure

### Documentation (this feature)

```text
specs/006-openstatus-monitoring/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── openstatus-runtime.md
└── tasks.md
```

### Source code / repo layout (anticipated later tasks)

```text
kubernetes/
└── apps/
    └── monitoring/
        ├── namespace.yaml
        ├── kustomization.yaml
        └── openstatus/
            ├── ks.yaml
            └── app/
                ├── kustomization.yaml
                ├── helmrelease.yaml or deployment manifests
                ├── secret.sops.yaml
                ├── configmap.yaml
                ├── datastore-pvc.yaml or database claim/reference
                ├── tinybird-pvc.yaml if Tinybird-local is enabled
                └── httproute*.yaml

docs/
├── cluster-definition.md
├── index.md
└── operations/openstatus.md
```

**Structure decision**: use a new top-level namespace directory `kubernetes/apps/monitoring/` with child app `openstatus/`. This keeps OpenStatus grouped with future monitoring/observability workloads and follows the existing `kubernetes/apps/<namespace>/<app>/` GitOps convention. Do not create manifests during this planning step.

## Phase 0 — Research Decisions

Research output is captured in [research.md](./research.md). Key decisions:

1. **OpenStatus over uptime-kuma**: OpenStatus is the planned monitoring/status service for talos-ii. No existing uptime-kuma state is migrated.
2. **Topology**: Start from upstream self-hosting architecture: workflows, server, dashboard, status-page, private-location, datastore, and optional Tinybird-local.
3. **Datastore**: Use PostgreSQL only if upstream supports it. Current upstream self-hosting docs use libSQL (`DATABASE_URL=http://libsql:8080`), so libSQL on Longhorn is the safe MVP default.
4. **Images**: Use upstream GHCR images through the in-cluster zot ghcr.io pull-through cache. Pin tags/digests during implementation.
5. **Exposure**: Expose dashboard/status-page through Gateway API HTTPRoutes. Avoid NodePort and avoid depending on OpenStatus IP restriction semantics for MVP.
6. **Auth**: `AUTH_SECRET` and `SELF_HOST=true` are required. MVP uses OAuth; implementation must provide supported OAuth provider credentials and callback URL configuration.

## Phase 1 — Design & Contracts

Design artifacts:

1. [data-model.md](./data-model.md): Kubernetes entities, persistent state, secrets/config, and service relationships.
2. [contracts/openstatus-runtime.md](./contracts/openstatus-runtime.md): runtime services, ports, health paths, env vars, and SOPS secret contract.
3. [quickstart.md](./quickstart.md): operator validation runbook for preflight, reconcile, health, persistence, and private-location checks.

## Phase 2 — Tasks Scope

[tasks.md](./tasks.md) decomposes the implementation into preflight, image supply decision, manifest authoring, secret encryption, Flux verification, UI/persistence/private-location smoke tests, and documentation. The task list deliberately does not implement Kubernetes manifests in this planning step.

## Key Risks

| Risk | Mitigation |
|---|---|
| Upstream image tags drift because README examples use `latest` | Resolve and pin tags/digests during implementation; pull through zot for cluster-local caching. |
| PostgreSQL preference conflicts with upstream libSQL requirement | Do not substitute databases without upstream support; document libSQL as not PostgreSQL-applicable. |
| OAuth callback or provider config is wrong | Treat auth-provider setup as a preflight gate; do not expose dashboard as ready until login works. |
| Tinybird-local adds stateful surface area | Persist it on Longhorn and include readiness checks before accepting check-history behavior. |
| Gateway route exposes admin UI publicly | Require authentication before accepting HTTPRoute as ready; status-page route can be separate. |
| Private-location cannot reach ingest API | Configure `OPENSTATUS_INGEST_URL` to self-hosted server API and verify with one check result. |

## Open Questions

1. Is `status.beaco.works` used for both dashboard and public status-page path routing, or should dashboard receive a second hostname?
2. Which OAuth provider should be wired first, GitHub or Google?
