---
description: "Task list for Forgejo Actions runner on talos-ii (DinD)"
---

# Tasks: Forgejo Actions runner on talos-ii (DinD)

**Input**: Design documents from `/home/beacon/swarm/specs/003-forgejo-runner-talos-ii/`
**Prerequisites**: plan.md, spec.md (research.md / data-model.md / quickstart.md / contracts/ are referenced inline by plan.md)
**Target cluster**: `[talos-ii]` only — every absolute path below is rooted at `/home/beacon/swarm/`. There must be no edit under `/home/beacon/swarm-01/` for this feature; the swarm-01 cleanup is a separately tracked PR (see Deferred section).

**Tests**: No automated test suite is generated. Validation is via the operator probes captured in [`plan.md` §Quickstart](./plan.md) and the verification checklist table at `plan.md` lines 346-371. Acceptance gates SC-001..SC-010 in [`spec.md`](./spec.md).

**Organization**: Tasks are grouped by phase (Pre-flight → Author → Encrypt+commit → Verify → Smoke test → Cutover → Documentation). Story labels `[US1]` / `[US2]` / `[US3]` mark the phase tasks that close out spec user stories.

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with the previous task (different files, no dependency on incomplete tasks).
- **[Story]**: maps to spec.md user stories (US1 = workflow runs end-to-end, US2 = talos-i cutover, US3 = build-container egress shape).
- All file paths are absolute under `/home/beacon/swarm/`.
- `[depends on T###]` is added for non-adjacent dependencies.

---

## Phase 0 — Pre-flight

**Purpose**: prove the cluster preconditions hold before authoring any manifest. Every check is read-only against running infrastructure; no edits in this phase except step T004 (talos-i scale-to-0, against the swarm-01 kubeconfig) and step T005 (token mint, in-memory). **The talos-i runner is scaled to 0 here but NOT unregistered yet — unregistration happens in Phase 5 only after Story 1 succeeds.**

- [ ] T001 Verify sing-box DaemonSet healthy on all three MS-01 nodes: `kubectl -n network get ds sing-box -o wide` shows `READY 3/3 UP-TO-DATE 3 AVAILABLE 3`; `kubectl -n network logs -l app=sing-box --tail=50 | grep -iE "auto_redirect|error"` shows auto_redirect lines and zero errors. This is the egress gateway the runner consumes (ADR shared/0004 Phase 2).
- [ ] T002 [P] Re-verify in-cluster Service names against the actual HelmReleases (Plan-stage Q1 found `forgejo-http`, `attic.nix`, `zot.registry` — re-confirm in case of namespace drift): `kubectl get svc -n development forgejo-http` (Port 3000), `kubectl get svc -n nix attic` (Port 8080), `kubectl get svc -n registry zot` (Port 5000 — for Phase 2 only). If any name differs, update `helmrelease.yaml` (T011) and `registration-token.sops.yaml` (T013) before commit.
- [ ] T003 [P] Verify LAN zot at `172.16.80.240:5000` is reachable from a talos-ii node: `kubectl debug node/<ms01-a> -it --image=curlimages/curl -- curl -sf http://172.16.80.240:5000/v2/_catalog | jq .repositories | head`. Expect a non-empty list including `library/docker`. Required for the Phase 1 dockerd registry mirror.
- [ ] T004 Scale the talos-i runner Deployment to 0 (against the **swarm-01 kubeconfig**, NOT talos-ii): `KUBECONFIG=<swarm-01-kubeconfig> kubectl -n development scale deploy forgejo-runner --replicas=0 && KUBECONFIG=<swarm-01-kubeconfig> kubectl -n development rollout status deploy forgejo-runner --timeout=2m`. Verify the runner appears `offline` in Forgejo Site Administration → Actions → Runners. **DO NOT delete the swarm-01 manifests** — that follow-up cleanup PR is hand-off out of scope per FR-001 / SC-006. **DO NOT unregister yet** — keeping the registration intact is the rollback path (see plan.md §Rollback).
- [ ] T005 Mint a fresh runner registration token from Forgejo (per [`plan.md` §Quickstart step 5](./plan.md) and contracts/runner-registration.md): `kubectl -n development exec deploy/forgejo -- forgejo actions generate-runner-token`. Record the token + the `CONFIG_INSTANCE` value `http://forgejo-http.development.svc.cluster.local:3000` + the `CONFIG_NAME` value `forgejo-runner-talos-ii` in a shell variable (do **not** write to a tracked file). **Tripwire**: token expires ~7 days; if the rest of this task list stretches past that window, re-mint and re-encrypt T013.

**Checkpoint**: cluster preconditions confirmed; talos-i Pod scaled to 0 (registration still alive); fresh registration token in operator's hand. Authoring can begin.

---

## Phase 1 — Author manifests

**Purpose**: write all eight files under `kubernetes/apps/forgejo-runner/` in dependency order. No commit yet — Phase 2 handles SOPS encryption and commit. Pattern reference: `kubernetes/apps/registry/zot/` (Spec 002) for the namespace+app double-nesting; `kubernetes/apps/nix/attic/` (Spec 001) for the bjw-s helmrelease shape (note: forgejo-runner uses the **wrenix** chart, not bjw-s, so the helmrelease values block is wrenix-shape).

