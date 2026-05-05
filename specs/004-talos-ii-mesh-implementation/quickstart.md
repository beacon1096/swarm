# Operator quickstart — talos-ii mesh deploy

This is the operator playbook for landing `siderolabs/tailscale` on talos-ii. It mirrors the eight phases (P0–P7) called out in `plan.md`. The full validation suite is V1–V5 in [contracts/validation-procedure.md](./contracts/validation-procedure.md).

Estimated wall-clock: 60–90 minutes for the deploy proper, plus 30 min documentation.

---

## P0 — Pre-flight (one-time)

### P0.1 — Tailscale ACL declares `tag:talos-ii-node`

In the Tailscale admin UI → Access Controls, ensure the JSON includes:

```jsonc
"tagOwners": {
  "tag:talos-ii-node": ["autogroup:admin"]
  // … existing tags untouched
},
"acls": [
  // existing rules untouched
  // The auto-default-allow-all-tagged-devices is sufficient for v1;
  // tighter ACLs are a follow-up.
]
```

If the tag is already declared (e.g. by an earlier exploratory run), no change.

### P0.2 — Mint OAuth client

Tailscale admin → Settings → OAuth clients → **Generate OAuth client**:
- Description: `talos-ii subnet routers`
- Scopes: `auth_keys:write`
- Tag: `tag:talos-ii-node`
- Expiry: never

Copy the client secret (`tskey-client-…`) immediately — only displayed once.

### P0.3 — Verify operator laptop is on the tailnet

```sh
tailscale status
# Should list the laptop as a tailnet member of tail5d550.ts.net
# Routes accepted: tailscale set --accept-routes (if not already)
```

### P0.4 — Verify sing-box DS excludes `100.64.0.0/10`

```sh
kubectl exec -n network ds/sing-box -- jq -r '.. | objects | select(.action=="route_exclude") | .ip_cidr // .ip_cidr_set // .geosite' /etc/sing-box/config.json
# Expected: a list including '100.64.0.0/10' (literal CIDR, not a geosite)
```

