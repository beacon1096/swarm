# Tailscale subnet router (host extension) — operations

`siderolabs/tailscale` runs as a Talos system extension on every
ms01-* node. Each node joins the tailnet under a stable hostname
(`talos-ii-ms01-{a,b,c}`) and advertises the cluster's podCIDR
(`10.44.0.0/16`) and svcCIDR (`10.55.0.0/16`) onto the tailnet so
off-cluster tailnet members can reach in-cluster IPs directly.

This is the **host-mode** layer. The **operator** (in-cluster
StatefulSet that wraps individual Services as ts-* proxy devices) is
a separate concern and lives in
[`tailscale-operator.md`](tailscale-operator.md). The two layers
work together — see
[ADR talos-ii/0014](../decisions/talos-ii/0014-tailscale-host-extension.md)
for the architecture.

## Where it lives

```
talos/
  patches/
    global/extension-tailscale-authkey.sops.yaml   # TS_AUTHKEY (SOPS, whole-file encrypted)
    ms01-a/machine-tailscale.yaml                  # ESC: TS_HOSTNAME=talos-ii-ms01-a + ROUTES + EXTRA_ARGS + …
    ms01-b/machine-tailscale.yaml                  # same shape, hostname differs
    ms01-c/machine-tailscale.yaml                  # same shape, hostname differs
  talconfig.yaml                                   # references all 4 patches in the global + per-node patches lists
```

talhelper merges the global ESC fragment (carrying `TS_AUTHKEY`) with
the per-node ESC fragment by `kind+name=tailscale`. Each rendered
`talos/clusterconfig/kubernetes-ms01-<x>.yaml` ends up with a single
ExtensionServiceConfig containing all 6 env entries:

| env | source | per-node? | notes |
|---|---|---|---|
| `TS_HOSTNAME` | `ms01-<x>/machine-tailscale.yaml` | yes | becomes the tailnet device name |
| `TS_ROUTES` | per-node (identical value across nodes today) | no | `10.44.0.0/16,10.55.0.0/16` |
| `TS_EXTRA_ARGS` | per-node (identical) | no | `--advertise-tags=tag:talos-ii-node --netfilter-mode=off` |
| `TS_ACCEPT_DNS` | per-node | no | `false` — pods use cluster CoreDNS (which itself forwards `*.ts.net` to MagicDNS); host doesn't take DNS from tailnet |
| `TS_AUTH_ONCE` | per-node | no | `true` — auth-key only used on first registration |
| `TS_AUTHKEY` | `global/extension-tailscale-authkey.sops.yaml` (SOPS) | shared | OAuth-issued ephemeral key, scope `auth_keys:write`, tag `tag:talos-ii-node` |

## Tailscale-side config (admin)

Two pieces (the `tag:talos-ii-node` tag is shared between the OAuth
client and the per-device identity):

### 1. OAuth client

Tailscale admin → Settings → OAuth clients → Generate.

| field | value |
|---|---|
| Description | `talos-ii host subnet routers` |
| Tag | `tag:talos-ii-node` |
| Scopes | `Auth Keys: Write` |

The resulting `tskey-client-…` is what goes into
`extension-tailscale-authkey.sops.yaml`. **Don't** mix this with the
operator's OAuth client (separate decision — see
[ADR 0014 §3](../decisions/talos-ii/0014-tailscale-host-extension.md#3-oauth-client--ephemeral-tag-based-acl)
for the split rationale).

### 2. ACL JSON

```jsonc
"tagOwners": {
  "tag:talos-ii-node":     ["autogroup:admin"],
  "tag:talos-ii-operator": ["autogroup:admin"],
  "tag:talos-ii-svc":      ["autogroup:admin"]
},
"autoApprovers": {
  "routes": {
    "10.44.0.0/16": ["tag:talos-ii-node"],
    "10.55.0.0/16": ["tag:talos-ii-node"]
  }
}
```

`autoApprovers.routes` is the no-click rolling-restart contract — a
new node coming up with the right tag advertises and is approved
without admin involvement.

## First-time bring-up (one node)

```bash
# 1. ensure schematic is up to date
talosctl upgrade --nodes=<node-ip> \
  --image=factory.talos.dev/installer-secureboot/012427dcde4d2c4eff11f55adf2f20679292fcdffb76b5700dd022c813908b07:v1.12.7 \
  --timeout=10m

# 2. push the merged config (ESC + TS_AUTHKEY)
talosctl -n <node-ip> apply-config \
  --file=./talos/clusterconfig/kubernetes-ms01-<x>.yaml --mode=auto

# 3. verify
talosctl -n <node-ip> services ext-tailscale          # STATE Running
talosctl -n <node-ip> get addresses | grep tailscale0  # 100.x assigned

# 4. on tailnet admin, confirm:
#    - talos-ii-ms01-<x> appears with tag:talos-ii-node
#    - Subnets 10.44.0.0/16 + 10.55.0.0/16 auto-approved
```

