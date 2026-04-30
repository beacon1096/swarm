# Feature Specification: zot OCI mirror in-cluster on talos-ii (Phase 4b)

**Feature Branch**: `002-zot-on-talos-ii`
**Created**: 2026-04-29
**Status**: Draft
**Input**: User description: "Migrate zot OCI mirror registry from LAN proxy host (172.16.80.240:5000) into the talos-ii cluster as Phase 4b"

## Scope

**Target cluster: `[talos-ii]` only.** This feature deploys zot exclusively on the talos-ii cluster. It MUST NOT be deployed on talos-i. talos-i consumes the same registry via Tailscale egress against the talos-ii-hosted instance — a single point of deployment with cross-cluster consumption. This scoping is a hard constraint per the project's per-cluster scoping rule (avoid the duplicate-deploy / wasted-storage anti-pattern that accumulated in the predecessor `swarm-01` repository).

This phase migrates the OCI pull-through cache from the LAN host `172.16.80.240:5000` into the cluster. The LAN host remains running until a later, separately-tracked decommissioning phase. Image content is **not** migrated; the in-cluster instance re-fills its cache on demand.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — talos-ii containerd pulls images via in-cluster zot (Priority: P1)

A Pod scheduled on a talos-ii node references an image whose registry (e.g. `mirror.gcr.io/coredns/coredns:1.13.1`, `ghcr.io/...`, `registry.k8s.io/...`) is configured as a Talos mirror endpoint pointing to the in-cluster zot Service. containerd resolves the mirror, fetches the manifest and layers from in-cluster zot, and the Pod reaches `Running` without traversing the LAN host or the public internet directly.

**Why this priority**: This is the core value. Until talos-ii nodes pull through the in-cluster zot, the LAN host is still load-bearing, the chicken-and-egg architecture persists, and the predecessor anti-pattern is unfixed. Every other story is supportive.

**Independent Test**: Pick a known image not yet cached anywhere (or use a fresh tag), schedule a Pod referencing it on talos-ii, and verify (a) the Pod reaches `Running`, (b) the in-cluster zot UI / API confirms the image was synced from upstream, and (c) the LAN host's zot logs show no request for the same image during the test window.

**Acceptance Scenarios**:

1. **Given** the in-cluster zot is healthy and the Talos `machine.registries.mirrors` configuration points to its in-cluster Service, **When** a fresh Pod requests `mirror.gcr.io/coredns/coredns:1.13.1`, **Then** containerd pulls successfully from the in-cluster zot, the image lands on the node, and the Pod reaches `Running`.
2. **Given** the in-cluster zot has previously cached an image, **When** a second talos-ii node pulls the same image, **Then** the request is served from local cache (no upstream sync), measurably faster than the first pull.
3. **Given** the in-cluster zot has anonymous read enabled, **When** any talos-ii containerd makes a `/v2/` mirror request without credentials, **Then** the request succeeds (no 401).

---

### User Story 2 — talos-i consumes the same registry across clusters via tailnet (Priority: P1)

A Pod on the talos-i cluster (which is **not** in this repository, has no zot of its own, and must not get one) references an image whose mirror endpoint resolves through the tailnet to the talos-ii-hosted zot's Tailscale ingress. containerd on talos-i pulls successfully without the LAN host being involved and without talos-i having its own zot replica.

**Why this priority**: This story validates the per-cluster scoping principle in production. If talos-i can't reach the talos-ii zot via tailnet, the temptation to "just deploy zot on talos-i too" returns and the architectural rule fails. Equally critical with Story 1.

**Independent Test**: From a talos-i node (or any tailnet host with kube access to talos-i), schedule a Pod referencing an image whose mirror routes via the tailnet hostname of the talos-ii zot. Verify the Pod reaches `Running` and that the talos-ii zot logs show the corresponding pull request.

**Acceptance Scenarios**:

1. **Given** the in-cluster zot is exposed on the tailnet at a stable hostname, **When** a talos-i node's containerd is configured to use that tailnet hostname as a mirror endpoint, **Then** image pulls on talos-i succeed end-to-end.
2. **Given** the talos-ii zot is the sole registry deployment, **When** the operator audits both clusters' manifests and namespaces, **Then** there is no `zot` HelmRelease, Service, or PVC on talos-i.

---

### User Story 3 — LAN host zot can be taken offline without breaking image pulls (Priority: P2)

The operator simulates a LAN-host outage (e.g. blocks egress to `172.16.80.240:5000` from cluster nodes, or stops the host process) to confirm both clusters' image pulls have fully migrated. New image pulls on both clusters continue to succeed; only previously-cached state on the LAN host (which is content-addressable and can be re-fetched) becomes unreachable.

**Why this priority**: This is the migration-completion gate. Until the LAN host can be removed from the hot path without breakage, Phase 4b is not done and the chicken-and-egg architecture is unresolved.

**Independent Test**: Apply a Talos node firewall rule (or analogous mechanism) that drops traffic to `172.16.80.240:5000` from the talos-ii nodes; on talos-i apply the equivalent. Trigger a fresh pull on each cluster (a new tag or a previously-uncached image) and verify success. Restore the LAN host afterward.

**Acceptance Scenarios**:

1. **Given** all Talos `machine.registries.mirrors` entries on talos-ii point to the in-cluster zot Service, **When** the LAN host is unreachable, **Then** new image pulls on talos-ii succeed by syncing upstream through the in-cluster zot.
2. **Given** the talos-i mirror configuration points to the in-cluster zot's tailnet hostname, **When** the LAN host is unreachable, **Then** new image pulls on talos-i succeed by the same path.
3. **Given** the migration is complete, **When** `task configure` re-renders the talos-ii machine-config, **Then** no rendered output contains the literal string `172.16.80.240`.

---

### User Story 4 — Operator updates a mirror upstream list without reboots (Priority: P3)

The operator adds a new upstream registry (or removes one) to the in-cluster zot configuration. The change is reconciled by Flux. New pulls for the added upstream succeed without restarting Talos nodes or rolling pods unrelated to zot. talos-ii machine-config changes (when needed) are applied as configuration patches that trigger a containerd reload, not a full node reboot, unless an explicit reboot is justified in the change description.

**Why this priority**: Day-2 ergonomics. Once deployed, upstream lists evolve (new private registries, new mirror sources). This must not become a reboot-driving chore — that violates the project's "no surprise reboots" principle.

**Independent Test**: Add one new upstream registry to the helmrelease values, commit, and observe Flux reconcile the change. Then push a Pod referencing an image from that new upstream and verify the pull succeeds. Verify no Talos node was rebooted during the change.

**Acceptance Scenarios**:

1. **Given** an operator adds a new entry to the zot upstream list, **When** Flux reconciles the change, **Then** the zot pod restarts (or hot-reloads, depending on chart support) and new pulls for the added upstream succeed.
2. **Given** the operator changes only the zot configuration (no Talos machine-config change), **When** the change is reconciled, **Then** no Talos node reboot is observed in the cluster event stream.

---

### Edge Cases

