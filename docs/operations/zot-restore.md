# zot in-cluster — Phase 4b operations runbook

## What this is

Operations runbook for the **in-cluster** zot OCI pull-through cache
on talos-ii (the `172.16.87.51:5000` Cilium-LB-announced Service plus
the `zot.tail5d550.ts.net:5000` tailnet hostname). Covers fresh-deploy
verification, image bumps, chart upgrades, adding a new upstream
registry, configuration edits, DR scenarios, and the chart-quirk
catalog this phase walked into.

For the **LAN host zot** at `172.16.80.240:5000` (still running as
fallback for talos-ii during the 7-day burn-in, and primary for any
consumer not yet migrated — notably talos-i in `swarm-01`), see
[`zot-mirror.md`](zot-mirror.md). The two docs are siblings; this one
is talos-ii-specific, that one is host-specific.

For the **why** behind the architecture (chart selection, probe
weakening, storage class deviation, two-step decommission, factory
carve-out), see
[ADR 0012 — zot in-cluster on talos-ii](../decisions/talos-ii/0012-zot-on-talos-ii.md).
For the original spec walkthrough — every gotcha tagged back as a
fold-back bug — see
[`specs/002-zot-on-talos-ii/`](../../specs/002-zot-on-talos-ii/).

## Pre-requisites

- Cilium L2 announcement pool has `172.16.87.51` free
  (`kubectl get svc -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[*].ip}{"\n"}{end}' | sort -u | grep 172.16.87.51`
  returns nothing if the LB is not present, or returns exactly one
  match (`zot-lb`) post-deploy).
- Default `longhorn` storage class healthy (`kubectl get sc longhorn`,
  `Provisioner: driver.longhorn.io`, `Default: true`). The LAN
  doc-stage `longhorn-r2` reference is a deviation that this runbook
  does not honor — see ADR 0012 §4.
- In-cluster sing-box healthy
  (`kubectl -n network rollout status deploy/sing-box --timeout=10s`,
  `kubectl -n network get svc sing-box-lb` should show LB IP
  `172.16.87.41`).
- LAN zot at `172.16.80.240:5000` reachable from the operator
  workstation, with the `zot/zot` Helm chart 0.1.79 already
  pre-pushed (chart-bump procedure below shows how to re-push). On a
  fresh-disaster-recovery deploy, this is the bootstrap source for
  the in-cluster zot's chart.
- `cluster-secrets` Secret in `flux-system` exists and contains
  `ZOT_PROBE_AUTH_HEADER` (the base64 of `admin:<plaintext>`,
  injected via Flux postBuild substitution).

## First-deploy verification

After a clean reconcile of `kubernetes/apps/registry/`, run this
sequence. The user has already run it once; the section is here for
disaster-recovery rebuild.

```bash
# Flux side
flux reconcile source git flux-system
flux reconcile kustomization zot -n flux-system
flux get hr -n registry zot
# expect: HelmRelease zot Ready=True

# Workload side
kubectl -n registry get pvc
# expect: zot-pvc-zot-0 Bound (chart-managed VCT, NOT a separate pvc.yaml)
kubectl -n registry get pods
# expect: zot-0 1/1 Running, restarts ≤ 1
kubectl -n registry get svc
# expect 3 services:
#   zot              ClusterIP      <chart-emitted internal>
#   zot-lb           LoadBalancer   172.16.87.51   (Cilium L2)
#   zot-tailscale    ClusterIP      <none, but tailscale-operator wires it>

# Tailscale per-Service proxy pod (lands in `network` ns, NOT `tailscale`,
# because tailscale-operator HelmRelease's targetNamespace is `network`)
kubectl -n network get pods | grep ts-zot
# expect: ts-zot-<id>-0   1/1   Running   (NOT NeedsLogin)
```

**LAN-side smoke** — anonymous read against the LB IP from
the operator workstation:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://172.16.87.51:5000/v2/
# expect: 200