If absent, BLOCK and patch the `/etc/nixos modules/common/sing-box.nix` source first (separate change, not this spec's scope).

---

## P1 — Schematic generation

### P1.1 — Submit factory schematic

Open https://factory.talos.dev/, configure:
- Architecture: `amd64`
- Bootloader: `sd-boot`
- Secure Boot: enabled
- Extensions: `siderolabs/intel-ucode`, `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`, **`siderolabs/tailscale`**
- Talos version: `v1.12.7`

Submit. Capture the resulting schematic ID — it is a 64-char hex string distinct from `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4`.

### P1.2 — Sanity-check the URL

```sh
curl -fsSI https://factory.talos.dev/image/<NEW_ID>/v1.12.7/metal-amd64.iso
# Expected: HTTP/2 200
```

---

## P2 — Manifest authoring

### P2.1 — Swap schematic ID in `talos/talconfig.yaml`

Replace `5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4` with the new ID at lines 33, 83, 133 (one per node `talosImageURL`).

### P2.2 — Create `talos/patches/global/machine-tailscale.yaml`

Content per [data-model.md Entity 2](./data-model.md#entity-2--extensionserviceconfig-for-tailscale).

### P2.3 — Create cleartext secret patch

```sh
cat > talos/patches/global/machine-files-tailscale-secret.sops.yaml <<'EOF'
---
machine:
  files:
    - op: create
      path: /var/etc/tailscale/auth.env
      permissions: 0o600
      content: |
        TS_AUTHKEY=tskey-client-XXXXXXXXXXXXXX?ephemeral=true&preauthorized=true
EOF
```

Replace the `tskey-client-XXX…` placeholder with the real OAuth client secret from P0.2.

### P2.4 — SOPS-encrypt in place

```sh
sops -e -i talos/patches/global/machine-files-tailscale-secret.sops.yaml

# Round-trip verify:
sops -d talos/patches/global/machine-files-tailscale-secret.sops.yaml | grep -q '^.*TS_AUTHKEY=tskey-client-' \
  && echo OK || echo FAIL
```

If FAIL: do not proceed. The cleartext is still in your shell history; clean it up before re-trying.

### P2.5 — Update CoreDNS HelmRelease

Edit `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`. Append the new `servers[]` entry per [data-model.md Entity 4](./data-model.md#entity-4--coredns-forward-block).

---

## P3 — Talos config regen

```sh
task talos:gen-config
# or whatever the repo's regen target is — check Taskfile.yaml

# Inspect the diff in clusterconfig/ to confirm:
# - all three nodes have new talosImageURL
# - all three have ExtensionServiceConfig:tailscale document
# - all three have machine.files entry for /var/etc/tailscale/auth.env
git diff clusterconfig/
```

---

## P4 — Commit

```sh
git add talos/talconfig.yaml \
        talos/patches/global/machine-tailscale.yaml \
        talos/patches/global/machine-files-tailscale-secret.sops.yaml \
        kubernetes/apps/kube-system/coredns/app/helmrelease.yaml \
        clusterconfig/

git commit -m "plan(talos-ii-mesh): rolling schematic upgrade + OAuth subnet-router on 3 nodes"
```

(The commit also lands docs in P6 — but those can come in a follow-up commit on the same branch if the operator prefers smaller commits. Single-commit is the plan-recommended path.)

---

## P5 — Rolling upgrade

**One node at a time. Verify between each.**

### P5.1 — ms01-a

```sh
task talos:upgrade-node IP=172.16.87.201
# Wait for node Ready
kubectl get nodes -w
```

When node is `Ready`:

**V1 partial check** (only ms01-a online so far):
```sh
tailscale status | grep talos-ii-ms01-a
# Expected: 'talos-ii-ms01-a online ... 10.44.0.0/16 10.55.0.0/16'
# Subnet route status active
```

**V2/V3 from a pod scheduled on ms01-a**:
```sh
kubectl run -n default --rm -it curl-ms01a --image=curlimages/curl \
  --overrides='{"spec":{"nodeName":"ms01-a"}}' -- sh -c '
    getent hosts attic.tail5d550.ts.net && \
    curl -fsS http://attic.tail5d550.ts.net/ -o /dev/null && \
    echo OK'
```

If V1/V2/V3 fail: rollback (P7 below) and diagnose before continuing.

### P5.2 — ms01-b

```sh
task talos:upgrade-node IP=172.16.87.202
```

Repeat V1/V2/V3 with `nodeName: ms01-b`. Confirm prior V1 still includes ms01-a.

### P5.3 — ms01-c

```sh
task talos:upgrade-node IP=172.16.87.203
```

Repeat. All three should now appear in `tailscale status`.

---

## P6 — End-to-end validation

Run the full V1–V5 suite per [contracts/validation-procedure.md](./contracts/validation-procedure.md). All five must pass.

### V1 — `tailscale status` from operator laptop

Expected: three rows for `talos-ii-ms01-{a,b,c}` online with `tag:talos-ii-node`, advertised routes `10.44.0.0/16,10.55.0.0/16`, route status `active`.

### V2 — pod-side DNS

```sh
kubectl run -n default --rm -it curl-test --image=curlimages/curl -- \
  getent hosts attic.tail5d550.ts.net
# Expected: 100.x.y.z address
```

### V3 — pod-side curl

```sh
kubectl run -n default --rm -it curl-test --image=curlimages/curl -- \
  curl -fsS http://attic.tail5d550.ts.net/ -o /dev/null && echo OK
# Cross-check attic-side log: source IP is one of the three router 100.x addresses.
```

### V4 — laptop → pod IP

```sh
# On operator laptop
curl -fsS http://<known-pod-ip-on-ms01-c>:<port>/
# Expected: pod's response

# On the entry node (whichever ms01-* tailscale picked):
talosctl logs --nodes <entry-ip> -f extensions
# Expected: tailscaled logs the inbound connection
```

### V5 — failover under sustained load

In one terminal:
```sh
kubectl run -n default -it curl-loop --image=curlimages/curl -- sh -c '
  while true; do curl -sS -o /dev/null -w "%{http_code}\n" http://attic.tail5d550.ts.net/ || echo FAIL; sleep 1; done
'
```

In another terminal: `task talos:upgrade-node IP=172.16.87.201` (reboot ms01-a). Observe loop output: at most ~30 s of failures, then resume. Repeat for ms01-b and ms01-c.

---

## P7 — Documentation

In a follow-up commit on the same branch (or amended into the deploy commit):

### P7.1 — `docs/talos-image-factory.md`

- Move `5456009e...` section to "Historical schematics — talos-ii" with `**Status:** superseded by <NEW_ID> on YYYY-MM-DD` line.
- Create new "Active schematic — `<NEW_ID>`" section with all sub-sections (factory URL, YAML, "Why each extension" updated table including `siderolabs/tailscale`).
- Remove the `siderolabs/tailscale` row from the "What is NOT in this schematic" table.
- Rewrite the "Tailscale: host extension vs in-cluster operator" footnote to reflect both-in-use, cross-link shared/0002.

### P7.2 — ADR

`docs/decisions/talos-ii/0014-tailscale-host-extension.md` per [data-model.md Entity 6](./data-model.md#entity-6--documentation-deltas).

### P7.3 — Runbook

`docs/operations/talos-ii-tailscale-mesh.md` — copy + adapt the deploy/verify/rollback content from this quickstart.

### P7.4 — Cluster definition

`docs/cluster-definition.md` — under talos-ii: add `tag:talos-ii-node` to the network-identity section.

### P7.5 — Index

`docs/index.md` — add ADR 0014 entry.

---

## Rollback (P8 / Q8 ladder)

Use only on validation failure or unrecoverable boot.

### Tier 1 — Schematic re-pin (recommended)

```sh
# Re-edit talconfig.yaml: replace <NEW_ID> with 5456009e... at all three sites
git checkout -- talos/talconfig.yaml  # or manual edit
task talos:gen-config
task talos:upgrade-node IP=172.16.87.201
task talos:upgrade-node IP=172.16.87.202
task talos:upgrade-node IP=172.16.87.203
```

Tailscale device records orphan in admin UI. Manual cleanup: select all three `talos-ii-ms01-*` devices → Delete. OAuth client itself remains valid; do NOT delete unless rotating.

### Tier 2 — Live config-only revert

If schematic boots fine but extension config is broken:

```sh
talosctl edit mc --nodes 172.16.87.201
# Remove ExtensionServiceConfig:tailscale document, save & exit
# Repeat for .202 and .203
```

Then fix patch in git, re-apply.

### Tier 3 — Catastrophic boot failure

Use vPro AMT KVM (BIOS-default on i226 NIC subnet) → boot rescue ISO → re-flash with prior schematic. Detailed in `docs/operations/talos-ii-rescue.md` (existing).

---

## Decommission (separate, future)

If a future operator decides to remove the host extension entirely:

1. Revoke OAuth client in Tailscale admin UI.
2. Remove `tag:talos-ii-node` from ACL.
3. Delete `talos/patches/global/machine-tailscale.yaml` and `machine-files-tailscale-secret.sops.yaml`.
4. Submit a new schematic without `siderolabs/tailscale`.
5. Re-pin in `talos/talconfig.yaml`; roll.
6. Remove the `ts.net:53` server block from CoreDNS HelmRelease.
7. Update docs: move current active schematic to historical, etc.

This is not in scope for this spec — the operator + extension are complementary per Constitution §VII v1.2.0 and shared/0002. Decommission would require a new ADR.