`apply-config` should report `Applied configuration without a reboot`
on a clean first install — adding ESC doesn't require a reboot, and
without prior `/var/lib/tailscale/tailscaled.state` the extension's
containerboot runs `tailscale up` directly with the merged env.

## Verifying pod → tailnet (V5-equivalent)

```bash
# from a pod scheduled on any ms01-* node:
nslookup talos-ii-ms01-c.tail5d550.ts.net 100.100.100.100
# -> Address: 100.x.x.x   (whatever ms01-c's current ephemeral IP is)

ping -c 3 <that 100.x address>
# -> 0% loss, RTT ~1-2 ms (same-LAN tailnet path)
```

If MagicDNS lookup returns `SERVFAIL` for non-`.ts.net` queries
(e.g. `example.com`), that's expected — `100.100.100.100` only
serves the tailnet zone.

## Rotating `TS_AUTHKEY`

OAuth-issued keys are reusable for many node registrations within
the OAuth client's lifetime — there's no per-key rotation. Rotation
needs are driven by:

- The OAuth client itself being compromised / scanned-and-revoked
  (the 2026-05-05 incident with `kjnW4ZGxQi11CNTRL`). In that case:
  1. Revoke the OAuth client in Tailscale admin.
  2. Generate a new OAuth client (same tag + scope).
  3. Mint a new ephemeral key
     (`?ephemeral=true&preauthorized=true`) from the new client.
  4. Update `extension-tailscale-authkey.sops.yaml`:
     ```bash
     # write cleartext to the final path, then SOPS-encrypt in-place
     # (.sops.yaml creation_rule needs the path to match)
     vi talos/patches/global/extension-tailscale-authkey.sops.yaml
     sops -e -i talos/patches/global/extension-tailscale-authkey.sops.yaml
     ```
  5. `task talos:generate-config` (talhelper merges into rendered configs).
  6. Per node, `talosctl apply-config --mode=auto`.
  7. `talosctl -n <ip> service ext-tailscale restart` — but **note the
     containerboot quirk** in the next section. If just rotating the
     auth-key (not changing other env), `tailscale set` propagation
     is enough; if changing flags, see "Changing TS_EXTRA_ARGS" below.
- The OAuth client's organization revocation policy. Currently no
  expiry; document in incident runbook if that changes.

## Changing `TS_EXTRA_ARGS` (the gotcha)

siderolabs/tailscale's containerboot wrapper **does not** re-run
`tailscale up` on subsequent service restarts; it runs
`tailscale set`. `set` only propagates a subset of prefs (auth-key
hostname, advertise-routes), and explicitly does **not** propagate
`--netfilter-mode` or `--accept-routes`. So a config change to those
flags doesn't take effect by `service restart` alone — you need to
force a fresh `tailscale up` by removing the persisted state.

The procedure (verified on ms01-a 2026-05-05):

```bash
# 1. apply-config to push the new ESC env (talhelper genconfig has rendered it)
talosctl -n <node-ip> apply-config --file=...

# 2. stop the extension service (graceful — tailscaled cleans up table 52 + nft)
talosctl -n <node-ip> service ext-tailscale stop
# wait for STATE Finished

# 3. delete /var/lib/tailscale/tailscaled.state via a one-shot privileged pod.
#    Talos doesn't expose `rm` over its API; we ride a hostPath pod in the
#    `forgejo-runner` namespace (the only namespace with PSA enforce=privileged):
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: { name: ts-state-reset, namespace: forgejo-runner }
spec:
  nodeName: <node>      # ms01-a / ms01-b / ms01-c
  hostPID: true
  restartPolicy: Never
  tolerations: [{ operator: Exists }]
  containers:
    - name: rm
      image: mirror.gcr.io/library/busybox:1.37
      command: [sh, -c, "rm -fv /host/var/lib/tailscale/tailscaled.{state,log.conf,log1.txt,log2.txt}"]
      securityContext: { privileged: true }
      volumeMounts: [{ name: tsstate, mountPath: /host/var/lib/tailscale }]
  volumes: [{ name: tsstate, hostPath: { path: /var/lib/tailscale, type: "" } }]
EOF
kubectl -n forgejo-runner wait pod/ts-state-reset --for=condition=Ready --timeout=60s || \
  kubectl -n forgejo-runner logs ts-state-reset
kubectl -n forgejo-runner delete pod ts-state-reset

# 4. start the extension - containerboot sees no state, runs `tailscale up` with full TS_EXTRA_ARGS
talosctl -n <node-ip> service ext-tailscale start

# 5. verify the new tailnet identity (different ephemeral IP since state was reset)
talosctl -n <node-ip> get addresses | grep tailscale0
```

