# Post-incident architecture notes — 2026-05-05

Captures the architectural reasoning that emerged during the
afternoon's wedge / Cloudflare-tunnel incident. This file is a
**parking lot** + decision log — it is not authoritative ADR
content; the decisions that survive review get folded into ADRs
shared/0002 (mesh integration modes), talos-ii/0014 (now superseded),
talos-ii/0015 (forthcoming, userspace mesh-egress), and possibly a
future shared ADR on host-OS choice.

## Final root-cause attribution (replaces earlier hypotheses)

The wedge symptom (LAN ingress to ms01-* host services hanging,
later cluster pods unable to reach Cloudflare) was **not**:

- ❌ tailscale's nft chains conflicting with Cilium (initial
  hypothesis — `--netfilter-mode=off` did not fix it)
- ❌ a peer (UCG-Pro) advertising the same /24 as ms01-*'s LAN
  (intermediate hypothesis — `--accept-routes=false` made the LAN
  ingress symptom go away but did NOT fix the cluster-egress symptom)
- ❌ cluster-egress vmess upstream blocking Cloudflare anycast
  (transient suspicion — disproven by the diagnostic curl from navi
  itself: navi → CF :443 / :7844 returns HTTP/2 200, RTT ~1 ms)
- ❌ cluster-egress URLTest selecting a broken vmess node for CF
  destinations (disproven — same outbound chain works for
  github.com / gstatic / cn.tails.beacoworks.xyz at the same time)
- ❌ TUNNEL_TRANSPORT_PROTOCOL=quic incompatibility with
  vmess-tunnel-wrap (disproven — http2 + post-quantum=false has
  the same `dial tcp 198.41.x.x:7844: i/o timeout`)

Confirmed cause is:

- ✅ `siderolabs/tailscale` extension's tailscaled (kernel mode)
  installs **`ip rule` policy routing** in the host network namespace
  via netlink — specifically priority 5210/5230/5250 (fwmark guards)
  + 5270 (`from all lookup 52`) and rule 1 (`from all lookup
  3152659062`, a tailscaled-internal table). These priorities are
  **all above** main table 32766.
- ✅ Sing-box `tun-in` (the cluster auto_redirect TPROXY entry)
  receives pod outbound packets, dispatches to a vmess outbound,
  receives reply packets from the vmess upstream, then **writes the
  reply IP packet back to the TUN device** (`172.19.0.1`).
- ✅ Kernel processes that reply packet through the new ip rule
  list. Some rule (most likely 5270 lookup 52, or rule 1) matches
  before main, sending the reply elsewhere (tailscale0 or unreachable
  table) instead of cilium_host → pod.
- ✅ **Empirical confirmation**: `talosctl service ext-tailscale
  stop` on ms01-c → cf-tunnel pod registers 4 connections to
  198.41.x.x:7844 LAX colos within 5 seconds (in QUIC mode, no
  config change needed).

The morning's `--accept-routes=false` partial fix masked the LAN
ingress symptom because table 52 ended up empty (no peer routes
accepted). But the **rule structure itself** still exists — and rule
1 / rule 5270 lookup-with-no-match → fall-through. We don't fully
understand why fall-through to main produced the wedge for cluster
egress (when there's no matching prefix in 52, kernel should hit
main eventually), but **stopping tailscaled removes the entire
ruleset and fixes it**. So the conclusion is the right one: any
host-mode kernel tailscaled is incompatible with our sing-box
auto_redirect setup, and the fix is structural — don't run kernel
tailscaled in the host netns at all.

## Architecture direction (post-incident)

### Principle 1 — host netns has exactly two privileged tenants

In our setup, host netns (where Cilium kube-proxy-replacement runs
the eBPF service mesh and where sing-box DS auto_redirect installs
nft + ip rule + a TUN device) **must not have a third party** doing
the same. Specifically: no kernel-mode WireGuard / Tailscale /
Netbird daemon on host. Anything that needs to install ip rules,
nft chains, or routing tables in the root netns is OUT.

This applies to the current talos-ii build AND any future iterations
(NixOS-as-host included — same kernel, same conflict class).

### Principle 2 — mesh client lives in a Pod, expressed as SOCKS5

The cluster's connection to a tailnet (Tailscale, Netbird, or any
successor) is operationalised as:

```
Pod  →  cilium  →  host netns  →  sing-box auto_redirect  →
        sing-box userspace dispatches per route rule  →
        SOCKS5 outbound  →  ts-userspace Pod  →
        userspace WireGuard  →  tailnet peer
```

