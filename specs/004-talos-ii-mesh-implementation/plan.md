# Implementation Plan: talos-ii mesh — `siderolabs/tailscale` + 3-node subnet router

**Branch**: `004-talos-ii-mesh-implementation` | **Date**: 2026-05-04 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/004-talos-ii-mesh-implementation/spec.md`

## Summary

Land ADR `shared/0002` Option C on talos-ii by adding the official `siderolabs/tailscale` system extension to the Talos image factory schematic for all three `ms01-*` nodes. Each node runs `tailscaled` in the host network namespace under the `siderolabs/tailscale` extension service (which is a thin wrapper around upstream `containerboot`), authenticates to the tailnet using a single Tailscale OAuth client (`auth_keys:write` + owner `tag:talos-ii-node`) that mints a short-lived ephemeral key on every boot, and advertises subnet routes for PodCIDR `10.44.0.0/16` and ServiceCIDR `10.55.0.0/16`. All three nodes advertise the same routes; Tailscale's subnet-router redundancy gives HA without coordination. CoreDNS gets a `ts.net:53 → 100.100.100.100` forward block so pods resolve `*.tail5d550.ts.net` directly.

Implementation is a rolling Talos schematic upgrade — three planned reboots, one node at a time, gated by per-node `tailscale status` + smoke-test verification. The change is reversible by re-pinning the prior schematic ID `5456009e...`. No Constitution amendment is needed because §VII v1.2.0 (ratified 2026-05-04, separate commit) already formalizes the operator + subnet-router two-tier model. The existing in-cluster `tailscale-operator` keeps doing per-Service named ingress untouched.

## Technical Context

**Workload type**: Talos host-level system extension (`siderolabs/tailscale`) on three bare-metal control-plane nodes. Cluster-side change is one CoreDNS HelmRelease values diff. No new Pod, no new namespace, no new Service.
**Talos version**: `v1.12.7` (`talos/talenv.yaml`, unchanged).
**Kubernetes version**: pinned in `talos/talenv.yaml` (unchanged).
**Bootloader / Secure Boot**: `sd-boot` + `secureboot=true`. Both factory parameters are preserved on the new schematic; the resulting schematic ID is a new SHA256 distinct from `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`.
**Schematic delta**: existing extensions `siderolabs/intel-ucode`, `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools` plus added `siderolabs/tailscale`.
**Schematic ID hardcoded sites**: `talos/talconfig.yaml` lines 33, 83, 133 (one per node `talosImageURL`). All three swap to the new ID in the same commit.
**Extension config channel**: Talos `ExtensionServiceConfig` document, `name: tailscale`, plus an environment-overrides file at `/var/etc/tailscale/auth.env` written via `machine.files` from a SOPS-encrypted patch (per upstream README: "Extra tailscale specific environment vars can be configured as needed in `/var/etc/tailscale/auth.env`").
**Auth wire format**: `TS_AUTHKEY=<oauth_client_secret>?ephemeral=true&preauthorized=true`. Tailscale OAuth client secrets begin `tskey-client-<id>-<rand>`; passing the secret directly to `tailscale up --auth-key` (which is what `containerboot` does internally) auto-mints a tagged short-lived key. URL-style query suffix is the documented OAuth wire format per Tailscale KB 1215.
**Tag**: `tag:talos-ii-node`. Owned by the OAuth client.
**Routes advertised**: `10.44.0.0/16,10.55.0.0/16` per spec D3.
**Hostname pattern**: `talos-ii-${HOSTNAME}` → `talos-ii-ms01-a`, `talos-ii-ms01-b`, `talos-ii-ms01-c` (Q5 decision; see research.md).
**CoreDNS source-of-truth**: HelmRelease values stanza at `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml` (`spec.values.servers[]`). The chart converts the structured `servers/zones/plugins` shape into a Corefile. The `ts.net:53` block lands as a NEW `servers` entry (not a Corefile-string append). Plugin-order-within-block is N/A because `ts.net:53` is its own server block.
**Constitution version**: 1.2.0 (ratified 2026-05-05). §VII rewrite already formalizes operator + extension complementarity. This spec does NOT propose any further amendment.
**Per-cluster scope**: `[talos-ii]` only. Zero touch to talos-i / `swarm-01`.
**Reversibility**: re-pin prior schematic ID `5456009e...` in `talos/talconfig.yaml`; `task talos:upgrade-node` per node restores prior boot. Tailscale device records orphan (cleanup is one operator-deletion in admin UI; ephemeral keys auto-expire ~5 min).

## Constitution Check

Cross-checked against [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) **v1.2.0**:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] — bare metal, no nesting | PASS | No hypervisor surface; Talos still runs directly on MS-01. |
| **II. Storage** [both] — Longhorn only | N/A | No storage component. |
| **III. Network** [talos-ii] — Cilium, no overlay at host layer | PASS | Cilium remains the in-cluster CNI for `10.44.0.0/16` / `10.55.0.0/16`. The host `tailscaled` runs in the host network namespace and owns its own TUN (`tailscale0`); it does NOT replace Cilium's BPF datapath. Pod-to-tailnet packets traverse pod → cluster default route → host net ns → kernel route table picks `tailscale0` for `100.64.0.0/10` and the advertised tailnet routes; non-tailnet pod traffic is unchanged. Bond / VLAN 87 underlay untouched. |
| **IV. Image factory** [talos-ii] — official factory only | PASS | `siderolabs/tailscale` is in the **official sidero catalog** (per ADR talos-ii/0004 the official factory and its catalog are permitted; only custom extensions are forbidden on talos-ii). FR-001 keeps `factory.talos.dev` as the source. The stale "rejected for talos-ii" footnote in `docs/talos-image-factory.md` is rewritten in the same commit chain (FR-003) — that's the schematic-transparency obligation. |
| **V. Secrets** [both] — age, gitignored private key | PASS | OAuth client_id + client_secret SOPS-encrypted into `talos/patches/global/machine-files-tailscale-secret.sops.yaml` using the talos-rule recipient at `.sops.yaml`. No plaintext at rest. Decryption flows through `talhelper genconfig` (which wraps `sops -d` over each `*.sops.*` patch before merging) so the rendered machineconfig sent to the node has the cleartext only at apply time. |
| **VI. Public exposure** [both] | N/A | Nothing publicly exposed. Tailscale tailnet membership is a private-LAN/cross-cluster facility, not public. |
| **VII. Private exposure** [both] — operator + subnet-router two-tier (v1.2.0) | PASS | Constitution §VII v1.2.0 explicitly authorizes the host extension as the cross-cluster mesh + node-level egress complement to the per-Service operator. FR-019 keeps the operator running unchanged; this spec is purely additive. No §VII rewrite is required (FR-021 is satisfied by virtue of v1.2.0 already covering the case). |
| **VIII. GitOps** [both] | PASS | `talconfig.yaml` change reconciled via `task talos:upgrade-node` (existing flow). CoreDNS HelmRelease values change reconciled by Flux. SOPS-encrypted OAuth credentials committed alongside the patch. |
| **IX. Spec-Driven Development** [both] | PASS | This Plan + spec.md are the artifacts. |
| **X. Documentation** [both] | PASS-by-requirement | FR-003 (factory doc), FR-017 (ADR `talos-ii/0014` + runbook + cluster-definition), FR-018 (cross-links) all mandate doc updates in the same commit chain. The optional `talos-ii/0014-tailscale-host-extension.md` ADR is the recommended path — see Project Structure note below. |
| **XI. No surprise reboots / destructive shortcuts** [both] | PASS | Three planned reboots, one node at a time, runbook-tracked (FR-012, FR-013, FR-016). SC-010 enforces zero unplanned reboots. Rollback re-pins the prior schematic ID and re-rolls. Reversible by construction. |
| **Per-cluster scoping** | PASS | Spec Scope `[talos-ii]` only; FR-020 forbids talos-i / `swarm-01` touches. Future talos-i adoption is a separate spec under shared/0003. |

**Result: PASS — no Constitution violations. No Complexity Tracking entries required.**

## Project Structure

### Documentation (this feature)

```text
specs/004-talos-ii-mesh-implementation/
├── plan.md                                      # This file
├── research.md                                  # Phase 0 — Q1-Q8 resolutions
├── data-model.md                                # Phase 1 — entity shapes (schematic delta, ExtensionServiceConfig, OAuth secret, CoreDNS forward block)
├── quickstart.md                                # Phase 1 — operator runbook (pre-flight → schematic → roll → validate → docs)
├── contracts/
│   ├── extension-service-config.md              # Phase 1 — Talos ExtensionServiceConfig YAML contract
│   ├── coredns-forward-block.md                 # Phase 1 — CoreDNS HelmRelease values diff contract
│   └── validation-procedure.md                  # Phase 1 — FR-015 verifications as machine-readable contracts
└── tasks.md                                     # Phase 2 — written by /tasks (NOT by /plan)
```

### Source code / repo layout (impacted areas)

```text
talos/
├── talconfig.yaml                                                       # MODIFIED — three schematic-ID hardcodes (lines 33, 83, 133) swap from 5456009e... to <new-schematic-id>
└── patches/
    └── global/
        ├── machine-tailscale.yaml                                       # NEW — ExtensionServiceConfig document for `tailscale` extension
        └── machine-files-tailscale-secret.sops.yaml                     # NEW — `machine.files` patch dropping /var/etc/tailscale/auth.env (SOPS-encrypted; talos rule = whole-file mac_only_encrypted)

