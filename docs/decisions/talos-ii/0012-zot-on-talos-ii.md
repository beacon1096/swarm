# ADR talos-ii/0012 — zot OCI mirror in-cluster on talos-ii (Phase 4b)

**Scope:** talos-ii. zot is **not** deployed on talos-i; talos-i (in
the `swarm-01` repo) consumes this same instance via the tailnet
hostname `zot.tail5d550.ts.net:5000`.
**Status:** accepted
**Date:** 2026-04-30

## Context

Phase 4b of the talos-ii rebuild moves the OCI pull-through cache
from the LAN host `172.16.80.240:5000` (a single SATA-disk-backed
zot binary running under systemd on the management VLAN — see
[`docs/operations/zot-mirror.md`](../../operations/zot-mirror.md))
into the cluster as a Flux-managed HelmRelease.

The LAN host was always tagged "chicken-and-egg emergency stopgap"
in the runbook prose: it predated the in-cluster sing-box, the
Cilium L2 announcement pool, and the Longhorn storage tier on
talos-ii. With each of those primitives now in steady state
(attic Phase 4a being the most recent reliance test), the
constraint that forced the registry to live off-cluster is gone.
The follow-up was tracked in user memory
(`project_zot_in_cluster_target.md`) for several weeks waiting for
that platform readiness.

The constitution doesn't say "registries must be in-cluster" in
those words, but it does enforce the per-cluster scoping rule and
the "GitOps-native, Flux-reconciled" rule. A LAN host running a
hand-rolled binary under a one-off systemd unit is the inverse of
both: it can't be expressed in `kubernetes/apps/`, no flux
controller knows about it, and configuration drift (e.g. the
`docker.n8n.io` upstream that was added to the LAN host on
2026-04-28 in commit `ceaee29` but only realised on incident) is
invisible to repo review.

Sub-decisions to nail down:

1. Why **now**, and what changed.
2. The `[talos-ii]` scoping vs. the predecessor `swarm-01` repo's
   per-cluster zot deploys.
3. Helm chart selection (official `zot/zot` vs. the repo's
   `bjw-s app-template` baseline).
4. Storage class (the plan said `longhorn-r2`; reality used the
   default `longhorn`).
5. Probe shape (the chart hardcodes a path the binary doesn't
   serve; how we patched around it).
