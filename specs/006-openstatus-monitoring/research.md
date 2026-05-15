# Research: OpenStatus monitoring on talos-ii

## R1 — Upstream self-hosting shape

**Decision**: Treat upstream OpenStatus Docker Compose self-hosting as the initial architecture source.

**Rationale**: The documented self-hosted stack consists of `workflows`, `server`, `dashboard`, `status-page`, `private-location`, `libsql`, and `tinybird-local`. This captures the minimum pieces required for UI, API, scheduling/check execution, persistence, and status pages.

**Consequence**: The Kubernetes MVP is multi-service. A single-container deployment is not assumed unless implementation research finds an upstream-supported all-in-one image.

## R2 — Datastore choice

**Decision**: Use PostgreSQL only if OpenStatus upstream supports it; otherwise use libSQL on Longhorn-backed persistence.

**Rationale**: User preference is cluster-managed PostgreSQL where applicable. Current upstream self-hosting docs and `.env.docker.example` use `DATABASE_URL=http://libsql:8080` and `DATABASE_AUTH_TOKEN`, not PostgreSQL connection variables. Replacing the datastore without upstream support is higher risk than running the documented datastore.

**Consequence**: Plan and tasks include a preflight verification step. If PostgreSQL support is not confirmed, libSQL is the MVP datastore and PostgreSQL is marked not applicable.

## R3 — Image supply

**Decision**: Use upstream pre-built GHCR images through the in-cluster zot ghcr.io pull-through cache.

**Rationale**: Upstream README documents pre-built images for `ghcr.io/openstatushq/openstatus-server`, `openstatus-dashboard`, `openstatus-workflows`, `openstatus-private-location`, `openstatus-status-page`, and `openstatus-checker`. The cluster zot configuration already includes an on-demand `https://ghcr.io` sync source, so the MVP can pull these images through zot instead of building internally.

**Consequence**: Implementation should resolve immutable tags or digests for the upstream images and use the zot cache path. No internal image build/publish pipeline is required for MVP unless upstream removes the images or a required component is missing.

## R4 — Exposure model

**Decision**: Use Gateway API HTTPRoute for the dashboard and status-page paths/hosts; avoid NodePort and avoid relying on OpenStatus IP restriction for MVP.

**Rationale**: The repository constitution defaults public HTTP services to Gateway/Cloudflare Tunnel. OpenStatus self-hosting docs warn IP restriction is unsafe behind non-Vercel proxies unless `X-Forwarded-For` is stripped and rewritten.

**Consequence**: The MVP can be public only behind OpenStatus authentication. IP-restricted pages are explicitly out of scope.

## R5 — Auth and secrets

**Decision**: SOPS-manage all secrets and use OAuth for MVP login.

**Rationale**: Upstream marks `AUTH_SECRET`, `SELF_HOST=true`, and `NEXT_PUBLIC_URL` as required. The user chose OAuth over magic-link email, so the MVP should avoid Resend unless upstream still requires it at runtime.

**Consequence**: Tasks require choosing and configuring a supported OAuth provider and callback URL before exposing the dashboard route as complete.

## R7 — MCP support

**Decision**: Treat OpenStatus MCP support as a selection driver and post-MVP enablement path, not as an initial deployment blocker.

**Rationale**: OpenStatus exposes a Streamable HTTP MCP endpoint authenticated with the same `x-openstatus-key` API key used by REST/ConnectRPC. MCP can list and mutate status pages, status reports, and maintenance windows depending on API-key scope.

**Consequence**: MVP must preserve API-token creation and server/API reachability needed for later MCP use. Creating an MCP client config and long-lived read/write API key is deferred until after login, workspace, and status page are validated.

## R6 — MVP deferrals

**Decision**: Defer alerting integrations, multi-region probes, historical import, Terraform/CLI management, paid-feature automation, custom status-page theming, and advanced status-page access controls.

**Rationale**: The requested outcome is a minimal reliable MVP. Each deferred item adds secrets, external dependencies, or operational surface area that is not required to prove OpenStatus as the monitoring/status platform.

**Consequence**: MVP success is UI reachability, persistence, one private-location check, and one basic status page.