- [ ] T006 Create the namespace dir: `mkdir -p /home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/app`.
- [ ] T007 [P] Create the Namespace at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/namespace.yaml`: `apiVersion: v1`, `kind: Namespace`, `metadata.name: forgejo-runner`, three labels `pod-security.kubernetes.io/enforce: privileged`, `pod-security.kubernetes.io/audit: privileged`, `pod-security.kubernetes.io/warn: privileged`, plus annotation `kustomize.toolkit.fluxcd.io/prune: disabled` per repo convention. Pattern: clone `/home/beacon/swarm/kubernetes/apps/registry/namespace.yaml`. **Tripwire (per plan.md line 395)**: PSA labels SHOULD all three be at `privileged`; the talos-ii cluster's effective PSA default appears permissive today, but defense-in-depth requires explicit labels so this namespace's permission model survives any future cluster-wide PSA default change. Verify post-apply: `kubectl get ns forgejo-runner -o jsonpath='{.metadata.labels}'` shows all three keys at `privileged`.
- [ ] T008 [P] Create the namespace-tier kustomization at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/kustomization.yaml`: kustomize.config.k8s.io/v1beta1, `resources: [./namespace.yaml, ./forgejo-runner/ks.yaml]`. Pattern: clone `/home/beacon/swarm/kubernetes/apps/registry/kustomization.yaml`.
- [ ] T009 [P] Create the Flux Kustomization at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/ks.yaml`: kustomize.toolkit.fluxcd.io/v1, name `forgejo-runner`, `path: ./kubernetes/apps/forgejo-runner/forgejo-runner/app`, `targetNamespace: forgejo-runner`, `prune: true`, `wait: false`, `timeout: 10m`, `interval: 1h`, `postBuild.substituteFrom: [{name: cluster-secrets, kind: Secret}]`, **no `dependsOn`** (Flux retries until the Namespace appears). Pattern: clone `/home/beacon/swarm/kubernetes/apps/registry/zot/ks.yaml`.
- [ ] T010 [P] Create the OCIRepository at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/app/ocirepository.yaml`: source.toolkit.fluxcd.io/v1, name `forgejo-runner`, namespace `forgejo-runner`, `url: oci://codeberg.org/wrenix/helm-charts/forgejo-runner`, `ref.tag: 0.7.6`, `interval: 1h`. **Note**: this pulls **directly from codeberg.org**, NOT from LAN zot — Flux source-controller has its own egress and the chart is not pre-pushed to LAN zot. **Tripwire (per plan.md line 403)**: codeberg.org chart fetch happens through Flux source-controller's general egress, NOT through sing-box (no proxy env on source-controller pod). If unreachable at apply time the OCIRepository goes `Failed`; unblock = one-time `helm push` to LAN zot at `oci://172.16.80.240:5000/charts/forgejo-runner` and update this URL.
- [ ] T011 Create the HelmRelease at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/app/helmrelease.yaml`: helm.toolkit.fluxcd.io/v2, name `forgejo-runner`, `chartRef.{kind: OCIRepository, name: forgejo-runner}`, full values per [`plan.md` §Phase 1 Entities — HelmRelease](./plan.md). Required values:
  - `knownLastVersion: true` (chart enforcement)
  - `replicaCount: 1`, `strategy.type: Recreate`
  - `image.{registry: code.forgejo.org, repository: forgejo/runner, tag: 12.7.3}` — **NOTE**: swarm-01 pinned `12.7.3-amd64`, but that suffix doesn't exist on `code.forgejo.org` (verified at T003 time: 404). The non-suffixed tag `12.7.3` is a multi-arch manifest list which resolves to amd64 on x86_64 nodes automatically. Same correctness, simpler pin.
  - `dind.image.{registry: 172.16.80.240:5000, repository: library/docker, tag: 29.2.1-dind}` — same `-amd64`-suffix fix as above. Docker Hub publishes `29.2.1-dind`, `29.2.1-dind-rootless`, `29.2.1-dind-alpine3.23` but NOT `29.2.1-dind-amd64`. Use the multi-arch manifest. (Phase 1 LAN zot pull-through; Phase 2 flips to `zot.registry.svc.cluster.local:5000`)
  - `kubectl.image` chart default `docker.io/alpine/kubectl:1.35.3` (Talos `machine-registries` proxies docker.io through LAN zot)
  - `runner.config.create: true`, `runner.config.existingInitSecret: forgejo-runner-secret`
  - `runner.config.file.runner.{capacity: 3, timeout: 12h, labels: ["ubuntu-latest:docker://node:20.12-bookworm", "nix-builder:docker://nixos/nix:latest"]}`
  - `runner.config.file.container.{network: host, valid_volumes: [], options: "-v /workspace", privileged: false}`
  - `runner.config.file.container.envs.{HTTP_PROXY, HTTPS_PROXY, http_proxy, https_proxy}` = `http://sing-box.network.svc.cluster.local:7890`
  - `runner.config.file.container.envs.{NO_PROXY, no_proxy}` = `.beaco.works,.beacoworks.xyz,.svc,.svc.cluster.local,.svc.cluster.local.,.cluster.local,.cluster.local.,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,localhost,127.0.0.1` — **both dotted AND trailing-dot variants** of `.cluster.local` and `.svc.cluster.local` (canonical: attic 2026-04-28 incident; plan.md line 401)
  - `runner.config.file.container.envs.GOPROXY` = `https://goproxy.cn,https://proxy.golang.org,direct` — **carry verbatim from swarm-01** per plan.md line 402 (drop `goproxy.cn` middle hop is a deferred experiment, NOT in v1)
  - `dind.resources.{requests: {cpu: 500m, memory: 2Gi}, limits: {cpu: 8, memory: 8Gi}}` per FR-021
  - `resources.{requests: {cpu: 100m, memory: 256Mi}, limits: {cpu: 2, memory: 512Mi}}` (top-level applies to runner container per FR-021)
  - `securityContext.privileged: true` (chart default — both runner and dind inherit; runner-hardening deferred per research Q4)
  - `postRenderers[0].kustomize.patches[]`: three JSONPatch operations per [`plan.md` lines 209-237](./plan.md):
    - patch `containers/0/env/-` (runner) adding `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` — chart's `runner.config.file.container.envs` only sets env on **spawned build containers**, NOT on act_runner itself
    - patch `containers/1/volumeMounts/-` (dind) adding `dockerd-config` mount at `/etc/docker/daemon.json` with `subPath: daemon.json`
    - patch `volumes/-` adding the `dockerd-config` volume referencing ConfigMap `forgejo-runner-dockerd-config`
  - **Tripwire (per plan.md line 396)**: postRenderer container index `[0]=runner, [1]=dind` per chart 0.7.6 `templates/deployment.yaml`; if a future bump reorders containers, the daemon.json mount lands in the wrong container silently. Verify post-apply: `kubectl -n forgejo-runner get pod -o yaml | yq '.spec.containers[].name'` returns `[runner, dind]`.
  - **Tripwire (per plan.md line 397)**: `subPath: daemon.json` is **mandatory** — without it the entire ConfigMap mount replaces all of `/etc/docker/`, clobbering anything dockerd writes there at runtime.
