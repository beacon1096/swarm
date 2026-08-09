---
description: "Task list for private Syncthing introducer on talos-ii"
---

# Tasks: Private Syncthing introducer

**Input**: `/home/beacon/swarm/specs/007-syncthing-introducer/`
**Target**: talos-ii, namespace `collaboration`.

## Phase 0 — Security Preflight

- [ ] T001 Define a deny-by-default tailnet ACL: bootstrap operator to TCP 8384; intended clients to TCP 22000.
- [ ] T002 Verify the shared `proxied` ProxyClass and tailnet DNS behavior for hostname `syncthing`.
- [X] T003 Confirm official image tag `ghcr.io/syncthing/syncthing:2.1.3` and its runtime UID/GID/security-context requirements.

## Phase 1 — Author GitOps Manifests

- [X] T004 Add `syncthing/ks.yaml` to `/home/beacon/swarm/kubernetes/apps/collaboration/kustomization.yaml`.
- [X] T005 Create `/home/beacon/swarm/kubernetes/apps/collaboration/syncthing/ks.yaml` targeting `collaboration`.
- [X] T006 Create the app-template 4.6.2 OCIRepository and HelmRelease with one `Recreate` replica.
- [X] T007 Create `syncthing-data`: 100 GiB RWO `longhorn-r3`, mounted at `/var/syncthing`.
- [X] T008 Create the Tailscale-operator ClusterIP Service exposing only TCP 8384 and 22000 with hostname `syncthing` and ProxyClass `proxied`.
- [X] T009 Create app `kustomization.yaml`; do not add HTTPRoute, Ingress, NodePort, LoadBalancer, UDP 22000, or UDP 21027.

## Phase 2 — Static Validation

- [X] T010 Render the collaboration Kustomization successfully.
- [X] T011 Audit rendered output for the pinned image/chart, one replica, Recreate strategy, PVC mount, and exact TCP ports.
- [X] T012 Confirm `git diff` contains no credential, Device ID, public exposure, Cilium change, or unrelated file.

## Phase 3 — Deploy and Bootstrap

- [ ] T013 Reconcile Flux and verify HelmRelease, Pod, PVC, and Tailscale Service readiness.
- [ ] T014 From the sole ACL-authorized identity, open the fresh GUI and immediately set a strong GUI password before adding devices/folders.
- [ ] T015 Reconnect to prove GUI authentication, record the Device ID securely, and prove an unauthorized tailnet identity cannot reach 8384.
- [ ] T016 Recreate the Pod and verify the Device ID and GUI authentication persist.

## Phase 4 — Introducer Validation

- [ ] T017 On two clients, add the server Device ID with `tcp://syncthing.tail5d550.ts.net:22000` and enable **Introducer**.
- [ ] T018 Verify both clients connect over TCP 22000 and an eligible known device is introduced according to Syncthing rules.
- [ ] T019 Review every introduced device before accepting folders; record no runtime Device IDs or GUI passwords in Git.

## Phase 5 — Documentation

- [X] T020 Update `docs/cluster-definition.md` with the private Syncthing introducer and persistent volume.
- [X] T021 Add an operations runbook covering ACL preflight, immediate GUI password bootstrap, client setup, persistence test, upgrade, and PVC-preserving rollback.
- [X] T022 Link the runbook from `docs/index.md`.

## Dependencies

- T001 and T002 block reconciliation and first GUI access.
- T014 must be completed in the same attended bootstrap session as first GUI reachability.
- T017 starts only after T015 and T016 pass.
