# Implementation Plan: zot OCI mirror in-cluster on talos-ii (Phase 4b)

**Branch**: `002-zot-on-talos-ii` (feature dir; current git branch is `main`) | **Date**: 2026-04-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-zot-on-talos-ii/spec.md`

## Summary

Bring up zot as an in-cluster OCI pull-through cache on talos-ii, replacing the LAN host instance at `172.16.80.240:5000` as the primary mirror endpoint for talos-ii's containerd. Single instance, scoped to talos-ii only (per the per-cluster scoping principle); talos-i consumes the same registry across the tailnet through the in-cluster `tailscale-operator`. Storage is a 300 Gi `longhorn-r2` PVC; deployment is the official `zot/zot` Helm chart sourced from LAN zot; egress to upstream registries traverses the in-cluster sing-box; node-side exposure is a Cilium L2-announced LoadBalancer at `172.16.87.51:5000`. Cutover is reversible via a transitional two-endpoint `endpoints[]` list in the Talos `machine-registries.yaml` patch (in-cluster first, LAN host second) and Talos's hot-applied `--mode=auto` config update means no node reboots. Decommissioning the LAN host is a separately tracked phase, gated on this Plan's acceptance. No data is migrated — content is content-addressable and re-fills naturally.

## Technical Context

**Workload type**: stateful HTTP server (zot, single Go binary, ~30 MB image), single-replica Deployment behind a ClusterIP + a Cilium L2-announced LoadBalancer + a tailscale-operator-exposed ClusterIP.
**Primary container image**: `ghcr.io/project-zot/zot-linux-amd64` — pinned by digest, captured at apply time (see [research.md Q11](./research.md#q11--image-digest-pin-for-ghcrioproject-zotzot-linux-amd64)). Bootstraps via in-cluster sing-box egress (Plan Y, see Q5), **not** through any zot mirror — avoids the chicken-and-egg.
**Helm chart**: official `zot/zot` v0.1.79, pre-pushed to LAN zot at `oci://172.16.80.240:5000/charts/zot` (same one-time push pattern as `tailscale-operator`). Diverges from the rest of the repo's `bjw-s app-template` convention; the divergence is justified by zot's nested `extensions.sync.registries[]` schema benefiting materially from the chart's JSON-schema validation (see [research.md Q4](./research.md#q4--helm-chart-selection-official-zot-vs-bjw-s-app-template)).
**Storage backend**: `longhorn-r2` storage class, 300 Gi PVC `zot-store`. Replica count `2` (not `3`) because cached registry content is replaceable by re-syncing from upstream — Constitution Principle II.
**Database**: none. zot stores everything in the local OCI layout on the PVC.
**Egress policy**: pod-level `HTTP_PROXY` / `HTTPS_PROXY` = `http://sing-box.network.svc.cluster.local:7890`. `NO_PROXY` includes the trailing-dot variants of `cluster.local` (Go httpproxy quirk per attic precedent, [`docs/operations/sing-box-egress.md`](../../docs/operations/sing-box-egress.md) and `kubernetes/apps/nix/attic/app/helmrelease.yaml`).
**Node-side exposure**: `zot-lb` LoadBalancer Service annotated `lbipam.cilium.io/ips: "172.16.87.51"`. Talos `machine.registries.mirrors` entries use the literal IP `http://172.16.87.51:5000` as the primary endpoint, with `http://172.16.80.240:5000` as the transition-window fallback.
**Cross-cluster exposure**: `zot-tailscale` ClusterIP Service with `tailscale.com/expose=true`, `tailscale.com/hostname=zot`, `tailscale.com/proxy-class=proxied`. Tailnet hostname `zot.tail5d550.ts.net:5000`. talos-i consumes via this hostname in a follow-up phase (out of scope here, contract documented).
**Auth model**: htpasswd (single admin user) for push, anonymous read for pull. SOPS-encrypted in `zot-secret`. No authentik/OIDC, no multi-user RBAC (FR-008).
**Talos machine-config delta**: `templates/config/talos/patches/global/machine-registries.yaml.j2` modified to make the in-cluster zot LB IP the primary mirror endpoint and the LAN host a fallback for every existing `*.io` mirror entry (`docker.io`, `ghcr.io`, `quay.io`, `mirror.gcr.io`, `code.forgejo.org`, `docker.n8n.io`); new entries added for `gcr.io`, `registry.k8s.io`, `docker.elastic.co`. `factory.talos.dev` left at LAN host (out of scope). New self-referential entry for `172.16.87.51:5000`. Hot-applied via `talosctl apply --mode=auto`, **no reboot** ([research.md Q2](./research.md#q2--fr-018-does-talos-machineregistriesmirrors-change-require-a-reboot)).
**Project type**: GitOps cluster manifest set + Talos config patch. No application code is written — only YAML, jinja2-templated machine-config, ADR markdown, runbook markdown.
**Constraints**: 300 Gi cache budget; no surprise reboots (Constitution XI / FR-018 / SC-007); cutover reversibility via fallback endpoint (FR-019); no public exposure (FR-015); no zot-on-talos-i (FR-001 / SC-005 enforced through per-cluster scoping).
**Scale/scope**: 3 talos-ii nodes pulling on demand; talos-i (3 nodes) added in follow-up phase via tailnet. Steady-state pull volume modest (cluster has ~30 deployed apps); cold-start re-fill is one-time multi-GB blob transfer through sing-box.

## Constitution Check

Cross-checked against [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.1.0:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] — bare metal, no nesting | ✅ pass | Pure k8s workload; no hypervisor surface. |
| **II. Storage** [both] — Longhorn only, `replicaCount: 3` for irreplaceable | ✅ pass | `longhorn-r2` (replica 2). Cache content is replaceable; r3 explicitly not justified ([research.md Q9](./research.md#q9--pvc-sizing-and-storage-class)). |
| **III. Network** [talos-ii] — Cilium, no overlay | ✅ pass | Cilium L2-announced LB IP `172.16.87.51` from existing `cilium-l2` pool. Same pattern as envoy/sing-box LB. |
| **IV. Image factory** [talos-ii] — official factory, no custom extensions | ✅ pass | No Talos image change. `factory.talos.dev` mirror entry deliberately not modified (out of scope). |
| **V. Secrets** [both] — age, gitignored private key | ✅ pass | `zot-secret` (htpasswd + admin plaintext) SOPS-encrypted. |
| **VI. Public exposure** [both] — Cloudflare Tunnel default, VPS exception per-service | ✅ pass / N/A | No public exposure (FR-015). No HTTPRoute, no Cloudflare Tunnel route. |
| **VII. Private exposure** [both] — Tailscale operator only, no NodePort | ✅ pass | `zot-tailscale` Service uses tailscale-operator with `proxy-class: proxied`. The LB Service `zot-lb` is in-VLAN host reachability, not "private LAN exposure" — same exemption category as `envoy-internal` / `sing-box-lb` / `k8s-gateway` already in this repo. |
| **VIII. GitOps** [both] — flux reconciles `kubernetes/apps/*` | ✅ pass | All manifests under `kubernetes/apps/registry/zot/`. |
| **IX. Spec-Driven Development** [both] | ✅ pass | This Plan + `spec.md` are the artifacts. |
| **X. Documentation** [both] — ADR + index update in same commit chain | ✅ pass by requirement | FR-020 mandates ADR `0012-zot-on-talos-ii.md` + runbook `zot-restore.md` + `docs/index.md` update at implement time. |
| **XI. No surprise reboots / destructive shortcuts** [both] | ✅ pass | Talos `machine.registries` change is hot-applied via `--mode=auto`; verification step in the runbook (dmesg) catches any false-positive reboot ([research.md Q2](./research.md#q2--fr-018-does-talos-machineregistriesmirrors-change-require-a-reboot)). |
| **Per-cluster scoping** rule | ✅ pass | Manifests scoped to talos-ii repo only (this repo). FR-001 / SC-005 forbid talos-i deployment; talos-i consumption via tailnet is documented as a contract but not implemented here. |

**Result: PASS — no Constitution violations. No Complexity Tracking entries required.**

## Project Structure

### Documentation (this feature)

```text
specs/002-zot-on-talos-ii/
├── plan.md                              # This file
├── research.md                          # Phase 0 — three NEEDS CLARIFICATION + 8 design decisions resolved
├── data-model.md                        # Phase 1 — entity shapes (Secrets, PVC, HelmRelease, Services, etc.)
├── quickstart.md                        # Phase 1 — operator playbook (pre-flight → deploy → cutover → verify → rollback)
├── contracts/
│   └── zot-config.md                    # Phase 1 — required keys in zot config.json + extensions.sync.registries[] shape
├── checklists/
│   └── requirements.md                  # written by /specify
└── tasks.md                             # Phase 2 — written by /tasks (NOT by this command)
```

### Source code / repo layout (impacted areas)

```text
kubernetes/
└── apps/
    └── registry/                                  # NEW namespace dir
        ├── namespace.yaml                         # NEW
        ├── kustomization.yaml                     # NEW (lists ./zot)
        └── zot/                                   # NEW app dir
            ├── ks.yaml                            # NEW — Flux Kustomization, no dependsOn
            └── app/
                ├── kustomization.yaml             # NEW — resource list
                ├── ocirepository.yaml             # NEW — official zot chart 0.1.79 from LAN zot
                ├── helmrelease.yaml               # NEW — image pinned by digest, sing-box proxy env, full config.json in values
                ├── pvc.yaml                       # NEW — zot-store PVC (300 Gi longhorn-r2)
                ├── secret.sops.yaml               # NEW — htpasswd + admin-password (SOPS-encrypted)
                ├── service-lb.yaml                # NEW — Cilium L2 LB Service at 172.16.87.51
                └── service-tailscale.yaml         # NEW — tailscale-operator-annotated ClusterIP

templates/config/talos/patches/global/
└── machine-registries.yaml.j2                     # MODIFIED — in-cluster IP first, LAN fallback;
                                                   #   add gcr.io / registry.k8s.io / docker.elastic.co;
                                                   #   add 172.16.87.51:5000 self-referential;
                                                   #   leave factory.talos.dev unchanged

docs/
├── index.md                                       # MODIFIED — add ADR + runbook entries
├── decisions/talos-ii/0012-zot-on-talos-ii.md     # NEW
└── operations/zot-restore.md                      # NEW
```

**Structure decision**: standard `kubernetes/apps/<namespace>/<app>/{ks.yaml,app/}` layout exactly mirroring authentik / matrix / coder / n8n / attic. New top-level namespace `registry/` (analogous to `nix/` from Phase 4a). The existing `docs/operations/zot-mirror.md` (which describes the **LAN host** zot) gains a "see also: in-cluster zot" cross-link but is not deleted — it remains current until the LAN host is decommissioned in a follow-up phase. **Crucially: no manifests under `templates/`** apart from the existing `machine-registries.yaml.j2` edit.

## Phase 0 — Outline & Research

Three Technical Context items needed resolution before design could proceed (the three `[NEEDS CLARIFICATION]` markers in the spec) plus eight Plan-stage design decisions the spec deferred. They're written up in [research.md](./research.md):

1. **FR-006 — LAN zot upstream enumeration** ([Q1](./research.md#q1--fr-006-enumerate-the-lan-zot-upstream-registries)). Resolved via direct HTTP catalog query (`http://172.16.80.240:5000/v2/_catalog`) plus the in-repo [`docs/operations/zot-mirror.md`](../../docs/operations/zot-mirror.md). The implemented set is a strict superset of the LAN host's current 5: `docker.io, ghcr.io, quay.io, mirror.gcr.io, code.forgejo.org, docker.n8n.io` plus the operator-required adds `gcr.io, registry.k8s.io, docker.elastic.co`. `factory.talos.dev` deliberately not synced (would conflict with the curated pre-push for the secureboot installer).

2. **FR-018 — reboot vs. hot-reload** ([Q2](./research.md#q2--fr-018-does-talos-machineregistriesmirrors-change-require-a-reboot)). Resolved as **no reboot**. `talosctl apply-config --mode=auto` (the path used by `task talos:apply-node`) hot-reloads `machine.registries` on Talos 1.12.7 — confirmed empirically by the repo's own [`docs/operations/zot-mirror.md`](../../docs/operations/zot-mirror.md) which already says *"no reboot needed for registries-only changes"*. Constitution Principle XI is therefore satisfied; the runbook adds a `dmesg` post-apply verification as the safety check.

3. **SC-008 — throughput baseline** ([Q3](./research.md#q3--sc-008-throughput-baseline-numeric-vs-qualitative)). Resolved as **qualitative**: *"in-cluster zot pull latency ≤ 1.0× LAN-zot's under comparable conditions; a measurable regression is a defect."* The architectural changes (one fewer L3 hop, NVMe-direct local reads on cache hit, no router transit) make this a strict-improvement migration; a numeric MB/s target would impose synthetic-load-test overhead with no corresponding gain.

The remaining Plan-stage decisions ([Q4–Q11](./research.md)) cover:

- Helm chart choice (official `zot/zot`, not `bjw-s app-template`).
- Bootstrap chicken-and-egg (Plan Y: zot pulls itself via sing-box, no LAN-host special-case).
- Node-side exposure (Cilium L2 LB at `172.16.87.51`, matching the existing envoy/sing-box pattern).
- Talos `machine-registries.yaml.j2` redesign (two-endpoint list with in-cluster primary, LAN fallback).
- talos-i consumption contract (tailscale-operator + `zot.tail5d550.ts.net:5000`, **not implemented in this Plan**).
- PVC sizing (300 Gi `longhorn-r2`).
- Auth (htpasswd in SOPS Secret).
- Image digest pin (capture at apply time).

**Output**: [research.md](./research.md) — all `[NEEDS CLARIFICATION]` resolved, no blockers for Phase 1.

## Phase 1 — Design & Contracts

### Entities ([data-model.md](./data-model.md))

- **Namespace** (1): `registry` — new top-level namespace.
- **Secret** (1): `zot-secret` — `htpasswd` (bcrypt of admin password) + `admin-password` (plaintext for operator tooling). SOPS-encrypted.
- **PVC** (1): `zot-store` — 300 Gi RWO, `longhorn-r2`, mounted at `/var/lib/registry`.
- **OCIRepository** (1): `zot` — chart `0.1.79` from `oci://172.16.80.240:5000/charts/zot` (LAN zot, plain HTTP).
- **HelmRelease** (1): `zot` — official chart values render full `config.json` from `configFiles.config.json`; image pinned by digest; `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` set per attic precedent; `Recreate` strategy; resources sized for the steady-state load.
- **Services** (3): the chart-emitted `zot` ClusterIP; a separate `zot-lb` LoadBalancer (Cilium-L2-IP `172.16.87.51`); a separate `zot-tailscale` ClusterIP carrying the three `tailscale.com/*` annotations.
- **Flux Kustomization** (1): `zot` — applies `kubernetes/apps/registry/zot/app`, no dependsOn.
- **Talos patch edit**: `templates/config/talos/patches/global/machine-registries.yaml.j2` — endpoints reordered, three new mirror entries, one new self-referential entry.

### Contracts ([contracts/zot-config.md](./contracts/zot-config.md))

Documents the exact `config.json` shape zot expects, the nine `extensions.sync.registries[]` entries with their `urls` / `onDemand: true` / `pollInterval: "0"` / `tlsVerify: true` / `content[]` glob shape, the `accessControl.repositories["**"]` policy structure (anonymous read + admin push), the storage `gc`/`dedupe`/`gcInterval` knobs, and the optional extension blocks (`search`, `scrub`, `metrics`). Includes the verification curl recipes for FR-007 / FR-008 acceptance.

### Quickstart ([quickstart.md](./quickstart.md))

Operator playbook: pre-flight (chart push, image digest capture, htpasswd generation, SOPS encryption) → write manifests → first commit (manifests only, no Talos patch yet) → smoke-test the in-cluster zot (anon read, push auth, cold sync) → update Talos `machine-registries.yaml.j2` and apply per node sequentially with `dmesg` verification → run SC-001 through SC-008 acceptance probes → land the ADR + runbook + index update in the same commit chain → rollback procedure (revert the Talos patch — fallback endpoint means in-cluster zot failures don't auto-rollback, just fall through) → decommission step description (NOT this Plan; tracked separately as the gate that closes the predecessor anti-pattern).

### Agent context update

The repository has no `<!-- SPECKIT START --> / <!-- SPECKIT END -->` markers in any agent context file (verified by grep — no `CLAUDE.md`, `AGENTS.md`, or `.specify/memory/*` carries those markers). No update is performed; the next time an agent context file with those markers is introduced, the convention is to point it at this `plan.md`.

## Phase 2 — Tasks (handled by `/tasks`, not by this command)

`/tasks` will turn the deliverables in this plan into a dependency-ordered task list. The expected ordering is:

1. **Pre-flight checks**: Flux healthy, Longhorn healthy, sing-box healthy, `cilium-l2` LB pool has `172.16.87.51` free, LAN zot up.
2. **One-time chart push**: `helm pull` zot 0.1.79, `helm push` to LAN zot at `oci://172.16.80.240:5000/charts`.
3. **Capture zot image digest**: `crane digest ghcr.io/project-zot/zot-linux-amd64:v2.1.5`. If `MANIFEST_INVALID` surfaces at apply time, fall back to `skopeo --format=oci` re-push (same recipe as attic Phase 4a).
4. **Generate admin credentials**: random password + bcrypt htpasswd line on the operator workstation.
5. **Author manifests** in the file order in "Project Structure" above. SOPS-encrypt `secret.sops.yaml`.
6. **First commit + push** (manifests only, no Talos patch). Watch flux reconcile to a healthy state.
7. **Smoke-test in-cluster zot**: anonymous read, push without auth (401), push with auth (202), cold sync from upstream.
8. **Update `machine-registries.yaml.j2`** with the in-cluster-first, LAN-fallback shape (research.md Q7).
9. **Apply per node sequentially** (`task talos:apply-node IP=172.16.87.20{1,2,3}`), with `dmesg` and `hosts.toml` verification between each.
10. **Run acceptance probes**: SC-001 (fresh pull on talos-ii via in-cluster zot), SC-003 (LAN host outage drill), SC-006 (cache hit faster than miss), SC-007 (no unplanned reboots), SC-008 (qualitative throughput parity). SC-002 / SC-005 are out of scope to *implement* but reachability of the tailnet path is verified (`curl http://zot.tail5d550.ts.net:5000/v2/`).
11. **Land ADR + runbook + index update** in the same commit chain.
12. **Final commit + push**.

(Phase 4b's "decommission the LAN host" step is **not** a task here. It's tracked as a follow-up phase that gates Phase 4b's *closure*, not its *cutover*. SC-004's "zero `172.16.80.240` references" gate is met *after* that follow-up, not after this Plan's commits.)

### Likely tripwires (per implementer judgment)

- **Chart's `configFiles.config.json` value type** — the official `zot/zot` chart accepts the config either as a YAML mapping (which it serialises to JSON internally) or as a raw JSON string. Mapping form is preferred (chart's JSON schema validates field names); writing a raw JSON string blob bypasses that validation. Cross-check at apply time which form the chart version expects (`helm show values zot/zot --version 0.1.79`).
- **`extensions.sync.registries[].onDemand` must be a bool, not a string** — common mistake in YAML. The chart's schema would catch it, but only if values are mapping-form (see above).
- **Image digest pinning + LAN zot manifest validation** — zot's own image *should* be OCI-formatted (zot upstream knows how to serve OCI), but if the upstream digest fails with `MANIFEST_INVALID` at first apply, use the same `skopeo copy --format=oci` workaround documented in attic Phase 4a's ADR (0011-attic-cnpg.md) and re-pin to the OCI-converted digest. Same layer content, different envelope.
- **`HTTP_PROXY` / `NO_PROXY` trailing-dot variants** — must include both `cluster.local` and `cluster.local.` in `NO_PROXY`. Go's `net/http/httpproxy` matcher does **not** normalize the trailing dot (the same incident that bit attic on 2026-04-28; the comment in `kubernetes/apps/nix/attic/app/helmrelease.yaml` captures the failure mode). Without the trailing-dot variant, in-cluster service-name lookups silently route through sing-box and fail with cryptic timeouts.
- **`zot-lb` Service selector must match the chart's Pod labels** — the official chart uses `app.kubernetes.io/name=zot, app.kubernetes.io/instance=zot`. Verify with `kubectl get pods -n registry --show-labels` after the first reconcile and adjust the LB Service's selector if the chart uses a different label combination (chart minor versions sometimes drift).
- **`zot-tailscale` Service requires the third annotation `tailscale.com/proxy-class: proxied`** — without it the per-Service tailscale proxy pod (`ts-zot-<id>-0`) cannot reach `controlplane.tailscale.com` (GFW-blocked from talos-ii's default egress) and stays `NeedsLogin`. Easy to miss; documented in [`docs/operations/tailscale-operator.md`](../../docs/operations/tailscale-operator.md).
- **ts-proxy Pod namespace is `network`, not `tailscale`** — the tailscale-operator HelmRelease's `targetNamespace: network`, so `ts-zot-<id>-0` lands in `network` alongside the operator. Verify with `kubectl get pods -n network | grep ts-zot`.
- **Talos apply ordering** — apply node 201, verify, then 202, then 203. **Do not parallelise.** A bad apply that breaks containerd-config picks up on the next node; serial apply with verification between each catches it on the first node and leaves the other two healthy as a recovery path.
- **`task configure` re-encryption** (per `~/.claude/projects/.../memory/MEMORY.md`) — running `makejinja` directly bypasses the `encrypt-secrets` step. After any direct `makejinja` run, `task encrypt-secrets` (or `sops -e -i`) all `*.sops.*` before commit. The `task configure` umbrella does both; prefer it.
- **`pgpass`-class size for cached blobs** — the 300 Gi PVC sizing accommodates the LAN host's current ~80 Gi plus organic growth. If the operator notices utilisation climbing above 240 Gi (80 %), Longhorn supports online expansion: `kubectl edit pvc -n registry zot-store` and bump the `requests.storage`. **Caveat** (per `~/.claude/projects/.../memory/MEMORY.md`): `kubectl exec -i` truncates large stdin; if at any point a runbook procedure calls for piping multi-MB content into the zot pod, use `kubectl cp` + `--filename` instead.
- **Image bumps require Pod restart** — zot does not hot-reload `config.json`. Adding a new upstream registry means a brief Pod outage on `Recreate` while the new ConfigMap content propagates. Acceptable; documented in the runbook's "Add a new upstream" procedure.
- **Talos `factory.talos.dev` mirror entry stays at LAN host** — do not refactor it during the Talos patch edit. It's amd64-only, pre-pushed, and unrelated to Phase 4b's pull-through cache migration. Touching it is scope creep.
- **Tailnet path TLS is irrelevant** — talos-i's containerd will reach `http://zot.tail5d550.ts.net:5000` (plain HTTP); the WireGuard layer underneath provides encryption. Don't try to "harden" this path with TLS — that's the spec's edge-case bullet about "Cross-cluster TLS / certificate chain" answered explicitly. Plain HTTP on tailnet is the agreed posture.

## Complexity Tracking

(no Constitution violations — table omitted)
