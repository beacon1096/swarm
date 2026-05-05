# Contract — `ExtensionServiceConfig` for tailscale

**File**: `talos/patches/global/machine-tailscale.yaml`
**Document apiVersion**: `v1alpha1`
**Document kind**: `ExtensionServiceConfig`
**Service name**: `tailscale` (matches the extension's manifest name; do not change)

## Required environment keys

| Key | Value | Required? | Source of truth |
|---|---|---|---|
| `TS_HOSTNAME` | `talos-ii-${HOSTNAME}` | YES | Talos env-substitution; per-node `talos-ii-ms01-{a,b,c}` |
| `TS_ROUTES` | `10.44.0.0/16,10.55.0.0/16` | YES | Constitution III; spec D3 |
| `TS_EXTRA_ARGS` | `--advertise-tags=tag:talos-ii-node --accept-routes` | YES | spec FR-007 |
| `TS_ACCEPT_DNS` | `false` | YES | Plan-stage decision (Q2 + Q3); avoid host-resolv leak |
| `TS_AUTH_ONCE` | `true` | YES | Long-lived host service; prevent re-`up` storm |

## Forbidden environment keys

| Key | Why forbidden |
|---|---|
| `TS_AUTHKEY` | MUST NOT be in this file — secret material lives in `/var/etc/tailscale/auth.env` (machine-files patch) |
| `TS_USERSPACE` | Default (kernel networking) is correct; userspace mode loses performance |
| `TS_KUBE_SECRET` | Not running tailscaled as a Pod |

## Validation

After upgrade:

```sh
talosctl get extensionserviceconfigs --nodes 172.16.87.201
# Expected one row:
# NAMESPACE   TYPE                     ID          VERSION
# runtime     ExtensionServiceConfig   tailscale   1
```

```sh
talosctl get extensionserviceconfigs tailscale -o yaml --nodes 172.16.87.201 | grep -E '^- TS_'
# Expected: all five required keys present with correct values
```

## Round-trip with hostname substitution

If `${HOSTNAME}` literal appears in `talosctl get` output (i.e. substitution failed), fall back to per-node patches:

```text
talos/patches/ms01-a/machine-tailscale.yaml   # TS_HOSTNAME=talos-ii-ms01-a
talos/patches/ms01-b/machine-tailscale.yaml   # TS_HOSTNAME=talos-ii-ms01-b
talos/patches/ms01-c/machine-tailscale.yaml   # TS_HOSTNAME=talos-ii-ms01-c
```

(remove the global one) — three near-duplicate files. Cost is acceptable; ergonomic loss is small.