kubernetes/
└── apps/
    └── kube-system/
        └── coredns/
            └── app/
                └── helmrelease.yaml                                     # MODIFIED — add second servers[] entry for ts.net:53 → 100.100.100.100

docs/
├── talos-image-factory.md                                               # MODIFIED — (a) move 5456009e... section to "Historical schematics — talos-ii" with supersession date, (b) create new active section with new ID + tailscale in extension list, (c) update "Why each extension" table with siderolabs/tailscale row, (d) rewrite "Tailscale: host extension vs in-cluster operator" footnote to reflect both-in-use complementarity, (e) drop the "rejected" row in the negative-extensions table referencing the old anti-pattern stance
├── decisions/
│   └── talos-ii/
│       └── 0014-tailscale-host-extension.md                             # NEW (RECOMMENDED) — talos-ii-specific ADR cross-linking shared/0002, shared/0003, shared/0004, talos-ii/0004, talos-ii/0005; documenting D1/D2/D3 implementation choices
├── operations/
│   └── talos-ii-tailscale-mesh.md                                       # NEW — operator runbook (deploy / verify / rollback / decommission); content sourced from quickstart.md
├── cluster-definition.md                                                # MODIFIED — record `tag:talos-ii-node` identity and node-level Tailscale capability under talos-ii section
└── index.md                                                             # MODIFIED — add ADR 0014 entry to the talos-ii decisions list (if the index uses one)
```

**Structure Decision**: This is a Talos OS / cluster-fabric change, not an application deploy. The diff lives primarily under `talos/` (schematic + machine-config patches) with one cluster-side touch (`kubernetes/apps/kube-system/coredns/`). Documentation lands under `docs/` per Constitution §X. ADR 0014 is the next sequential talos-ii ADR slot (last is 0013-forgejo-runner-talos-ii). The optional ADR is recommended (not skipped) because the OAuth-mint mechanism, the HA-3-router topology, and the hostname pattern are talos-ii-specific implementation choices that future operators (and the inevitable talos-i analog spec) will reference.

## Phase 0 — Research (Q1–Q8 resolutions)

Full text in [research.md](./research.md). Summary table:

| Q | Topic | Decision |
|---|---|---|
| Q1 | `ExtensionServiceConfig` YAML shape | Single ExtensionServiceConfig doc with `name: tailscale` + minimal env (`TS_AUTHKEY`, `TS_HOSTNAME`, `TS_ROUTES`, `TS_EXTRA_ARGS`, `TS_ACCEPT_DNS=false`, `TS_AUTH_ONCE=true`). OAuth credentials wired via `TS_AUTHKEY` containing the OAuth secret + `?ephemeral=true&preauthorized=true` URL params. Secret material delivered via `machine.files` writing `/var/etc/tailscale/auth.env` (SOPS-encrypted whole-file). |
| Q2 | CoreDNS source-of-truth | HelmRelease values at `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`. Add a second `servers[]` entry (the chart compiles to Corefile). NOT a raw ConfigMap edit. |
| Q3 | sing-box `route_exclude_address` audit | Sing-box config is rendered from `/etc/nixos` via `sops.templates`; per parent context the `route_exclude_address` list there already contains `100.64.0.0/10`. In-repo HelmRelease comments mention `geoip-private + geoip-cn` (RFC1918 + CN), which does NOT include CGNAT — the explicit `100.64.0.0/10` line is in the Nix source, not visible in the HelmRelease. **Plan-stage action**: pre-flight verification step in quickstart re-confirms by reading the rendered config inside the running pod (`tailscale-mesh-deploy` runbook step P1). No code change required if confirmed. |
| Q4 | Cross-cluster ACL `tag:talos-ii-node` ↔ `tag:talos-i-node` | **Deferred** to talos-i adoption (shared/0003). This spec only declares `tag:talos-ii-node` and grants subnet-router permission for it (FR-005). |
| Q5 | HA semantics — 3 nodes advertising same routes | Tailscale subnet-router redundancy: when multiple devices advertise overlapping routes, the control plane selects one as the **primary** for each destination (deterministic per dst, not load-balanced). On primary failure (heartbeat timeout, default ~30s), reconvergence picks one of the remaining advertising routers. Behavior is documented and standard. Hostname pattern `talos-ii-${HOSTNAME}` makes the three devices distinguishable in admin UI. |
| Q6 | `ExtensionServiceConfig` placement precedence | Place as a global Talos patch at `talos/patches/global/machine-tailscale.yaml` so all three nodes get identical config. talhelper merges global patches into every node's machineconfig. ExtensionServiceConfig is a separate document (not a `machine.*` field) — talhelper passes through extra documents transparently. |
| Q7 | Subnet-router opt-in scope | All three nodes are subnet routers (HA decision per spec D1). The global patch applies uniformly; no per-node override. If a future operator wants to opt one node out, `talos/patches/<node>/machine-tailscale-noroute.yaml` would override `TS_ROUTES=` to empty — not in scope here. |
| Q8 | Rollback path | Two layers: (a) **Talos schematic rollback**: re-pin `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4` in `talos/talconfig.yaml`, run `task talos:upgrade-node IP=...` per node. Installer image is content-addressable so re-flash is mechanical. (b) **Bad config recovery**: if a node's `tailscaled` config is broken but the node boots, `talosctl edit mc` removes the ExtensionServiceConfig + machine-files entry and reboots into a working state without the extension. (c) **Catastrophic boot failure**: `talosctl reset --graceful=false --reboot` (per parent guidance) brings the node back without applying the broken config; node is then re-flashed with prior schematic. Tailscale device cleanup is operator-side (admin UI), low-stakes; ephemeral keys auto-expire. |

## Phase 1 — Design & Contracts

Full text in [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md). Summary of the four critical contracts:

### 1. Talos schematic delta (factory.talos.dev YAML)

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
      - siderolabs/tailscale          # NEW
  bootloader: sd-boot
# secureboot=true preserved as factory parameter (not a YAML field).
```

