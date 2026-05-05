# Phase 1 — Data Model

Entity shapes for the talos-ii mesh implementation. These are the exact YAML / data structures the implementer will produce in `/tasks` phase. No Pod, no Service, no namespace — every entity below lives at the Talos host config layer or in the CoreDNS HelmRelease values.

---

## Entity 1 — Talos schematic delta

**Type**: factory.talos.dev schematic (submitted via the factory API or interactive editor).
**Persistence**: schematic ID stored in `talos/talconfig.yaml` at three node URLs.
**Cardinality**: one schematic for all three ms01-* nodes (per Q6/Q7).

### Schematic YAML (factory submission body)

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/intel-ucode
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
      - siderolabs/tailscale          # NEW
  bootloader: sd-boot
```

### Factory parameters (URL query, not YAML)

| param | value | notes |
|---|---|---|
| `arch` | `amd64` | MS-01 |
| `bootloader` | `sd-boot` | unchanged from current |
| `secureboot` | `true` | unchanged from current; preserves existing PCR-bound key bundle |
| `platform` | `metal` | bare-metal |
| `target` | `metal` | installer.tar.gz target |
| `version` | `1.12.7` | from `talos/talenv.yaml` |

### Resulting installer URL pattern

```
factory.talos.dev/installer-secureboot/<NEW_SCHEMATIC_ID>
```

### Validation

The new ID is a 64-char hex SHA256, distinct from `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`. Confirm by:

```sh
talosctl get extensions --nodes 172.16.87.201
# After upgrade, output includes a row for siderolabs/tailscale
```

---

## Entity 2 — `ExtensionServiceConfig` for tailscale

**Type**: Talos top-level config document (apiVersion `v1alpha1`, kind `ExtensionServiceConfig`).
**Path**: `talos/patches/global/machine-tailscale.yaml`.
**Persistence**: rendered into the running node's machineconfig by talhelper; talosctl applies; extension reads at start.

### Full file content

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
```

### Field semantics

| key | value | why this value |
|---|---|---|
| `TS_HOSTNAME` | `talos-ii-${HOSTNAME}` | Talos env-substitution yields per-node values `talos-ii-ms01-{a,b,c}`. Prefix avoids collision with future generic-`ms01-a` enrollments by other operators. |
| `TS_ROUTES` | `10.44.0.0/16,10.55.0.0/16` | Spec D3: PodCIDR + ServiceCIDR. Comma-separated per containerboot convention. |
| `TS_EXTRA_ARGS` | `--advertise-tags=tag:talos-ii-node --accept-routes` | Tailscale `up`-command extra flags. `advertise-tags` is mandatory for OAuth-minted keys. `accept-routes` makes the node receive talos-i's advertised CIDRs once talos-i adopts. |
| `TS_ACCEPT_DNS` | `false` | Don't rewrite host `/etc/resolv.conf` — pods resolve `ts.net` via cluster CoreDNS forward (Entity 4), not via host MagicDNS. |
| `TS_AUTH_ONCE` | `true` | Don't re-`up` on every container restart. Long-lived host service. |

### Notably absent

- `TS_AUTHKEY` — lives in the secret file (Entity 3), NOT here. Containerboot reads both and merges.
- `TS_USERSPACE` — left default (kernel networking). MS-01 has TUN support; userspace mode would lose performance.
- `TS_KUBE_SECRET` — N/A; we are not running tailscaled as a Pod.

---

## Entity 3 — OAuth credential SOPS file

**Type**: Talos `machine.files` patch.
**Path**: `talos/patches/global/machine-files-tailscale-secret.sops.yaml` (committed encrypted; cleartext intermediate is `.gitignore`-d in the workflow).
**Persistence**: SOPS-encrypted at rest; decrypted by talhelper at apply time; landed at `/var/etc/tailscale/auth.env` on every node with mode `0o600`.

### Pre-encryption content

```yaml
---
machine:
  files:
    - op: create
      path: /var/etc/tailscale/auth.env
      permissions: 0o600
      content: |
        TS_AUTHKEY=tskey-client-XXXXXXXXXXXXXX?ephemeral=true&preauthorized=true
```

### Encryption procedure

```sh
sops -e -i talos/patches/global/machine-files-tailscale-secret.sops.yaml
```

The `.sops.yaml` rule `talos/.*\.sops\.ya?ml` is whole-file (`mac_only_encrypted: true`), with age recipient `age19w3svwspecedu893ges7te9qc5qgj3r5tykpkqrl43f90ndlvg4qant4ej`. Round-trip verify before commit:

```sh
sops -d talos/patches/global/machine-files-tailscale-secret.sops.yaml | grep TS_AUTHKEY
```

### OAuth client mint procedure (one-shot, manual)

1. Tailscale admin → Settings → OAuth clients → "Generate OAuth client"
2. Description: `talos-ii subnet routers`
3. Scopes: `auth_keys:write`
4. Tag: `tag:talos-ii-node`
5. Expiry: never
6. Copy the secret immediately (only displayed once).
7. Paste into the `TS_AUTHKEY=` line above.
8. Encrypt with `sops -e -i`.

### Field semantics

| param | value | why |
|---|---|---|
| `tskey-client-XXX-YYY` | the OAuth client secret | Tailscale's documented OAuth wire format (KB 1215) — `tailscale up --auth-key <secret>` mints an ephemeral tagged key. |
| `?ephemeral=true` | URL query | Device record auto-expires ~5 min after heartbeat loss. |
| `?preauthorized=true` | URL query | Skip manual approval in admin UI. |

---

## Entity 4 — CoreDNS forward block

**Type**: Helm chart values entry under `spec.values.servers[]`.
**Path**: `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`.
**Persistence**: Flux reconciles HelmRelease → chart renders Corefile → CoreDNS `reload` plugin picks up new config.

