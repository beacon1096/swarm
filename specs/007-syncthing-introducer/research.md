# Research: Private Syncthing introducer

## R1 — Workload packaging

**Decision**: Use bjw-s app-template 4.6.2 and official `ghcr.io/syncthing/syncthing:2.1.3`.

**Rationale**: app-template 4.6.2 is already mirrored into the in-cluster Zot and used for single-workload applications. A pinned official image keeps supply and upgrade behavior explicit.

## R2 — Durable identity and storage

**Decision**: Mount a pre-created 100 GiB `longhorn-r3` PVC at `/var/syncthing`, with one `Recreate` replica.

**Rationale**: Syncthing's certificate, Device ID, GUI credentials, peer/folder database, and any folder data under that path must survive rescheduling. Concurrent writers are inappropriate for this application state.

## R3 — Private exposure

**Decision**: Expose only TCP 8384 and TCP 22000 through one Tailscale-operator Service; clients dial `tcp://syncthing.tail5d550.ts.net:22000`.

**Rationale**: The introducer and its operators are tailnet members. Explicit TCP addressing removes the need for public/global discovery, relay dependence, UDP QUIC, LAN LoadBalancer, or local broadcast discovery.

## R4 — Bootstrap security

**Decision**: Treat the tailnet ACL as the mandatory initial security boundary and set a GUI password immediately after first access.

**Rationale**: A fresh Syncthing GUI can be unauthenticated. Tailscale-private does not mean every tailnet identity should administer it. The Service must initially be reachable only by the bootstrap operator; peer setup waits until authentication is enabled.

**Consequence**: Reconciliation is blocked until the ACL exists. The operator verifies an unauthorized identity is denied, sets the password, reconnects successfully, then records the Device ID. The password lives in Syncthing's persisted config; it is not committed in plaintext.

## R5 — Introducer ownership

**Decision**: Configure the server/device relationship and **Introducer** checkbox in each Syncthing client GUI.

**Rationale**: Introducer trust and folder sharing are runtime relationships between Device IDs. Baking peer topology into Kubernetes would mix application trust state with deployment state and complicate rotation.

## R6 — Excluded datapath changes

**Decision**: Make no Cilium egress or masquerade change.

**Rationale**: `specs/005-cilium-datapath-canary/plan.md` concluded no safe transparent PodCIDR-egress candidate. Tailnet Service ingress is sufficient for this deployment.
