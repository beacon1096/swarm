# Tasks: zot OCI mirror in-cluster on talos-ii (Phase 4b)

**Input**: Design documents from `/home/beacon/swarm/specs/002-zot-on-talos-ii/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md, contracts/zot-config.md
**Target cluster**: `[talos-ii]` only — every absolute path below is rooted at `/home/beacon/swarm/`. There must be no edit under `/home/beacon/swarm-01/` for this feature.

**Tests**: No automated test suite is generated. Validation is performed via the operator probes captured in [`quickstart.md`](./quickstart.md) and the success criteria SC-001..SC-008 in [`spec.md`](./spec.md).

**Organization**: Tasks are grouped by user story so the P1 cutover can ship independently of the P2 tailnet contract verification and the P3 LAN-host decommission.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Maps to user stories from spec.md (US1, US2, US3, US4)
- All file paths are absolute under `/home/beacon/swarm/`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Pre-flight + one-time bootstrap actions that every later phase assumes have run.

- [X] T001 Verify Flux healthy on talos-ii: `flux get all -A | grep -v True` returns no Ready=False rows; `flux get sources oci -A` lists the existing `oci-zot-charts` source healthy.
- [X] T002 Verify default `longhorn` SC (replicaCount=2 per repo convention) and node capacity: `kubectl get sc longhorn` (must show `Provisioner: driver.longhorn.io`, default class); `kubectl -n longhorn-system get nodes.longhorn.io -o wide` (each node `Schedulable: true` with ≥ 600 Gi free). **DEVIATION from plan**: plan/research said `longhorn-r2`, but no such named SC exists in this repo. `kubernetes/apps/storage/longhorn/app/storageclass-replicated-3.yaml`'s comment explicitly says "everything else uses `longhorn` (default class with replicaCount=2)". Use default `longhorn`; do NOT create a named `longhorn-r2`.
- [X] T003 Verify `cilium-l2` LB pool has `172.16.87.51` free: `kubectl get ciliumloadbalancerippool -o yaml` shows `.51` inside an enabled CIDR; `kubectl get svc -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[*].ip}{"\n"}{end}' | sort -u | grep -F 172.16.87.51` returns nothing (IP is unclaimed).
- [X] T004 Verify in-cluster sing-box healthy: `kubectl -n network rollout status deploy/sing-box --timeout=10s` and `kubectl -n network get svc sing-box` (ClusterIP DNS name `sing-box.network.svc.cluster.local` resolves; port 7890 reachable from a debug pod).
- [X] T005 Verify LAN zot at `172.16.80.240:5000` is reachable from operator workstation and exposes the chart we need (or pre-push it): `curl -s 'http://172.16.80.240:5000/v2/charts/zot/tags/list' | jq .`. If `0.1.79` is absent, run `helm pull oci://ghcr.io/project-zot/helm-charts/zot --version 0.1.79 && helm push zot-0.1.79.tgz oci://172.16.80.240:5000/charts --plain-http` and re-verify.
- [X] T006 Capture the zot image digest at apply time and record it for use in `helmrelease.yaml` (FR-009): `crane digest ghcr.io/project-zot/zot-linux-amd64:v2.1.5` (or current latest stable tag). Record digest + tag in a scratch note. Expected format `sha256:…`. If `crane` is unavailable, fall back to `docker pull && docker images --digests`.
- [X] T007 Generate the admin htpasswd line + plaintext password on the operator workstation only (do **not** run inside any pod): `ADMIN_PW=$(pwgen -s 48 1); htpasswd -bnB admin "$ADMIN_PW"` (bcrypt rounds=10). Record both the `admin:$2y$10$…` line and the plaintext for use in T013.
- [X] T008 [P] Create the `registry/` namespace directory tree: `mkdir -p /home/beacon/swarm/kubernetes/apps/registry/zot/app`.

**Checkpoint**: Pre-flight green. Chart on LAN zot. Image digest captured. Credentials generated. Empty directory tree exists.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Author the static manifests and umbrella scaffolding that every user story depends on. These tasks land the in-cluster zot itself; **no Talos host containerd flip happens here** — that's User Story 1.

**CRITICAL**: No user-story phase can begin until T009..T020 complete and Flux reconciles HelmRelease `zot` to Ready=True.

