# sing-box — cluster egress proxy

`sing-box` is the cluster's outbound proxy for any traffic that
needs to reach destinations the host network can't reliably get to
on its own (control planes blocked by GFW, registries that go
through CDNs with intermittent loss, etc.). It exposes a mixed
inbound on port 7890 — speaks HTTP `CONNECT` and SOCKS5 on the
same port — so any client that knows how to set `HTTPS_PROXY` /
`HTTP_PROXY` can use it without modification.

## Two sing-box instances, different jobs

There are two sing-box processes in this rack. Don't confuse them:

| where | purpose | listener | who uses it |
|---|---|---|---|
| **on-host**, on `172.16.80.240` | terminate non-CN traffic on the gateway box, hand routes to BIRD/OSPF for the UDR | `127.0.0.1:7890` (HTTP/SOCKS5), `tun0` (transparent) | `bird` for OSPF announcement; nothing else now |
| **in-cluster**, in `network/sing-box` | egress for cluster workloads (and zot) that need to reach blocked control planes | `sing-box.network.svc.cluster.local:7890` (in-cluster) and `172.16.87.41:7890` (LB) | tailscale operator+proxies, zot, anything else with `HTTPS_PROXY` set |

Originally the in-cluster sing-box used the on-host one as upstream
(or routed via tun0). Once the in-cluster sing-box was bootstrapped,
**we cut the dependency** — the on-host instance now only feeds BIRD,
and zot's egress was moved to the in-cluster LB IP. If the host box
disappears, the cluster's egress keeps working.

## In-cluster deployment

[`kubernetes/apps/network/sing-box/`](../../kubernetes/apps/network/sing-box/)

| file | role |
|---|---|
| `helmrelease.yaml` | bjw-s app-template, 2 replicas, runs the NixOS-built sing-box image |
| `secret.sops.yaml` | the actual sing-box `config.json` (route rules, outbounds), encrypted |
| `forgejo-pull-secret.sops.yaml` | future: pull credentials when image moves off the bootstrap zot path |
| `service-lb.yaml` | LoadBalancer Service, `lbipam.cilium.io/ips: 172.16.87.41`, for off-cluster callers |
| `ocirepository.yaml` | flux OCIRepository pointing at the bjw-s app-template chart |

The image is `172.16.80.240:5000/infrastructure/nix-fleet/sing-box:init`,
a NixOS rootfs built from `/etc/nixos`'s `k8s-sing-box-oci` derivation:

```
nix build .#k8s-sing-box-oci
```

We bypass NixOS's systemd init and exec the sing-box binary directly:

```yaml
command: ["/nix/store/7fl1bc1p4a3z6wc1bcc2b7sg1ys1fkc2-sing-box-1.13.5/bin/sing-box"]
args: ["run", "-c", "/etc/sing-box/config.json"]
```

The `/nix/store` hash changes whenever nixpkgs moves — bump it
together with the image tag whenever the pipeline ships a new build.
The image itself is the bootstrap `:init` tag, hand-pushed once;
later builds will produce `v1.13.x`-style tags via the standard
nix-fleet release pipeline (manual main → matrix approval → tagged →
prod).

CA bundle for upstream TLS comes from a hostPath mount of Talos's
`/etc/ssl/certs` (read-only).

## Exposing to off-cluster callers

`172.16.87.41` is Cilium L2-announced on the management VLAN.
`172.16.80.0/24` and `172.16.87.0/24` are routed by the UDR, so any
host on either VLAN can reach `172.16.87.41:7890` directly. Today
only the zot host (`172.16.80.240`) uses it externally — see
[zot mirror docs](zot-mirror.md).

The in-cluster ClusterIP service (`sing-box.network.svc.cluster.local:7890`)
stays unchanged for pod-network callers — pods don't need to go
through a LoadBalancer just to reach a sibling Service.

## Who uses it (and how)

### Tailscale operator

The operator pod and every per-Service proxy pod need to reach
`controlplane.tailscale.com` and `log.tailscale.com`, both blocked.

- Operator: postRenderer in
  [`kubernetes/apps/network/tailscale/app/helmrelease.yaml`](../../kubernetes/apps/network/tailscale/app/helmrelease.yaml)
  injects `HTTPS_PROXY=http://sing-box.network.svc.cluster.local:7890`
  on the Deployment.
- Per-Service proxy pods: a `ProxyClass` resource named `proxied`
  carries the same env. Services opt in with annotation
  `tailscale.com/proxy-class: proxied`. See
  [`proxyclass.yaml`](../../kubernetes/apps/network/tailscale/app/proxyclass.yaml)
  and [tailscale operator docs](tailscale-operator.md).

### zot mirror

systemd unit drop-in
`/etc/systemd/system/talos-mirror.service.d/proxy.conf` on the
proxy host:

```
Environment="HTTPS_PROXY=http://172.16.87.41:7890"
Environment="HTTP_PROXY=http://172.16.87.41:7890"
Environment="NO_PROXY=127.0.0.1,localhost,172.16.0.0/12,10.0.0.0/8"
```

zot uses these for its sync extension's outbound to upstream
registries. See [zot mirror docs](zot-mirror.md).

### Future callers

Any HelmRelease that needs to reach a blocked endpoint can just add
the same env vars to the container spec. The cluster doesn't have
a transparent egress path (no MASQUERADE-on-tun0) — apps have to
explicitly opt in via env.

## NO_PROXY conventions

When setting `HTTPS_PROXY` on a workload, also set:

```
NO_PROXY=127.0.0.1,localhost,10.44.0.0/16,10.55.0.0/16,172.16.0.0/12,svc,svc.cluster.local,cluster.local
```

The CIDR ranges:

- `10.44.0.0/16` — pod network
- `10.55.0.0/16` — service network
- `172.16.0.0/12` — covers all our VLANs (.20/.80/.87)

The bare `svc` / `svc.cluster.local` / `cluster.local` are needed
because some Go HTTP clients match `NO_PROXY` against the *unresolved*
hostname, not the resolved IP. The Tailscale operator notably broke
once when only IP CIDRs were listed.

**Caution**: avoid setting `HTTP_PROXY` / `HTTPS_PROXY` on
`flux-source-controller` or `flux-helm-controller` globally — when
this was tried on 2026-04-28, `NO_PROXY` matched against `*.svc` but
not the trailing-dot variant `*.svc.`, breaking ALL HelmReleases.
Use per-app env injection instead.

## Config (the rule set)

`config.json` lives in `kubernetes/apps/network/sing-box/app/secret.sops.yaml`
and is encrypted with SOPS+age. Mounted at `/etc/sing-box/config.json`
read-only via the `config` Secret persistence in the helmrelease.

Modifying the rule set: decrypt, edit, re-encrypt:

```bash
sops kubernetes/apps/network/sing-box/app/secret.sops.yaml
```

After editing, the helmrelease will re-roll the StatefulSet on next
flux reconcile because the Secret content changed. (The `reloader`
controller is installed but the bjw-s template doesn't auto-annotate
secret-mounted pods — manual `kubectl rollout restart` is fine for
config changes you want to apply now.)

## Status as of 2026-04-28

- 2 replicas running, ClusterIP + LoadBalancer (`172.16.87.41`) both healthy
- Tailscale operator + proxies routing through it (operator
  successfully reaches `controlplane.tailscale.com`)
- zot mirror's sync extension routing through it (verified
  end-to-end pulls of `library/nginx`, `library/alpine`,
  `tailscale/k8s-operator`)
- On-host sing-box on `172.16.80.240` is no longer in any cluster
  data path; kept only for BIRD/OSPF route advertisement to the UDR