- **Upstream registry unreachable from in-cluster sing-box**: When sing-box egress fails or the upstream itself is down, zot's on-demand sync must fail fast (not hang for minutes), and previously-cached images must continue to serve. No silent fallback to direct egress that bypasses sing-box.
- **Egress proxy whitespace / trailing-dot quirks**: HTTP_PROXY / HTTPS_PROXY / NO_PROXY env vars must include the trailing-dot variant of in-cluster service names (cf. attic precedent), or in-cluster sync requests for `cluster.local.` style names will silently route through the proxy and fail.
- **Large blob (multi-GB) sync through sing-box**: First-pull of a large image through the in-cluster sing-box must succeed end-to-end without truncation or proxy timeout. If sing-box's default buffers/timeouts can't handle multi-GB blobs, that is a sing-box configuration issue surfaced by zot, not a zot-side workaround.
- **Storage filling up**: Longhorn-r2 PVC has a finite size. Once full, on-demand sync of new content will start failing. Operator must have observable signal (PVC fill metric) before failures occur. Automated GC tuning is in scope; automated PVC expansion is not.
- **zot's own container image**: zot's `ghcr.io/project-zot/zot-linux-amd64` image must itself be pullable. Bootstrapping order requires that the image be available either from the LAN zot (during transition) or from the in-cluster zot's own cache once primed; on a cold-cluster restart, the image must come from a path that doesn't require zot to already be running. (Resolution path is Plan-stage research — see Assumptions.)
- **Cross-cluster TLS / certificate chain on tailnet path**: talos-i pulls through the tailnet hostname of the talos-ii zot. The hostname's TLS chain (Tailscale-issued vs operator-managed) and containerd's trust configuration must align — or the mirror must be explicit-HTTP if that's the agreed posture. A `[NEEDS CLARIFICATION]` exists below for the precise transport choice.
- **Talos config patch propagation**: Updating `machine-registries.yaml.j2` regenerates each node's machine-config. The change must reach all three nodes safely. The spec MUST be explicit about whether containerd reloads suffice or whether a reboot is required (no surprise reboots).

## Requirements *(mandatory)*

### Functional Requirements

#### Deployment scope

- **FR-001**: The in-cluster zot deployment MUST exist only on the **talos-ii** cluster. There MUST be no zot HelmRelease, Service, PVC, Tailscale ingress, or related manifest on the talos-i cluster.
- **FR-002**: All cluster-side configuration (HelmRelease, secrets, Service exposures, PVC) MUST be declared as code under `kubernetes/apps/registry/zot/` in this repository and reconciled by Flux. There MUST be no manual `kubectl apply` for the steady-state deploy.
- **FR-003**: All credentials (push admin token / htpasswd entry, any additional secrets) MUST be SOPS-encrypted in the repo — no plaintext at rest in git.

#### Registry capability

