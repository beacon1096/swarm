# Implementation Plan: Private Syncthing introducer on talos-ii

**Branch**: `007-syncthing-introducer` | **Date**: 2026-08-09 | **Spec**: [spec.md](./spec.md)

## Summary

Add a single Flux-managed Syncthing 2.1.3 workload to `collaboration` using the mirrored bjw-s app-template 4.6.2. Persist `/var/syncthing` on a 100 GiB `longhorn-r3` PVC and privately expose GUI TCP 8384 plus sync TCP 22000 through the Tailscale operator. Clients opt into introducer behavior in their own GUI and pin `tcp://syncthing.tail5d550.ts.net:22000`.

## Technical Context

**Workload**: single stateful application Deployment.
**Storage**: one pre-created RWO `longhorn-r3` PVC, 100 GiB.
**Exposure**: Tailscale operator only; TCP 8384/22000.
**Testing**: Flux readiness, rendered/live exposure audit, GUI bootstrap, Pod-recreation persistence, two-client introducer test.
**Constraints**: no public route, UDP/local discovery, NodePort, Cilium change, reboot, or destructive PVC operation.

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| Storage | PASS | Longhorn-only; r3 protects identity and data. |
| Network | PASS | Existing Cilium networking; Tailscale per-Service private ingress. |
| Secrets | PASS-with-gate | Initial GUI is unauthenticated; restrictive tailnet ACL precedes immediate password setup. |
| Public/private exposure | PASS | No public exposure; operator Service follows private default. |
| GitOps/spec process | PASS | Flux manifests follow these design artifacts. |
| No destructive shortcuts | PASS | Rollback preserves PVC; no reboot. |

## Project Structure

```text
specs/007-syncthing-introducer/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── tasks.md

kubernetes/apps/collaboration/
├── kustomization.yaml
└── syncthing/
    ├── ks.yaml
    └── app/
        ├── kustomization.yaml
        ├── ocirepository.yaml
        ├── helmrelease.yaml
        ├── pvc.yaml
        └── service-tailscale.yaml
```

## Design

1. Reuse the existing `collaboration` namespace and SOPS/Flux defaults.
2. Mirror the existing app-template 4.6.2 OCIRepository pattern from Attic.
3. Run one `Recreate` replica of `ghcr.io/syncthing/syncthing:2.1.3` with `/var/syncthing` on the explicit PVC.
4. Use a separate annotated ClusterIP Service with tailnet hostname `syncthing` and TCP ports 8384/22000.
5. Gate first access with tailnet ACLs, then immediately set GUI authentication and record the Device ID.
6. Configure clients manually; Kubernetes owns reachability and durability, not peer/folder declarations.

## Key Risks

| Risk | Mitigation |
|---|---|
| Fresh GUI is unauthenticated | Deny-by-default tailnet ACL before reconcile; one operator bootstraps and sets password immediately. |
| Device identity changes | Persist all of `/var/syncthing`; verify Device ID after Pod recreation. |
| Accidental broader exposure | Render and inspect for HTTPRoute, NodePort, LoadBalancer and UDP ports. |
| Introducer expands trust unexpectedly | Clients opt in deliberately; verify introduced devices before accepting folders. |
| Transparent egress design is unsafe | Do not change Cilium or depend on the closed `005` canary. |

## Open Questions

None blocking. Exact tailnet ACL principals are an operator-owned preflight input.
