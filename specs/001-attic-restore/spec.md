# Feature Specification: Attic restore on talos-ii (Phase 4a)

**Feature Branch**: `001-attic-restore`
**Created**: 2026-04-29
**Status**: Draft
**Input**: User description: "Restore attic (Nix binary cache server) onto talos-ii — Phase 4a of the swarm-01 → talos-ii migration"

## User Scenarios & Testing *(mandatory)*

### User Story 1 — NixOS host pulls authenticated cache during rebuild (Priority: P1)

A NixOS host in the fleet (managed by the separate Nix fleet repo) runs `nixos-rebuild switch`. The Nix daemon presents a long-lived bearer token via its netrc file to the cluster's binary cache. For every store path that has previously been pushed to the `nix-fleet` cache, the host downloads it from the cluster instead of building locally or hitting `cache.nixos.org`.

**Why this priority**: This is the core value proposition. Without authenticated reads working end-to-end, every NixOS rebuild on every fleet host falls back to compiling from source or pulling from upstream — slow, GFW-fragile, and burns CPU. Every other capability (push, multi-tenant, etc.) is supportive.

**Independent Test**: Mint a pull token for `nix-fleet`, place it in a netrc on a single NixOS host, and run a rebuild. Verify (a) the rebuild completes faster than it would without the cache, (b) `journalctl -u nix-daemon` shows substitutions sourced from the cluster cache, and (c) `https://nix.${SECRET_DOMAIN}/nix-fleet/nix-cache-info` returns 200 with the netrc credentials.

**Acceptance Scenarios**:

1. **Given** a fresh NixOS host with the rotated `nix-fleet` token in its netrc, **When** the operator runs `nixos-rebuild switch`, **Then** previously-pushed store paths download from the cluster cache rather than building from source or fetching from upstream.
2. **Given** a NixOS host without a valid token, **When** it queries `nix-cache-info` against the cache, **Then** the request is rejected with HTTP 401 (no anonymous reads).
3. **Given** the cluster is healthy and the cache contains the requested path, **When** a NixOS host requests it during rebuild, **Then** the response is served by the cluster directly (no upstream proxy hop required).

---

### User Story 2 — Operator pushes a build to the cache (Priority: P2)

An operator (or CI runner) on a NixOS workstation runs `nix copy --to https://nix.${SECRET_DOMAIN}/nix-fleet ...` with a push-capable token. The store paths are uploaded into the cluster's nar-store, are durable across pod restarts, and are immediately available to fleet hosts as cache hits.

**Why this priority**: Without push, the cache stays empty and Story 1 has nothing to serve. But push happens once per build and only from a small number of trusted hosts, so it's logistically simpler and the bar for failure tolerance is lower than reads.

**Independent Test**: From a NixOS workstation, push a known small derivation. Verify the push returns success, then from a different NixOS host (with a pull-only token) confirm the path resolves as a cache hit on the next rebuild.

**Acceptance Scenarios**:

1. **Given** a push token scoped to `nix-fleet` and a healthy cluster, **When** an operator runs `nix copy --to ...`, **Then** the upload succeeds and the path is immediately retrievable.
2. **Given** the cluster is restarted (pod reschedule), **When** an operator queries previously-pushed paths, **Then** they are still served (state is durable, not in-memory only).

---

### User Story 3 — Operator rotates the shared `nix-fleet` token (Priority: P3)

The shared NixOS-fleet token (currently in `secrets/shared/attic.yaml` of the Nix fleet repo) is rotated — either on the standard 1-year cadence, or early if a host is decommissioned or the token is suspected exposed. The operator mints a new token in the cluster, distributes it to all fleet hosts via the SOPS-encrypted shared secret, then revokes the old token.

**Why this priority**: Rotation is a periodic operations task with a known runbook; correctness matters more than convenience. Less critical than the day-to-day pull/push paths but still a must-have for the migration to be considered complete.

**Independent Test**: Mint a replacement token, update the shared secret, rebuild one fleet host, verify it can still pull. Then revoke the old token, attempt to use it, verify rejection. Then rebuild a second fleet host with the new token to confirm the rotation propagates.

**Acceptance Scenarios**:

1. **Given** an authorized operator with cluster access, **When** they invoke the documented token-mint procedure, **Then** a new token with the requested validity and scope is produced and the procedure is reproducible from the runbook alone (no tribal knowledge required).
2. **Given** an old token has been revoked, **When** any client attempts to use it, **Then** the request is rejected with HTTP 401.

---

### Edge Cases

- **Upstream cache (`cache.nixos.org`) unreachable from cluster**: A pull-through miss when egress is broken should fail fast and surface a clear error, not hang for minutes. The egress path through the in-cluster sing-box must be the only routing — no silent fallback to direct egress that would be GFW-blocked.
- **Postgres unavailable**: If the metadata DB is down (CNPG primary failover, replica lag), pulls of already-stored paths should still succeed if technically possible; pushes should fail cleanly rather than partially write.
- **Storage near full**: At 100Gi the nar-store will fill with sustained pushes. The system should expose enough signal (PVC fill metric, attic logs) for the operator to notice before writes start failing, but no automatic GC is in scope for this restore.
- **Token leaked**: An operator who suspects a token is compromised must be able to revoke it without service interruption to other tokens. Multi-token support exists upstream and must remain functional.
- **Container image unavailable from LAN zot**: The `ghcr.io/zhaofengli/attic:latest` image must be cacheable through the LAN zot mirror. If `latest` is unstable, pin to a digest or named tag — but the deploy must not depend on a direct ghcr.io fetch from the cluster.
- **First-deploy DB schema migration**: The attic process expects to run schema migrations on its first connect. CNPG must accept these from the application user (not just superuser).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The cluster MUST host an attic binary-cache server reachable at `https://nix.${SECRET_DOMAIN}` from the public internet (via Cloudflare Tunnel + envoy-external) and at the same hostname from the tailnet.
- **FR-002**: The server MUST require authentication for all cache reads and writes — there MUST be no anonymous (unauthenticated) access path.
- **FR-003**: The server MUST persist its nar-store (uploaded store paths) across pod restarts and node reschedules. The store MUST survive single-node failure (storage replication).
- **FR-004**: The server MUST persist its metadata (cache definitions, token records, path index) in a Postgres database that survives single-node failure (multi-replica with automatic failover).
- **FR-005**: The Postgres major version MUST match the swarm-01 attic database (PG 16) so that the same client/server protocol expectations hold; this is a fresh deploy with no data import, but version-pinning prevents protocol drift if a future need to import emerges.
- **FR-006**: The server MUST be able to fetch from upstream binary caches (`cache.nixos.org` and any configured S3 fronts) for paths it doesn't have locally. All such egress MUST traverse the in-cluster sing-box proxy — no direct cluster-to-internet egress for this workload.
- **FR-007**: The server's container image MUST be pulled through the LAN zot mirror at `172.16.80.240:5000`, not directly from `ghcr.io`. The ghcr.io mirror entry already exists on Talos nodes; this requirement is to confirm no new direct-egress dependency is introduced.
- **FR-008**: An authorized operator MUST be able to mint a new pull-only or push-capable token, scoped to a named cache (`nix-fleet`), with a configurable validity period, using a documented procedure that is reproducible from the runbook alone.
- **FR-009**: An authorized operator MUST be able to revoke an existing token without disrupting other valid tokens.
- **FR-010**: All cluster-level configuration (HelmRelease, secrets, HTTPRoute, PVC, CNPG cluster, Tailscale service) MUST be declared as code in the swarm repo under `kubernetes/apps/nix/attic/` and reconciled by Flux. There MUST be no manual `kubectl apply` steps required for the cluster-side deploy.
- **FR-011**: All secrets (DB DSN, attic JWT signing key, etc.) MUST be SOPS-encrypted in the repo — no plaintext secrets at rest in git.
- **FR-012**: Public exposure MUST go through envoy-external (Cloudflare Tunnel), not envoy-internal. The cache must be reachable from a NixOS host outside the home network without requiring tailnet access.
- **FR-013**: Tailnet exposure MUST be available (per the standard tailscale-operator annotation pattern) so that hosts already on the tailnet can reach the cache without going through Cloudflare. This avoids hitting Cloudflare body-size or rate limits for big nar uploads.
- **FR-014**: The repo's documentation index (`docs/index.md`) MUST list both the new ADR and the new operations runbook in the same commit that introduces them.
- **FR-015**: An ADR documenting the CNPG-vs-bitnami decision and PG version pin MUST exist at `docs/decisions/talos-ii/0011-attic-cnpg.md`, parallel in style to ADRs 0008–0010.
- **FR-016**: An operations runbook MUST exist at `docs/operations/attic-restore.md` covering: first-deploy verification, the token-mint procedure, the fleet-rollout procedure, and the revoke procedure.

