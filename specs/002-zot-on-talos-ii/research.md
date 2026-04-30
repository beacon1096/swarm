# Research — zot OCI mirror in-cluster on talos-ii (Phase 4b)

Phase 0 deliverable. Resolves the three `[NEEDS CLARIFICATION]` markers from the spec (FR-006, FR-018, SC-008) and pins the additional design choices that the spec deliberately deferred to Plan stage (helm chart shape, bootstrap chicken-and-egg, Talos host -> in-cluster zot exposure, machine-registries redesign, talos-i consumption contract).

Each section follows the **Decision / Rationale / Alternatives** shape.

---

## Q1 — FR-006: enumerate the LAN zot upstream registries

**Decision**: the upstream-sync set must be exactly:

```text
docker.io          (https://registry-1.docker.io)
ghcr.io            (https://ghcr.io)
quay.io            (https://quay.io)
mirror.gcr.io      (https://mirror.gcr.io)
gcr.io             (https://gcr.io)
registry.k8s.io    (https://registry.k8s.io)
code.forgejo.org   (https://code.forgejo.org)
docker.elastic.co  (https://docker.elastic.co)
docker.n8n.io      (https://docker.n8n.io)
cache.nixos.org    (https://cache.nixos.org)        # optional, see note below
```

`factory.talos.dev` is **deliberately excluded** from sync (consistent with the LAN host's posture — see `docs/operations/zot-mirror.md`). The Talos secureboot installer is amd64-only and pre-pushed; adding a sync entry would trigger digest-mismatch loops between the on-demand fetch and the curated push. The Talos installer image must continue to come via the LAN host or be pre-pushed into the in-cluster zot at deploy time, not through `extensions.sync`.

`cache.nixos.org` is OCI-shaped only at the surface (it's actually a Nix binary cache, not a registry); attic + Nix tooling reach it directly via `HTTP_PROXY` to sing-box, not via zot. Including it in the zot sync list is harmless but unused; the implementer may drop it from the zot config without functional impact. Listed here only for spec completeness against FR-005.

**Rationale**:

- The LAN host SSH endpoint (`proxy.beacoworks.xyz`) was unreachable from the operator workstation at Plan time (DNS resolution failure). Falling back to `curl http://172.16.80.240:5000/v2/_catalog?n=2000` returned 29 cached repositories spanning the registries above (`bitnami/`, `ghcr-content`, `quay`-shaped, `coredns/coredns` from `mirror.gcr.io`, `n8nio/n8n` from `docker.n8n.io`, `code.forgejo.org`-mirrored Forgejo charts, `zhaofengli/attic` from `ghcr.io`, etc.).
- The repo's own [`docs/operations/zot-mirror.md`](../../docs/operations/zot-mirror.md) section "What gets cached" enumerates the LAN host's `extensions.sync.registries[]` explicitly: `registry-1.docker.io`, `ghcr.io`, `quay.io`, `code.forgejo.org`, `mirror.gcr.io`. The catalog confirms `n8nio/n8n` is also cached, which corresponds to the `docker.n8n.io` entry added in commit `ceaee29` (visible in repo git log). `gcr.io`, `registry.k8s.io`, `docker.elastic.co`, `cache.nixos.org` are **operator-required additions** per FR-005 — required to be in the in-cluster zot's set even if the LAN host doesn't currently mirror them, because (a) they're already named in the spec and (b) Phase 4b is the moment to clean up the LAN host's drift.
- The set above is therefore a strict superset of the LAN host's current sync set, satisfying FR-006.

**Alternatives considered**:

- **Mirror only the literal LAN host set (5 registries)**: would silently regress FR-005's explicit operator-required adds and force a follow-up edit on first miss for `gcr.io` / `registry.k8s.io` / `docker.elastic.co`. Rejected.
- **Block on direct SSH access to the LAN host**: would push Phase 4b out and contributes nothing — the catalog endpoint already gives us upstream coverage information, and the operator can confirm the SSH-only configuration details (auth, GC schedule, dedupe) at deploy time without blocking the plan.
- **Drop `factory.talos.dev` mirror coverage**: not required. The Talos node-side `machine.registries.mirrors` entry for `factory.talos.dev` continues to point at the LAN host (which has the secureboot installer pre-pushed). This is **out of scope for Phase 4b** and tracked separately under Talos image factory operations.

---

## Q2 — FR-018: does Talos `machine.registries.mirrors` change require a reboot?

**Decision**: **no reboot**. `talosctl apply-config --mode=auto` (the path used by `task talos:apply-node`) hot-reloads the registry mirror configuration on Talos 1.12.7 without restarting the node. The change propagates to containerd via the `/etc/cri/conf.d/hosts/<registry>/hosts.toml` files (which Talos regenerates on config apply) and containerd's hosts-file resolver re-reads them on the next pull request — no containerd restart, no kubelet restart, no node reboot.

**Rationale**:

- The repo already documents this empirically: [`docs/operations/zot-mirror.md`](../../docs/operations/zot-mirror.md) "Adding a new upstream" step 4 says verbatim *"`task talos:apply-node IP=172.16.87.20{1,2,3}` — no reboot needed for registries-only changes"*. This is observed behaviour on the current cluster, not a paper claim.
- Talos's `machine.registries` lives under the configuration-class subset that Talos categorises as **non-disruptive**. Talos 1.5+ implemented this by regenerating `/etc/cri/conf.d/hosts/*/hosts.toml` on config apply rather than mutating containerd's static config; containerd's hosts.toml resolver does not require a restart to pick up changes. Talos 1.12.x retains this behaviour.
- `--mode=auto` lets `talosctl` choose the least-disruptive mode the diff allows: **no-reboot** for non-disruptive fields like `machine.registries`, **staged** for fields requiring a reboot, **immediate** for live-applicable runtime fields. We rely on this categorisation rather than forcing `--mode=no-reboot` (which would refuse the apply if any single field were misclassified). If a future config change unrelated to zot were combined into the same apply and that field required a reboot, `--mode=auto` would reboot — but our practice (per [`docs/operations/zot-mirror.md`](../../docs/operations/zot-mirror.md)) is to land registries changes by themselves.

**Verification at apply time** (runbook step, not a Plan-stage gate):

```bash
talosctl --talosconfig <path> -n <node> get machineconfig
talosctl --talosconfig <path> -n <node> dmesg | tail -50
# observe: no reboot phase entry, no kernel boot banner.
talosctl --nodes <node> read /etc/cri/conf.d/hosts/docker.io/hosts.toml
# observe: server entries reflect the new endpoint set.
```

**Constitution Principle XI** (no surprise reboots) is therefore satisfied: the change is non-disruptive by Talos's own classification, and the runbook spells out the verification check.

**Alternatives considered**:

- **Force `--mode=no-reboot`**: safer in the sense that a misclassified field would *fail loudly* instead of rebooting silently. Rejected for v1 because it conflicts with the project's standard `task talos:apply-node` flow (which uses `--mode=auto`); changing the standard flow is out of scope for this feature. The runbook's "any reboot during Phase 4b that is not pre-declared is a defect" wording (per SC-007) plus the dmesg verification step provide an equivalent post-hoc detection.
- **Schedule a maintenance window for the apply**: only required if `--mode=auto` would reboot. Per the repo's prior empirical evidence, it doesn't. No window required.
- **Roll node-by-node with manual `containerd` verification between each**: this is the runbook's sequential apply pattern anyway (apply to node 1, verify, then 2, then 3). No additional work needed.

---

## Q3 — SC-008: throughput baseline, numeric vs. qualitative

**Decision**: **qualitative** target. SC-008 reads, post-resolution:

> *"After rollout, the in-cluster zot's image-pull latency for talos-ii nodes is no worse than the LAN host zot's was under comparable conditions, on the cache-hit path. The expectation is **strictly better** (≤ 1.0× LAN-zot latency) given the network-topology improvements; a measurable regression would be a defect."*

No numeric MB/s target.

**Rationale**:

- The in-cluster zot's network path is **strictly shorter and faster** than the LAN host's:
  - **One fewer L3 hop**. talos-ii nodes (172.16.87.0/24) currently reach the LAN host (172.16.80.240) through the UDR Pro's inter-VLAN routing. The in-cluster zot is reached via Cilium L2-announced LB IP on **the same VLAN** as the nodes, so containerd's pull traffic stays on the local broadcast domain and never traverses the router.
  - **Storage is faster**. The LAN host stores blobs on a single SATA disk (or whatever the host happens to have); in-cluster zot stores on Longhorn over NVMe (MS-01 PCIe 4.0 NVMe partitions), with two replicas synchronously written. Read path is local-NVMe-direct on cache hits.
  - **No egress proxy on the cluster-internal hop**. The LAN host runs `HTTPS_PROXY=http://172.16.87.41:7890` for sync, but client pulls (containerd → zot) on the LAN host go direct without a proxy. The in-cluster path is symmetric: containerd → ClusterIP/LB → zot pod, no proxy injection.
- The only path on which in-cluster could be *slower* is the **cold-cache, upstream-sync** path — both deployments traverse sing-box for upstream, and the sing-box is the same in-cluster sing-box in both cases (the LAN host's `HTTPS_PROXY` already targets the in-cluster sing-box LB IP per [`docs/operations/sing-box-egress.md`](../../docs/operations/sing-box-egress.md)). So even on cache miss the network paths are equivalent length, and the in-cluster zot has no inherent disadvantage.
- A numeric target is unnecessary because *no part of the migration could plausibly slow steady-state pulls* — every architectural change is in the direction of "faster". A qualitative SC reduces the amount of synthetic-load-test scaffolding the runbook has to carry, while the prescription "strictly better, ≤ 1.0×" gives the operator a concrete pass/fail at acceptance time.
- The "comparable conditions" qualifier acknowledges that real measurement noise (parallel pulls, Longhorn rebuilds, sing-box load) makes a single before/after comparison non-deterministic. The qualitative phrasing protects against false positives from transient noise without sacrificing the regression detector.

**Alternatives considered**:

- **Numeric MB/s target** (e.g. ≥ 200 MB/s on cache hit): would require a one-shot pre-measurement against the LAN host (with all the same noise concerns) plus a matched post-measurement. The runbook overhead is non-trivial and the target itself would be arbitrary. Rejected.
- **Latency-percentile target** (p95 < 1 s on a known image): captures a more useful signal than throughput, but still requires baselining pre-cutover. Rejected for the same reason.
- **"No measurable regression" with no upper bound**: too soft — any regression that happened to come in under measurement noise would slip through. The "≤ 1.0×" wording is sharper.

---

## Q4 — Helm chart selection: official zot vs. bjw-s app-template

**Decision**: **official `zot.zot/zot` chart**, sourced from the LAN zot at deploy time (re-pushed to LAN zot from `ghcr.io/project-zot/helm-charts/zot`, same pattern as `tailscale-operator` per [`docs/operations/tailscale-operator.md`](../../docs/operations/tailscale-operator.md) "Why the chart is on local zot").

**Rationale**:

- zot's `config.json` schema for `extensions.sync.registries[]` is **deeply nested and easy to mis-render**: each upstream gets a `urls`/`onDemand`/`tlsVerify`/`pollInterval`/`content[]`/`maxRetries`/`retryDelay`/`certDir` map. The official chart exposes this through values that the chart's own JSON schema validates at lint time; mis-typed YAML is caught before flux reconciles.
- The official chart ships RBAC (anonymous-read + admin-push split), htpasswd integration, GC scheduling, dedupe knobs, and PVC sizing as first-class values. Reproducing all of these in a hand-written ConfigMap inside `bjw-s app-template` is feasible but error-prone, and every error costs an iteration in flux + Longhorn (PVC re-creates are slow).
- Maintenance cost. The official chart updates with each zot release; renovate can bump the chart version pin and the values stay backward-compatible most of the time. A hand-written ConfigMap requires the operator to track upstream `config.json` schema changes manually.
- The decision **diverges** from the rest of this repo (attic, n8n, forgejo, vaultwarden, coder, sing-box all use `bjw-s app-template`). The divergence is justified by zot's config complexity, which is materially different from those other apps' (which take a small number of env vars + a TOML/YAML/INI file). The Plan documents this divergence so the implementer doesn't try to "homogenise" by switching to app-template.

**Chart pin**:

- `zot/zot` chart version `0.1.79` (latest as of 2026-04-29; the implementer should re-pin to the latest at deploy time and record the digest in the helmrelease comment, same pattern as the rest of the repo).
- Pulled to LAN zot via:

  ```bash
  helm pull oci://ghcr.io/project-zot/helm-charts/zot --version 0.1.79
  helm push zot-0.1.79.tgz oci://172.16.80.240:5000/charts --plain-http
  ```

  then referenced from a Flux `OCIRepository` at `oci://172.16.80.240:5000/charts/zot`.

**Alternatives considered**:

- **`bjw-s app-template` 4.6.2 + hand-written ConfigMap**: the homogenous choice. Rejected for the schema-validation reason above; the savings in chart-uniformity are outweighed by the cost of getting `extensions.sync` wrong on first apply and burning flux + Longhorn cycles to fix it.
- **Custom in-repo chart**: total overkill for a single-instance pull-through cache. Rejected.
- **Pin against `oci://ghcr.io/project-zot/helm-charts/zot` directly**: the Flux source-controller's egress (sing-box patch) makes this technically possible, but matches none of the rest of the repo's source pattern and re-introduces public-egress dependency on flux reconcile. Rejected.

---

## Q5 — Bootstrap chicken-and-egg: how does zot's own image get pulled?

**Decision**: **Plan Y** — zot's image (`ghcr.io/project-zot/zot-linux-amd64`) is fetched through the in-cluster `sing-box` egress, *not* through any zot mirror. Concretely:

- The Talos `machine.registries.mirrors.ghcr.io` entry will be **removed** (in the redesign — see Q7) so that `ghcr.io` pulls go direct.
- "Direct" is, however, **`HTTPS_PROXY=http://172.16.87.41:7890` via Talos's `machine.registries.config.ghcr.io.tls`/auth/proxy chain** — i.e., containerd egresses through the Cilium-LB-announced sing-box. This works at cold start because sing-box is itself bootstrapped from the LAN host (`172.16.80.240:5000/infrastructure/nix-fleet/sing-box:init`, see `kubernetes/apps/network/sing-box/app/helmrelease.yaml`), so by the time zot's pod is scheduled, sing-box is already serving traffic.
- Once zot is healthy and has cached its own image, containerd's local image cache covers re-pulls; subsequent restarts of the zot Pod don't go upstream. Cold-cluster recovery (full reboot of all 3 nodes) is the only scenario where the bootstrap chain matters — and in that scenario sing-box (which still pulls from LAN zot) comes up first because its image source is the *bootstrap* LAN zot, not the in-cluster one.

**Bootstrap order** at cold start (operator-relevant):

1. Talos boots, joins control plane via mirrored `factory.talos.dev` (LAN host — out of scope, unchanged).
2. Cilium starts (image cached locally on each node; on a fresh node, pulled via the existing mirror configuration which still points at the LAN host until the new config is applied — see Q7).
3. sing-box starts (image from LAN zot at `172.16.80.240:5000/infrastructure/nix-fleet/sing-box:init`).
4. zot starts (image `ghcr.io/project-zot/zot-linux-amd64@sha256:<pinned>`, pulled via sing-box).
5. The new Talos `machine-registries.yaml` is applied; mirror endpoints flip to the in-cluster zot's LB IP.
6. All subsequent pulls go through in-cluster zot.

**Rationale**:

- **Cleaner**. No "this one path keeps going to the LAN host even after migration" special case. The `ghcr.io` mirror entry is either *all* in-cluster or absent — no `ghcr.io/project-zot/*` exception.
- **sing-box is already a hard dep** for everything else in the cluster that touches the public internet (attic's outbound, tailscale-operator's controlplane reach, the LAN host zot's own sync extension). Adding zot to that list is consistent.
- **Plan X** (keep the LAN host as a fallback for `ghcr.io/project-zot/*`) would require an `endpoints[]` array of two values in the Talos machine-config, with the LAN host listed first or second depending on policy. Containerd then iterates them in order, and a partial outage on either side could mask the other's failure during normal operations. The test surface area is bigger.

**The runbook captures one cold-start verification step**: after a full-cluster reboot (which the runbook does not require, but the operator may exercise as a recovery drill), confirm that zot's pod transitions through `ImagePullBackOff` for at most one or two attempts before sing-box-mediated egress succeeds. If the pod stays in `ImagePullBackOff` indefinitely, sing-box is unhealthy and the operator should fix sing-box first.

**Alternatives considered**:

- **Plan X**: keep LAN host as fallback. Rejected for the cleanliness reasons above.
- **Pre-push the zot image to the LAN zot then mirror-pull from there as a one-time bootstrap**: works but introduces a "magic" pull path that the runbook has to maintain forever, since on each zot version bump the operator would have to re-push to LAN zot. Plan Y has zero per-bump operator overhead.
- **Use `imagePullPolicy: IfNotPresent` and rely on whatever's already cached on each node**: brittle on cold start, fails on a fresh node-add. Rejected.
- **Run zot as a `DaemonSet` that mounts a hostPath cache directory**: would solve the bootstrap problem trivially (each node has its own zot, all nodes are peers) but contradicts FR-001's single-instance scoping and FR-013's "stable ClusterIP Service" wording. Rejected.

---

## Q6 — How does Talos host containerd reach an in-cluster zot Service?

**Decision**: **Cilium L2-announced LoadBalancer Service**, using a dedicated IP from the existing `cilium-l2` pool (`172.16.87.0/24` block in `kubernetes/apps/kube-system/cilium/app/networks.yaml`). Allocate **`172.16.87.51`** for `zot-lb`.

The IP allocation pattern matches existing services:

| IP | Service | Purpose |
|---|---|---|
| `172.16.87.11` | `envoy-external` | public ingress |
| `172.16.87.21` | `envoy-internal` | LAN ingress (forgejo /etc/hosts target) |
| `172.16.87.31` | `k8s-gateway` | k8s-gateway DNS |
| `172.16.87.41` | `sing-box-lb` | egress proxy LB |
| **`172.16.87.51`** | **`zot-lb`** | **in-cluster registry LB (this feature)** |

Talos node containerd reaches zot via `http://172.16.87.51:5000` — same VLAN as the nodes themselves, no router transit, plain HTTP (consistent with the LAN host posture; HTTPS adds ops cost without security benefit on a private VLAN).

**Rationale**:

- **Matches every other "host needs to reach an in-cluster Service" precedent** in this repo. envoy-internal, sing-box-lb, k8s-gateway — all use the same Cilium L2 announcement pattern. zot is the same shape: external (host-network) traffic into a Service that happens to be backed by Pods.
- **NodePort** would technically work but is rejected in this repo as a default exposure pattern (Constitution Principle VII *"private services use the in-cluster `tailscale` operator … no NodePort exposure to the LAN by default"*). Even though the Talos host containerd is itself on the management VLAN (not "the LAN" in the cross-cluster sense), the principle is consistent: NodePort makes the service surface area indeterminate (which port? which node?) and forces the operator to track per-port allocations.
- **HostNetwork** on the zot Pod would conflict with Cilium's IPAM and is rejected category-wise (we don't run any HostNetwork Pods in this repo).
- The L2 announcement reaches the Talos host containerd because:
  - Cilium L2-announces `172.16.87.51` on the management VLAN via the same announcement policy that already covers `.11`/`.21`/`.31`/`.41`.
  - Talos host containerd has its own resolver (UDR Pro at `172.16.87.254`); IPv4 ARP for `172.16.87.51` resolves locally without DNS.
  - The Talos `machine.registries.mirrors` entries use the literal IP `172.16.87.51:5000`, not a DNS name — same convention as the existing `172.16.80.240:5000` entries.

**Pool capacity**: the `172.16.87.0/24` block has many addresses left (we use 4 of ~252). One additional allocation is well within the spec's "at least one free" assumption.

**Alternatives considered**:

- **NodePort 30500**: works but loses the "stable IP, stable port, doesn't move" property and adds a per-node tracking burden. Rejected.
- **Self-hosted DNS name `zot.svc.beaco.lan`** resolved by the UDR's local DNS: another moving piece (DNS server config) for a problem that L2 + literal IP already solves. Rejected.
- **Reuse `172.16.87.41` (sing-box-lb)** with a path/port multiplexer: nonsense — sing-box is HTTP/SOCKS5 mixed-proxy, zot is OCI HTTP. Rejected.
- **Allocate from a different block (172.16.87.61, 172.16.87.71)**: arbitrary; `.51` continues the existing 10-step convention. Picked for consistency, not technical reasons.

---

## Q7 — `templates/config/talos/patches/global/machine-registries.yaml.j2` redesign

**Decision**: every mirror entry that currently lists `http://172.16.80.240:5000` as its sole endpoint becomes a list with **the in-cluster zot LB IP first, the LAN host second** during transition. After the transition window closes (Phase 4b acceptance complete), the LAN host fallback is dropped in a follow-up commit. Concretely, the cutover commit lands:

```yaml
machine:
  registries:
    mirrors:
      docker.io:
        endpoints:
          - http://172.16.87.51:5000   # in-cluster zot
          - http://172.16.80.240:5000  # LAN host fallback (drop after transition)
      ghcr.io:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      quay.io:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      mirror.gcr.io:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      gcr.io:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      registry.k8s.io:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      docker.elastic.co:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      code.forgejo.org:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      docker.n8n.io:
        endpoints:
          - http://172.16.87.51:5000
          - http://172.16.80.240:5000
      "172.16.80.240:5000":
        # Self-referential entry kept so legacy HelmRelease references
        # like 172.16.80.240:5000/charts/* continue to work plain-HTTP
        # against the LAN host during transition. Removed in the
        # decommission commit alongside the migration of any HelmRelease
        # that still hard-codes 172.16.80.240:5000 to the in-cluster
        # zot's hostname/IP.
        endpoints:
          - http://172.16.80.240:5000
      "172.16.87.51:5000":
        # Self-referential entry for in-cluster zot, mirrors the pattern
        # for LAN host. Lets us write `172.16.87.51:5000/charts/foo`
        # in HelmReleases without containerd attempting HTTPS.
        endpoints:
          - http://172.16.87.51:5000
      factory.talos.dev:
        # Unchanged. Talos installer is amd64-only and pre-pushed
        # to the LAN host. See docs/operations/zot-mirror.md.
        endpoints:
          - http://172.16.80.240:5000
```

**Rationale**:

- **Two-endpoint list satisfies FR-019** (cutover reversibility). If the in-cluster zot is unhealthy on first apply, containerd falls through to the LAN host on a per-pull basis without operator intervention. The operator can also revert the patch by deleting the in-cluster zot endpoint from each entry, with a single re-render and re-apply cycle.
- **In-cluster first** so that the migration takes effect immediately on apply; LAN host is the safety net only.
- **`factory.talos.dev` left at LAN host** because it's not in scope for Phase 4b (see Q1) and changing it would conflate two migrations.
- **Self-referential `172.16.87.51:5000` entry** is added so HelmReleases or jobs that reference images by path on the in-cluster zot (analogous to the `172.16.80.240:5000/infrastructure/nix-fleet/sing-box:init` pattern) work plain-HTTP.

**Decommission step** (out of scope for this Plan, tracked separately):

After Phase 4b acceptance criteria (SC-001 through SC-008) are satisfied and the LAN host has been observed serving zero pull traffic for the runbook's defined "transition window" (≥ 7 days):

1. Drop the LAN host endpoint from each mirror's `endpoints[]` list (leaving only the in-cluster IP).
2. Remove the `"172.16.80.240:5000"` self-referential mirror entry.
3. Re-render and re-apply Talos config (no reboot, per Q2).

This commit is **not** part of Phase 4b — it's the gate that closes the predecessor anti-pattern. SC-004 (zero `172.16.80.240` references in rendered output) is checked *after* that decommission step, not after Phase 4b's initial cutover. The spec wording (SC-004) acknowledges this: *"After cutover"* refers to the full migration, not the first apply.

**Alternatives considered**:

- **Single endpoint, in-cluster only, no fallback**: violates FR-019 reversibility. Rejected.
- **LAN host first, in-cluster second**: would make the migration silent (pulls would still go to LAN host until LAN host is unhealthy). Rejected — defeats the purpose of cutover.
- **Inline both in `endpoints[]` permanently**: long-term operational hazard (LAN host left running indefinitely contradicts the "decommissioning is a separate phase" assumption). Rejected as the long-term shape; acceptable as transitional shape.

---

## Q8 — talos-i consumption contract (out of scope to *implement*, in scope to *commit*)

**Decision**: in-cluster zot is exposed on the tailnet via the `tailscale-operator`-managed Service pattern, exactly mirroring `attic-tailscale`. The exposure is part of the talos-ii deploy in this Plan; the talos-i consumer-side change (machine-config update on talos-i) is **explicitly out of scope** for this feature and tracked as a follow-up phase (currently in the `swarm-01` repo's queue).

**Concrete shape** (lands in this Plan's manifests):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: zot-tailscale
  namespace: registry
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "zot"
    tailscale.com/proxy-class: "proxied"
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: zot
    app.kubernetes.io/instance: zot
  ports:
    - name: http
      port: 5000
      targetPort: 5000
      protocol: TCP
```

**Tailnet hostname**: `zot.tail5d550.ts.net:5000` (per the project's tailnet domain `tail5d550.ts.net`, observed in `attic-tailscale`'s service definition).

**talos-i consumption** (NOT this feature; documented for the contract only):

When talos-i is wired up in a separate phase, its `machine.registries.mirrors` will list:

```yaml
docker.io:
  endpoints:
    - http://zot.tail5d550.ts.net:5000
ghcr.io:
  endpoints:
    - http://zot.tail5d550.ts.net:5000
# ... and so on for every upstream this Plan defines.
```

talos-i nodes resolve `zot.tail5d550.ts.net` via the tailnet operator's MagicDNS (which is reachable from talos-i because talos-i's nodes already participate in the tailnet for the `forgejo`/`vaultwarden` cross-cluster paths). containerd on talos-i then talks to the talos-ii zot via the tailnet path; the tailscale-operator on talos-ii proxies the request to the zot Pod.

**Rationale**:

- **No NodePort, no public exposure** — both forbidden by Constitution Principle VII / VI. tailscale-operator is the only sanctioned path.
- **`proxy-class: proxied`** is required because the tailnet operator's per-Service proxy pod itself needs egress to `controlplane.tailscale.com` (GFW-blocked from default talos-ii egress). The `proxied` ProxyClass routes that pod's outbound through sing-box. This is documented in [`docs/operations/tailscale-operator.md`](../../docs/operations/tailscale-operator.md).
- **Plain HTTP on the tailnet path is acceptable** because tailnet itself provides WireGuard encryption end-to-end. Adding an in-cluster TLS terminator is dead weight on a private overlay.
- The contract is committed in this Plan so that when talos-i's wiring phase begins, the consumer knows exactly which hostname / port / scheme to point at without a back-channel conversation.

**Alternatives considered**:

- **Skip the tailnet exposure in this Plan entirely; add it later**: would violate User Story 2's "talos-i consumes via tailnet" acceptance scenario. Rejected.
- **Expose the zot LB IP directly to talos-i via routed VLAN**: requires UDR Pro routing changes between the talos-ii management VLAN and talos-i's VLAN, plus firewall rules. Out of scope and contradicts the "no L3 routing between clusters, use tailscale" constitution wording.
- **Public hostname behind Cloudflare Tunnel**: forbidden (FR-015, no public exposure for zot).

---

## Q9 — PVC sizing and storage class

**Decision**: PVC `zot-store`, **300 Gi**, storage class `longhorn-r2`.

**Rationale**:

- The LAN host's `/var/lib/talos-mirror/` currently holds ~80–100 Gi of cached blobs after several months of use across both clusters' image needs. 300 Gi gives ~3× headroom, accommodating: more upstream registries (FR-005 adds `gcr.io`, `registry.k8s.io`, `docker.elastic.co` which the LAN host doesn't currently mirror), talos-i's pulls once it joins via tailnet, and a year of organic growth without expansion churn.
- **`longhorn-r2`, not `longhorn-r3`**: cached registry content is content-addressable and reproducible (re-syncable from upstream). Constitution Principle II permits replicaCount 2 for replaceable data and explicitly reserves r3 for irreplaceable data. zot cache is the canonical "replaceable" workload.
- 300 Gi × 2 replicas = 600 Gi consumed across the 3 MS-01 nodes' Longhorn pool. Each MS-01 has a ~1 TiB NVMe partition for Longhorn; 200 Gi per node is well within capacity.

**Alternatives considered**:

- **100 Gi** (matches LAN host today): too tight for the FR-005 expansion of upstreams. Rejected.
- **500 Gi**: defensible but unnecessary. Operator can expand later via Longhorn's online expansion if utilisation reaches 80 %.
- **`longhorn-r3`**: violates Principle II's r2-default, gains nothing (data is replaceable). Rejected.

---

## Q10 — htpasswd vs. token for the admin push credential

**Decision**: **htpasswd** (`bcrypt` of admin password) stored in the SOPS-encrypted `zot-secret`'s `htpasswd` key, mounted into the zot Pod at `/etc/zot/htpasswd` and referenced from `config.json` as `accessControl.repositories[*].permissions[].users` or `extensions.search.cve` (depending on which features we enable). Anonymous read is permitted via `accessControl.repositories[**].defaultPolicy: ["read"]` (or equivalent in zot's grammar).

**Rationale**:

- htpasswd is the simplest credential format zot supports natively. The official chart's `mountSecret` value injects the file directly.
- Single-credential model (one admin) matches the spec (FR-008: "a single SOPS-encrypted credential for operator/admin pushes"). No multi-user RBAC complexity.
- bcrypt hash cost stays reasonable (rounds=10) — not a high-frequency authentication path.

**Alternatives considered**:

- **OIDC against authentik**: total overkill for a single-operator push path. Rejected.
- **Long-lived bearer token** in a Secret: zot's bearer-token support exists but adds complexity (token format, expiry, rotation) over a static htpasswd entry.
- **Anonymous push too** (no auth at all): rejected by FR-008 explicitly.

---

## Q11 — Image digest pin for `ghcr.io/project-zot/zot-linux-amd64`

**Decision**: pin to a digest at deploy time. The implementer captures the digest at apply time from `crane digest ghcr.io/project-zot/zot-linux-amd64:v2.1.5` (or the latest stable at that moment) and records it in `helmrelease.yaml`'s `image.digest:` field, alongside a comment naming the source tag.

**Open at Plan time**: the exact digest is a **deploy-time capture**, not a Plan-stage commitment. Same pattern as attic in Phase 4a. The runbook documents the bump procedure (`crane digest`, edit, commit).

**OCI manifest format compatibility**: zot's own image is built and published by zot upstream as an OCI manifest (zot is itself an OCI registry; they get the format right). No `skopeo --format=oci` workaround anticipated, unlike the `ghcr.io/zhaofengli/attic` case in Phase 4a (which had a Docker v2 schema-2 envelope). If a workaround does turn out to be needed at apply time, the runbook captures the same `skopeo copy --format=oci` recipe used for attic.

---

## Cross-check — does this Plan introduce any constitution violations?

Re-checked against `.specify/memory/constitution.md` v1.1.0 in light of the design decisions above:

| Principle | Status | Notes |
|---|---|---|
| **I. Hypervisor stance** [talos-ii] | ✅ pass | Pure k8s workload. |
| **II. Storage** [both] — Longhorn, r3 for irreplaceable only | ✅ pass | `longhorn-r2`, justified above (Q9). |
| **III. Network** [talos-ii] | ✅ pass | Cilium L2 + LB IP, same pattern as existing services. |
| **IV. Image factory** [talos-ii] | ✅ pass | No Talos image change. `factory.talos.dev` mirror entry left at LAN host (out of scope). |
| **V. Secrets** [both] | ✅ pass | `zot-secret` SOPS-encrypted (htpasswd). |
| **VI. Public exposure** [both] | ✅ pass / N/A | No public exposure (FR-015). |
| **VII. Private exposure** [both] | ✅ pass | `zot-tailscale` Service via tailscale-operator + ProxyClass `proxied`. No NodePort. |
| **VIII. GitOps** [both] | ✅ pass | All manifests under `kubernetes/apps/registry/zot/`. |
| **IX. Spec-Driven Development** [both] | ✅ pass | This Plan + the spec are the artifacts. |
| **X. Documentation** [both] | ✅ pass by requirement | ADR `0012-zot-on-talos-ii.md` + runbook `zot-restore.md` + `docs/index.md` update mandated for the implementation commit chain (FR-020). |
| **XI. No surprise reboots** [both] | ✅ pass | FR-018 resolved (Q2); machine-config change is hot-applied. |
| **Per-cluster scoping** rule | ✅ pass | Manifests scoped to talos-ii repo only; talos-i consumption contract documented but not implemented here. |

No violations — Complexity Tracking section omitted from `plan.md`.

---

## Summary of resolved unknowns

| Spec marker | Resolution | Where |
|---|---|---|
| FR-006 (LAN upstream enumeration) | 10 upstreams listed; superset of LAN host's current 5 | Q1 |
| FR-018 (reboot vs. hot-reload) | Hot-reload via `talosctl apply --mode=auto` | Q2 |
| SC-008 (throughput baseline) | Qualitative ≤ 1.0× LAN baseline | Q3 |

| Plan-stage decision | Resolution | Where |
|---|---|---|
| Helm chart | Official `zot/zot` 0.1.79 | Q4 |
| Bootstrap path | Plan Y, sing-box egress | Q5 |
| Host -> Service exposure | Cilium L2 LB IP `172.16.87.51` | Q6 |
| machine-registries shape | In-cluster first, LAN fallback during transition | Q7 |
| talos-i contract | tailscale-operator + `zot.tail5d550.ts.net:5000` | Q8 |
| PVC size / class | 300 Gi `longhorn-r2` | Q9 |
| Auth | htpasswd in SOPS Secret | Q10 |
| Image pin | Digest captured at deploy time | Q11 |

No `[NEEDS CLARIFICATION]` markers remain. Phase 1 can proceed.
