# talos-ii bootstrap — lessons from the trenches

What went wrong on day 1 (2026-04-27 → 2026-04-28) bringing up the
3-node bare-metal Talos cluster, and how we worked around each issue.
Written down because (a) ms01-b/c will need the same fixes if we ever
rebuild and (b) talos-i adoption will hit a different but overlapping
list. Keep in mind: **once sing-box runs as a cluster workload, most
of the "China network" workarounds in this doc become unnecessary**
because the proxy stops being a single point on a separate host.

For each item: what we saw, root cause, fix, status (one-time vs
persistent), and whether in-cluster sing-box would supersede it.

---

## A. Hardware / BIOS quirks (MS-01 specific)

These are persistent — they hold for any future MS-01 install.

### A1. PCIe ASPM in two BIOS groups
- **Saw:** NVMe `nvme0n1` randomly disappears mid-install
  (`volume STATE phase failed / no such attributes system_disk`),
  single-node etcd reports 14 s `apply request took too long`.
- **Why:** MS-01 BIOS has independent ASPM toggles for SA-PCIE
  (4 TB NVMe + X710 + user PCIe slot) and PCH-PCIE (i226 + slow SSDs
  + WiFi). Disabling only one group leaves the other still aggressive.
- **Fix:** disable ASPM and L1 substates in **both** groups.
- **Documented:** [ADR talos-ii/0006](../decisions/talos-ii/0006-disable-pcie-aspm.md)
- **Persistent:** yes — survives reinstalls, but BIOS reset undoes it.

### A2. Secure Boot setup-mode flow needs a specific order
- **Saw:** `failed to enroll secureboot keys`, install loops to
  unsigned boot.
