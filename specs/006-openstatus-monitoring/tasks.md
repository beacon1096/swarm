---
description: "Task list for OpenStatus monitoring on talos-ii"
---

# Tasks: OpenStatus monitoring on talos-ii

**Input**: Design documents from `/home/beacon/swarm/specs/006-openstatus-monitoring/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/openstatus-runtime.md, quickstart.md
**Target cluster**: `[talos-ii]` only. Do not edit `swarm-01` and do not remove any uptime-kuma deployment because none is being replaced.

**Tests**: Validation is operator-run: Flux readiness, HTTPRoute responses, login/workspace creation, persistence restart, private-location check result, and plaintext-secret grep.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with adjacent tasks when files/resources do not overlap.
- **[Story]**: maps to spec user stories.
- All paths are absolute under `/home/beacon/swarm/`.

---

## Phase 0 — Preflight Decisions

**Purpose**: close the risky upstream unknowns before writing manifests.

- [ ] T001 Resolve immutable tags/digests for upstream GHCR images `openstatus-server`, `openstatus-dashboard`, `openstatus-status-page`, `openstatus-workflows`, `openstatus-private-location`, and `openstatus-checker`, then map them to the zot ghcr.io pull-through cache path.
- [ ] T002 [P] Verify current OpenStatus datastore support. If PostgreSQL is supported, map it to the existing cluster-managed PostgreSQL pattern; otherwise record libSQL-on-Longhorn as the MVP datastore.
- [ ] T003 [P] Enable Tinybird-local for MVP check history, with persistent storage and a SOPS-managed `TINY_BIRD_API_KEY` if required by runtime.
- [ ] T004 Use `status.beaco.works` as the MVP public hostname and confirm whether dashboard and status-page share that host by path/routing or whether dashboard needs a second host.
- [ ] T005 Choose the first OAuth provider for MVP, configure callback URLs for `status.beaco.works`, and document required SOPS keys.

---

## Phase 1 — Author GitOps Manifests

**Purpose**: create the OpenStatus namespace/app layout after Phase 0 resolves image, datastore, and auth choices.

- [ ] T006 Create `/home/beacon/swarm/kubernetes/apps/monitoring/openstatus/app/`.
- [ ] T007 [P] Create `/home/beacon/swarm/kubernetes/apps/monitoring/namespace.yaml` for namespace `monitoring`.
- [ ] T008 [P] Create `/home/beacon/swarm/kubernetes/apps/monitoring/kustomization.yaml` listing `namespace.yaml` and `openstatus/ks.yaml`.
- [ ] T009 [P] Create `/home/beacon/swarm/kubernetes/apps/monitoring/openstatus/ks.yaml` for the Flux Kustomization targeting namespace `monitoring`.
- [ ] T010 Create OpenStatus application manifests in `/home/beacon/swarm/kubernetes/apps/monitoring/openstatus/app/` using either a verified chart or explicit workloads for dashboard, server, workflows, status-page, private-location, datastore, and Tinybird-local if enabled.
- [ ] T011 [P] Create persistent storage manifests for libSQL or verified PostgreSQL reference, plus Tinybird-local PVC if enabled. Use Longhorn-backed storage and do not include destructive lifecycle hooks.
- [ ] T012 [P] Create `secret.sops.yaml` in plaintext form only long enough to populate required keys, then proceed immediately to Phase 2 encryption before staging.
- [ ] T013 [P] Create non-secret config mapping env vars from `contracts/openstatus-runtime.md`.
- [ ] T014 Create Gateway API HTTPRoutes for dashboard and status-page exposure through existing cluster ingress conventions.
- [ ] T015 Create app-level `kustomization.yaml` listing secrets, config, storage, workloads/chart resources, services, and HTTPRoutes.

---

## Phase 2 — Encrypt And Sanity Check

**Purpose**: ensure no plaintext secrets and no scope drift before any commit.

- [ ] T016 SOPS-encrypt `/home/beacon/swarm/kubernetes/apps/monitoring/openstatus/app/secret.sops.yaml` from repo root.
- [ ] T017 Verify decrypt round trip from `/home/beacon/swarm` using `sops -d`.
- [ ] T018 Grep the OpenStatus manifests for forbidden scope/exposure drift: no `uptime-kuma`, no `swarm-01`, no `NodePort`, no plaintext token strings, no unrelated namespace edits.
- [ ] T019 Run `git diff` and confirm all secret values are encrypted (`ENC[...]`) and only intended OpenStatus files changed.

---

## Phase 3 — Reconcile And Smoke Test

**Purpose**: prove the MVP works after Flux applies it.

- [ ] T020 Watch Flux reconcile the `openstatus` Kustomization and verify all pods are ready.
- [ ] T021 [US1] Verify dashboard HTTPRoute responds and login works with the chosen auth path.
- [ ] T022 [US2] Create a workspace and one HTTP monitor, restart application pods, and verify configuration persists.
- [ ] T023 [US3] Register/start the private-location probe with self-hosted `OPENSTATUS_INGEST_URL` and verify it reports healthy.
- [ ] T024 [US3] Verify one monitor check result appears from the talos-ii private location.
- [ ] T025 [US4] Create a minimal status page and verify the status-page HTTPRoute renders.
- [ ] T026 Verify the OpenStatus API token path needed for future MCP use is present; do not create or store a long-lived MCP key unless explicitly requested.
- [ ] T027 Verify no Talos node reboot or machine-config change occurred during the MVP rollout.

---

## Phase 4 — Documentation

**Purpose**: document the deployed service and operator procedure.

- [ ] T028 [P] Add `/home/beacon/swarm/docs/operations/openstatus.md` covering deploy, required secrets/env vars, health checks, persistence, private-location setup, MCP follow-up, rollback, and deferred features.
- [ ] T029 [P] Update `/home/beacon/swarm/docs/cluster-definition.md` with the `monitoring` namespace and OpenStatus workload.
- [ ] T030 [P] Update `/home/beacon/swarm/docs/index.md` with the OpenStatus runbook entry.
- [ ] T031 Decide whether an ADR is warranted for replacing the planned uptime-kuma role; if yes, add it under `/home/beacon/swarm/docs/decisions/talos-ii/` and link it from the runbook/index.

---

## Deferred / Out Of Scope

- Alerting integrations: Slack, Discord, PagerDuty, email/SMS notifications beyond login email.
- Multi-region probes and cloud private locations.
- Historical import from uptime-kuma or any other system.
- Terraform/CLI monitor management.
- Paid-feature unlock automation and workspace limit customization beyond what is required to create the MVP monitor/status page.
- Custom status-page branding, custom domain automation, and IP-restricted status pages.

## Dependencies & Execution Order

- Phase 0 blocks all manifest authoring.
- T016 through T019 are sequential and must complete before commit.
- Phase 3 starts only after Flux has reconciled the manifests.
- Documentation can be drafted in parallel but should reflect the actual Phase 3 results before finalizing.
