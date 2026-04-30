# Data model — zot OCI mirror in-cluster on talos-ii (Phase 4b)

This is a GitOps feature, not an application code feature. The "data model" enumerates the cluster resources the implementation declares and the relationships among them. Each entity below corresponds to a manifest file under `kubernetes/apps/registry/zot/` (a new top-level namespace `registry`).

## Namespace

- **`registry`** — new namespace. Plain `Namespace` resource at `kubernetes/apps/registry/namespace.yaml`. The `registry/` tier gets a `kustomization.yaml` listing `./zot` so the umbrella `kubernetes/flux/cluster/...` walker picks it up. Pattern mirrors the `nix/` namespace introduced in Phase 4a.

## Secrets (1)

### `zot-secret` (Opaque)

| Key | Source | Notes |
|---|---|---|
| `htpasswd` | `htpasswd -bnB admin '<password>'` | bcrypt rounds=10. Single line, format `admin:$2y$10$…`. Mounted at `/secret/htpasswd` (chart's `mountSecret` value). |
| `admin-password` | hand-generated, ≥ 32 chars random | Plaintext, kept alongside the bcrypt hash. Used by operator tooling (skopeo, helm push) and runbook procedures. **Same value** as the plaintext that produced the bcrypt above. |

Both values SOPS-encrypted with the project's age key. Lives at `kubernetes/apps/registry/zot/app/secret.sops.yaml`.

## OCIRepository (1)

### `zot` (chart source)

- **Kind**: `source.toolkit.fluxcd.io/v1` `OCIRepository`
- **URL**: `oci://172.16.80.240:5000/charts/zot`
- **Tag**: `0.1.79` (chart version pin; refresh at deploy time)
- **`insecure: true`** (LAN zot is plain-HTTP, same as attic / sing-box / forgejo / coder / n8n / vaultwarden chart sources in this repo)

**Bootstrap step**: the chart must be pre-pushed to the LAN zot once before the first reconcile, via:

```bash
helm pull oci://ghcr.io/project-zot/helm-charts/zot --version 0.1.79
helm push zot-0.1.79.tgz oci://172.16.80.240:5000/charts --plain-http
```

Same one-time push as for `tailscale-operator` (per [`docs/operations/tailscale-operator.md`](../../docs/operations/tailscale-operator.md) "Why the chart is on local zot"). The runbook lists this as a pre-flight step, not part of the steady-state Flux loop.

## PVC (1)

### `zot-store`

- **Kind**: `v1/PersistentVolumeClaim`
- **Name**: `zot-store`
- **Access mode**: `ReadWriteOnce` (single-replica Deployment, no need for RWX)
- **Storage class**: `longhorn-r2` (cached registry content is replaceable; Constitution Principle II)
- **Size**: `300Gi`
- **Mount path** (in pod): `/var/lib/registry`

Pre-created (analogous to `attic-store`) so the storage class + size are explicit and survive HelmRelease deletion. Lives at `kubernetes/apps/registry/zot/app/pvc.yaml`.

## HelmRelease (1)

### `zot`

- **Kind**: `helm.toolkit.fluxcd.io/v2` `HelmRelease`
- **Name**: `zot`
- **`targetNamespace: registry`** (set on the parent `Kustomization`, not on the HelmRelease itself, matching the repo convention)
- **Chart source**: the `zot` `OCIRepository` above
- **No `dependsOn`** (HelmRelease.dependsOn only resolves against other HelmReleases; same pattern as attic).

#### Key values

| Path | Value | Why |
|---|---|---|
| `image.repository` | `ghcr.io/project-zot/zot-linux-amd64` | Upstream zot image. |
| `image.tag` | (e.g. `v2.1.5`) | Tag for human reference. |
| `image.digest` | `sha256:<TBD-at-apply-time>` | FR-009. Same pin pattern as attic. |
| `replicaCount` | `1` | Single-replica, RWO PVC. |
| `strategy.type` | `Recreate` | Serialise restarts on RWO PVC. |
| `service.type` | `ClusterIP` | The LB Service is a separate manifest (see below). |
| `service.port` | `5000` | zot's HTTP port. |
| `persistence.enabled` | `true` | |
| `persistence.existingClaim` | `zot-store` | Pre-created PVC. |
| `persistence.mountPath` | `/var/lib/registry` | zot config's `storage.rootDirectory`. |
| `mountConfig` | `true` | Chart-managed `config.json` ConfigMap. |
| `configFiles.config.json` | (full zot config — see contracts/zot-config.md) | The whole config file is rendered from values; chart validates the `extensions.sync.registries[]` shape. |
| `mountSecret` | `true` | Chart-managed htpasswd mount. |
| `secretFiles.htpasswd` | (from `zot-secret`) | Chart's `extraVolumeMounts` + `extraVolumes` pattern. Path is `/secret/htpasswd`. |
| `env.HTTP_PROXY` | `http://sing-box.network.svc.cluster.local:7890` | Egress for `extensions.sync` upstream pulls. |
| `env.HTTPS_PROXY` | `http://sing-box.network.svc.cluster.local:7890` | Same. |
| `env.NO_PROXY` | `.svc,.svc.cluster.local,.svc.cluster.local.,cluster.local,cluster.local.,10.0.0.0/8,172.16.0.0/12,localhost,127.0.0.1` | Trailing-dot variant included (Go httpproxy quirk per attic precedent). |
| `securityContext.runAsNonRoot` | `true` | |
| `securityContext.runAsUser` | `1000` | |
| `resources.requests.cpu` | `100m` | |
| `resources.requests.memory` | `256Mi` | |
| `resources.limits.memory` | `1Gi` | Headroom for sync extension's blob staging. |

**Lives at**: `kubernetes/apps/registry/zot/app/helmrelease.yaml`.

## Services (3)

### `zot` (chart-emitted ClusterIP)

- Standard chart output. ClusterIP. Backs the chart's Pod selector.
- Used by:
  - in-cluster clients (rare — most pulls go via the LB IP from Talos host containerd, not in-cluster Pods)
  - the `zot-tailscale` Service's tailscale-operator proxy Pod (which selects on the same labels)
- Not a separate manifest — the chart creates it.

### `zot-lb` (LoadBalancer, Cilium L2-announced)

- **Kind**: `v1/Service`, `type: LoadBalancer`
- **Name**: `zot-lb`
- **Annotation**: `lbipam.cilium.io/ips: "172.16.87.51"`
- **Selector**: matches the chart's Pod (`app.kubernetes.io/name: zot`, `app.kubernetes.io/instance: zot`)
- **Port**: `5000` (TCP)
- **Purpose**: serves Talos host containerd. The Talos node-side `machine.registries.mirrors` entries point at `http://172.16.87.51:5000`.

**Lives at**: `kubernetes/apps/registry/zot/app/service-lb.yaml`. Pattern matches `kubernetes/apps/network/sing-box/app/service-lb.yaml` (sing-box-lb at 172.16.87.41).

### `zot-tailscale` (ClusterIP, tailscale-operator-annotated)

- **Kind**: `v1/Service`, `type: ClusterIP`
- **Annotations**:
  - `tailscale.com/expose: "true"`
  - `tailscale.com/hostname: "zot"`
  - `tailscale.com/proxy-class: "proxied"` (per [`docs/operations/tailscale-operator.md`](../../docs/operations/tailscale-operator.md))
- **Selector**: matches the chart's Pod
- **Port**: `5000` (TCP)
- **Purpose**: tailnet exposure. Tailscale-operator creates `ts-zot-<id>-0` proxy pod which joins tailnet as `zot.tail5d550.ts.net`. Other tailnet members (notably talos-i nodes, in a follow-up phase) reach the registry via `http://zot.tail5d550.ts.net:5000`.

**Lives at**: `kubernetes/apps/registry/zot/app/service-tailscale.yaml`.

## ConfigMap (chart-emitted)

The chart renders `configFiles.config.json` from values into a ConfigMap. The implementer does **not** hand-write this — letting the chart manage it is half the reason we picked the official chart (Q4). The shape of the rendered `config.json` is captured in [`contracts/zot-config.md`](./contracts/zot-config.md).

## Talos machine-config patch (templates dir)

### `templates/config/talos/patches/global/machine-registries.yaml.j2`

- **Modified, not created**.
- Existing entries' `endpoints` arrays gain the in-cluster zot LB IP `http://172.16.87.51:5000` as the first endpoint, with `http://172.16.80.240:5000` retained as fallback during transition.
- New self-referential entry: `"172.16.87.51:5000": { endpoints: ["http://172.16.87.51:5000"] }` so plain-HTTP image references against the in-cluster zot work for HelmReleases.
- `factory.talos.dev` left unchanged (out of scope).

The exact pre/post diff is captured in [`research.md` Q7](./research.md). The implementer's task is mechanical: swap the endpoints lists and add the new self-referential entry; do not touch `factory.talos.dev`.

## Flux Kustomization

### `zot` (the application Kustomization)

- **Kind**: `kustomize.toolkit.fluxcd.io/v1` `Kustomization`
- **Name**: `zot`
- **Path**: `./kubernetes/apps/registry/zot/app`
- **`postBuild.substituteFrom`**: `cluster-secrets` Secret (standard pattern, even though zot itself doesn't need any substitutions yet — keeps the umbrella consistent)
- **`prune: true`**, **`wait: false`**, **`timeout: 10m`**
- **`targetNamespace: registry`**
- **No `dependsOn`** (Longhorn + sing-box are runtime requirements but the repo convention is to let kube's restart-on-failure handle the wait, per attic / coder / n8n / matrix `ks.yaml`).

**Lives at**: `kubernetes/apps/registry/zot/ks.yaml`.

## Documentation

### ADR `docs/decisions/talos-ii/0012-zot-on-talos-ii.md`

- Records the architectural decision (in-cluster zot, single instance on talos-ii, tailnet exposure for talos-i, sing-box bootstrap).
- Cross-links to ADR `0011-attic-cnpg.md` for the egress-proxy + image-pull-format precedent.
- Listed in `docs/index.md` under "Decisions → talos-ii".

### Runbook `docs/operations/zot-restore.md`

- Operator playbook: pre-flight (chart push, image push if needed) → deploy (commit, observe flux) → cutover (machine-registries patch apply + verification) → post-cutover (smoke tests against User Stories 1/2/3, SC-001 through SC-008) → rollback (revert machine-registries patch) → bump procedures (zot version, chart version, image digest).
- Listed in `docs/index.md` under "Operations".

### `docs/index.md`

- Adds entries for the ADR and the runbook in the same commit chain (FR-020).

### Optional: update `docs/operations/zot-mirror.md`

- The existing LAN-host-zot doc gains a "see also: in-cluster zot" pointer. Not strictly required by the spec; the implementer's judgement at commit time.

## Cardinality summary

```text
namespace: 1 (registry)
secrets:   1 (zot-secret)
PVCs:      1 (zot-store, 300Gi longhorn-r2)
OCIRepos:  1 (zot, chart from LAN zot)
HelmReleases: 1 (zot)
Services:  3 (zot ClusterIP via chart, zot-lb LoadBalancer, zot-tailscale ClusterIP)
Kustomizations: 1 (zot)
ConfigMaps: 1 (chart-emitted, holds config.json)

cluster modifications outside registry/:
- 1 namespace addition (kubernetes/apps/registry/{namespace.yaml,kustomization.yaml})
- 1 Talos patch edit (templates/config/talos/patches/global/machine-registries.yaml.j2)
- 1 Cilium LB IP allocation (172.16.87.51, no manifest change — pool is permissive)

documentation:
- 1 ADR (0012-zot-on-talos-ii.md)
- 1 runbook (zot-restore.md)
- 1 docs/index.md update
- 1 optional zot-mirror.md cross-link
```
