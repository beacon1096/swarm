# ADR shared/0005 — Investigate Cilium datapath change for PodCIDR transparent egress

**Scope:** shared — primary target talos-ii; talos-i inherits the same
egress model only after a separate adoption decision.
**Status:** proposed / investigation only. No implementation decision yet.
**Date:** 2026-05-13
**Supersedes:** —
**Related:** [shared/0004 — Cluster egress gateway](0004-cluster-egress-gateway.md),
[talos-ii/0013 — Forgejo Actions runner](../talos-ii/0013-forgejo-runner-talos-ii.md),
[talos-ii/0014 — Tailscale host extension](../talos-ii/0014-tailscale-host-extension.md)

## Context

ADR shared/0004 originally selected a transparent egress design:
`CiliumEgressGatewayPolicy` selects an egress node and host-network
sing-box captures egress with `auto_redirect`, so workloads do not need
`HTTP_PROXY` / `HTTPS_PROXY` environment variables.

That design is currently blocked for normal PodCIDR workloads. The
2026-05-05 amendment to shared/0004 identified Cilium's datapath and BPF
masquerade as the likely blocker. A 2026-05-13 QEMU Talos lab refined this:
host netfilter counters can be reached from PodCIDR traffic in some cases,
but ordinary PodCIDR traffic still does not enter sing-box userspace, and
`CiliumEgressGatewayPolicy` traffic can egress directly through the gateway
node without sing-box evidence. Therefore the blocker is not solved by only
setting `bpf.masquerade=false`; the issue is the interaction between Cilium's
Pod/eGW datapath and sing-box's host-network `auto_redirect` handoff.

The current operational model is therefore two-tier:

- `hostNetwork: true` workloads, especially forgejo-runner, can use
  sing-box transparent egress because their traffic traverses host
  netfilter.
- PodCIDR workloads, including n8n and Forgejo itself, must opt in with
  explicit proxy env pointing at `sing-box.network.svc.cluster.local:7890`.

Recent incidents confirmed the tail cost of the env contract:

- n8n Matrix notifications timed out to Cloudflare-backed
  `matrix.beaco.works` until proxy env was added.
- Forgejo mirror creation / sync timed out cloning from `github.com`
  until upper- and lower-case proxy env was added for Forgejo and its
  git/libcurl subprocesses.

This ADR opens an investigation into how to change the Cilium datapath so
PodCIDR egress can become transparent again. The operator goal is not
just convenience: relying on proxy env leaves every future workload to
prove that every binary and subprocess honors those variables. Go build
fetchers, git subprocesses, language package managers, and sandboxed
tools can ignore or fail to inherit env, turning platform egress into a
never-ending per-application patch loop. The operator accepts the risk of
a bounded Cilium datapath canary to remove that class of failures.

The forgejo-runner `hostNetwork: true` pattern is therefore considered a
workaround, not the desired general model. It is acceptable for CI/build
executors because they have unusual nested-network needs, but it should
not become the default shape for ordinary applications.

## Current Facts

talos-ii Cilium values currently include:

```yaml
routingMode: native
ipv4NativeRoutingCIDR: 10.44.0.0/16
kubeProxyReplacement: true
bpf:
  masquerade: true
  hostLegacyRouting: true
egressGateway:
  enabled: true
```

No production `CiliumEgressGatewayPolicy` resources are deployed today.
The Stage 1a PoC policy from shared/0004 was torn down.

sing-box is already deployed as a privileged host-network DaemonSet on
egress-labeled nodes. It owns `/dev/net/tun` and host netfilter rules
for `auto_redirect`. The mixed proxy listener on `:7890` is retained for
PodCIDR workloads.

The cluster has already hit two relevant failure modes:

- The 2026-05-04 sing-box rollout captured private / cluster CIDRs and
  sinkholed internal traffic until the affected node was rebooted.
- The 2026-05-05 Talos Tailscale host extension installed policy routes
  that conflicted with sing-box TUN reply traffic, breaking Cloudflare-
  bound workloads.

Any implementation must treat datapath changes as Tier 0 cluster work.

## Options To Investigate

### Option A — Keep current two-tier model

PodCIDR workloads keep explicit proxy env. `hostNetwork` remains the
escape hatch for CI / build workloads that need kernel-level capture.

Pros:

- Lowest risk.
- Already verified for n8n, Forgejo, Tailscale operator/proxies, zot,
  attic, and Flux source-controller.
- No Cilium datapath blast radius.

Cons:

- Does not remove the per-workload proxy contract.
- New workloads can still fail silently if proxy env is forgotten.
- Tools that ignore env still require workload-specific fixes.

