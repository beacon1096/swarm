# Tailscale operator — exposing services on the tailnet

The Tailscale Kubernetes operator (`tailscale-operator` Helm chart,
v1.96.5) lets us expose any in-cluster Service onto the tailnet by
adding an annotation. Each exposed Service gets its own per-Service
proxy pod (a StatefulSet `ts-<svc>-<id>-0`) joined to the tailnet as
a discrete Tailscale device. Today this is how cross-cluster
traffic reaches into talos-ii without going through Cloudflare.

## Where it runs

[`kubernetes/apps/network/tailscale/`](../../kubernetes/apps/network/tailscale/)

| file | role |
|---|---|
| `helmrelease.yaml` | the operator chart, with a postRenderer that injects `HTTPS_PROXY` env on the operator Deployment |
| `ocirepository.yaml` | flux OCIRepository pointing at `oci://172.16.80.240:5000/charts/tailscale-operator` (chart pre-pushed to local zot — see below) |
| `proxyclass.yaml` | a `ProxyClass` resource named `proxied` that carries the same `HTTPS_PROXY` env onto per-Service proxy pods |
| `kustomization.yaml` | resource list |

OAuth client credentials live in `cluster-secrets` (re-encrypted from
the swarm-01 era; same OAuth client serves both clusters since they
share a tailnet):

```yaml
SECRET_TAILSCALE_OAUTH_CLIENT_ID
SECRET_TAILSCALE_OAUTH_CLIENT_SECRET
```

These are referenced by `${SECRET_TAILSCALE_OAUTH_CLIENT_ID}` /
`${SECRET_TAILSCALE_OAUTH_CLIENT_SECRET}` in the operator's
`oauth.clientId` / `oauth.clientSecret` values.

## The two GFW workarounds (both required)

The operator and its proxy pods both need to reach
`controlplane.tailscale.com` and `log.tailscale.com`. From talos-ii's
default egress those endpoints reliably TLS-EOF. Two layers, two
workarounds:

### 1. Operator pod — postRenderer Kustomize patch

The `tailscale-operator` chart doesn't expose env config for the
operator container. The chart values would be the natural place to
inject `HTTPS_PROXY`, but they aren't templated in. So we patch the
rendered Deployment via flux's `postRenderers`:

```yaml
postRenderers:
  - kustomize:
      patches:
        - target:
            kind: Deployment
            name: operator
          patch: |
            - op: add
              path: /spec/template/spec/containers/0/env/-
              value: { name: HTTPS_PROXY, value: http://sing-box.network.svc.cluster.local:7890 }
            - op: add
              path: /spec/template/spec/containers/0/env/-
              value: { name: HTTP_PROXY,  value: http://sing-box.network.svc.cluster.local:7890 }
            - op: add
              path: /spec/template/spec/containers/0/env/-
              value: { name: NO_PROXY,    value: "127.0.0.1,localhost,10.44.0.0/16,10.55.0.0/16,172.16.0.0/12,svc,svc.cluster.local,cluster.local" }
```

### 2. Per-Service proxy pods — `ProxyClass`

The operator spawns a StatefulSet (`ts-<svc>-<id>-0`) per exposed
Service. Those pods also need the proxy env, but they're not
managed by the chart. The operator does, however, look at a
`ProxyClass` CRD when one is referenced via annotation:

```yaml
# kubernetes/apps/network/tailscale/app/proxyclass.yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyClass
metadata: { name: proxied }
spec:
  statefulSet:
    pod:
      tailscaleContainer:
        env:
          - { name: HTTPS_PROXY, value: http://sing-box.network.svc.cluster.local:7890 }
          - { name: HTTP_PROXY,  value: http://sing-box.network.svc.cluster.local:7890 }
          - { name: NO_PROXY,    value: "127.0.0.1,localhost,10.44.0.0/16,10.55.0.0/16,172.16.0.0/12,svc,svc.cluster.local,cluster.local" }
```

Services that should be exposed on the tailnet must opt in to this
ProxyClass:

```yaml
metadata:
  annotations:
    tailscale.com/expose: "true"
    tailscale.com/hostname: "forgejo"
    tailscale.com/proxy-class: "proxied"
```

Without `proxy-class: proxied`, the per-Service proxy pod gets no
proxy env and TLS-EOFs against `controlplane.tailscale.com`,
showing up in `kubectl logs` as `NeedsLogin`.

See [sing-box egress docs](sing-box-egress.md) for context on the
`NO_PROXY` value (the unresolved-hostname matching quirk and why
trailing-dot domains broke earlier attempts).

## Why the chart is on local zot

`pkgs.tailscale.com` (the official Helm chart host) is GFW-blocked
and gives a TLS EOF from talos-ii. flux can't fetch the chart through
its source-controller because attaching `HTTPS_PROXY` to the flux
controllers globally broke other HelmReleases (the trailing-dot
NO_PROXY issue).

Workaround: pre-pull and re-push to the LAN zot:

```bash
helm pull tailscale/tailscale-operator --version 1.96.5
helm push tailscale-operator-1.96.5.tgz oci://172.16.80.240:5000/charts --plain-http
```

The `OCIRepository` then references `oci://172.16.80.240:5000/charts/tailscale-operator`
on the LAN, which works without a proxy. zot is configured plain-HTTP
on `:5000` — the self-referential entry in
[`machine-registries.yaml.j2`](../../templates/config/talos/patches/global/machine-registries.yaml.j2)
tells containerd that.

## Currently exposed services

| service | namespace | tailscale hostname | use |
|---|---|---|---|
| `forgejo-tailscale` | `development` | `forgejo` | the talos-i forgejo-runner (when ported in) needs a non-Cloudflare path back to forgejo for event hooks; also serves `LOCAL_ROOT_URL` for in-cluster callers |

That's the only one for now. As more services need cross-cluster or
remote-laptop reach, follow the same pattern: ClusterIP Service with
the three annotations.

## Adding a new exposed service

1. Create (or edit) the Service. Add:
   ```yaml
   metadata:
     annotations:
       tailscale.com/expose: "true"
       tailscale.com/hostname: "<short-name>"
       tailscale.com/proxy-class: "proxied"
   ```
2. Commit + flux reconcile. The operator notices the annotation and
   spawns a `ts-<svc>-<id>-0` StatefulSet in the `tailscale` namespace.
3. The new device shows up at `tailscale.com/admin/machines` named
   `<short-name>` after ~30 s. Authorize it if your tailnet is
   ACL-restricted.
4. Test: from any tailnet member, `curl http://<short-name>.<tailnet>.ts.net:<port>/...`

## Known issues / caveats

- **DERP relay flakiness**: the `cn-qcloud` DERP region is part of
  Tailscale's official infra but unreliable from inside CN. Control
  plane (key exchange via `controlplane.tailscale.com`) works fine
  through sing-box; data plane direct-connection works for hosts
  with public IPs but DERP-relayed connections drop frequently.
  Deferred until we either run our own DERP or tailnet routing
  matures.
- **OAuth client is shared between clusters**: same client ID and
  secret used for talos-ii and talos-i. Don't rotate without
  coordinating both clusters' `cluster-secrets`.
- **Operator can't reach `controlplane.tailscale.com` directly**:
  always check the postRenderer is in effect after any
  `HelmRelease` change. `kubectl -n tailscale describe pod operator-...`
  should show all three proxy env vars.

## Status as of 2026-04-28

- Operator running, OAuth handshake successful
- ProxyClass `proxied` created, in use by `forgejo-tailscale`
- `forgejo` device visible on the tailnet (control plane), data
  plane subject to DERP flakiness above