- **FR-004**: The in-cluster zot MUST act as an OCI pull-through cache: for upstream registries listed in its configuration, on a request for an uncached image it MUST fetch from the upstream, store locally, and serve subsequent requests from local storage.
- **FR-005**: The configured upstream registry list MUST include at minimum: `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `mirror.gcr.io`, `gcr.io`, `code.forgejo.org`, `docker.elastic.co`, `docker.n8n.io`, `cache.nixos.org`. The `mirror.gcr.io` entry is required (resolves the immediate talos-i CoreDNS pull-failure trigger). The `gcr.io` entry is required per operator request.
- **FR-006**: The configured upstream list MUST be a strict superset of the upstreams currently mirrored by the LAN host zot, so that no current image-pull path regresses on cutover. [NEEDS CLARIFICATION: The current LAN host zot configuration on `172.16.80.240` should be enumerated to confirm completeness; any upstream there but not listed in FR-005 must be added before Phase 4b is closed.]
- **FR-007**: Anonymous read access MUST be permitted for all repositories so that talos-ii containerd (which has no credentials configured for the mirror) can pull without authentication.
- **FR-008**: Push access MUST require an admin credential. The admin credential is used only by operators / migration tooling, not by routine image pulls.
- **FR-009**: zot's own container image MUST be pinned by digest (not floating tag) in the repo to ensure deterministic reconciliation.

#### Storage

- **FR-010**: zot's persistent storage MUST use Longhorn with replica count `2` (the project's `longhorn-r2` storage class). Replica count MUST NOT be `3` because the cached content is reproducible by re-syncing from upstream — replica-3 cost is not justified.
- **FR-011**: The PVC MUST be sized to comfortably hold a year of typical pull traffic for this fleet. The exact size is a Plan-stage decision based on observed LAN-zot fill rate; spec-stage minimum is "several hundred GiB" with headroom for growth without expansion churn.

#### Network

- **FR-012**: All zot egress to upstream registries MUST traverse the in-cluster sing-box proxy (`network/sing-box`). Configuration MUST set `HTTP_PROXY` / `HTTPS_PROXY` to the sing-box service URL and a `NO_PROXY` value that includes both the bare and trailing-dot forms of in-cluster service names (matching the attic helmrelease precedent).
- **FR-013**: zot MUST be exposed inside the talos-ii cluster as a stable ClusterIP Service so that talos-ii containerd's `machine.registries.mirrors` entries can target it.
- **FR-014**: zot MUST be exposed on the tailnet so that talos-i containerd (which has no in-cluster path to talos-ii Services) can reach it. The tailnet exposure MUST be implemented through the in-cluster `tailscale-operator` (i.e. a `Service` with the appropriate ProxyClass / annotations), **not** a `NodePort`.
- **FR-015**: zot MUST NOT be exposed publicly. There MUST be no Cloudflare Tunnel route, no public DNS hostname, and no `envoy-external` HTTPRoute targeting zot in this phase.

#### Talos node configuration

- **FR-016**: The Talos machine-config patch (`talos/patches/global/machine-registries.yaml` and its `templates/.../machine-registries.yaml.j2` source) MUST be updated so that mirror endpoints for all registries currently pointing at `http://172.16.80.240:5000` instead point at the in-cluster zot Service URL.
- **FR-017**: After the Talos patch update, `task configure` (or the equivalent re-render path) MUST produce machine-config output that contains zero references to `172.16.80.240`. (This is a verifiable repo-grep check.)
- **FR-018**: The Talos machine-config change MUST be applied to nodes via a path that **does not require a reboot**. If the necessary change can be hot-applied (containerd reload), that path MUST be used. If a reboot is unavoidable, the spec must be amended (with explicit justification) before implementation. [NEEDS CLARIFICATION: confirm at Plan stage that mirror endpoint changes propagate via `talosctl apply --mode=auto` without forcing a node reboot in our current Talos version, given our containerd settings.]
- **FR-019**: Cutover MUST be reversible: if the in-cluster zot fails to serve a critical pull during the rollout, the operator MUST be able to revert the machine-config patch to point back at the LAN host with no more than one reconciliation cycle of disruption.

#### Documentation & process

- **FR-020**: The same commit (or contiguous commit chain) that lands the manifests MUST include: (a) an ADR under `docs/decisions/talos-ii/` recording the in-cluster migration decision, (b) an operator runbook under `docs/operations/` covering deploy / verify / cutover / revert, and (c) any required updates to `docs/index.md` and `docs/cluster-definition.md`.

### Key Entities

