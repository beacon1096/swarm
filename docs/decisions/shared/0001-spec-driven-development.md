# ADR shared/0001 — Spec-Driven Development with `spec-kit`

**Scope:** shared — applies to talos-ii and talos-i (when adopted).
**Status:** accepted
**Date:** 2026-04-27

## Context

The previous swarm-01 repo accumulated workarounds for ~14 months without explicit decision capture:

- Custom `util-linux-mountpoint` extension
- KubeVirt VM definitions in `talos-ii/harvester/`
- `forgejo-runner` transparent-proxy initContainer JSON patch
- `attic-ts` / `zot-ts` Tailscale ExternalName indirection
- spegel `prependExisting: true` (added under fire today)
- ~5 different victoria-metrics RWO `nodeSelector` pin patches
- The historical TODO list in `AGENTS.md` accumulated stale entries

In each case the reason for the change was clear at the moment, but reading the repo a year later required reverse-engineering from commit messages — which often described **what** without **why**.

## Decision

Adopt **`spec-kit`** ([github/spec-kit](https://github.com/github/spec-kit)) for non-trivial changes to this cluster.

Specifically:

1. Anything matching the trigger list in [Constitution §IX](../../../.specify/memory/constitution.md#ix-spec-driven-development-both) goes through:
   - `/specify` — the user-facing description and acceptance criteria
   - `/plan` — technical approach (which framework, which CRD, which network policy, etc.)
   - `/tasks` — discrete actionable steps a person or agent can do
   - `/implement` — actually doing them

2. Each spec gets a directory under `specs/NNN-<slug>/` with:
   - `spec.md` — the user-level description
   - `plan.md` — the technical decisions
   - `tasks.md` — the actionable list (sometimes flagged `[P]` for parallel)
   - `research.md`, `data-model.md`, `quickstart.md` — as relevant

3. The constitution (`.specify/memory/constitution.md`) is the immovable backstop: every spec/plan must conform.

4. **Decisions outlive specs** — when a spec is complete, the durable lessons get distilled into:
   - `docs/decisions/<scope>/NNNN-<title>.md` — ADRs (this very file is one), where `<scope>` is `shared`, `talos-ii`, or `talos-i`
   - `docs/cluster-definition.md` updates (per-cluster section)
   - `docs/talos-image-factory.md` updates (per-cluster section)

## Scope

In:
- New cluster topology changes (nodes, network, storage classes)
- New apps (anything beyond a `renovate` version bump)
- Architectural decisions (CSI choice, OS choice, ingress strategy)
- Security boundary changes
- Cross-cluster integrations

Out:
- `renovate` PRs that touch only image tags / chart versions
- Pure config tweaks within an existing app (memory limit, replica count for stateless apps)
- Incident response: do what's needed first, write an ADR after if architecture changed

## Alternatives considered

- **No formal process, just AGENTS.md entries** — what we had. Drifted into stale TODOs.
- **Roll our own templates** — the `spec-kit` ones are well-tested and cover the structure we want. Customizing them is allowed but starts from a working baseline.
- **Use a different framework (e.g., Architecture Haiku / C4 modeling)** — heavier, more focused on diagrams than on capturing decisions.

## Consequences

Positive:
- Forces a "why" doc before any large change
- ADRs become a navigable history independent of git
- Slash-commands (`/specify`, `/plan`, `/tasks`, `/implement`) integrate with Claude Code, so the agent uses the same artifacts
- Reduces the chance of repeating mistakes — past ADRs surface as soon as a similar idea is proposed

Negative:
- Overhead for small changes (mitigated by exempting `renovate` and trivial tweaks)
- Adds `.specify/`, `.claude/commands/`, `specs/` to the repo — extra surface for a reader

## ADR numbering across clusters

Each subdirectory under `docs/decisions/` keeps its own counter — `talos-ii/0001`, `talos-i/0001`, and `shared/0001` are all independent series and never renumbered. References between ADRs always use the qualified path (e.g. `talos-ii/0004`), never bare `ADR 0004`.

This matters because:

- A talos-ii architectural choice (e.g. bare metal) must not collide with talos-i's separate decision sequence
- A shared decision (e.g. this ADR) is not "owned" by any single cluster
- New clusters joining the repo just get a new subdirectory and start from `0001`

## How spec-kit was bootstrapped here

1. `specify init --here --ai claude` failed (CLI 0.0.22 expected GitHub release assets that v0.8.x no longer publishes)
2. Manually copied templates and bash scripts from a fresh clone of `github/spec-kit@v0.8.1` into `.specify/`
3. Copied command markdowns to `.claude/commands/` and rewrote `scripts:` frontmatter from `scripts/bash/...` to `.specify/scripts/bash/...` to keep paths consistent
4. Created `.specify/memory/constitution.md` with the multi-cluster constraints
5. Created the first set of ADRs covering the decisions made before spec-kit existed in the repo:
   - `talos-ii/0001`–`0004` (cluster-specific decisions)
   - `shared/0001` (this one)

If `specify` CLI is upgraded later (via `uv tool install`), the `init --here` command will likely still want to merge templates — be careful about regenerating files that have been customized.