- [ ] T012 [P] Create the dockerd ConfigMap at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/app/dockerd-config.yaml`: `apiVersion: v1`, `kind: ConfigMap`, `metadata.{name: forgejo-runner-dockerd-config, namespace: forgejo-runner}`, `data.daemon.json` containing the Phase 1 dockerd config per [`plan.md` lines 178-185](./plan.md):
  ```json
  {
    "registry-mirrors": ["http://172.16.80.240:5000"],
    "insecure-registries": ["172.16.80.240:5000"],
    "bip": "10.250.0.1/16"
  }
  ```
  **Tripwire (per plan.md line 399)**: dockerd may refuse the bridge subnet on first start if a previous Pod's `emptyDir` somehow leaked state with a different `bip`. Mitigation already in place: HelmRelease `strategy: Recreate` (T011) ensures fresh Pod per upgrade and `emptyDir` is per-Pod by definition.
- [ ] T013 [P] Create the SOPS Secret stub at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml` (plaintext form before encryption — Phase 2 encrypts in place): `apiVersion: v1`, `kind: Secret`, `metadata.{name: forgejo-runner-secret, namespace: forgejo-runner}`, `type: Opaque`, `stringData.CONFIG_TOKEN` = the token from T005, `stringData.CONFIG_INSTANCE` = `http://forgejo-http.development.svc.cluster.local:3000`, `stringData.CONFIG_NAME` = `forgejo-runner-talos-ii`. **Tripwire**: file is plaintext at this point — DO NOT commit yet (Phase 2 SOPS-encrypts before commit). The `.sops.yaml` regex in repo root already covers `kubernetes/.*\.sops\.yaml` for recipient resolution.
- [ ] T014 Create the app-tier kustomization at `/home/beacon/swarm/kubernetes/apps/forgejo-runner/forgejo-runner/app/kustomization.yaml` listing under `resources:` in this order: `./registration-token.sops.yaml`, `./ocirepository.yaml`, `./dockerd-config.yaml`, `./helmrelease.yaml`. Pattern: clone `/home/beacon/swarm/kubernetes/apps/registry/zot/app/kustomization.yaml`.
- [ ] T015 Cross-check the umbrella Flux loop picks up the new namespace dir: `grep -rn "forgejo-runner\|apps/" /home/beacon/swarm/kubernetes/flux/cluster/`. If the umbrella uses an explicit list (not a directory walker), append `./apps/forgejo-runner`. If it walks `apps/`, no edit needed (matches Spec 002 / T019 outcome).
- [ ] T016 Sanity-grep that no `swarm-01` strings, no `talos-i` cluster references, no `tailscale.com/expose` annotations, and no NodePort-mode Services landed in `/home/beacon/swarm/kubernetes/apps/forgejo-runner/`: `grep -rEn 'swarm-01|talos-i\b|NodePort|tailscale\.com/(expose|hostname|proxy-class)' /home/beacon/swarm/kubernetes/apps/forgejo-runner/`. Expected: zero matches (FR-001, FR-026, FR-027). Inline YAML comments referencing swarm-01 as historical context are tolerated only if explicit.

**Checkpoint**: all eight files written; registration token still plaintext; nothing committed.

---

## Phase 2 — Encrypt + commit

**Purpose**: SOPS-encrypt the registration token, prove recipient correctness via round-trip decrypt, and ship the manifests as one PR. Flux reconciles automatically on merge to main.