- **In-cluster zot Service**: The cluster-internal endpoint (ClusterIP) used by talos-ii containerd as the mirror target for all configured upstream registries.
- **Tailnet zot endpoint**: The Tailscale-operator-published hostname/IP through which talos-i (and any other tailnet consumer) reaches the same registry instance.
- **Upstream registry list**: The set of public registries zot proxies and caches. Treated as configuration data in the helmrelease values, not as Kubernetes objects.
- **zot storage volume**: A Longhorn-backed PVC holding the cached blobs and manifests. Content-addressable, reproducible by re-syncing from upstream.
- **Admin push credential**: A single SOPS-encrypted credential for operator/admin pushes. Not used by routine pulls.
- **Talos `machine.registries.mirrors` configuration**: The Talos node-level mirror map. The artifact updated to redirect `*.io` pulls from the LAN host to the in-cluster Service.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a fresh Pod on a talos-ii node, pulling `mirror.gcr.io/coredns/coredns:1.13.1` via the in-cluster zot succeeds (Pod reaches `Running`) within 5 minutes of scheduling, on the first attempt, with no manual intervention.
- **SC-002**: From a Pod on a talos-i node, pulling the same image via the talos-ii zot's tailnet endpoint succeeds within 5 minutes on the first attempt.
- **SC-003**: With the LAN host zot deliberately made unreachable (firewall drop or process stopped), both clusters can still pull at least one new (uncached) image to completion.
- **SC-004**: After cutover, a repo-wide grep for the literal `172.16.80.240` in rendered machine-config output (post-`task configure`) returns zero matches.
- **SC-005**: After cutover, the talos-i cluster has zero zot-related Kubernetes objects (HelmRelease, Service, Deployment, PVC, ConfigMap with zot config, Secret containing zot credentials) — verifiable by namespace/label scan.
- **SC-006**: A second pull of any previously-cached image on talos-ii completes faster than the corresponding first pull (cache-hit path observable as substantially lower latency than upstream-sync path); a single repeated pull of a representative image is sufficient signal.
- **SC-007**: The migration introduces zero unplanned Talos node reboots. Any reboot during Phase 4b that is not pre-declared in the runbook is a defect.
- **SC-008**: After rollout, sustained image-pull throughput from talos-ii nodes meets or exceeds the throughput previously observed against the LAN host zot under comparable conditions (no measurable performance regression for steady-state pulls). [NEEDS CLARIFICATION: define the throughput baseline — is it sufficient to say "qualitatively no slower than LAN zot" or do we want a numeric MB/s target captured during the runbook?]

## Assumptions

- **In-cluster sing-box is healthy and capacity-sufficient**: zot's upstream sync may push multi-GB blobs through sing-box. Sing-box is assumed to handle the throughput; if not, that's a separate sing-box-tuning issue surfaced (but not fixed) by this work.
- **Cilium L2 announce pool has capacity**: If the chosen exposure design needs an additional LB IP, the `cilium-l2` pool has at least one free address.
- **Longhorn-r2 has node-side capacity**: Each MS-01 NVMe partition has enough free space for a several-hundred-GiB replica of the zot PVC. (Concrete sizing is a Plan-stage decision.)
- **No data migration**: zot content is content-addressable; the in-cluster instance re-fetches everything on first miss. The LAN host's existing cache is **not** copied. This trades a one-time re-sync cost for migration simplicity.
- **LAN host stays online during transition**: The LAN host zot at `172.16.80.240:5000` continues running through this phase. It is taken offline only as part of an explicit, separately-tracked decommissioning phase, after Phase 4b's acceptance criteria are met.
- **talos-i CoreDNS image-pull failure resolves indirectly**: The talos-i CoreDNS chart 1.45.2 default image (`mirror.gcr.io/coredns/coredns:1.13.1`) currently fails to pull on talos-i nodes due to absent registry mirror / spegel / HTTP_PROXY paths. This spec does **not** fix that directly; it provides the in-cluster zot whose tailnet endpoint, once consumed by talos-i, resolves the symptom. Wiring talos-i to consume that endpoint is **out of scope** for Phase 4b and tracked separately.
- **swarm-01 zot manifests as read-only reference**: The predecessor repo's `kubernetes/apps/registry/zot/app/` manifests (helmrelease, helmrepository, httproute, service-tailscale, secret.sops) inform the structure of this work but are NOT migrated as-is. This phase produces a fresh adaptation that honors talos-ii constraints and the per-cluster scoping principle.
- **OCI manifest format compatibility for zot's own image**: zot's `ghcr.io/project-zot/zot-linux-amd64` may or may not need re-conversion to OCI manifest format on first cache (cf. attic precedent). Resolving this is a Plan-stage research item, not a spec-stage decision.
- **Talos containerd hot-reloads mirror endpoints**: The mirror-endpoint change in Talos's `machine.registries.mirrors` is assumed to apply via configuration-only path (containerd reload, not full reboot) on the current Talos version. This is the explicit-non-reboot requirement of FR-018; it MUST be confirmed during Plan stage.

