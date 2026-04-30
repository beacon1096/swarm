# Research — Attic restore (Phase 4a)

Three open questions surfaced from the Technical Context and got resolved here. Plus one cross-check that turned out to be a no-op.

---

## Q1 — Postgres major version: 16 vs. 17 vs. 18

**Decision**: PG **16** (image `ghcr.io/cloudnative-pg/postgresql:16.4`).

**Rationale**:

- swarm-01's existing attic deploy uses bitnami PG `16.x` (`helmrelease-postgresql.yaml`). No state migration is in scope today, but if a future need arises to extract token rows or tag bindings from the old DB, cross-major-version `pg_dump`/`pg_restore` is unsupported.
- attic itself supports PG 13+ — version choice doesn't constrain attic functionality.
- CNPG offers 14 / 15 / 16 / 17. 16 is the matching version + the latest "boring" choice (as of 2026-04-29 17 is GA but 16 has more operational track record across the swarm-ii apps; matrix is on 15.4 because of a synapse-specific dump constraint, but we don't have that constraint here).
- 16.4 is the current CNPG-published patch tag (mirroring the latest OS-level CNPG image).

**Alternatives considered**:

- **PG 17**: feasible (no application blockers) but breaks the "version match" property and gains us nothing concrete.
- **PG 18.3** (which authentik / coder / n8n use in this repo): would mismatch swarm-01 on the chance we ever want to import data. Rejected for that reason.

---

## Q2 — Container image pin

**Decision**: pin `ghcr.io/zhaofengli/attic` to a digest, *not* `:latest`.

**Rationale**:

- FR-007 requires the image to be cacheable through the LAN zot. zot's pull-through resolves the floating `:latest` tag against the upstream registry every reconcile — defeating cacheability and reintroducing GFW exposure on every restart.
- Reproducibility: a future "why did pulls slow down?" debug session needs to know what image the running pod actually has, not what `:latest` resolved to today.

**Initial digest** (capture only — the implementer should re-pin to the latest published digest at apply time and record it in the helmrelease comment):

```
ghcr.io/zhaofengli/attic@sha256:<TBD-at-apply-time>
```

The runbook will document the bump procedure: pull image to a workstation, take its digest, edit `helmrelease.yaml`, commit. This is the same pattern used for the bitnami PG digest pin in swarm-01's attic-postgresql helmrelease.

**Alternatives considered**:

- **Floating `:latest`**: fails FR-007 and creates the hidden "what version is actually running" problem.
- **Build our own image** in this repo's `containers/`: total overkill; upstream is well-maintained.
- **Self-host on Forgejo**: deferred; the LAN zot pull-through is sufficient for now.

---

## Q3 — `server.toml` rendering with a CNPG-managed DB password

**Decision**: **dual-secret pattern** — the DB password is duplicated, with the same plaintext value, in two SOPS files. CNPG's `bootstrap.initdb.secret` references one (`attic-pg-app`); attic reads the other (`attic-secret`'s `server.toml`) which has the password inlined into `database.url`.

**Rationale**:

- This is the same pattern the repo already uses for `coder` (`coder-pg-app` + `coder-secret.pg-connection-url`). One existing pattern is better than two.
- The alternative — runtime template-rendering with an init container — adds a sidecar pull, an emptyDir mount, and a multi-step lifecycle dependency for a problem the dual-secret pattern solves with zero moving parts.
- The flux `postBuild.substituteFrom` mechanism only substitutes `${VAR}` references in YAML manifests, not inside opaque file payloads embedded in Secret `stringData`. So we cannot put a placeholder in the embedded `server.toml` and have flux fill it in — that would require a separate render step anyway.
- Operational rotation is documented in the runbook: rotate the password in both SOPS files in a single commit. flux applies them atomically, the CNPG operator updates the user role, the attic Pod reconciles to the new password.

**Alternatives considered**:

- **`postBuild.substituteFrom` with a `cluster-secrets` entry for the DB DSN**: would work *only* if the DSN lived in `cluster-secrets` (i.e., centrally), which violates the per-app-secret-locality convention that the rest of the repo follows. Also, exposing a DB DSN in `cluster-secrets` is a gratuitous blast-radius increase.
- **InitContainer + envsubst**: works but adds an alpine pull, a second container in the pod spec, and a trivial-but-real lifecycle bug if envsubst silently turns missing vars into empty strings (attic would then try to connect anonymously). Rejected.
- **Use `attic-server`'s native env-var support**: as of 2026-04 attic does not support env-var interpolation inside `server.toml`'s `[database]` section (it does for the JWT secret, but not the DSN). Out of our hands.

---

## Cross-check — does the Talos `machine-registries.yaml.j2` need a new mirror entry?

**No.** `ghcr.io/zhaofengli/attic` resolves through the existing entry:

```yaml
ghcr.io:
  endpoints:
    - http://172.16.80.240:5000
```

(see `templates/config/talos/patches/global/machine-registries.yaml.j2:28-30`)

zot's `extensions.sync.registries[]` configuration on the proxy host is set to `onDemand: true` for ghcr.io — first cluster pull populates the cache, subsequent pulls (other nodes, restarts) hit the LAN cache directly. No Talos-level config change required for this feature.

For comparison: the docker.n8n.io entry was added during Phase 3e because n8n's image is hosted on a separate registry (`docker.n8n.io/n8nio/n8n`) that wasn't in the existing entry list. attic does not have that problem.

---

## Open follow-ups (not blockers for this feature)

- **Garbage collection** — once the cache fills past, say, 80 Gi, we'll want a periodic GC. attic supports `atticadm gc`; can be wired up as a CronJob in a future spec. Not in scope here.
- **Multi-cache (subcache) support** — only `nix-fleet` is created. If/when we want a per-developer cache, just `atticadm` it post-deploy; no manifest change needed.
- **Switch from local-store to S3-backed store** — would let us take Longhorn out of the durability path. Out of scope; would also require choosing/deploying an S3 backend in-cluster (Garage? MinIO?) which is a separate spec.
- **Pull a release tag as soon as upstream cuts one** — currently the upstream `zhaofengli/attic` repo only ships `:latest`. If they start tagging `v0.x.y`, we should switch from the digest pin to a semver tag.
