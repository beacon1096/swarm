# ADR talos-ii/0003 — Direct VLAN 87 on UDM-Pro, no OVN

**Scope:** talos-ii only. talos-i uses Harvester's existing 172.16.107.0/24 management network and won't move.
**Status:** accepted
**Date:** 2026-04-27

## Context

The previous talos-ii used OVN VPC `talos-ii-subnet` (10.20.0.0/24) for VM-to-VM networking, with the VPC carried over VXLAN tunnels between Harvester hosts. This was the only place OVN was meaningful.

OVN central crashed (see [ADR talos-ii/0001](0001-bare-metal-talos.md)). Even after recovery, OVN's value proposition for our use case was negative:
- We had **one** VPC, **one** subnet, **no** floating IPs, **no** cross-VPC routes, **no** OVN security groups, **no** OVN-IC
- All it did was put an extra encapsulation layer between Talos VMs and the host network
- It also added 4 architectural failure modes (raft death-loop, OVS cache divergence, VXLAN MTU, kube-ovn-cni init)

## Decision

Talos hosts attach **directly** to a new UDM-Pro VLAN:

- **VLAN ID:** 87 (chosen for proximity to the existing 84 management VLAN — easy to remember, easy to filter on the switch)
- **Subnet:** 172.16.87.0/24
- **Gateway:** 172.16.87.254 (UDM-Pro)
- **Trunk:** added to the `mgmt-bo` LACP bond on each MS-01

Cluster-internal networking is then Cilium's job (PodCIDR 10.44.0.0/16, ServiceCIDR 10.55.0.0/16). Cilium can use VXLAN, geneve, or eBPF native routing — that's a Cilium config decision, not exposed at the VLAN layer.

## Alternatives considered

- **Use the existing 10.20.0.0/24 from OVN** — would mean reconfiguring UDM-Pro to host that subnet directly. Doable but no benefit; the IP is just an arbitrary `RFC1918` range we picked when OVN was the boundary.
- **VLAN 88 / 89 / 100** — meh, 87 wins by adjacency to 84.
- **No VLAN at all (untagged on a port)** — requires dedicating a UDM-Pro port to the cluster, which we don't want; more flexible to keep everything trunked.

## Consequences

Positive:
- Removes OVN entirely (kube-ovn, ovn-central, kube-ovn-cni, OVS bridges, multus NAD CRDs, etc.)
- Talos VMs directly addressable from the LAN — easier debugging, easier multi-cluster reachability if we ever want it
- No more VXLAN-on-VXLAN (Cilium VXLAN previously rode on top of OVN's VXLAN at MTU 8950, costing both perf and reasoning capacity)

Negative:
- Lose **per-VPC isolation** — but we never had more than one VPC anyway
- IP range is now visible to anyone with LAN access (firewall rules at UDM control this)

## Migration cost

For the from-scratch rebuild this is "free" — there's no migration, just configure the new VLAN before installing. (If we had tried to do this on the running OVN cluster, it would have been a coordinated VM-network reattachment, which is more disruptive than the rebuild itself.)
