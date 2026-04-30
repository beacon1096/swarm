# Specification Quality Checklist: zot OCI mirror in-cluster on talos-ii (Phase 4b)

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-04-29
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [ ] No [NEEDS CLARIFICATION] markers remain — 3 markers present (FR-006, FR-018, SC-008); all within the 3-marker budget
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Project-Specific Quality (this repo)

- [x] Target cluster explicitly tagged `[talos-ii]` in Scope section (per `feedback_per_cluster_scoping.md`)
- [x] Out-of-Scope section explicitly excludes deployment to talos-i
- [x] Out-of-Scope section explicitly excludes data migration from LAN zot
- [x] Out-of-Scope section explicitly excludes decommissioning the LAN host
- [x] Out-of-Scope section explicitly excludes public exposure
- [x] Constitution Check section present and cross-referenced against version 1.1.0
- [x] Upstream registry list explicitly includes `mirror.gcr.io` (talos-i CoreDNS trigger)
- [x] Upstream registry list explicitly includes `gcr.io` (operator-requested)
- [x] No-surprise-reboots principle (Principle XI) addressed in FR-018
- [x] Cross-cluster consumption path (talos-i via tailnet) specified, not duplicated

## Notes

- Three [NEEDS CLARIFICATION] markers remain, all within the 3-marker budget. They are appropriate for `/clarify` resolution and do not block `/plan` if the operator chooses to make informed defaults at planning time:
  1. **FR-006** — Completeness check of LAN-zot upstream list vs. the FR-005 set. Resolution: enumerate live LAN-zot config and add any missing upstreams.
  2. **FR-018** — Confirm Talos `machine.registries.mirrors` change propagates without node reboot on the current Talos version. Resolution: Plan-stage research / dry-run.
  3. **SC-008** — Whether throughput baseline is qualitative ("not slower than LAN zot") or numeric (MB/s target). Resolution: operator preference.
- All three markers are low-risk: scope is unchanged regardless of how they resolve; only verification specifics shift.
- Predecessor repo `swarm-01`'s `kubernetes/apps/registry/zot/app/` is correctly treated as read-only reference (Assumption), not migrated.