### Key Entities *(include if feature involves data)*

- **Cache (`nix-fleet`)**: A named binary cache within attic. Backed by the nar-store (file blobs in the PVC) and a row set in the metadata DB. The default and currently only cache for this restore.
- **Token**: A bearer credential, scoped to one or more caches with `pull` and/or `push` permissions, with an optional validity window. Issued and revoked by `atticadm`. Distributed to NixOS hosts via the Nix-fleet repo's shared SOPS secret.
- **Nar-store entry**: A content-addressed file representing a Nix store path's archive. Lives on the PVC; metadata in Postgres.
- **HelmRelease (`attic`)** and **HelmRelease/Cluster (`attic-postgresql` → CNPG `Cluster`)**: The cluster-side declarations Flux reconciles to bring up the workload.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A NixOS fleet host with the rotated `nix-fleet` token completes a `nixos-rebuild switch` substituting from the cluster cache (vs. building from source or fetching upstream) within a representative time budget — concretely, a rebuild that previously took N minutes against `cache.nixos.org` directly takes the same or less against the cluster cache once paths are populated.
- **SC-002**: An unauthenticated `curl https://nix.${SECRET_DOMAIN}/nix-fleet/nix-cache-info` returns HTTP 401, demonstrating no anonymous read path exists.
- **SC-003**: An authenticated bearer-token request to `https://nix.${SECRET_DOMAIN}/_api/v1/cache-config/nix-fleet` returns HTTP 200 with the expected JSON cache descriptor.
- **SC-004**: After a forced restart of the attic pod, all previously-pushed paths remain retrievable (state durability check).
- **SC-005**: After a forced failover of the CNPG primary, the cache resumes serving reads within the documented CNPG failover window without operator intervention.
- **SC-006**: The complete restore (manifests merged, Flux reconciled, token rotated, fleet hosts switched over) is achievable by following the runbook alone — no out-of-band knowledge required.

## Assumptions

- The in-cluster sing-box (`network/sing-box`) is healthy and reachable at the documented service URL (`http://sing-box.network.svc.cluster.local:7890`). This is a hard dependency; out-of-scope to re-establish here.
- The LAN zot mirror at `172.16.80.240:5000` is healthy and has the existing ghcr.io upstream-sync configured. This is the de-facto image-pull source for the cluster (per the existing `templates/config/talos/patches/global/machine-registries.yaml.j2`).
- CloudNativePG operator v1.29+ is already installed in the cluster (per Phase 3b). No operator install is in scope.
- The `talos-ii` cluster has a working envoy-external Gateway listening on the public hostname pattern and a working envoy-internal Gateway listening on `*.svc.cluster.local` and the LAN LB IP — same as used by Phase 3 apps.
- SOPS+age encryption is wired up via the existing `templates/overrides/kubernetes/components/sops/` pattern. New secret files placed under `kubernetes/apps/nix/attic/` will be encrypted with the project's age key.
- The existing `secrets/shared/attic.yaml` in the separate Nix-fleet repo will be updated manually by the operator after the new token is minted. The Nix-fleet repo is not modified by this feature.
- No state migration from the swarm-01 attic instance is required. The nar-store starts empty; fleet hosts will re-push paths as they rebuild. This is acceptable because attic is content-addressable — there's no semantic loss, only a one-time bandwidth/CPU cost.
- The 100Gi nar-store size matches swarm-01's existing allocation; no resizing decision is in scope.
- Multi-tenant subcaches beyond `nix-fleet` are out of scope. If/when other caches (e.g. per-developer scratch caches) are needed, they'll be added in a follow-up spec.
- The "remove zot from LAN host, run zot in-cluster" migration is a separate piece of work (tracked in project memory) and is **not** a dependency of this restore. Attic depends only on the LAN zot continuing to exist for the duration of this work.
