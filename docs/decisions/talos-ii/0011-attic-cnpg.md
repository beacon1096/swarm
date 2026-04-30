# ADR talos-ii/0011 — Attic on CloudNativePG (Phase 4a)

**Scope:** talos-ii. attic isn't planned for talos-i.
**Status:** accepted
**Date:** 2026-04-29

## Context

Phase 4a of the talos-ii rebuild: stand up `attic` (Nix binary
cache server, `ghcr.io/zhaofengli/attic`) on the new cluster as
the authenticated source for the NixOS fleet. swarm-01 ran attic
behind a single-instance bitnami `postgresql` subchart; we keep
the application binary the same but swap the data layer.

Unlike Phase 3 PG-backed apps (authentik / matrix / coder / n8n)
this is a **fresh deploy with no state migration**. attic is
content-addressable; the nar-store re-fills naturally as fleet
hosts re-push during rebuild. The metadata DB holds cache
definitions and token rows — those *are* lost, but in practice
we mint replacements from scratch (token rotation is documented
runbook anyway).

Sub-decisions to nail down:

1. CNPG vs. continuing with bitnami subchart.
2. PG major version pin.
3. Whether to import any swarm-01 state.
4. How the helmrelease orders itself against the CNPG cluster.
5. How the `ghcr.io/zhaofengli/attic` image gets cached on LAN zot
   given zot's manifest validation.
6. The mismatch between the documented atticadm CLI surface and
   the surface the binary actually exposes (limits what the
   restore runbook can promise, see Consequences).

## Decision

### 1. CloudNativePG, not the bitnami subchart

Per ADR 0007 and the precedent of authentik (0008) / matrix-synapse
(0009) / coder + n8n (0010): every PG-backed workload on this
cluster lands on CNPG via a per-app `Cluster` CR. attic is no
exception even though the source cluster used the bitnami subchart.

Concrete shape:

```text
kubernetes/apps/nix/attic/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── pg-cluster.yaml         # CNPG Cluster (PG 16, 3 instances)
    ├── pg-secret.sops.yaml     # attic-pg-app + attic-pg-superuser
    ├── ocirepository.yaml      # bjw-s app-template 4.6.2 from LAN zot
    ├── helmrelease.yaml        # attic container + values
    ├── pvc.yaml                # 100 Gi nar-store, longhorn-r3
    ├── secret.sops.yaml        # server.toml + RS256 keypair
    ├── httproute.yaml          # nix.${SECRET_DOMAIN} via envoy-external
    └── service-tailscale.yaml  # tailscale-operator-annotated ClusterIP
```

Reasons to commit to CNPG even for a workload as small as attic's
metadata DB:

- **Operator surface consistency** — every PG cluster on talos-ii
  is a CNPG `Cluster` CRD with the same status conditions, same
  `kubectl cnpg` debug surface, same backup story (when we wire
  one up). Mixing in a bitnami StatefulSet just for attic would
  force a parallel mental model for nothing in return.
- **Multi-replica + automatic failover** — attic is single-replica
  on the app side (RWO PVC), so the only durability layer that
  *can* hide a node-local failure is the DB. CNPG gives us 3
  instances with promotion on primary loss; bitnami would give us
  one StatefulSet pod and a 5–15 min reschedule window.
