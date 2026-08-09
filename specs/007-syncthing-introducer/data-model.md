# Data Model: Private Syncthing introducer

## Kubernetes Entities

- **Namespace `collaboration`**: Existing namespace; no new privilege boundary.
- **Flux Kustomization `syncthing`**: Reconciles the app directory into `collaboration`.
- **OCIRepository `syncthing`**: References the in-cluster mirrored bjw-s app-template 4.6.2 chart.
- **HelmRelease `syncthing`**: One `Recreate` replica using `ghcr.io/syncthing/syncthing:2.1.3`.
- **PVC `syncthing-data`**: 100 GiB, RWO, `longhorn-r3`, mounted at `/var/syncthing`.
- **Service `syncthing-tailscale`**: Annotated ClusterIP with hostname `syncthing`, shared `proxied` ProxyClass, TCP 8384 and TCP 22000.

## Persistent Application State

| State | Purpose | Durability requirement |
|---|---|---|
| Device certificate/key | Stable Device ID and trust anchor | Must survive Pod replacement |
| Syncthing config | GUI auth, peer/folder relationships, listen settings | Must survive Pod replacement |
| Index/database | Synchronization metadata | Must survive Pod replacement |
| Folder data | Optional present/future replicated content | Stored within the 100 GiB volume |

## Runtime Relationships

- Operator reaches `syncthing.tail5d550.ts.net:8384` only when allowed by tailnet ACL.
- Client stores the server Device ID, enables **Introducer**, and uses `tcp://syncthing.tail5d550.ts.net:22000`.
- Syncthing determines introduced devices from its own trusted runtime relationships; Kubernetes does not declare Device IDs or folders.

## Lifecycle Invariants

- Exactly one Syncthing Pod writes the RWO volume.
- Pod replacement does not change Device ID or GUI authentication.
- Helm/Flux rollback preserves the PVC.
- No public route, UDP exposure, or plaintext GUI credential exists in Git.
