---
description: "Task list for talos-ii mesh — siderolabs/tailscale + 3-node subnet router (HA, OAuth+tag)"
---

# Tasks: talos-ii mesh — `siderolabs/tailscale` + 3-node subnet router

**Input**: Design documents from `/home/beacon/swarm/specs/004-talos-ii-mesh-implementation/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md, contracts/
**Target cluster**: `[talos-ii]` only — every absolute path below is rooted at `/home/beacon/swarm/`. There must be no edit under `/home/beacon/swarm-01/` for this feature; talos-i adoption is the separate work tracked under shared/0003.

**Tests**: No automated test suite is generated. Validation is via the V1–V5 procedure in [`contracts/validation-procedure.md`](./contracts/validation-procedure.md) — five gated steps mapping FR-015 to machine-readable predicates. Acceptance gates SC-001..SC-010 in [`spec.md`](./spec.md).

**Organization**: Tasks are grouped by phase (Pre-flight → Schematic generation → Author → Encrypt+commit → Talos config regen → Rolling upgrade → CoreDNS reconcile + cross-cluster validation → Documentation). Story labels `[USx]` mark tasks that close out spec user stories (US1 = pod-to-tailnet, US2 = tailnet-to-pod, US3 = HA single-node-fail, US4 = operator+extension complementarity, US5 = ephemeral device hygiene).

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can run in parallel with the previous task (different files, no dependency on incomplete tasks).
- **[Story]**: maps to spec.md user stories.
- All file paths are absolute under `/home/beacon/swarm/`.
- `[depends on T###]` is added for non-adjacent dependencies.

---

## Phase 0 — Pre-flight

**Purpose**: prove the cluster preconditions hold and capture the manual one-shot Tailscale-admin setup before authoring any manifest. No file edits in this phase except T005 (OAuth client_secret captured into a shell variable, NOT a tracked file). The OAuth client lifetime is unbounded; the client_secret is captured here and survives across this entire tasks.md run.

- [ ] T001 Verify Cilium + kube-proxy healthy on all three MS-01 nodes (precondition for kube-proxy DNAT on the tailnet→pod entry hop, FR-015(4)): `kubectl -n kube-system get ds cilium kube-proxy -o wide` shows `READY 3/3` for both. `kubectl -n kube-system logs -l k8s-app=cilium --tail=50 | grep -iE "error|fatal"` returns nothing concerning. If kube-proxy is replaced by Cilium-kube-proxy-replacement (cluster default), the `kube-proxy` DS may not exist — confirm via `cilium config view | grep kube-proxy-replacement` returning `true`.
- [ ] T002 [P] Verify sing-box DaemonSet healthy on all three MS-01 nodes: `kubectl -n network get ds sing-box -o wide` shows `READY 3/3 UP-TO-DATE 3 AVAILABLE 3`; `kubectl -n network logs -l app=sing-box --tail=50 | grep -iE "auto_redirect|error"` shows auto_redirect lines and zero errors. This is the egress gateway whose `route_exclude_address` MUST cover `100.64.0.0/10` (verified in T003).
- [ ] T003 [P] Verify sing-box `route_exclude_address` includes `100.64.0.0/10` by reading the rendered config from a running pod (per Q3 / quickstart P0.4): `kubectl exec -n network ds/sing-box -- jq -r '.. | objects | select(.action=="route_exclude") | .ip_cidr // .ip_cidr_set // .geosite' /etc/sing-box/config.json | grep -F '100.64.0.0/10'`. Expected: one literal-CIDR match. **Tripwire (per project memory `feedback_sops_cross_repo_cwd.md` round-trip principle)**: the in-repo HelmRelease comment mentions only `geoip-private + geoip-cn` (RFC1918 + CN) — that does NOT cover CGNAT. The explicit `100.64.0.0/10` line is in the `/etc/nixos modules/common/sing-box.nix` source, rendered through `sops.templates`. If absent from the live pod, BLOCK and patch `/etc/nixos` first — do NOT proceed to Phase 1.
- [ ] T004 [P] Verify factory.talos.dev reachability + Secure Boot key bundle still valid: `curl -fsSI https://factory.talos.dev/image/5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4/v1.12.7/metal-amd64.iso` returns `HTTP/2 200`. The current `5456009e...` schematic boots today on all three nodes, so the existing Secure Boot key bundle (PCR-bound) is known good — the new schematic in Phase 1 is signed by the same bundle (per Plan §Risks #1).
- [ ] T005 Manual Tailscale admin one-shot setup (per quickstart P0.1 + P0.2):
  1. Tailscale admin → Access Controls → JSON: ensure `"tagOwners": { "tag:talos-ii-node": ["autogroup:admin"] }` is present (no-op if already declared from an earlier exploratory run). Save.
  2. Tailscale admin → Settings → OAuth clients → **Generate OAuth client**: Description `talos-ii subnet routers`; Scopes `auth_keys:write`; Tag `tag:talos-ii-node`; Expiry `never`. Click Generate.
  3. **Copy the client_secret immediately** (only displayed once). It begins `tskey-client-…`. Capture in a shell variable: `TS_OAUTH_SECRET='tskey-client-…'`. Do NOT write to any tracked file.
  **Tripwire (FR-006 / Plan Risk #2)**: client_secret is the long-lived credential — leakage means revoke + re-mint + re-encrypt + re-deploy all 3 nodes. Verify your shell history is suppressed (`HISTCONTROL` includes `ignorespace`, lead the `TS_OAUTH_SECRET=...` line with a space).
- [ ] T006 [P] Verify operator laptop is enrolled in tailnet `tail5d550.ts.net` and accepts routes: `tailscale status | head -3` shows the laptop as a tailnet member; `tailscale set --accept-routes` (idempotent — no-op if already on). This is required for V1 / V4 / V5 verification later.

**Checkpoint**: cluster preconditions confirmed; OAuth client minted; secret captured in shell variable; tag `tag:talos-ii-node` declared in ACL; operator laptop on tailnet with route-accept on. Authoring can begin.

---

## Phase 1 — Schematic generation

**Purpose**: submit the new image-factory schematic adding `siderolabs/tailscale` to the existing extension list. No file edits in this phase; the captured schematic ID feeds into Phase 2.

- [ ] T007 Submit new schematic to https://factory.talos.dev/ (per quickstart P1.1) with: Architecture `amd64`, Bootloader `sd-boot`, Secure Boot `enabled`, Talos version `v1.12.7`, Extensions `siderolabs/intel-ucode` + `siderolabs/iscsi-tools` + `siderolabs/util-linux-tools` + **`siderolabs/tailscale`** (NEW). Submit. Capture the resulting schematic ID — a 64-char hex SHA256 distinct from `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`. Capture in a shell variable: `NEW_ID='<64-hex>'`. **Tripwire (Plan Risk #1)**: the new schematic is signed by the same Secure Boot key bundle as the current one (factory parameter `secureboot=true` selects the well-known sidero bundle), so PCR binding survives. If first-node upgrade fails Secure Boot verification on boot, that's Tier 3 rollback (vPro AMT KVM rescue).
- [ ] T008 [P] [depends on T007] Sanity-check the new schematic URL is fetchable: `curl -fsSI "https://factory.talos.dev/image/${NEW_ID}/v1.12.7/metal-amd64.iso"` returns `HTTP/2 200`. Also `curl -fsSI "https://factory.talos.dev/installer-secureboot/${NEW_ID}/v1.12.7/installer.tar.gz"` returns 200 — that is the URL `task talos:upgrade-node` will fetch.
- [ ] T009 [depends on T007] Document the new ID in operator's notes (NOT a tracked file yet — that comes in Phase 7 documentation): paste `NEW_ID` into the operator's scratchpad alongside the supersession date `YYYY-MM-DD` (today). The `NEW_ID` value will be hardcoded into `talos/talconfig.yaml` (T010), `docs/talos-image-factory.md` (T029), and the ADR (T030); per cross-entity invariant 1 in data-model.md these must agree across 4 sites.

**Checkpoint**: new schematic ID captured and reachable; ready to author manifests.

---

## Phase 2 — Author manifests

**Purpose**: write all five files (1 talconfig swap + 3 per-node tailscale patches + 3 per-node SOPS secret patches + 1 CoreDNS edit) in dependency order. No commit yet — Phase 3 handles SOPS encryption + commit. Pattern reference: existing `talos/patches/global/machine-*.yaml` for the patch shape; the per-node directory convention is documented in `talos/patches/README.md` (`${node-hostname}/` directories are applied to that node only).

**Operator decision baked in**: `${HOSTNAME}` substitution inside `ExtensionServiceConfig.environment[]` is **not used** — per-node patches are authored from the start (per the pre-task user decision; Plan Risk #3 fallback path is taken upfront, no canary). This produces 3 near-duplicate tailscale ExtensionServiceConfig files and 3 near-duplicate SOPS secret files.

- [ ] T010 Replace the schematic ID in `/home/beacon/swarm/talos/talconfig.yaml` at three sites — lines 33 (ms01-a), 83 (ms01-b), 133 (ms01-c) — swapping `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4` for `${NEW_ID}` from T007. Verify exactly 3 occurrences disappear and 3 occurrences appear: `grep -c '5456009e' talos/talconfig.yaml` returns 0; `grep -c "${NEW_ID}" talos/talconfig.yaml` returns 3. **Tripwire (data-model.md cross-entity invariant 1)**: schematic ID consistency — the new ID lands here and in 1 doc site (T029) for a total of 4 occurrences across 2 files; mismatch is a lint failure.
- [ ] T011 Create the per-node patch directory tree: `mkdir -p /home/beacon/swarm/talos/patches/ms01-a /home/beacon/swarm/talos/patches/ms01-b /home/beacon/swarm/talos/patches/ms01-c`. The talhelper convention from `talos/patches/README.md` is `${node-hostname}/` — talhelper applies these to that node only. **Tripwire**: directory name MUST exactly match the `nodes[].hostname` in `talconfig.yaml` (`ms01-a`, `ms01-b`, `ms01-c`). Typo silently drops the patch.
- [ ] T012 [P] [depends on T011] Create the ExtensionServiceConfig at `/home/beacon/swarm/talos/patches/ms01-a/machine-tailscale.yaml`:
  ```yaml
  ---
  apiVersion: v1alpha1
  kind: ExtensionServiceConfig
  name: tailscale
  environment:
    - TS_HOSTNAME=talos-ii-ms01-a
    - TS_ROUTES=10.44.0.0/16,10.55.0.0/16
    - TS_EXTRA_ARGS=--advertise-tags=tag:talos-ii-node --accept-routes
    - TS_ACCEPT_DNS=false
    - TS_AUTH_ONCE=true
  ```
  **Tripwire #1 (per-node hardcoded HOSTNAME)**: `TS_HOSTNAME` is the literal `talos-ii-ms01-a`, NOT `talos-ii-${HOSTNAME}` — substitution is rejected by operator decision. **Tripwire #2 (Forbidden envs per `contracts/extension-service-config.md`)**: `TS_AUTHKEY` MUST NOT appear here — secret material lives in T015's separate file.
- [ ] T013 [P] [depends on T011] Create `/home/beacon/swarm/talos/patches/ms01-b/machine-tailscale.yaml` — identical to T012 except `TS_HOSTNAME=talos-ii-ms01-b`.
- [ ] T014 [P] [depends on T011] Create `/home/beacon/swarm/talos/patches/ms01-c/machine-tailscale.yaml` — identical to T012 except `TS_HOSTNAME=talos-ii-ms01-c`.
- [ ] T015 [P] [depends on T011, T005] Create the cleartext secret patch at `/home/beacon/swarm/talos/patches/ms01-a/machine-files-tailscale-secret.sops.yaml` (plaintext form before SOPS encryption — Phase 3 encrypts in place):
  ```yaml
  ---
  machine:
    files:
      - op: create
        path: /var/etc/tailscale/auth.env
        permissions: 0o600
        content: |
          TS_AUTHKEY=${TS_OAUTH_SECRET}?ephemeral=true&preauthorized=true
  ```
  Substitute the literal `TS_OAUTH_SECRET` value from T005 into the `content:` block (do not leave the `${...}` placeholder — talhelper does not substitute shell variables in patches). All three nodes share the same OAuth client_secret per Plan-stage decision (one OAuth client owns `tag:talos-ii-node`; each node mints its own ephemeral key on boot). **Tripwire (FR-006)**: file is plaintext at this point — DO NOT commit yet (Phase 3 SOPS-encrypts before commit).
- [ ] T016 [P] [depends on T011, T005] Create `/home/beacon/swarm/talos/patches/ms01-b/machine-files-tailscale-secret.sops.yaml` — identical content to T015 (same OAuth secret; only the file path differs).
- [ ] T017 [P] [depends on T011, T005] Create `/home/beacon/swarm/talos/patches/ms01-c/machine-files-tailscale-secret.sops.yaml` — identical content to T015.
- [ ] T018 [depends on T012, T013, T014, T015, T016, T017] Wire each per-node patch into `/home/beacon/swarm/talos/talconfig.yaml`. The existing `nodes[].patches:` block on each node currently contains one inline TPM-encryption patch (lines ~63-77 ms01-a, ~113-127 ms01-b, ~163-177 ms01-c). Add two `@./patches/<hostname>/...` entries per node before/after the existing inline patch:
  ```yaml
      patches:
        - "@./patches/ms01-a/machine-tailscale.yaml"
        - "@./patches/ms01-a/machine-files-tailscale-secret.sops.yaml"
        - # Encrypt system disk with TPM
          |- ...existing inline patch unchanged...
  ```
  Repeat for ms01-b and ms01-c with their respective hostnames. **Tripwire (per `talos/patches/README.md`)**: per-node patches under `${node-hostname}/` are auto-discovered ONLY if listed in `nodes[].patches:` — talhelper does NOT scan the directory. Forgetting to wire an entry silently drops the patch. Verify exactly 6 new `@./patches/ms01-{a,b,c}/...` lines after this edit.
- [ ] T019 [P] [depends on T011] Confirm SOPS rule covers per-node path: `grep -F 'talos/.*\.sops\.ya?ml' /home/beacon/swarm/.sops.yaml` returns the talos rule. The regex is `talos/.*\.sops\.ya?ml` (whole-file `mac_only_encrypted: true`, age recipient `age19w3svw...qant4ej`), which matches `talos/patches/ms01-a/machine-files-tailscale-secret.sops.yaml` and the other two — no `.sops.yaml` rule edit needed. **Tripwire (project memory `feedback_sops_cross_repo_cwd.md`)**: rule presence proves recipient resolution path; round-trip decrypt (T021) is the only check that proves recipient correctness.
- [ ] T020 [P] Update CoreDNS HelmRelease at `/home/beacon/swarm/kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`. Append a NEW second entry to the existing `spec.values.servers[]` array (after the existing `.`-zone entry, NOT a plugin inside it) per [`contracts/coredns-forward-block.md`](./contracts/coredns-forward-block.md):
  ```yaml
        - zones:
            - zone: ts.net
              scheme: dns://
          port: 53
          plugins:
            - name: errors
            - name: cache
              parameters: 30
            - name: forward
              parameters: . 100.100.100.100
            - name: log
              configBlock: |-
                class error
  ```
  **Tripwire #1 (Plan Risk #5)**: it MUST be a NEW `servers[]` entry, NOT a plugin inside the existing `.` server block. The chart compiles each `servers[]` entry into a separate Corefile server block; CoreDNS picks longest-zone-match, so `*.ts.net` queries hit the new block. **Tripwire #2**: `forward` plugin's `parameters: . 100.100.100.100` — the leading `.` is the zone match (everything in this server block), the IP is MagicDNS — both are required, do not collapse.

**Checkpoint**: 7 files created/modified across `talos/` and `kubernetes/`; secrets still plaintext; nothing committed.

---

## Phase 3 — SOPS encrypt + commit

**Purpose**: SOPS-encrypt the 3 per-node secret files, prove recipient correctness via round-trip decrypt, run pre-commit grep for plaintext leakage, and ship the manifests as one commit. Flux reconciles automatically on merge to main; the talconfig.yaml + talos patch changes are picked up by the next `task talos:configure` (Phase 4).

- [ ] T021 [depends on T015, T016, T017] SOPS-encrypt each per-node secret file in place (run from inside `/home/beacon/swarm` to avoid cross-repo `.sops.yaml` confusion per project memory `feedback_sops_cross_repo_cwd.md`):
  ```sh
  cd /home/beacon/swarm
  sops -e -i talos/patches/ms01-a/machine-files-tailscale-secret.sops.yaml
  sops -e -i talos/patches/ms01-b/machine-files-tailscale-secret.sops.yaml
  sops -e -i talos/patches/ms01-c/machine-files-tailscale-secret.sops.yaml
  ```
  **Tripwire (project memory `feedback_sops_cross_repo_cwd.md`)**: if `cwd` straddles two repos at SOPS time, the wrong `.sops.yaml` recipient may be picked up. The presence of `ENC[…]` markers proves encryption, NOT recipient correctness — that's T022's job.
- [ ] T022 [depends on T021] Round-trip decrypt verification — the only check that proves recipient correctness:
  ```sh
  cd /home/beacon/swarm
  for n in a b c; do
    sops -d talos/patches/ms01-${n}/machine-files-tailscale-secret.sops.yaml | grep -q '^.*TS_AUTHKEY=tskey-client-' \
      && echo "ms01-${n}: OK" || echo "ms01-${n}: FAIL"
  done
  ```
  Expected: 3 lines all `OK`. Any FAIL → re-run T021 from inside `/home/beacon/swarm` (NOT `/home/beacon/swarm-01/`) to ensure the swarm cluster age recipient (`age19w3svwspecedu893ges7te9qc5qgj3r5tykpkqrl43f90ndlvg4qant4ej`) is the one used.
- [ ] T023 [depends on T022] Final pre-commit grep for plaintext leakage in the 3 SOPS files:
  ```sh
  cd /home/beacon/swarm
  for n in a b c; do
    grep -L 'ENC\[' talos/patches/ms01-${n}/machine-files-tailscale-secret.sops.yaml \
      && echo "ms01-${n}: PLAINTEXT LEAK" || echo "ms01-${n}: encrypted ok"
  done
  ```
  Expected: 3 lines all `encrypted ok`. Any PLAINTEXT LEAK → STOP and re-run T021. Also `git diff --cached -- 'talos/patches/ms01-*/machine-files-tailscale-secret.sops.yaml' | grep -E '^\+.*tskey-client-'` must return NOTHING (no plaintext OAuth secret in staged diff).
- [ ] T024 [depends on T023] Stage + commit Phase 1+2 manifests as one GPG-signed commit. Stage explicitly (no `git add -A` per the Git Safety Protocol):
  ```sh
  cd /home/beacon/swarm
  git add talos/talconfig.yaml \
          talos/patches/ms01-a/machine-tailscale.yaml \
          talos/patches/ms01-b/machine-tailscale.yaml \
          talos/patches/ms01-c/machine-tailscale.yaml \
          talos/patches/ms01-a/machine-files-tailscale-secret.sops.yaml \
          talos/patches/ms01-b/machine-files-tailscale-secret.sops.yaml \
          talos/patches/ms01-c/machine-files-tailscale-secret.sops.yaml \
          kubernetes/apps/kube-system/coredns/app/helmrelease.yaml
  git commit -m "feat(talos-ii): siderolabs/tailscale subnet router on 3 ms01 nodes"
  ```
  If GPG signing fails (pinentry timeout), STOP and surface the failure — do NOT use `--no-gpg-sign`. The clusterconfig regen (Phase 4) lands as a separate follow-up commit on the same branch.

**Checkpoint**: manifests committed (encrypted secrets, schematic ID swapped, CoreDNS forward block added). Ready for Talos config regen.

---

## Phase 4 — Talos config regen

**Purpose**: regenerate the rendered `clusterconfig/kubernetes-ms01-{a,b,c}.yaml` from `talconfig.yaml` + per-node patches via talhelper. This produces the actual machineconfig that `task talos:upgrade-node` will apply. Diff inspection confirms only tailscale-related fields changed.

- [ ] T025 [depends on T024] Run `cd /home/beacon/swarm && task talos:configure`. This is `talhelper genconfig` per `.taskfiles/talos/Taskfile.yaml` line 9. talhelper SOPS-decrypts each `*.sops.yaml` patch in-memory, merges global + per-node patches, and writes `clusterconfig/kubernetes-ms01-{a,b,c}.yaml`. **Tripwire**: if talhelper errors with "could not decrypt" the round-trip in T022 missed something — STOP and re-verify SOPS recipient.
- [ ] T026 [depends on T025] Verify each rendered config includes the ExtensionServiceConfig + machine.files entries:
  ```sh
  cd /home/beacon/swarm
  for n in a b c; do
    yq 'select(.kind == "ExtensionServiceConfig" and .name == "tailscale") | .environment' clusterconfig/kubernetes-ms01-${n}.yaml
    yq '.machine.files[] | select(.path == "/var/etc/tailscale/auth.env")' clusterconfig/kubernetes-ms01-${n}.yaml
  done
  ```
  Expected per node: 5-key env block (`TS_HOSTNAME` matching the node, `TS_ROUTES`, `TS_EXTRA_ARGS`, `TS_ACCEPT_DNS=false`, `TS_AUTH_ONCE=true`) + a `machine.files` entry containing the cleartext `TS_AUTHKEY=tskey-client-…` (decrypted into the rendered file — this is intentional, the file is `clusterconfig/` which is gitignored at the talhelper level; verify via `git check-ignore clusterconfig/kubernetes-ms01-a.yaml` returning the path).
- [ ] T027 [depends on T026] Diff vs prior to confirm only tailscale-related fields and the `talosImageURL` schematic ID changed:
  ```sh
  cd /home/beacon/swarm
  git diff HEAD~1 -- clusterconfig/ | grep -E '^[+-]' | grep -vE 'tailscale|TS_|installer-secureboot|/var/etc/tailscale|^[+-]{3}|^[+-]\s*$'
  ```
  Expected: no other diff hunks. Any unrelated change (e.g. accidental kubelet bump) is a defect — STOP and reset.
- [ ] T028 [depends on T027] Stage + commit the regenerated clusterconfig as a separate GPG-signed commit:
  ```sh
  cd /home/beacon/swarm
  git add clusterconfig/
  git commit -m "talos(ii): regen clusterconfig for tailscale extension"
  ```
  (talhelper's git workflow puts rendered configs in a separate commit so the manifest commit T024 is reviewable in isolation. If the repo's existing convention bundles them, fold T028 into T024 and skip this task.)

**Checkpoint**: rendered configs ready; per-node ExtensionServiceConfig + machine.files entries verified; ready for rolling upgrade.

---

## Phase 5 — Rolling upgrade (DESTRUCTIVE — node reboots)

**Purpose**: apply the new schematic + per-node tailscale config to all three ms01-* nodes, one at a time, gated by per-node `tailscale status` + smoke-test verification. **One node at a time. Verify between each.** Per FR-012, concurrent upgrades MUST NOT happen. Per SC-010, three planned reboots total — any unplanned reboot is a defect.

**Rollback** (per Q8 / quickstart P8): three-tier ladder — (1) re-pin `5456009e...` schematic + re-roll, (2) `talosctl edit mc` removes ExtensionServiceConfig live, (3) vPro AMT KVM rescue + USB ISO with prior schematic. Any V1/V2/V3 failure on a given node aborts the rollout and triggers tier 1 rollback BEFORE proceeding to the next node.

### ms01-a

- [ ] T029 [US1, US3] [depends on T028] Upgrade ms01-a to the new schematic: `cd /home/beacon/swarm && task talos:upgrade-node IP=172.16.87.201`. This wraps `talosctl upgrade --image factory.talos.dev/installer-secureboot/${NEW_ID}/v1.12.7/installer.tar.gz --nodes 172.16.87.201`. Watch progress in another terminal: `kubectl get nodes -w`. **Tripwire (Plan Risk #1)**: if Secure Boot verification fails the node won't return to `Ready` — escalate to Tier 3 rollback (vPro AMT KVM rescue) immediately. Expected wall-clock: ~3-5 minutes from upgrade start to `Ready`.
- [ ] T030 [US1, US3] [depends on T029] Verify ms01-a is Ready and the extension is registered: `kubectl get node ms01-a` shows `STATUS Ready`; `talosctl get extensions --nodes 172.16.87.201` includes a row for `siderolabs/tailscale`; `talosctl get extensionserviceconfigs tailscale -o yaml --nodes 172.16.87.201 | grep -E '^- TS_'` returns all 5 expected env keys with the ms01-a-specific `TS_HOSTNAME=talos-ii-ms01-a` (per `contracts/extension-service-config.md` validation block).
- [ ] T031 [US1, US3] [depends on T030] V1-partial check from operator laptop: `tailscale status | grep talos-ii-ms01-a` shows `talos-ii-ms01-a online` with `tag:talos-ii-node`; `tailscale status --json | jq '.Peer | to_entries[] | select(.value.HostName == "talos-ii-ms01-a") | .value.PrimaryRoutes'` returns `["10.44.0.0/16","10.55.0.0/16"]`. **Tripwire**: if `PrimaryRoutes` is empty but the device shows online, the OAuth-minted key likely registered without subnet-router permission — check the admin UI Machines tab for "Approve subnet routes" prompt; per `contracts/validation-procedure.md` V1 fail-mode 3, auto-approve was assumed in T005's ACL setup but may need manual click.
- [ ] T032 [US1] [depends on T031] V2/V3 from a pod scheduled on ms01-a (DNS still pre-CoreDNS-reconcile — that lands in Phase 6; this verification can use direct 100.x address resolved from operator laptop's `tailscale status`):
  ```sh
  ATTIC_TS_IP=$(tailscale status --json | jq -r '.Peer | to_entries[] | select(.value.HostName == "attic" or (.value.DNSName | startswith("attic."))) | .value.TailscaleIPs[0]' | head -1)
  kubectl run -n default --rm -it curl-ms01a --image=curlimages/curl --restart=Never \
    --overrides='{"spec":{"nodeName":"ms01-a"}}' -- curl -fsS "http://${ATTIC_TS_IP}/" -o /dev/null && echo OK
  ```
  Expected: `OK`. This proves pod-to-tailnet reachability via ms01-a's local tailscaled (US1 path partial — full DNS-mediated path verified after T040). **Failure**: V2/V3 fail → tier 1 rollback BEFORE T033.
- [ ] T033 [US3] [depends on T032] Verify ms01-b and ms01-c workloads remain unaffected: `kubectl get pods -A -o wide | grep -E 'ms01-b|ms01-c' | grep -vE 'Running|Completed'` returns NOTHING (no Pending, no CrashLoopBackOff). `kubectl top nodes` shows all three nodes within normal ranges.

### ms01-b

- [ ] T034 [US1, US3] [depends on T033] Upgrade ms01-b: `cd /home/beacon/swarm && task talos:upgrade-node IP=172.16.87.202`. Watch `kubectl get nodes -w`.
- [ ] T035 [US1, US3] [depends on T034] Verify ms01-b is Ready + extension registered (same shape as T030, replace `172.16.87.201` with `172.16.87.202` and `ms01-a` with `ms01-b`).
- [ ] T036 [US1, US3] [depends on T035] V1-partial check: `tailscale status | grep -E 'talos-ii-ms01-(a|b)'` shows BOTH ms01-a (still online from T031) AND ms01-b online with tag + routes. Confirms partial HA state (2-of-3 routers).
- [ ] T037 [US1] [depends on T036] V2/V3 from a pod scheduled on ms01-b (same shape as T032 with `nodeName: ms01-b`).
- [ ] T038 [US3] [depends on T037] Verify ms01-c workloads remain unaffected (same as T033, scoped to ms01-c only).

### ms01-c

- [ ] T039 [US1, US3] [depends on T038] Upgrade ms01-c: `cd /home/beacon/swarm && task talos:upgrade-node IP=172.16.87.203`. Watch `kubectl get nodes -w`.
- [ ] T040 [US1, US3] [depends on T039] Verify ms01-c is Ready + extension registered (same shape as T030, with `172.16.87.203` and `ms01-c`).
- [ ] T041 [US1, US3] [depends on T040] V1 full check: `tailscale status | grep -E 'talos-ii-ms01-(a|b|c)'` shows ALL THREE online with `tag:talos-ii-node`. `tailscale status --json | jq '.Peer | to_entries[] | select(.value.Tags // [] | index("tag:talos-ii-node")) | {Name: .value.HostName, Routes: .value.PrimaryRoutes // [], Online: .value.Online}'` returns 3 entries each with `Online: true` AND `Routes: ["10.44.0.0/16","10.55.0.0/16"]` per `contracts/validation-procedure.md` V1.
- [ ] T042 [US1] [depends on T041] V2/V3 from a pod scheduled on ms01-c (same shape as T032 with `nodeName: ms01-c`).

**Checkpoint**: all three nodes upgraded; tailscale status shows 3 routers online with routes active; pre-CoreDNS-reconcile direct-IP path verified per node. Acceptance gate for SC-001 met. Ready for CoreDNS reconcile.

---

## Phase 6 — CoreDNS reconcile + cross-cluster path validation (V2–V5)

**Purpose**: wait for Flux to reconcile the updated CoreDNS HelmRelease, then run the full V1–V5 validation suite from `contracts/validation-procedure.md`. This phase's pass is the acceptance gate for SC-002, SC-003, SC-004, SC-005, SC-006 (US1, US2, US3, US4 verified).

- [ ] T043 [depends on T042] Wait for Flux to reconcile CoreDNS HelmRelease: `kubectl -n flux-system get helmrelease coredns -w` until `READY=True` `STATUS=Helm install/upgrade succeeded`. To force: `flux -n flux-system reconcile hr coredns`. Verify the rendered ConfigMap picks up the new server block: `kubectl get cm -n kube-system coredns -o jsonpath='{.data.Corefile}' | grep -A6 '^ts.net:53'` returns the `forward . 100.100.100.100` line. **Tripwire (Plan Risk #5)**: if instead the operator added `forward ts.net 100.100.100.100` inside the `.` server block (anti-pattern per `contracts/coredns-forward-block.md`), the Corefile will still have one server block — STOP, fix per T020, re-commit, re-reconcile.
- [ ] T044 [US1] [depends on T043] V2 — pod-side DNS resolution per `contracts/validation-procedure.md`: `kubectl run -n default --rm -it dns-test --image=curlimages/curl --restart=Never -- getent hosts attic.tail5d550.ts.net`. Pass: stdout contains a `100.x.y.z` address (CGNAT). Fail-modes: NXDOMAIN → check tailnet hostname; resolves to non-100.x → catch-all `forward .` matched ahead (re-inspect Corefile rendering).
- [ ] T045 [US1] [depends on T044] V3 — pod-side curl: `kubectl run -n default --rm -it curl-test --image=curlimages/curl --restart=Never -- curl -fsS http://attic.tail5d550.ts.net/ -o /dev/null -w 'HTTP %{http_code}\n'`. Pass: HTTP 2xx or 30x. Cross-check from a tailnet client with attic admin access: `kubectl logs -n nix attic-0 --tail 20 | grep '"GET /"'` shows source IP as one of the three subnet-router 100.x addresses (NOT the tailscale-operator proxy IP — that's US4's distinguishing test).
- [ ] T046 [US2] [depends on T045] V4 — tailnet client → Pod IP via subnet router. Pick a known Pod IP on ms01-c with a known HTTP port (CoreDNS metrics 9153 is a reliable choice): `kubectl get pods -A -o wide | grep -m1 ms01-c`. From operator laptop: `curl -fsS http://<pod-ip>:9153/metrics | head -5`. Pass: stdout contains `# HELP coredns_…`. Cross-check: `talosctl logs --nodes 172.16.87.201 --tail 20 -f -k tailscale | grep <pod-ip>` (or .202 / .203 — exactly one of the three nodes' tailscaled logs the inbound). **Tripwire (Plan Risk #4 / spec edge case "rp_filter")**: Talos default is `rp_filter=2` (loose) which permits the asymmetric flow. If a future Talos default flips to strict (1), V4 breaks — flag in the runbook (T049).
- [ ] T047 [US3] [depends on T046] V5 — failover under sustained load. Setup the curl loop (terminal 1) per `contracts/validation-procedure.md`:
  ```sh
  kubectl run -n default -it curl-loop --image=curlimages/curl --restart=Never -- sh -c '
    i=0; fail=0
    while [ $i -lt 600 ]; do
      if curl -sS -m 2 -o /dev/null -w "" http://attic.tail5d550.ts.net/; then :; else fail=$((fail+1)); fi
      i=$((i+1))
      sleep 1
    done
    echo "fails=$fail/600"
  '
  ```
  In terminal 2, reboot each node at staggered times (per quickstart P5 / contracts V5): `task talos:upgrade-node IP=172.16.87.201` at t=30s, `IP=172.16.87.202` at t=180s, `IP=172.16.87.203` at t=330s. **Pass criterion**: final loop output `fails=N/600` with N ≤ 90 (SC-005). **Tripwire (Plan Risk #4)**: any single reboot exceeding 60s individually is a fail — distinguish Talos boot time (≤45s typical) from Tailscale reconvergence (~30s). Note also: rebooting a node restarts CoreDNS if scheduled there, momentarily breaking pod-side DNS — the 30s window is AGGREGATE, not per-component.
- [ ] T048 [US4] [depends on T047] V4-complement / SC-006 — verify tailscale-operator continues to work for per-Service named ingress. Pre-deploy snapshot (taken in T002 if recorded; otherwise compare against operator's reference): `kubectl -n network get statefulsets -l tailscale.com/parent-resource-type=service` lists all `ts-*` proxy StatefulSets — count + Ready state should match pre-deploy. From operator laptop: `tailscale status --json | jq '.Peer | to_entries[] | select(.value.HostName | test("^attic|^forgejo|^zot|^ts-")) | {Name: .value.HostName, Tags: .value.Tags}'` shows operator-managed devices NOT carrying `tag:talos-ii-node` (different identity). Cross-check: `dig @<laptop-tailscale> attic.tail5d550.ts.net +short` returns the **operator proxy's** 100.x address (NOT a router-node 100.x — per spec edge case "Operator doubling: don't mistake this for misconfig").

**Checkpoint**: V1–V5 + V4-complement all green. Acceptance gate met for SC-001..SC-006 + SC-009..SC-010. US1, US2, US3, US4 verified.

---

## Phase 7 — Documentation finalization (Story 5 + Constitution X)

**Purpose**: ship the ADR + runbook + cluster-definition update + factory-doc rewrite + index ToC entries as the same commit chain as the implementation per Constitution Principle X. Per quickstart P7, these can ride after V1–V5 close so the docs reflect actual deployed shape (not aspirational), but they MUST land before the branch merges.

**Operator decision baked in**: ADR `docs/decisions/talos-ii/0014-tailscale-host-extension.md` is **written** (not deferred to a "shared/0002 alone is sufficient" framing). It captures D1 (HA 3-router) / D2 (OAuth+tag) / D3 (advertise PodCIDR + ServiceCIDR) implementation specifics on top of shared/0002's canonical mode decision. Cross-link list per FR-018.

- [ ] T049 [P] Author the ADR at `/home/beacon/swarm/docs/decisions/talos-ii/0014-tailscale-host-extension.md` with sections Status / Context / Decision / Consequences. Cross-link **shared/0002** (mesh integration modes — accepted parent decision), **shared/0003** (talos-i positioning — explains why mesh becomes cluster fabric), **shared/0004** (cluster egress gateway — explains the `route_exclude_address` interaction documented in spec edge cases), **talos-ii/0004** (official factory — extension-catalog basis), **talos-ii/0005** (Secure Boot — schematic submission constraint). Body captures D1 (HA 3-node), D2 (OAuth+tag `tag:talos-ii-node`), D3 (advertise PodCIDR `10.44.0.0/16` + ServiceCIDR `10.55.0.0/16`). Pattern: clone shape from `/home/beacon/swarm/docs/decisions/talos-ii/0013-forgejo-runner-talos-ii.md`. Per FR-018: ADR cross-link list is a hard requirement. **NOTE**: this task creates the file; the ADR body is filled in by the operator in this same commit (NOT pre-written here).
- [ ] T050 [P] Author the operator runbook at `/home/beacon/swarm/docs/operations/talos-ii-tailscale-mesh.md` covering: (a) deploy procedure (Phase 0 OAuth mint, Phase 1 schematic, Phase 2-4 author/encrypt/regen, Phase 5 rolling roll); (b) verify procedure (V1-V5 condensed from `contracts/validation-procedure.md` + the V4-complement operator-vs-extension test); (c) rollback procedure (Tier 1 schematic re-pin / Tier 2 `talosctl edit mc` / Tier 3 vPro AMT KVM rescue per Q8); (d) decommission procedure (revoke OAuth client → remove `tag:talos-ii-node` from ACL → delete patches → submit no-tailscale schematic → re-pin → roll → remove CoreDNS forward block); (e) common debug paths (sing-box `100.64.0.0/10` exclusion absent, `${HOSTNAME}` substitution found in env (per-node hardcode missed), OAuth client rotation procedure, `rp_filter` strict-mode flag). Pattern: clone shape from `/home/beacon/swarm/docs/operations/forgejo-runner.md`. **NOTE**: this task creates the file; runbook body is filled in by operator in this same commit.
- [ ] T051 [P] Update `/home/beacon/swarm/docs/talos-image-factory.md` per FR-003 + data-model.md Entity 6:
  1. **Move** the existing `5456009e...` section to a new `## Historical schematics — talos-ii` heading; add `**Status:** superseded by ${NEW_ID} on YYYY-MM-DD` line.
  2. **Create** new `## Active schematic — ${NEW_ID}` section above with full structure (factory URL, schematic YAML showing all 4 extensions including `siderolabs/tailscale`, "Why each extension" table).
  3. **Add** the `siderolabs/tailscale` row to the "Why each extension" table: `reason: subnet router for cross-cluster mesh fabric per shared/0002 Option C; OAuth client + tag:talos-ii-node identity` and `drop-when: when mesh control plane changes (re-evaluate)`.
  4. **REMOVE** (do not just edit) the `siderolabs/tailscale` row from the "What is NOT in this schematic" / negative-extensions table at line ~87 — that row is now wrong per Constitution v1.2.0 / shared/0002.
  5. **Rewrite** the "Tailscale: host extension vs in-cluster operator" footnote (line ~135) to reflect that BOTH are now in use complementarily — operator for per-Service named ingress, extension for cluster-fabric subnet routing — with cross-link to shared/0002. Replace the "We use only the in-cluster operator … The host extension is rejected for talos-ii" sentence with the complementarity framing.
  **Tripwire (data-model.md cross-entity invariant 1)**: schematic ID consistency check: `grep -F "${NEW_ID}" talos/talconfig.yaml docs/talos-image-factory.md | wc -l` returns `4` (3 in talconfig + 1 active section header in docs).
- [ ] T052 [P] Update `/home/beacon/swarm/docs/cluster-definition.md` per FR-017:
  1. Update the "Schematic ID" row in the talos-ii Operating-system section (line ~70) from `5456009e...` to `${NEW_ID}` with link to the new active section in `talos-image-factory.md`.
  2. Under the talos-ii "Cluster networking & ingress" section, add a line: `tag:talos-ii-node` — Tailscale identity for all three ms01-* nodes (subnet router advertising PodCIDR `10.44.0.0/16` + ServiceCIDR `10.55.0.0/16`); see [ADR talos-ii/0014](decisions/talos-ii/0014-tailscale-host-extension.md).
- [ ] T053 [P] Update `/home/beacon/swarm/docs/index.md` ToC entries: add ADR 0014 entry under "Decisions → talos-ii" pointing at `decisions/talos-ii/0014-tailscale-host-extension.md`; add the runbook entry under "Operations" pointing at `operations/talos-ii-tailscale-mesh.md`.
- [ ] T054 [depends on T049, T050, T051, T052, T053] Final commit chain: stage T049-T053 as ONE GPG-signed commit. Message: `docs(talos-ii-mesh): ADR 0014 + runbook + factory + cluster-definition + index (Phase 7 close)`. Per Constitution X / FR-031 these MUST land in the same commit chain as the implementation; the chain is T024 (manifests) + T028 (clusterconfig regen) + T054 (docs).
- [ ] T055 [depends on T054] Push branch + open PR (or fast-merge per operator preference per the spec 003 precedent). `cd /home/beacon/swarm && git push origin 004-talos-ii-mesh-implementation`. Title: `feat(talos-ii): siderolabs/tailscale + 3-node subnet router (mesh fabric)`. Body cites spec.md / plan.md / shared/0002.

**Checkpoint**: Constitution X satisfied; production deployed AND documented; PR open or merged.

---

## Phase 8 — Post-acceptance observation (US5, deferred)

**Purpose**: User Story 5 (ephemeral device hygiene) is operational/long-running and is NOT a blocking acceptance gate. T056 documents the observation procedure; the operator runs it on convenience over the following days/weeks and updates the runbook with findings if anomalies surface.

- [ ] T056 [US5] Observe Tailscale admin device list over the next 72 hours of normal operation: after the rolling-upgrade reboots in T029/T034/T039, verify in the Tailscale admin UI that no stale `Expired` devices for talos-ii linger beyond the ~5min ephemeral session timeout. Steady-state count for `tag:talos-ii-node` should be exactly 3. If a stale device persists (admin UI shows `Expired` rows for talos-ii-ms01-* not auto-pruned), file an issue against `siderolabs/tailscale` extension and document workaround in the runbook (T050) — operator-side delete is the workaround. Per spec SC-005's User Story 5 "operational hygiene, not functional correctness" framing, T056 is deferred-observation not a blocking acceptance gate.

**Checkpoint**: Story 5 is observation-only; no action required if devices auto-prune as expected.

---

## Deferred / out-of-scope (NOT in this tasks.md)

These are intentionally NOT in the checkbox list above. They are tracked separately and will land via their own spec / commit chain.

- **Cross-cluster ACL between `tag:talos-ii-node` and `tag:talos-i-node`**: gated on talos-i adoption per shared/0003. The talos-i analog spec (future) declares its own tag and adds the ACL rule pair in the same change.
- **Migration to a self-hosted tailnet control plane (Headscale / NetBird)**: per shared/0003 sub-decision (2), implementation lives in `/etc/nixos`, not this repo. Structurally compatible — OAuth-client-based registration works against both SaaS and self-hosted control planes.
- **`tailscale serve` on subnet-router nodes** as an alternative to per-Service operator ingress: listed in shared/0002's "Open questions deferred". Not decided here. Operator stays the per-Service ingress mechanism.
- **NetworkPolicy default-deny rollout** with explicit `100.64.0.0/10` carve-out: not in scope; flagged for future awareness in spec assumptions.
- **Removal of in-cluster `tailscale-operator`**: out of scope per FR-019. Both layers stay per Constitution §VII v1.2.0.
- **Constitution §VII rewrite**: §VII v1.2.0 (already merged in commit `f695b84`) formalizes operator + extension complementarity. FR-021 is satisfied by virtue of v1.2.0 already covering the case; no further amendment needed in this spec's chain.
- **`siderolabs/binfmt-misc` cross-arch CI extension**: separately tracked; out of scope here.
- **OAuth client_secret rotation drill**: rotation procedure documented in T050 runbook but not exercised in this spec. Triggered on detected leak only.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 0 (Pre-flight)**: T001..T006. T001..T004 are independent reads; T005 (OAuth mint) is the manual one-shot that gates T015..T017. T006 is independent (laptop tailnet check).
- **Phase 1 (Schematic generation)**: T007..T009. T007 is the manual factory submission; T008 is the URL sanity check (depends on T007); T009 is operator-notes capture (depends on T007).
- **Phase 2 (Author manifests)**: T010..T020. T010 (talconfig.yaml ID swap) is independent of the per-node patch authoring (T011..T017). T018 wires per-node patches into talconfig.yaml — depends on T012..T017 having pinned filenames. T019 is a sanity check on `.sops.yaml` rule coverage. T020 (CoreDNS) is independent of all the talos changes.
- **Phase 3 (Encrypt + commit)**: T021..T024 — strictly sequential. T022 round-trip MUST pass before T023 grep before T024 commit.
- **Phase 4 (Talos config regen)**: T025..T028 — depends on T024. T026 verification gates T027 diff check gates T028 commit.
- **Phase 5 (Rolling upgrade)**: T029..T042 — strictly sequential per FR-012 (one node at a time). T029→T030→T031→T032→T033 for ms01-a; T034→T035→T036→T037→T038 for ms01-b; T039→T040→T041→T042 for ms01-c. Each node's V1-partial check must pass before proceeding.
- **Phase 6 (CoreDNS reconcile + V1-V5)**: T043..T048 — depends on T042 (last node up). T043 (Flux reconcile) gates T044 (V2 DNS) gates T045 (V3 curl) gates T046 (V4 laptop→pod) gates T047 (V5 failover). T048 (V4-complement / US4) can run in parallel with T046.
- **Phase 7 (Documentation)**: T049..T055 — depends on T048 (acceptance gate green). T049..T053 are file-disjoint (different doc files), parallel. T054 commits them; T055 pushes/PRs.
- **Phase 8 (Observation)**: T056 — deferred-observation, runs over hours/days after T055. Not a blocking gate.

### Within Each Phase

- **Phase 0**: T001 + T002 + T003 + T004 + T006 run in parallel (one bash session per check). T005 is manual + serial.
- **Phase 2**: T011 (mkdir) precedes T012..T017 (file authoring); T012..T017 are file-disjoint and `[P]`-able. T018 depends on T012..T017 completing. T019 + T020 are independent sanity/edit tasks.
- **Phase 5**: strict serial — node-at-a-time per FR-012; no `[P]` markers.
- **Phase 7**: T049, T050, T051, T052, T053 are file-disjoint and `[P]`-able; T054 collects + commits; T055 pushes.

### Parallel Opportunities

- **Phase 0**: 5 of 6 tasks runnable in parallel (T001, T002, T003, T004, T006); T005 is the manual gate.
- **Phase 2**: 7 of 11 tasks marked `[P]` (T012, T013, T014, T015, T016, T017, T019, T020) — different files, no inter-dependencies.
- **Phase 7**: 5 of 7 tasks marked `[P]` (T049, T050, T051, T052, T053) — different doc files.

---

## Tripwires (consolidated, per plan.md §Risks + cross-cutting findings)

Surfaced inline above near the relevant tasks; recapped here for runbook reference.

- **`${HOSTNAME}` substitution NOT used** (T012, T013, T014): per-node patches each have hardcoded `TS_HOSTNAME=ms01-X` (operator decision — skip the canary, go per-node from the start). Plan Risk #3 fallback path is taken upfront.
- **SOPS recipient correctness** (T021, T022): round-trip decrypt is the only check that proves recipient match (project memory `feedback_sops_cross_repo_cwd.md`); ENC[…] markers prove encryption only. Run `sops -e -i` from inside `/home/beacon/swarm` to avoid cross-repo `.sops.yaml` confusion.
- **Schematic Secure Boot signing** (T007, T029): new schematic must be signed by the same key bundle (factory parameter `secureboot=true` selects the well-known sidero bundle). UEFI refuses boot if signature mismatches; Tier 3 rollback (vPro AMT KVM rescue) needed. Verified by the fact that current `5456009e...` boots — but first node upgrade (T029) is the canary.
- **Tailscale subnet router HA = primary-with-failover** (T031, T036, T041, T047): NOT load-balance (per Plan Q5). Only one node serves a given tailnet→pod packet at a time; reconvergence on heartbeat timeout (~30s default).
- **CoreDNS forward block lands as NEW server entry** (T020, T043): NOT as a plugin in the existing `.` server. Per Plan Risk #5 / Q2; chart compiles each `servers[]` entry into a separate Corefile server block, longest-zone-match wins.
- **Per-node tailscale config drift** (T011..T017, T056): 3 near-duplicate files. If a 4th node is later added, must remember to clone + edit the per-node patches — no global patch shortcut. Also `talconfig.yaml` `nodes[].patches:` block needs the new entry per node.
- **OAuth client_secret leakage scope** (T005, T015..T017, T024): secret embedded in the SOPS-encrypted machine-files patch. Node-level disk encryption (TPM, talconfig.yaml lines 64-77) is the only protection at rest on-node. Rotation procedure: revoke client in admin UI → mint new → re-encrypt + re-deploy all 3 nodes (~10 min operator time, no service impact since existing ephemeral keys keep working until they expire ~5 min after node next reboots).
- **Schematic ID propagation** (T010, T029, T051): `docs/talos-image-factory.md` is "trust this file" per its own preamble; if the file disagrees with `talconfig.yaml` after this work, fix `talconfig.yaml` not the doc. Cross-entity invariant 1 lint: `grep -F "${NEW_ID}" talos/talconfig.yaml docs/talos-image-factory.md | wc -l` returns 4.
- **sing-box `100.64.0.0/10` exclusion** (T003): verified-already in `/etc/nixos modules/common/sing-box.nix`; T003 is a runtime audit step against the live pod's rendered config. No `/etc/nixos` change is part of this spec; if absent, BLOCK and patch nixos source first.
- **OAuth + ephemeral key + Talos clock skew** (spec edge case, runbook in T050): OAuth-minted ephemeral keys have a short TTL; if a node's clock is skewed by more than the TTL (NTP fails on first boot), authentication fails. Talos has chrony built-in; if `tailscaled` won't start post-T029, check `talosctl logs --nodes <ip> -f -k chrony` for NTP sync.
- **`rp_filter` reverse-path** (T046, runbook in T050): Talos default is `2` (loose) which permits the asymmetric tailnet→pod flow. If a future Talos default flips to strict (1), V4 breaks — flag in runbook.
- **kube-proxy / Cilium-kube-proxy-replacement** (T001, T046): the tailnet→pod entry hop relies on kube-proxy DNAT (or Cilium's replacement) on the entry node. Cilium-kube-proxy-replacement = true is verified in T001.

---

## Notes

- `[P]` tasks = different files / independent cluster reads, no dependencies on incomplete tasks.
- `[USx]` label maps tasks to spec.md user stories: US1 (pod-to-tailnet outbound), US2 (tailnet-to-pod inbound), US3 (HA single-node-fail), US4 (operator + extension complementarity), US5 (ephemeral device hygiene — observation only).
- All paths absolute under `/home/beacon/swarm/` — there is NO edit under `/home/beacon/swarm-01/` for this feature (talos-i adoption is the separate work tracked under shared/0003).
- The cross-cluster ACL between `tag:talos-ii-node` and `tag:talos-i-node` is deferred to talos-i adoption per FR-005 + Out of Scope.
- Commit chain per Constitution X: T024 (manifests) → T028 (clusterconfig regen) → T054 (docs) — three GPG-signed commits on `004-talos-ii-mesh-implementation`.
- Stop at Phase 5 per-node V1/V2/V3 gates to validate before proceeding to next node; rollback (Q8 Tier 1) is mechanical and reversible.
- Avoid: editing the same file from parallel `[P]` tasks (none of the `[P]` markers above pair on the same file by design).