curl -s 'http://172.16.87.51:5000/v2/_catalog?n=200' | jq -r '.repositories[]' | head
# expect: a list — exact contents depend on what the cluster has pulled.
# Phase 4b initial: empty until first pull happens; post-burn-in: ~10s of repos.
```

**Tailnet smoke** — from any tailnet member (operator workstation, or
a talos-i node post-adoption):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://zot.tail5d550.ts.net:5000/v2/
# expect: 200
```

If the tailnet probe hangs or 404s, the per-Service proxy pod is
stuck. Check:

```bash
kubectl -n network logs ts-zot-<id>-0 | grep -Ei 'logged in|magicsock|NeedsLogin'
```

`NeedsLogin` means the `tailscale.com/proxy-class: proxied`
annotation is missing or the `proxied` ProxyClass itself is
mis-rendered — see [`tailscale-operator.md`](tailscale-operator.md).

## Image pull catalog inspection

zot's catalog is the operator's go-to for "did this image actually
land in cache". Run any of these from a debug pod:

```bash
# All cached repos
kubectl run -n registry --rm -i probe \
  --image=curlimages/curl --restart=Never -- \
  curl -s 'http://zot:5000/v2/_catalog?n=200' | jq

# Tags for a specific repo (replace path)
kubectl run -n registry --rm -i probe \
  --image=curlimages/curl --restart=Never -- \
  curl -s 'http://zot:5000/v2/curlimages/curl/tags/list' | jq

# Manifest for a specific tag (verify a known image cached)
kubectl run -n registry --rm -i probe \
  --image=curlimages/curl --restart=Never -- \
  curl -sI \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    http://zot:5000/v2/curlimages/curl/manifests/latest
# expect: HTTP/1.1 200 with Content-Type: application/vnd.oci.image.manifest.v1+json
```

Phase 4b's first verified image-pull-via-zot was `curlimages/curl`,
landed during the post-cutover smoke. The operator should expect
the catalog to grow organically as fleet workloads pull new images;
the Longhorn PVC fill rate is the relevant capacity signal.

## Image-tag bump (zot binary)

zot's own container image (`ghcr.io/project-zot/zot-linux-amd64`) is
pinned by both **tag** and **digest** in
`kubernetes/apps/registry/zot/app/helmrelease.yaml`'s `image.tag` /
`image.digest`. Bumping is a deliberate operator action.

Unlike the `ghcr.io/zhaofengli/attic` case in Phase 4a (which needed
a `skopeo --format=oci` workaround for `MANIFEST_INVALID`), **zot's
own image is published as an OCI manifest by zot upstream**. No
re-encoding needed. Workflow:

```bash
# 1. Find the upstream digest for the new tag
nix-shell -p crane --command \
  'crane digest ghcr.io/project-zot/zot-linux-amd64:v2.1.6'
# capture as DIGEST=sha256:...

# 2. Edit kubernetes/apps/registry/zot/app/helmrelease.yaml
#    - image.tag: v2.1.6
#    - image.digest: $DIGEST
#    - update the YAML comment above image.digest if your DIGEST line
#      no longer matches "captured at apply time per FR-009" (rephrase
#      or just bump the date)

# 3. Re-render any downstream check, commit, push
git add kubernetes/apps/registry/zot/app/helmrelease.yaml
git commit -m "fix(registry): bump zot image to v2.1.6"
git push
```

If `crane digest` fails (proxy issue), fall back to
`docker pull ghcr.io/project-zot/zot-linux-amd64:v2.1.6 && docker images --digests`.

**If a future zot release does fall back to a Docker v2 schema-2
manifest envelope** (very unlikely; zot upstream publishes their
own image through their own registry), use the attic-style workaround:

```bash
nix-shell -p skopeo --command "
  skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    --override-os linux --override-arch amd64 \
    --format=oci \
    docker://ghcr.io/project-zot/zot-linux-amd64@$UPSTREAM_DIGEST \
    docker://172.16.80.240:5000/project-zot/zot-linux-amd64:v2.1.6
"
# Then crane digest --insecure 172.16.80.240:5000/project-zot/zot-linux-amd64:v2.1.6
# and pin the OCI digest, with both digests in a YAML comment.
```