- **Rotation pattern reuse** — DB password rotation here is the
  exact dual-SOPS-file pattern coder and authentik already use
  (`pg-secret.sops.yaml.<app>-pg-app.password` ↔
  `secret.sops.yaml.<app>-secret`'s embedded DSN). One existing
  pattern is better than two.
- **Observability surface** — the `Cluster` CRD's status
  conditions (`Ready`, `currentPrimary`, instance state) are
  immediately visible to flux, kubectl, and any future
  alerting on top. The bitnami subchart's StatefulSet exposes
  `Ready: 1/1` and nothing else.

### 2. PostgreSQL 16, not 17 or 18

Pin `imageName: ghcr.io/cloudnative-pg/postgresql:16.4`.

- swarm-01's existing attic deploy is on **PG 16.x** (bitnami).
  No data migration is in scope today, but if a future need
  surfaces to extract token rows or tag bindings from the old DB
  for forensics or partial restore, cross-major
  `pg_dump`/`pg_restore` is **not supported**. Locking the version
  to the source major is cheap insurance.
- 18.x (which authentik / coder / n8n use here) would mismatch
  swarm-01 on the off chance we ever do that import.
- 17 is GA but gains nothing — neither attic nor we need any 17+
  features.

This is the same kind of "match the source major" call that
matrix-synapse made for PG 15 in [ADR 0009](0009-matrix-synapse-cnpg-pg15.md),
just for a different version number.

### 3. No state migration — `nix-fleet` cache starts empty

attic is **content-addressable**. The nar-store is reproducible
data: every byte in it can be re-pushed by a fleet host on its
next rebuild, or re-fetched from `cache.nixos.org` (via the
sing-box egress) on first miss. The cost of importing the
swarm-01 nar-store is implementation complexity; the benefit is
a one-time bandwidth + CPU saving that's already absorbed by the
`cache.nixos.org` upstream.

Token rows in the metadata DB are *not* content-addressable —
they're configuration. They're also already stale: the
swarm-01 tokens are about to be revoked anyway as part of the
migration, and the new tokens are minted fresh against the
new RS256 keypair. So nothing in that DB is worth preserving
either.

The cost-benefit:

- **Importing nar-store**: requires either a `tar`-and-untar
  through a helper Pod (vaultwarden-style, but at 10s–100s of
  GiB) or an S3-style sync — neither is wired up. The new
  store re-fills in the natural course of fleet rebuilds.
- **Importing token rows**: requires a PG dump from the old
  cluster + schema-compatibility check across attic versions +
  importing under a new RS256 keypair (which would require
  re-signing all token rows — they wouldn't validate otherwise).
  Total deviation from "fresh deploy" simplicity for
  configuration that's about to be rotated.

The 100 Gi nar-store size matches swarm-01's allocation and
isn't the bottleneck; cluster bandwidth into `cache.nixos.org`
through sing-box is the bottleneck for first-fill, and that
amortizes across days of fleet activity.

### 4. No `dependsOn` — neither at HelmRelease nor Flux Kustomization layer

`HelmRelease.dependsOn` only resolves against **other
HelmReleases**. CNPG `Cluster` is a CRD, not a chart, so
listing `attic-pg` there pins the helmrelease in
`PrerequisitesNotMet` forever. Same gotcha hit at deploy time
(see [`tasks.md` T009 fold-back](../../../specs/001-attic-restore/tasks.md)).

The right pattern is to let kube's restart-on-failure handle
the brief CrashLoopBackOff while the DB bootstraps. This is
how authentik / matrix / coder / n8n all do it; the attic
helmrelease conforms.

`Kustomization.dependsOn` could in principle reference the
`cloudnative-pg` Flux Kustomization (which lives in `flux-system`,
not `cnpg-system` — a separate gotcha). But none of the existing
PG-backed apps list it, and adding it for attic alone would be
inconsistent. Skipped.

### 5. zot rejects upstream's Docker-v2 manifest — `skopeo --format=oci` workaround

The LAN zot mirror at `172.16.80.240:5000` has a Docker-v2
schema-2 manifest validator that rejects the upstream
`ghcr.io/zhaofengli/attic` index manifest with `MANIFEST_INVALID`.
Other ghcr.io images in the cluster (CNPG, tailscale, etc.) pull
through fine — this is image-specific, related to how the
upstream multi-arch index is shaped.

Workaround:

```bash
nix-shell -p skopeo --command '
  skopeo copy --src-tls-verify=false --dest-tls-verify=false \
    --override-os linux --override-arch amd64 \
    --format=oci \
    docker://ghcr.io/zhaofengli/attic@sha256:<upstream-index-digest> \
    docker://172.16.80.240:5000/zhaofengli/attic:phase4a
'
```

The OCI re-encoding produces a *new* digest with the same layer
content but a different manifest envelope. The helmrelease pins
the **OCI-converted** digest (currently
`sha256:3a0b0bfcb0f8dc7426a048593a9c413c10944d8acc9151dca806fe0b898dee1f`),
not the upstream Docker-v2 digest (currently
`sha256:18574aba70fc89d2b695273fbe2e7b2f8ad7e8e786b4cc535124fbe14bada1d0`).

**Image bump procedure** must record both:

1. The upstream Docker-v2 multi-arch index digest (what you'd
   see if you `crane digest ghcr.io/zhaofengli/attic:latest`).
2. The OCI-converted digest you get back from `skopeo copy`.

Both go in a YAML comment above the `image.digest:` field. The
runbook has the full bump procedure.

### 6. atticadm CLI surface is narrower than upstream docs imply

Empirical surface in this version of the binary:

- `atticadm -f <toml> make-token --sub <s> --validity <d> [--pull <c>]+ [--push <c>]+` — works.
- `atticadm help` / `--help` — works.
- `atticadm -f <toml> create-cache <name>` — **does not exist**.
- `atticadm -f <toml> list-caches` — **does not exist**.
- `atticadm -f <toml> revoke-token <kid>` — **does not exist**.
- `atticd server` subcommand — **does not exist**.
- `atticd --listen` flag — **does not exist** (listen address goes
  in `server.toml`).

This is documented as a limitation, not a decision — the project
upstream intends `atticadm` to grow these eventually. Concrete
implications for our deploy:

- **Cache creation goes through the REST API** (admin token →
  `POST /_api/v1/cache-config/<name>`). The runbook documents
  the exact call.
- **Token revocation is not directly available**. Our compensation:
  short validity windows (1y is the upper end; emergency tokens
  go 1d) plus the nuclear option of rotating the RS256 keypair
  (which invalidates *all* outstanding tokens — coordinate with
  `nix-daemon`s + CI before pulling that lever). This is not the
  decision we wanted to reach, but it's the surface the binary
  gives us. Tracked as a follow-up to revisit on every attic
  bump — the day upstream adds `revoke-token` we can drop the
  rotation-as-revocation pattern.

## Consequences

Positive:

- Operator surface consistency with authentik / matrix / coder /
  n8n — same `kubectl cnpg`, same dual-secret rotation pattern,
  same Cluster CRD status visibility.
- Multi-replica DB removes the DB layer as a single-node-failure
  pivot; primary failover is automatic.
- PG 16 pin keeps the door open for future state imports from
  swarm-01 without a `pg_upgrade` step.
- Image pin via OCI-converted digest both honors FR-007 (no
  direct ghcr.io pulls from cluster nodes) and gives us a
  stable, reproducible image identity.

Negative / accepted trade-offs:

- DB password rotation requires editing **two** SOPS files in
  one commit (`pg-secret.sops.yaml.attic-pg-app.password` and
  `secret.sops.yaml.attic-secret`'s embedded DSN). If they
  drift, attic CrashLoopBackOffs with `password authentication
  failed`. The runbook flags this prominently.
- Token revocation isn't a real operation in this attic version —
  short validity + keypair rotation is the closest substitute.
  Mostly fine for a small, trusted fleet; would not be fine for a
  multi-tenant deployment with arbitrary clients.
- Cache creation requires a one-shot REST call with an admin
  bearer token; no `atticadm` shortcut. Documented; not painful
  for the operator-once-per-cache cadence we're at.
- Image bump requires recording two digests (upstream + OCI
  conversion) in the YAML comment, and the bump tooling has to
  run skopeo locally. No automation in scope; the runbook has
  the procedure.
- Small-DB-on-3-replicas is wasteful in absolute terms (the
  schema is ~MB-scale and we run it on 3× longhorn-r3 = 9 PVCs).
  Same trade-off authentik made; cheap given Longhorn / cluster
  scale and worth the consistency.

## Related

- [ADR 0007](0007-cloudnative-pg-operator.md) — CNPG operator decision
- [ADR 0008](0008-authentik-cnpg-restore.md) — authentik on CNPG
- [ADR 0009](0009-matrix-synapse-cnpg-pg15.md) — matrix-synapse PG version pin precedent
- [ADR 0010](0010-coder-n8n-cnpg.md) — coder + n8n on CNPG (same dual-secret pattern)
- [Operations: attic restore](../../operations/attic-restore.md)
- [Operations: tailscale operator](../../operations/tailscale-operator.md) — for the `proxy-class: proxied` annotation requirement
- [Operations: zot mirror](../../operations/zot-mirror.md) — where the OCI-converted attic image lives
- [specs/001-attic-restore/](../../../specs/001-attic-restore/) — the spec dir, including all fold-back lessons