The ts-userspace Pod runs `tailscaled --tun=userspace-networking
--socks5-server=:1055 --dns-server=:53` (or netbird-equivalent
when/if we swap). This Pod is a tailnet device with its own ephemeral
identity, joined via a dedicated OAuth client + tag (`tag:talos-ii-egress`).

The **sing-box → SOCKS5** boundary is the swap point:

| Layer | Concrete today | Swappable to |
|---|---|---|
| Mesh client process in Pod | tailscaled userspace mode | netbird (when it gains userspace), or a wireguard-go shim, or any future protocol |
| SOCKS5 endpoint | `ts-userspace.network.svc.cluster.local:1055` | unchanged |
| sing-box outbound config | `type=socks` server=that DNS | unchanged |
| Cluster CoreDNS forward for ts.net | → ts-userspace Pod :53 | unchanged (each mesh client has its DNS API) |
| Tag-based ACL | `tag:talos-ii-egress` | rename, otherwise unchanged |

### Principle 3 — desktop NixOS uses the same shape

The same decoupling applies to laptops/personal hosts running NixOS:

- Sing-box's bundled `tailscale` outbound only provides "use tailscale
  for proxying" — it lacks the operational CLI surface
  (`tailscale status / netcheck / who-am-i / ssh / set --runtime-prefs`).
- A separate tailscaled process + sing-box-via-SOCKS5 keeps the
  full operator UX while still routing apps through tailscale
  selectively.
- Future netbird migration: same agent-swap, same sing-box config.

This means **spec 005's design lands a primitive that's reusable
on desktop too** — not just a cluster-specific patch. Worth
documenting that explicitly when it lands.

### Principle 4 — what's still kernel-mode (and where)

The "no kernel mesh in our host netns" rule does NOT extend to:

- **Other tailnet members** outside the cluster (laptop, phone,
  UCG-Pro on the LAN, talos-i nodes when adopted) — they keep
  kernel-mode tailscaled. They're the ones advertising subnet
  routes (LAN access, talos-i's podCIDR/svcCIDR for cross-cluster).
- **A potential future small-VM kernel-mode tailscaled** that acts
  as the talos-ii subnet router on the LAN — a separate machine,
  not on the Talos nodes themselves. Worth considering if and when
  cross-cluster pod-IP-direct (the spec 004 D3 use case) becomes a
  hard requirement that Cilium ClusterMesh can't cover.

### Principle 5 — `/24` vs `/23` advertise overlap is not the right lever

The user's intuition (which had worked on ZeroTier) was that more
specific local prefix would win over a less-specific tailnet
advertise:

- ZeroTier installs routes in **main table** (kernel default). Within
  one table, longest-prefix-match works → /24 in main wins over /23
  in main. Intuition holds.
- Tailscale installs routes in **table 52** with a higher-priority
  ip rule (`from all lookup 52 priority 5270`). Kernel ip rule
  semantics: rules are processed in priority order; **first rule to
  produce a non-null lookup wins**. Longest-prefix-match is
  per-table, not global. So /24 in main NEVER beats /23 in
  table 52, regardless of prefix length.
- Modern WireGuard-based mesh tools (Tailscale, Netbird, Headscale)
  generally use policy routing (ip rule + dedicated table) not raw
  main-table inserts. This is the architectural distinction.
- **In our chosen userspace direction this is moot** — there's no
  kernel-side tailscale routing at all, no ip rule, no table 52 in
  the host netns. The /23 superset advertise (e.g., the LAN
  gateway's choice) becomes invisible at the kernel level on
  ms01-* nodes; only the ts-userspace Pod's internal tailscale
  state knows about it.

So the LAN-renumber idea is **independent**: change LAN to
`172.16.88.0/24` for semantic separation if useful, but don't
expect it to fix the wedge or affect routing precedence. The wedge
is fixed by removing kernel-mode tailscaled.

## Parking lot — host OS migration to NixOS (NOT a current decision)

Captured because it came up in the post-incident discussion. Move to
its own research spec when/if we want to actually evaluate.

### Why considered

- Current "build sing-box OCI image in `/etc/nixos` flake → push to
  zot → reference in cluster DS" pipeline has 5 steps; if sing-box
  ran as a host systemd unit (via NixOS module), it'd be 1
  (`nixos-rebuild switch`).
- Sops + age key reuse across `/etc/nixos` and `swarm` is partial
  (separate keys today). Unifying via NixOS host would simplify
  secret distribution.
- Talos limits host-side debugging (no shell, talosctl-API only).
  NixOS has SSH + `journalctl` + raw `nft list ruleset`.
- Spec 003's hostNetwork=true forgejo-runner workaround was needed
  partly because Talos's containerd integration has friction with
  DinD's iptables management; NixOS host could make this simpler.

### Why not now

- Talos's value props are real and real-world: opinionated k8s
  bootstrap, A/B atomic upgrades, sd-boot + LUKS+TPM2 sealing built
  in, image factory URL → bootable USB. Re-implementing each on
  NixOS is non-trivial work (lanzaboote for SecureBoot;
  nixos-installer or custom ISO via flake; manual k3s/kubeadm
  bootstrap; manual cluster-wide upgrade orchestration).
- Migration is **not in-place** — Longhorn data + workloads have to
  be drain-and-redeploy onto a fresh NixOS+k3s cluster. Significant
  effort + risk.
- The immediate pain (forgejo down, cf-tunnel CrashLoopBackOff) is
  fully solved by spec 005 without an OS swap. OS swap is a
  separate, larger architectural decision that should not be
  bundled with incident response.

### What we can share *without* the OS swap (low-cost wins)

- **SOPS double-recipient**: shared secrets (cloudflare token,
  tailscale OAuth client/secret) live in `/etc/nixos/secrets/shared/`
  with both yubikey-GPG and the swarm age key as recipients. swarm
  references them via SOPS decrypt. Eliminates copy-paste drift.
- **Sing-box OCI build pipeline**: already shared today (the
  sing-box config NixOS module compiles into the image, image
  pushed to in-cluster zot, cluster pulls). Document this as an
  intentional cross-repo coupling rather than ad-hoc.
- **Shared Renovate config**: both repos have similar bumping
  needs; one Renovate config with `repositories: []` covering both
  reduces overhead.

### What requires the OS swap (the real benefit ledger)

- Run sing-box / tailscaled / monitoring agents directly as systemd
  units; bypass the OCI build entirely.
- Custom kernel modules / patches without going through
  siderolabs/extensions.
- Direct shell + journalctl on the cluster nodes.
- Single sops/age key story.

### When to revisit

After spec 005 is stable for ≥4 weeks. If at that point the
"no host shell + slow image-build pipeline" pains are still
sharp, write a research spec (`spec 00X-host-os-evaluation`) that
includes:

- A real PoC: one spare machine running NixOS + k3s + sops-nix +
  flux + sing-box-on-host. Run it for 2 weeks under realistic load
  (forgejo runner, attic cache, etc.).
- Side-by-side ops cost analysis: time-to-deploy a sing-box config
  change, time to add a kernel module, time to debug a wedge.
- Migration path estimate: weeks of effort + risk.

Decision criterion: NixOS PoC must show **clearly more than
incremental** improvement. If it's "kind of nicer", stay on Talos.

## Action items committed today

1. ✅ ext-tailscale ESC removed from `talconfig.yaml`, applied to all
   3 nodes with `mode=auto` (no reboot). All 3 ext-tailscale services
   now in `Waiting` state — won't start on next node reboot.
2. ✅ ADR talos-ii/0014 marked **superseded same-day**. Header
   updated with detailed status.
3. ✅ This post-incident notes file authored.
4. ⏳ Spec 005 (`mesh-egress-userspace-pod`) — to be drafted next
   session. Lands the userspace tailscale Pod + sing-box SOCKS5
   outbound + CoreDNS retarget + tag/ACL migration.
5. ⏳ ADR talos-ii/0015 — accompany spec 005 to formalise the new
   architecture.
6. ⏳ (deferred) Cilium ClusterMesh research spec — for the
   cross-cluster pod-IP-direct use case if/when needed.
7. ⏳ (deferred) Host-OS evaluation research spec — see parking lot
   above.

## Appendix — diagnostic commands that helped

```bash
# Pin down tailscale-vs-sing-box conflict — before/after
talosctl --endpoints 100.<x> -n 100.<x> service ext-tailscale stop
# wait ~10s, then check the affected workload (e.g., cf-tunnel) for
# state transition

# Sing-box mixed-proxy (TCP CONNECT) bypass test — proves the vmess
# upstream path works for CF, isolating the wedge to tun-in only
kubectl -n network exec sing-box-<id> -- \
  /run/current-system/sw/bin/curl -m 8 -sIv \
  -x http://127.0.0.1:7890 https://api.cloudflare.com/

# IP rule + table dumps from sing-box host pod (privileged + hostNet)
kubectl -n network exec sing-box-<id> -- /run/current-system/sw/bin/ip rule
kubectl -n network exec sing-box-<id> -- /run/current-system/sw/bin/ip route show table 52

# Talos resource view (works via tailnet endpoint when LAN wedged)
talosctl --endpoints 100.<x> -n 100.<x> get routestatus -o yaml | \
  awk '/destination:/{d=$2}/outLinkName:/{ln=$2}/table:/{t=$2; print t " " d " " ln}'
```
