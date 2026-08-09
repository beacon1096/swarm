# Syncthing introducer

Syncthing runs as a single `collaboration/syncthing` Deployment. Its device
certificate, configuration, index, and synchronized data live on the
`syncthing-data` Longhorn PVC. The only ingress is the Tailscale Service at
`syncthing.tail5d550.ts.net`: GUI on TCP 8384 and sync on TCP 22000.

## Bootstrap

Before the first reconciliation, restrict TCP 8384 to the bootstrap operator
in the tailnet ACL and TCP 22000 to intended clients. Open
`http://syncthing.tail5d550.ts.net:8384`, immediately set a GUI username and
password, reconnect to verify authentication, and store the displayed Device
ID in the operator's secure inventory. Confirm an unauthorized tailnet identity
cannot reach TCP 8384.

On each client, add the stored Device ID with the explicit address
`tcp://syncthing.tail5d550.ts.net:22000` and enable **Introducer**. Do not make
two devices introducers for each other. Review introduced devices before
accepting folders.

## Verification

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration get helmrelease,pod,pvc,svc
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration rollout status deployment/syncthing
```

After recording the Device ID, recreate the Pod once and confirm both the
Device ID and GUI authentication remain unchanged.

## Upgrade and rollback

Pin upgrades in the HelmRelease, render the chart, and reconcile through Flux.
Rollback by reverting or suspending the GitOps workload while retaining
`syncthing-data`. Never delete the PVC as part of routine rollback.