6. `extensions.search` enablement (with **no** `cve` block).
7. Egress envelope (sing-box, NO_PROXY trailing-dot).
8. Talos `machine.registries.mirrors` cutover shape.
9. Admin credential handling (htpasswd in SOPS, plus the
   chart's `Authorization: Basic` probe header).
10. Cutover commit vs. decommission commit (two-step,
    7-day burn-in gate between them).

## Decision

### 1. In-cluster zot now; LAN host stays as fallback (this phase) and decommissions later

The LAN host `172.16.80.240:5000` is preserved as a second-rank
fallback during Phase 4b. The cutover commit (`e7f3462` —
`feat(talos): cutover containerd mirror endpoints to in-cluster
zot (Phase 4b)`) lists `[in-cluster, LAN host]` as the
two-element `endpoints[]` for each mirrored upstream. This is
deliberately **reversible**:

- If the in-cluster zot has a bad apply or the LB IP fails to
  announce, containerd falls through to the LAN host on a
  per-pull basis without operator intervention. FR-019
  reversibility is satisfied without a rollback commit.
- If the cutover fails catastrophically, the operator reverts
  by re-rendering the `.j2` with the in-cluster IP removed and
  re-applying — a single config-change cycle on each node, no
  reboot.

The decommission step (drop the LAN host from `endpoints[]`,
remove the `"172.16.80.240:5000"` self-referential entry) is
**not** part of this ADR. It rides on its own commit after a
≥ 7-day burn-in window during which the LAN host serves zero
hot-path requests from talos-ii nodes (verified via
`journalctl -u talos-mirror`). The repo-grep success criterion
SC-004 (`grep -r 172.16.80.240 kubernetes/ templates/` returns
zero matches outside `factory.talos.dev`) closes only after that
decommission.

`factory.talos.dev` stays on the LAN host indefinitely. Three
independent reasons:

- **Bootstrap order**: the in-cluster zot can't serve the Talos
  installer for a node that hasn't joined the cluster yet. The
  installer needs to come from a path that exists before talos-ii
  exists. The LAN host is that path.
- **amd64-only schematic**: our schematic is single-arch and
  pre-pushed (curated). Adding `factory.talos.dev` to
  `extensions.sync.registries[]` would race the on-demand fetch
  against the curated push and trip `digest mismatch` loops, the
  same failure mode the original zot-mirror runbook documents.
- **Manifest shape volatility**: factory.talos.dev's manifest
  format has shifted across Talos versions. The LAN host's
  curated push pins exactly what we want; sync would pick up
  whatever upstream emits.

### 2. `[talos-ii]` only — never `[both]`, never replicated to talos-i

Per the per-cluster scoping rule (user memory
`feedback_per_cluster_scoping.md`): one workload, one cluster,
consumed cross-cluster via tailnet. talos-i (NEC8 / Harvester /
KubeVirt nesting) consumes via `zot.tail5d550.ts.net:5000` with
the `proxied` ProxyClass on the tailscale-operator-published
Service (same pattern as `attic-tailscale`).

Concretely: the predecessor `swarm-01` repo has a
`kubernetes/apps/registry/zot/` of its own (LAN host's read-only
reference, plus the in-flight talos-i wiring). That tree does
**not** migrate to this repo, and this repo's
`kubernetes/apps/registry/zot/` does **not** get duplicated to
swarm-01. When (if) talos-i is adopted into this repo, its
`machine.registries.mirrors` will point at the tailnet hostname
above; it will not get its own zot HelmRelease.

This is the same scoping pattern attic (Phase 4a, ADR 0011) and
n8n / coder (ADR 0010) follow. SC-005 (zero zot objects on
talos-i) is enforced by code review at adoption time, not by an
in-repo grep today (since talos-i isn't in this repo yet).

### 3. Official `zot/zot` chart 0.1.79, **not** `bjw-s app-template`

This is the deliberate exception to the repo's chart-uniformity
baseline. attic (0011), n8n / coder (0010), forgejo, vaultwarden,
sing-box all use `bjw-s app-template`. zot does not.

Rationale (research.md Q4):

- zot's `config.json` schema is **deeply nested**:
  `extensions.sync.registries[]` is a list of maps with
  `urls` / `onDemand` / `tlsVerify` / `pollInterval` /
  `content[]` (itself a list of `prefix`/`destination`/
  `stripPrefix` triples) / `maxRetries` / `retryDelay` /
  `certDir`. Mis-typing any of these (especially `onDemand`
  as a string instead of a bool) renders silently and only
  fails at runtime when zot rejects the parsed config.
- The official chart ships a JSON schema for its values that
  validates the `configFiles.config.json` mapping at
  `helm template`/`helm install` time, before flux ever sees
  the rendered manifest. An app-template version of the same
  config would render whatever YAML the operator typed.
- The chart also ships first-class values for htpasswd
  integration (`mountSecret`), GC scheduling, dedupe knobs,
  PVC sizing, and probe timing. Reproducing all of these in
  app-template would be feasible but adds attack surface and
  iteration cost (each PVC fix-up costs a Longhorn rebuild
  cycle).

**This deviation is scoped to zot.** Future reviewers should not
"unify" attic / vaultwarden / coder onto the official chart on
the strength of this ADR. The decision is local to zot's
schema-density problem; nothing else in the repo has the same
shape.

### 4. Default `longhorn` SC, **not** a named `longhorn-r2` SC

`plan.md` / `research.md` / `data-model.md` all originally
specified `storageClassName: longhorn-r2`. At apply time, no
such named SC exists in this repo. The repo's convention is
captured in
`kubernetes/apps/storage/longhorn/app/storageclass-replicated-3.yaml`'s
comment: **"everything else uses default `longhorn` (replicaCount
= 2)"**. The default class **is** the r2 path; there is no
separate `longhorn-r2`.

So the helmrelease lands `pvc.storageClassName: longhorn` with
`pvc.storage: 300Gi`. Replica count 2 is correct (cached
content is reproducible from upstream — Constitution Principle
II's r3-for-irreplaceable-only rule explicitly excludes mirror
caches), the storage class name is the only change.

The PVC is **chart-managed via `volumeClaimTemplates`**, not a
separate `pvc.yaml` in our manifests, because chart 0.1.79's
StatefulSet template builds the VCT from `pvc.*` values
unconditionally and does **not** honor `existingClaim`. A
pre-created PVC would dangle. The PVC materializes at runtime
as `zot-pvc-zot-0`.

### 5. Probes: `tcpSocket` on :5000 via `postRenderers.kustomize.patches[]`

This is the deepest implementation pothole this phase hit. Five
commits chase it in the git log (`6f10ea3` → `1eac6af` →
`e54f85b` → `9f034ab` → `ce42eb3` → `a7422af` → `05457db` →
`d4f8a79` → `fddf4ee`).

Chart 0.1.79's StatefulSet template hardcodes the probe paths to
`/livez`, `/readyz`, `/startupz`. These paths are served by the
`mgmt` extension. zot v2.1.5's binary, **even with `mgmt`
implicitly enabled by `search.enable: true`**, does not expose
these particular paths — kubelet sees 404. The chart's `values`
expose probe **timing** (`failureThreshold`, `periodSeconds`,
…) but **not** the probe **path**.

Three escape attempts that didn't work:

- **`/v2/` httpGet + `authHeader`**: zot v2.1.5's `/v2/` endpoint
  treats htpasswd auth as required even when AccessControl
  permits anonymous-read on `**` repos (the `/v2/` route is the
  registry root, not a repo path). Even with the chart's
  `authHeader: <base64 admin:pw>` value injecting an
  `Authorization: Basic …` header, response shape varied
  enough across container restarts (200 / 401 / 404 depending
  on whether sync extension had finished its first poll) that
  readiness flapped.
- **Drop `auth` block entirely on the probe path**: chart values
  don't expose this — the probe `httpGet.httpHeaders` is what
  the chart renders, period.
- **Force `mgmt` on with explicit `extensions.mgmt.enable: true`**:
  zot v2.1.5 doesn't accept that as a top-level `extensions.mgmt`
  block; `search.enable: true` is the only documented mgmt
  prerequisite, and it doesn't materialize the routes anyway.

The escape that worked: `helmrelease.spec.postRenderers.kustomize.patches[]`
on the rendered StatefulSet. We `op: remove` the
`httpGet` block from each probe and `op: add` a
`tcpSocket: { port: 5000 }`. This proves "process is listening
on the registry port" — weaker than a `/v2/` HTTP-level
health check, but unblocks chart install where the HTTP-level
checks all flap.

**Decision**: probe is a process-level liveness signal. HTTP-level
health is the runbook operator's job, not kubelet's:

- After deploy / upgrade, the runbook prescribes a
  `curl http://172.16.87.51:5000/v2/_catalog?n=200` from a
  debug pod plus a sample image-pull dry-run (`crane pull`
  through the chain). That's the actual "is zot healthy"
  check.
- A future chart bump that exposes probe paths as values, or a
  zot release that materializes `/livez` properly, lets us
  drop the postRenderer.

### 6. `search.enable: true` but **no** `extensions.search.cve` block

Counter-intuitive. We don't actually use zot's search UI; we
use it as a passive on-demand cache only. Why enable search?

Because mgmt extension prerequisite. zot's mgmt routes (which
include `/v2/_zot/ext/mgmt`, `/v2/_zot/ext/userprefs`, …) are
gated on `search.enable: true`. Even though kubelet's
`/livez|/readyz|/startupz` probes don't actually work against
mgmt routes (see §5), having `search.enable: true` is a
prerequisite for the chart to render without complaining, and
it's what every working zot deploy on the public reference
documents.

