# Contract: OpenStatus runtime

## Services And Health Paths

| Component | Kubernetes Service | Port | Readiness contract |
|---|---|---:|---|
| dashboard | `openstatus-dashboard` | 3000 | HTTP `GET /` returns 200 or expected auth page |
| status-page | `openstatus-status-page` | 3000 | HTTP `GET /` returns 200 for configured page after setup |
| server/API | `openstatus-server` | 3000 | HTTP `GET /ping` or upstream-equivalent health endpoint succeeds |
| workflows | `openstatus-workflows` | 3000 | HTTP `GET /ping` succeeds |
| private-location | `openstatus-private-location` | 8080 | HTTP `GET /health` succeeds if exposed internally |
| libSQL | `openstatus-libsql` | 8080 | TCP/HTTP health succeeds before app startup |
| Tinybird-local | `openstatus-tinybird` | 7181 | HTTP `GET /` succeeds if enabled |

If implementation finds different upstream health endpoints, update this contract and quickstart before authoring manifests.

## Required Environment Contract

```text
DATABASE_URL=http://openstatus-libsql:8080
DATABASE_AUTH_TOKEN=<optional-if-libsql-auth-enabled>
AUTH_SECRET=<sops-secret>
SELF_HOST=true
NEXT_PUBLIC_URL=https://<dashboard-hostname>
AUTH_TRUST_HOST=true
NODE_ENV=production
CRON_SECRET=<sops-secret>
OPENSTATUS_INGEST_URL=http://openstatus-server.monitoring.svc.cluster.local:3000
OPENSTATUS_KEY=<sops-secret-private-location-key>
TINYBIRD_URL=http://openstatus-tinybird:7181
TINY_BIRD_API_KEY=<sops-secret-if-tinybird-enabled>
AUTH_GITHUB_ID=<sops-secret-if-github-oauth-enabled>
AUTH_GITHUB_SECRET=<sops-secret-if-github-oauth-enabled>
AUTH_GOOGLE_ID=<sops-secret-if-google-oauth-enabled>
AUTH_GOOGLE_SECRET=<sops-secret-if-google-oauth-enabled>
```

Only one OAuth provider should be enabled for MVP unless implementation verifies that multiple providers are needed. Optional provider keys (`RESEND_API_KEY`, `QSTASH_*`, `UNKEY_*`, notification integrations, Sentry, Stripe, Vercel) must stay unset for MVP unless a chosen runtime path requires them.

## MCP Contract

- MCP is post-MVP enablement, not a deployment dependency.
- The self-hosted API must preserve the API-token path needed to create an OpenStatus key after login.
- Do not store a long-lived MCP API key in Git unless explicitly requested.
- Future MCP clients use `x-openstatus-key` against the OpenStatus MCP endpoint; prefer read-only keys for assistants that only observe status.

## HTTPRoute Contract

- Dashboard route targets only the dashboard Service.
- Status-page route targets only the status-page Service.
- Server/API route is exposed only if private-location or browser flows require an ingress-visible endpoint; otherwise use ClusterIP internally.
- No NodePort or LoadBalancer Service is introduced for OpenStatus MVP.
- If routes are public, OpenStatus authentication must be verified before declaring the dashboard route ready.

## SOPS Contract

- `secret.sops.yaml` must contain only encrypted secret values before commit.
- `git diff` must show `ENC[...]` for all secret material.
- Decryption must be verified from `/home/beacon/swarm` so the repository `.sops.yaml` recipient is used.