- [X] T009 [P] Create namespace manifest at `/home/beacon/swarm/kubernetes/apps/registry/namespace.yaml` with `apiVersion: v1`, `kind: Namespace`, `metadata.name: registry`. Pattern: clone `/home/beacon/swarm/kubernetes/apps/nix/namespace.yaml`.
- [X] T010 [P] Create namespace-tier kustomization at `/home/beacon/swarm/kubernetes/apps/registry/kustomization.yaml` listing `./namespace.yaml` and `./zot/ks.yaml`. Pattern: clone `/home/beacon/swarm/kubernetes/apps/nix/kustomization.yaml`.
- [X] T011 [P] Create Flux Kustomization at `/home/beacon/swarm/kubernetes/apps/registry/zot/ks.yaml`: `kind: Kustomization` (kustomize.toolkit.fluxcd.io/v1), name `zot`, path `./kubernetes/apps/registry/zot/app`, `targetNamespace: registry`, `prune: true`, `wait: false`, `timeout: 10m`, `postBuild.substituteFrom: cluster-secrets`, no `dependsOn`. Pattern: clone `/home/beacon/swarm/kubernetes/apps/nix/attic/ks.yaml`.
- [X] T012 [P] Create OCIRepository at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/ocirepository.yaml`: `kind: OCIRepository` (source.toolkit.fluxcd.io/v1), name `zot`, namespace `registry`, `url: oci://172.16.80.240:5000/charts/zot`, `ref.tag: 0.1.79`, `insecure: true`, `interval: 1h`. Pattern: clone the OCIRepository in `/home/beacon/swarm/kubernetes/apps/nix/attic/app/`.
- [X] T013 Create SOPS-encrypted Secret at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/secret.sops.yaml` containing `zot-secret` (Opaque) with `stringData.htpasswd` = the bcrypt line from T007 and `stringData.admin-password` = the plaintext from T007 (data-model.md §Secrets). Edit the plaintext file first, then `sops --encrypt --in-place /home/beacon/swarm/kubernetes/apps/registry/zot/app/secret.sops.yaml`. Verify `head -5 secret.sops.yaml` shows `ENC[…]` markers before commit.
- [X] T014 [P] Create PVC at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/pvc.yaml`: name `zot-store`, namespace `registry`, `accessModes: [ReadWriteOnce]`, `storageClassName: longhorn`, `resources.requests.storage: 300Gi`. Pattern: clone `/home/beacon/swarm/kubernetes/apps/nix/attic/app/pvc.yaml`. **DEVIATION (1)**: chart 0.1.79 `templates/statefulset.yaml` always builds a `volumeClaimTemplates` from `pvc.*` values when `persistence: true` and does NOT honor `existingClaim`. Pre-creating a separate PVC would dangle. Pivoted to chart-managed VCT (`pvc.storage: 300Gi`, `pvc.storageClassName: longhorn`); pvc.yaml NOT created. PVC will materialize at runtime as `zot-pvc-zot-0`. **DEVIATION (2)**: storageClassName is `longhorn` (default class, replicaCount=2 per repo convention), NOT `longhorn-r2` as plan/research originally specified — no named `longhorn-r2` SC exists.
- [X] T015 Create HelmRelease at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/helmrelease.yaml`: `kind: HelmRelease` (helm.toolkit.fluxcd.io/v2), name `zot`, chartRef the `zot` OCIRepository, full values per [`data-model.md` §HelmRelease](./data-model.md). Required values: `image.repository: ghcr.io/project-zot/zot-linux-amd64`, `image.tag: v2.1.5` (or current), `image.digest: <T006 digest>`, `replicaCount: 1`, `strategy.type: Recreate`, `service.type: ClusterIP`, `service.port: 5000`, `persistence.enabled: true`, `persistence.existingClaim: zot-store`, `persistence.mountPath: /var/lib/registry`, `mountConfig: true`, `mountSecret: true`, full `configFiles.config.json` per [`contracts/zot-config.md`](./contracts/zot-config.md) (9 registries, NOT including `factory.talos.dev` or `cache.nixos.org`), env `HTTP_PROXY=HTTPS_PROXY=http://sing-box.network.svc.cluster.local:7890`, env `NO_PROXY` MUST include both `cluster.local` and `cluster.local.` trailing-dot variants (Go httpproxy quirk per attic precedent). Comment block above the env section pointing at the attic 2026-04-28 trailing-dot incident. **DEVIATION**: `mountSecret: false` (chart would render a Secret named `zot-secret` colliding with our SOPS Secret of the same name). Mounted via `extraVolumes`+`extraVolumeMounts` instead.
- [X] T016 [P] Create LoadBalancer Service at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/service-lb.yaml`: name `zot-lb`, namespace `registry`, `type: LoadBalancer`, annotation `lbipam.cilium.io/ips: "172.16.87.51"`, selector `app.kubernetes.io/name: zot` + `app.kubernetes.io/instance: zot`, port 5000/TCP. Pattern: clone `/home/beacon/swarm/kubernetes/apps/network/sing-box/app/service-lb.yaml`.
- [X] T017 [P] Create tailscale Service at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/service-tailscale.yaml`: name `zot-tailscale`, namespace `registry`, `type: ClusterIP`, three annotations `tailscale.com/expose: "true"`, `tailscale.com/hostname: "zot"`, `tailscale.com/proxy-class: "proxied"` (third one mandatory per attic Phase 4a lesson — without `proxied` ProxyClass the per-Service ts proxy stays `NeedsLogin` because controlplane.tailscale.com is GFW-blocked from default talos-ii egress). Selector matches the chart Pod labels; port 5000/TCP.
- [X] T018 [P] Create app-tier kustomization at `/home/beacon/swarm/kubernetes/apps/registry/zot/app/kustomization.yaml` with `resources: [secret.sops.yaml, ocirepository.yaml, pvc.yaml, helmrelease.yaml, service-lb.yaml, service-tailscale.yaml]`. **DEVIATION**: `pvc.yaml` removed (see T014 deviation note); resources listed: `secret.sops.yaml, ocirepository.yaml, helmrelease.yaml, service-lb.yaml, service-tailscale.yaml`.
- [X] T019 Cross-check the umbrella Flux loop picks up the new namespace dir: `grep -rn "registry" /home/beacon/swarm/kubernetes/flux/cluster/`. If the umbrella uses an explicit list (not a directory walker), append `./apps/registry`. If it walks `apps/`, no edit needed.
- [X] T020 Sanity-grep that no `swarm-01` strings, no `talos-i` cluster references, and no NodePort-mode Services landed in `/home/beacon/swarm/kubernetes/apps/registry/`: `grep -rEn 'swarm-01|talos-i\b|NodePort' /home/beacon/swarm/kubernetes/apps/registry/`. Expected: zero matches. **NOTE**: 3 hits returned, all inside YAML comments that explicitly scope talos-i wiring as out-of-scope and tracked in the swarm-01 repo. No machine-config refs and no NodePort.
- [X] T021 Commit Phase 2 manifests as a single GPG-signed commit (manifests only — no Talos patch yet). Commit message: `feat(registry): zot OCI mirror on talos-ii (Phase 4b deploy)`. If GPG signing fails (pinentry timeout), STOP and surface the failure — do **not** use `--no-gpg-sign`. Push to remote. **NOTE**: per user instruction, commit landed locally; PUSH DEFERRED for user review.
- [ ] T022 Watch Flux reconcile: `flux reconcile source git flux-system && flux reconcile kustomization zot -n flux-system && flux get hr -n registry zot`. Wait for `HelmRelease zot Ready=True`. Verify: `kubectl -n registry get pvc zot-store` (Bound), `kubectl -n registry get pods` (1 Running 1/1), `kubectl -n registry get svc` (3 services: chart-emitted `zot` ClusterIP, `zot-lb` with EXTERNAL-IP `172.16.87.51`, `zot-tailscale` ClusterIP), and `kubectl -n network get pods | grep ts-zot` (the per-Service tailscale proxy pod `ts-zot-<id>-0` lands in the `network` namespace, **not** `tailscale` — note the `tailscale-operator` HelmRelease's `targetNamespace: network`). DEFERRED until after push.
- [ ] T023 Smoke-test the in-cluster zot before any host containerd flip: anonymous read returns 200 (`curl -s -o /dev/null -w '%{http_code}\n' http://172.16.87.51:5000/v2/`); push without auth returns 401; push with auth from T007 returns 202; cold sync against `mirror.gcr.io/coredns/coredns:1.13.1` returns a valid OCI image manifest. If cold sync fails, check sing-box health and the Pod's `HTTP_PROXY` / `NO_PROXY` env (the trailing-dot variant is the most likely culprit). DEFERRED until after push + reconcile.

**Checkpoint**: In-cluster zot healthy, smoke-tested, but Talos host containerd still pulls from LAN host. Story phases can begin.

---

## Phase 3: User Story 1 — talos-ii containerd pulls via in-cluster zot (Priority: P1) MVP

**Goal**: Flip Talos host containerd's `machine.registries.mirrors` so all 9 upstream registries resolve to the in-cluster zot first, with the LAN host as fallback during transition. No node reboots.

**Independent Test**: Schedule a Pod referencing `mirror.gcr.io/coredns/coredns:1.13.1` (or any uncached image) on a talos-ii node. Pod reaches Running. `kubectl logs -n registry deploy/zot --tail=200 | grep coredns` shows the corresponding GET, confirming the request went through in-cluster zot, not the LAN host.

### Implementation for User Story 1

- [ ] T024 [US1] Edit `/home/beacon/swarm/templates/config/talos/patches/global/machine-registries.yaml.j2` per [`research.md` Q7](./research.md): every existing mirror entry's `endpoints[]` becomes `[http://172.16.87.51:5000, http://172.16.80.240:5000]` (in-cluster first, LAN fallback). Add new mirror entries for `gcr.io`, `registry.k8s.io`, `docker.elastic.co` (same two-endpoint shape). Add new self-referential entry `"172.16.87.51:5000": { endpoints: [http://172.16.87.51:5000] }`. **DO NOT modify** the `factory.talos.dev` entry (out of scope, see Q1) and **DO NOT remove** the existing `"172.16.80.240:5000"` self-referential entry (kept for transition; removed in US3).
- [ ] T025 [US1] Re-render Talos config via the project's umbrella: `cd /home/beacon/swarm && task configure`. **Do not** run `makejinja` directly — that path bypasses `encrypt-secrets` (per `~/.claude/projects/.../memory/MEMORY.md`); if the operator does run makejinja directly, follow it immediately with `task encrypt-secrets` (or `sops -e -i` on each `*.sops.*`) before any commit.
- [ ] T026 [US1] Inspect the rendered diff: `cd /home/beacon/swarm && git diff -- talos/patches/global/machine-registries.yaml`. Verify in-cluster IP added as first endpoint for all 9 upstreams (`docker.io`, `ghcr.io`, `quay.io`, `mirror.gcr.io`, `gcr.io`, `registry.k8s.io`, `code.forgejo.org`, `docker.elastic.co`, `docker.n8n.io`); LAN host preserved as second endpoint; `factory.talos.dev` unchanged; new self-referential entry for `172.16.87.51:5000` present.
- [ ] T027 [US1] Verify no SOPS plaintext leakage from the re-render: `git diff --stat | grep -E '\.sops\.'` — any `*.sops.*` paths in the diff must show ENC[…] markers, not plaintext (per `~/.claude/projects/.../memory/MEMORY.md` makejinja+sops feedback).
- [ ] T028 [US1] Commit the cutover as a separate GPG-signed commit. Message: `feat(talos-ii): cut talos containerd over to in-cluster zot (Phase 4b cutover)`. Push to remote. (If GPG signing fails, STOP and report — do not `--no-gpg-sign`.)
- [ ] T029 [US1] Apply Talos config to node 172.16.87.201 sequentially (not parallel): `cd /home/beacon/swarm && task talos:apply-node IP=172.16.87.201`. The default `--mode=auto` hot-reloads `machine.registries` — no reboot expected (research.md Q2, FR-018, SC-007).
- [ ] T030 [US1] Verify node 172.16.87.201 did **not** reboot: `talosctl --nodes 172.16.87.201 dmesg | tail -50` — expected NO `BOOT`/`Linux version`/`[ 0.000000]` lines. Verify `hosts.toml` updated: `talosctl --nodes 172.16.87.201 read /etc/cri/conf.d/hosts/docker.io/hosts.toml` — expected: server entries reflect `172.16.87.51:5000` first, `172.16.80.240:5000` second.
- [ ] T031 [US1] Apply to node 172.16.87.202 (only after T030 passes): `task talos:apply-node IP=172.16.87.202`; same dmesg + hosts.toml verification.
- [ ] T032 [US1] Apply to node 172.16.87.203 (only after T031 passes): `task talos:apply-node IP=172.16.87.203`; same dmesg + hosts.toml verification.
- [ ] T033 [US1] SC-001 acceptance: `kubectl run sc001 --rm -it --restart=Never --image=mirror.gcr.io/coredns/coredns:1.13.1 -- /bin/sh -c 'echo ok'`. Pod reaches Running. Confirm pull flowed through in-cluster zot: `kubectl logs -n registry deploy/zot --tail=200 | grep coredns` shows the corresponding GET on `/v2/coredns/coredns/manifests/1.13.1`.
- [ ] T034 [US1] SC-006 acceptance (cache hit faster than miss): `kubectl create deploy sc006 --image=docker.io/library/redis:8.0 --replicas=1 && kubectl scale deploy sc006 --replicas=3 && kubectl get pods -l app=sc006 -w`. Pods 2 and 3 land on different nodes than Pod 1 and pull from the in-cluster zot's cache, noticeably faster. `kubectl delete deploy sc006` afterward.
- [ ] T035 [US1] SC-007 acceptance (no unplanned reboots): `talosctl --nodes 172.16.87.201,172.16.87.202,172.16.87.203 dmesg | grep -E 'BOOT|Linux version|\[\s*0\.0+\]'`. Expected: only one boot per node, predating Phase 4b. No new boot entries.
- [ ] T036 [US1] SC-008 acceptance (qualitative throughput parity): `time crane pull --insecure 172.16.80.240:5000/library/alpine:3.20 /tmp/alpine-lan.tar` and `time crane pull --insecure 172.16.87.51:5000/library/alpine:3.20 /tmp/alpine-incluster.tar`. Expected: in-cluster ≤ LAN under comparable conditions.

**Checkpoint**: User Story 1 fully functional. talos-ii image pulls flow through in-cluster zot. LAN host is now a fallback, not the primary. **MVP complete — feature can be demoed at this point.**

---

## Phase 4: User Story 2 — talos-i tailnet consumption contract (Priority: P1, contract-only here)

**Goal**: Verify the tailnet exposure works end-to-end so that talos-i (in a separate repo, **not** modified by this feature) can consume the in-cluster zot via `zot.tail5d550.ts.net:5000` when its own follow-up phase ships. The talos-i `machine.registries.mirrors` change itself is **out of scope** — it lives in the `swarm-01` repo.

**Independent Test**: From any tailnet member (operator workstation, or any existing tailnet node), `curl -s -o /dev/null -w '%{http_code}\n' http://zot.tail5d550.ts.net:5000/v2/` returns 200. The tailscale-operator-spawned `ts-zot-<id>-0` proxy pod is Running and not `NeedsLogin`.

### Verification for User Story 2

- [ ] T037 [US2] Verify the `ts-zot-<id>-0` proxy pod is Running and reached the tailnet (NOT `NeedsLogin`): `kubectl -n network get pods | grep ts-zot` (status Running, restarts ≤ 1); `kubectl -n network logs ts-zot-<id>-0 | grep -Ei 'logged in|magicsock'` shows successful tailnet join.
- [ ] T038 [US2] Verify the tailnet hostname `zot` resolves and routes to the in-cluster zot: from operator workstation (or any tailnet host), `curl -s -o /dev/null -w '%{http_code}\n' http://zot.tail5d550.ts.net:5000/v2/`. Expected: 200. If 404 or hangs: check the Service has all three annotations (T017) including `tailscale.com/proxy-class: proxied`.
- [ ] T039 [US2] Confirm scoping: this feature did **not** add zot manifests to the swarm-01 repo. From the `/home/beacon/swarm` repo only: `find /home/beacon/swarm -path '*swarm-01*' -prune -o -type f -name 'helmrelease.yaml' -print 2>/dev/null | xargs grep -l 'kind: HelmRelease' 2>/dev/null | xargs grep -l '\bzot\b' 2>/dev/null` returns at most one path under `/home/beacon/swarm/kubernetes/apps/registry/zot/`. Document in the runbook (T046) that talos-i wiring is tracked in `swarm-01`'s queue.

**Checkpoint**: Tailnet contract live and reachable. talos-i wiring is unblocked but not performed in this feature.

---

## Phase 5: User Story 3 — LAN host removable from hot path (Priority: P2, decommission)

**Goal**: After ≥ 7 days of observed steady-state operation, drop the LAN host fallback endpoint from the Talos `machine.registries.mirrors` entries. SC-004 then passes for the first time.

**Independent Test**: After this phase commits and applies, `task configure && grep -r '172.16.80.240' /home/beacon/swarm/kubernetes/ /home/beacon/swarm/templates/` returns zero matches. Image pulls on talos-ii continue to succeed against in-cluster zot only.

**WAIT GATE** (per [`research.md` Q7](./research.md), [`spec.md` SC-004](./spec.md)): do not start T040 until ≥ 7 days have elapsed since T032 with the in-cluster zot serving traffic and the LAN host's logs showing zero hot-path requests from talos-ii nodes. Confirm via `ssh root@172.16.80.240 'journalctl -u talos-mirror --since "7 days ago" | grep "172.16.87.20[123]"'` returning empty.

### Implementation for User Story 3

- [ ] T040 [US3] Edit `/home/beacon/swarm/templates/config/talos/patches/global/machine-registries.yaml.j2`: drop the second `http://172.16.80.240:5000` endpoint from each of the 9 mirror entries (`docker.io`, `ghcr.io`, `quay.io`, `mirror.gcr.io`, `gcr.io`, `registry.k8s.io`, `code.forgejo.org`, `docker.elastic.co`, `docker.n8n.io`); remove the self-referential `"172.16.80.240:5000"` block. **DO NOT touch** `factory.talos.dev` (still LAN host — out of scope) and **DO NOT remove** the `"172.16.87.51:5000"` self-referential block.
- [ ] T041 [US3] Re-render: `cd /home/beacon/swarm && task configure`. Verify no SOPS leakage: re-confirm `*.sops.*` markers per T027.
- [ ] T042 [US3] SC-004 acceptance pre-commit: `grep -rEn '172\.16\.80\.240' /home/beacon/swarm/kubernetes/ /home/beacon/swarm/templates/ /home/beacon/swarm/talos/` — expected: only the `factory.talos.dev` mirror entry hit (still allowed; out of scope per Q1). Historical references under `/home/beacon/swarm/docs/` are tolerated. If ANY hit is found in `kubernetes/` or `templates/` outside `factory.talos.dev`, fix before commit.
- [ ] T043 [US3] Commit as a separate GPG-signed commit: `feat(talos-ii): decommission LAN-host zot fallback from machine-registries (Phase 4b close)`. Push.
- [ ] T044 [US3] Apply Talos config sequentially: `task talos:apply-node IP=172.16.87.201` → dmesg verification (no reboot) → `task talos:apply-node IP=172.16.87.202` → verify → `task talos:apply-node IP=172.16.87.203` → verify.
- [ ] T045 [US3] 24-hour burn-in: schedule a representative pull every hour for 24 h (e.g. via a CronJob or by re-running T033 sporadically). Confirm `kubectl logs -n registry deploy/zot --tail=1000 | grep -c 'level=error'` stays low (< 10/h baseline). The LAN host stays online (Out-of-Scope per spec — decommission of the host process itself is a separately tracked phase, not this feature).

**Checkpoint**: LAN host is no longer in the hot path. SC-004 passes for the first time. Phase 4b's *closure* gate is met.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation that Constitution X requires to land in the same commit chain as the implementation. Run `/implement` may interleave these with the user stories above; either way they MUST ship before Phase 4b is considered complete (FR-020).

- [ ] T046 [P] Author ADR at `/home/beacon/swarm/docs/decisions/talos-ii/0012-zot-on-talos-ii.md` with sections Status / Context / Decision / Consequences. Cite [`research.md`](./research.md) for the four chart-vs-bjw-s / bootstrap-Plan-Y / Cilium-LB-IP-`172.16.87.51` / `factory.talos.dev`-exception decisions. Explicitly state that the official chart deviation from the repo's `bjw-s app-template` baseline is scoped to zot (not a new repo-wide baseline). Cross-link `0011-attic-cnpg.md` for the egress-proxy + image-pull-format precedent.
- [ ] T047 [P] Author runbook at `/home/beacon/swarm/docs/operations/zot-restore.md` covering: (a) image-push pipeline including the `skopeo copy --format=oci` workaround for `MANIFEST_INVALID` (attic Phase 4a lesson); (b) chart-upgrade procedure (`helm pull` → `helm push` to LAN zot → bump `OCIRepository.spec.ref.tag` → check upstream release notes for breaking config schema changes); (c) catalog inspection (`curl http://172.16.87.51:5000/v2/_catalog`); (d) DR — how to rebuild the in-cluster zot from a clean PVC, with the LAN zot acting as bootstrap source for the chart.
- [ ] T048 [P] Update `/home/beacon/swarm/docs/index.md`: add a row under "Decisions → talos-ii" pointing at `0012-zot-on-talos-ii.md`; add a row under "Operations" pointing at `zot-restore.md`.
- [ ] T049 [P] Cross-link `/home/beacon/swarm/docs/operations/zot-mirror.md` (the existing LAN-host-zot doc) to the new in-cluster runbook with a single "see also: in-cluster zot at `docs/operations/zot-restore.md`" line near the top. Audit other docs for stale `172.16.80.240` references after Phase 5: `grep -rEn '172\.16\.80\.240' /home/beacon/swarm/docs/`. Where the reference is historical (e.g. inside an ADR's "Consequences" or a Phase-4a runbook), leave as-is. Where the reference is current ops guidance, update to point at `172.16.87.51:5000`.
- [ ] T050 [P] Final commit chain: ensure ADR + runbook + index update land in the same commit chain as the implementation (FR-020). Acceptable shapes: (a) one big commit with manifests + docs together at T021; (b) the docs commit immediately follows the cutover commit at T028; (c) docs land alongside the decommission commit at T043. NOT acceptable: docs ship in a separate PR or week from the manifests/cutover. Final push.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001..T008. T001..T007 can run in parallel against pre-flight checks; T008 (mkdir) is trivially independent.
- **Foundational (Phase 2)**: T009..T023 — depend on Phase 1 complete. Within Phase 2, T009..T012 + T014 + T016..T018 are file-disjoint and parallelizable; T013 must precede commit; T015 depends on T012/T014 having decided names; T019..T023 are sequential (umbrella check → grep → commit → reconcile → smoke).
- **User Story 1 (Phase 3, P1)**: T024..T036 — depends on Phase 2 complete (zot must be Ready before host containerd flips). T024..T028 sequential within the cutover. T029→T030→T031→T032 STRICTLY sequential (one node at a time, never parallel — bad apply on first node leaves remaining two as recovery path; per `quickstart.md` §6 and `plan.md` "tripwires"). T033..T036 sequential acceptance.
- **User Story 2 (Phase 4, P1 contract-only)**: T037..T039 — depends on Phase 2 complete (Tailnet exposure exists from T017+T022). Independent of Phase 3 timing; can run alongside or before US1 cutover.
- **User Story 3 (Phase 5, P2)**: T040..T045 — depends on US1 burn-in (≥ 7 days post-T032). MUST NOT start before the wait gate.
- **Polish (Phase 6)**: T046..T050 — landable any time but commit chain MUST ride with the implementation per FR-020.

### Within Each User Story

- US1: cutover edits (T024..T028) → sequential apply (T029..T032) → acceptance probes (T033..T036).
- US2: pure verification, can run after T022 succeeds.
- US3: gated on observation window; then mechanical apply pattern matching US1.

### Parallel Opportunities

- **Phase 1**: T001..T007 are independent reads of cluster state and can be parallelized (one bash session per check).
- **Phase 2**: T009, T010, T011, T012, T014, T016, T017, T018 are all `[P]` — different files, no inter-dependencies. T015 (helmrelease.yaml) depends only on T006/T012/T014 having pinned names; it can be authored in parallel with T013 (secret) once those are decided.
- **Phase 3**: T029..T032 are STRICTLY SERIAL (Talos apply-per-node). The acceptance probes T033/T034 are independent of each other but share the cluster — interleave-safe.
- **Phase 4**: T037, T038, T039 are independent verifications.
- **Phase 6**: T046, T047, T048, T049 are all `[P]` — different doc files.

---

## Parallel Example: Phase 2 (Foundational)

```bash
# After T013 (secret) is encrypted and ready, the following 8 manifest edits
# can be authored in parallel sessions (different files, no shared state):
Task: "Create namespace.yaml at /home/beacon/swarm/kubernetes/apps/registry/namespace.yaml"
Task: "Create kustomization.yaml at /home/beacon/swarm/kubernetes/apps/registry/kustomization.yaml"
Task: "Create ks.yaml at /home/beacon/swarm/kubernetes/apps/registry/zot/ks.yaml"
Task: "Create ocirepository.yaml at /home/beacon/swarm/kubernetes/apps/registry/zot/app/ocirepository.yaml"
Task: "Create pvc.yaml at /home/beacon/swarm/kubernetes/apps/registry/zot/app/pvc.yaml"
Task: "Create service-lb.yaml at /home/beacon/swarm/kubernetes/apps/registry/zot/app/service-lb.yaml"
Task: "Create service-tailscale.yaml at /home/beacon/swarm/kubernetes/apps/registry/zot/app/service-tailscale.yaml"
Task: "Create app/kustomization.yaml at /home/beacon/swarm/kubernetes/apps/registry/zot/app/kustomization.yaml"
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 (Setup) — T001..T008.
2. Phase 2 (Foundational) — T009..T023.
3. Phase 3 (US1 cutover) — T024..T036.
4. **STOP and VALIDATE**: Phase 4b's *cutover* is achieved. talos-ii pulls through in-cluster zot. LAN host is fallback.
5. Phase 6 docs co-commit (T046..T050) is mandatory per FR-020 — even at MVP shape.

### Incremental Delivery

1. MVP (above) → demoable.
2. Phase 4 (US2 contract verify) — non-blocking on US1, ship anytime.
3. Wait ≥ 7 days, then Phase 5 (US3 decommission) → SC-004 passes.

### Parallel Team Strategy

Single-operator workflow expected. If a second operator is available:

- Operator A: Phase 1 + Phase 2 manifest edits (T001..T020).
- Operator B (parallel): Phase 6 ADR + runbook drafts (T046, T047) — content-complete by the time T020 ships.

---

## Tripwires (per [`plan.md` §"Likely tripwires"](./plan.md))

- **`task configure` vs raw `makejinja`**: only `task configure` runs `encrypt-secrets` after re-render. If T025 / T041 use `makejinja` directly, follow with `task encrypt-secrets` (or `sops -e -i` on each `*.sops.*`) before commit. (Verified at T027.)
- **GPG signing**: T021/T028/T043 commits MUST be GPG-signed. If pinentry times out, STOP and surface the failure — do **NOT** use `--no-gpg-sign`.
- **Talos `--mode=auto` hot-reload**: T029..T032 and T044 are designed around containerd hot-reload (research.md Q2). If dmesg shows a reboot, that is a defect (SC-007) — investigate before applying to the next node.
- **Sequential node apply**: T029→T030→T031→T032 and T044 sequential; never `for IP in 201 202 203; do task talos:apply-node IP=…; done` in parallel. A bad apply on node 201 caught early leaves 202/203 as recovery path.
- **`tailscale.com/proxy-class: proxied`**: missing in T017 → `ts-zot-<id>-0` stays `NeedsLogin` indefinitely (attic Phase 4a lesson). All three annotations are mandatory.
- **`NO_PROXY` trailing-dot variants**: T015 must include both `cluster.local` and `cluster.local.` — Go's `net/http/httpproxy` doesn't normalize the trailing dot (attic 2026-04-28 incident). Without the trailing dot, in-cluster service-name lookups silently route through sing-box and fail.
- **Image-format MANIFEST_INVALID at first apply**: T022 may hit `MANIFEST_INVALID` if the upstream zot image envelope isn't OCI. Workaround documented in `quickstart.md` step 1: `skopeo copy --format=oci` to LAN zot, re-pin digest. T047 captures the recipe in the runbook.
- **Chart values: mapping vs raw JSON string for `configFiles.config.json`**: prefer mapping form so the chart's JSON schema validates. `onDemand` MUST be a bool not a string — mapping form catches that.
- **`zot-lb` selector match**: T016 must match the chart's actual Pod labels (`app.kubernetes.io/name=zot, app.kubernetes.io/instance=zot`). Verify `kubectl -n registry get pods --show-labels` after T022 and adjust the LB selector if the chart minor version drifted.
- **`ts-zot` lands in `network` namespace, not `tailscale`**: the tailscale-operator HelmRelease's `targetNamespace: network` (T022 verification). Looking under `tailscale` ns will find nothing.
- **`factory.talos.dev` is sacred**: T024 and T040 MUST NOT touch the `factory.talos.dev` mirror entry. Out of scope (research.md Q1). `cache.nixos.org` is similarly absent from `extensions.sync` (handled directly via sing-box).
- **`kubectl exec -i` truncates large stdin** (per `~/.claude/projects/.../memory/MEMORY.md`): if any task-side procedure pipes > ~100 MB into the zot pod (image push, blob restore), use `kubectl cp` + `--filename` instead of `exec -i <`.
- **Chart upgrade may break config schema**: T047's chart-upgrade procedure must check upstream zot release notes — `extensions.sync.registries[].content[]` schema has shifted in past versions.

---

## Notes

- `[P]` tasks = different files, no dependencies on incomplete tasks.
- `[USx]` label maps tasks to spec.md user stories for traceability.
- All paths absolute under `/home/beacon/swarm/` — there is no edit under `/home/beacon/swarm-01/` for this feature.
- US4 from `spec.md` ("operator updates upstream list without reboots") is implicitly validated by the day-2 procedures captured in T047 (the runbook's "Add a new upstream" section); no dedicated phase needed since the architecture from US1 already satisfies it.
- Commit after each phase or logical group. Stop at any checkpoint to validate independently.
- Avoid: editing the same file from parallel `[P]` tasks (none of the `[P]` markers above pair on the same file by design).