We deliberately do **not** include `extensions.search.cve` (the
CVE-scan sub-block). Including it triggers a **91 MiB
trivy-db download** at startup (zot fetches the CVE
database from `ghcr.io/aquasecurity/trivy-db` to populate the
scanner). That download blocks `readyz` for 60–90 s on first
boot and re-runs on every Pod restart.

Three reasons not:

- We're a **passive cache**, not a CVE scanner. The
  scan results are never read.
- The 91 MiB download has to traverse sing-box → upstream, which
  is exactly the slow path we're trying to avoid having on
  the Pod's hot startup.
- It re-runs on **every** restart (no on-disk persistence
  between Pod lifecycles). On a Longhorn rebuild that bounces
  the Pod, that's a 90-s pause for nothing.

Commit `9f034ab` (disable search/CVE entirely) walked this back
when we realised mgmt routes need search. Commit `a7422af`
landed the final shape: `search.enable: true`, no `cve`.

### 7. Egress: sing-box via env, NO_PROXY trailing-dot variants

zot's `extensions.sync` calls go upstream (docker.io, ghcr.io,
…) which means egress through GFW. Same envelope as attic /
flux-instance:

```yaml
env:
  - name: HTTP_PROXY
    value: http://sing-box.network.svc.cluster.local:7890
  - name: HTTPS_PROXY
    value: http://sing-box.network.svc.cluster.local:7890
  - name: NO_PROXY
    value: ".svc,.svc.cluster.local,.svc.cluster.local.,cluster.local,cluster.local.,10.0.0.0/8,172.16.0.0/12,localhost,127.0.0.1"
```

