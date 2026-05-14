# Phase 0 — Research

## Decision 1 — Lab before production

**Decision**: The first executable phase is a local QEMU Talos lab created with `talosctl cluster create qemu`.

**Rationale**: Cilium datapath changes can affect all packets handled by the CNI. A local lab proves the Cilium value toggles, egress policy shape, capture method, DNS checks, and rollback commands before talos-ii is touched.

**Alternatives considered**: A direct talos-ii canary was rejected because even canary-labeled workloads cannot fully isolate Cilium agent restarts or datapath-wide behavior.

## Decision 2 — Production is a later maintenance-window canary only

**Decision**: talos-ii is tested only after Phase 0 passes, during a maintenance window, with pre-collected rollback values and AMT/emergency access confirmed.

**Rationale**: `bpf.masquerade` is a datapath-level setting. The production exercise is therefore bounded by stop-the-line gates rather than treated like an ordinary workload rollout.

**Alternatives considered**: A normal Flux rollout without an operator present was rejected because rollback may require direct Cilium/Talos intervention.

## Decision 3 — Compare `bpf.masquerade=true` and `false`

**Decision**: The experiment must run the same no-proxy-env canary matrix under the current `bpf.masquerade=true` baseline and the candidate `bpf.masquerade=false` setting.

**Rationale**: ADR `shared/0004` identified BPF masquerade bypassing host netfilter as the likely blocker. A paired comparison is needed to distinguish application behavior from datapath behavior.

**Alternatives considered**: Testing only `false` was rejected because it would not prove whether behavior changed from the production baseline.

## Decision 4 — `CiliumEgressGatewayPolicy` is part of the test

**Decision**: A canary-scoped `CiliumEgressGatewayPolicy` must be tested in lab and production canary.

**Rationale**: The current architecture uses Cilium egress-gateway semantics plus host-network sing-box. The experiment must verify whether policy-selected PodCIDR packets reach the intended gateway path and whether sing-box/netfilter observes them.

**Alternatives considered**: Raw default-route testing was rejected because it would not validate the production-intended selection mechanism.

## Decision 5 — Direct leak is failure, not partial success

**Decision**: Public egress from selected canary pods must be classified as proxied-through-sing-box, failed-closed, or leaked-direct. Leaked-direct fails the canary.

**Rationale**: The platform goal is controlled transparent egress, not merely internet reachability.

**Alternatives considered**: Accepting direct success as a fallback was rejected because it weakens the egress contract and hides DNS/geographic pollution issues.

## Decision 6 — DNS is tested separately from TCP/HTTPS

**Decision**: DNS checks are first-class validation steps for cluster-local and public names.

**Rationale**: HTTPS success can mask polluted DNS, cached answers, or resolver path drift. Cluster DNS and public DNS have different correctness criteria.

**Alternatives considered**: Inferring DNS health from `curl` was rejected as ambiguous.

## Decision 7 — dae/BPF-native proxy is lab-eligible, production-blocked

**Decision**: dae or another BPF-native proxy candidate is a separate track that may progress from documentation/source review to a local QEMU Talos lab experiment. It must not be deployed on talos-ii by this spec unless a later explicit amendment or spec accepts that risk.

**Rationale**: If Cilium SNAT runs on the BPF datapath, a BPF-native proxy may match the actual packet path better than forcing traffic back through netfilter. But dae may contend with Cilium for BPF hook ownership, routing marks, conntrack expectations, DNS interception, and fail-closed behavior. A disposable lab is the right place to test coexistence and cleanup.

**Alternatives considered**: Deploying dae directly to talos-ii was rejected because BPF hook conflicts or cleanup failures can affect node networking. Keeping dae as documentation-only was rejected because the operator explicitly wants to compare both routes while the lab exists.

## Phase 0 Lab Evidence — 2026-05-13

**Lab shape**: local Talos QEMU cluster under `/tmp/tq`, Talos `v1.12.7`, Kubernetes `v1.35.4`, Cilium `1.19.3`, two nodes (`cc-controlplane-1`, `cc-worker-1`), Cilium native routing, kube-proxy replacement, egress gateway enabled, `bpf.hostLegacyRouting=true`, lab PodCIDR `10.244.0.0/16`.

**Host prerequisites discovered**:

- NixOS lacks traditional OVMF paths; `talosctl cluster create qemu` needed temporary `/usr/share/qemu/OVMF*.fd` symlinks to the Nix store OVMF files.
- Long QEMU state paths exceed the UNIX socket 108-byte limit; short state path `/tmp/tq` was required.
- NixOS firewall blocked the Talos QEMU provisioner's DHCP/DNS traffic on `talos+` bridges; temporary input allows for UDP/67 and TCP/UDP/53 were required.

**Observed datapath behavior**:

- No-proxy Pod egress succeeded with both `bpf.masquerade=true` and `bpf.masquerade=false` when no sing-box transparent capture was installed.
- A host-network sing-box `tun` inbound with `auto_redirect=true`, `stack=system`, and direct outbound successfully captured hostNetwork traffic from the worker node. Logs showed `inbound/tun[tun-in]: inbound redirect connection from 10.5.0.3` followed by outbound direct connection.
- Ordinary PodCIDR traffic scheduled on the same worker hit sing-box's nft `prerouting` redirect counter, but did not produce sing-box connection logs and timed out. Restarting sing-box after toggling Cilium values did not change this.
- Setting `bpf.masquerade=false` did not make ordinary PodCIDR traffic enter sing-box userspace.
- A lab `CiliumEgressGatewayPolicy` selecting a control-plane pod and gatewaying through the worker made the request succeed through worker SNAT, but sing-box saw no connection and its `prerouting` redirect counter did not increase. This is a direct-leak outcome under the validation contract.
- A generic iptables `REDIRECT --to-ports 18080` rule in `nat PREROUTING` reproduced the sing-box symptom: Cilium-managed Pod traffic incremented the rule counter, but a host-network `nc -l -p 18080` listener received nothing and the Pod timed out.
- Replacing `REDIRECT` with explicit `DNAT --to-destination 10.5.0.3:18080` made the same host-network listener receive the Pod's TLS ClientHello. The Cilium lxc interface for the Pod had only IPv6 link-local addressing and no IPv4 address.
- Replacing that target with sing-box's dynamic transparent TCP listener port, for example `DNAT --to-destination 10.5.0.3:<sing-box-port>`, made sing-box log `inbound/tun[tun-in]: inbound redirect connection from 10.244.1.12` and the Pod request succeeded.
- Replacing `tun auto_redirect` with a fixed-port sing-box `redirect` inbound (`listen_port: 16000`) plus explicit node-local DNAT also worked for same-node PodCIDR traffic. sing-box logged `inbound/redirect[redirect-in]: inbound connection from 10.244.1.x` and preserved the original destination.
- The fixed-port `redirect` inbound did not make `CiliumEgressGatewayPolicy` traffic capturable. With sing-box restricted to the worker gateway node, selected control-plane Pod traffic succeeded directly through worker SNAT, produced no sing-box logs, and did not increment the worker DNAT rule. This confirms the egress-gateway path bypasses host `nat PREROUTING` from the perspective required by sing-box/netfilter capture.

**Interpretation**:

The original blocker hypothesis was too narrow. The lab still supports the high-level concern that normal PodCIDR / Cilium egress-gateway traffic is not captured by host-network sing-box, but it does not support the simpler claim that `bpf.masquerade=false` is sufficient to restore capture.

The same-node Pod failure appears specifically tied to sing-box's use of netfilter `REDIRECT` for TCP auto-redirect. Cilium endpoint veth/lxc interfaces do not carry an IPv4 address in this lab. A `REDIRECT` rule can increment in `PREROUTING` but still fail to deliver to a host socket, while an explicit DNAT to the node IPv4 and sing-box's transparent listener succeeds and preserves original-destination handling well enough for sing-box to proxy the flow.

The egress-gateway failure is separate: selected traffic arriving over the Cilium gateway path did not hit sing-box's `prerouting` redirect rule at all and leaked direct through worker SNAT. That means a DNAT workaround for same-node Pod traffic would not by itself solve the production-intended `CiliumEgressGatewayPolicy` selector model.

**Potential sing-box + Cilium implementation shapes**:

1. **Node-local transparent capture on every workload node**: run sing-box as a host-network DaemonSet on every node that may host selected workloads, expose a fixed `redirect` inbound, and install nft/iptables DNAT rules that send PodCIDR TCP/HTTPS traffic to `nodeIP:<redirect-port>`. This avoids Cilium egress gateway entirely and was proven in lab for same-node Pod traffic. Open problems: selection granularity, DNS interception, UDP/QUIC handling, private CIDR exclusions, lifecycle cleanup, and fail-closed behavior if sing-box or the DNAT rule is absent.
2. **Dedicated egress nodes plus workload scheduling**: run the node-local capture only on egress-labeled nodes and schedule workloads that need transparent egress onto those nodes. This keeps traffic same-node and avoids Cilium egress-gateway capture gaps, but it turns transparent egress into a scheduling/topology contract rather than a namespace-only policy.
3. **Cilium/BPF-side selection with sing-box as outbound engine**: keep Cilium in charge of selecting/redirecting Pod flows, but forward them into sing-box via a fixed listener or side channel. This would need a Cilium-supported redirect primitive or custom BPF/TC logic; it was not implemented in this lab.
4. **Reject netfilter sing-box for egress-gateway-selected traffic**: keep explicit proxy env or evaluate dae/BPF-native interception for the egress-gateway-style requirement.

The lab evidence favors (1) or (2) if sing-box must remain the transparent proxy. It disfavors using `CiliumEgressGatewayPolicy` as the selector feeding sing-box `auto_redirect`.

**Current recommendation from Phase 0**:

- Do not proceed to a talos-ii production canary for `bpf.masquerade=false + CiliumEgressGatewayPolicy + sing-box auto_redirect` as the planned fix.
- Keep explicit proxy env for production PodCIDR workloads until another transparent capture design is proven.
- Continue investigation only if a future netfilter-based design accepts node-local capture or workload scheduling to egress nodes. Same-node Pod capture is technically possible with explicit DNAT to a fixed sing-box `redirect` inbound, but this is not equivalent to `CiliumEgressGatewayPolicy` namespace selection.
- Keep the dae/BPF-native track open as the next likely comparative lab route, but only after the sing-box miss reason is documented as far as practical.

## Phase 0b dae/BPF-native lab evidence — 2026-05-13

**Deployment shape tested**: disposable `dae-lab` namespace in the local Talos QEMU lab, privileged host-network DaemonSet scheduled only to `cc-worker-1`, `docker.io/daeuniverse/dae:latest` (`sha256:167b552600dd8cb98b9237d44ef59b8d2123cb82d694ba293334e15f51128bcc`), config mounted at `/etc/dae/config.dae` with mode `0600`, host mounts for `/sys/fs/bpf`, `/sys/fs/cgroup`, `/sys/kernel/debug`, and `/sys/kernel/tracing`.

**dae facts confirmed**:

- `dae` requires config files to end in `.dae` and rejects config file permissions that are group-writable or world-accessible; Kubernetes ConfigMap `defaultMode: 0600` was required.
- `dae` binds Linux TC/eBPF programs. Upstream docs describe `wan_interface` for local-host programs and `lan_interface` for downstream/router traffic.
- On Talos kernel `6.18.24`, dae created a Netkit device pair `dae0 <-> dae0peer`, loaded eBPF programs/maps, and used an internal socket mark `0x100` when `so_mark_from_dae` was unset.
- Running `dae trace -4 -p tcp -P 80 --drop-only` inside the dae container crashed with a nil pointer panic, so `dae trace` was not usable as validation evidence in this image/version.

**WAN-interface test**:

- Config with `wan_interface: enp0s2`, `auto_config_kernel_parameter: false`, and `routing { dip(1.1.1.1) -> block; fallback: direct }` started successfully.
- `bpftool net` showed dae legacy `clsact` programs on `enp0s2` while Cilium had TCX programs on the same device: `tcx/ingress cil_from_netdev`, `tcx/egress cil_to_netdev`, plus dae `clsact` ingress/egress.
- A host-network curl pod on `cc-worker-1` still reached `http://1.1.1.1/` with HTTP `301`.
- An ordinary no-proxy Pod on `cc-worker-1` also reached `http://1.1.1.1/` with HTTP `301`.
- Interpretation: in this Cilium TCX lab, merely adding dae `wan_interface` programs did not produce effective fail-closed control over hostNetwork or Pod egress.

**LAN/Pod-interface test**:

- A held ordinary Pod on `cc-worker-1` had IP `10.244.1.141`; its host-side Cilium interface was `lxce2a8a6042af8`.
- Binding `lan_interface: lxce2a8a6042af8` with `auto_config_kernel_parameter: false` started but logged `send_directs on lxce2a8a6042af8 is on`, and no dae TC programs were attached to that interface.
- Enabling `auto_config_kernel_parameter: true` let dae bind the Cilium lxc interface and attach legacy `clsact` programs `dae_lan_ingress_l2` and `dae_lan_egress_l2`.
- `bpftool net` then showed Cilium TCX programs and dae legacy `clsact` programs on the same lxc interface: `tcx/ingress cil_from_container`, `tcx/egress cil_to_container`, plus dae `clsact` ingress/egress.
- The held Pod still reached both `http://1.1.1.1/` and `http://1.0.0.1/` with HTTP `301`, despite `dip(1.1.1.1) -> block`.
- Interpretation: dae can attach to a Cilium endpoint interface if allowed to mutate sysctls, but in this Cilium TCX datapath that did not make dae's block rule authoritative for Pod traffic.

**Cleanup evidence**:

- Deleted the held Pod and the entire `dae-lab` namespace.
- After deletion, `bpftool net` showed only Cilium TCX attachments; dae `clsact` programs were gone.
- `/proc/net/dev` no longer listed `dae0` or the test Pod lxc interface.
- `cilium status --brief` on the worker remained `OK`.

**Phase 0b conclusion**:

The dae spike does not provide a production-ready transparent PodCIDR egress path for the current Cilium configuration. It proved dae can run privileged on Talos, create Netkit devices, and attach TC programs, but Cilium's TCX programs remain the effective datapath owner for both node and Pod interfaces. The tested dae rules did not fail closed and therefore count as direct-leak outcomes. Pursuing dae further would require a separate design that explicitly handles Cilium TCX hook ordering/chaining, endpoint lifecycle, sysctl mutation, Kubernetes selection, DNS, and fail-closed enforcement.

## Phase 0c Cilium Local Redirect Policy lab evidence — 2026-05-14

**Deployment shape tested**: local Talos QEMU lab, Cilium `1.19.3`, temporary `localRedirectPolicies.enabled=true`, Cilium `CiliumLocalRedirectPolicy` CRD applied manually from the matching Cilium release, and a node-local Python HTTP backend pod on `cc-worker-1`.

**Setup details**:

- Helm upgrade set `localRedirectPolicies.enabled=true`; the Cilium agent DaemonSet had to be explicitly restarted before the runtime `enable-local-redirect-policy` setting became active.
- The chart upgrade did not install the `ciliumlocalredirectpolicies.cilium.io` CRD in this lab, so the CRD was applied manually from Cilium `v1.19.3`.
- The test policy matched fixed destination `1.1.1.1:80/TCP` and redirected to local backend pod `10.244.1.133:8080/TCP`.
- Cilium confirmed the datapath entry with `cilium-dbg lrp list` and `cilium-dbg service list`: `1.1.1.1:80/TCP -> 10.244.1.133:8080/TCP (LocalRedirect)`.

**Observed behavior**:

- A normal no-proxy Pod on the same worker requesting `http://1.1.1.1/` was redirected to the local backend and received the backend's test HTTP response.
- A normal no-proxy Pod requesting non-matching `http://1.0.0.1/` went direct and returned Cloudflare HTTP `301`.
- The backend attempted `SO_ORIGINAL_DST` and received `FileNotFoundError`; this redirect did not expose netfilter-style original-destination metadata to the backend.
- The policy lived in namespace `lrp-test`, but a client Pod in `default` was still redirected. This test did not find source namespace/pod selection semantics in Local Redirect Policy; the match was destination tuple oriented.
- After deleting the local backend while keeping the LRP object, `http://1.1.1.1/` from a normal Pod succeeded directly with Cloudflare HTTP `301`. That is direct leak, not fail-closed.

**Cleanup evidence**:

- Deleted `lrp-test` namespace and test backend.
- Restored `localRedirectPolicies.enabled=false`, restarted lab Cilium, and deleted the temporary LRP CRD.
- Cilium status returned `OK`; Helm values again showed `localRedirectPolicies.enabled: false`.

**Phase 0c conclusion**:

Cilium Local Redirect Policy works as a Cilium-native fixed IP:port or Service redirect to a node-local backend. It is useful for NodeLocal DNS, metadata IPs, and other fixed frontend tuples. It is not a complete transparent public egress base for this cluster because it does not express `0.0.0.0/0:443` style capture, does not provide source namespace/pod selection in the tested shape, does not expose original-destination semantics to the backend, and leaks direct when the node-local backend is absent.