- **Why:** AMI BIOS doesn't persist Setup-Mode across reboots — you
  must clear keys then boot the Talos ISO **without rebooting in
  between** (so the same firmware session goes straight to
  sd-boot's `Install Keys`).
- **Fix:** documented procedure.
- **Documented:** [ADR talos-ii/0005, "MS-01 (AMI BIOS) actual procedure"](../decisions/talos-ii/0005-secure-boot.md#ms-01-ami-bios-actual-procedure--verified-2026-04-28)
- **Persistent:** yes — needed for any reinstall.

### A3. Power button mechanical tolerance with rack mounting
- **Saw:** ms01-c got accidentally power-cycled twice when handling
  USB cables / repositioning, because the rack pushed the chassis
  against something that brushed the power button.
- **Why:** physical tolerance between the chassis recess and the
  rack rails on this specific MS-01.
- **Fix (long-term):** padding shim. (Not done yet — TODO.)
- **Persistent:** yes — physical.

### A4. CPU fan plug fit
- **Saw:** ms01-a kept shutting down mid-install due to thermal.
- **Why:** the CPU fan power plug had worked loose; fan was barely
  spinning.
- **Fix:** reseat plug, set fan curve to manual-max in BIOS during
  install just in case.
- **Persistent:** one-time. Worth checking on every chassis on any
  future reinstall though.

---

## B. Networking gotchas (UDR Pro / USW)

### B1. VLAN 87 not trunked from USW LAG to UDR Pro `br87`
- **Saw:** ms01-a installs OK, comes up at .87.201, but ICMP from
  anywhere outside VLAN 87 fails. UDR's `bridge link` shows br87
  has only one member: `switch0.87`. No `eth10.87`.
- **Why:** Unifi UI's "Tagged VLAN Management" on the USW-Aggregation
  uplink to UDR was a Custom list that didn't include VLAN 87. So
  the LAG accepts/sends 87-tagged frames at the access-port level
  (members are ms01-a/b/c), but the USW→UDR uplink trunk wasn't
  carrying 87, and VLAN 87's L3 br87 on UDR was orphaned in the
  internal switch.
- **Fix:** add VLAN 87 to the tagged list on **both** the USW
  uplink port *and* the UDR's corresponding LAN port. After the
  fix, `bridge link` on UDR shows `eth10.87` joined to `br87`,
  ARP for .87.x works, traffic flows.
- **Persistent:** yes — but only matters at network setup time.
  If we reset Unifi config or migrate switches, recheck.

### B2. UDR Tailscale subnet route advertisement
- **Saw:** Couldn't reach .87.x from the laptop directly via
  Tailscale until the UDR node advertised + we approved the
  172.16.87.0/24 subnet route.
- **Fix:** `tailscale set --advertise-routes=...,172.16.87.0/24`
  on UDR + approve in tailnet admin.
- **Persistent:** yes — auto-advertise in Unifi UI doesn't always
  catch new VLANs.

### B3. USW LAG Native VLAN should NOT be the cluster VLAN
- **Saw:** Initial UDR LAG had Native VLAN = "Phylanx-01 Talos-ii (87)"
  with "Allow All" tagged. Talos sends 802.1Q-tagged frames, switch
  saw both untagged-falls-into-87 and tagged-87, behavior brittle.
- **Fix:** Native = `Default`, Tagged = Custom + 87 (or Allow All
  including 87). LACPDUs go to default, VLAN 87 frames go tagged
  through.
- **Persistent:** yes.

---

## C. China-network workarounds (most go away with in-cluster sing-box)

### C1. `cluster.yaml` DNS / NTP defaults unreachable
- **Saw:** Talos install boot console: `1.1.1.1:53 io timeout`,
  Cloudflare NTP times out.
- **Fix:** in `cluster.yaml`:
  - `node_dns_servers: ["172.16.87.254"]` (UDR's VLAN 87 gateway,
    forwards to AliDNS upstream).
  - `node_ntp_servers: ["118.31.3.89", "203.107.6.88"]` (the two
    distinct IPv4s ntp{1..7}.aliyun.com collapse to; cluster-template
    schema requires IPv4 not hostnames).
- **Documented:** comments in `cluster.yaml`.
- **Persistent until:** in-cluster sing-box exposes a tun/SOCKS that
  pods use — but **node-level** DNS/NTP runs before pods, so even
  with in-cluster sing-box, *node-level* DNS/NTP probably still
  needs to be CN-reachable. Keep this fix.

### C2. cert-manager default DoH (`1.1.1.1` / `1.0.0.1`) unreachable
- **Saw:** ACME DNS-01 challenge hangs forever:
  `Post "https://1.0.0.1:443/dns-query": context deadline exceeded`.
- **Fix:** swap to AliDNS DoH in
  `templates/config/kubernetes/apps/cert-manager/cert-manager/app/helmrelease.yaml.j2`:
  ```yaml
  dns01RecursiveNameservers: https://223.5.5.5/dns-query,https://223.6.6.6/dns-query
  ```
- **Documented:** commit `71b5597`.
- **Persistent until:** in-cluster sing-box (cert-manager pod could
  route 1.1.1.1 through the proxy). Even then, AliDNS direct is
  faster + simpler — keep the fix.

### C3. Talos installer image fetch from `factory.talos.dev` is slow
- **Saw:** Multiple Talos install attempts timed out pulling the
  ~250 MB OCI installer image. Direct WAN got HTTP/2 stream RST
  from the GFW. Through sing-box on the proxy host, ~0.7–4 Mbps
  (variable), but 8+ minutes for one image meant install time-window
  ran out before write-to-disk completed.
- **Fix (durable):** local pull-through OCI mirror.
  - `zot v2.1.5` running on proxy host (172.16.80.240:5000), HTTP.
  - Pre-warmed via `skopeo copy --override-arch amd64
    factory.talos.dev/installer-secureboot/<schematic>:v1.12.7
    172.16.80.240:5000/...`. (Multi-arch full pull was slower; one
    arch is enough for amd64-only MS-01 fleet.)
  - In Talos: `machine.registries.mirrors.factory.talos.dev:
    endpoints: [http://172.16.80.240:5000]`
    (`templates/config/talos/patches/global/machine-registries.yaml.j2`).
- **Net effect:** ms01-b/c's install pulled the image at LAN speed
  (seconds vs minutes), no thermal pressure on NVMe, no GFW issues.
- **Persistent until:** in-cluster mirror replaces it. Even so, a
  pull-through cache at the LAN edge is generally faster than
  in-cluster (no kube-apiserver hop). Keep the proxy-host mirror.

### C4. zot's `onDemand: true` blocks GETs while syncing
- **Saw:** After skopeo finished, GET `/manifests/v1.12.7` hung
  for 10 s. zot logs showed it triggered a fresh on-demand sync
  on every GET because local-digest (amd64-single) ≠ remote-digest
  (multi-arch index), then failed back to local after timeout.
- **Fix:** `extensions.sync` removed entirely from
  `/etc/talos-mirror/zot.json`. zot now serves only what was
  pre-pushed via skopeo. Re-run `skopeo copy` whenever the
  schematic / Talos version changes.
- **Persistent:** keeps the mirror predictable.

### C5. Talos install can't add kernel args under Secure Boot (UKI)
- **Saw:** Tried `machine.install.extraKernelArgs: [pcie_aspm=off]`,
  talhelper rejected:
  `extraKernelArgs and grubUseUKICmdline can't be used together`.
- **Why:** Secure Boot + UKI bakes kernel cmdline into the signed
  unified kernel image at schematic build time. Adding args at
  apply-time would break the signature.
- **Workaround:** rebuild schematic at factory.talos.dev with the
  arg baked in (one-way schematic ID change — not worth doing for
  one arg). For now, BIOS is the sole enforcement point for ASPM.
- **Documented:** [ADR talos-ii/0006](../decisions/talos-ii/0006-disable-pcie-aspm.md).

### C6. sing-box outbound DNS got stuck once
- **Saw:** sing-box reported `lookup docs-cdn.beacoworks.xyz:
  context deadline exceeded` on every attempt, all outbounds
  unreachable, even though system-level `getent ahosts` resolved
  the same domain fine.
- **Why:** sing-box's internal resolver state machine got wedged.
  Best guess: a UDP DNS reply got dropped during a transient
  connection issue, the resolver's pending-request queue never
  got flushed.
- **Fix:** `systemctl restart sing-box`.
- **Persistent until:** sing-box has a robust internal DNS
  retry / circuit-breaker. Document it as an operator action:
  whenever the proxy "looks like it should work but doesn't",
  restart sing-box first.

### C7. UDR Pro lost power; services on .80.240 came back fine
- **Saw:** Mid-bootstrap, the proxy host's power dropped (likely
  related to the same rack/cabling as the MS-01 power-button issue).
- **Outcome:** all systemd services (`sing-box`, `talos-mirror`,
  `bird`) came back automatically. zot's mirror disk didn't lose
  cache. Cluster paused until it came back, then resumed.
- **Persistent:** keep services systemd-enabled. (They are.)

---

## D. Talos / cluster-template gotchas (not CN-specific)

### D1. talhelper rejects RFC 6902 JSON patches on multi-doc machineconfig
- **Saw:** `JSON6902 patches are not supported for multi-document
  machine configuration` when we used `op: replace` per-node patches.
- **Why:** Talos v1.12 splits machineconfig into multiple v1alpha1
  documents (HostnameConfig / BondConfig / VLANConfig / etc.).
  RFC 6902 doesn't know which doc to operate on.
- **Fix:** override the talconfig template directly
  (`templates/overrides/talos/talconfig.yaml.j2`) — emit our LACP
  bond + VLAN inline at generator time instead of patching.
- **Documented:** commit `f4b5031`.

### D2. talhelper drops `vlans[].vip` when bond config is present
- **Saw:** machineconfig was missing the kube-apiserver VIP after
  talhelper translated bond + VLAN into modular configs.
- **Fix:** add a controller-only patch with the legacy
  `machine.network.interfaces[].vlans[].vip:` form. Talos honors
  both legacy and modular forms; the legacy form survives talhelper's
  translation.
- **Documented:** `templates/config/talos/patches/controller/vip.yaml.j2`.

### D3. Bond `deviceSelectors` triggers modular form, hides issues
- **Saw:** When we used `bond.deviceSelectors: - driver: i40e`,
  talhelper produced a `LinkAliasConfig` doc and translation got
  wonky. Switching to explicit `bond.interfaces: [enp2s0f0np0,
  enp2s0f1np1]` kept talhelper on a well-tested path.
- **Documented:** `templates/overrides/talos/talconfig.yaml.j2`
  comment.
- **Persistent:** keep explicit interface names. They're the same
  on every MS-01 X710 (consistent kernel naming).

### D4. cluster-template's `machine.install.wipe` defaults to false
- **Saw:** Repeated install attempts left partial state on NVMe;
  on next boot Talos tried to use the previous (failed) STATE
  partition with mismatched TPM PCRs, broke.
- **Fix in our case:** cold reboot from USB ISO solved it (fresh
  maintenance mode wipes nothing but boots from ISO instead of
  from the partial NVMe install). We didn't need `wipe: true`
  in the end — but keep it in mind if reinstalls become routine.

### D5. Longhorn driver-deployer crashloops without `csi.kubeletRootDir`
- **Saw:** `longhorn-driver-deployer` in `CrashLoopBackOff`,
  CSIDriver never registered, all PVCs stuck Pending.
  Manager pod logs:
  > `failed to get arg root-dir. Need to specify "--kubelet-root-dir"
  > in your Longhorn deployment yaml.: failed to get cmdline of proc
  > kubelet: failed to deploy proc cmdline detection pod
  > discover-proc-kubelet-cmdline: object is being deleted`
- **Why:** Longhorn auto-detects the kubelet's `--root-dir` flag by
  spawning a privileged pod that reads `/proc/<kubelet>/cmdline`.
  Talos isolates that path (the kubelet doesn't sit in a pid we can
  introspect cleanly). The discover pod fires in a loop and the
  deployer keeps trying to recreate it before the previous one has
  finished terminating.
- **Fix:** in the chart values, hard-code
  `csi.kubeletRootDir: /var/lib/kubelet` (Talos's kubelet state
  directory). Documented in our HelmRelease + ADR talos-ii/0002.
- **Persistent:** yes for any Talos+Longhorn install. Apply the same
  fix on talos-i if Longhorn ever lands there directly (vs the
  Harvester wrapper).

### D6. cert-manager Order in `errored` state needs manual nudge
- **Saw:** Both DNS-01 challenges became `valid` but the Order
  errored with `Failed to finalize Order: 404 Certificate not found`.
  cert-manager's default backoff is long; the cluster sat unable
  to issue the cert.
- **Fix:** `kubectl annotate -n network kustomization envoy-gateway
  reconcile.fluxcd.io/requestedAt=$(date +%s) --overwrite` after
  deleting the Certificate / CertificateRequest. Flux re-creates
  the Certificate from git, cert-manager picks up cached LE authzs,
  and the new Order finalizes within seconds.
- **Persistent until:** rare. If we see `Failed to finalize Order`
  again in the future, this is the playbook.

---

## What gets simpler once sing-box runs in-cluster

We're planning to deploy sing-box in talos-ii (probably as a DaemonSet
or specific-node workload) so the cluster has its own egress proxy and
doesn't rely on a separate ARM host. Once that exists:

| current friction | in-cluster sing-box helps? |
|---|---|
| C1 node DNS/NTP — Cloudflare unreachable | **No** — node-level config runs pre-CNI |
| C2 cert-manager DoH | **Maybe** — could route 1.1.1.1 through the in-cluster proxy via NetworkPolicy egress, but AliDNS direct stays simpler |
| C3 talos installer image | **No** — install runs pre-CNI; LAN-edge mirror still beats in-cluster proxy for that traffic |
| C4 zot onDemand quirk | **No** — independent issue |
| C6 single sing-box outbound stall | **Yes** — multiple sing-box pods + LB → no SPOF |
| All other in-cluster image pulls (helm charts, ghcr.io etc.) | **Yes** — Spegel + in-cluster sing-box covers it |

Net: ~half the CN-specific items become operational rather than
load-bearing. The pre-CNI ones (DNS / NTP / installer) still need
the host-level proxy.

---

## Last verified

2026-04-28 — first end-to-end success: `https://echo.beaco.works/`
returned HTTP 200 via Cloudflare Tunnel → envoy-external → echo Pod.
3-node etcd healthy, all 13 HelmReleases True.
