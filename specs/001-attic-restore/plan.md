# Implementation Plan: Attic restore on talos-ii (Phase 4a)

**Branch**: `001-attic-restore` (feature dir; current git branch is `main`) | **Date**: 2026-04-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-attic-restore/spec.md`

## Summary

Bring up an authenticated Nix binary cache (`attic`) on the bare-metal talos-ii cluster, sized and shaped like the swarm-01 deployment but with two architectural swaps: (1) the metadata DB moves from a single bitnami-PG StatefulSet to a 3-replica CloudNativePG `Cluster` (`attic-pg`) on `longhorn-r3` storage, and (2) all egress from the attic pod (image pulls aside, which already go via the LAN zot mirror) traverses the in-cluster sing-box proxy. No nar-store data is migrated; the cache starts empty and re-fills naturally as NixOS fleet hosts rebuild. After deploy, an operator mints a fresh `nix-fleet` pull token via `kubectl exec deploy/attic -- atticadm`, drops it into the separate Nix-fleet repo's SOPS shared secret, and rebuilds fleet hosts to validate end-to-end.

## Technical Context

**Workload type**: stateful HTTP server (Rust binary, ~30 MB image), single-replica Deployment behind a ClusterIP Service.
**Primary container image**: `ghcr.io/zhaofengli/attic` — pinned by digest (see Phase 0 / research.md decision; `:latest` is rejected by FR-007 and good practice). Pulled through the LAN zot mirror at `172.16.80.240:5000` via the existing ghcr.io pull-through entry — **no new mirror entry is required** (validated in Phase 0).
**Helm chart**: `bjw-s app-template` v4.6.2, sourced from the LAN zot at `oci://172.16.80.240:5000/charts/app-template`. Same chart + version that `n8n`, `forgejo`, `vaultwarden`, `sing-box` use in this repo.
**Storage backend**: `longhorn-r3` storage class for both the 100 Gi nar-store PVC and the 8 Gi CNPG-instance PVCs (3× replicas).
**Database**: CloudNativePG `Cluster` named `attic-pg`, 3 instances, image `ghcr.io/cloudnative-pg/postgresql:16.4` (PG 16 — see ADR rationale in research.md). App credentials in `attic-pg-app` Secret, superuser in `attic-pg-superuser` Secret. Read/write Service is `attic-pg-rw.nix.svc.cluster.local`.
**Egress policy**: pod-level `HTTP_PROXY` / `HTTPS_PROXY` = `http://sing-box.network.svc.cluster.local:7890`. `NO_PROXY` MUST include the trailing-dot variant of `cluster.local` (Go's `httpproxy` matcher does not normalize trailing dots); see the 2026-04-28 incident comment in `templates/overrides/kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml.j2`.
**Public ingress**: HTTPRoute on `envoy-external` Gateway (Cloudflare Tunnel) for `nix.${SECRET_DOMAIN}`, port 8080.
**Tailnet ingress**: dedicated ClusterIP Service `attic-tailscale` with the three required tailscale-operator annotations (`expose=true`, `hostname=attic`, `proxy-class=proxied`).
**Auth model**: attic-native bearer tokens (HS256/RS256 JWT signed by the server's private key in `server.toml`). Not behind authentik OIDC — clients are headless `nix-daemon`s that don't do interactive OIDC.
**Project type**: GitOps cluster manifest set. No application code is being written by this feature — only YAML, jinja2-templated manifest, ADR markdown, and runbook markdown.
**Constraints**: 100 Gi nar-store budget; no native Cloudflare-large-upload concerns because clients can switch to the tailnet path for big nar uploads (`nix copy --to https://attic.<tailnet>.ts.net/nix-fleet`). No measured perf goal — informally, fleet rebuild against the cluster cache should not be slower than against `cache.nixos.org` directly once paths are populated (per SC-001).
**Scale/scope**: ~5 NixOS fleet hosts pulling, 1–2 hosts pushing. Cache size grows to ~tens of GB over months.

## Constitution Check

Cross-checked against [`.specify/memory/constitution.md`](../../.specify/memory/constitution.md) v1.1.0:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] — bare metal, no nesting | ✅ pass | Pure k8s workload; doesn't touch hypervisor layer. |
| **II. Storage** [both] — Longhorn only, `replicaCount: 3` for irreplaceable | ✅ pass | All PVCs use `longhorn-r3`. The nar-store is *not* irreplaceable in the strict sense (content-addressable, can re-push) but consistency with other Phase 3 apps and the 100 Gi size both warrant r3. |
| **III. Network** [talos-ii] — Cilium, no overlay | ✅ pass | Standard ClusterIP + HTTPRoute path. No new CNI surface. |
| **IV. Image factory** [talos-ii] — official factory, no custom extensions | ✅ pass | No Talos image change. No new schematic ID. |
| **V. Secrets** [both] — age, gitignored private key | ✅ pass | All 3 new secrets (`attic-pg-app`, `attic-pg-superuser`, `attic-secret`) are SOPS-encrypted; private key already gitignored. |
| **VI. Public exposure** [both] — Cloudflare Tunnel default, VPS exception per-service | ✅ pass | Default Cloudflare path is fine. Tailnet path is supplementary, not a public-exposure decision. |
| **VII. Private exposure** [both] — Tailscale operator only, no NodePort | ✅ pass | tailscale-operator annotation pattern, no NodePort. |
| **VIII. GitOps** [both] — flux reconciles `kubernetes/apps/*` | ✅ pass | All new manifests live under `kubernetes/apps/nix/attic/` and are picked up by the standard `kubernetes/apps/nix/kustomization.yaml`. |
| **IX. Spec-Driven Development** [both] — spec → plan → tasks → implement for arch changes | ✅ pass | This very document. |
| **X. Documentation** [both] — ADR + index update in same commit as change | ✅ pass | ADR 0011 + `attic-restore.md` runbook + `docs/index.md` update are all in scope. |
| **XI. No surprise reboots / destructive shortcuts** [both] | ✅ pass | Fresh deploy; nothing to delete or restart non-gracefully. |

**Result: PASS — no Constitution violations. No Complexity Tracking entries required.**

## Project Structure

### Documentation (this feature)

```text
specs/001-attic-restore/
├── plan.md            # This file
├── research.md        # Phase 0 — open questions resolved (PG version, image pin, server.toml render strategy)
├── data-model.md      # Phase 1 — entity shapes (Secret keys, CNPG bootstrap, ConfigMap absence)
├── quickstart.md      # Phase 1 — operator playbook (deploy → mint → rotate fleet → verify)
├── contracts/
│   └── attic-server-toml.md   # Phase 1 — required keys in attic's server.toml + which Secret holds each
├── checklists/
│   └── requirements.md        # written by /specify
└── tasks.md           # Phase 2 — written by /tasks (NOT by this command)
```

### Source code / repo layout (impacted areas)

```text
kubernetes/
└── apps/
    └── nix/                                    # NEW namespace dir
        ├── namespace.yaml                      # NEW
        ├── kustomization.yaml                  # NEW (lists ./attic)
        └── attic/                              # NEW app dir
            ├── ks.yaml                         # NEW — Flux Kustomization, depends on cnpg + longhorn
            └── app/
                ├── kustomization.yaml          # NEW — resource list
                ├── ocirepository.yaml          # NEW — bjw-s app-template 4.6.2 from LAN zot
                ├── helmrelease.yaml            # NEW — app-template values
                ├── pg-cluster.yaml             # NEW — CNPG Cluster (PG 16, 3× longhorn-r3)
                ├── pg-secret.sops.yaml         # NEW — pre-create attic-pg-app + attic-pg-superuser
                ├── pvc.yaml                    # NEW — nar-store PVC (100 Gi longhorn-r3)
                ├── secret.sops.yaml            # NEW — server.toml + JWT keys
                ├── httproute.yaml              # NEW — envoy-external Cloudflare path
                └── service-tailscale.yaml      # NEW — tailscale-operator-annotated ClusterIP

docs/
├── index.md                                    # MODIFIED — add ADR + runbook entries
├── decisions/talos-ii/0011-attic-cnpg.md       # NEW
└── operations/attic-restore.md                 # NEW
```

**Structure decision**: standard `kubernetes/apps/<namespace>/<app>/{ks.yaml,app/}` layout exactly mirroring authentik / matrix / coder / n8n. This is the first app in the new `nix` namespace so a `namespace.yaml` and namespace-level `kustomization.yaml` are added; both are minimal (compare to `kubernetes/apps/identity/{namespace.yaml,kustomization.yaml}`). No template files are introduced (no jinja2 work, nothing under `templates/`) because there are no per-cluster variations and no template-render-time secrets — all variables come from `cluster-secrets` via flux's `postBuild.substituteFrom`. **Crucially: no manifests under `templates/`.**

## Phase 0 — Outline & Research

Three Technical Context items needed resolution before design could proceed. They're written up in [research.md](./research.md):

1. **PG major version** — pinned to **PG 16** to match the swarm-01 deployment (5Gi bitnami PG 16). No data migration is in scope, but a future need could emerge to import dump-extracted token rows; cross-major-version `pg_restore` is not supported, so version-pinning is the cheap insurance. Image: `ghcr.io/cloudnative-pg/postgresql:16.4`.

2. **Container image pin** — pinned to **`ghcr.io/zhaofengli/attic@sha256:<digest>`**. Upstream tags only `latest` reliably; floating tag is incompatible with FR-007 (reproducibility) and the in-cluster image cache (zot would re-resolve `:latest` on every pull). The exact digest is captured in research.md and gets refreshed only when the operator deliberately rolls forward.

3. **`server.toml` render strategy** — `database.url` is **inlined** into `server.toml` inside the SOPS-encrypted `attic-secret`, with the password value duplicated in two places: `attic-pg-app` (which CNPG's `bootstrap.initdb.secret` references) and the inlined DSN. Same dual-secret pattern that `coder` uses (`coder-pg-app` + `coder-secret`'s `pg-connection-url`). Rejected alternatives: (a) `${VAR}` substitution in `server.toml` via flux's `postBuild` — works for top-level keys but not for the nested toml shape, and would require committing a partially-secret file; (b) initContainer envsubst — extra moving parts and an alpine sidecar pull for a problem that the dual-secret pattern already solves cleanly elsewhere in the repo.

A fourth question — "does the Talos `machine-registries.yaml.j2` need a new mirror entry for ghcr.io?" — was checked and the answer is **no**. The existing `ghcr.io: endpoints: [http://172.16.80.240:5000]` entry already covers `ghcr.io/zhaofengli/attic`; zot's `extensions.sync.registries[]` for ghcr.io is configured for `onDemand: true`, so the first cluster pull will populate the cache for subsequent nodes.

**Output**: [research.md](./research.md) — all NEEDS CLARIFICATION resolved, no blockers for Phase 1.

## Phase 1 — Design & Contracts

### Entities ([data-model.md](./data-model.md))

- **Secrets** (3): `attic-pg-app`, `attic-pg-superuser`, `attic-secret`. The first two follow the standard CNPG pattern (basic-auth `username`/`password`). The third holds `server.toml`, `token-rs256-secret-base64`, `token-rs256-public-key-base64`.
- **CNPG `Cluster`** (`attic-pg`): 3 instances, `bootstrap.initdb.{database: attic, owner: attic}`, `superuserSecret: attic-pg-superuser`, storage 8 Gi `longhorn-r3`, image `ghcr.io/cloudnative-pg/postgresql:16.4`.
- **PVC** (`attic-store`): RWO, 100 Gi, `longhorn-r3`, mounted at `/var/lib/attic/store`.
- **HelmRelease** (`attic`): app-template 4.6.2; one container `app` running `attic --config /config/server.toml`; mounts `attic-secret` at `/config/server.toml` (subPath) and the PVC at `/var/lib/attic/store`; sets `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` env per the cluster convention.
- **Services** (2): the chart-emitted `attic` ClusterIP for HTTPRoute backend; a separate `attic-tailscale` ClusterIP carrying the three `tailscale.com/*` annotations.
- **HTTPRoute** (`attic`): `nix.${SECRET_DOMAIN}` → `attic:8080` via `envoy-external`.

### Contracts ([contracts/attic-server-toml.md](./contracts/attic-server-toml.md))

Documents the exact `server.toml` schema attic expects, which key belongs in which Secret, and the JWT key generation procedure (one-shot `openssl genpkey` + base64 — only run on the operator workstation, never re-run after deploy because it would invalidate every existing token).

### Quickstart ([quickstart.md](./quickstart.md))

Operator playbook: clone repo → `task encrypt-secrets` after editing the SOPS files → push → flux reconciles → exec into pod → `atticadm make-token --pull nix-fleet --validity 1y` → paste into Nix-fleet repo's `secrets/shared/attic.yaml` → `sops -e -i` → `nixos-rebuild switch` on one host → verify HTTP 200 from authenticated probe + HTTP 401 from anonymous probe → roll out to remaining hosts.

### Agent context update

The repository has no `<!-- SPECKIT START --> / <!-- SPECKIT END -->` markers in any agent context file (verified by grep — no such markers in `CLAUDE.md`, `AGENTS.md`, `.specify/memory/*`). No update is performed; the next time an agent context file with those markers is introduced, the convention is to point it at this `plan.md`.

## Phase 2 — Tasks (handled by `/tasks`, not by this command)

`/tasks` will turn the deliverables in this plan into a dependency-ordered task list. The expected ordering is:

1. **Pre-flight** — confirm CNPG operator is healthy in `cnpg-system`; confirm `longhorn-r3` storage class exists; confirm sing-box at `network/sing-box` is reachable; pre-pull the bjw-s chart 4.6.2 to LAN zot if not already there (it is — n8n already uses it).
2. **Generate JWT keys** locally on the operator workstation; capture as base64 to paste into `secret.sops.yaml`.
3. **Generate the DB password** locally; populate it into both `pg-secret.sops.yaml` (as `password`) and `secret.sops.yaml` (inlined into `server.toml`'s `database.url`).
4. **Write manifests** in the file order listed in "Project Structure" above. SOPS-encrypt the two `*.sops.yaml` files.
5. **Update `kubernetes/apps/nix/kustomization.yaml`** to list `./attic` and update the parent `kubernetes/flux/cluster/...` if the new namespace dir isn't auto-discovered.
6. **Write ADR `0011-attic-cnpg.md` and runbook `attic-restore.md`**; update `docs/index.md` in the same commit.
7. **Commit + push**.
8. **Watch flux reconcile** (`flux get hr -n nix attic`, `kubectl get cluster -n nix attic-pg`, `kubectl get pvc -n nix`).
9. **Verify acceptance**: anonymous probe → 401, authenticated probe (after token mint) → 200, push a test path, pull on a different host.
10. **Rotate fleet token**: mint, paste into Nix-fleet repo, rebuild one host, then the rest.
11. **Final acceptance**: rebuild a fleet host end-to-end, observe cache hits in nix-daemon logs, confirm SC-001/-002/-003/-004/-005/-006.

### Likely tripwires (per implementer judgment)

- **`server.toml` shape** — the binary expects `[chunking]`, `[storage]`, `[database]`, `[compression]`, `[garbage-collection]` as *sections*. **Do NOT** include `[jwt]` or `[require-proof-of-possession]` as section headers — `require-proof-of-possession` is a top-level boolean (writing it as a section header crashes attic with "invalid type: map, expected a boolean"); `[jwt]` would expect nested keys we provide via env vars instead. Both default fine. If chunking is misconfigured, pushes silently fail with cryptic 500s. The contract in `contracts/attic-server-toml.md` enumerates the minimal correct shape.
- **`atticd` CLI surface** — there is **no** `server` subcommand and **no** `--listen` flag. Listen address comes from `server.toml`'s top-level `listen = "[::]:8080"`. Pass only `--config /config/server.toml` as args; passing anything else makes the binary exit with `unexpected argument 'server' found`.
- **`allowed-hosts` ignores port** — attic's Host-header allowlist match does NOT strip the port. Production traffic via Cloudflare/Tailscale uses 443/443 and the Host is the bare FQDN, so this never bites in normal use. But in-cluster probes via `curl http://attic:8080/...` send `Host: attic:8080` and get rejected with HTTP 400 "Bad Host". Probe with `-H "Host: attic"` (or via the public URL once HTTPRoute is up) instead.
- **JWT key generation** — `openssl genrsa` produces PKCS#1; attic expects PKCS#8 RS256. Use `openssl genpkey -algorithm RSA -out priv.pem -pkeyopt rsa_keygen_bits:4096`, then base64-encode the *file contents* (not just the `-----BEGIN-----` block). If you regenerate after deploy, every existing token in the DB becomes unverifiable — runbook calls this out explicitly.
- **CNPG-app-secret password vs. server.toml DSN drift** — the same password is written in two SOPS files. The runbook's "rotating the DB password" section needs to spell out: rotate in `pg-secret.sops.yaml` AND `secret.sops.yaml` together, in one commit, then `flux reconcile` will roll out a new attic pod with the matching DSN. Otherwise attic crashloops with `password authentication failed`.
- **`HelmRelease.dependsOn` doesn't accept CRD references** — only resolves against other HelmReleases. Pointing it at `attic-pg` (a CNPG `Cluster` CRD) pins the chart in `PrerequisitesNotMet` forever. Drop the dependsOn; let kube's restart-on-failure handle the brief CrashLoopBackOff while the DB bootstraps.
- **`Kustomization.dependsOn` namespace** — if you add it for `cloudnative-pg`, the namespace is **`flux-system`**, not `cnpg-system`. The latter is where the operator runs (targetNamespace); the former is where the Flux Kustomization resource itself lives. Easier: don't add the dependsOn at all — coder/n8n/matrix don't.
- **Image digest pinning + LAN zot manifest validation** — zot rejects upstream `ghcr.io/zhaofengli/attic`'s Docker v2 schema-2 manifest with `MANIFEST_INVALID`. Workaround: `nix-shell -p skopeo` then `skopeo copy --src-tls-verify=false --dest-tls-verify=false --override-os linux --override-arch amd64 --format=oci docker://ghcr.io/zhaofengli/attic@sha256:<upstream-index> docker://172.16.80.240:5000/zhaofengli/attic:phase4a`. Pin the helmrelease to the OCI-converted digest; same layer content, different envelope. Other ghcr.io images (cloudnative-pg, for instance) pull through zot fine without this — it's image-specific.
- **Tailscale ProxyClass annotation** — the `proxy-class: proxied` annotation MUST be on the `attic-tailscale` Service; without it the per-Service tailscale proxy pod can't reach `controlplane.tailscale.com` and stays `NeedsLogin`. Easy to miss because two of the three required annotations are documented in many places but the third one (`proxy-class`) is documented only in `docs/operations/tailscale-operator.md`.
- **ts-proxy Pod namespace is `network`, not `tailscale`.** The tailscale-operator HelmRelease's `targetNamespace: network`, so the per-Service `ts-<svc>-<id>-0` Pods land in `network` alongside the operator. Some of the project's own runbook prose still says "tailscale namespace" which is stale wording inherited from a doc-template; verifying the proxy with `kubectl get pods -n network | grep ts-attic` is correct.
- **`atticadm` has no `create-cache` / `list-caches` / `revoke-token` subcommands** — these are documented upstream but absent from this version of the binary. Cache creation goes through the REST API (`POST /_api/v1/cache-config/<name>` with admin Bearer + `Host: nix.beaco.works`); cache listing isn't directly exposed (operator tracks via the runbook's issuance log + git history); token revocation is achieved via short validity windows (1y is the upper bound; emergency tokens go 1d) plus the nuclear-option RS256 keypair rotation that invalidates all outstanding tokens at once. The runbook covers all three procedures.
- **No real admin/op token scope in `atticadm make-token`.** A token with `--pull <cache>` AND `--push <cache>` on the target cache has enough privilege to call `_api/v1/cache-config/<cache>` endpoints — there is no separate `--admin` flag. So the "admin token" used to create a cache is just a 5m-validity push+pull token; treat it as ephemeral. Document this with cache creation so the operator doesn't reach for a flag that doesn't exist.

## Complexity Tracking

(no Constitution violations — table omitted)
