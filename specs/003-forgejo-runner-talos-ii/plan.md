# Implementation Plan: Forgejo Actions runner on talos-ii (DinD)

**Branch**: `003-forgejo-runner-talos-ii` | **Date**: 2026-05-04 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/003-forgejo-runner-talos-ii/spec.md`

## Summary

Deploy a single-replica Forgejo Actions runner Pod on talos-ii using the wrenix `forgejo-runner` Helm chart in DinD shape (`act_runner` + privileged `dockerd` sidecar) on a fresh `forgejo-runner` namespace with PSA `enforce/audit/warn: privileged`. x86_64-only. The runner consumes the in-cluster sing-box egress gateway (ADR `shared/0004` Phase 2, DaemonSet on all three MS-01 nodes with `auto_redirect`) as a CI consumer — both via explicit `HTTP_PROXY` env on `act_runner` + spawned build containers, and implicitly via kernel-level `auto_redirect` for tools that ignore env (notably nix sandbox Go fetches). Forgejo, attic, and the registry mirror are reached through cluster-local DNS (`forgejo-http.development.svc:3000`, `attic.nix.svc:8080`, `zot.registry.svc:5000`) with zero Tailscale operator hops — this is the entire reason for moving off talos-i. Phase 1 mirrors dockerd registry pulls through the LAN zot at `172.16.80.240:5000` (anonymous read); Phase 2 (config-only flip, separately tracked) moves to the in-cluster zot at `zot.registry.svc.cluster.local:5000` with htpasswd auth via a docker `config.json`. dockerd uses non-default bridge `10.250.0.0/16` to avoid colliding with the `172.16.0.0/12` Tailscale subnet umbrella; that subnet falls inside sing-box's `route_exclude_address` so DinD-internal traffic is NOT TUN-intercepted (the correct intentional behavior). Cutover is talos-i-runner-off → mint fresh registration token in Forgejo → SOPS-encrypt + commit → Flux reconciles → smoke-test `nix-fleet`'s `build-and-push.yaml` → close. No double-running steady state; short outage is acceptable.

## Technical Context

**Workload type**: stateful Pod (single Deployment replica, two long-running containers + a one-shot `forgejo-runner-init-config` Job). No external traffic served — runner is a job-pulling client.
**Helm chart**: `oci://codeberg.org/wrenix/helm-charts/forgejo-runner` ref tag `0.7.6` (latest "knownLastVersion" — chart enforces explicit opt-in via `knownLastVersion: true` to acknowledge upstream's "last released" status).
**Primary container images**:
- `act_runner`: `code.forgejo.org/forgejo/runner:12.7.3` (Plan-stage check at apply time for newer 12.7.x patches). Pulled through LAN zot mirror (zot proxies `code.forgejo.org`). **Note**: swarm-01 pinned `12.7.3-amd64`, but that literal tag does NOT exist upstream (verified at T003 — returns 404). The non-suffixed tag is the multi-arch manifest list, which resolves to amd64 on x86_64 nodes automatically.
- `dind`: `172.16.80.240:5000/library/docker:29.2.1-dind` in Phase 1 (LAN zot pull-through cache). Same `-amd64` suffix correction as above — Docker Hub publishes `29.2.1-dind`, `29.2.1-dind-rootless`, `29.2.1-dind-alpine3.23` but NOT `29.2.1-dind-amd64`. The multi-arch tag `29.2.1-dind` resolves to amd64 automatically. Plan-stage 5-minute spot-check on Docker Hub `library/docker` tag list — bump only if `29.2.x` security patch released.
- `kubectl`: chart default `docker.io/alpine/kubectl:1.35.3` (the chart's registration Job container) — Talos `machine-registries` already proxies `docker.io` through LAN zot, so the chart-default reference works without override.

**Storage backend**: chart-default `emptyDir` for `runner-data`, `runner-config`, `docker-certs`. No PVC for `/var/lib/docker` in v1 — layer cache is lost on Pod restart (re-fetchable from mirror; cost is one extra round-trip on cold start). See [research.md Q5](./research.md#q5--persistent-layer-cache-decision).
**Database**: none.
**Egress policy**:
- `act_runner` container: `HTTP_PROXY` / `HTTPS_PROXY` / `http_proxy` / `https_proxy` = `http://sing-box.network.svc.cluster.local:7890`. `NO_PROXY` (and lowercase `no_proxy`) carries `.beaco.works,.beacoworks.xyz,.svc,.svc.cluster.local,.svc.cluster.local.,.cluster.local,.cluster.local.,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1` — note both dotted and trailing-dot variants of `.cluster.local` per the attic 2026-04-28 incident (Go's `net/http/httpproxy` matcher does not normalize trailing dots).
- spawned build containers: same env propagated via `runner.config.file.container.envs` (chart-native channel).
- `dockerd` sidecar: NO `HTTP_PROXY` / `HTTPS_PROXY` env. Image-pull traffic flows to the configured registry-mirror (LAN zot in Phase 1 → in-cluster zot in Phase 2); the mirror handles its own upstream egress through sing-box. Pushing dockerd's TLS handshakes through sing-box would be redundant and would re-enter the auto_redirect intercept loop.
- Underlying kernel safety net: sing-box DS `auto_redirect: true` on all three MS-01 nodes captures egress packets at host netfilter regardless of env propagation — this is the structural fix to the nix-sandbox Go-fetcher failure mode.

**Node-side / cluster-side exposure**: NONE. No Service, no NodePort, no LoadBalancer, no `tailscale-operator` annotation, no HTTPRoute, no Cloudflare Tunnel. Runner is purely a client (FR-026, FR-027).
**Auth model**: htpasswd-style basic auth at the **dockerd → in-cluster zot** boundary in Phase 2 (anonymous read in Phase 1 against LAN zot). For Phase 2 we mount a docker `config.json` from a SOPS Secret at `/root/.docker/config.json` in the dockerd container with the `auths` block containing the zot admin credentials. See [contracts/dockerd-config.md](./contracts/dockerd-config.md). For runner registration: `CONFIG_TOKEN` / `CONFIG_INSTANCE` / `CONFIG_NAME` SOPS-encrypted in `registration-token.sops.yaml`; bootstrap-only (chart's registration Job persists credentials to the runner's `-configfile` Secret on first run).
**Runner labels**: exactly `ubuntu-latest:docker://node:20.12-bookworm` and `nix-builder:docker://nixos/nix:latest`. Identical to talos-i; zero workflow YAML edits required in `nix-fleet`.
**Concurrency**: `replicaCount: 1`, `runner.config.file.runner.capacity: 3`, no HPA. Job timeout `12h`.
**Resource shape (per FR-021)**:
- `runner` container: requests `cpu=100m mem=256Mi`, limits `cpu=2 mem=512Mi`.
- `dind` container: requests `cpu=500m mem=2Gi`, limits `cpu=8 mem=8Gi`.
- Pod-level ephemeral storage: requests `30Gi`, limits `60Gi`.

**Talos machine-config delta**: NONE. No new mirror entries, no new schematic, no node reboot. The runner is a regular Pod; Talos PSA enforcement honors namespace labels per Edge Case "Privileged mode + Talos".
**Project type**: GitOps cluster manifest set + ADR + runbook. No application code.
**Constraints**: no public exposure (FR-026); no tailnet exposure (FR-027); zero workflow YAML edits in `nix-fleet` (SC-005); zero unplanned Talos reboots (SC-010); deploy-on-talos-ii-only (FR-001 / SC-006); coexistence with sing-box DS netfilter without rule collision (FR-023 / SC-007).
**Scale/scope**: single pod, single MS-01 node at any time. Worst-case 6-job concurrency (3 active, 3 queued) — accepted because nix-fleet is the only consumer and is human-triggered.

## Constitution Check

Cross-checked against [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.1.0:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] — bare metal, no nesting | ✅ pass | Pure k8s workload; no hypervisor surface. |
| **II. Storage** [both] — Longhorn only, `replicaCount: 3` for irreplaceable | ✅ N/A | No PVC in v1. dockerd layer cache is `emptyDir`; content is replaceable from mirror. |
| **III. Network** [talos-ii] — Cilium, no overlay | ✅ pass | Pod sits on Cilium PodCIDR `10.44.0.0/16` like every other workload. dockerd's bridge `10.250.0.0/16` is internal to the Pod network namespace and does NOT intersect with VLAN 87 (`172.16.87.0/24`). |
| **IV. Image factory** [talos-ii] — official factory, no custom extensions | ✅ pass | No Talos image change. No new schematic. |
| **V. Secrets** [both] — age, gitignored private key | ✅ pass | `registration-token.sops.yaml` SOPS-encrypted with the swarm cluster age recipient `age19w3svwspecedu893ges7te9qc5qgj3r5tykpkqrl43f90ndlvg4qant4ej`. Phase 2's docker `config.json` likewise SOPS-encrypted. |
| **VI. Public exposure** [both] — Cloudflare Tunnel default | ✅ N/A | No public exposure (FR-026). |
| **VII. Private exposure** [both] — Tailscale operator only, no NodePort | ✅ pass-by-omission | Runner is a client. No NodePort, no `tailscale-operator` Service. The talos-i runner's three ExternalName + Tailscale-annotation Services are explicitly NOT carried across (Edge Case "Vestigial `service-{forgejo,attic,zot}-egress.yaml`"). |
| **VIII. GitOps** [both] — flux reconciles `kubernetes/apps/*` | ✅ pass | All manifests under `kubernetes/apps/forgejo-runner/forgejo-runner/`. |
| **IX. Spec-Driven Development** [both] | ✅ pass | This Plan + `spec.md` are the artifacts. |
| **X. Documentation** [both] — ADR + index update in same commit chain | ✅ pass-by-requirement | FR-031 / FR-032 mandate ADR `0013-forgejo-runner-talos-ii.md` + runbook + `cluster-definition.md` + `index.md` updates at implement time. ADR cross-links `shared/0002`, `shared/0003`, `shared/0004`. |
| **XI. No surprise reboots / destructive shortcuts** [both] | ✅ pass | No Talos machine-config touch. SC-010 enforces this as an acceptance gate. |
| **Per-cluster scoping** rule (project memory `feedback_per_cluster_scoping.md`) | ✅ pass | Spec Scope tags `[talos-ii]` only; FR-001 / SC-006 forbid talos-i deployment AND require the talos-i runner be decommissioned (not duplicated). |

### Constitution-relevant explicit acknowledgment: privileged dind

The `dind` container's `securityContext.privileged: true` is **mandatory** (FR-006, FR-007) and is an opt-in via the `forgejo-runner` namespace's three PSA labels at `privileged`. The constitution does not have a "no privileged Pods" principle; the relevant gate is Principle XI ("destructive shortcuts") which this satisfies because the privilege is scoped to a single namespace, well-known to be a CI sandbox by design, and is the single supported runtime for `docker:dind` on Talos. Spec Decisions Resolved Q4 walks through the alternatives (rootless-docker, Sysbox, Kubernetes-native runners) and rejects them for this phase. The runner-container privileged-drop-via-postRenderer is a Plan-stage hardening decision — see [research.md Q4](./research.md#q4--runner-container-hardening-postrenderer-kustomize-patch).

**Result: PASS — no Constitution violations. No Complexity Tracking entries required.**

## Project Structure

### Documentation (this feature)

```text
specs/003-forgejo-runner-talos-ii/
├── plan.md                              # This file
├── research.md                          # Phase 0 — Plan-stage decisions resolved
├── data-model.md                        # Phase 1 — entity shapes (HelmRelease values, Namespace, Secret, ConfigMap)
├── quickstart.md                        # Phase 1 — operator runbook (cutover ordering, verification, rollback)
├── contracts/
│   ├── dockerd-config.md                # Phase 1 — dockerd daemon.json shape (Phase 1 + Phase 2)
│   └── runner-registration.md           # Phase 1 — registration secret shape + token-mint procedure
├── checklists/
│   └── requirements.md                  # written by /specify
└── tasks.md                             # Phase 2 — written by /tasks (NOT by this command)
```

### Source code / repo layout (impacted areas)

```text
kubernetes/
└── apps/
    └── forgejo-runner/                                  # NEW namespace dir (top-level)
        ├── kustomization.yaml                           # NEW (lists ./forgejo-runner)
        ├── namespace.yaml                               # NEW — Namespace with three PSA `privileged` labels
        └── forgejo-runner/                              # NEW app dir (mirrors zot/zot, attic/attic shape)
            ├── ks.yaml                                  # NEW — Flux Kustomization, no dependsOn, targetNamespace forgejo-runner
            └── app/
                ├── kustomization.yaml                   # NEW — resource list
                ├── ocirepository.yaml                   # NEW — wrenix forgejo-runner chart 0.7.6 from codeberg.org
                ├── helmrelease.yaml                     # NEW — full values (image pins, runner config, dind config, postRenderers)
                ├── registration-token.sops.yaml         # NEW — CONFIG_TOKEN / CONFIG_INSTANCE / CONFIG_NAME (SOPS-encrypted)
                └── dockerd-config.yaml                  # NEW — ConfigMap with daemon.json (mounted into dind container)
                                                        #   Phase 2 adds dockerd-zot-auth.sops.yaml (docker config.json with zot creds)

docs/
├── index.md                                             # MODIFIED — add ADR + runbook entries (separate task per FR-031)
├── cluster-definition.md                                # MODIFIED — record forgejo-runner namespace + workload on talos-ii
├── decisions/talos-ii/0013-forgejo-runner-talos-ii.md   # NEW (separate task per FR-031, NOT in this plan)
└── operations/forgejo-runner.md                         # NEW (separate task per FR-031, NOT in this plan)
```

**Structure decision**: top-level namespace dir `kubernetes/apps/forgejo-runner/` (analogous to `registry/` from spec 002 and `nix/` from Phase 4a) with a single child app dir of the same name. The double-nesting (`forgejo-runner/forgejo-runner/`) matches `registry/zot/`, `nix/attic/`, etc. — the outer namespace dir's `kustomization.yaml` lists `./namespace.yaml` + `./forgejo-runner/ks.yaml`, and the inner `app/` dir is what Flux's child Kustomization actually points at. This is the canonical repo convention; deviating would be a per-cluster-scoping anti-pattern. The new namespace dir is automatically picked up by `kubernetes/flux/cluster/ks.yaml`'s `path: ./kubernetes/apps` (which recurses via the apps-level convention) — no edit needed there. **Crucially: nothing under `templates/`** (no Talos machine-config delta).

## Phase 0 — Outline & Research

The five `[NEEDS CLARIFICATION]` markers from the `/specify` draft are already resolved in the spec's "Decisions Resolved" section (Q1–Q5). The Plan-stage research items below correspond to the spec's "Open Questions" section (residual Plan-stage refinements, not spec-stage blockers) plus three additional design decisions surfaced during plan investigation. They're written up in [research.md](./research.md):

1. **Q1 — In-cluster Service-name verification** ([research.md Q1](./research.md#q1--in-cluster-service-names-verification)). Spec assumed `zot.network.svc.cluster.local` for the future Phase 2 mirror. Field investigation via `kubectl get svc -A | grep zot` confirmed actual is `zot.registry.svc.cluster.local:5000` (zot lives in the `registry` namespace on talos-ii, not `network`). Forgejo HTTP API confirmed at `forgejo-http.development.svc.cluster.local:3000` (chart-default Service name is `forgejo-http`, not `forgejo`). Attic confirmed at `attic.nix.svc.cluster.local:8080`. **All references in this plan, helmrelease.yaml values, and Phase 2 dockerd config use the actual names**, not the spec's tentative ones. The spec's open question on this is closed.

2. **Q2 — dockerd image version pin freshness** ([research.md Q2](./research.md#q2--dockerd-image-version-pin)). Initial pin is `library/docker:29.2.1-dind-amd64` (matches swarm-01). 5-minute spot-check at apply time on Docker Hub's `library/docker` tag list; bump if `29.2.x` security patch released. Decision is to **lock at `29.2.1-dind-amd64` for first deploy** to minimize variables vs. swarm-01 reference; bump in a follow-up commit if observed drift warrants. Pulled via LAN zot at `172.16.80.240:5000/library/docker:29.2.1-dind-amd64` — zot's pull-through cache adds the tag on first request (already configured to proxy `docker.io`).

3. **Q3 — dockerd daemon.json injection mechanism** ([research.md Q3](./research.md#q3--dockerd-daemonjson-injection-mechanism)). The wrenix chart (verified by reading `/tmp/forgejo-runner/templates/deployment.yaml`) does NOT have a values knob for dockerd configuration files — it sets only `DOCKER_TLS_CERTDIR=/certs` env and mounts the `docker-certs` volume. To inject `daemon.json`, we use a **separate ConfigMap (`forgejo-runner-dockerd-config`) mounted via a postRenderer Kustomize patch** at `/etc/docker/daemon.json` on the dind container with `subPath: daemon.json` (so only the file is overlaid, not the entire `/etc/docker/` directory). The patch indexes the dind container by position (`containers/1`); chart 0.7.6 declares runner first, dind second. See [contracts/dockerd-config.md](./contracts/dockerd-config.md) for the exact patch shape.

4. **Q4 — Runner-container hardening (postRenderer Kustomize patch)** ([research.md Q4](./research.md#q4--runner-container-hardening-postrenderer-kustomize-patch)). The chart sets `securityContext.privileged: true` on the **runner** container as well as dind (chart values default `securityContext.privileged: true` is shared by both via `{{- toYaml .Values.securityContext | nindent 12 }}`). Decision: **defer runner-container hardening to a follow-up commit**, NOT in v1. Rationale: (a) the chart's runner container runs as root and has no cluster-API access (its ServiceAccount has no RoleBinding outside the `forgejo-runner-init-config` Job's secret-patch role, which only affects the Job's `upload-config` container); (b) the `runner` container's only privileged operation is `nc -z 127.0.0.1 2376` health probing of the dind socket, which doesn't require privileged but does require root in the chart's current entrypoint; (c) shipping the postRenderer patch in v1 risks breaking the chart's startup ordering for a non-load-bearing security improvement on a CI sandbox. Once v1 is stable and Story 1 is green, a separate commit drops `runner` privileged + adds `runAsUser: 1000` via postRenderer. Tracked as a follow-on task, not blocking.

5. **Q5 — Persistent layer cache decision** ([research.md Q5](./research.md#q5--persistent-layer-cache-decision)). Decision: **emptyDir for v1**, NOT a Longhorn PVC. Rationale: (a) Pod restarts are infrequent (HelmRelease reconcile triggers a restart on values change, otherwise restarts are operator-initiated); (b) re-fetching layer cache from the LAN zot mirror takes ~20-30s on cold start vs. the ~2-minute baseline of a `nix build`, so the marginal cost is small; (c) a Longhorn PVC introduces a Pod-shutdown ordering concern (dockerd's `/var/lib/docker` write must flush before umount, and Talos's pod-shutdown grace period default is 30s, which is borderline for a busy layer cache directory); (d) future optimization path is clear if observed cold-start cost grows — swap `emptyDir` for `Longhorn r2` PVC in a single-line values change. Defer to follow-on.

6. **Q6 — Phase 2 cutover authentication mechanism** ([research.md Q6](./research.md#q6--phase-2-zot-auth-via-docker-configjson)). The in-cluster zot at `zot.registry.svc.cluster.local:5000` requires htpasswd basic auth for **mgmt routes and write paths**, with anonymous read-only on `**` repo paths. dockerd's mirror pulls are read-only (HTTP `GET /v2/.../manifests/...` and `/v2/.../blobs/...`) — but zot's anonymous read may still trigger auth challenges depending on the `accessControl` policy. Verified path: dockerd's `daemon.json` `registry-mirrors` accepts URLs without auth, but auth is configured separately via `~/.docker/config.json` on the **dockerd container's filesystem** (NOT via daemon.json). Phase 2 mounts a SOPS Secret `dockerd-zot-auth.sops.yaml` containing a docker `config.json` at `/root/.docker/config.json` in the dind container. The secret has shape `{"auths":{"zot.registry.svc.cluster.local:5000":{"auth":"<base64(admin:password)>"}}}`. Phase 1 (LAN zot, anonymous read) needs no auth at all. Phase 2 is config-only (one new SOPS Secret + one extra volumeMount in the postRenderer patch + one-line `daemon.json` `registry-mirrors` URL flip). See [contracts/dockerd-config.md](./contracts/dockerd-config.md).

7. **Q7 — `network: host` and CoreDNS resolution from spawned build containers** ([research.md Q7](./research.md#q7--network-host-and-coredns-resolution)). The runner config sets `runner.config.file.container.network: host` matching swarm-01. "host" here means the **act_runner Pod's network namespace** (not the Talos node's host network namespace) — common point of confusion. In that namespace the Pod's `/etc/resolv.conf` points at the cluster CoreDNS service, so spawned build containers inherit cluster DNS resolution and can resolve `attic.nix.svc.cluster.local` etc. natively. **This is verified by the same setting working on swarm-01 with the same Cilium CoreDNS topology.** No DNS workaround needed.

8. **Q8 — act_runner log-stream path back to Forgejo** ([research.md Q8](./research.md#q8--actrunner-logstream-not-routed-via-singbox)). The runner's `CONFIG_INSTANCE` is `http://forgejo-http.development.svc.cluster.local:3000`, which falls under the `.svc.cluster.local` NO_PROXY entry. Therefore the log-stream HTTP requests from `act_runner` to Forgejo go **direct** (cluster ClusterIP), NOT through sing-box. Verified at apply time by inspecting sing-box logs during a job run — there should be no entries for `forgejo-http.development.svc` destinations. Avoids the pointless round-trip through the proxy.

**Output**: [research.md](./research.md) — all Plan-stage open items resolved; no blockers for Phase 1.

## Phase 1 — Design & Contracts

### Entities ([data-model.md](./data-model.md))

- **Namespace** (1): `forgejo-runner` — new top-level namespace. Three PSA labels: `pod-security.kubernetes.io/enforce: privileged`, `pod-security.kubernetes.io/audit: privileged`, `pod-security.kubernetes.io/warn: privileged`. Annotation `kustomize.toolkit.fluxcd.io/prune: disabled` per repo convention (matches `registry/namespace.yaml` shape).
- **Secret** (1 in v1, 2 from Phase 2): `forgejo-runner-secret` with stringData keys `CONFIG_TOKEN`, `CONFIG_INSTANCE`, `CONFIG_NAME`. SOPS-encrypted with the swarm cluster age recipient. Phase 2 adds `dockerd-zot-auth` Secret with docker `config.json` payload.
- **ConfigMap** (1): `forgejo-runner-dockerd-config` — non-secret `daemon.json` payload. Phase 1 content: `{"registry-mirrors":["http://172.16.80.240:5000"],"insecure-registries":["172.16.80.240:5000"],"bip":"10.250.0.1/16"}`. Phase 2 flips one line: `"registry-mirrors":["http://zot.registry.svc.cluster.local:5000"]` and updates `insecure-registries` accordingly (in-cluster zot serves plain HTTP from inside the cluster).
- **OCIRepository** (1): `forgejo-runner` — chart `0.7.6` from `oci://codeberg.org/wrenix/helm-charts/forgejo-runner`. Note: this ref pulls **directly from codeberg.org**, not via LAN zot, because the wrenix chart is not pre-pushed to LAN zot. Consistent with the swarm-01 reference. Flux's source-controller goes through the cluster's general egress, NOT the runner's HTTP_PROXY (source-controller is a different Pod). If codeberg.org reachability ever becomes a CI-time concern, a follow-up phase could push the chart into the LAN zot under `oci://172.16.80.240:5000/charts/forgejo-runner` (same one-time push pattern as `tailscale-operator` / `zot/zot`); not required for v1.
- **HelmRelease** (1): `forgejo-runner` — full values block (see [data-model.md](./data-model.md) for the exact YAML). Notable shape:
  - `knownLastVersion: true` (chart enforcement)
  - `replicaCount: 1`
  - `image.{registry,repository,tag}` → `code.forgejo.org` / `forgejo/runner` / `12.7.3-amd64`
  - `dind.image.{registry,repository,tag}` → `172.16.80.240:5000` / `library/docker` / `29.2.1-dind-amd64`
  - `kubectl.image` → chart default `docker.io/alpine/kubectl:1.35.3` (resolved through Talos's `machine-registries` mirror config)
  - `runner.config.create: true` + `runner.config.existingInitSecret: forgejo-runner-secret`
  - `runner.config.file.runner.{capacity: 3, timeout: 12h, labels: [...]}`
  - `runner.config.file.container.{network: host, valid_volumes: [], options: "-v /workspace", privileged: false}`
  - `runner.config.file.container.envs.{HTTP_PROXY, HTTPS_PROXY, http_proxy, https_proxy, NO_PROXY, no_proxy, GOPROXY}`
  - `dind.resources.{requests, limits}` per FR-021
  - `resources.{requests, limits}` for the runner container per FR-021 (chart's top-level `resources` applies to runner container)
  - `securityContext.privileged: true` (chart default; both runner and dind containers inherit; runner-hardening deferred per Q4)
  - `postRenderers[0].kustomize.patches[]`: (a) inject `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` env on the runner container (chart's `runner.config.file.container.envs` only sets env on **spawned build containers**, NOT on the act_runner Pod's runner container itself — same swarm-01 postRenderer pattern); (b) add `volumeMount` for the dockerd-config ConfigMap on the dind container at `/etc/docker/daemon.json` with `subPath: daemon.json`; (c) add the corresponding `volume` entry referencing the ConfigMap. Phase 2 adds a fourth patch mounting the dockerd-zot-auth Secret at `/root/.docker/config.json` on the dind container.
- **Flux Kustomization** (1): `forgejo-runner` — applies `kubernetes/apps/forgejo-runner/forgejo-runner/app`, no dependsOn, `targetNamespace: forgejo-runner`, `postBuild.substituteFrom: [{name: cluster-secrets, kind: Secret}]` per repo convention.
- **No Service, no HTTPRoute, no PVC, no NetworkPolicy in v1**.

### Contracts

#### [contracts/runner-registration.md](./contracts/runner-registration.md)

- Manifest skeleton for `registration-token.sops.yaml` with `stringData: {CONFIG_TOKEN, CONFIG_INSTANCE, CONFIG_NAME}`.
- `CONFIG_INSTANCE` value: `http://forgejo-http.development.svc.cluster.local:3000`. Note: cluster-local plain HTTP (no TLS) is fine because the traffic stays inside the Pod network and Forgejo doesn't enforce HTTPS-only on the chart-default Service.
- `CONFIG_NAME` value: `forgejo-runner-talos-ii` (distinct from the talos-i registration name `forgejo-runner` per FR-005, so the operator can disambiguate during cutover).
- `CONFIG_TOKEN` value: minted at deploy time. Two paths documented:
  1. **CLI inside Forgejo pod** (preferred — scriptable):
     ```
     kubectl -n development exec deploy/forgejo -- forgejo actions generate-runner-token
     ```
     Use a deployment selector to be restart-resilient. Token is bootstrap-only and expires (~7 days default); once the runner registers, it gets a persistent credential in the chart's `forgejo-runner-config` Secret.
  2. **Admin UI** (manual): Site Administration → Actions → Runners → Create new runner → copy token (one-shot, do not navigate away).
- After mint, encrypt with `sops -e -i registration-token.sops.yaml` (the `.sops.yaml` regex already covers `kubernetes/.*\.sops\.yaml`).
- Recipient: `age19w3svwspecedu893ges7te9qc5qgj3r5tykpkqrl43f90ndlvg4qant4ej` (swarm cluster age key from `.sops.yaml`).
- The chart's `forgejo-runner-init-config` Job consumes this Secret as `envFrom: secretRef: name: forgejo-runner-secret` (chart value `runner.config.existingInitSecret`). On first reconciliation the Job's `generate-config` container calls `forgejo-runner register` against `CONFIG_INSTANCE` and writes a `.runner` credential to a shared volume; the `upload-config` container then `kubectl patch`es that credential into the `forgejo-runner-config` Secret. From that point onward the registration token in `forgejo-runner-secret` is unused — the runner authenticates via the persisted credential. The token can therefore be allowed to expire after first successful registration; no rotation needed.

#### [contracts/dockerd-config.md](./contracts/dockerd-config.md)

- **Phase 1 `daemon.json`**:
  ```json
  {
    "registry-mirrors": ["http://172.16.80.240:5000"],
    "insecure-registries": ["172.16.80.240:5000"],
    "bip": "10.250.0.1/16"
  }
  ```
  - `bip` (bridge IP) chosen over `default-address-pools` because (a) the runner only spawns containers on `docker0` (single network), (b) `bip` is the simplest possible knob, (c) `default-address-pools` is for when containers span multiple custom networks which we don't do. If a future workflow needs a custom network (`docker network create`), switch to `default-address-pools` then; not needed for v1.
  - `10.250.0.1/16` chosen because (a) `10.250.0.0/16` is comfortably inside sing-box's `route_exclude_address` of `10.0.0.0/8`, (b) does not collide with Cilium's PodCIDR `10.44.0.0/16` or ServiceCIDR `10.55.0.0/16`, (c) does not collide with the `172.16.0.0/12` Tailscale subnet umbrella.
  - `insecure-registries` is required because `172.16.80.240:5000` serves plain HTTP (no TLS); without this entry dockerd refuses to use it as a mirror.
- **Phase 2 `daemon.json`** (separate follow-up commit, NOT in v1):
  ```json
  {
    "registry-mirrors": ["http://zot.registry.svc.cluster.local:5000"],
    "insecure-registries": ["zot.registry.svc.cluster.local:5000"],
    "bip": "10.250.0.1/16"
  }
  ```
  Plus `/root/.docker/config.json` mounted from `dockerd-zot-auth.sops.yaml`:
  ```json
  {
    "auths": {
      "zot.registry.svc.cluster.local:5000": {
        "auth": "<base64(admin:password)>"
      }
    }
  }
  ```
  The base64 value is `echo -n 'admin:<plaintext-from-zot-secret>' | base64`. Both Secrets (zot-side and dockerd-side) share the same admin password (rotation requires updating both in lock-step).
- **postRenderer patch shape** (Kustomize JSONPatch, applied to the rendered Deployment):
  ```yaml
  patches:
    - target: { kind: Deployment, name: forgejo-runner }
      patch: |
        # 1) inject HTTP_PROXY env on runner container (containers[0])
        - op: add
          path: /spec/template/spec/containers/0/env/-
          value: { name: HTTP_PROXY, value: "http://sing-box.network.svc.cluster.local:7890" }
        - op: add
          path: /spec/template/spec/containers/0/env/-
          value: { name: HTTPS_PROXY, value: "http://sing-box.network.svc.cluster.local:7890" }
        - op: add
          path: /spec/template/spec/containers/0/env/-
          value: { name: NO_PROXY, value: ".beaco.works,.beacoworks.xyz,.svc,.svc.cluster.local,.svc.cluster.local.,.cluster.local,.cluster.local.,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1" }
        # 2) mount dockerd-config ConfigMap on dind container (containers[1])
        - op: add
          path: /spec/template/spec/containers/1/volumeMounts/-
          value: { name: dockerd-config, mountPath: /etc/docker/daemon.json, subPath: daemon.json }
        # 3) add the volume entry
        - op: add
          path: /spec/template/spec/volumes/-
          value:
            name: dockerd-config
            configMap:
              name: forgejo-runner-dockerd-config
              items:
                - { key: daemon.json, path: daemon.json }
  ```
  - Container index `0` = runner, index `1` = dind, verified by reading wrenix chart 0.7.6 `templates/deployment.yaml` (runner declared first, then dind). If a future chart version reorders containers, the patch silently mounts daemon.json into the wrong container — verify post-apply: `kubectl -n forgejo-runner get pod -o yaml | yq '.spec.containers[].name'` (expect `[runner, dind]`).
  - `subPath: daemon.json` is **mandatory** — without it the entire ConfigMap mount would replace `/etc/docker/` and clobber other dockerd state.

### Quickstart ([quickstart.md](./quickstart.md))

Operator playbook (cutover ordering and verification):

#### Pre-flight (before first commit)
1. **Verify sing-box DS health on all three MS-01 nodes**:
   ```
   kubectl -n network get ds sing-box -o wide
   kubectl -n network logs -l app=sing-box --tail=50 | grep -i "auto_redirect"
   ```
   Expect three `READY 3/3`, no error logs about netfilter table conflicts.
2. **Verify in-cluster Service names** (Plan-stage Q1 was field-verified, but re-check at apply time in case namespace drift):
   ```
   kubectl get svc -n development forgejo-http   # expects Port 3000
   kubectl get svc -n nix attic                  # expects Port 8080
   kubectl get svc -n registry zot               # expects Port 5000 (Phase 2 only)
   ```
3. **Verify LAN zot reachability from a talos-ii node**:
   ```
   kubectl debug node/<ms01-a> -it --image=curlimages/curl -- curl -sf http://172.16.80.240:5000/v2/_catalog
   ```
   Expect a non-empty `repositories` list.
4. **Decommission talos-i runner**:
   ```
   # against talos-i kubeconfig (swarm-01 cluster):
   kubectl -n development scale deploy forgejo-runner --replicas=0
   ```
   Verify Pod terminates and runner appears as `offline` in Forgejo Site Administration → Actions → Runners. Do NOT delete the swarm-01 manifests yet — that's a follow-up cleanup PR after Story 1 succeeds.
5. **Mint registration token** (per [contracts/runner-registration.md](./contracts/runner-registration.md)):
   ```
   kubectl -n development exec deploy/forgejo -- forgejo actions generate-runner-token
   ```
   Record token. Token expires in ~7 days; if Story 1 isn't completed within that window, re-mint.

#### Apply (first commit)
6. **Author manifests** in the order shown in "Project Structure" above:
   - `kubernetes/apps/forgejo-runner/namespace.yaml`
   - `kubernetes/apps/forgejo-runner/kustomization.yaml`
   - `kubernetes/apps/forgejo-runner/forgejo-runner/ks.yaml`
   - `kubernetes/apps/forgejo-runner/forgejo-runner/app/kustomization.yaml`
   - `kubernetes/apps/forgejo-runner/forgejo-runner/app/ocirepository.yaml`
   - `kubernetes/apps/forgejo-runner/forgejo-runner/app/helmrelease.yaml`
   - `kubernetes/apps/forgejo-runner/forgejo-runner/app/dockerd-config.yaml` (ConfigMap)
   - `kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml` (SOPS-encrypt before commit)
7. **SOPS-encrypt** the registration-token Secret:
   ```
   sops -e -i kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml
   ```
   **Tripwire** (per project memory `feedback_makejinja_sops.md` and `feedback_sops_cross_repo_cwd.md`): if `cwd` straddles two repos at SOPS time, the wrong `.sops.yaml` recipient may be picked up. Verify: `sops -d kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml | head -5` round-trip MUST decrypt successfully. The presence of `ENC[…]` markers proves encryption, not recipient correctness.
8. **Commit + push** to branch `003-forgejo-runner-talos-ii`:
   ```
   git add kubernetes/apps/forgejo-runner/
   git commit -m "feat(forgejo-runner): DinD on talos-ii, Phase 1 LAN zot mirror"
   git push origin 003-forgejo-runner-talos-ii
   ```
9. **Open + merge PR** (via the repo's standard review flow). Flux reconciles on merge.

#### Verify (post-Flux-reconcile)
10. **Watch reconciliation**:
    ```
    kubectl -n flux-system get kustomization forgejo-runner -w
    kubectl -n forgejo-runner get all
    ```
    Expect: Namespace created → registration Job runs → runner Pod becomes `Running 2/2`.
11. **Pod-level health checks** (matches FR-024 verification gate):
    ```
    kubectl -n forgejo-runner get pod -o wide
    kubectl -n forgejo-runner exec -c dind <runner-pod> -- docker ps     # expect: empty list, no error
    kubectl -n forgejo-runner exec -c dind <runner-pod> -- docker info | grep -i "default address"
    kubectl -n forgejo-runner logs <runner-pod> -c runner --tail=50      # expect: "registered as runner X"
    ```
12. **dockerd bridge subnet verification** (FR-012 / Story 4):
    ```
    kubectl -n forgejo-runner exec -c dind <runner-pod> -- docker network inspect bridge | grep Subnet
    # expect: "Subnet": "10.250.0.0/16"
    ```
13. **Sing-box coexistence** (FR-023 / SC-007 / Story 4):
    ```
    # on the node hosting the runner Pod:
    talosctl -n <node> get nftrules -o yaml | head -60
    # or via debug pod: kubectl debug node/<n> -it --image=alpine/nftables -- nft list ruleset
    ```
    Expect both `inet sing-box` table AND dockerd-managed `nat` / `filter` chains, NO rules in `inet sing-box` table differing from pre-runner snapshot.
14. **Forgejo UI verification**: Site Administration → Actions → Runners shows exactly one online runner named `forgejo-runner-talos-ii` with labels `ubuntu-latest` and `nix-builder`.

#### Smoke test (Story 1)
15. **Dispatch nix-fleet `build-and-push.yaml`** on a non-tagged branch (`workflow_dispatch`).
16. **Monitor jobs**:
    - All 4 parallel jobs (`warm-cache`, `build-systems` matrix, `build-installer-iso`, `build-and-push-k8s-sing-box-oci`) reach `success` (SC-001).
    - `nix build` step inside `nixos/nix:latest` container completes without Go-fetcher failure (SC-002 — the structural fix).
    - Image pulls of `node:20.12-bookworm` and `nixos/nix:latest` show requests in LAN zot's logs (SC-003).
17. **Acceptance gate**: if any of (15)/(16) fails, do NOT proceed to talos-i decommission — debug via `kubectl logs`, sing-box logs, and zot logs.

#### Close (Story 2)
18. **Forgejo UI**: navigate to talos-i runner row → Delete (unregister). The talos-i Pod is already at `--replicas=0` from step 4.
19. **Open follow-up cleanup PR on swarm-01** removing `kubernetes/apps/development/forgejo-runner/` from the talos-i manifest tree (out-of-scope of THIS plan — separate task per spec FR-001 / SC-006).
20. **Land ADR + runbook** (separate task per FR-031 / FR-032):
    - `docs/decisions/talos-ii/0013-forgejo-runner-talos-ii.md`
    - `docs/operations/forgejo-runner.md`
    - `docs/cluster-definition.md` update (add `forgejo-runner` namespace row)
    - `docs/index.md` ToC entries

#### Rollback
- If Story 1 fails: `kubectl -n forgejo-runner scale deploy forgejo-runner --replicas=0`, scale talos-i back to `--replicas=1` against swarm-01 kubeconfig (registration is still there because we did NOT unregister yet — step 18 is post-success). Restore previous runner availability in <2min.
- If reconciliation itself fails (Job error, Pod CrashLoop): suspend the Flux Kustomization (`kubectl -n flux-system patch kustomization forgejo-runner -p '{"spec":{"suspend":true}}' --type=merge`), debug, fix, push, unsuspend.

### Verification checklist (operator-facing, plan-time)

| FR / SC | Check | Command / Where |
|---|---|---|
| FR-001 | No HelmRelease on talos-i after cutover | swarm-01 kubeconfig: `kubectl -n development get hr forgejo-runner` (after step 19) |
| FR-006 / FR-007 | Pod 1/1 Running with two containers | `kubectl -n forgejo-runner get pod` |
| FR-008 | x86_64 image tags | `kubectl -n forgejo-runner get pod -o yaml \| grep image:` (expect `-amd64` suffix) |
| FR-010 | replicaCount=1, capacity=3 | `kubectl -n forgejo-runner get deploy -o yaml \| grep replicas` + Forgejo runner detail page |
| FR-011 | Labels match | Forgejo runner detail page: `ubuntu-latest`, `nix-builder` |
| FR-012 | dockerd bridge `10.250.0.0/16` | step 12 |
| FR-013 | dockerd has NO HTTP_PROXY env | `kubectl -n forgejo-runner get pod -o yaml \| yq '.spec.containers[1].env'` |
| FR-014 | dockerd registry-mirrors flippable | grep ConfigMap content |
| FR-015 | act_runner has HTTP_PROXY env | `kubectl -n forgejo-runner get pod -o yaml \| yq '.spec.containers[0].env'` |
| FR-018 | CONFIG_INSTANCE points cluster-local | decrypt + grep registration-token.sops.yaml |
| FR-019 | TLS on port 2376 | `kubectl -n forgejo-runner exec -c runner <pod> -- env \| grep DOCKER` (expect `DOCKER_HOST=tcp://127.0.0.1:2376`, `DOCKER_TLS_VERIFY=1`) |
| FR-022 | init-config Job ran successfully | `kubectl -n forgejo-runner get jobs` |
| FR-023 / SC-007 | sing-box nftables intact | step 13 |
| FR-026 | No public exposure | `kubectl -n forgejo-runner get svc,httproute` (empty) |
| FR-027 | No tailscale Service | `kubectl -n forgejo-runner get svc -o yaml \| grep tailscale.com/expose` (empty) |
| SC-001 | Workflow first-attempt success | step 16 |
| SC-002 | nix Go-fetcher succeeds | step 16 |
| SC-005 | Zero workflow YAML edits | `nix-fleet` repo `git log` shows no `runs-on` changes |
| SC-006 | talos-i clean | swarm-01: `kubectl -n development get all -l app.kubernetes.io/name=forgejo-runner` (empty after step 19) |
| SC-009 | No public DNS / Cloudflare / tailscale | namespace audit |
| SC-010 | No Talos reboot | `talosctl -n <each-node> dmesg \| tail -20` |

### Agent context update

The repository has no `<!-- SPECKIT START --> / <!-- SPECKIT END -->` markers in any agent context file. No update is performed; the next time an agent context file with those markers is introduced, the convention is to point it at this `plan.md`.

## Phase 2 — Tasks (handled by `/tasks`, not by this command)

`/tasks` will turn the deliverables in this plan into a dependency-ordered task list. The expected ordering (informational only — `/tasks` is the authority):

1. **Pre-flight checks** (Quickstart steps 1–3): sing-box DS healthy, Service names confirmed, LAN zot reachable.
2. **Decommission talos-i runner** (Quickstart step 4): scale to 0, do NOT unregister yet.
3. **Mint registration token** (Quickstart step 5).
4. **Author manifests** (Quickstart step 6) in the file order in "Project Structure".
5. **SOPS-encrypt registration-token Secret** (Quickstart step 7) and round-trip-decrypt to verify recipient correctness.
6. **First commit + push + PR + merge** (Quickstart steps 8–9). Flux reconciles.
7. **Verification probes** (Quickstart steps 10–14): Pod health, dockerd bridge subnet, sing-box coexistence, Forgejo UI presence.
8. **Smoke test Story 1** (Quickstart steps 15–16): dispatch `build-and-push.yaml`, watch all 4 jobs to success.
9. **Acceptance gate** (Quickstart step 17): if any failure, debug; do NOT proceed.
10. **Cutover finalize** (Quickstart steps 18–19): unregister talos-i runner in Forgejo UI, open swarm-01 cleanup PR.
11. **Documentation commit chain** (Quickstart step 20 / FR-031 / FR-032): ADR `0013-forgejo-runner-talos-ii.md`, runbook `forgejo-runner.md`, `cluster-definition.md` update, `index.md` ToC entries.
12. **Phase 2 follow-up** (separately tracked, after spec 002 zot-on-talos-ii reaches stable): flip dockerd `daemon.json` `registry-mirrors` to `zot.registry.svc.cluster.local:5000`, add `dockerd-zot-auth.sops.yaml` Secret + postRenderer patch mounting it at `/root/.docker/config.json`. Single follow-up commit.

### Likely tripwires (per implementer judgment)

- **Wrong namespace label level** — PSA labels SHOULD be `privileged`, not `baseline` or `restricted`. Note that the talos-ii cluster's effective PSA default appears permissive (no existing namespace has explicit PSA labels yet privileged Pods like sing-box DS run successfully) — so missing labels would not necessarily reject pod creation today. Defense-in-depth: still apply all three labels at `privileged` so this namespace's permission model is explicit and survives any future cluster-wide PSA default change. Verifiable post-apply: `kubectl get ns forgejo-runner -o jsonpath='{.metadata.labels}'` shows all three keys at `privileged`.
- **postRenderer JSONPatch path fragility** — the patch indexes containers by position (`/spec/template/spec/containers/0/...`). If wrenix chart 0.8.x reorders containers (e.g. inserts a new sidecar at index 0), the patch silently mounts daemon.json into the wrong container. Verify post-apply: `kubectl -n forgejo-runner get pod -o yaml | yq '.spec.containers[].name'` — expected `[runner, dind]`. If reordered, swap indices in helmrelease.yaml's postRenderers block.
- **`subPath: daemon.json` is mandatory** — without `subPath`, the ConfigMap mount replaces all of `/etc/docker/`, clobbering anything dockerd writes there at runtime. With `subPath`, only the `daemon.json` file is overlaid. Test pre-merge by `helm template` + `yq` extracting the postRenderer-patched Deployment.
- **Token expiry during prolonged debug** — the registration token expires ~7 days after mint. If Story 1 debug stretches beyond that window, the `forgejo-runner-init-config` Job's `generate-config` container fails with `invalid token`. Re-mint per Quickstart step 5 and re-encrypt; the rest of the Pod state survives because the chart's `forgejo-runner-config` Secret already has the persisted credential from any prior successful registration. If no prior registration succeeded, the re-mint is the unblock path.
- **dockerd refusing the bridge subnet on first start** — if dockerd has cached state from a previous Pod (the `emptyDir` is supposed to be fresh per Pod, but a chart upgrade that retains the volume could leak state), the new `bip` value may conflict with existing networks. Mitigation: HelmRelease's `strategy: Recreate` ensures a fresh Pod per upgrade, and `emptyDir` is per-Pod by definition.
- **`network: host` confusion** — common misread is "host = Talos node host network namespace". Reality: "host" means the **Pod's** network namespace, i.e. spawned containers see the same `/etc/resolv.conf` and `/etc/hosts` as the act_runner Pod. This is the desired behavior — it lets build containers resolve `attic.nix.svc.cluster.local` natively via Cilium CoreDNS.
- **NO_PROXY trailing-dot variants** — Go's `net/http/httpproxy` matcher does NOT normalize trailing dots. NO_PROXY must include BOTH `.cluster.local` and `.cluster.local.` (and the same for `.svc.cluster.local`). The attic 2026-04-28 incident in `kubernetes/apps/nix/attic/app/helmrelease.yaml` is the canonical reference.
- **GOPROXY in build container envs** — swarm-01 had `GOPROXY: "https://goproxy.cn,https://proxy.golang.org,direct"` to mitigate GFW-blocked Go module downloads. talos-ii's nix-fleet workflows benefit from the same. Decision in v1: **carry the swarm-01 GOPROXY value verbatim** in `runner.config.file.container.envs` to avoid surprise regression. If observed unnecessary, remove in a follow-up.
- **codeberg.org reachability for OCI chart fetch** — Flux's source-controller fetches the chart `oci://codeberg.org/wrenix/helm-charts/forgejo-runner:0.7.6` directly, NOT through the runner's HTTP_PROXY (different Pod, no proxy env set on source-controller). If codeberg.org is unreachable from the cluster's general egress at apply time, the OCIRepository goes `Failed`. Mitigation if it surfaces: pre-push the chart to LAN zot at `oci://172.16.80.240:5000/charts/forgejo-runner` (one-time `helm push` on the operator workstation), update `ocirepository.yaml` URL, retry. Not pre-emptive in v1; matches swarm-01 reference.
- **`task configure` re-encryption** (per project memory `feedback_makejinja_sops.md`) — running `makejinja` directly bypasses the `encrypt-secrets` step. After any direct `makejinja` run, `task encrypt-secrets` (or `sops -e -i`) all `*.sops.*` before commit. The `task configure` umbrella does both.
- **Phase 2 docker config.json mountPath collision** — `/root/.docker/config.json` mount may collide if the dind image's entrypoint writes there. The official `library/docker:dind` image's entrypoint does NOT write to `/root/.docker/`, but a future bump might. Verify at apply time: `kubectl exec -c dind <pod> -- ls /root/.docker/`. If conflict, switch to `DOCKER_CONFIG=/var/lib/docker-config` env + mount there instead.

## Risks captured + mitigations

(Plan-stage residual risks beyond what's covered in spec Edge Cases.)

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| dockerd nftables chains conflict with sing-box `inet sing-box` table | Low (names are disjoint, verified shape) | High (workflow fails silently with weird egress) | Quickstart step 13: explicit `nft list ruleset` snapshot diff before/after. Spec Story 4 acceptance gate. |
| Layer cache cold-start cost grows over time as `library/*` image set grows | Medium | Low (~30s extra per cold start) | Defer Longhorn PVC to follow-up if observed. Q5 decision. |
| Privileged dind container escape | Medium (CI sandbox by design) | High (host node compromise) | Accepted risk. Mitigation: namespace-scoped privilege via PSA labels (no other workloads share `forgejo-runner` namespace), no Tailscale exposure, no ServiceAccount with cluster-API access. |
| Single-pod 6-job overload causes OOM kills | Low (sized for 3 + queue) | Medium (job retries, partial workflow stall) | FR-021 limits `dind: limits.memory=8Gi`; nix-fleet's 6-job peak is 3-active 3-queued, so memory pressure is bounded by the 3 actives. Future scaling: capacity=6 single pod, then replicas=2. |
| Phase 2 cutover surprises (htpasswd auth, plaintext HTTP) | Medium | Medium | Phase 2 is a separate, smaller, well-scoped follow-up commit. Q6 contract documents the exact mechanism. Rollback = revert one commit. |
| codeberg.org chart fetch fails | Low | Medium (HelmRelease stuck `pending`) | Tripwire above; one-time `helm push` to LAN zot is the unblock. |
| Token expires during prolonged debug | Medium (7-day window) | Low (re-mint is 30s) | Tripwire above; runbook step explicit. |

## What's deferred to tasks.md

- Step-by-step task list with `[ ]` checkboxes
- Per-task ownership / assignee
- Per-task verification commands (Quickstart's verification table is the source — `/tasks` chunks it into per-task gates)
- ADR + runbook authorship (separate sub-task chain per FR-031)
- swarm-01 cleanup PR (separate task on the swarm-01 repo)
- Phase 2 mirror cutover (separate phase, gated on spec 002's stable close)

## Complexity Tracking

(no Constitution violations — table omitted)
