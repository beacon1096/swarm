# Quickstart — zot OCI mirror in-cluster on talos-ii (Phase 4b)

Operator playbook for bringing up the in-cluster zot, cutting over Talos host containerd, and verifying acceptance. Follow top-to-bottom in order. Each step has a verification check; do not proceed past a failing check.

## 0. Pre-flight

Required state before starting:

- Flux is healthy on talos-ii (`flux get all -A` shows no `False` Ready conditions).
- Longhorn is healthy (`kubectl get nodes.longhorn.io -n longhorn-system`).
- `cilium-l2` LB pool has `172.16.87.51` free (`kubectl get ciliumloadbalancerippool -o yaml` and `kubectl get svc -A` to confirm no service has claimed `.51`).
- sing-box is healthy (`kubectl -n network rollout status deploy/sing-box`).
- LAN zot at `172.16.80.240:5000` is up — it remains the chart source and the fallback during transition.
- Operator has SSH access to `172.16.80.240` (or proxy.beacoworks.xyz) for the one-time chart push and for verification logs.
- SOPS age key is on the operator workstation (`~/.config/sops/age/keys.txt`) and the workstation can encrypt against `.sops.yaml` recipients.

### Pre-push the official zot chart to LAN zot

```bash
helm pull oci://ghcr.io/project-zot/helm-charts/zot --version 0.1.79
helm push zot-0.1.79.tgz oci://172.16.80.240:5000/charts --plain-http
# Verify:
curl -s 'http://172.16.80.240:5000/v2/charts/zot/tags/list' | jq .
# Expected: {"tags": ["0.1.79"]}
```

If the chart version has moved on at the time of deploy, bump the tag everywhere consistently (`OCIRepository.spec.ref.tag`, the verify command, the runbook).

## 1. Capture the zot image digest

```bash
crane digest ghcr.io/project-zot/zot-linux-amd64:v2.1.5
# (or whatever the latest stable tag is at apply time)
```

Record the digest. It goes into `helmrelease.yaml`'s `image.digest:`. **Do not** commit `:latest` or a floating tag (FR-009).

If `crane` is unavailable, use:

```bash
docker pull ghcr.io/project-zot/zot-linux-amd64:v2.1.5
docker images --digests ghcr.io/project-zot/zot-linux-amd64
```

If at first apply zot's pod stays in `ImagePullBackOff` with `MANIFEST_INVALID` (the same class of failure attic hit in Phase 4a), fall back to the `skopeo --format=oci` workaround:

```bash
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    --override-os linux --override-arch amd64 --format=oci \
    docker://ghcr.io/project-zot/zot-linux-amd64@sha256:<upstream-digest> \
    docker://172.16.80.240:5000/project-zot/zot-linux-amd64:v2.1.5
crane digest 172.16.80.240:5000/project-zot/zot-linux-amd64:v2.1.5
# Re-pin helmrelease.yaml to this OCI-converted digest.
```

This is the same recipe used for `ghcr.io/zhaofengli/attic` in Phase 4a (per ADR 0011-attic-cnpg.md).

## 2. Generate the admin htpasswd

On the operator workstation (do **not** run inside any cluster pod):

```bash
# Generate a strong password.
ADMIN_PW=$(pwgen -s 48 1)
# Bcrypt it for htpasswd.
htpasswd -bnB admin "$ADMIN_PW"
# Output line is "admin:$2y$10$...". Copy it as the htpasswd value.
echo "$ADMIN_PW"
# Copy the plaintext too — it goes into the same Secret as `admin-password`.
```

Both values land in `kubernetes/apps/registry/zot/app/secret.sops.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: zot-secret
  namespace: registry
type: Opaque
stringData:
  htpasswd: |
    admin:$2y$10$...
  admin-password: <plaintext>
```

After editing, encrypt:

```bash
sops --encrypt --in-place kubernetes/apps/registry/zot/app/secret.sops.yaml
# Or use the project's helper:
task encrypt-secrets
```

**Caveat** (per `~/.claude/projects/.../memory/MEMORY.md`): if you run `makejinja` directly during this step, that bypasses the `encrypt-secrets` step in the `task configure` pipeline. Re-run `task encrypt-secrets` (or `sops -e -i`) on `*.sops.*` before commit.