## Adding a new upstream registry

Two-side change: the **zot config** gets a new entry in
`extensions.sync.registries[]`, and the **Talos machine-config** gets
a new mirror entry pointing all three nodes at the in-cluster zot for
that upstream. Both must land in the same commit chain (or the LAN
host bootstrap path can serve as a stop-gap).

### 1. zot config side

Edit `kubernetes/apps/registry/zot/app/helmrelease.yaml`'s
`configFiles.config.json`:

```yaml
extensions:
  sync:
    enable: true
    registries:
      # … existing entries …
      - urls: ["https://new-upstream.example.com"]
        onDemand: true                  # MUST be a bool, not "true"
        pollInterval: "0"
        tlsVerify: true
        content:
          - prefix: "**"
            destination: "/"
            stripPrefix: false
```

**Pitfalls** in `extensions.sync` schema:

- `onDemand` MUST be a boolean. The chart's JSON schema catches a
  string at `helm template` time but only if you use the mapping
  form (which we do). A raw JSON string in `configFiles.config.json`
  bypasses the schema check.
- `pollInterval: "0"` is correct (string). `pollInterval: 0` (int)
  also works in some chart versions but is less portable.
- `urls[]` is a list, not a single URL string.
- `tlsVerify: true` is the safe default. Set false only if the
  upstream uses a self-signed cert and you've audited the chain.

### 2. Talos machine-config side

Edit `templates/config/talos/patches/global/machine-registries.yaml.j2`,
add a block under `mirrors:`:

```yaml
new-upstream.example.com:
  endpoints:
    - http://172.16.87.51:5000   # in-cluster zot
    - http://172.16.80.240:5000  # LAN host fallback (during transition)
```

After the decommission commit, drop the second endpoint.

### 3. Local validation (BEFORE commit)

Always render and diff locally before pushing. Pushing first and
fixing forward means each iteration costs a full Flux reconcile
plus a chart pod restart on the cluster — slow and visible to other
consumers. `flux build` / `helm template` are fully offline (no API
server, no cluster state mutation), so iterate freely until the
output looks right.

```bash
cd /home/beacon/swarm

# 3a. Render the Kustomization Flux will apply (offline, no cluster).
#     This catches YAML/postBuild substitution issues without touching
#     the cluster.
flux build kustomization zot \
  --path ./kubernetes/apps/registry/zot/app \
  --kustomization-file kubernetes/apps/registry/zot/ks.yaml \
  | yq '.spec.values.configFiles."config.json"' -r | jq .extensions.sync
# expect: your new entry appears in the rendered config.json

# 3b. Render the chart locally to see the actual StatefulSet that will
#     be applied (catches probe-patch / VCT / Secret-mount drift between
#     chart versions).
helm template zot oci://172.16.80.240:5000/charts/zot --version 0.1.79 \
  --plain-http \
  -f <(flux build kustomization zot --path ./kubernetes/apps/registry/zot/app \
       --kustomization-file kubernetes/apps/registry/zot/ks.yaml \
       | yq '.spec.values' -y)

# 3c. (Optional) server-side dry-run against the live cluster — catches
#     admission-webhook rejections (PSA, Kyverno, etc.) without mutating.
#     Read-only on the API server side.
flux diff kustomization zot --path ./kubernetes/apps/registry/zot/app
```

**Do NOT `kubectl apply` directly to the cluster to "test"**: even
though Flux will eventually reconcile back to Git (≤1h default
interval, sooner if `prune: true` removes drift), any field your
manual apply added that's NOT owned by Flux's field manager
(`kustomize-controller`) will linger as orphaned drift. Recovery
means manual `kubectl edit` to delete the orphan field — strictly
worse than catching it in `flux build` output.

### 4. Re-render Talos config and commit

