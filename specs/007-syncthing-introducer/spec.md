# Feature Specification: Private Syncthing introducer on talos-ii

**Feature Branch**: `007-syncthing-introducer`
**Created**: 2026-08-09
**Status**: Draft
**Input**: Deploy Syncthing as a durable, Tailscale-private introducer.

## Scope

Deploy one Syncthing 2.1.3 instance in the existing `collaboration` namespace through Flux. It primarily provides a stable Syncthing Device ID and introducer relationship; its 100 GiB volume also permits later folder participation without changing storage architecture. The GUI and sync protocol are reachable only through a Tailscale-operator Service. There is no public route, NodePort, LAN LoadBalancer, local discovery, or Kubernetes-managed peer topology.

## User Scenarios & Testing

### User Story 1 - Operator securely bootstraps Syncthing (P1)

An authorized tailnet operator opens the GUI, immediately sets GUI authentication, and records the persistent Device ID.

**Independent Test**: Reach TCP 8384 over the allowed tailnet identity, set a strong password before adding devices, restart the Pod, and verify authentication and Device ID persist.

**Acceptance Scenarios**:

1. **Given** Flux has reconciled the app, **When** an identity allowed by the tailnet ACL opens `syncthing.tail5d550.ts.net:8384`, **Then** the GUI is reachable without any public route.
2. **Given** a fresh configuration has no GUI password, **When** initial bootstrap begins, **Then** tailnet ACLs are the temporary security boundary and the password is set immediately before peer configuration.
3. **Given** the Pod is recreated, **When** Syncthing returns, **Then** the GUI password, Device ID, certificate, and configuration are unchanged.

### User Story 2 - Clients use the stable introducer (P1)

A client adds the server Device ID, checks **Introducer**, and uses `tcp://syncthing.tail5d550.ts.net:22000` as its explicit address.

**Independent Test**: Add the introducer on two authorized clients, connect both over TCP 22000, and verify an eligible device known to the introducer is learned according to Syncthing's introducer rules.

### User Story 3 - Exposure stays private and narrow (P1)

Only TCP 8384 and 22000 are exposed by the Tailscale operator.

**Independent Test**: Inspect rendered and live Services, confirm no HTTPRoute/Ingress/NodePort/LoadBalancer or UDP port exists, and verify an identity denied by the tailnet ACL cannot connect.

## Requirements

- **FR-001**: Deploy to `collaboration` through Flux and bjw-s app-template `4.6.2`.
- **FR-002**: Use official image `ghcr.io/syncthing/syncthing:2.1.3` and one replica with `Recreate` strategy.
- **FR-003**: Persist `/var/syncthing` on a pre-created 100 GiB `longhorn-r3` RWO PVC.
- **FR-004**: Expose only TCP 8384 and TCP 22000 using a Tailscale-operator ClusterIP Service with hostname `syncthing` and the repository's shared ProxyClass.
- **FR-005**: Do not create HTTPRoute, Ingress, NodePort, LoadBalancer, UDP 22000, or local-discovery UDP 21027 exposure.
- **FR-006**: Configure peers and the Introducer flag in Syncthing clients, not Kubernetes manifests.
- **FR-007**: Clients use explicit address `tcp://syncthing.tail5d550.ts.net:22000`; dynamic/global discovery is not required for this deployment.
- **FR-008**: A restrictive tailnet ACL MUST be active before first GUI access. The operator MUST set a strong GUI password immediately, before adding peer devices or folders.
- **FR-009**: Rollback MUST preserve the PVC. No node reboot, machine-config change, or Cilium datapath change is permitted.

## Success Criteria

- **SC-001**: Flux reports the Syncthing Kustomization and HelmRelease ready and the Pod is healthy.
- **SC-002**: Authorized tailnet clients reach 8384 and 22000; no public or LAN exposure exists.
- **SC-003**: GUI authentication and Device ID survive Pod recreation.
- **SC-004**: Two test clients connect through the explicit TCP address and introducer behavior is observed.
- **SC-005**: The live PVC is Bound at 100 GiB using `longhorn-r3`.

## Assumptions

- Tailnet DNS resolves `syncthing.tail5d550.ts.net` and ACL administration is available before deployment.
- The Tailscale operator and shared `proxied` ProxyClass remain installed.
- Introducer relationships do not replace explicit folder, trust, and encryption decisions.