## Out of Scope

This section is explicit about what Phase 4b does **not** do. Each item is a deliberate exclusion, not an oversight.

- **Migrating cached blobs from LAN zot**: Content is reproducible; re-fill is acceptable. No `skopeo sync` / image-by-image copy step.
- **Decommissioning the LAN host zot**: Phase 4b leaves the LAN host running. A later phase (separately tracked) handles deprovisioning, host reuse, or cold-standby promotion.
- **Public exposure of the in-cluster zot**: No Cloudflare Tunnel, no public DNS, no `envoy-external` HTTPRoute. Pull-through caches are an internal capability.
- **Deployment to talos-i**: Per the per-cluster scoping principle, zot is talos-ii-only. talos-i consumes via tailnet against the talos-ii instance and does not get its own zot deployment under any circumstance in this phase.
- **Fixing the talos-i CoreDNS image-pull failure**: That symptom is the trigger that makes this phase urgent, but it's resolved indirectly (once talos-i is wired to consume the in-cluster zot's tailnet endpoint, which is a separate phase). This spec does not modify talos-i directly.
- **Advanced zot features**: No image signing (cosign), no OCI artifact storage beyond standard mirror cache, no signature verification on sync, no per-repository quotas, no RBAC beyond the simple anonymous-read / admin-push split. v1 = mirror cache + sync only.
- **Automatic PVC expansion**: If storage fills, the operator handles it manually following the runbook. Auto-expansion is not configured.
- **Wiring talos-i's `machine.registries.mirrors` to consume the tailnet endpoint**: That is a talos-i-side change in a separate repo (currently `swarm-01`) and is tracked as a follow-up phase, even though it's the consumer side of the same architectural goal.

## Constitution Check

Cross-reference of this spec against the project constitution (`/.specify/memory/constitution.md`, version 1.1.0):

- **Principle II (Storage, [both])**: PASS — uses the `longhorn-r2` Longhorn storage class. No new CSI introduced. Replica count `2` is permitted (default is 2; lift to 3 only for irreplaceable data, which mirror cache is not).
- **Principle IV (Image factory, [talos-ii])**: PASS — zot does not affect Talos image selection or factory choice. No new schematic.
- **Principle V (Secrets, [both])**: PASS — admin credential is SOPS-encrypted (FR-003); no plaintext at rest.
- **Principle VI (Public exposure, [both])**: N/A — no public exposure in this phase (FR-015).
- **Principle VII (Private exposure, [both])**: PASS — talos-i cross-cluster reach is via the in-cluster `tailscale-operator`-managed Service (FR-014). No NodePort.
- **Principle VIII (GitOps, [both])**: PASS — all manifests under `kubernetes/apps/registry/zot/` reconciled by Flux; no manual `kubectl apply` for steady state (FR-002).
- **Principle IX (Spec-Driven Development, [both])**: PASS by construction — this is the `/specify` artifact for the change.
- **Principle X (Documentation, [both])**: PASS by requirement — FR-020 mandates ADR + runbook + index updates in the same commit chain.
- **Principle XI (No surprise reboots / no destructive shortcuts, [both])**: ATTENTION — FR-018 explicitly forbids surprise reboots and requires the Plan stage to confirm hot-reload propagation. One [NEEDS CLARIFICATION] is reserved for this question. If Plan-stage research finds reboot is unavoidable, the spec must be amended before implementation.
- **Per-cluster scoping rule** (project memory `feedback_per_cluster_scoping.md`): PASS — Scope section above explicitly tags `[talos-ii]` only; FR-001 + SC-005 enforce no-deploy-on-talos-i; Out-of-Scope reiterates the same. The predecessor swarm-01 zot directory is treated as read-only reference (per Assumptions), not migrated.
