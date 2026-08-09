# Quickstart: Private Syncthing introducer

## Preflight

1. Create a deny-by-default tailnet ACL permitting only the bootstrap operator to reach `syncthing:8384`; permit intended Syncthing clients to reach `syncthing:22000`.
2. Confirm tailnet DNS will provide `syncthing.tail5d550.ts.net` through the Tailscale operator.
3. Render manifests and confirm only TCP 8384/22000 are exposed and no public route exists.

```bash
nix shell nixpkgs#kustomize -c kustomize build kubernetes/apps/collaboration
rg -n 'HTTPRoute|Ingress|NodePort|LoadBalancer|protocol: UDP|21027' kubernetes/apps/collaboration/syncthing
```

## Reconcile and Inspect

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig flux reconcile kustomization syncthing --with-source
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration get helmrelease,pod,pvc,svc
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration rollout status deployment/syncthing
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration get pvc syncthing-data -o wide
```

## Mandatory First Bootstrap

1. From the sole ACL-authorized operator identity, open `http://syncthing.tail5d550.ts.net:8384`.
2. Before adding any device or folder, set a strong GUI username/password in **Settings → GUI**.
3. Close and reopen the GUI; verify authentication is required.
4. Record the server Device ID from **Actions → Show ID** in the operator's secure inventory.
5. Confirm an unauthorized tailnet identity cannot reach TCP 8384.

Do not leave the fresh unauthenticated GUI unattended, even though it is tailnet-only.

## Client Introducer Setup

On each intended client:

1. Add a remote device using the recorded server Device ID.
2. Set its address to `tcp://syncthing.tail5d550.ts.net:22000`.
3. Check **Introducer** deliberately.
4. Accept the reciprocal device relationship on the server GUI if prompted.
5. Confirm the connection is TCP and verify any learned device before accepting folders.

## Persistence Test

Record the Device ID, recreate only the Pod, and compare after recovery:

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration delete pod -l app.kubernetes.io/instance=syncthing
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n collaboration rollout status deployment/syncthing
```

The GUI must still require authentication and the Device ID must match exactly.

## Rollback

Remove or suspend the workload through GitOps while retaining `syncthing-data`. Never delete the PVC as part of routine rollback.
