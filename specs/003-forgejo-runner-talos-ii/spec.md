# Feature Specification: Forgejo Actions runner on talos-ii (DinD)

**Feature Branch**: `003-forgejo-runner-talos-ii`
**Created**: 2026-05-04
**Status**: Draft
**Input**: User description: "Deploy forgejo-runner on talos-ii with Docker-in-Docker, x86_64 only, replacing the talos-i runner. Egress goes through sing-box auto_redirect (kernel-level) plus explicit HTTP_PROXY env on act_runner and spawned containers. Local cluster Services for forgejo and attic; LAN zot 172.16.80.240 as initial registry mirror, switching to in-cluster zot Service in Phase 2."

## Scope

**Target cluster: `[talos-ii]` only.** This feature deploys a Forgejo Actions runner exclusively on the talos-ii cluster. It MUST NOT be deployed on talos-i. The existing `swarm-01` (talos-i) runner is **retired** as part of cutover — there is no double-running steady state. talos-i has no Forgejo runner after this change, and there is no plan to put one back: the role of talos-i in the post-shared/0003 architecture is offsite observability + backup, not CI.

## Decisions Resolved

The five `[NEEDS CLARIFICATION]` markers from the `/specify` draft were resolved by the parent agent on 2026-05-04. One-line summary; full rationale lives inside the relevant FR / Edge Case / Assumption sections.

- **Q1 — In-cluster Service names**: Forgejo HTTP API at `forgejo-http.development.svc.cluster.local:3000`; attic at `attic.nix.svc.cluster.local:8080`; future in-cluster zot at `zot.network.svc.cluster.local:5000` (namespace assumption confirmed at Plan stage). No ExternalName / Tailscale-egress wrappers — all Services are cluster-local on talos-ii.
- **Q2 — dockerd image source**: Pull `docker.io/library/docker:<version>-dind-amd64` through the LAN zot pull-through cache at `172.16.80.240:5000/library/docker:<version>-dind-amd64`. Initial pin `29.2.1-dind-amd64` (matching swarm-01) unless Plan stage finds a newer reason. Phase 2 cuts to `zot.network.svc.cluster.local:5000`. Rejected: standing up a `registry.beaco.works` alias-wrapper.
- **Q3 — alpine/kubectl container**: KEEP at chart default. It is NOT a Deployment-level sidecar — it is a one-shot container in the chart's `forgejo-runner-init-config` Job (`templates/jobs.yaml`) that patches the registration credential into the runner's Secret after `forgejo-runner generate-config` runs. Without it, registration never persists. Pull through LAN zot like every other image.
- **Q4 — Pod Security Admission**: New namespace `forgejo-runner` with namespace-level labels `pod-security.kubernetes.io/{enforce,audit,warn}: privileged`. Wrenix chart applies no PSA labels of its own. The `dind` container's `privileged: true` is mandatory; the `runner` container's privileged flag is a candidate for postRenderer-Kustomize hardening (drop privileged + `runAsUser: 1000`) at Plan stage. Build containers spawned inside DinD keep chart default `runner.config.file.container.privileged: false`.
- **Q5 — `runner.capacity` and concurrency**: `runner.config.file.runner.capacity: 3`, `replicaCount: 1`, no HPA. Single pod on a single MS-01 node; nix-fleet's 6-job peak (`build-systems` ×4 + `build-installer-iso` + `build-and-push-k8s-sing-box-oci`) queues 3 + waits 3, acceptable because nix-fleet is the only consumer and is human-triggered. Resource limits: `runner` requests `cpu=100m mem=256Mi` / limits `cpu=2 mem=512Mi`; `dind` requests `cpu=500m mem=2Gi` / limits `cpu=8 mem=8Gi`; ephemeral-storage requests `30Gi` / limits `60Gi`. Future scaling path: capacity=6 first (single pod), then replicas=2 with anti-affinity if memory-bound.

This is the first **CI consumer** of the in-cluster sing-box egress gateway (ADR `shared/0004`, Phase 2 deployed) and the **structural fix** to the recurring NixOS-CI failure where nix's sandboxed Go fetcher does not honor `HTTPS_PROXY` env. Sing-box `auto_redirect` captures all pod-egress traffic at host netfilter regardless of env propagation, so nix sandbox builds succeed transparently.

This phase is **x86_64 only**. Cross-arch (arm64, loongarch64) is deferred until the `siderolabs/binfmt-misc` Talos extension lands, which itself is bundled with the Tailscale-extension schematic refresh (separate ADR, separate phase).

## User Scenarios & Testing *(mandatory)*

### User Story 1 — NixOS-CI workflow runs on talos-ii runner end-to-end (Priority: P1)

The `nix-fleet` repo's `build-and-push.yaml` workflow (warm-cache → matrix builds → installer-iso → k8s-sing-box-oci → update-prod-branch) is dispatched against the new talos-ii runner. Every job:

1. Pulls `node:20.12-bookworm` and `nixos/nix:latest` build container images via dockerd's registry mirror (initially LAN zot at `172.16.80.240:5000`, then in-cluster zot in Phase 2).
2. Runs `DeterminateSystems/nix-installer-action` with `extra-conf: http-proxy = http://sing-box.network.svc.cluster.local:7890` — the env-honoring path that worked on talos-i once HTTP_PROXY was wired.
3. Runs `nix build .#…` whose nix sandbox makes Go-fetcher HTTPS calls (sops module, etc.) — these MUST succeed even though Go's fetcher in nix's sandbox is the case that motivated this whole refactor. Success here proves sing-box `auto_redirect` is doing its job at the kernel level.
4. Runs `ryanccn/attic-action` against the in-cluster attic Service (no Tailscale hop).
5. On tag pushes, uploads installer ISO to Forgejo release and pushes the `k8s-sing-box-oci` image to the Forgejo registry (also via in-cluster Service).