```bash
cd /home/beacon/swarm
task configure                  # NOT raw `makejinja` — task wrapper
                                # runs encrypt-secrets after re-render
                                # (per ~/.claude/.../memory/MEMORY.md
                                # makejinja+sops feedback)

# Verify no SOPS plaintext leaked
git diff --stat | grep -E '\.sops\.' | xargs -I{} grep -l 'ENC\[' {}
# every *.sops.* file should still show ENC[...] markers

git add kubernetes/apps/registry/zot/app/helmrelease.yaml \
        templates/config/talos/patches/global/machine-registries.yaml.j2 \
        talos/patches/global/machine-registries.yaml
git commit -m "feat(registry): add <new-upstream> mirror"
git push

# Trigger Flux immediately instead of waiting for the 1h interval.
flux reconcile source git flux-system
flux reconcile kustomization zot --with-source
flux reconcile helmrelease zot -n registry

# Watch the rollout
flux get hr -n registry zot --watch

# Per-node Talos apply, sequential (NOT parallel)
task talos:apply-node IP=172.16.87.201
# verify no reboot via dmesg, then proceed:
task talos:apply-node IP=172.16.87.202
task talos:apply-node IP=172.16.87.203
```

### 5. Verify the new upstream serves

```bash
kubectl run -n registry --rm -it test-pull --restart=Never \
  --image=new-upstream.example.com/some-known-image:tag -- \
  /bin/sh -c 'echo ok'
# expect: pod reaches Running

# Confirm it flowed through in-cluster zot, not direct
kubectl logs -n registry zot-0 --tail=200 | grep some-known-image
# expect: GET /v2/some-known-image/manifests/...
```

## Chart upgrade procedure

zot's official chart (`zot/zot`) lives at
`oci://ghcr.io/project-zot/helm-charts/zot`. We mirror it through
the LAN zot at `oci://172.16.80.240:5000/charts/zot` (same
one-time-bootstrap pattern as `tailscale-operator`), and the Flux
`OCIRepository` at `kubernetes/apps/registry/zot/app/ocirepository.yaml`
points at the LAN-mirrored copy with `insecure: true`.

```bash
# 1. Pull the new chart version from the public registry
helm pull oci://ghcr.io/project-zot/helm-charts/zot --version 0.1.80

# 2. Re-push to LAN zot
helm push zot-0.1.80.tgz oci://172.16.80.240:5000/charts --plain-http

# 3. Verify it landed
curl -s 'http://172.16.80.240:5000/v2/charts/zot/tags/list' | jq
# expect: 0.1.80 in .tags

# 4. CRITICAL: read upstream release notes for breaking config schema
#    changes BEFORE bumping the OCIRepository tag. The
#    extensions.sync.registries[].content[] schema has shifted in
#    past versions — a bump from 0.1.79 to 0.1.80 might require
#    flag renames or bool-to-string flips.
#    https://github.com/project-zot/helm-charts/releases

# 5. Bump the OCIRepository tag in the repo
sed -i 's/tag: 0.1.79/tag: 0.1.80/' \
  kubernetes/apps/registry/zot/app/ocirepository.yaml

# 6. Re-check our two known chart-quirk workarounds still apply:
#    a. helmrelease.spec.postRenderers.kustomize.patches[] still
#       references /spec/template/spec/containers/0/{startup,liveness,readiness}Probe
#       — if chart 0.1.80 changes container ordering or probe paths,
#       these JSON patches will silently no-op or fail at apply.
#    b. mountSecret: false + extraVolumes still mounts /secret/htpasswd
#       — if the chart renames the htpasswd path or changes the
#       Secret mount expectation, our SOPS Secret won't reach zot.
#    c. Probe path defaults — if 0.1.80 ships /v2/-based probes by
#       default OR exposes probe paths as values, we may be able to
#       drop the postRenderer entirely. Test in a `helm template`
#       dry-run first.

# 7. Apply the chart bump as a normal flux-driven update
git add kubernetes/apps/registry/zot/app/ocirepository.yaml \
        kubernetes/apps/registry/zot/app/helmrelease.yaml
git commit -m "fix(registry): bump zot chart to 0.1.80"
git push
```