## 3. Write the manifests

Create the directory tree:

```bash
mkdir -p kubernetes/apps/registry/zot/app
```

Files to author (in this order; the kustomization.yaml resource list reflects it):

1. `kubernetes/apps/registry/namespace.yaml` — `kind: Namespace`, `name: registry`.
2. `kubernetes/apps/registry/kustomization.yaml` — lists `./zot`, `./namespace.yaml`.
3. `kubernetes/apps/registry/zot/ks.yaml` — Flux Kustomization (see data-model.md).
4. `kubernetes/apps/registry/zot/app/kustomization.yaml` — resource list:
   ```yaml
   resources:
     - ./secret.sops.yaml
     - ./ocirepository.yaml
     - ./pvc.yaml
     - ./helmrelease.yaml
     - ./service-lb.yaml
     - ./service-tailscale.yaml
   ```
5. `kubernetes/apps/registry/zot/app/secret.sops.yaml` — already encrypted from Step 2.
6. `kubernetes/apps/registry/zot/app/ocirepository.yaml` — chart source.
7. `kubernetes/apps/registry/zot/app/pvc.yaml` — `zot-store`, 300 Gi, longhorn-r2.
8. `kubernetes/apps/registry/zot/app/helmrelease.yaml` — values per data-model.md.
9. `kubernetes/apps/registry/zot/app/service-lb.yaml` — Cilium L2-announced LB at 172.16.87.51.
10. `kubernetes/apps/registry/zot/app/service-tailscale.yaml` — tailscale-operator-annotated.

Cross-check the umbrella picks up the new namespace dir:

```bash
grep -r "registry" kubernetes/flux/cluster/
# If there's an explicit list, add `registry/` to it. If it's a directory walker, no edit needed.
```

## 4. First commit (manifests only, no Talos patch yet)

Commit the manifests but **do not yet update the Talos `machine-registries.yaml.j2`**. This separation is the cutover gate: zot must be healthy and proven before host containerd starts depending on it.

```bash
git add kubernetes/apps/registry/
git commit -m "feat(registry): zot OCI mirror on talos-ii (Phase 4b deploy)"
git push
```

Watch flux:

```bash
flux reconcile source git flux-system
flux reconcile kustomization zot -n flux-system
flux get hr -n registry zot
kubectl get pvc -n registry zot-store
kubectl get pods -n registry
kubectl get svc -n registry
```

Expected end-state:

- HelmRelease `zot` Ready=True.
- PVC `zot-store` Bound.
- Pod `zot-<id>` Running 1/1.
- Services: chart's `zot` ClusterIP, `zot-lb` with EXTERNAL-IP `172.16.87.51`, `zot-tailscale` with the per-svc tailscale-operator proxy spawned (`kubectl get pods -n network | grep ts-zot`).

## 5. Smoke-test the in-cluster zot (before any host containerd flip)

```bash
# Anonymous read (FR-007).
curl -s -o /dev/null -w 'anon-read=%{http_code}\n' http://172.16.87.51:5000/v2/

# Push without auth fails (FR-008).
curl -s -o /dev/null -w 'push-no-auth=%{http_code}\n' -X POST http://172.16.87.51:5000/v2/test/blobs/uploads/

# Push with auth succeeds.
curl -s -o /dev/null -w 'push-auth=%{http_code}\n' -u "admin:$ADMIN_PW" -X POST http://172.16.87.51:5000/v2/test/blobs/uploads/

# Cold sync from upstream (forces sing-box egress).
curl -s 'http://172.16.87.51:5000/v2/library/alpine/manifests/3.20' \
     -H 'Accept: application/vnd.oci.image.manifest.v1+json' | jq .mediaType
```

Expected: `200`, `401`, `202`, and a valid OCI image manifest type. If the cold sync fails, check sing-box health and the Pod's `HTTP_PROXY` / `NO_PROXY` env (the trailing-dot variants are mandatory).

## 6. Update the Talos `machine-registries.yaml.j2` (cutover)