### Option B — Disable Cilium BPF masquerade cluster-wide

Set `bpf.masquerade: false` and rely on the legacy masquerade path so
PodCIDR egress can traverse host netfilter. Then re-test
`CiliumEgressGatewayPolicy + sing-box auto_redirect` for namespace- or
pod-selected transparent egress.

Pros:

- Directly targets the known blocker from shared/0004.
- Keeps sing-box's existing netfilter/TUN implementation as the capture
  point.
- Could restore the original per-namespace transparent egress design.
- Risk is acceptable for a controlled canary because the current env
  contract has proven structurally incomplete for tools that do not honor
  or inherit proxy variables.

Cons:

- Cluster-wide change; no obvious namespace-scoped version of this knob.
- May affect Cilium native routing, egress gateway behavior,
  kube-proxy-replacement assumptions, and pod-to-external NAT.
- Requires a maintenance window and explicit rollback procedure.

Phase 0 lab result, 2026-05-13:

- No-proxy Pod egress worked with both `bpf.masquerade=true` and `false` when no transparent capture was active.
- A minimal host-network sing-box `tun` inbound with `auto_redirect=true` captured hostNetwork traffic and logged `inbound/tun[tun-in]` connections.
- Ordinary PodCIDR traffic hit sing-box nft `prerouting` redirect counters but did not appear in sing-box logs and timed out.
- `bpf.masquerade=false` did not change that ordinary PodCIDR result.
- A lab `CiliumEgressGatewayPolicy` routed selected control-plane Pod traffic through the worker egress node and the request succeeded, but sing-box had no logs and no redirect-counter increment for that flow. This classifies as direct leak.
- A generic `REDIRECT --to-ports 18080` reproduced the ordinary PodCIDR miss without sing-box: counters increased, but a host-network listener received nothing.
- Explicit `DNAT --to-destination <node-ip>:18080` delivered the same Pod flow to the listener. Explicit `DNAT --to-destination <node-ip>:<sing-box-transparent-port>` delivered the flow to sing-box; sing-box logged the Pod source IP and proxied the request successfully.
- The likely same-node miss reason is that Cilium lxc endpoint interfaces have no IPv4 address, so PREROUTING `REDIRECT` can match but cannot deliver the packet to the host socket as sing-box expects. Explicit DNAT to the node IPv4 avoids that particular failure.
- A fixed-port sing-box `redirect` inbound plus explicit DNAT to `node-ip:16000` also captured same-node PodCIDR traffic and preserved the original destination.
- The same fixed-port DNAT did not capture `CiliumEgressGatewayPolicy` traffic arriving at the worker gateway node; selected traffic succeeded as direct worker SNAT without sing-box evidence and without DNAT counter increments once sing-box was restricted to the gateway node.

Conclusion: Option B, as originally framed, is not production-ready and should not proceed to talos-ii canary without a new mechanism that proves selected PodCIDR traffic enters sing-box userspace or fails closed. A future netfilter design would need something closer to explicit DNAT/TPROXY to a known node-local transparent listener, plus a separate answer for Cilium egress-gateway traffic that currently bypasses sing-box's PREROUTING rule entirely.

The viable sing-box+Cilium shape from lab is therefore **node-local capture**, not **Cilium egress-gateway feeding sing-box**. That could mean sing-box plus DNAT rules on every workload node, or workload scheduling onto egress nodes where local capture is installed. Both are materially different designs from shared/0004 and need a new rollout spec if pursued.

### Option C — Intercept on the BPF datapath instead of netfilter

Keep BPF masquerade and move the transparent capture point to where the
packets actually flow: Cilium / TC / eBPF. This could mean a Cilium-native
feature, local redirect policy, a Cilium L7 proxy mode, or a BPF-native
transparent proxy such as `dae`.

Pros:

- Architecturally matches current datapath.
- Avoids changing cluster-wide masquerade behavior.

Cons:

- Highest complexity and least precedent in this repo.
- Cilium L7 proxy is not equivalent to transparent L3/TUN capture.
- BPF hook ownership / chaining with Cilium must be proven. Cilium already
  attaches programs to the relevant datapath; another BPF proxy may
  conflict, override, or depend on hook ordering.
- Kubernetes semantics must be rebuilt or verified: namespace/pod
  selection, private CIDR exclusions, fail-closed behavior, DNS handling,
  and GitOps lifecycle.

#### Option C1 — Evaluate `dae` as a BPF-native proxy candidate

`dae` is worth a separate research spike because it is designed around
eBPF-based transparent proxying. If Cilium SNAT runs on BPF, a proxy that
also intercepts on BPF/TC may align better with the actual packet path
than trying to force packets back through netfilter for sing-box.