Submitted to https://factory.talos.dev/ with `secureboot=true&bootloader=sd-boot&platform=metal&target=metal&arch=amd64&version=1.12.7`. Yields a new SHA256 ID. The new ID replaces `5456009e...` in `talos/talconfig.yaml` at three sites (lines 33, 83, 133).

### 2. `ExtensionServiceConfig` for tailscale (`talos/patches/global/machine-tailscale.yaml`)

```yaml
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_HOSTNAME=talos-ii-${HOSTNAME}
  - TS_ROUTES=10.44.0.0/16,10.55.0.0/16
  - TS_EXTRA_ARGS=--advertise-tags=tag:talos-ii-node --accept-routes
  - TS_ACCEPT_DNS=false
  - TS_AUTH_ONCE=true
# Note: TS_AUTHKEY is NOT here — it lives in /var/etc/tailscale/auth.env
# (machine-files-tailscale-secret.sops.yaml). Containerboot reads both and merges.
```

Notes:
- `TS_HOSTNAME` uses Talos's environment substitution syntax (`${HOSTNAME}` is provided by Talos); yields `talos-ii-ms01-a`, `talos-ii-ms01-b`, `talos-ii-ms01-c`. (If substitution is not supported in this scope, the fallback is one ExtensionServiceConfig per node — Q5/Q6 plan-stage decision is to attempt `${HOSTNAME}` first; quickstart's P3 verifies and falls back if needed.)
- `TS_ACCEPT_DNS=false` is **deliberate** — we do not want each node's `/etc/resolv.conf` rewritten by tailscaled; cluster DNS continues to be served by CoreDNS via the kubelet path. The `ts.net:53` resolution path uses CoreDNS forward, NOT host-level Magic DNS.
- `--accept-routes` is included so that once talos-i adopts and advertises its `10.42.0.0/16` / `10.43.0.0/16`, the talos-ii nodes pick those up automatically (no per-node config change at adoption time).
- `--advertise-tags=tag:talos-ii-node` is mandatory for OAuth-minted keys (Tailscale rejects un-tagged OAuth registrations).

