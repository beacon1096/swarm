# Data Model: OpenStatus monitoring on talos-ii

## Kubernetes Entities

- **Namespace `monitoring`**: New namespace for OpenStatus and future monitoring workloads. No privileged PSA required for MVP.
- **Flux Kustomization `openstatus`**: Reconciles `kubernetes/apps/monitoring/openstatus/app` into the `monitoring` namespace.
- **Application workloads**: Deployments or Helm-rendered workloads for `dashboard`, `server`, `workflows`, `status-page`, `private-location`, `libsql`, and `tinybird-local` if enabled.
- **Services**: ClusterIP Services for dashboard, server/API, workflows as needed, status-page, private-location only if needed, libSQL, and Tinybird-local if enabled.
- **HTTPRoutes**: Gateway API routes for dashboard and status-page. Keep admin/dashboard and public status-page exposure separable.
- **PVCs**: Longhorn-backed persistent volumes for libSQL data and Tinybird-local data if enabled. No PVC deletion as part of normal rollback.
- **SOPS Secret `openstatus-secret`**: Auth, email/OAuth, API, cron, analytics, and private-location tokens.
- **ConfigMap `openstatus-config`**: Non-secret env values such as service URLs, `SELF_HOST=true`, `NODE_ENV=production`, and selected public URLs.

## Runtime Services

| Service | Purpose | Upstream port | Persistence |
|---|---|---:|---|
| `libsql` | Primary documented datastore | 8080 HTTP, 5001 gRPC | Required PVC unless PostgreSQL support is verified |
| `tinybird-local` | Local analytics/check history | 7181 | PVC if enabled |
| `workflows` | Background jobs and scheduled tasks | 3000 | `workflows-data` if upstream still requires it |
| `server` | API/ingest backend | 3000 container, 3001 compose mapping | Stateless except datastore |
| `dashboard` | Admin UI | 3000 container, 3002 compose mapping | Stateless except datastore |
| `status-page` | Public status page renderer | 3000 container, 3003 compose mapping | Stateless except datastore |
| `private-location` | Probe/check executor | 8080 container, 8081 compose mapping | Secret key only |

## Secret Keys

Minimum SOPS-managed keys to verify during implementation:

- `AUTH_SECRET`
- `RESEND_API_KEY` if using magic-link email
- `AUTH_GITHUB_ID` and `AUTH_GITHUB_SECRET` if using GitHub OAuth
- `AUTH_GOOGLE_ID` and `AUTH_GOOGLE_SECRET` if using Google OAuth
- `CRON_SECRET`
- `SUPER_ADMIN_TOKEN` if used
- `DATABASE_AUTH_TOKEN` if libSQL auth is enabled
- `TINY_BIRD_API_KEY` if Tinybird-local is enabled
- `OPENSTATUS_KEY` for each private location
- `QSTASH_*`, `UNKEY_*`, `STRIPE_*`, `SENTRY_*`, and notification provider tokens only if explicitly enabled later

## Config Values

- `DATABASE_URL`: `http://libsql:8080` for documented libSQL mode, or PostgreSQL connection string only if verified upstream-supported.
- `SELF_HOST`: `true`.
- `NEXT_PUBLIC_URL`: dashboard public URL, for example `https://openstatus.beaco.works`.
- `OPENSTATUS_INGEST_URL`: self-hosted server/API URL reachable by private-location pods.
- `TINYBIRD_URL`: `http://tinybird-local:7181` if Tinybird-local is enabled.
- `NODE_ENV`: `production`.
- `AUTH_TRUST_HOST`: `true` for dashboard/status-page when running behind cluster ingress.

## Persistence Contract

- Workspace, monitor, status-page, and user records must survive application pod restarts.
- Check result history must survive restarts if Tinybird-local is enabled for MVP.
- Rollback must scale/suspend workloads without deleting PVCs.
- Backups are not part of MVP, but the implementation runbook must identify the PVCs/datastore that would need backup later.