**Why this priority**: This is the entire reason for the deployment. If the workflow fails on the new runner, none of the rest matters. This story is also the gate that lets us decommission the talos-i runner.

**Independent Test**: With the runner deployed and registered, dispatch `build-and-push.yaml` on a non-tagged branch. Verify all four parallel jobs reach `success` and the artifacts are present (attic cache populated, OCI image pushed to Forgejo registry).

**Acceptance Scenarios**:

1. **Given** the talos-ii runner is registered and idle, **When** the operator dispatches `build-and-push.yaml`, **Then** every job picks up on the talos-ii runner (verified by runner name in job logs) and reaches `success`.
2. **Given** a job is running `nix build`, **When** the nix sandbox issues an HTTPS request to a Go module proxy that the Go fetcher does NOT propagate `HTTPS_PROXY` to, **Then** the request still succeeds — proven by sing-box logs showing the connection on the auto_redirect path (table `inet sing-box`, fwmark 0x2023/0x2024).
3. **Given** the workflow uses `nix-installer-action`'s `http-proxy = http://sing-box.network.svc.cluster.local:7890` extra-conf, **When** the action runs, **Then** the env-explicit path also works (HTTP CONNECT one-shot through sing-box mixed inbound). Both paths working in parallel is the design.
4. **Given** the workflow runs on a tag push, **When** the `update-prod-branch` job runs, **Then** the `prod` branch is fast-forwarded to the released SHA.

---

### User Story 2 — talos-i runner cutover is clean and irreversible (Priority: P1)

Before merge: the talos-i runner remains the registered runner for `nix-fleet` and is the one picking up jobs.

After merge + reconciliation: the talos-i runner is unregistered (Forgejo `Settings → Actions → Runners` no longer lists it), the talos-i runner Pod is gone, and the talos-ii runner is the sole runner for `nix-fleet`. A short outage window during cutover is acceptable (no consumer other than nix-fleet, which can wait).

**Why this priority**: Same priority as Story 1 because partial cutover is worse than no cutover — if both runners are registered with the same labels, jobs round-robin and Story 1's verification becomes ambiguous. Also: leaving the talos-i runner around violates the per-cluster scoping memo (don't accumulate duplicate deployments).

**Independent Test**: After cutover, in the Forgejo UI confirm exactly one runner with labels `ubuntu-latest` + `nix-builder` is online, and that runner is the talos-ii one. Re-dispatch `build-and-push.yaml`; every job's `runs-on: ubuntu-latest` lands on the talos-ii runner.

**Acceptance Scenarios**:

1. **Given** the talos-ii runner is registered and verified by Story 1, **When** the operator follows the runbook's "decommission talos-i runner" section, **Then** the talos-i runner Pod is `Terminated`, the registration token in Forgejo's runner DB is invalidated, and a re-dispatched workflow on `ubuntu-latest` cannot land on talos-i.
2. **Given** cutover is complete, **When** the operator audits `swarm-01` (read-only reference repo) for any remaining in-flight references, **Then** the only remaining artifact is the historical manifest tree (preserved as reference, not reconciled by Flux). The swarm-01 Flux instance MUST have stopped reconciling that path before this point.

---

### User Story 3 — Build container egress reaches public + private destinations correctly (Priority: P1)

Inside a job's spawned build container (e.g. `nixos/nix:latest`):

- `curl https://registry.npmjs.org/` and `git fetch https://github.com/...` succeed via sing-box (env-honored explicit path OR auto_redirect kernel path — both must work).
- `curl http://attic.nix.svc.cluster.local:8080/` succeeds **directly** (cluster.local DNS resolves to the in-cluster Service ClusterIP, NO_PROXY excludes `.svc.cluster.local`, traffic does NOT egress through sing-box).
- `curl http://forgejo-http.development.svc.cluster.local:3000/` likewise reaches cluster-internal Forgejo without a tailnet hop.
- `curl http://172.16.80.240:5000/` (LAN zot, Phase 1 mirror target) is reachable from dockerd; once Phase 2 cuts the mirror to in-cluster zot at `zot.network.svc.cluster.local:5000`, dockerd's mirror config switches but every other path stays the same.

**Why this priority**: This is what differentiates the talos-ii runner from the talos-i one. talos-i had to do `forgejo-ts.development.svc.cluster.local` + `attic-ts.development.svc.cluster.local` ExternalName hops via Tailscale operator because Forgejo and attic lived on a different cluster. On talos-ii, both are local (`forgejo-http.development` and `attic.nix`) and there's no Tailscale dependency at all for normal CI traffic. If this story silently regresses to the swarm-01 shape (uses Tailscale for in-cluster destinations), we've copied the wrong thing.