If the HelmRelease goes `Stalled` post-bump, the most likely cause
is a values-schema mismatch from breaking changes. Recovery
patterns are in [`flux-helm-recovery.md`](flux-helm-recovery.md).

## Configuration edits (without chart or image bump)

zot does **not** support runtime reload of `config.json`. The chart
gates this on a checksum/config annotation that triggers a Pod
restart whenever `configFiles.config.json` changes — which is the
right behavior, but the operator should know:

- Editing the `configFiles.config.json` mapping in `helmrelease.yaml`
  (e.g. tweaking GC schedule, adding/removing a sync registry,
  enabling/disabling an extension block) **forces a Pod restart**.
- The restart is `Recreate` strategy (RWO PVC + StatefulSet);
  expect ~30–60 s of registry unavailability while the new Pod
  starts and re-reads the chart-managed PVC.
- HelmRelease `spec.timeout: 15m` (or higher) is recommended
  because chart-managed PVC mount + first-boot validation can
  take 5–10 min on a cold node. The current helmrelease leaves
  HR timeout at default; bump it if you see HR `Stalled` waiting
  for Pod readiness post-edit.

## DR scenarios

### A. zot Pod won't start

Most common cause: chart bump or config edit hit one of the
chart-quirk pitfalls (probe paths, htpasswd mount, search/CVE).

```bash
kubectl -n registry describe pod zot-0
kubectl -n registry logs zot-0 --previous
```

If the description shows probe failures, refer to ADR 0012 §5
and recheck the postRenderer is in place. If the logs show
"trivy-db download" or extension-init churn, recheck
`search.cve` is **not** present (only `search.enable: true`).

If the HelmRelease is stuck `Stalled`, follow
[`flux-helm-recovery.md`](flux-helm-recovery.md):
`flux suspend hr -n registry zot` → `helm uninstall -n registry zot` →
re-apply manifests → `flux resume hr -n registry zot`. The PVC
`zot-pvc-zot-0` survives; the cache is preserved.

### B. zot is up but cluster pulls fail / 502 / hang

Likely the in-cluster sing-box is unhealthy and `extensions.sync`
can't reach upstream. Containerd's mirror config falls through to
the LAN host endpoint on 5xx, so fleet impact is limited during
the burn-in window.

```bash
kubectl -n network rollout status deploy/sing-box
kubectl -n registry logs zot-0 --tail=200 | grep -Ei 'proxy|sync'
```

The runbook for sing-box is [`sing-box-egress.md`](sing-box-egress.md).
While sing-box is being repaired, the LAN host fallback covers
talos-ii pulls; the operator does NOT need to roll back the
machine-config flip.

### C. LAN host zot ALSO unreachable, in-cluster has no cache

Worst-case-but-not-catastrophic. New image pulls go through
sing-box → upstream directly (slow, GFW-impacted), but they
succeed. The operator should:

1. Triage why the LAN host died. Common case: `talos-mirror.service`
   stopped or the host's NVMe is full.
2. Restore the LAN host or accept that for the duration of the
   in-cluster zot's cache-fill, pulls are slower.
3. The fleet does NOT lose any running Pods (containerd's local
   image cache still serves currently-running images).

### D. Cluster-wide reboot / cold start

This is the bootstrap chicken-and-egg path. Per ADR 0012's
research.md Q5 (Plan Y):

1. Talos boots, joins via `factory.talos.dev` (LAN host —
   unchanged carve-out).
2. Cilium starts (image cached locally on each node).
3. sing-box starts (image from LAN zot at
   `172.16.80.240:5000/infrastructure/nix-fleet/sing-box:init`).
4. zot starts (image fetched via sing-box from
   `ghcr.io/project-zot/zot-linux-amd64@<digest>`). May
   `ImagePullBackOff` once or twice while sing-box stabilizes;
   ride it out.