### Diff (additive, not modifying the existing `.` server block)

```yaml
spec:
  values:
    servers:
      - zones:                              # EXISTING — unchanged
          - zone: .
            scheme: dns://
            use_tcp: true
        port: 53
        plugins:
          # ... existing plugin chain unchanged ...
      - zones:                              # NEW
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

### Compiled Corefile equivalent

```
. {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa { ... }
    autopath @kubernetes
    forward . /etc/resolv.conf
    cache { prefetch 20; serve_stale }
    loop
    reload
    loadbalance
    prometheus 0.0.0.0:9153
    log { class error }
}

ts.net:53 {
    errors
    cache 30
    forward . 100.100.100.100
    log { class error }
}
```

CoreDNS picks the longest-matching zone, so `*.ts.net` queries hit the new block; everything else hits `.`.

### Field semantics

| key | value | why |
|---|---|---|
| `zone` | `ts.net` | Tailscale tailnets always live under `*.ts.net` (here `tail5d550.ts.net`). Forwarding the whole TLD is fine — it's resolved by Tailscale's MagicDNS resolver only. |
| `forward parameters` | `. 100.100.100.100` | MagicDNS service IP (Tailscale documented constant). |
| `cache parameters` | `30` | 30s TTL — short to pick up tailnet membership changes quickly; long enough to avoid hammering MagicDNS for repeat lookups. |

---

## Entity 5 — `talconfig.yaml` schematic ID swap

**Type**: in-place string replacement at three sites.
**Path**: `talos/talconfig.yaml`.

### Sites (line numbers approximate)

| line | old | new |
|---|---|---|
| 33 (ms01-a) | `factory.talos.dev/installer-secureboot/5456009e...` | `factory.talos.dev/installer-secureboot/<NEW_ID>` |
| 83 (ms01-b) | same | same |
| 133 (ms01-c) | same | same |

All three swap in the same commit. No other edits to `talconfig.yaml` in this spec's scope.

---

## Entity 6 — Documentation deltas

**Type**: markdown edits + new ADR.
**Persistence**: git history.

### `docs/talos-image-factory.md` modifications

1. **Move** the `5456009e...` section to a new `## Historical schematics — talos-ii` heading; add `**Status:** superseded by <NEW_ID> on YYYY-MM-DD` line.
2. **Create** new `## Active schematic — <NEW_ID>` section above with full structure (factory URL, schematic YAML, "Why each extension" table including `siderolabs/tailscale`).
3. **Update** the "Why each extension" table with row:

   ```
   | siderolabs/tailscale | subnet router for cross-cluster mesh fabric per shared/0002 Option C; OAuth client + tag:talos-ii-node identity | when mesh control plane changes (re-evaluate) |
   ```

4. **Remove** the `siderolabs/tailscale` row from the "What is NOT in this schematic" table at line ~87 (the row currently states "rejected because operator pattern; anti-pattern for our setup" — this is now wrong per Constitution v1.2.0 / shared/0002).
5. **Rewrite** the "Tailscale: host extension vs in-cluster operator" footnote (line ~135) to reflect that BOTH are now in use complementarily, with cross-link to shared/0002.

### `docs/decisions/talos-ii/0014-tailscale-host-extension.md` (NEW)

Standard ADR template. Cross-links per FR-018:
- shared/0002 (parent decision)
- shared/0003 (talos-i positioning, why this is mesh fabric)
- shared/0004 (sing-box edge case)
- talos-ii/0004 (official factory constraint)
- talos-ii/0005 (Secure Boot constraint)

Decisions captured:
- D1: HA 3-node topology
- D2: OAuth client + `tag:talos-ii-node`
- D3: advertise PodCIDR + ServiceCIDR

### `docs/operations/talos-ii-tailscale-mesh.md` (NEW)

Operator runbook. Sources content from this spec's [quickstart.md](./quickstart.md). Sections:
- Deploy (P0 → P5)
- Verify (V1 → V5)
- Rollback (Tier 1 / Tier 2 / Tier 3 per Q8)
- Decommission (revoke OAuth client, remove patches, re-pin schematic, remove `tag:talos-ii-node` from ACL)

### `docs/cluster-definition.md` modifications

Under the talos-ii section, add a line under "Network identity":
- `tag:talos-ii-node` — Tailscale identity for all three ms01-* nodes (subnet router + tailnet member)

### `docs/index.md` modifications

If the index lists ADRs by cluster, add `talos-ii/0014-tailscale-host-extension.md` to the talos-ii decisions list.

---

## Cross-entity invariants

1. **Schematic ID consistency**: the new ID appearing in `talos/talconfig.yaml` MUST match the active section header in `docs/talos-image-factory.md`. Lint check: `grep -F "<NEW_ID>" talos/talconfig.yaml docs/talos-image-factory.md` returns 4 matches (3 in talconfig + 1 in docs).
2. **Secret round-trip**: `sops -d talos/patches/global/machine-files-tailscale-secret.sops.yaml | grep -q '^TS_AUTHKEY=tskey-client-'` returns 0 before commit. Round-trip is the only reliable encryption check (per project memory `feedback_sops_cross_repo_cwd.md`).
3. **CoreDNS server-block uniqueness**: only one `servers[]` entry per `port:zone` tuple. Adding `ts.net:53` is unique because the existing entry is `.` (catch-all).
4. **Tag string consistency**: `tag:talos-ii-node` appears identically in (a) `TS_EXTRA_ARGS=--advertise-tags=tag:talos-ii-node`, (b) Tailscale ACL JSON, (c) OAuth client ownership, (d) ADR 0014 text. One literal, four places.