Questions a `dae` spike must answer before any cluster deployment:

- Can `dae` coexist with Cilium's TC/eBPF programs on the same Talos
  nodes without replacing or breaking Cilium hooks?
- Does it support a DaemonSet shape on Talos with a safe cleanup path for
  BPF programs and maps?
- Can it exclude PodCIDR, ServiceCIDR, LAN, loopback, link-local, and
  tailnet ranges as strictly as sing-box must?
- Can it express or integrate with Kubernetes namespace / pod selection,
  or would it be node-global?
- Can it provide fail-closed semantics for selected public egress, or only
  best-effort transparent routing?
- Can it replace sing-box's current outbound features, or would it only be
  a capture layer forwarding into sing-box?
- How does it handle DNS, especially public DNS poisoning for GitHub,
  registries, Matrix, and `cache.nixos.org`?

This option should not be treated as automatically safer than Option B.
Cilium's BPF datapath is the standard Cilium route; adding a second BPF
datapath owner may be more complex than disabling only Cilium's BPF
masquerade while keeping the rest of Cilium's BPF features.

Phase 0b dae lab result, 2026-05-13:

- A privileged dae DaemonSet could run on the Talos QEMU worker, create a
  Netkit `dae0` device pair, and attach TC programs.
- dae required ConfigMap-backed config mode `0600`; default Kubernetes
  ConfigMap permissions were rejected as too open.
- With `wan_interface: enp0s2` and `dip(1.1.1.1) -> block`, both a
  host-network curl pod and an ordinary Pod still reached `1.1.1.1`
  directly.
- With `lan_interface` bound to the held Pod's Cilium `lxc...` interface,
  dae first refused to bind until `send_redirects` was disabled. Enabling
  `auto_config_kernel_parameter` allowed attachment, but the Pod still
  reached the blocked public IP directly.
- `bpftool net` showed the relevant conflict shape: Cilium owned the same
  node and endpoint interfaces through TCX programs, while dae attached
  legacy `clsact` programs alongside them. In this lab, dae's policy did
  not become authoritative for Cilium Pod traffic.
- `dae trace` crashed with a nil pointer panic in this image/version, so it
  was not usable as observability evidence.
- Cleanup by deleting the lab namespace removed dae `clsact` attachments and
  `dae0`; Cilium remained healthy.

Conclusion: dae is not currently a proven safer route for talos-ii. It may
still be technically interesting, but production use would need a new design
that explicitly solves Cilium TCX hook ordering/chaining, endpoint lifecycle,
sysctl mutation, Kubernetes selection, DNS, and fail-closed enforcement.

#### Option C2 — Evaluate Cilium Local Redirect Policy

Cilium Local Redirect Policy was tested as a Cilium-native redirect primitive
because it can steer pod traffic for a fixed frontend tuple to a node-local
backend pod through Cilium's own service datapath.

Phase 0c Local Redirect Policy lab result, 2026-05-14:

- Enabling LRP required `localRedirectPolicies.enabled=true`, a Cilium agent
  restart, and manual installation of the matching Cilium `CiliumLocalRedirectPolicy`
  CRD in the lab.
- A policy for fixed destination `1.1.1.1:80/TCP` created a Cilium
  `LocalRedirect` service entry to a backend pod on the same worker.
- A normal no-proxy Pod requesting `http://1.1.1.1/` was redirected to the
  local backend and received the backend's response.
- A non-matching destination, `http://1.0.0.1/`, went direct as expected.
- The backend could not read `SO_ORIGINAL_DST`; this did not behave like a
  netfilter transparent proxy handoff that exposes the original destination.
- The policy was destination-oriented. A client in `default` was redirected
  by a policy living in `lrp-test`; this test did not find namespace/pod
  source selection semantics suitable for opt-in transparent egress.
- When the backend was removed, the matched `1.1.1.1:80` request succeeded
  directly. This is direct leak, not fail-closed.

Conclusion: Local Redirect Policy is useful for fixed frontends such as
NodeLocal DNS, metadata IPs, or specific service/IP tuples. It is not a
complete transparent public egress base because it does not express broad
`0.0.0.0/0:443` capture, does not provide the required source selection in
the tested shape, does not expose original-destination semantics to the
backend, and leaks direct when the local backend is absent.

### Option D — Per-pod sidecar / init netns capture

Inject a sidecar or initContainer into selected pods to install TPROXY / TUN
rules inside the pod network namespace.

Pros:

- Can be workload-scoped.
- Does not require changing Cilium cluster datapath.

Cons:

- Re-opens the sidecar design rejected in shared/0004.
- Requires `NET_ADMIN`, lifecycle cleanup, and webhook or per-workload
  boilerplate.
- Does not solve nested DinD as cleanly as hostNetwork.

## Decision Questions

This ADR is not ready to choose an implementation. The next discussion
must decide at least:

- How to bound the accepted Cilium datapath risk during a canary, not
  whether the risk is categorically worth taking. The motivation is to
  remove an env-dependence class that repeatedly fails for subprocesses
  and build tools.
- Is fail-closed required for selected namespaces if sing-box is down,
  or is direct egress leakage acceptable during failure?
- Should transparent egress be opt-in by namespace, pod label, or all
  non-platform workloads?
- If Option B is pursued, do we keep `CiliumEgressGatewayPolicy` as the
  selection mechanism, and what are the initial gateway nodes / egress
  IPs / interfaces?
- If Option C is pursued, is `dae` or another BPF-native proxy mature
  enough to run alongside Cilium, and does it reduce risk compared with
  Option B?
- What private ranges are non-negotiable capture exclusions?
- Public DNS must be included in the design. Domestic resolvers can
  poison registry / GitHub / cache domains, so a transparent egress design
  that still lets pods resolve public names directly is incomplete.
- Which workloads keep env during burn-in, and when to remove env after a
  successful transparent path. Long term, production should not depend on
  proxy env for ordinary PodCIDR egress.

## Fail-Closed vs Leak-Open

For this cluster, the preferred target is **fail-closed** for selected
transparent-egress workloads: if a workload is selected for transparent
public egress and sing-box is unavailable or not capturing, public egress
should fail instead of falling back to direct internet access.

Reasons:

- Direct egress is known unreliable from this site and can fail with GFW
  timeout / DNS poisoning symptoms.
- A direct fallback hides platform regressions. The application appears
  to work sometimes, but sing-box is no longer enforcing the intended
  routing policy.
- Some destinations may have privacy or policy expectations around
  routing through the proxy chain rather than the WAN directly.

The canary must therefore distinguish three outcomes for each public
destination:

- **proxied success**: request succeeds and sing-box evidence shows
  capture. This is the only successful transparent-egress outcome.
- **fail-closed**: request fails when sing-box is unavailable or not
  selected. This is acceptable during failure testing.
- **direct leak**: request succeeds but sing-box has no evidence of
  capture. This is a canary failure, even if the application-level request
  succeeded.

How fail-closed might be enforced depends on the chosen datapath:

- With `CiliumEgressGatewayPolicy`, selected pod/namespace egress can be
  steered to egress nodes. If the policy or gateway path cannot guarantee
  failure instead of direct fallback, the design needs an additional
  NetworkPolicy / Cilium policy layer that denies public egress except via
  the intended gateway path.
- With broad host netfilter capture, fail-closed may require explicit
  drop rules for selected source CIDRs when sing-box is not active. This
  is risky because stale drop/capture rules can cause the same class of
  outage seen on 2026-05-04, so lifecycle cleanup must be proven.
- During canary, leak detection is mandatory before production fail-closed
  enforcement. A leak means the datapath is not under control.

## Selection Mechanism: CiliumEgressGatewayPolicy Or Something Else

The desired production shape remains **opt-in**, not cluster-wide capture
of every packet. The likely selector is still `CiliumEgressGatewayPolicy`,
but only if disabling BPF masquerade makes its gateway path observable by
sing-box netfilter capture.

What `CiliumEgressGatewayPolicy` gives us:

- Namespace and pod-label selection for who uses the egress gateway.
- A way to choose egress node(s), egress IP, and outbound interface.
- A failover model that is native to Cilium rather than hand-written
  per-node routing.
- A clear object to audit in GitOps.

What it does **not** give us by itself:

- It does not redirect to a local sing-box port.
- It does not prove packets traverse host netfilter.
- It does not automatically provide fail-closed semantics unless the
  gateway datapath blackholes rather than falls back direct.

The canary must answer these concrete questions before selecting it for
production:

- After `bpf.masquerade: false`, does a no-proxy PodCIDR packet selected
  by `CiliumEgressGatewayPolicy` appear in sing-box `auto_redirect` logs?
- Does the policy need explicit `egressIP` and `interface: bond0.87` for
  deterministic behavior on talos-ii?
- What happens when the selected gateway node has no healthy sing-box pod?
  Direct leak, blackhole, or failover?
- Can the policy be scoped to a canary namespace first, then expanded to
  selected namespaces without touching platform namespaces like
  `kube-system`, `network`, `flux-system`, and `observability`?
- Does Cilium support the exact HA semantics we need on the current
  3-control-plane-node topology, or do we need one egress node first and
  multi-node later?