5. Once zot is Ready, all subsequent pulls flip to in-cluster.

If zot stays in `ImagePullBackOff` indefinitely after a cold
start, **fix sing-box first**. zot is downstream of sing-box on
the bootstrap path.

### E. PVC fills up

The chart-managed VCT is sized 300 Gi. zot's own GC
(`storage.gc: true`, `gcInterval: 24h`, `gcDelay: 1h`) runs
periodically but only reclaims orphan blobs (manifest-less
content). Operator action when the PVC nears 80%:

```bash
# Check fill
kubectl -n registry exec zot-0 -- df -h /var/lib/registry

# If GC has work to do, force a run by restarting the Pod
# (zot picks up gc settings on init; mid-run reconfig is not exposed)
kubectl -n registry rollout restart sts/zot
```

If GC isn't enough, expand the PVC. Longhorn supports online
expansion: edit `pvc.storage` in `helmrelease.yaml`, commit.
The chart-managed VCT will request the expansion; Longhorn
applies without Pod restart.

## Decommission gate (Phase 5 trigger)

The **cutover** commit (`e7f3462`) leaves
`172.16.80.240:5000` as the second endpoint per upstream
mirror. The **decommission** commit (a separate, future
commit, NOT included in Phase 4b) drops that fallback.

Gate criteria — all must be true before the decommission commit
is allowed to land:

1. ≥ **7 days elapsed** since the last `task talos:apply-node`
   on the cutover (i.e. since node 203 was applied in the
   cutover sequence).
2. **Zero hot-path requests** from talos-ii nodes hit the LAN
   host during that 7-day window. Verify on the LAN host:
   ```bash
   ssh root@172.16.80.240 \
     'journalctl -u talos-mirror --since "7 days ago" \
       | grep -E "172.16.87.20[123]"'
   # expect: empty output
   ```
3. **In-cluster zot logs show baseline error rate**:
   ```bash
   kubectl logs -n registry zot-0 --tail=10000 \
     | grep -c 'level=error'
   # expect: < 100 over 7 days, i.e. baseline noise, not a
   # broken upstream
   ```
4. **`/v2/_catalog?n=2000`** on the in-cluster zot returns a
   non-trivial set of repos covering the workloads actually
   running on the cluster.

When all four pass, edit
`templates/config/talos/patches/global/machine-registries.yaml.j2`
to drop the second `http://172.16.80.240:5000` endpoint per
upstream and remove the `"172.16.80.240:5000"` self-referential
block (leave `factory.talos.dev` and the new
`"172.16.87.51:5000"` self-ref untouched). Re-render and apply
sequentially. SC-004 (zero `172.16.80.240` hits in
`kubernetes/` + `templates/`) closes for the first time at this
commit.

## Known issues / chart quirks (Phase 4b lessons)

These captured the bulk of the Phase 4b iteration cost. Each is
load-bearing on a specific commit; if you find yourself second-
guessing one of these, re-read the linked commit + ADR section
before changing it.

- **Chart 0.1.79 hardcodes probe paths to `/livez|/readyz|/startupz`,
  which zot v2.1.5 does not serve, even with mgmt extension
  prerequisites met.** The chart values only expose probe
  **timing**, not **path**. Workaround: replace `httpGet` with
  `tcpSocket: { port: 5000 }` via
  `helmrelease.spec.postRenderers.kustomize.patches[]`. See
  ADR 0012 §5 + commit `fddf4ee`. **On chart bump, verify the
  patch JSON paths still resolve** (container ordering in the
  StatefulSet template may shift).
- **Chart 0.1.79 does not honor `existingClaim`**. The
  StatefulSet template always builds a `volumeClaimTemplates`
  from `pvc.*` values whenever `persistence: true`. A
  pre-created PVC would dangle. We use chart-managed VCT;
  PVC materializes as `zot-pvc-zot-0`. ADR 0012 §4.