**Both** `cluster.local` and `cluster.local.` (trailing dot) MUST
appear in `NO_PROXY`. Go's `net/http/httpproxy` matches NO_PROXY
entries by strict suffix and does not normalize the trailing
dot. Talos pods often resolve in-cluster names with the FQDN
form (trailing dot present); without listing both variants
explicitly, in-cluster service-name lookups silently route
through sing-box and fail because sing-box can't resolve cluster
names. Captured in the attic 2026-04-28 incident write-up;
zot inherits the same workaround.

`cn.tails.beacoworks.xyz` (the cn-qcloud DERP region) is added
to NO_PROXY at the sing-box level (commit `26e6b2c`), not in
this helmrelease — that's the user-memory-tracked
DERP-bypass-for-controlplane-traffic path that the tailscale
proxy pods need, not zot.

### 8. machine-registries cutover: 9 mirrors, 3 newly added, two-endpoint shape

The `machine-registries.yaml.j2` cutover (commit `e7f3462`)
landed:

- **6 existing mirrors** (`docker.io`, `ghcr.io`, `quay.io`,
  `mirror.gcr.io`, `code.forgejo.org`, `docker.n8n.io`):
  `endpoints[]` flipped from `[LAN]` to
  `[in-cluster, LAN]`.
- **3 new mirrors** (`gcr.io`, `registry.k8s.io`,
  `docker.elastic.co`): added with the same two-endpoint shape.
  These three were named in FR-005 but never previously
  configured on the LAN host or anywhere else; Phase 4b is the
  moment to clean up the LAN host's drift.
- **`factory.talos.dev`**: unchanged. Still single LAN host
  endpoint. See §1 above for the three-reasons-deep carve-out.
- **Self-referential `"172.16.80.240:5000"`**: kept. Required
  so any HelmRelease that hard-codes
  `172.16.80.240:5000/foo:bar` (e.g. the sing-box `:init`
  bootstrap path) continues to work plain-HTTP. Removed only at
  the decommission commit.
- **Self-referential `"172.16.87.51:5000"`**: **not** added in
  the cutover commit. The `.j2` comment block above each block
  spells this out: "no symmetric self-ref for 172.16.87.51:5000
  yet because nothing references that hostname directly". When
  a future HelmRelease grows a `172.16.87.51:5000/…` literal,
  add it then.

Apply mode: `talosctl apply --mode=auto` (the path
`task talos:apply-node` uses). `machine.registries` is
non-disruptive in Talos's classification — containerd
re-reads `/etc/cri/conf.d/hosts/<reg>/hosts.toml` on next pull
without a process restart. All three nodes hot-reloaded in
sequence (201 → 202 → 203) with `dmesg` showing no kernel
boot banners, satisfying SC-007.

### 9. Admin credential: htpasswd in SOPS Secret + `authHeader` in HelmRelease

Two flavors of "admin password" coexist. They must stay in sync
or the chart's probe injection (which we then strip — see §5)
errors and the user-facing push-via-`docker login` works while
the probe header doesn't.

- **htpasswd** in `kubernetes/apps/registry/zot/app/secret.sops.yaml`
  (Secret name `zot-secret`, key `htpasswd`). Mounted via
  `extraVolumes` + `extraVolumeMounts` at `/secret/htpasswd`,
  referenced from `config.json`'s
  `http.auth.htpasswd.path: /secret/htpasswd`. This is what
  `docker login`-style pushes authenticate against.
- **`authHeader`** value in `helmrelease.yaml`:
  `${ZOT_PROBE_AUTH_HEADER}`, substituted by Flux postBuild
  from the `cluster-secrets` Secret (the
  `kubernetes/components/sops/cluster-secrets.sops.yaml` file's
  `ZOT_PROBE_AUTH_HEADER` key). Value is `base64(admin:<plaintext>)`,
  which the chart injects as a probe `Authorization: Basic …`
  header. Becomes a no-op once the postRenderer strips the
  httpGet block (§5), but kept in case we revert to httpGet in
  a future chart bump.

**Why not commit a literal base64 in the helmrelease?** Because
the literal contains the plaintext password (base64 is not
encryption). Going via cluster-secrets keeps the password
SOPS-encrypted at rest.

**Rotation**: change both. Edit `secret.sops.yaml`'s `htpasswd`
(re-`htpasswd -bnB`) and `cluster-secrets.sops.yaml`'s
`ZOT_PROBE_AUTH_HEADER` (re-base64) in **one commit**. Same
dual-secret pattern attic uses for its DSN drift (ADR 0011 §6).
The runbook flags this as a footgun.

The vaultwarden admin password rotation is a separate event but
shares the same memory cell of "yet another secret to rotate";
the runbook calls out the bookkeeping.

### 10. Two-step landing: cutover commit, decommission commit

Why split:

- **Cutover** (`e7f3462`): the helmrelease + the machine-registries
  flip. Reversible by removing one endpoint per upstream.
- **Decommission**: drops the LAN host endpoint per upstream,
  drops the `"172.16.80.240:5000"` self-ref. **Irreversible**
  in the sense that the next pull-failure during the burn-in
  would be invisible without the safety net.

The 7-day burn-in is a watch-only period: the LAN host stays
running, in-cluster zot serves all hot-path requests,
`journalctl -u talos-mirror` on the LAN host should show zero
requests from `172.16.87.20[123]`. Once that is empirically
true for a week, the decommission can land.

This is also why **SC-004 (zero `172.16.80.240` references in
rendered output) does not pass at the cutover commit**. SC-004
is closed only after the decommission.

## Consequences

Positive:

- Talos containerd's image pulls now traverse one fewer L3 hop
  (cluster-internal Cilium L2 vs. UDR-mediated inter-VLAN to the
  LAN host) and land on NVMe-backed Longhorn with two replicas
  instead of the LAN host's single SATA disk. Latency-on-cache-hit
  is strictly better; SC-008's qualitative "≤ 1.0× LAN baseline"
  is met without measurement.
- Zero-reboot cutover. Nodes 201/202/203 hot-reloaded
  `machine.registries` via `--mode=auto`; `dmesg` showed no kernel
  boot banners; SC-007 closed.
- Reversibility preserved through the burn-in window. The cutover
  commit alone doesn't cut the LAN host off; if the in-cluster
  zot has a bad pull, containerd falls through.
- The `bjw-s` chart-uniformity rule is preserved everywhere except
  zot. The exception is documented (this ADR §3) and scoped.
- Configuration is now Flux-reconciled, not a hand-rolled systemd
  unit. Schema validation runs at flux-render time. Drift (e.g.
  the `docker.n8n.io` upstream that was added off-repo on the LAN
  host on 2026-04-28) is no longer possible.
- talos-i wiring is unblocked: when its phase ships, it points at
  `zot.tail5d550.ts.net:5000` and consumes through the same
  proxied tailnet path attic / forgejo already use.

Negative / accepted trade-offs:

- **Probe shape weakened to `tcpSocket`** (§5). HTTP-level
  health is now a runbook concern, not kubelet's. A zot binary
  that listens on :5000 but serves 500s for every `/v2/`
  request would pass kubelet's probe and fail real traffic.
  Acceptable because (a) zot's failure modes in practice are
  catastrophic (Pod doesn't start, listener doesn't bind) and
  the tcpSocket catches those, and (b) the runbook prescribes
  a real probe.
- **Chart 0.1.79 schema quirks lock us into a postRenderer
  (§5) and a specific `mountSecret: false` + `extraVolumes`
  workaround (§9)**. Both will need attention on every chart
  bump — the runbook's chart-upgrade section walks through
  re-checking these.
- **Two SOPS files per password rotation** (§9). Same shape
  as attic's DB password rotation; same runbook prominence.
- **`search.enable: true` without `cve` (§6)** is a brittle
  configuration: a future zot release that requires the full
  search stack would force us to either accept the trivy-db
  cost or re-evaluate. Tracked as runbook caveat.
- **The 7-day burn-in defers SC-004** (§10). For a calendar
  week after the cutover commit, repo grep for
  `172.16.80.240` returns hits — by design.
- **`factory.talos.dev` stays on the LAN host indefinitely
  (§1)**. This is not Phase 4b's problem to solve and probably
  never will be — the chicken-and-egg is fundamental.

## Related

- [ADR 0007](0007-cloudnative-pg-operator.md) — CNPG operator decision (egress-proxy precedent)
- [ADR 0010](0010-coder-n8n-cnpg.md) — same dual-secret rotation pattern
- [ADR 0011](0011-attic-cnpg.md) — egress-proxy + image-pull-format precedent; tailnet `proxied` ProxyClass; per-Service tailscale Pod in `network` ns
- [Operations: zot in-cluster (Phase 4b)](../../operations/zot-restore.md)
- [Operations: zot LAN host (Phase 4a and earlier)](../../operations/zot-mirror.md)
- [Operations: sing-box egress](../../operations/sing-box-egress.md) — the `HTTP_PROXY` target
- [Operations: tailscale-operator](../../operations/tailscale-operator.md) — the `proxied` ProxyClass requirement
- [Operations: Flux + Helm recovery](../../operations/flux-helm-recovery.md) — referenced from §5 for stuck-HR recovery
- [specs/002-zot-on-talos-ii/](../../../specs/002-zot-on-talos-ii/) — spec / plan / research / data-model / quickstart / contracts