**Independent Test**: From inside a running build container, run a curated curl matrix: a public HTTPS, a `*.svc.cluster.local` HTTP, the LAN zot, and a destination that should fail (e.g. an internet host explicitly blocked by sing-box's outbound policy). Verify each result matches the design intent.

**Acceptance Scenarios**:

1. **Given** the runner is configured with `HTTPS_PROXY=http://sing-box.network.svc.cluster.local:7890` and `NO_PROXY` containing `.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16`, **When** a build container resolves `attic.nix.svc.cluster.local`, **Then** the connection is direct (no proxy CONNECT, no auto_redirect intercept — verified by absent sing-box log entry for that destination).
2. **Given** the same runner config, **When** a build container resolves `proxy.golang.org`, **Then** the connection goes through sing-box (verified by sing-box log).
3. **Given** sing-box's DaemonSet has `route_exclude_address` covering `10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10`, **When** dockerd's bridge `10.250.0.0/16` carries DinD-internal traffic between act_runner ↔ dockerd ↔ build container, **Then** that traffic is NOT TUN-intercepted (the bridge IP space is in the exclude list).

---

### User Story 4 — Coexistence with sing-box DaemonSet on the same node is stable (Priority: P2)

The sing-box DaemonSet is already running on `ms01-a`, `ms01-b`, `ms01-c` with `auto_redirect = true`, owning nftables table `inet sing-box`, fwmarks `0x2023` / `0x2024`, ip rule priorities `9000`–`9002`, and route table `2022`. The DinD sidecar will, on first start, install dockerd's nftables/iptables-nft chains (`nat`, `filter`, the dockerd-managed `DOCKER`, `DOCKER-USER`, etc.). The names are disjoint, but the operator must verify no rule order or fwmark collision emerges in steady state.

**Why this priority**: Important but not blocking — if it does collide, we discover it at deploy time, not as a latent regression in workflow runs. P2 because Story 1's success implicitly proves much of this; Story 4 is the explicit confirmation step.

**Independent Test**: On a node where both sing-box DS and a runner DinD pod are scheduled, dump nftables (`nft list ruleset`) and confirm: (a) `inet sing-box` table is intact and unchanged from pre-runner deploy, (b) iptables-nft `nat` and `filter` tables show dockerd's chains, (c) packet trace on a test job confirms egress packets traverse the expected chains in the expected order.

**Acceptance Scenarios**:

1. **Given** sing-box DS pre-existed on `ms01-a`, **When** the runner Pod schedules onto `ms01-a` and dockerd starts, **Then** `nft list table inet sing-box` shows the same rule set as before (no overwrite, no orphan), and `iptables-nft -t nat -L` shows dockerd's chains added.
2. **Given** both are running, **When** a build container makes a public HTTPS request, **Then** the packet path is: build container → docker0 (`10.250.0.0/16`) → host netfilter prerouting → sing-box auto_redirect (TUN) → upstream — verifiable by counter increments on `inet sing-box` chain rules during the test.

---

### User Story 5 — Phase 2 mirror cutover from LAN zot to in-cluster zot is non-disruptive (Priority: P3)

After spec `002-zot-on-talos-ii` lands and the in-cluster zot is healthy, the runner's dockerd `daemon.json` `registry-mirrors` switches from `http://172.16.80.240:5000` to the in-cluster zot Service URL. This is a config-only change reconciled by Flux; no runner re-registration, no node reboot.

**Why this priority**: P3 because it's a follow-on phase, not a blocker for Story 1. Captured here so Plan stage knows the configuration must accommodate this swap cleanly (single value to flip, not a structural change).

**Independent Test**: After the value flip, dispatch a workflow that requires a fresh image pull (a tag dockerd hasn't seen). Verify the pull succeeds and the in-cluster zot's logs show the corresponding upstream-sync request, while the LAN zot's logs show no request for that tag during the test window.

**Acceptance Scenarios**:

1. **Given** the in-cluster zot is healthy and the runner's `daemon.json` is updated via Flux, **When** dockerd is restarted (rolled by the change), **Then** subsequent build-container image pulls flow through the in-cluster zot.
2. **Given** the cutover is done, **When** the operator stops the LAN zot host, **Then** the runner workflow still completes (only previously-cached state on the LAN host becomes unreachable, but that's content-addressable and re-fetchable).

---

### Edge Cases

- **dockerd bridge subnet collision with Tailscale subnet routes**: Tailscale subnet routers advertise `172.16.{10,20,80,100}.0/24`. dockerd's default `172.17.0.0/16` would collide on the `172.16.0.0/12` umbrella. We force `bip = "10.250.0.1/16"` and `default-address-pools` to `10.250.0.0/16`. Verified by `ip route` on the dockerd sidecar showing `10.250.0.0/16 dev docker0`.
- **dockerd's own egress under sing-box auto_redirect**: dockerd issues registry-pull HTTPS requests to its configured mirror. The mirror is on LAN (`172.16.80.240/24`) — that subnet is in sing-box's `route_exclude_address`, so dockerd's traffic to the mirror is NOT intercepted (correct: avoids loopback into TUN). Once Phase 2 switches the mirror to an in-cluster Service, the destination is `10.55.0.0/16` (ServiceCIDR, also excluded). Both phases keep dockerd off the TUN path; build containers' general egress is on the TUN path. This is intentional and must be documented in the runbook.
- **No HTTPS_PROXY on dockerd container**: We do NOT set `HTTPS_PROXY` on the dockerd sidecar's environment. Reasoning: dockerd's image-pull traffic is mirror-bound (LAN or in-cluster zot), the mirror handles its own upstream egress through sing-box, and pushing dockerd-side traffic through sing-box would re-introduce the auto_redirect interception of dockerd's TLS handshakes — fragile and uncalled-for.
- **Privileged mode + Talos**: Talos restricts privileged Pods. The runner Pod opts in via the `forgejo-runner` namespace's three PSA labels: `pod-security.kubernetes.io/enforce: privileged`, `pod-security.kubernetes.io/audit: privileged`, `pod-security.kubernetes.io/warn: privileged`. The wrenix chart applies no PSA labels itself, so the labels MUST be set on the Namespace resource managed by Flux.
- **Namespace PSA misconfiguration prevents pod creation**: If the `forgejo-runner` namespace is missing any of the three PSA labels (or has them set to a stricter level like `restricted`), the runner Deployment's Pods fail admission with `pods "forgejo-runner-..." is forbidden: violates PodSecurity "restricted:latest": privileged (container "dind" must not set securityContext.privileged=true) ...` and the ReplicaSet stays at `0/1`. Mitigation = ensure the Namespace manifest carries all three PSA labels at `privileged`. Verifiable by `kubectl get ns forgejo-runner -o jsonpath='{.metadata.labels}'` showing the three label keys.
- **dockerd nftables interaction with sing-box auto_redirect**: covered above under "dockerd's own egress under sing-box auto_redirect" — the `10.250.0.0/16` docker bridge subnet falls within sing-box's `route_exclude_address` covering `10.0.0.0/8`, so DinD-internal traffic between act_runner ↔ dockerd ↔ build container is NOT TUN-intercepted. This is the correct intentional behavior, not a workaround. The `inet sing-box` table and dockerd's iptables-nft `nat` / `filter` chains are name-disjoint; Story 4 is the explicit verification step.
- **Storage**: act_runner has minimal state (registration cache); dockerd has more (image layer cache between job invocations). DinD's image layer cache is `emptyDir` by default. We accept that layer cache is lost on Pod restart (re-fetchable from mirror; cost is one extra round-trip on cold start). Persistent layer cache is not in scope for v1.
- **Vestigial `configmap.yaml` from swarm-01**: The swarm-01 manifests contained a transparent-proxy ConfigMap that was never wired (verified). This spec explicitly does NOT carry that artifact across — the structural equivalent on talos-ii is sing-box auto_redirect at the host level, not a per-Pod config.
- **Vestigial `service-{forgejo,attic,zot}-egress.yaml` from swarm-01**: Those three ExternalName + Tailscale-annotation manifests existed on talos-i because Forgejo / attic / zot were on a different cluster. On talos-ii, all three are local cluster Services or LAN; this spec explicitly does NOT carry those manifests across.
- **Same labels as talos-i for zero-touch workflow compat**: `ubuntu-latest:docker://node:20.12-bookworm` and `nix-builder:docker://nixos/nix:latest`. If labels diverged, every workflow's `runs-on` would need editing. They MUST match.
- **Registration token re-mint**: The talos-i runner's `CONFIG_TOKEN` is bound to that runner identity. The talos-ii runner needs a fresh registration token from Forgejo `Site Administration → Actions → Runners → Create new runner`, SOPS-encrypted into this repo. The talos-i token in the swarm-01 secret is decommissioned by Story 2.

## Requirements *(mandatory)*

### Functional Requirements

#### Deployment scope and identity

- **FR-001**: The runner deployment MUST exist only on the **talos-ii** cluster. There MUST be no `forgejo-runner` HelmRelease, Service, Deployment, or Secret reconciled by Flux on talos-i after this phase completes.
- **FR-002**: The runner MUST be deployed in a new dedicated namespace `forgejo-runner` (not in `development`, where the Forgejo server lives). Cleaner RBAC boundary and room for future runners (GitLab, devcontainer host) without namespace overload.
- **FR-003**: All cluster-side configuration (HelmRelease, namespace, Secret, OCIRepository, any required ServiceAccount / NetworkPolicy) MUST be declared as code under `kubernetes/apps/forgejo-runner/forgejo-runner/` (or analogous Flux path; final layout is a Plan-stage decision but MUST follow the existing `kubernetes/apps/<group>/<app>/` convention).
- **FR-004**: The runner registration token (`CONFIG_TOKEN`, `CONFIG_INSTANCE`, `CONFIG_NAME`) MUST be SOPS-encrypted in the repo. The token used for talos-i MUST NOT be reused; a fresh token is minted from Forgejo for the new runner.
- **FR-005**: The runner registration name MUST be distinct from the talos-i registration (e.g. `forgejo-runner-talos-ii`) so both can be observed in Forgejo's runner list during cutover and the operator can unambiguously decommission the right one.

#### Runtime shape

- **FR-006**: The runner Pod MUST use the **Docker-in-Docker (DinD)** two-container shape: an `act_runner` container running the Forgejo runner binary, and a `dockerd` sidecar in privileged mode providing the Docker socket the runner uses for spawning build containers.
- **FR-007**: The dockerd sidecar's `securityContext.privileged: true` MUST be permitted by the namespace's Pod Security policy. The `forgejo-runner` namespace MUST carry all three PSA labels at `privileged`: `pod-security.kubernetes.io/enforce: privileged`, `pod-security.kubernetes.io/audit: privileged`, `pod-security.kubernetes.io/warn: privileged`. The wrenix chart does not apply PSA labels itself; the Namespace resource managed by Flux MUST set them. The chart's `runner` container is also `privileged: true` by default; dropping that to non-privileged + `runAsUser: 1000` via a postRenderer Kustomize patch is a recommended hardening step but is a Plan-stage decision (NOT mandated at spec stage). The chart's one-shot `kubectl` container in the registration Job is non-privileged; PSA `enforce: privileged` admits less-privileged pods.
- **FR-008**: The runner MUST be x86_64 only. Image tags MUST be the explicit `-amd64` variants (e.g. `code.forgejo.org/forgejo/runner:12.7.3-amd64`, `docker.io/library/docker:<pinned>-dind-amd64`). Multi-arch build support is out of scope; the chosen images MUST be pinned to the amd64 variant.
- **FR-009**: The runner job timeout MUST be **12h** (matching talos-i and the workflow's `timeout-minutes: 720`).
- **FR-010**: Runner concurrency MUST be `runner.config.file.runner.capacity: 3` with `replicaCount: 1` and no HPA. Single-pod design is deliberate: simplifies scheduling (no anti-affinity needed), keeps dockerd layer cache 100% reused across the 3 concurrent jobs, removes replica health-management complexity. Worst-case workflow peak is 6 concurrent jobs (nix-fleet `build-systems` ×4 + `build-installer-iso` + `build-and-push-k8s-sing-box-oci`); 3 run, 3 queue. Acceptable because nix-fleet is the only consumer and is human-triggered. Future scaling path: raise capacity to 6 first (still single pod), then go `replicaCount: 2` with anti-affinity across distinct ms01-* nodes only if memory pressure forces it.

#### Runner config — labels

- **FR-011**: The runner labels MUST be exactly `ubuntu-latest:docker://node:20.12-bookworm` and `nix-builder:docker://nixos/nix:latest`, identical to the talos-i runner. Workflow YAML in `nix-fleet` MUST require zero edits to land on the new runner.

#### Runner config — networking

- **FR-012**: The dockerd sidecar MUST use a non-default bridge subnet `10.250.0.0/16` (configured via `daemon.json` `bip` and `default-address-pools`). It MUST NOT use the default `172.17.0.0/16` because that collides with the `172.16.0.0/12` umbrella that hosts Tailscale subnet routes (`172.16.{10,20,80,100}.0/24`).
- **FR-013**: The dockerd sidecar MUST NOT have `HTTP_PROXY` / `HTTPS_PROXY` env set. Its outbound traffic is image-pull traffic to its configured mirror; the mirror handles upstream egress.
- **FR-014**: The dockerd `daemon.json` MUST set `registry-mirrors` to `["http://172.16.80.240:5000"]` in Phase 1 (matching the same path Talos installer + sing-box image bootstrap take), and MUST be flippable to the in-cluster zot Service URL `http://zot.network.svc.cluster.local:5000` in Phase 2 by changing one configuration value (no structural rework).
- **FR-015**: The `act_runner` container MUST have `HTTP_PROXY` / `HTTPS_PROXY` / `http_proxy` / `https_proxy` set to `http://sing-box.network.svc.cluster.local:7890`, and `NO_PROXY` / `no_proxy` set to a value containing at minimum: `.beaco.works,.beacoworks.xyz,.tail5d550.ts.net,.svc,.svc.cluster.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1`.
- **FR-016**: Spawned build containers MUST inherit the same `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` set via the runner config's `runner.config.file.container.envs` field. This is the explicit env-honoring path; sing-box `auto_redirect` at the host kernel is the safety net for tools that ignore env (notably nix sandbox Go fetches).
- **FR-017**: The runner MUST NOT depend on the in-cluster Tailscale operator for routine job traffic. Specifically: there MUST be no `service-forgejo-egress.yaml` ExternalName, no `service-attic-egress.yaml` ExternalName, no `service-zot-egress.yaml` ExternalName, and no Tailscale annotations on the runner Pod or Services. Forgejo (`forgejo-http.development.svc.cluster.local:3000`), attic (`attic.nix.svc.cluster.local:8080`), and the registry mirror are reachable via cluster-local paths or LAN; no tailnet hop is needed.
- **FR-018**: The runner's `CONFIG_INSTANCE` MUST point at the in-cluster Forgejo Service `http://forgejo-http.development.svc.cluster.local:3000` via cluster-local DNS, NOT a tailnet hostname, NOT a public hostname. (Plan stage confirms the exact Service name against the actual Forgejo HelmRelease values.)
- **FR-019**: The act_runner ↔ dockerd socket MUST use the **chart-default TLS configuration on port 2376** with the shared `docker-certs` `emptyDir` volume mounted into both containers (`DOCKER_HOST=tcp://localhost:2376`, `DOCKER_TLS_VERIFY=1`, `DOCKER_CERT_PATH=/certs/client`). The swarm-01 override to plaintext `tcp://localhost:2375` is **explicitly rejected** for talos-ii — TLS is the chart default and is the safer baseline. No certificate management is needed at the cluster level: the dockerd entrypoint regenerates a fresh self-signed CA on each Pod start and writes it into the shared volume.
- **FR-020**: The dockerd container image MUST be sourced as `172.16.80.240:5000/library/docker:<version>-dind-amd64` in Phase 1 (LAN zot pull-through cache; zot proxies docker.io and adds `library/docker` on first access just like other `library/*` repos already in its catalog) and MUST be flippable to `zot.network.svc.cluster.local:5000/library/docker:<version>-dind-amd64` in Phase 2. Initial pin is `29.2.1-dind-amd64` unless Plan stage finds a newer reason. A `registry.beaco.works` alias-wrapper is **explicitly NOT** introduced for talos-ii.

#### Resource limits

- **FR-021**: The runner Deployment MUST set per-container resource requests and limits as the spec-stage starting points (Plan stage refines):
  - `runner` container: `requests.cpu=100m`, `requests.memory=256Mi`, `limits.cpu=2`, `limits.memory=512Mi`.
  - `dind` container: `requests.cpu=500m`, `requests.memory=2Gi`, `limits.cpu=8`, `limits.memory=8Gi` (sized for 3 concurrent nix builds at ~2-3 GB peak each plus dockerd overhead, all on a single node).
  - Pod-level ephemeral storage: `requests=30Gi`, `limits=60Gi`. If layer-cache loss on Pod restart proves expensive in observed throughput, replace the `/var/lib/docker` `emptyDir` with a Longhorn PVC — that is a Plan-stage decision.
  Because `replicaCount: 1` and `runner.capacity: 3`, all 3 concurrent jobs share the same Pod's limits — they are NOT per-job.

#### Registration Job

- **FR-022**: The chart's `forgejo-runner-init-config` Job (`templates/jobs.yaml`) is part of the deployed shape and MUST NOT be disabled. It runs two one-shot containers: (1) `generate-config` (the `act_runner` image) writes a `.runner` credential file from the registration token to a shared volume, (2) `upload-config` (chart-default `docker.io/alpine/kubectl:1.35.3`) `kubectl patch`es that credential into the runner's `-configfile` Secret. The `upload-config` container is a one-shot Job container, **NOT a Deployment-level sidecar of the runner Pod**. Without this Job, runner registration never persists. The `alpine/kubectl` image MUST be pulled through the LAN zot mirror like every other image; chart-default image reference is acceptable.

#### Coexistence with sing-box

- **FR-023**: The runner deployment MUST NOT modify or assume ownership of the sing-box DaemonSet's nftables table `inet sing-box`, fwmarks `0x2023` / `0x2024`, ip rules `9000`–`9002`, or route table `2022`. Coexistence with dockerd's iptables-nft chains is required and MUST be verified during deploy (User Story 4).
- **FR-024**: The runner Pod's traffic patterns MUST behave as: (a) DinD-internal traffic on `10.250.0.0/16` is NOT TUN-intercepted (subnet is in sing-box `route_exclude_address` covering `10.0.0.0/8`), (b) build container egress to public destinations IS TUN-intercepted (auto_redirect kernel path), (c) build container egress to `*.svc.cluster.local` and LAN `172.16.0.0/12` is direct (NO_PROXY exempts these for env-honoring tools, and `route_exclude_address` exempts these for non-env-honoring tools).

#### Build container privileges

- **FR-025**: The runner config MUST keep the chart default `runner.config.file.container.privileged: false` for build containers spawned by act_runner inside DinD. The DinD sidecar itself is privileged (mandatory); the build containers it spawns are non-privileged children. This explicitly **rejects** the swarm-01 `values-dind-bypass.yaml` pattern (host-network + `privileged: false` build containers) — the chart default is correct for talos-ii.

#### Public/private exposure

- **FR-026**: The runner MUST NOT be exposed publicly. There MUST be no Cloudflare Tunnel route, no public DNS hostname, and no `envoy-external` HTTPRoute targeting the runner.
- **FR-027**: The runner MUST NOT be exposed on the tailnet via the in-cluster `tailscale-operator`. The runner is a job-pulling client; nothing needs to call it directly.

#### Cutover

- **FR-028**: Before the talos-i runner is decommissioned, the talos-ii runner MUST have demonstrably succeeded at least one full `build-and-push.yaml` run end-to-end (Story 1's acceptance scenarios all green).
- **FR-029**: The talos-i runner decommission MUST be a deliberate, runbook-tracked step (HelmRelease suspension on swarm-01 followed by deletion, plus runner unregistration in Forgejo's UI). It MUST NOT happen as a side-effect of this phase's automation.
- **FR-030**: A short outage window (the runner offline between talos-i decommission and talos-ii first-job pickup) is acceptable. No double-running steady state is required.

#### Documentation & process

- **FR-031**: The same commit chain that lands the manifests MUST include: (a) an ADR `docs/decisions/talos-ii/0013-forgejo-runner-talos-ii.md` recording the decision (DinD, x86_64, no-Tailscale-hop, sing-box-egress consumer); (b) an operator runbook section under `docs/operations/` covering deploy / verify / cutover / rollback; (c) updates to `docs/cluster-definition.md` to record the new namespace + workload; (d) a changelog entry in `docs/index.md` if the index uses one.
- **FR-032**: The ADR MUST cross-link to `shared/0002` (mesh integration modes), `shared/0003` (talos-i positioning — explains why talos-i is NOT getting the runner), and `shared/0004` (cluster egress gateway — explains why sing-box auto_redirect is the structural fix).

### Key Entities

- **`act_runner` container**: The Forgejo runner process. Pulls jobs from Forgejo, spawns build containers via the dockerd socket, streams logs back. Image: `code.forgejo.org/forgejo/runner:<pinned>-amd64` (exact version pin is a Plan-stage decision; current talos-i is `12.7.3`).
- **`dockerd` sidecar**: Privileged Docker daemon providing the socket the runner uses. Image: `172.16.80.240:5000/library/docker:29.2.1-dind-amd64` in Phase 1, flipping to `zot.network.svc.cluster.local:5000/library/docker:<version>-dind-amd64` in Phase 2 (exact version pin confirmed at Plan stage). Configured with non-default bridge `10.250.0.0/16` and registry mirror initially `http://172.16.80.240:5000`. Talks to act_runner over chart-default TLS on port 2376.
- **Build container**: An ephemeral container spawned by act_runner per workflow job. Image determined by the workflow's `runs-on` label resolution (e.g. `node:20.12-bookworm` for `ubuntu-latest`, `nixos/nix:latest` for `nix-builder`). Non-privileged (chart default). Inherits `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` from runner config's `container.envs`.
- **`forgejo-runner-init-config` Job (one-shot)**: Wrenix chart's registration Job. Two containers: `generate-config` (act_runner image) writes the `.runner` credential to a shared volume; `upload-config` (chart-default `docker.io/alpine/kubectl:1.35.3`, pulled via LAN zot) `kubectl patch`es that credential into the runner's `-configfile` Secret. Runs once per HelmRelease reconciliation; NOT a Deployment-level sidecar.
- **Runner registration secret**: SOPS-encrypted Secret containing `CONFIG_TOKEN`, `CONFIG_INSTANCE`, `CONFIG_NAME`. Distinct values from talos-i's registration; minted fresh from Forgejo at deploy time.
- **`forgejo-runner` namespace**: Dedicated namespace for the runner. Labelled with all three PSA labels at `privileged` (`enforce`, `audit`, `warn`).
- **sing-box DaemonSet (existing)**: External dependency. Already running on all three MS-01 nodes. Provides both env-explicit proxy on `:7890` and kernel-level `auto_redirect` interception. NOT modified by this phase.
- **In-cluster Forgejo Service (existing)**: `forgejo-http.development.svc.cluster.local:3000`. The runner's `CONFIG_INSTANCE` points here. (Plan stage confirms the exact Service name against the actual Forgejo HelmRelease values.)
- **In-cluster attic Service (existing)**: `attic.nix.svc.cluster.local:8080` (Phase 4a in flight per project memory). The workflow's `attic-action` step targets this.
- **LAN zot host (transitional)**: `http://172.16.80.240:5000` — Phase 1 dockerd registry mirror AND source of the `library/docker:<version>-dind-amd64` image itself. Will be replaced by in-cluster zot Service `zot.network.svc.cluster.local:5000` in Phase 2 (separately tracked, depends on spec `002-zot-on-talos-ii` completion).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: After deploy, dispatching `nix-fleet`'s `build-and-push.yaml` on a non-tagged commit completes all four parallel jobs (`warm-cache`, `build-systems` matrix, `build-installer-iso`, `build-and-push-k8s-sing-box-oci`) on the new talos-ii runner, end-to-end, on the first attempt with no manual re-runs.
- **SC-002**: The original failure mode — nix sandbox Go-fetcher HTTPS calls failing because the Go fetcher does not honor `HTTPS_PROXY` env — does NOT reproduce. A `nix build` step that pulls the `sops` Go module succeeds without any per-workflow env workaround.
- **SC-003**: Image pulls of `node:20.12-bookworm` and `nixos/nix:latest` flow through the configured registry mirror (Phase 1: LAN zot at `172.16.80.240:5000`; Phase 2: in-cluster zot Service). Verified by mirror-side request logs during a fresh-cache job.
- **SC-004**: After Story 2's cutover, exactly one runner with labels `ubuntu-latest` and `nix-builder` appears as `online` in Forgejo's runner UI; that runner is the talos-ii one. The talos-i runner is not in the list.
- **SC-005**: A workflow re-dispatch confirms zero workflow YAML edits were required in `nix-fleet` to migrate from talos-i to talos-ii runner — same `runs-on: ubuntu-latest`, same labels, same outcome.
- **SC-006**: `kubectl get all,helmreleases,secrets -n forgejo-runner` on **talos-i** returns nothing (or, if the swarm-01 manifests still physically exist there but are suspended from Flux, no Pods are running).
- **SC-007**: `nft list table inet sing-box` on each MS-01 node returns the same rule set before and after the runner Pod schedules, confirming no fwmark / chain collision with dockerd's iptables-nft chains.
- **SC-008**: When the Phase 2 mirror cutover happens (separate task), flipping the dockerd `daemon.json` `registry-mirrors` value is the only change required on the runner side. No re-registration, no namespace recreation, no Talos node reboot.
- **SC-009**: No public DNS hostname, no Cloudflare Tunnel route, and no Tailscale operator Service is created for the runner. Verified by namespace audit.
- **SC-010**: The migration introduces zero unplanned Talos node reboots. Any reboot during this phase that is not pre-declared in the runbook is a defect.

## Assumptions

- **sing-box DS Phase 2 is operational**: ADR `shared/0004` Phase 2 (DaemonSet on all three nodes with `auto_redirect`) is deployed and stable. If sing-box is partial or PoC-only on `ms01-a`, runner Pods must be node-affinity-pinned to `ms01-a` until Phase 2 catches up — that's a Plan-stage decision branch, not a spec-stage rewrite.
- **Forgejo on talos-ii is operational and reachable cluster-locally**: The Forgejo HelmRelease is on talos-ii (post Phase 3a-3e migrations). The runner's `CONFIG_INSTANCE` resolves via cluster DNS without any Tailscale hop.
- **attic on talos-ii is operational and reachable cluster-locally**: Same as above, post Phase 4a (attic migration in flight per project memory). If attic is still on swarm-01 at deploy time, the workflow's attic-action step will need the `tail5d550.ts.net` fallback URL until Phase 4a completes — that's a workflow-side concern, not a runner-side architectural decision.
- **LAN zot at `172.16.80.240:5000` remains reachable from MS-01 nodes during Phase 1**: Same connectivity assumption as the Talos installer and sing-box image bootstrap. Decommission of the LAN zot is a separately-tracked phase (post in-cluster zot in spec `002-zot-on-talos-ii`).
- **MS-01 nodes have headroom for DinD layer cache**: act_runner + dockerd + 3 concurrent build containers under load (nix builds) is non-trivial. We assume MS-01's CPU + memory headroom is sufficient; tuning `capacity` downward is acceptable if observed pressure warrants.
- **Privileged-pod admission on talos-ii is configurable via standard PSA labels**: Talos's PSA enforcement honors the three namespace labels (`pod-security.kubernetes.io/{enforce,audit,warn}: privileged`). No custom AdmissionPolicy is needed. The wrenix chart applies no PSA labels of its own; the Namespace manifest under `kubernetes/apps/forgejo-runner/forgejo-runner/` is the single source of truth.
- **Workflow secrets / vars (`ATTIC_ENDPOINT`, `ATTIC_CACHE`, `ATTIC_TOKEN`, `REGISTRY_ENDPOINT`, `REPO_TOKEN_OWNER`, `REPO_TOKEN`) are configured in Forgejo at the org/repo level**: This phase does not re-mint them; if any are missing or stale they're handled in `nix-fleet`, not here.
- **swarm-01 manifests as read-only reference**: The predecessor `swarm-01/kubernetes/apps/development/forgejo-runner/` files inform shape but are NOT migrated as-is. Vestigial parts (the unwired transparent-proxy `configmap.yaml`, the three Tailscale-egress `service-*.yaml` files) are explicitly NOT carried across.
- **x86_64-only is acceptable for v1**: There is no current arm64 / loongarch64 build target in `nix-fleet`'s workflow. When such a target lands, it will be paired with the `siderolabs/binfmt-misc` Talos extension landing on talos-ii (separate ADR, separate phase).

## Out of Scope

This phase does **not** do these things, deliberately:

- **Cross-arch CI** (arm64 / loongarch64). Deferred until `siderolabs/binfmt-misc` extension lands. Tracked separately.
- **GitLab runner / devcontainer-host runner** in the same namespace. The namespace is sized for them but no second runner is deployed in this phase.
- **Persistent layer cache for dockerd**. v1 uses `emptyDir`; layer cache is lost on Pod restart (re-fetchable from mirror). Persistent cache is a future optimization, not a v1 feature.
- **In-cluster zot mirror cutover** (Phase 2). This phase deploys with LAN zot as the mirror; switching to in-cluster zot is the separately-tracked follow-on phase that depends on spec `002-zot-on-talos-ii` completing.
- **NixOS-CI workflow YAML changes**. The workflow's `runs-on` labels and proxy config remain identical. If any workflow tweak turns out necessary post-deploy, it's a `nix-fleet` repo concern, not this phase.
- **talos-i runner re-deployment**. The talos-i runner is decommissioned and not replaced. Future CI on talos-i, if ever needed, would be its own spec.
- **Public exposure of any runner artifacts**. Runners pull jobs; they don't serve traffic. No Cloudflare Tunnel, no public DNS.
- **Tailscale-operator hops for in-cluster destinations**. The whole point of being on talos-ii is that Forgejo + attic + zot are local — no tailnet hop. The talos-i runner's three ExternalName Services are explicitly not carried across.
- **Modifying sing-box DaemonSet behavior**. If the runner reveals a sing-box tuning need (timeouts, `route_exclude_address` tweaks), it's tracked under `shared/0004`, not as a runner-side workaround.

## Open Questions

The five `[NEEDS CLARIFICATION]` markers from the `/specify` draft are resolved (see "Decisions Resolved" near the top). The items below are residual Plan-stage refinements, not spec-stage blockers:

- **Forgejo HTTP Service name verification**: The decided value is `forgejo-http.development.svc.cluster.local:3000`. Plan stage MUST cross-check this against the actual Forgejo HelmRelease's `service` block on talos-ii — chart variants sometimes name it `forgejo` rather than `forgejo-http`. If the actual name differs, FR-018 / Key Entities update is mechanical.
- **In-cluster zot Service namespace**: The decided value is `zot.network.svc.cluster.local:5000`. The `network` namespace is assumed (matches sing-box). Plan stage confirms when spec `002-zot-on-talos-ii` lands.
- **dockerd version pin freshness check**: Initial pin is `29.2.1-dind-amd64`. Plan stage spends 5 minutes checking the upstream `library/docker` Docker Hub tag list for security-relevant newer patches (`29.2.x` or `29.3.x`); bump if so.
- **runner-container hardening (postRenderer Kustomize patch)**: The chart sets `securityContext.privileged: true` on the runner container (not just dind). Recommended hardening: drop privileged + add `runAsUser: 1000` on the runner container only via a postRenderer Kustomize patch. Plan stage decides whether to ship this in v1 or defer.
- **Persistent layer cache trade-off**: `emptyDir` for `/var/lib/docker` is the v1 default (FR-021). If observed cold-start cost is high after deploy, swap to a Longhorn PVC. This is a follow-on tweak, not a blocker.
- **act_runner log-stream path back to Forgejo**: act_runner streams job logs back to `CONFIG_INSTANCE`. Since `CONFIG_INSTANCE` is `*.svc.cluster.local`, NO_PROXY should exempt it — but verify the log stream isn't accidentally going through sing-box, which would round-trip pointlessly. Tested in Plan stage.
- **CoreDNS resolution from inside build containers under `network: host`**: swarm-01 uses `runner.config.file.container.network: host` so build containers inherit the host Pod's resolv.conf (Cilium CoreDNS). This MUST work on talos-ii too; if it doesn't (because Talos host networking differs subtly), Plan stage works around. (Inheriting "host" here means the *Pod's* network namespace, not the Talos node's — a common point of confusion.)

## Constitution Check

Cross-reference of this spec against the project constitution (`/.specify/memory/constitution.md`, version 1.1.0):

- **Principle II (Storage, [both])**: PASS — the runner has no PersistentVolume need in v1. dockerd layer cache is `emptyDir`. If we later add persistent layer cache, it will use Longhorn-r2 per the principle.
- **Principle III (Network, [talos-ii])**: PASS — runner sits on Cilium PodCIDR `10.44.0.0/16` like every other workload. dockerd's bridge `10.250.0.0/16` is internal to the Pod network namespace and doesn't intersect with the host VLAN 87 (`172.16.87.0/24`).
- **Principle V (Secrets, [both])**: PASS — registration token SOPS-encrypted (FR-004); no plaintext at rest in git.
- **Principle VI (Public exposure, [both])**: N/A — no public exposure (FR-026).
- **Principle VII (Private exposure, [both])**: PASS-by-omission — the runner is a client, not a server. No NodePort, no Tailscale operator Service exposure (FR-027). The constitution's rule applies to *exposing* services; this spec exposes nothing.
- **Principle VIII (GitOps, [both])**: PASS — all manifests under `kubernetes/apps/forgejo-runner/forgejo-runner/` reconciled by Flux (FR-003); no manual `kubectl apply` for steady state.
- **Principle IX (Spec-Driven Development, [both])**: PASS by construction — this is the `/specify` artifact for the change.
- **Principle X (Documentation, [both])**: PASS by requirement — FR-031 mandates ADR + runbook + cluster-definition + index updates in the same commit chain. ADR cross-link requirements in FR-032.
- **Principle XI (No surprise reboots, [both])**: PASS — runner deployment is a HelmRelease in a new namespace; touches no Talos machine-config, triggers no node reboot. SC-010 makes this an explicit acceptance gate.
- **Per-cluster scoping rule** (project memory `feedback_per_cluster_scoping.md`): PASS — Scope section above explicitly tags `[talos-ii]` only; FR-001 + SC-006 enforce no-deploy-on-talos-i. Critically, the talos-i runner is **decommissioned**, not duplicated; this directly counters the swarm-01 anti-pattern of accumulating per-cluster duplicates.
