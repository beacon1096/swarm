# Feature Specification: OpenStatus monitoring on talos-ii

**Feature Branch**: `006-openstatus-monitoring`
**Created**: 2026-05-14
**Status**: Draft
**Input**: User description: "Add self-hosted OpenStatus as the uptime/status monitoring service for talos-ii, effectively replacing the planned role of uptime-kuma, not replacing an existing deployment. Keep this as a minimal reliable MVP."

## Scope

**Target cluster: `[talos-ii]` only.** This feature introduces OpenStatus as a new GitOps-managed monitoring/status service. It does not remove or migrate an existing uptime-kuma deployment; it supersedes only the planned role uptime-kuma would have filled.

The MVP is intentionally narrow: OpenStatus is reachable, persistent state is configured, required secrets and environment variables are documented and SOPS-managed, one in-cluster private location can run checks, Tinybird-local is enabled for check history, and a basic health path is validated. Advanced alerting, third-party integrations, multi-region probes, historical imports, custom domains beyond the MVP HTTPRoute, and status-page customization are deferred. OpenStatus is selected partly because its API-key based MCP server can later let AI assistants read and manage status pages, incidents, reports, and maintenance windows.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Operator opens the OpenStatus web UI (Priority: P1)

An operator can reach the OpenStatus dashboard through the cluster Gateway API route and authenticate using the configured self-hosted auth path.

**Why this priority**: If the UI is not reachable and authenticated, the service cannot be administered or used as the uptime/status platform.

**Independent Test**: After Flux reconciliation, open the configured HTTPRoute hostname and verify the dashboard responds with an HTTP 200 or expected auth redirect, then complete login with the configured auth mechanism.

**Acceptance Scenarios**:

1. **Given** Flux has reconciled the OpenStatus manifests, **When** the operator visits the configured dashboard hostname, **Then** the request routes through the Gateway API HTTPRoute to the OpenStatus dashboard service.
2. **Given** `AUTH_SECRET`, `SELF_HOST=true`, and OAuth provider credentials are configured, **When** the operator signs in, **Then** a workspace can be created without manual pod access.
3. **Given** OpenStatus is exposed through a non-Vercel reverse proxy, **When** any IP-restriction feature is considered, **Then** it is treated as out of scope for MVP unless the reverse proxy strips and rewrites `X-Forwarded-For`.

---

### User Story 2 - OpenStatus persists monitoring data (Priority: P1)

OpenStatus retains workspace, monitor, status-page, and check result data across pod restarts using cluster-managed persistent storage.

**Why this priority**: Monitoring history and configuration are the only durable value of this service. An ephemeral deployment would not be a reliable replacement for the planned uptime-kuma role.

**Independent Test**: Create a workspace and HTTP monitor, restart OpenStatus pods, and verify the workspace, monitor, and recent check state remain present.

**Acceptance Scenarios**:

1. **Given** the OpenStatus datastore pod is restarted, **When** the web UI comes back, **Then** previously created workspace and monitor records are still present.
2. **Given** the OpenStatus Tinybird-local component is restarted, **When** check history is viewed, **Then** recent check data remains available from persistent storage.
3. **Given** the user preference for cluster-managed PostgreSQL where applicable, **When** implementation begins, **Then** PostgreSQL is used only if upstream OpenStatus supports it; otherwise the documented libSQL datastore is deployed with Longhorn-backed persistence.

---

### User Story 3 - talos-ii services are monitored by a private location (Priority: P1)

A self-hosted private location probe runs inside talos-ii and checks at least one cluster service through the self-hosted OpenStatus ingest/API path.

**Why this priority**: OpenStatus self-hosting currently depends on private locations for checks. Without a probe, the UI may work but monitoring does not.

**Independent Test**: Configure one HTTP monitor for a known internal or public endpoint and verify check results appear in OpenStatus from the talos-ii private location.

**Acceptance Scenarios**:

1. **Given** a private location is registered, **When** its pod starts with `OPENSTATUS_KEY` and `OPENSTATUS_INGEST_URL`, **Then** it reports healthy to the OpenStatus server.
2. **Given** a monitor targets the selected health endpoint, **When** the private location checks it, **Then** the result appears in the dashboard within one check interval.
3. **Given** the cluster egress path relies on sing-box for public traffic, **When** the private location checks a public endpoint, **Then** the implementation follows the existing cluster egress conventions and does not introduce a direct-leak exception.

---

### User Story 4 - A minimal public status page can be served (Priority: P2)

A basic status page is reachable through Gateway API so external users can see service status once monitors are configured.

**Why this priority**: Status publication is useful but secondary to bringing up reliable monitoring and administration.

**Independent Test**: Create a basic status page, attach one monitor, and verify the status-page route renders through the configured hostname.

**Acceptance Scenarios**:

1. **Given** a status page exists, **When** the configured status hostname is requested, **Then** the status page renders through an HTTPRoute without exposing admin-only services unnecessarily.
2. **Given** no custom branding or custom-domain automation is configured, **When** the status page renders, **Then** the default OpenStatus page is acceptable for MVP.

### Edge Cases

