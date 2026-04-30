---
description: "Task list for Attic restore on talos-ii (Phase 4a)"
---

# Tasks: Attic restore on talos-ii (Phase 4a)

**Input**: Design documents from `/specs/001-attic-restore/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/attic-server-toml.md, quickstart.md

**Tests**: NOT requested in spec.md. No test-task entries are generated. Verification happens via post-deploy operator probes (curl, nixos-rebuild) per quickstart.md.

**Organization**: Tasks are grouped by user story (US1 = pull, US2 = push, US3 = rotation) so each story can be delivered, validated, and demoed independently.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: independent file/work, can run in parallel with other [P] tasks in the same phase.
- **[Story]**: phase-3+ tasks only — maps the work to spec.md's user stories.
- All file paths are absolute or rooted at `~/swarm`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: pre-flight verification + create the directory scaffolding.

- [X] T001 Verify cluster prerequisites are healthy: `kubectl get pods -n cnpg-system` (CNPG operator), `kubectl get sc longhorn-r3` (storage class exists), `kubectl get svc -n network sing-box` (egress proxy reachable), `curl -sI http://172.16.80.240:5000/v2/charts/app-template/manifests/4.6.2` (LAN zot has the chart). Document results in shell history; do not modify any file.
- [X] T002 Create empty directory tree: `mkdir -p ~/swarm/kubernetes/apps/nix/attic/app`. Then create `~/swarm/kubernetes/apps/nix/namespace.yaml` (single `Namespace` resource named `nix`, mirroring the shape of `~/swarm/kubernetes/apps/identity/namespace.yaml`) and `~/swarm/kubernetes/apps/nix/kustomization.yaml` (kustomize.config.k8s.io/v1beta1 listing `./namespace.yaml` and `./attic/ks.yaml` under `resources:`, mirroring `~/swarm/kubernetes/apps/identity/kustomization.yaml`).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: stand up the persistent + crypto state and bring the attic Pod online with `require-auth` on. After this phase, an in-cluster anonymous probe to the chart-emitted `attic` ClusterIP returns HTTP 401 — proving the auth gate works *before* any token exists. No user story can begin until this completes.

**⚠️ CRITICAL**: every US1/US2/US3 task assumes the Pod is `Running`, the CNPG cluster is `Healthy`, and `kubectl exec deploy/attic -- atticadm` works.