### 3. OAuth credential SOPS file (`talos/patches/global/machine-files-tailscale-secret.sops.yaml`)

Pre-encryption shape:

```yaml
---
machine:
  files:
    - op: create
      path: /var/etc/tailscale/auth.env
      permissions: 0o600
      content: |
        TS_AUTHKEY=tskey-client-<oauth_client_id>-<oauth_client_secret>?ephemeral=true&preauthorized=true
```

Post-encryption: whole-file encrypted via SOPS using the `talos/.*\.sops\.ya?ml` rule from `.sops.yaml` (`mac_only_encrypted: true`, age recipient `age19w3svwspecedu893ges7te9qc5qgj3r5tykpkqrl43f90ndlvg4qant4ej`). The `talos` rule is whole-file (`encrypted_regex` not set), unlike `bootstrap|kubernetes` which is `data|stringData`-only. talhelper picks up the `*.sops.*` filename and decrypts before rendering machineconfig.

OAuth client mint procedure: Tailscale admin console → Settings → OAuth clients → "Generate OAuth client" with scope `auth_keys:write` and tag `tag:talos-ii-node` and no expiry. Copy the secret immediately (only shown once). Paste into the cleartext file above, then `sops -e -i` to encrypt in place.

### 4. CoreDNS forward block (`kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`)

