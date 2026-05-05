# Contract — CoreDNS `ts.net:53` forward block

**File**: `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml`
**Section**: `spec.values.servers[]` — append a new entry; do NOT modify the existing `.` entry.

## Exact YAML to append

Append AFTER the existing `.`-zone entry, BEFORE any non-server top-level keys:

```yaml
      - zones:
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

## Resulting Corefile (post-Helm-render)

CoreDNS evaluates by zone match, longest match wins. Both server blocks listen on port 53; queries land on whichever zone matches:

```
. {
    errors
    health { lameduck 5s }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods verified
        fallthrough in-addr.arpa ip6.arpa
    }
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

## Validation

```sh
# After Flux reconciles:
kubectl get cm -n kube-system coredns -o jsonpath='{.data.Corefile}' | grep -A6 '^ts.net:53'
# Expected: forward . 100.100.100.100 line in the output
```

```sh
kubectl run -n default --rm -it dns-test --image=curlimages/curl -- \
  getent hosts attic.tail5d550.ts.net
# Expected: 100.x.y.z address (Tailscale MagicDNS-resolved)
```

```sh
# Also verify non-tailnet resolution still works (regression check):
kubectl run -n default --rm -it dns-test --image=curlimages/curl -- \
  getent hosts example.com
# Expected: real public IP via the existing forward . /etc/resolv.conf path
```

## Anti-patterns (do not do)

1. **Adding `forward ts.net 100.100.100.100` inside the existing `.` server block.** Order-dependent; conflicts with `forward . /etc/resolv.conf`.
2. **Editing the rendered ConfigMap directly.** Flux reverts on next reconcile.
3. **Increasing cache TTL beyond 60s.** Tailscale device IPs can change on re-registration; long TTLs delay re-discovery.
