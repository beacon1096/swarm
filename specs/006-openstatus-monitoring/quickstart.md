# Quickstart: OpenStatus monitoring MVP

## Preflight

1. Resolve the upstream OpenStatus GHCR commit tag and confirm the zot ghcr.io pull-through cache path.
2. Verify whether current OpenStatus supports PostgreSQL. If not, proceed with libSQL on Longhorn.
3. Use `status.beaco.works` as the MVP public hostname; decide whether dashboard shares it or gets a second hostname.
4. Choose the first supported OAuth provider and configure its callback URL for `status.beaco.works`.
5. Enable Tinybird-local and persistent storage for MVP check history.

## Deploy Validation

1. Reconcile Flux for the future `openstatus` Kustomization.
2. Verify pods in `monitoring` are ready and not restarting.
3. Verify dashboard route:

```bash
curl -I https://<dashboard-hostname>/
```

4. Verify status-page route after creating a page:

```bash
curl -I https://<status-hostname>/
```

5. Verify server/workflows health from inside the namespace:

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n monitoring get pods,svc,httproute
```

## Persistence Test

1. Create workspace and one HTTP monitor in the UI.
2. Restart application pods, not datastore PVCs.
3. Confirm workspace and monitor still exist.

## Private Location Test

1. Create or retrieve a private-location `OPENSTATUS_KEY`.
2. Confirm private-location pod has `OPENSTATUS_INGEST_URL` pointing at the self-hosted API.
3. Create one HTTP monitor for a basic health endpoint.
4. Confirm one check result appears from the talos-ii private location.

## Rollback Shape

Suspend or scale down OpenStatus workloads through GitOps changes. Do not delete PVCs during rollback. Do not run direct `kubectl delete pvc`.

## MCP Follow-Up

After dashboard login, workspace creation, and status-page validation, create an OpenStatus API key from the UI if MCP access is needed. Prefer a read-only key for assistant observation flows; use read/write only when the assistant is intentionally allowed to create or resolve status reports and maintenance windows.
