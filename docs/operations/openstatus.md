# OpenStatus Operations

OpenStatus is the planned uptime/status monitoring service for `talos-ii`. It replaces the planned role of uptime-kuma; there is no uptime-kuma state to migrate.

## Deployment

- GitOps entry: `kubernetes/apps/monitoring/openstatus/ks.yaml`
- App manifests: `kubernetes/apps/monitoring/openstatus/app/`
- Namespace: `monitoring`
- Public status page: `https://status.beaco.works`
- Dashboard: `https://openstatus.beaco.works`

The Flux Kustomization reconciles normally once the manifests are committed and pushed.

## Runtime Shape

- `openstatus-libsql`: documented upstream datastore, persisted at `/var/lib/sqld` on Longhorn.
- `openstatus-tinybird`: local analytics/check-history service, persisted on Longhorn.
- `openstatus-workflows`: scheduler/background workflow service, persisted at `/app/data`.
- `openstatus-server`: API backend.
- `openstatus-dashboard`: admin UI.
- `openstatus-status-page`: public status-page renderer.
- `openstatus-checker`: checker service.
- `openstatus-private-location`: in-cluster probe, scaled to 0 until an `OPENSTATUS_KEY` is created from the UI/API.

Images use upstream GHCR commit tag `ef7691a` with digests pinned in manifests. Talos containerd mirrors `ghcr.io` and `docker.io` through zot at `172.16.87.51:5000`.

## Required Secrets

`kubernetes/apps/monitoring/openstatus/app/secret.sops.yaml` must stay SOPS-encrypted. Replace the placeholder GitHub OAuth values before unsuspending:

- `AUTH_GITHUB_ID`
- `AUTH_GITHUB_SECRET`

GitHub OAuth callback for the dashboard should be:

```text
https://openstatus.beaco.works/api/auth/callback/github
```

After creating a private location in OpenStatus, replace `OPENSTATUS_KEY` and scale `openstatus-private-location` to 1.

## Reconcile

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n monitoring get kustomization openstatus
```

If rollout must be paused, set `suspend: true` on the `openstatus` Flux Kustomization and let Flux reconcile.

## Smoke Tests

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n monitoring get pods,svc,httproute,pvc
curl -I https://openstatus.beaco.works/
curl -I https://status.beaco.works/
```

Then verify in the UI:

- OAuth login succeeds.
- A workspace can be created.
- A basic HTTP monitor can be created.
- Restarting application pods does not lose workspace/monitor configuration.
- After `OPENSTATUS_KEY` is set and private-location is scaled to 1, one check result appears from the talos-ii private location.

## MCP Follow-Up

OpenStatus exposes an API-key authenticated MCP endpoint. After the dashboard and status page are validated, create an API key from the OpenStatus UI if assistant access is needed. Prefer read-only keys for observation; use read/write keys only for deliberate incident/status-report automation.

Do not store long-lived MCP API keys in Git unless explicitly requested.

## Rollback

Suspend or scale down workloads through GitOps. Do not delete PVCs unless intentionally destroying OpenStatus state.