Diff:

```yaml
    servers:
      - zones:
          - zone: .
            scheme: dns://
            use_tcp: true
        port: 53
        plugins:
          - name: errors
          # ... existing chain unchanged ...
          - name: log
            configBlock: |-
              class error
      # NEW SERVER BLOCK
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

The chart compiles each `servers[]` entry into a separate Corefile server block. CoreDNS evaluates server blocks by zone match, so `*.ts.net` queries match the new block before the catch-all `.` block — there is no plugin-order-within-block question because they are different blocks.

### 5. Validation contracts (machine-readable)

[contracts/validation-procedure.md](./contracts/validation-procedure.md) restates FR-015 as five gated steps with explicit pass/fail predicates. Summary:

| Step | Command | Pass criterion |
|---|---|---|
| V1 | `tailscale status` (from operator laptop) | Three devices `talos-ii-ms01-{a,b,c}` online with `tag:talos-ii-node`; route advertisement `10.44.0.0/16,10.55.0.0/16`; subnet-route status `active` |
| V2 | `kubectl run -n default --rm -it curl-test --image=curlimages/curl -- getent hosts attic.tail5d550.ts.net` | resolves to a 100.x address |
| V3 | (same pod) `curl -fsS http://attic.tail5d550.ts.net/` | HTTP 2xx; attic-side log shows source as one of the three router 100.x addresses |
| V4 | (from operator laptop) `curl -fsS http://<pod-ip-on-ms01-c>:<port>/` | pod's response body; `tcpdump` on entry-node tailscale0 shows the SYN |
| V5 | reboot `ms01-a`, `ms01-b`, `ms01-c` one at a time with sustained curl loop | each reboot disrupts loop ≤ 30 s before resuming via remaining routers |

## Quickstart

Full operator playbook in [quickstart.md](./quickstart.md). Phase summary:

**P0 — Pre-flight (manual, one-time)**:
1. Tailscale admin console: declare `tag:talos-ii-node` in ACL JSON if not already; mint OAuth client (scope `auth_keys:write`, owner `tag:talos-ii-node`, no expiry); copy secret.
2. Verify operator laptop is enrolled in tailnet `tail5d550.ts.net` and route-accept is enabled.
3. Read existing sing-box pod's rendered config (`kubectl exec -n network ds/sing-box -- cat /etc/sing-box/config.json | jq '.route.rules[] | select(.action==\"route_exclude\")'`); confirm `100.64.0.0/10` is in the exclude set. Per Q3, this is expected from the /etc/nixos source. If absent, BLOCK and fix /etc/nixos source first.

**P1 — Schematic generation**:
4. Submit new schematic to https://factory.talos.dev/ with extensions list including `siderolabs/tailscale` and `secureboot=true`. Capture new schematic ID.

**P2 — Manifest authoring**:
5. Update `talos/talconfig.yaml` — replace `5456009e...` with new ID at lines 33, 83, 133.
6. Create `talos/patches/global/machine-tailscale.yaml` (Phase 1 §2 contract).
7. Create cleartext `talos/patches/global/machine-files-tailscale-secret.yaml` with OAuth-secret-bearing auth.env content; rename to `.sops.yaml` and `sops -e -i` to encrypt in place. Round-trip-decrypt and confirm `ENC[…]` ≠ readable plaintext.
8. Update `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml` — append the `ts.net:53` `servers[]` entry.

**P3 — Talos config regen + commit**:
9. `task talos:gen-config` (or whatever the repo's regen target is — verify Taskfile).
10. Commit per the message in this plan's footer. SOPS-encrypted file is committed alongside.

**P4 — Rolling upgrade**:
11. `task talos:upgrade-node IP=172.16.87.201` (ms01-a). Wait for `Ready`. `tailscale status` from laptop shows ms01-a online with tag + routes. V2/V3 from a pod scheduled on ms01-a succeed.
12. Repeat for `IP=172.16.87.202` (ms01-b). Verify ms01-b online and prior verification still passes.
13. Repeat for `IP=172.16.87.203` (ms01-c).

**P5 — CoreDNS reconcile + validation**:
14. Flux reconciles CoreDNS HelmRelease (or `flux reconcile ks kube-system` to force). Verify pod resolves `attic.tail5d550.ts.net` (V2).
15. Run V1–V5 end-to-end. Any failure → P6 rollback.

**P6 — Documentation**:
16. Update `docs/talos-image-factory.md` (move historical, update active, fix footnote, fix "rejected" row).
17. Write ADR `docs/decisions/talos-ii/0014-tailscale-host-extension.md` with cross-links per FR-018.
18. Write `docs/operations/talos-ii-tailscale-mesh.md` runbook (this file's quickstart content + rollback details).
19. Update `docs/cluster-definition.md` and `docs/index.md`.

**P7 (optional, on failure) — Rollback**:
20. Re-pin `5456009e...` in `talos/talconfig.yaml`. `task talos:upgrade-node` per node. Tailscale device records orphan in admin UI; ephemeral keys expire ~5 min. OAuth client itself remains valid (no rotation needed; it's just unused until P4 retried).

## Phase 2 — Tasks Preview (informational)

`/tasks` will produce checkbox-ordered tasks; this is a non-binding preview of grouping and order:

1. **Pre-flight (T-001 … T-003)** — Tailscale admin: ACL declares `tag:talos-ii-node`; OAuth client minted; sing-box `100.64.0.0/10` exclusion verified.
2. **Schematic generation (T-004 … T-005)** — Submit new schematic; capture ID; reproduce locally with `talosctl get extensions` against an existing node to sanity-check.
3. **Manifest authoring (T-006 … T-009)** — `talconfig.yaml` ID swap (3 sites); `machine-tailscale.yaml` ExtensionServiceConfig; `machine-files-tailscale-secret.sops.yaml` cleartext-then-SOPS-encrypted; CoreDNS HelmRelease values append.
4. **Talos config regen (T-010)** — `task talos:gen-config`; review diff.
5. **Commit + Flux reconcile setup (T-011)** — single commit per the message at the bottom.
6. **Rolling upgrade ms01-a (T-012a … T-012e)** — `task talos:upgrade-node`; per-node verifications V1, V2, V3.
7. **Rolling upgrade ms01-b (T-013a … T-013e)** — same gate.
8. **Rolling upgrade ms01-c (T-014a … T-014e)** — same gate.
9. **CoreDNS reconcile (T-015)** — verify Flux applied; `kubectl get cm -n kube-system coredns -o yaml` confirms second server block.
10. **End-to-end validation (T-016)** — full V1–V5 pass.
11. **Documentation (T-017 … T-020)** — `docs/talos-image-factory.md`, ADR 0014, runbook, cluster-definition, index.

## Risks + mitigations

1. **Schematic submission with `secureboot=true` produces a kernel that won't verify against existing PCR-bound Secure Boot keys**.
   - *Mitigation*: `secureboot=true` in the factory parameter signs with the well-known sidero Secure Boot key bundle, which is the same bundle the existing schematic was signed with (verified by the fact that `5456009e...` boots today). PCR binding is on the bundle, not the schematic ID. First node upgrade is the canary; if it fails to boot, the node sits at the boot-loader prompt and is recovered by re-flashing the prior schematic ISO via the existing rescue procedure (i226 NIC + vPro AMT KVM).
2. **OAuth client_secret leak** (commit secret in plaintext, leak via container exec, etc.).
   - *Mitigation*: SOPS-encrypted at rest (Constitution §V). Decrypted only at `talhelper genconfig` time; rendered file at `/var/etc/tailscale/auth.env` is `0o600` and only readable by the `tailscaled` extension's runtime user. Detection: Tailscale admin UI shows the client's last-used time — anomalous clients can be revoked. Revocation procedure: revoke client in admin UI, mint replacement, re-encrypt, commit, roll. ~10 minutes operator time, no service impact (existing ephemeral devices keep working until they expire).
3. **`${HOSTNAME}` substitution not supported inside `ExtensionServiceConfig.environment`**.
   - *Mitigation*: First-node canary tests the substitution. If `talosctl get extensionserviceconfigs -o yaml` shows `${HOSTNAME}` literal, fall back to per-node `talos/patches/<node>/machine-tailscale.yaml` files (Q6 fallback); cost is three near-duplicate patches instead of one global. Quickstart's V1 verification step catches this within minutes.
4. **Subnet-router orphan on node reboot** — Tailscale considers a device offline only after heartbeat timeout (~30 s by default) plus device-expiry interaction with ephemeral keys.
   - *Mitigation*: ephemeral OAuth-minted keys (`?ephemeral=true&preauthorized=true`) cause the prior device record to disappear ~5 minutes after the node stops sending heartbeats. Until then, Tailscale's HA reconvergence (Q5) picks a different active router for affected destinations within ~30 s. Net user-visible impact ≤ 30 s per reboot, matching SC-005.
5. **CoreDNS server-block ordering subtlety**: even though `ts.net` and `.` are different zones, an operator could mistakenly add the `ts.net` block as a plugin inside the existing `.` block, which would fail (CoreDNS forward plugin doesn't multi-zone in one block).
   - *Mitigation*: contracts/coredns-forward-block.md gives the exact YAML to copy. Round-trip verification: render values via `helm template` locally and inspect the resulting Corefile before committing.
6. **Cilium BPF masquerade re-SNATs pod-to-tailnet packets to the node IP**, defeating tailnet-side IP visibility.
   - *Mitigation*: this is not a defect — it's the documented expected behavior per spec edge case "Cilium BPF masquerade vs tailscaled". The tailnet-visible source for outbound is the **subnet-router node's tailnet 100.x IP** (after tailscaled's NAT inside the TUN), regardless of Cilium's masquerade. attic-side logs see the 100.x address (SC-003). If a future requirement needs pod-IP-visibility upstream of tailscaled, that's a separate spec — out of scope here.

## What is deferred (separately tracked, NOT this plan)

- **Cross-cluster ACL between `tag:talos-ii-node` and `tag:talos-i-node`**. Gated on talos-i adoption. Will be in the talos-i analog spec under shared/0003.
- **Operator deprecation**. Out of scope. Both layers (operator + extension) stay per Constitution §VII v1.2.0; this spec is purely additive.
- **Self-hosted tailnet control plane** (Headscale / NetBird). Per shared/0003 sub-decision (2), implementation lives in `/etc/nixos`, not this repo. Structurally compatible — OAuth-client-based registration works against both SaaS and self-hosted control planes.
- **`tailscale serve` on subnet-router nodes** as an alternative to per-Service operator ingress. Listed in shared/0002's "Open questions deferred"; not decided here.
- **NetworkPolicy default-deny rollout** with explicit `100.64.0.0/10` carve-out. Not in scope.

## Complexity Tracking

> No Constitution Check violations. This section intentionally left empty.