- [X] T003 On the operator workstation, generate the three secret materials per quickstart.md §1: `DB_PASSWORD` (≥32 chars random), `SU_PASSWORD` (≥32 chars random, independent), and the RS256 keypair (`openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096`). Capture base64 of priv + pub. **Same `DB_PASSWORD` plaintext value will appear in two SOPS files** — keep it in a shell variable, not a file. Shred any temp PEMs at the end (`shred -u /tmp/attic-*.pem`).
- [X] T004 Write `~/swarm/kubernetes/apps/nix/attic/app/pg-secret.sops.yaml` containing two YAML documents: `attic-pg-app` (basic-auth, `username: attic`, `password: $DB_PASSWORD`) and `attic-pg-superuser` (basic-auth, `username: postgres`, `password: $SU_PASSWORD`). Mirror the document shape of `~/swarm/kubernetes/apps/development/coder/app/pg-secret.sops.yaml` (note the `kubernetes.io/basic-auth` type). Then `sops -e -i` to encrypt. Verify `git diff` shows `ENC[…]` markers and no plaintext leaked.
- [X] T005 Write `~/swarm/kubernetes/apps/nix/attic/app/secret.sops.yaml` (single document, name `attic-secret`, type `Opaque`) with `stringData` keys `server.toml` (full TOML body per `contracts/attic-server-toml.md` "Minimal correct shape" — `database.url` MUST inline the same `$DB_PASSWORD` plaintext from T003), `token-rs256-secret-base64`, and `token-rs256-public-key-base64`. Then `sops -e -i`. Verify encryption.
- [X] T006 [P] Write `~/swarm/kubernetes/apps/nix/attic/app/ocirepository.yaml`: `OCIRepository` named `attic` (the chart, not the app), pointing at `oci://172.16.80.240:5000/charts/app-template` tag `4.6.2`, with `insecure: true`. Mirror `~/swarm/kubernetes/apps/development/n8n/app/ocirepository.yaml` exactly except for the resource name.
- [X] T007 [P] Write `~/swarm/kubernetes/apps/nix/attic/app/pg-cluster.yaml`: CNPG `Cluster` named `attic-pg`, `instances: 3`, `imageName: ghcr.io/cloudnative-pg/postgresql:16.4`, `bootstrap.initdb.{database: attic, owner: attic, secret.name: attic-pg-app, encoding: UTF8}`, `superuserSecret.name: attic-pg-superuser`, `storage.{size: 8Gi, storageClass: longhorn-r3}`, `primaryUpdateStrategy: unsupervised`, `monitoring.enablePodMonitor: false`, `resources.requests.{cpu: 50m, memory: 128Mi}` / `resources.limits.memory: 384Mi`. Mirror `~/swarm/kubernetes/apps/collaboration/matrix/app/pg-cluster.yaml` for shape, swap PG version + name + DB/owner.
- [X] T008 [P] Write `~/swarm/kubernetes/apps/nix/attic/app/pvc.yaml`: `PersistentVolumeClaim` named `attic-store`, `accessModes: [ReadWriteOnce]`, `storageClassName: longhorn-r3`, `resources.requests.storage: 100Gi`. Standalone — not a `volumeClaimTemplate`.
- [X] T009 Write `~/swarm/kubernetes/apps/nix/attic/app/helmrelease.yaml`: `HelmRelease` named `attic`, `chartRef.{kind: OCIRepository, name: attic}`, `values.controllers.attic.containers.app` with: image `ghcr.io/zhaofengli/attic` pinned by digest (resolve current digest at apply time and embed it in the `values.controllers.attic.containers.app.image` block; record digest in a one-line YAML comment above; **caveat: zot rejects upstream's Docker-v2 schema-2 manifest with `MANIFEST_INVALID`. Workaround: `nix-shell -p skopeo` then `skopeo copy --src-tls-verify=false --dest-tls-verify=false --override-os linux --override-arch amd64 --format=oci docker://ghcr.io/zhaofengli/attic@sha256:<upstream-index-digest> docker://172.16.80.240:5000/zhaofengli/attic:phase4a`. Pin the helmrelease to the resulting *OCI-converted* digest, not the upstream Docker digest. Same layer content; only the manifest envelope differs. Record both digests in the YAML comment.**), args `["--config", "/config/server.toml"]` (atticd has **no** `server` subcommand and **no** `--listen` flag — listen address is set in `server.toml`), ports name `http` containerPort `8080`, env `ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64` + `ATTIC_SERVER_TOKEN_RS256_PUBLIC_KEY_BASE64` from `attic-secret`, env `HTTPS_PROXY` / `HTTP_PROXY` = `http://sing-box.network.svc.cluster.local:7890`, env `NO_PROXY` = `".svc,.svc.cluster.local,.svc.cluster.local.,cluster.local,cluster.local.,10.0.0.0/8,172.16.0.0/12,localhost,127.0.0.1"`, securityContext `{runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, allowPrivilegeEscalation: false, readOnlyRootFilesystem: false, capabilities.drop: [ALL]}`, resources `{requests: {cpu: 50m, memory: 128Mi}, limits: {memory: 512Mi}}`. `values.service.app.{controller: attic, ports.http.port: 8080}`. `values.persistence.{config: {type: secret, name: attic-secret, globalMounts: [{path: /config/server.toml, subPath: server.toml, readOnly: true}]}, store: {type: persistentVolumeClaim, existingClaim: attic-store, globalMounts: [{path: /var/lib/attic/store}]}}`. **Do NOT** add `dependsOn` for `attic-pg` — `HelmRelease.dependsOn` only resolves against other HelmReleases, and `attic-pg` is a CNPG `Cluster` CRD; referencing it pins the chart in `PrerequisitesNotMet`. Let kube's restart-on-failure handle the brief CrashLoopBackOff while the DB bootstraps. Reference `~/swarm/kubernetes/apps/development/n8n/app/helmrelease.yaml` for the bjw-s shape.
- [X] T010 Write `~/swarm/kubernetes/apps/nix/attic/ks.yaml`: Flux `Kustomization` named `attic`, `path: ./kubernetes/apps/nix/attic/app`, `postBuild.substituteFrom: [{name: cluster-secrets, kind: Secret}]`, `targetNamespace: nix`, `prune: true`, `wait: false`, `timeout: 10m`, `interval: 1h`, `sourceRef.{kind: GitRepository, name: flux-system, namespace: flux-system}`. **Do NOT** add a `dependsOn` block — none of the existing apps (coder/n8n/matrix) depend on the cnpg or longhorn Flux Kustomizations. They trust the cluster baseline; Flux retries the HelmRelease until the Cluster CRD is reconciled. (If you do want to add one, the CNPG Flux Kustomization is named `cloudnative-pg` and lives in **`flux-system`** namespace, not `cnpg-system` — `cnpg-system` is the operator install ns.) Mirror `~/swarm/kubernetes/apps/development/coder/ks.yaml`.
- [X] T011 Write `~/swarm/kubernetes/apps/nix/attic/app/kustomization.yaml` listing under `resources:` (in this order): `./pg-secret.sops.yaml`, `./secret.sops.yaml`, `./ocirepository.yaml`, `./pg-cluster.yaml`, `./pvc.yaml`, `./helmrelease.yaml`. **Do not** list `./httproute.yaml` or `./service-tailscale.yaml` yet — those land in Phase 3 (US1).
- [X] T012 Run `cd ~/swarm && task encrypt-secrets` (idempotent — re-encrypts if the prior `sops -e` somehow left plaintext). Then `git status` to confirm only encrypted files are staged-able. Commit ONE commit on a working branch with all foundational files: `feat(nix): attic Phase 4a foundational (CNPG + secrets + helmrelease)`.
- [ ] T013 Push the foundational commit. Watch flux reconcile: `flux reconcile source git flux-system && flux reconcile kustomization apps -n flux-system`. Then `flux get hr -n nix attic` → `READY=True`. `kubectl get cluster -n nix attic-pg -w` until `Ready=True` (3 instances). `kubectl rollout status -n nix deploy/attic`. From inside the cluster: `kubectl run -n nix --rm -it probe --image=curlimages/curl --restart=Never -- curl -sI http://attic:8080/nix-fleet/nix-cache-info | head -1` → expect HTTP/1.1 401 (auth gate proven; satisfies SC-002 partially via in-cluster path). If anything is `Pending` / `CrashLoopBackOff`, debug per quickstart.md §3 "Common stalls" before continuing.

**Checkpoint**: Pod up, anonymous in-cluster probe = 401, no tokens exist yet, no public path yet.

---

## Phase 3: User Story 1 — NixOS host pulls authenticated cache (Priority: P1) 🎯 MVP

**Goal**: end-to-end "fleet host pulls cache hits over the public Cloudflare path", proving SC-001, SC-002 (externally), SC-003.

**Independent Test**: from a NixOS fleet host with the rotated `nix-fleet` token in its netrc, `nixos-rebuild switch` substitutes ≥1 path from `nix.beaco.works`. Anonymous external probe to `nix.beaco.works/nix-fleet/nix-cache-info` returns 401; authenticated probe to `/_api/v1/cache-config/nix-fleet` returns 200.

### Implementation for User Story 1

- [ ] T014 [P] [US1] Write `~/swarm/kubernetes/apps/nix/attic/app/httproute.yaml`: Gateway-API `HTTPRoute` named `attic`, `hostnames: ["nix.${SECRET_DOMAIN}"]`, `parentRefs: [{name: envoy-external, namespace: network, sectionName: https}]`, single rule with `backendRefs: [{name: attic, port: 8080}]`. Mirror `~/swarm/kubernetes/apps/identity/authentik/app/httproute.yaml` for shape.
- [ ] T015 [P] [US1] Write `~/swarm/kubernetes/apps/nix/attic/app/service-tailscale.yaml`: `Service` named `attic-tailscale`, `type: ClusterIP`, `selector: {app.kubernetes.io/name: attic}`, ports `[{name: http, port: 8080, targetPort: 8080, protocol: TCP}]`, **annotations** `tailscale.com/expose: "true"`, `tailscale.com/hostname: "attic"`, `tailscale.com/proxy-class: "proxied"`. **All three annotations are required** — without `proxy-class: proxied` the per-Service Tailscale proxy pod stays `NeedsLogin` (see `docs/operations/tailscale-operator.md`).
- [ ] T016 [US1] Update `~/swarm/kubernetes/apps/nix/attic/app/kustomization.yaml` to append `./httproute.yaml` and `./service-tailscale.yaml` to the `resources:` list. Commit + push: `feat(nix): expose attic via Cloudflare + tailnet (US1)`.
- [ ] T017 [US1] Watch flux reconcile, then verify the public route + tailnet device are alive: `kubectl get httproute -n nix attic -o yaml | yq '.status'` (expect `Accepted=True` from `envoy-external`); `kubectl get pods -n tailscale | grep ts-attic` (expect a `ts-attic-<id>-0` Pod `Running`); `kubectl logs -n tailscale ts-attic-<id>-0 | tail -20` (expect successful tailnet login, **not** `NeedsLogin`).
- [ ] T018 [US1] Create the `nix-fleet` cache: `kubectl exec -n nix deploy/attic -- atticadm -f /config/server.toml create-cache nix-fleet --public false`. Confirm: `kubectl exec -n nix deploy/attic -- atticadm -f /config/server.toml list-caches` shows `nix-fleet`.
- [ ] T019 [US1] Mint the long-lived pull token: `kubectl exec -n nix deploy/attic -- atticadm -f /config/server.toml make-token --sub nix-daemon --validity 1y --pull nix-fleet`. Capture the JWT. **Do not** paste it into any log file in this repo.
- [ ] T020 [US1] In the **separate Nix-fleet repo** (not `swarm`), edit `secrets/shared/attic.yaml`: replace the existing `nix-daemon` token with the new JWT, keeping the netrc-file shape identical. Run `sops -e -i secrets/shared/attic.yaml`. Commit on the Nix-fleet repo: `rotate attic pull token (post-talos-ii migration)`. Push.
- [ ] T021 [US1] Pick one canary fleet host (e.g. the smallest / least critical machine). SSH in and `sudo nixos-rebuild switch --flake .#<canary>`. While it runs, in another terminal: `journalctl -u nix-daemon -n 200 -f | grep -E 'attic|nix-fleet|substitut'`. Expect ≥1 line showing a substitute coming from `nix.beaco.works`. If `403`/`404` instead, the token is wrong; if `connection refused`, the route is wrong. After canary succeeds, roll out to the rest of the fleet (`nixos-rebuild switch` on each, sequentially or in parallel).
- [ ] T022 [US1] Final external acceptance: from a workstation **outside** the home network and **off** the tailnet, `curl -sI https://nix.beaco.works/nix-fleet/nix-cache-info | head -1` → `HTTP/2 401` (SC-002). Then `curl -sI -H "Authorization: Bearer $TOKEN" https://nix.beaco.works/_api/v1/cache-config/nix-fleet | head -1` → `HTTP/2 200` (SC-003). Then `curl -s -H "Authorization: Bearer $TOKEN" https://nix.beaco.works/_api/v1/cache-config/nix-fleet | jq` → JSON with the cache config (substantive 200, not just "hello"). SC-001 is satisfied by canary rebuild logs from T021.

**Checkpoint**: US1 complete — fleet pulls work end-to-end, MVP is shippable here. STOP and validate before moving to US2.

---

## Phase 4: User Story 2 — Operator pushes a build (Priority: P2)

**Goal**: prove the write path works and the cache is durable across pod + DB restarts. Satisfies SC-004 and SC-005.

**Independent Test**: a path pushed from an operator workstation is retrievable by a different fleet host, survives a forced attic Pod restart, and survives a CNPG primary failover.

### Implementation for User Story 2

- [ ] T023 [US2] Mint a separate push token (do not reuse the pull token from T019): `kubectl exec -n nix deploy/attic -- atticadm -f /config/server.toml make-token --sub operator-push --validity 90d --push nix-fleet --pull nix-fleet`. Capture in a *temporary* local netrc on the operator workstation (chmod 600).
- [ ] T024 [US2] From the operator workstation, push a known small derivation: `nix copy --to "https://nix.beaco.works/nix-fleet?compression=zstd" $(nix build nixpkgs#hello --no-link --print-out-paths)`. Expect zero errors, completion in seconds for hello. Verify: `nix path-info --store https://nix.beaco.works/nix-fleet $(nix build nixpkgs#hello --no-link --print-out-paths)` returns the path.
- [ ] T025 [US2] On a fleet host with **only** the pull token (different from the workstation in T024), force a fresh substitute by adding a non-cached attribute that depends on hello, or simply `nix-store --realise --add-root /tmp/r <hello-path>` after `nix-store --delete <hello-path>` to force a re-fetch. Confirm via `journalctl -u nix-daemon` that the substitute came from `nix.beaco.works`. SC-001 reinforced; cross-host write→read path proven.
- [ ] T026 [US2] Durability — pod restart (SC-004): `kubectl delete pod -n nix -l app.kubernetes.io/name=attic`. Wait for the new Pod via `kubectl rollout status -n nix deploy/attic`. Then re-pull the path from T025 — it should still resolve as a hit, not require re-push.
- [ ] T027 [US2] Durability — CNPG failover (SC-005): identify current primary `kubectl get cluster -n nix attic-pg -o jsonpath='{.status.currentPrimary}'`. Promote a replica: `kubectl cnpg promote -n nix attic-pg <new-primary-pod>`. Watch `kubectl logs -n nix deploy/attic --tail=50 -f` — expect a brief reconnect window (≤30 s) and then resumed serving. Re-curl the auth probe from T022; should be 200 again. **Once verified, do not also kill the old primary** — let CNPG resync naturally.

**Checkpoint**: US2 complete — push works, durability proven for both layers (storage + DB).

---

## Phase 5: User Story 3 — Operator rotates the shared `nix-fleet` token (Priority: P3)

**Goal**: validate that the rotation runbook is reproducible and that revocation actually rejects old tokens (SC-006).

**Independent Test**: an operator following the runbook alone can mint a replacement token, roll it out to ≥2 fleet hosts, revoke the prior token, and confirm the prior token gives 401.

### Implementation for User Story 3

- [ ] T028 [US3] Mint a replacement pull token: `kubectl exec -n nix deploy/attic -- atticadm -f /config/server.toml make-token --sub nix-daemon --validity 1y --pull nix-fleet`. Capture the new JWT.
- [ ] T029 [US3] In the Nix-fleet repo, replace the JWT in `secrets/shared/attic.yaml` (keep the surrounding netrc-file shape identical). `sops -e -i`. Commit + push on the Nix-fleet repo: `rotate attic pull token (drill)`.
- [ ] T030 [US3] On one fleet host, `nixos-rebuild switch` to pick up the new token. Verify `journalctl -u nix-daemon` shows successful substitutes (the new token works). Then on a second fleet host, repeat — confirms rotation propagates via the SOPS secret + nixos-rebuild path.
- [ ] T031 [US3] Revoke the old (pre-T028) token. atticadm exposes this via `atticadm … revoke-token <kid>` once you know the key id; the runbook will document the procedure. **After revocation**, on a host that has not yet picked up the new token (or by manually crafting a request with the old JWT), `curl -sI -H "Authorization: Bearer $OLD_TOKEN" https://nix.beaco.works/_api/v1/cache-config/nix-fleet | head -1` → expect `HTTP/2 401`.

**Checkpoint**: US3 complete — rotation drilled end-to-end, old token confirmed dead.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: ratify the architectural decision (ADR), capture the learned procedure (runbook), update the documentation index. Per Constitution X, ADR + runbook + index must land in the same commit as feature changes — do this as a final commit on the same branch before merge.

- [ ] T032 [P] Write `~/swarm/docs/decisions/talos-ii/0011-attic-cnpg.md`. Sections: `# ADR 0011 — Attic on CloudNativePG`, `## Status: Accepted (2026-04-29)`, `## Context` (swarm-01 used bitnami PG; swarm-ii has standardized on CNPG since Phase 3b; multi-replica failover for cluster-internal services is desirable; PG 16 specifically because swarm-01's existing data is on 16.x and cross-major restores are unsupported even though we don't migrate state today; storage class is `longhorn-r3` for consistency with other Phase 3 apps), `## Decision` (CNPG `Cluster` `attic-pg` with PG 16, 3 replicas, longhorn-r3, dual-secret pattern for DSN matching `coder`'s approach), `## Consequences` (positive: failover, observability via CNPG operator, consistent operator surface; negative: small-DB-on-3-replicas overhead is wasteful in absolute terms but cheap given Longhorn/cluster scale; rotation requires editing two SOPS files), `## Non-state-migration rationale` (attic is content-addressable; the 100 Gi nar-store is reproducible from fleet hosts re-pushing on rebuild; the cost of importing swarm-01 state is implementation complexity, the benefit is one-time bandwidth savings — not worth the deviation from "fresh deploy" simplicity). Mirror `docs/decisions/talos-ii/0010-coder-n8n-cnpg.md` shape.
- [ ] T033 [P] Write `~/swarm/docs/operations/attic-restore.md`. Sections: `# Attic restore — Phase 4a runbook`, `## What this is` (one paragraph — points readers at this spec dir for "why"), `## First-deploy verification` (extracted from quickstart.md §§1–4), `## Token mint procedure` (the exact `kubectl exec atticadm` invocation, both pull-only and push variants, with `--validity` guidance from swarm-01's README), `## Fleet rollout` (extracted from quickstart.md §7), `## Token revocation` (the procedure validated in T031), `## DB password rotation` (the dual-SOPS-file caveat: rotate `pg-secret.sops.yaml` and `secret.sops.yaml`'s embedded DSN in **one commit**, then `flux reconcile`), `## Adding a new cache` (one-shot `atticadm create-cache <name>` — no manifest change). Cross-link to ADR 0011 and to `docs/operations/tailscale-operator.md` (for the `proxy-class: proxied` requirement).
- [ ] T034 Update `~/swarm/docs/index.md`: under `talos-ii` ADR list, add `[talos-ii/0011 — Attic on CloudNativePG](decisions/talos-ii/0011-attic-cnpg.md)` after the 0010 entry. Under Operations, add `[Attic restore (Phase 4a runbook)](operations/attic-restore.md) — token mint, fleet rollout, rotation` (placement: after `n8n-restore.md`).
- [ ] T035 Final commit: stage `docs/decisions/talos-ii/0011-attic-cnpg.md`, `docs/operations/attic-restore.md`, `docs/index.md`. Commit message: `docs(attic): ADR 0011 + restore runbook + index update`. Push. Open a PR (or merge directly into `main` per repo convention) bundling: foundational commit (T012), US1 commit (T016), and this docs commit. Verify SC-006 by handing the runbook to the operator hat and walking through "could a future operator do this restore from the runbook alone?" — if any step needed information from this spec dir or git log, fold it into the runbook now.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: T001 (verification) gates T002 (creation). T001→T002 sequential.
- **Phase 2 (Foundational)**: T003 (secret material gen) gates T004+T005 (the two SOPS files use the material). T004 + T005 are sequential (same shell session, same `$DB_PASSWORD` value), but T006/T007/T008 (manifest files for OCIRepository / CNPG / PVC) are parallel with T005. T009 (helmrelease) writes a single file but references both Secrets and the PVC, so T009 follows T005+T008. T010 (ks.yaml) is independent. T011 (app kustomization) references all the files above so it follows T009+T010. T012 (encrypt + commit) follows T011. T013 (push + verify) follows T012. **All of Phase 2 must complete before any Phase 3+ task starts.**
- **Phase 3 (US1)**: T014 + T015 are parallel (different files). T016 (kustomization update + commit) follows both. T017 (verify route + tailnet) follows T016. T018 (create cache) follows T013 (Pod up) only — could technically run in parallel with T017 but logically it's after the public path is up. T019 follows T018. T020 follows T019. T021 follows T020. T022 finalizes US1.
- **Phase 4 (US2)**: T023 follows US1 complete. T024 follows T023. T025 follows T024. T026 follows T025. T027 follows T026. (US2 is mostly sequential — each step builds on the prior.)
- **Phase 5 (US3)**: T028 follows US2 complete (don't drill rotation while US2 push verification is mid-flight). T029 follows T028. T030 follows T029. T031 follows T030.
- **Phase 6 (Polish)**: T032 + T033 are parallel (different files). T034 follows both. T035 (final commit) follows T034.

### User Story Dependencies

- **US1 (P1)**: depends only on Foundational. **MVP — stop here for an initial demo if needed.**
- **US2 (P2)**: depends on US1 (cache exists, public route exists). Could run in parallel with US3 if a second operator picks up rotation drilling, but no real reason to.
- **US3 (P3)**: depends on US1 (token to rotate exists). Independent of US2.

### Parallel Opportunities (within phases)

- Phase 2: T006, T007, T008 in parallel (different files, no shared state).
- Phase 3: T014, T015 in parallel.
- Phase 6: T032, T033 in parallel.

---

## Parallel Example: Phase 2 manifest writes

```bash
# After T003-T005 (secrets ready), launch T006/T007/T008 in parallel:
Task: "Write ocirepository.yaml — bjw-s app-template 4.6.2 from LAN zot"
Task: "Write pg-cluster.yaml — CNPG attic-pg, PG 16, 3× longhorn-r3"
Task: "Write pvc.yaml — attic-store, 100Gi longhorn-r3"
```

---

## Implementation Strategy

### MVP First (US1 only)

1. Phase 1 + Phase 2 → cluster has the persistent + crypto state, attic Pod up, anonymous probe = 401.
2. Phase 3 → cache exists, fleet has new token, fleet rebuild substitutes from cluster cache.
3. **STOP**: SC-001/2/3 satisfied — feature is shippable as MVP.

### Incremental delivery

1. MVP (above) → demo. Land first commit.
2. Add Phase 4 (US2 push) → second commit verifying durability + failover. SC-004/5.
3. Add Phase 5 (US3 rotation) → third commit drilling rotation. SC-006 partial.
4. Add Phase 6 (Polish) → docs commit closing SC-006 fully.

A reasonable single-PR strategy: do Phases 1–6 on one branch, three commits total (foundational + US1 ks update + docs), and merge as one PR. The user-story checkpoints exist for the implementer's own confidence + future bisection.

### Single-operator strategy (this is the realistic case)

Run sequentially T001 → T035. The "parallel" markers help only insofar as the operator's editor lets them keep ~3 files open at once (Phase 2 manifest writes, Phase 6 doc writes); there is no team to fan out to here.

---

## Notes

- [P] tasks = different files, no dependencies — concurrency is editor-level for a single operator.
- [Story] label maps tasks back to spec.md user stories.
- Verify each Checkpoint before advancing to the next phase. Do not skip the in-cluster 401 probe (T013) — it is the cheapest signal that auth is wired up correctly.
- Commit at every phase boundary minimum. Many small commits are cheap; debugging a "what went wrong between Phase 2 and the tailnet device showing up" later is not.
- Do not regenerate JWT keys after Phase 2 completes — every existing token would be invalidated. The keys are long-lived per the contract.
- Watch for password drift between `pg-secret.sops.yaml.attic-pg-app.password` and `secret.sops.yaml.attic-secret.server.toml`'s `database.url` — they are two SOPS files that must hold the same plaintext. If the Pod CrashLoopBackOffs with `password authentication failed`, that is the cause.