Edit `templates/config/talos/patches/global/machine-registries.yaml.j2` per [`research.md` Q7](./research.md#q7--templatesconfigtalospatchesglobalmachine-registriesyamlj2-redesign):

- Each upstream's `endpoints[]` becomes `[http://172.16.87.51:5000, http://172.16.80.240:5000]`.
- New self-referential entry for `172.16.87.51:5000`.
- `factory.talos.dev` left unchanged.

Re-render:

```bash
task configure
# Or, if you ran makejinja directly: task encrypt-secrets immediately after.
git diff talos/patches/global/machine-registries.yaml
# Verify the diff matches expectations: in-cluster IP added as first endpoint everywhere
# except factory.talos.dev; LAN host preserved as fallback.
```

Apply per node, sequentially:

```bash
task talos:apply-node IP=172.16.87.201
# Wait for apply to complete. Then:
talosctl --nodes 172.16.87.201 dmesg | tail -20
# Expected: NO reboot. NO "TASK boot" lines. Apply phase logs only.
talosctl --nodes 172.16.87.201 read /etc/cri/conf.d/hosts/docker.io/hosts.toml
# Expected: server entries reflect 172.16.87.51:5000 (and 172.16.80.240:5000 as fallback).

# Then nodes 202, 203 in turn, with the same dmesg + hosts.toml verification.
task talos:apply-node IP=172.16.87.202
task talos:apply-node IP=172.16.87.203
```

## 7. Post-cutover verification (acceptance)

### SC-001 — fresh pull on talos-ii via in-cluster zot

```bash
kubectl run sc001 --rm -it --restart=Never --image=mirror.gcr.io/coredns/coredns:1.13.1 -- /bin/sh -c 'echo ok'
# Pod must reach Running, not ImagePullBackOff.
```

Confirm the pull went through the in-cluster zot by checking the zot Pod logs for the corresponding GET on `/v2/coredns/coredns/manifests/1.13.1`:

```bash
kubectl logs -n registry deploy/zot --tail=200 | grep coredns
```

### SC-002 — fresh pull on talos-i via tailnet path

This SC is verified in a follow-up phase that wires talos-i's `machine.registries.mirrors` to `zot.tail5d550.ts.net:5000`. **Out of scope for this Plan's implement step**; the contract is documented (research.md Q8) so the follow-up phase can land without re-litigating the protocol/hostname.

For Phase 4b acceptance, validate the tailnet path is *reachable* from a tailnet host:

```bash
# From any tailnet member (operator workstation works):
curl -s -o /dev/null -w '%{http_code}\n' http://zot.tail5d550.ts.net:5000/v2/
# Expected: 200.
```

### SC-003 — LAN host outage drill

Simulate LAN host outage by blocking egress to `172.16.80.240:5000` from one talos-ii node:

```bash
# On 172.16.87.201, install a node-level filter via Talos (or use a transient pod with NET_ADMIN).
# Easier: stop talos-mirror on the LAN host briefly:
ssh root@172.16.80.240 'systemctl stop talos-mirror'
# Trigger a fresh pull (a tag that's not yet cached anywhere):
kubectl run sc003 --rm -it --restart=Never --image=ghcr.io/zhaofengli/attic:phase4a -- /bin/sh -c 'echo ok'
# Expected: Pod still reaches Running, served by in-cluster zot's upstream sync.
ssh root@172.16.80.240 'systemctl start talos-mirror'
```

### SC-004 — no `172.16.80.240` in rendered output

After the **decommission** step (which is **not** part of this Plan's commit chain), re-run:

```bash
task configure
grep -r '172.16.80.240' talos/
# Expected: zero matches.
```

For Phase 4b acceptance (with LAN host preserved as fallback), this check intentionally **still finds matches** — that's correct, the decommission phase removes them later.

### SC-005 — talos-i cluster has no zot objects

Out of scope for this Plan's verification (talos-i is in a separate repo). The follow-up phase audits this when wiring talos-i.

### SC-006 — cache hit faster than cache miss

```bash
# First pull, observe time to Running.
time kubectl run sc006a --rm -it --restart=Never --image=docker.io/library/redis:8.0 -- /bin/sh -c 'echo ok'

# Delete the local image cache on the node by re-scheduling to a different node.
# Easiest: scale up a Deployment and observe the second Pod's pull time.
kubectl create deploy sc006b --image=docker.io/library/redis:8.0 --replicas=1
kubectl scale deploy sc006b --replicas=3
kubectl get pods -l app=sc006b -w
# Pods 2 and 3 land on different nodes and pull from the in-cluster zot's cache.
# Expected: noticeably faster than the first pull. Exact numbers don't matter (SC-008 is qualitative).
kubectl delete deploy sc006b
```

### SC-007 — no unplanned reboots

```bash
talosctl --nodes 172.16.87.201,172.16.87.202,172.16.87.203 dmesg | grep -E 'BOOT|Linux version|\[\s*0\.0+\]'
# Expected: only one boot per node, predating Phase 4b. No new boot entries.
```

### SC-008 — qualitative throughput

A single repeated pull comparison is sufficient signal:

```bash
# Time a pull from a fresh node.
time crane pull --insecure 172.16.80.240:5000/library/alpine:3.20 /tmp/alpine-lan.tar
time crane pull --insecure 172.16.87.51:5000/library/alpine:3.20 /tmp/alpine-incluster.tar
```

Expected: `172.16.87.51:5000` is no slower than `172.16.80.240:5000` (typically faster — same VLAN, NVMe, no router transit).

## 8. Land the documentation (same commit chain as the cutover)

Per FR-020, the migration is incomplete without:

1. `docs/decisions/talos-ii/0012-zot-on-talos-ii.md` — ADR.
2. `docs/operations/zot-restore.md` — runbook (this very playbook, polished).
3. `docs/index.md` — pointers added.
4. (Optional) cross-link added to `docs/operations/zot-mirror.md` pointing readers to the new in-cluster instance.

These can land in the same commit as the manifests or in an adjacent commit; what matters is they ship together (no orphan code without docs, no orphan docs without code).

## 9. Rollback procedure (if needed)

If at any point during cutover (Step 6 onward) the in-cluster zot proves unreliable:

```bash
# Revert the machine-registries.yaml.j2 to its pre-cutover state.
git revert <cutover-commit>
task configure
task talos:apply-node IP=172.16.87.201
task talos:apply-node IP=172.16.87.202
task talos:apply-node IP=172.16.87.203
```

Because the cutover commit kept `172.16.80.240:5000` as a fallback in every `endpoints[]` list, in-cluster zot failures during the transition window do **not** require a rollback — containerd falls through to the LAN host automatically. A full revert is only needed if there's a *systematic* problem (e.g. zot pod CrashLoopBackOff that masks anonymous reads with 5xx errors that don't trigger fall-through).

## 10. Decommission step (NOT this Plan)

After ≥ 7 days of observed correct operation against in-cluster zot, a follow-up commit:

1. Drops the `172.16.80.240:5000` fallback endpoint from each `endpoints[]` list.
2. Removes the `"172.16.80.240:5000"` self-referential mirror entry.
3. Re-renders, re-applies, re-verifies SC-004 (which now must pass).

This is tracked separately and gates Phase 4b's *closure*, not its *cutover*.

## 11. Day-2 procedures (for the runbook)

### Add a new upstream registry

1. Edit `helmrelease.yaml`'s `configFiles.config.json.extensions.sync.registries[]` — add the new upstream.
2. Add the corresponding `<registry>: { endpoints: [...] }` entry to `templates/config/talos/patches/global/machine-registries.yaml.j2`.
3. Commit, push, observe flux reconcile.
4. `task configure && task talos:apply-node IP=...` for each node.
5. Verify with a test pull from the new upstream.

### Bump zot version

1. `crane digest ghcr.io/project-zot/zot-linux-amd64:vX.Y.Z` → record digest.
2. Edit `helmrelease.yaml`'s `image.tag` and `image.digest`.
3. Commit, push, observe flux reconcile + Pod restart (Recreate strategy → brief PVC unmount).
4. Smoke-test (Step 5 above).

### Bump zot helm chart

1. `helm pull oci://ghcr.io/project-zot/helm-charts/zot --version <new>`
2. `helm push <chart>.tgz oci://172.16.80.240:5000/charts --plain-http`
3. Edit `ocirepository.yaml`'s `ref.tag`.
4. Observe flux reconcile.

### PVC near-full

```bash
kubectl get pvc -n registry zot-store
df -h on the Longhorn replica nodes
```

If utilisation > 80 %, expand the PVC (Longhorn supports online expansion) — operator action, not automated.
