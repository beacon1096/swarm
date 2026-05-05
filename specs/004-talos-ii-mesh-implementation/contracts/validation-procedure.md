# Contract — Validation procedure

Five gated steps, each with explicit pass/fail predicates. All five MUST pass before declaring deploy complete (per spec FR-016). Any failure aborts the rollout and triggers rollback (Q8 / quickstart P8).

---

## V1 — `tailscale status` from operator laptop

**Command**:

```sh
tailscale status | grep talos-ii-ms01
```

**Pass criteria** (ALL three):

1. Three rows: `talos-ii-ms01-a`, `talos-ii-ms01-b`, `talos-ii-ms01-c`.
2. Each row's status is `online`.
3. Each row carries `tag:talos-ii-node`.

**Detail check** for route advertisement:

```sh
tailscale status --json | jq '.Peer | to_entries[] | select(.value.Tags // [] | index("tag:talos-ii-node")) | {Name: .value.HostName, Routes: .value.PrimaryRoutes // [], Online: .value.Online}'
```

**Pass**: each peer entry shows `Online: true` AND `Routes` includes (at least) `10.44.0.0/16` and `10.55.0.0/16`.

**Fail mode** examples + diagnostics:
- "0 talos-ii-* peers visible" → OAuth client misconfigured; check admin UI for un-tagged devices and the OAuth client's tag ownership.
- "peers visible but no routes" → check `talosctl logs --nodes <ip> -f -k tailscale` for `--advertise-routes` parsing errors.
- "peers visible, routes advertised, but route status not active" → admin UI → Machines → check "Approve subnet routes". Auto-approve was assumed in P0.1 ACL; if not enabled, manually approve.

---

## V2 — Pod-side DNS resolution

**Command**:

```sh
kubectl run -n default --rm -it dns-test --image=curlimages/curl --restart=Never -- \
  getent hosts attic.tail5d550.ts.net
```

**Pass criterion**: stdout contains a 100.x.y.z address (CGNAT range).

**Fail mode** examples:
- "no resolution" → CoreDNS `ts.net:53` block not picked up. `kubectl rollout restart -n kube-system deployment/coredns` and retry.
- "NXDOMAIN" → tailnet `tail5d550.ts.net` does not contain a host named `attic`. Try a known-good name (e.g. operator laptop's hostname).
- "resolution but to non-100.x address" → catch-all `forward .` is matching ahead of `ts.net:53`. Inspect rendered Corefile per [coredns-forward-block.md](./coredns-forward-block.md) validation.

---

## V3 — Pod-side curl to tailnet HTTP service

**Command**:

```sh
kubectl run -n default --rm -it curl-test --image=curlimages/curl --restart=Never -- \
  curl -fsS http://attic.tail5d550.ts.net/ -o /dev/null -w 'HTTP %{http_code}\n'
```

**Pass criterion**: `HTTP 2xx` or `HTTP 30x` (redirect is fine — curl with `-f` returns 22 on 4xx/5xx, 0 otherwise).

**Cross-check** (run from a tailnet client with attic admin access):

```sh
# attic-side log
kubectl logs -n nix attic-0 --tail 20 | grep '"GET / "'
# Expected: source address is a 100.x address belonging to one of the three subnet-router devices.
```

**Pass criterion** (cross-check): the source IP of the request is a tailnet 100.x address from one of the three `talos-ii-ms01-*` devices, NOT the operator-proxy IP.

**Fail mode** examples:
- "DNS resolves but curl times out" → Cilium BPF masquerade or sing-box auto_redirect intercepting. `talosctl logs --nodes <node> -f -k tailscale` for outgoing connection attempts; `kubectl exec -n network ds/sing-box -- nft list ruleset | grep 100.64` to verify CGNAT exclusion in active nftables.
- "curl succeeds but attic logs source as operator-proxy IP" → traffic went through tailscale-operator instead of subnet router. Confirm the `attic.tail5d550.ts.net` MagicDNS record points to the operator proxy (expected per Story 4) — the CONNECTING source on attic should be the subnet router's 100.x. Re-read attic logs more carefully.

---

## V4 — Tailnet client → Pod IP via subnet router

**Setup**: identify a known Pod IP on ms01-c, e.g.:

```sh
kubectl get pods -A -o wide | grep -m1 ms01-c
# Pick a pod with a known HTTP port — e.g. coredns-...:9153 (prometheus metrics)
```

**Command** (from operator laptop, on tailnet):

```sh
curl -fsS http://<pod-ip>:9153/metrics | head -5
```

**Pass criterion**: stdout contains Prometheus-format metrics (e.g. `# HELP coredns_...`).

**Cross-check** entry node:

```sh
talosctl logs --nodes 172.16.87.201 --tail 20 -f -k tailscale | grep <pod-ip>
# Or any of the three IPs depending on which Tailscale picked.
```

**Pass criterion** (cross-check): exactly one of the three nodes' tailscaled logs the inbound connection.

**Fail mode** examples:
- "connection refused" → reverse path filtering on entry node. `talosctl read /proc/sys/net/ipv4/conf/all/rp_filter` should show `2` (loose) — Talos default. If `1` (strict), file an upstream issue and apply a per-node sysctl patch.
- "connection times out" → inter-node Cilium forwarding broken. Test Pod-IP-to-Pod-IP from inside the cluster first (`kubectl exec curl-test -- curl <pod-ip>:9153`) — if that fails, the issue is Cilium, not Tailscale.

---

## V5 — Failover under sustained load

**Setup** (one terminal):

```sh
kubectl run -n default -it curl-loop --image=curlimages/curl --restart=Never -- sh -c '
  i=0; fail=0
  while [ $i -lt 600 ]; do
    if curl -sS -m 2 -o /dev/null -w "" http://attic.tail5d550.ts.net/; then :; else fail=$((fail+1)); fi
    i=$((i+1))
    sleep 1
  done
  echo "fails=$fail/600"
'
```

**Reboot test** (other terminal, while the loop runs):

```sh
# At t=30s into loop:
task talos:upgrade-node IP=172.16.87.201   # ms01-a
# At t=180s into loop:
task talos:upgrade-node IP=172.16.87.202   # ms01-b
# At t=330s into loop:
task talos:upgrade-node IP=172.16.87.203   # ms01-c
```

**Pass criterion**: final loop output `fails=N/600` with N ≤ 90 (3 reboots × ≤30 s each at 1 req/s).

**Note**: a reboot also restarts kube-proxy / Cilium on that node, which momentarily breaks pod-side DNS if CoreDNS is scheduled there too. The 30 s window is the AGGREGATE limit; if individual reboot hiccups go above ~15 s, that's likely Talos boot time (not Tailscale's reconvergence) and is acceptable. Any single reboot exceeding 60 s is a fail.

---

## Summary table

| Step | Predicate | Source FR/SC |
|---|---|---|
| V1 | 3 devices online with tag + routes active | FR-015(1), SC-001 |
| V2 | pod resolves `attic.tail5d550.ts.net` to 100.x | FR-011, FR-015(2), SC-002 |
| V3 | pod-side curl to tailnet HTTP service returns 2xx | FR-015(3), SC-003 |
| V4 | laptop-to-pod-IP via subnet router succeeds | FR-015(4), SC-004 |
| V5 | failover under sustained load ≤ 30 s/reboot | FR-015(5), SC-005 |

All five MUST pass for deploy-complete declaration (FR-016, SC-009, SC-010).