- **Chart 0.1.79 `mountSecret: true` + our SOPS Secret named
  `zot-secret` collide** (the chart would render its own
  Secret under the same name). Workaround: `mountSecret: false`
  + `extraVolumes`/`extraVolumeMounts` mounting the SOPS
  Secret at `/secret/htpasswd`. ADR 0012 §9.
- **`search.enable: true` is a mgmt prerequisite, but
  `extensions.search.cve` triggers a 91 MiB trivy-db download
  that blocks readiness on every Pod restart.** Enable
  `search` without the `cve` sub-block. ADR 0012 §6 + commits
  `9f034ab` (the wrong walk) and `a7422af` (the right shape).
- **`log.output: "stdout"` is interpreted literally as a
  filename**, which leads to `permission denied` because zot
  runs as uid 1000 and can't open `./stdout`. The correct
  value is `/dev/stdout`. Commits `1eac6af` and `e54f85b`.
- **Storage class `longhorn-r2` does not exist in this repo.**
  The default class `longhorn` IS the r2 path (replicaCount=2
  per repo convention; the comment in
  `kubernetes/apps/storage/longhorn/app/storageclass-replicated-3.yaml`
  spells this out). Don't try to "create the missing
  longhorn-r2 SC" if you see the deviation in plan/research —
  use the default. ADR 0012 §4.
- **`factory.talos.dev` is not in `extensions.sync.registries[]`
  and not flipped to in-cluster in the machine-config**. Three
  reasons (bootstrap, amd64-only schematic, manifest shape
  volatility — ADR 0012 §1). Don't try to "complete" the
  cutover by adding it.
- **`NO_PROXY` must include both `cluster.local` and
  `cluster.local.` (trailing dot)**. Go's `net/http/httpproxy`
  doesn't normalize. Same as attic / flux-instance. ADR 0012 §7.
- **Admin password rotation requires editing TWO SOPS files**:
  `kubernetes/apps/registry/zot/app/secret.sops.yaml`
  (the `htpasswd` value) AND
  `kubernetes/components/sops/cluster-secrets.sops.yaml`
  (the `ZOT_PROBE_AUTH_HEADER` value, which is
  `base64(admin:<plaintext>)`). One commit, both files.
  Drift here is silent (the htpasswd works for `docker login`,
  the probe `Authorization` header doesn't, but tcpSocket
  probe doesn't notice). ADR 0012 §9.
- **Tailscale per-Service proxy pod lands in `network` ns,
  not `tailscale`**. The tailscale-operator HelmRelease's
  `targetNamespace: network`. Looking under `tailscale` ns
  finds nothing.
- **`tailscale.com/proxy-class: proxied` is mandatory on the
  `zot-tailscale` Service**. Without it, the per-Service
  proxy pod stays `NeedsLogin` because
  `controlplane.tailscale.com` is GFW-blocked from default
  egress. attic Phase 4a lesson.
- **`makejinja` direct invocation skips `encrypt-secrets`** —
  user memory `feedback_makejinja_sops.md`. Always use
  `task configure` after editing `.j2` templates, or
  manually `task encrypt-secrets` (or `sops -e -i` on each
  `*.sops.*`) before commit.
- **`kubectl exec -i` truncates large stdin (>~100 MiB)** —
  user memory `feedback_kubectl_exec_stdin.md`. If a future
  procedure pipes a blob into the zot Pod (image push from
  workstation, blob restore), use `kubectl cp` + `--filename`
  instead.

## Status

- **2026-04-30**: Phase 4b cutover complete. In-cluster zot
  Ready=True. All 9 mirrors flipped. 3 nodes hot-reloaded
  without reboot (SC-007). First image (`curlimages/curl`)
  verified pulled through in-cluster zot. SC-001..SC-003,
  SC-005..SC-008 passing. **SC-004 deferred to decommission
  commit** (≥ 7 days post-cutover).
- **2026-05-07 (target)**: Decommission commit lands. SC-004
  closes. Phase 4b formally complete.