(`hostPath.type: ""` is required — Talos's view of `/var/lib/tailscale`
fails the kubelet's default `Directory` validation; empty type skips
the check.)

## Decommissioning a node

The tailnet device is **ephemeral**, so it auto-cleans when:

- The Talos node powers off / reboots — temporary, comes back as same
  hostname under a new ephemeral IP within ~10 s of next boot.
- The Talos node is removed from the cluster — auto-cleaned within
  Tailscale's stale-device timeout (~5 min).

If you need to force-clean a stale device (rare — only after a hard
power-off without graceful shutdown):

```
# tailscale admin → Machines → talos-ii-ms01-<x> → … → Remove
```

## Common debug paths

### Symptom: `talosctl -n 172.16.87.20x version` hangs (gRPC read timeout)

99% of the time this is the
[wedge documented in ADR 0014 §6](../decisions/talos-ii/0014-tailscale-host-extension.md#6---accept-routesfalse-interim--local-lan-advertise-overlap-is-fatal):
some peer is advertising a tailnet route that overlaps the node's
own LAN, and `--accept-routes=true` reactivated. Check:

```bash
# from a tailnet member that's not on the same VLAN as ms01-*:
tailscale status   # look for entries with PrimaryRoutes that overlap 172.16.87.0/24
```

The fix on the node side is `--accept-routes=false` (the default
since 2026-05-05). If somehow that regressed:

1. Stop ext-tailscale (graceful unwedge — table 52 cleans).
2. Re-render with `--accept-routes` removed from `TS_EXTRA_ARGS`.
3. Apply + state-reset + start (above procedure).

The fix on the advertising side is to either drop the redundant
advertisement, or set up a Tailscale ACL `routes` allowlist (see
[ADR 0014 §6](../decisions/talos-ii/0014-tailscale-host-extension.md#6---accept-routesfalse-interim--local-lan-advertise-overlap-is-fatal))
so `tag:talos-ii-node` simply ignores overlapping ones.

### Symptom: `ext-tailscale` STATE `Waiting`, EVENT `Waiting for extension service config`

The schematic boots but no ESC is applied yet. Either:
- `apply-config` hasn't been run since schematic upgrade, or
- the rendered config doesn't include the ESC (check that the
  per-node patch file ref is in `talconfig.yaml`'s `nodes[].patches`,
  and the global authkey patch is in the cluster-level `patches[]`).

### Symptom: Tailscale dashboard shows `talos-ii-ms01-<x>` but no Subnets

Routes weren't auto-approved. Check:

1. Tailnet ACL JSON has `autoApprovers.routes` for `tag:talos-ii-node`
   covering the advertised CIDRs.
2. The OAuth client is tagged `tag:talos-ii-node`. If you minted the
   auth-key from a *different* OAuth client (or untagged), the
   device's tag doesn't match autoApprovers. `tailscale up`'s
   `--advertise-tags=tag:talos-ii-node` only sets the tag if the
   auth-key permits it — i.e. the OAuth client must own that tag.

### Symptom: pod → tailnet hostname resolves but ping hangs

The MagicDNS lookup goes through CoreDNS's `ts.net` zone forward
(see [ADR 0014 §8](../decisions/talos-ii/0014-tailscale-host-extension.md#8-coredns-tsnet-zone-forwarding-to-magicdns)).
If lookup works but ping doesn't, the problem is the data-plane
side:

1. Confirm the destination is reachable from this node's tailnet
   IP — from the ms01-* host, `ping <100.x destination>`. If that
   also hangs, it's a tailnet routing issue (DERP, peer offline,
   etc.).
2. Confirm Cilium isn't dropping pod → tailscale0 egress. Check
   `kubectl exec` into the pod and `ip route get <100.x>` —
   should resolve via the cilium_host gateway.
3. Check the tailnet peer side advertises a route covering the
   pod's source `10.44.x.x` — without that, replies hit nowhere.
   This is the symmetric of `accept-routes` — peers need to accept
   our advertise.

## Cross-references

- [ADR talos-ii/0014](../decisions/talos-ii/0014-tailscale-host-extension.md) — the architectural decision behind this layer
- [ADR shared/0002](../decisions/shared/0002-mesh-integration-modes.md) — Option C selection
- [`specs/004-talos-ii-mesh-implementation/findings-tailscale-lan-wedge.md`](../../specs/004-talos-ii-mesh-implementation/findings-tailscale-lan-wedge.md) — long-form post-mortem of the wedge investigation
- [`tailscale-operator.md`](tailscale-operator.md) — sibling layer (in-cluster operator)
- [`talos-image-factory.md`](../talos-image-factory.md) — schematic ID + extensions