- **No official Kubernetes chart**: Upstream self-hosting is Docker Compose-oriented, but upstream publishes pre-built GHCR images for the app services. Implementation should use those images via the in-cluster zot ghcr.io pull-through cache and pin tags/digests deliberately.
- **Database mismatch**: Upstream self-hosting documents `DATABASE_URL=http://libsql:8080`; PostgreSQL must not be substituted unless upstream support is verified.
- **Tinybird-local persistence**: Upstream marks Tinybird as optional in env comments but self-hosting docs use it for analytics. MVP enables Tinybird-local and must persist it.
- **OAuth dependency**: MVP uses OAuth instead of magic-link email. Implementation must configure supported OAuth credentials and callback URLs before claiming UI login is complete.
- **Reverse-proxy headers**: OpenStatus IP restriction is not secure outside Vercel unless the proxy rewrites `X-Forwarded-For`; MVP must not advertise IP-restricted status pages.
- **Service startup ordering**: server/dashboard/status-page depend on datastore and workflows readiness; Kubernetes probes must prevent routes from serving broken startup states.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: OpenStatus MUST be deployed only to the talos-ii cluster through Flux-managed manifests in this repository.
- **FR-002**: The implementation MUST NOT remove, migrate, or reference an existing uptime-kuma deployment as a source of state; OpenStatus is a new deployment replacing only the planned monitoring role.
- **FR-003**: The MVP MUST include the OpenStatus dashboard, API/server, workflows/scheduler, datastore, private-location probe, and status-page component unless implementation research proves a smaller supported topology.
- **FR-004**: The dashboard web UI MUST be exposed through Gateway API HTTPRoute using the existing cluster ingress conventions.
- **FR-005**: The status-page component SHOULD be exposed through a separate HTTPRoute or route rule from the admin dashboard when feasible.
- **FR-006**: All secrets MUST be SOPS-encrypted before commit, including at minimum `AUTH_SECRET`, OAuth provider secret, `CRON_SECRET`, `SUPER_ADMIN_TOKEN` if used, `TINY_BIRD_API_KEY`, and private-location `OPENSTATUS_KEY` values.
- **FR-007**: Persistent state MUST use cluster-managed storage. If PostgreSQL is upstream-supported, use the existing cluster-managed PostgreSQL pattern; if not, deploy upstream-supported libSQL on Longhorn-backed storage.
- **FR-008**: The implementation MUST document all required environment variables and which Kubernetes Secret or ConfigMap provides each one.
- **FR-009**: The private-location probe MUST be configured with `OPENSTATUS_INGEST_URL` pointing at the self-hosted OpenStatus API path, not the hosted OpenStatus service.
- **FR-010**: The deployment MUST provide Kubernetes readiness/liveness checks for externally routed services and datastore-dependent components. The minimum accepted health endpoints are `/` for dashboard/status-page and `/ping` or upstream-equivalent for server/workflows.
- **FR-011**: The deployment MUST avoid NodePort and direct manual `kubectl apply` for steady state.
- **FR-012**: The MVP MUST include one documented smoke-test monitor for a basic health path.
- **FR-013**: Advanced alerting channels, paid-feature unlock automation, multi-region probes, historical imports, Terraform/CLI monitor management, and custom status-page theming MUST be deferred unless required for basic operation.
- **FR-014**: Any public exposure MUST follow the repository's Gateway/Cloudflare Tunnel default unless a later spec records a concrete exception.

### Key Entities

- **OpenStatus dashboard**: Admin UI for workspace, monitor, and status-page management. Upstream Docker Compose port 3002.
- **OpenStatus server/API**: Backend API used by dashboard, status-page, workflows, and private-location ingest. Upstream Docker Compose maps service port 3001 to container port 3000.
- **OpenStatus workflows**: Background jobs and scheduled tasks. Upstream Docker Compose port 3000 and health path `/ping`.
- **OpenStatus status-page**: Public status page renderer. Upstream Docker Compose port 3003.
- **Private location**: Probe container that executes checks and reports results to the self-hosted API using `OPENSTATUS_KEY` and `OPENSTATUS_INGEST_URL`.
- **Datastore**: Upstream documented libSQL service, or PostgreSQL only if implementation research confirms support.
- **Analytics store**: Tinybird-local for check history and charts.
- **MCP server**: OpenStatus API-key authenticated Streamable HTTP endpoint used by AI assistants for status pages, status reports, and maintenance windows. MCP client configuration is post-MVP, but the deployment should preserve the API/token path required to enable it later.
- **SOPS Secret**: Encrypted Kubernetes Secret containing auth, ingest, analytics, email, and admin tokens.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `kubectl` shows all OpenStatus MVP pods ready after Flux reconciliation with no CrashLoopBackOff.
- **SC-002**: The dashboard HTTPRoute returns HTTP 200 or an expected auth response from outside the cluster ingress path.
- **SC-003**: An operator can create a workspace and one HTTP monitor from the UI.
- **SC-004**: Restarting OpenStatus application pods does not lose workspace or monitor configuration.
- **SC-005**: A private-location check result appears in the dashboard within one configured interval.
- **SC-006**: All required secrets are SOPS-encrypted in git and no plaintext token/password appears in `git diff`.
- **SC-007**: No Talos node reboot, machine-config change, or destructive storage operation is required for the MVP.

## Assumptions

- Existing Flux, Gateway API, Cloudflare Tunnel, SOPS, Longhorn, and sing-box patterns remain available on talos-ii.
- OpenStatus upstream self-hosting docs are the source of truth unless implementation research finds a maintained Helm chart or Kubernetes deployment guide.
- The MVP public hostname is `status.beaco.works`. If dashboard and public status-page cannot safely share this host by path/routing, reserve a second hostname before manifest authoring.
- Upstream publishes pre-built images for `openstatus-server`, `openstatus-dashboard`, `openstatus-workflows`, `openstatus-private-location`, `openstatus-status-page`, and `openstatus-checker`; use zot to cache GHCR pulls instead of adding an internal build pipeline for MVP.