- [ ] T017 SOPS-encrypt the registration token in place: `cd /home/beacon/swarm && sops -e -i kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml`. **Tripwire (per project memory `feedback_sops_cross_repo_cwd.md` and plan.md line 288)**: if `cwd` straddles two repos at SOPS time, the wrong `.sops.yaml` recipient may be picked up. The presence of `ENC[…]` markers proves encryption, NOT recipient correctness.
- [ ] T018 Round-trip decrypt verification (the only check that proves recipient correctness): `cd /home/beacon/swarm && sops -d kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml | head -10`. Expect plaintext keys `CONFIG_TOKEN`, `CONFIG_INSTANCE`, `CONFIG_NAME` to decrypt back. If decrypt fails, re-run T017 from inside `/home/beacon/swarm` (NOT `/home/beacon/swarm-01`) to ensure the swarm cluster age recipient (`age19w3svwspecedu893ges7te9qc5qgj3r5tykpkqrl43f90ndlvg4qant4ej`) is the one used. **Tripwire (per plan.md line 404 / project memory `feedback_makejinja_sops.md`)**: `task configure` re-encrypt step is the canonical umbrella; if you ran `makejinja` directly anywhere along the way, follow with `task encrypt-secrets` (or `sops -e -i` per file) before commit.
- [ ] T019 [depends on T018] Final pre-commit grep for plaintext leakage: `git diff --staged --stat | grep -E '\.sops\.'` — any `*.sops.*` paths must show ENC[…] markers when inspected (`git diff --staged kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml | head -30`). If any plaintext token, password, or PEM appears, STOP and re-run T017.
- [ ] T020 Stage + commit Phase 1+2 manifests as one GPG-signed commit: `cd /home/beacon/swarm && git add kubernetes/apps/forgejo-runner/ && git commit -m "feat(forgejo-runner): DinD on talos-ii, Phase 1 LAN zot mirror"`. If GPG signing fails (pinentry timeout), STOP and surface the failure — do NOT use `--no-gpg-sign`.
- [ ] T021 [depends on T020] Push branch to remote: `cd /home/beacon/swarm && git push origin 003-forgejo-runner-talos-ii`. Open PR via `gh pr create` (or the repo's standard review flow). Title: `feat(forgejo-runner): DinD on talos-ii, Phase 1 LAN zot mirror`. Body cites spec.md / plan.md.
- [ ] T022 [depends on T021] Merge the PR (after review). Flux reconciles automatically on merge to main. Note the merge SHA for cross-reference in the ADR (Phase 6).

**Checkpoint**: PR merged, branch is now reflected on main, Flux is reconciling.

---

## Phase 3 — Verify post-Flux-reconcile

**Purpose**: walk the verification checklist table at [`plan.md` lines 346-371](./plan.md). Each task is one row. **Acceptance gate**: all 13 rows must be green before Phase 4. If any check fails, debug per [`plan.md` §Rollback](./plan.md) (suspend Flux Kustomization, fix, push, unsuspend) — do NOT proceed to smoke test.

- [ ] T023 Watch reconciliation: `kubectl -n flux-system get kustomization forgejo-runner -w`. Expect `READY=True`. In parallel: `kubectl -n forgejo-runner get all` shows Namespace → registration Job runs → runner Pod becomes `Running 2/2`.
- [ ] T024 [P] FR-006 / FR-007 — Pod 1/1 Running with **two** containers (runner + dind): `kubectl -n forgejo-runner get pod` shows `READY 2/2 STATUS Running`; `kubectl -n forgejo-runner get pod -o yaml | yq '.items[0].spec.containers[].name'` returns `[runner, dind]` (postRenderer index sanity per T011 tripwire).
- [ ] T025 [P] FR-008 — x86_64 image tags: `kubectl -n forgejo-runner get pod -o yaml | grep 'image:'` — every image line MUST end in `-amd64` for runner + dind (chart default `kubectl` image at `1.35.3` is amd64-default; that's acceptable).
- [ ] T026 [P] FR-022 — registration Job ran successfully: `kubectl -n forgejo-runner get jobs` shows `forgejo-runner-init-config` with `COMPLETIONS 1/1`. `kubectl -n forgejo-runner logs job/forgejo-runner-init-config -c generate-config | grep -i "registered"` shows successful registration. `kubectl -n forgejo-runner get secret forgejo-runner-config -o yaml` exists with persisted credential data.
- [ ] T027 FR-019 — TLS on port 2376 (chart default, swarm-01 plaintext-2375 override explicitly rejected per spec): `kubectl -n forgejo-runner exec -c runner <runner-pod> -- env | grep -E 'DOCKER_(HOST|TLS|CERT)'` shows `DOCKER_HOST=tcp://127.0.0.1:2376`, `DOCKER_TLS_VERIFY=1`, `DOCKER_CERT_PATH=/certs/client`.
- [ ] T028 [P] dockerd has zero containers and no errors: `kubectl -n forgejo-runner exec -c dind <runner-pod> -- docker ps` returns empty list, exit 0. `kubectl -n forgejo-runner logs <runner-pod> -c dind --tail=50 | grep -iE "error|fatal"` returns nothing concerning (a single `level=warning` about `/etc/docker/daemon.json` overlay is acceptable).
- [ ] T029 [P] FR-012 — dockerd bridge subnet `10.250.0.0/16` (NOT default `172.17.0.0/16` colliding with Tailscale umbrella): `kubectl -n forgejo-runner exec -c dind <runner-pod> -- docker network inspect bridge | jq '.[0].IPAM.Config[0].Subnet'` returns `"10.250.0.0/16"`.
- [ ] T030 [P] FR-013 — dockerd has NO HTTP_PROXY / HTTPS_PROXY env: `kubectl -n forgejo-runner get pod -o yaml | yq '.items[0].spec.containers[1].env[] | select(.name | test("(?i)proxy"))'` returns empty. (Mirror handles upstream egress; pushing dockerd's TLS handshakes through sing-box would re-enter the auto_redirect intercept loop.)
- [ ] T031 [P] FR-015 — act_runner HAS HTTP_PROXY / HTTPS_PROXY / NO_PROXY env (added by postRenderer patch — chart's `container.envs` only affects spawned build containers, not the runner Pod): `kubectl -n forgejo-runner get pod -o yaml | yq '.items[0].spec.containers[0].env[] | select(.name | test("(?i)proxy"))'` shows all three with sing-box ClusterDNS values. Verify NO_PROXY contains both `.cluster.local` AND `.cluster.local.` (trailing-dot variant per plan.md line 401).
- [ ] T032 act_runner is registered with Forgejo (FR-005, FR-018): `kubectl -n forgejo-runner logs <runner-pod> -c runner --tail=100 | grep -iE "registered as runner|listening for tasks"`. **Tripwire (per plan.md line 398)**: token expiry — if registration fails with `invalid token`, the ~7-day window from T005 has elapsed; re-mint and re-encrypt T013, then push a one-line bump.
- [ ] T033 [US3] FR-023 / SC-007 — sing-box nftables state intact (canonical Story 4 acceptance gate): on the node hosting the runner Pod, `talosctl -n <node-IP> get nftrules -o yaml | head -100` (or via debug pod: `kubectl debug node/<n> -it --image=alpine/nftables -- nft list ruleset`). Expect: (a) `inet sing-box` table identical to pre-runner snapshot (no new chains, no rule changes, no fwmark drift from `0x2023` / `0x2024`); (b) iptables-nft `nat` and `filter` tables NOW show dockerd-managed `DOCKER`, `DOCKER-USER`, `DOCKER-FORWARD` chains (added by dockerd start). Disjoint by design — names don't collide.
- [ ] T034 [US3] FR-024 — DinD-internal traffic on `10.250.0.0/16` is NOT TUN-intercepted (subnet is in sing-box `route_exclude_address` covering `10.0.0.0/8`): from inside the runner Pod, `kubectl -n forgejo-runner exec -c dind <runner-pod> -- ip route show 10.250.0.0/16` shows `dev docker0`. A test container's TCP between act_runner ↔ dockerd ↔ build container traverses docker0 directly, NOT the host TUN. Spot-check during smoke test (T040): no sing-box log entries for `10.250.*.*` destinations.
- [ ] T035 FR-018 — `CONFIG_INSTANCE` points cluster-local: `kubectl -n forgejo-runner get secret forgejo-runner-secret -o jsonpath='{.data.CONFIG_INSTANCE}' | base64 -d` returns `http://forgejo-http.development.svc.cluster.local:3000`. **Tripwire (per plan.md Q8)**: act_runner's log-stream back to Forgejo MUST go direct (NO_PROXY exempts `.svc.cluster.local`), NOT round-trip through sing-box. Spot-check during smoke test: `kubectl -n network logs deploy/sing-box --tail=200 | grep forgejo-http.development.svc` returns NOTHING.
- [ ] T036 [P] FR-026 / SC-009 — no public exposure: `kubectl -n forgejo-runner get svc,httproute,gateway 2>/dev/null` returns no resources. `kubectl -n forgejo-runner get pod -o yaml | grep -i 'tailscale\|cloudflare'` returns nothing.
- [ ] T037 [P] FR-027 — no tailnet exposure: `kubectl -n forgejo-runner get svc -o yaml | grep -E 'tailscale\.com/(expose|hostname|proxy-class)' || echo "ok: no tailscale annotations"`. Expect the `ok` line. (Per spec FR-017 the three swarm-01 ExternalName + Tailscale-egress Services are explicitly NOT carried across.)
- [ ] T038 SC-010 — no unplanned Talos node reboots during this phase: `for n in 172.16.87.201 172.16.87.202 172.16.87.203; do echo "=== $n ==="; talosctl -n $n dmesg | tail -20; done`. Expect: only the pre-existing boot lines, no new `[ 0.000000]` / `Linux version` entries since Phase 0.
- [ ] T039 Forgejo UI verification: Site Administration → Actions → Runners shows exactly **two** runner entries (during the cutover window): `forgejo-runner-talos-ii` ONLINE with labels `ubuntu-latest` + `nix-builder` (NEW, this deployment); plus `forgejo-runner` (the talos-i one) OFFLINE (scaled to 0 in T004, registration still alive). The talos-ii runner's labels match exactly the talos-i runner's labels per FR-011 / SC-005 (zero workflow YAML edits required in `nix-fleet`).

**Checkpoint**: all 13 verification rows green; Pod healthy; runner registered + online; sing-box undisturbed; talos-i runner offline-but-still-registered (intentional rollback path).

---

## Phase 4 — Smoke test (User Story 1)

**Purpose**: prove SC-001 + SC-002 — the structural fix to the original CI failure that triggered all of today's work. Dispatch `nix-fleet`'s `build-and-push.yaml` and watch all four parallel jobs to success.

- [ ] T040 [US1] Dispatch `nix-fleet`'s `build-and-push.yaml` workflow on a non-tagged branch via `workflow_dispatch`: navigate to `nix-fleet` Forgejo repo → Actions → `build-and-push.yaml` → Run workflow on default branch. (Or via API: `curl -X POST -H "Authorization: token <PAT>" "<forgejo-url>/api/v1/repos/<owner>/nix-fleet/actions/workflows/build-and-push.yaml/dispatches" -d '{"ref":"main"}'`.) Record the run ID for log cross-reference.
- [ ] T041 [US1] [depends on T040] Watch all 4 parallel jobs reach `success` end-to-end. Expected jobs: `warm-cache`, `build-systems` (matrix x4), `build-installer-iso`, `build-and-push-k8s-sing-box-oci`. Each must show "Picked up by runner forgejo-runner-talos-ii" in the early log lines (NOT the talos-i runner — talos-i is scaled to 0 from T004 and would not pick up anyway). **Acceptance gate (SC-001)**: every job reaches `success` on first attempt with no manual re-runs.
- [ ] T042 [US1] [depends on T041] **Acceptance gate (SC-002)** — the original failure mode does NOT reproduce: inspect the `nix build` step inside `nixos/nix:latest` build containers (`build-systems` matrix jobs) — the nix sandbox Go-fetcher fetches a `sops` Go module dependency and **succeeds**. This proves sing-box `auto_redirect` is doing its job at the kernel level (Go fetcher does NOT honor `HTTPS_PROXY` env, so success here can ONLY be via the auto_redirect kernel path — that's the structural fix). Cross-check: `kubectl -n network logs -l app=sing-box --tail=500 --since=15m | grep -E 'auto_redirect|fwmark.*0x202[34]'` shows the captured connections during the run window.
- [ ] T043 [US1] [depends on T042] [P] SC-003 — image pulls flow through LAN zot mirror: `ssh root@172.16.80.240 'journalctl -u zot --since "30 minutes ago"' | grep -E 'node:20\.12-bookworm|nixos/nix'` shows GET requests for `/v2/library/node/manifests/20.12-bookworm` and `/v2/nixos/nix/manifests/latest` during the workflow window. (Or `curl -s http://172.16.80.240:5000/v2/_catalog | jq` and verify both image repos appear in the catalog.)
- [ ] T044 [US1] [depends on T042] [P] On-tag-push subset of SC-001 (tag-push-only jobs `update-prod-branch`, ISO upload, OCI push to Forgejo registry): defer until a tagged release. Document in the runbook (T053) that tag-push verification is a follow-up after the next `nix-fleet` release.

**Acceptance gate**: T041 + T042 must be green before Phase 5. If either fails, do NOT decommission the talos-i runner — debug per [`plan.md` §Rollback](./plan.md). Rollback path: `kubectl -n forgejo-runner scale deploy forgejo-runner --replicas=0` on talos-ii, then `kubectl -n development scale deploy forgejo-runner --replicas=1` against swarm-01 kubeconfig (registration is still live from T004 — that's why we did NOT unregister yet).

**Checkpoint**: Story 1 acceptance gate passed. talos-ii is the working CI runner. Cutover finalize is unblocked.

---

## Phase 5 — Cutover finalize (User Story 2)

**Purpose**: irreversible decommission of the talos-i runner registration. After this point, talos-i has no Forgejo runner; the only consumer (nix-fleet) is now exclusively on talos-ii.

- [ ] T045 [US2] [depends on T042] Forgejo UI: Site Administration → Actions → Runners → click `forgejo-runner` (the talos-i row, currently OFFLINE) → Delete. The runner registration is invalidated server-side. Re-dispatching `build-and-push.yaml` after this point CANNOT land on talos-i because the registration no longer exists.
- [ ] T046 [US2] [P] Confirm Forgejo UI now shows exactly ONE online runner (SC-004): `forgejo-runner-talos-ii` with labels `ubuntu-latest` + `nix-builder`, status `online`. The talos-i runner is gone from the list.
- [ ] T047 [US2] SC-005 verification — zero workflow YAML edits required: `cd <nix-fleet-clone> && git log --since="$(date -d '7 days ago' --iso-8601)" -- '.forgejo/workflows/' '.gitea/workflows/' '.github/workflows/'` shows no `runs-on` modifications attributable to this migration. (Labels match exactly per FR-011, so no edits needed.)
- [ ] T048 [US2] [P] [depends on T045] **Hand-off note (NOT executed in this task list)**: open a follow-up cleanup PR on the **`swarm-01` repo** (separate working tree at `/home/beacon/swarm-01/`, NOT modified here) removing `kubernetes/apps/development/forgejo-runner/` from the talos-i manifest tree. SC-006 acceptance: `KUBECONFIG=<swarm-01-kubeconfig> kubectl get all,helmreleases,secrets -n forgejo-runner` returns nothing (or, if the manifests still physically exist with Flux suspended, no Pods running). **This is hand-off, not part of this tasks.md execution flow** — out of scope per the per-cluster scoping rule (don't modify swarm-01 from this repo's task list).

**Checkpoint**: Story 2 acceptance gate passed. Single-runner steady state on talos-ii. swarm-01 cleanup queued as follow-up PR on the swarm-01 repo.

---

## Phase 6 — Documentation (Story 3 / FR-031 / FR-032)

**Purpose**: ship the ADR + runbook + cluster-definition update + index ToC entries as a separate commit chain after Story 1 succeeds. Constitution Principle X requires these in the same commit chain as the implementation, but per Phase 4 acceptance gating they ride **after** Story 1 is green so the docs reflect the actual deployed shape (not aspirational).

- [ ] T049 [P] Author the ADR at `/home/beacon/swarm/docs/decisions/talos-ii/0013-forgejo-runner-talos-ii.md` with sections Status / Context / Decision / Consequences. Cross-link **shared/0002** (mesh integration modes — explains the egress baseline), **shared/0003** (talos-i positioning — explains why talos-i is NOT getting a runner), **shared/0004** (cluster egress gateway — explains why sing-box auto_redirect is the structural fix to the nix-Go-fetcher failure), and the local plan.md / spec.md. Pattern: clone shape from `/home/beacon/swarm/docs/decisions/talos-ii/0011-attic-cnpg.md` and `/home/beacon/swarm/docs/decisions/talos-ii/0012-zot-on-talos-ii.md`. Per FR-032: ADR cross-link list is a hard requirement. **NOTE**: this task creates the file; the ADR body is filled in by the operator in this same commit (NOT pre-written here).
- [ ] T050 [P] Author the runbook at `/home/beacon/swarm/docs/operations/forgejo-runner.md` covering: (a) deploy procedure (token mint via `kubectl exec deploy/forgejo`, SOPS encrypt, commit, Flux reconcile, verify); (b) verify procedure (the 13-row checklist from Phase 3 condensed); (c) cutover procedure (Phase 4 + Phase 5); (d) rollback procedure (suspend Flux Kustomization OR scale runner to 0 + scale talos-i back to 1 — the latter only valid PRE-T045); (e) common debug paths (sing-box health, dockerd bridge subnet, NO_PROXY trailing-dot, GOPROXY GFW route); (f) tag-push verification follow-up (T044). **NOTE**: this task creates the file; runbook body is filled in by operator in this same commit.
- [ ] T051 [P] Update `/home/beacon/swarm/docs/cluster-definition.md`: add a `forgejo-runner` namespace row to the talos-ii section (with workload type "CI runner (DinD)", labels, MS-01 single-pod note). Pattern: follow the existing namespace rows for `nix`, `registry`, etc.
- [ ] T052 [P] Update `/home/beacon/swarm/docs/index.md`: add the ADR entry under "Decisions → talos-ii" pointing at `0013-forgejo-runner-talos-ii.md`; add the runbook entry under "Operations" pointing at `forgejo-runner.md`.
- [ ] T053 Final commit chain: stage T049-T052 as ONE GPG-signed commit. Message: `docs(forgejo-runner): ADR 0013 + runbook + cluster-definition + index (Phase 6 close)`. Push. Open PR (or attach to T021's PR if still open). Per FR-031 these MUST land in the same commit chain as the implementation; if T021 already merged, this is the immediate-follow-up commit on main.

**Checkpoint**: Constitution X satisfied. Feature is production-deployed AND documented. Tasks list complete.

---

## Deferred / out-of-scope (NOT in this tasks.md)

These are intentionally NOT in the checkbox list above. They are tracked separately and will land via their own spec / commit chain.

- **Phase 2 mirror cutover (LAN zot → in-cluster zot at `zot.registry.svc.cluster.local:5000`)**: gated on spec `002-zot-on-talos-ii` reaching stable close. Single config-only commit: flip the `daemon.json` `registry-mirrors` URL in the `dockerd-config` ConfigMap, add `dockerd-zot-auth.sops.yaml` Secret (SOPS-encrypted docker `config.json` with admin htpasswd), add a fourth postRenderer patch mounting it at `/root/.docker/config.json` on the dind container. **Tripwire (per plan.md line 405)**: `/root/.docker/config.json` mountPath may collide if a future `library/docker:dind` image's entrypoint writes there. Verify at apply time: `kubectl exec -c dind <pod> -- ls /root/.docker/`. If conflict, switch to `DOCKER_CONFIG=/var/lib/docker-config` env + mount there.
- **Runner-container hardening (postRenderer privileged-drop + `runAsUser: 1000`)**: the chart's `runner` container inherits `securityContext.privileged: true` from the chart-default `securityContext` block, but only the `dind` container actually needs privileged. Plan-stage research Q4 deferred this to a follow-up commit; ship after v1 stable for ≥ 1 week of green workflow runs. Tracked as a hardening sub-task.
- **Persistent layer cache PVC (Longhorn) for `/var/lib/docker`**: v1 uses `emptyDir`; layer cache is lost on Pod restart (re-fetchable from mirror; ~30s extra cold start). Plan-stage Q5 deferred to follow-up. Trigger: if observed cold-start cost grows materially as the `library/*` image set grows, swap `emptyDir` for `Longhorn` PVC in a single-line values change.
- **GOPROXY simplification experiment**: drop the `goproxy.cn` middle hop after Story 1 stable, see if `direct` + sing-box auto_redirect alone suffices. If yes, simplifies the env block. If observed Go-module fetch slowdown or failure, revert. (Plan.md line 402 says carry verbatim from swarm-01 in v1; this is the v2 cleanup.)
- **NetworkPolicy v2 egress lock-down**: v1 has no NetworkPolicy in the `forgejo-runner` namespace. Future hardening: an egress NetworkPolicy that allows only sing-box (`network/sing-box:7890`), in-cluster Forgejo / attic / zot, and the LAN zot CIDR; deny everything else. Requires careful interaction analysis with `auto_redirect` (kernel path bypasses NetworkPolicy at the iptables-nft layer); separately tracked.
- **swarm-01 cleanup PR**: hand-off noted in T048. Removing `kubernetes/apps/development/forgejo-runner/` from the swarm-01 repo. NOT in this tasks.md because it touches `/home/beacon/swarm-01/` which is explicitly out-of-scope per the per-cluster scoping rule.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 0 (Pre-flight)**: T001..T005. T001..T003 are independent reads; T004 (talos-i scale-to-0) must precede T005 (token mint) only by convention (no hard dependency, but minimizes cutover-window confusion).
- **Phase 1 (Author)**: T006..T016 — depends on Phase 0 token in operator's hand. T006 (mkdir) precedes everything; T007..T013 are file-disjoint and parallelizable; T014 (app/kustomization.yaml) depends on T010 / T011 / T012 / T013 having pinned filenames; T015 + T016 are sanity greps after authoring.
- **Phase 2 (Encrypt + commit)**: T017..T022 — strictly sequential. T018 round-trip MUST pass before T020 commit. T021 push depends on T020. T022 merge depends on T021.
- **Phase 3 (Verify)**: T023..T039 — all depend on T022 merge + Flux reconcile. T023 is the watcher; T024..T038 are the 13 verification rows (mostly parallel-readable since they're cluster reads); T039 is the Forgejo UI cross-check.
- **Phase 4 (Smoke test)**: T040..T044 — depends on Phase 3 all-green. T040→T041→T042 sequential (workflow runs). T043 + T044 parallel after T042.
- **Phase 5 (Cutover finalize)**: T045..T048 — depends on T042 (Story 1 acceptance gate). T045 is irreversible; do NOT run before T042 is green.
- **Phase 6 (Documentation)**: T049..T053 — depends on Story 1 success (T042) so docs reflect actual deployed shape. T049..T052 parallel (different files); T053 is the commit/push.

### Within Each Phase

- **Phase 1**: T007 (namespace), T008 (kustomization), T009 (ks.yaml), T010 (ocirepository), T012 (dockerd-config), T013 (registration-token plaintext) are file-disjoint and `[P]`-able. T011 (helmrelease) is the largest task and depends only on T006 mkdir; can be authored alongside T007..T010 / T012 / T013. T014 collects all of them in the kustomization; T015 + T016 are post-author sanity.
- **Phase 3**: T024..T032 + T036..T038 are parallel-readable cluster checks. T033 + T034 (sing-box coexistence) are story-tagged US3 because they're FR-023 / FR-024 — Story 4's acceptance gate.

### Parallel Opportunities

- **Phase 0**: T001 + T002 + T003 run in parallel (one bash session per check).
- **Phase 1**: 7 of 11 tasks marked `[P]` (T007, T008, T009, T010, T012, T013) — different files, no inter-dependencies.
- **Phase 3**: 8 of 17 tasks marked `[P]` — independent cluster reads.
- **Phase 6**: 4 of 5 tasks marked `[P]` — different doc files; T053 (commit) collects them.

---

## Tripwires (consolidated, per plan.md lines 393-405)

Surfaced inline above near the relevant tasks; recapped here for runbook reference.

- **PSA labels privileged on namespace** (T007): defense-in-depth even if cluster default appears permissive.
- **postRenderer container index `[0]=runner, [1]=dind`** (T011): verify post-apply at T024.
- **`subPath: daemon.json` mandatory** (T011): without it, the entire `/etc/docker/` is replaced.
- **Token expiry ~7 days** (T005, T032): re-mint + re-encrypt T013 if Phase 4 stretches past the window.
- **Bridge subnet conflict on dockerd start** (T012): mitigation = HelmRelease `strategy: Recreate` already in T011.
- **`network: host` is Pod-namespace, not node-namespace** (T011 / plan.md line 400): clarification only — desired behavior, lets build containers inherit Cilium CoreDNS.
- **NO_PROXY trailing-dot variants** (T011, T031): both `.cluster.local` AND `.cluster.local.` (and same for `.svc.cluster.local`) — Go's `net/http/httpproxy` does NOT normalize trailing dots (canonical: attic 2026-04-28 incident).
- **GOPROXY value verbatim from swarm-01** (T011): carry `https://goproxy.cn,https://proxy.golang.org,direct` in v1 — simplification is a deferred experiment.
- **codeberg.org chart fetch via Flux source-controller's general egress** (T010): NOT through sing-box — source-controller has no proxy env. Unblock if unreachable: pre-push to LAN zot.
- **`task configure` re-encrypt step** (T018, plan.md line 404): if `makejinja` ran directly anywhere, follow with `task encrypt-secrets` before commit (per project memory `feedback_makejinja_sops.md`).
- **Phase 2 `/root/.docker/config.json` mountPath collision** (Deferred section): verify after Phase 2 apply with `kubectl exec -c dind <pod> -- ls /root/.docker/`.

---

## Notes

- `[P]` tasks = different files / independent cluster reads, no dependencies on incomplete tasks.
- `[USx]` label maps Phase 3..5 tasks to spec.md user stories for traceability (US1 = Story 1 workflow, US2 = Story 2 cutover, US3 = Story 3/4 build-container egress shape + sing-box coexistence).
- All paths absolute under `/home/beacon/swarm/` — there is NO edit under `/home/beacon/swarm-01/` for this feature (T048 is hand-off only, NOT executed here).
- The Forgejo Actions workflow YAML in `nix-fleet` requires zero edits per FR-011 / SC-005; T047 verifies this.
- Commit after each phase (Phase 2's T020, Phase 6's T053). Stop at Phase 4 acceptance gate to validate Story 1 before Phase 5's irreversible cutover.
- Avoid: editing the same file from parallel `[P]` tasks (none of the `[P]` markers above pair on the same file by design).