If `CiliumEgressGatewayPolicy` still bypasses sing-box after the datapath
change, then Option B does not restore shared/0004's original design and
the ADR should either reject production rollout or move to a different
intercept mechanism.

## Is Cilium BPF The Standard Path?

Yes. In this cluster, Cilium BPF is not an exotic deviation; it is the
normal operating model for modern Cilium features. `kubeProxyReplacement`,
native routing, service load-balancing, policy, and BPF masquerade all
belong to the Cilium datapath model.

Disabling `bpf.masquerade` would not mean "stop using Cilium BPF". It
would mean only that SNAT / masquerade moves away from the BPF masquerade
path, while other Cilium BPF functions may remain active. That narrower
change is why Option B is still plausible as a canary: it targets the
specific blocker from shared/0004 without abandoning Cilium's broader
BPF-based CNI model.

The trade-off is that BPF masquerade is itself a standard Cilium feature.
Turning it off may reduce performance or change NAT/egress-gateway
behavior. The canary must therefore compare the risk of changing one
Cilium datapath knob against the risk of introducing an additional
BPF-native proxy such as `dae`.

## Non-Negotiable Exclusions

Any transparent capture design must exclude at least:

- Pod CIDR: `10.44.0.0/16`
- Service CIDR: `10.55.0.0/16`
- LAN / VLAN ranges: `172.16.0.0/12`
- Loopback: `127.0.0.0/8`
- Link-local: `169.254.0.0/16`
- Tailscale CGNAT: `100.64.0.0/10`
- Forgejo-runner DinD bridge: `10.250.0.0/16`

The 2026-05-04 outage proves that letting private / cluster traffic enter
sing-box userspace can break CoreDNS, Service traffic, and control-plane
recovery.

## Verification Plan For A Future Spec

Before touching production workloads:

1. Snapshot current Cilium config, node routes, ip rules, and nftables
   state.
2. Create a temporary canary namespace and a no-proxy-env test pod.
3. Test direct failure today for known blocked endpoints:
   `https://github.com/`, `https://matrix.beaco.works/_matrix/client/versions`,
   and `https://cache.nixos.org/nix-cache-info`.
4. Apply the candidate datapath change and only then add a canary
   `CiliumEgressGatewayPolicy` if the option uses Cilium egress gateway.
5. Verify the canary pod reaches blocked endpoints with no proxy env and
   that sing-box logs show capture.
6. Verify internal traffic is not captured: CoreDNS, Service DNS names,
   pod-to-pod, LAN, and tailnet ranges.
7. Verify public DNS behavior explicitly. Public domains used for GitHub,
   registries, Matrix, and `cache.nixos.org` must not depend on domestic
   polluted DNS answers.
8. Verify failure behavior by stopping or pausing sing-box on the canary
   path and checking for fail-closed vs leak.
9. Re-test real workload classes before removing env from any of them:
   n8n Matrix, Forgejo mirror sync, Forgejo runner Nix/Go fetches, Flux
   source-controller fetches, Tailscale operator/proxy registration, zot
   upstream registry sync.

Rollback must be defined before rollout. At minimum it includes reverting
Cilium Helm values, deleting test egress policies, restoring proxy-env
workloads as the authority, and rebooting any node with orphaned sing-box
netfilter / ip-rule state.

## Likely Files Touched By Implementation

- `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`
- `kubernetes/apps/network/sing-box/app/helmrelease.yaml`
- `kubernetes/apps/network/sing-box/app/secret.sops.yaml`
- New `CiliumEgressGatewayPolicy` manifests if Option B keeps egress
  gateway selection.
- `kubernetes/apps/kube-system/coredns/app/helmrelease.yaml` if DNS is
  changed.
- Workloads currently using proxy env, only after burn-in:
  `development/n8n`, `development/forgejo`, `nix/attic`, `registry/zot`,
  `network/tailscale`, `flux-system/flux-instance`, and any future
  PodCIDR egress consumers.

## Spec-Kit Next Step

This ADR should not be implemented directly. If the operator wants to
continue past investigation, open a new spec-kit feature for a canary-only
Cilium datapath experiment. The current `.specify/feature.json` still
points at `specs/004-talos-ii-mesh-implementation`, which is not the
right implementation vehicle for this egress/datapath work.

Expected spec phases:

1. `/specify` the canary experiment and explicit rollback gates.
2. `/plan` the exact Cilium values, canary namespace, policies, and
   observability commands.
3. `/tasks` split preflight, canary rollout, validation, rollback drill,
   and production decision gate.
4. Implementation only after the ADR status changes from investigation
   to accepted.
