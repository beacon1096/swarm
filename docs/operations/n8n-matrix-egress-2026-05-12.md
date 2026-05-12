# Incident 2026-05-12 — n8n Matrix notification egress timeout

`Nix-Fleet CI` Matrix notifications failed from n8n after the talos-ii
restore / upgrade work. The failure was an outbound network timeout to
`matrix.beaco.works`, not a Matrix credential or room-permission problem.

This note records the symptom, diagnosis, and the decision to keep n8n on
the PodCIDR proxy-env contract documented in
[`sing-box-egress.md`](sing-box-egress.md) and ADR
[`shared/0004`](../decisions/shared/0004-cluster-egress-gateway.md).

## Timeline (UTC)

| time | event |
|------|-------|
| 06:58 | n8n execution `309` of workflow `Nix-Fleet CI` failed at node `Create a message`. |
| 07:01 | Error captured: `connect ETIMEDOUT 172.67.173.168:443` for `matrix.beaco.works` via Cloudflare. |
| 11:30 | Confirmed direct egress from the `development` namespace to `https://matrix.beaco.works/_matrix/client/versions` times out. |
| 11:30 | Confirmed the same endpoint succeeds through `http://sing-box.network.svc.cluster.local:7890`. |
| 11:35 | Added `HTTP_PROXY`, `HTTPS_PROXY`, and trailing-dot-safe `NO_PROXY` to the n8n HelmRelease and patched the live HelmRelease. |
| 11:36 | Helm reconciled and `deploy/n8n` rolled out successfully. |
| 11:38 | Manual n8n MCP execution `310` of the workflow test branch succeeded; Matrix returned event id `$09aqLHgcMecEf13j4iCTFN6NBqR3pUBe_9y7SK8JWnE`. |

## Symptom

The Matrix node failed with:

```text
The connection timed out, consider setting the 'Retry on Fail' option in the node settings
connect ETIMEDOUT 172.67.173.168:443
```

The failing node used the existing n8n Matrix credential
`Forgejo CI Matrix Account` and room
`!GfJXfhwgQXrmCRRjlf:beaco.works`. The error happened before Matrix
auth or room authorization could be evaluated.

## Root Cause

n8n runs as a normal PodCIDR workload in the `development` namespace.
Direct egress from that pod network to the Cloudflare-backed Matrix
endpoint is unreliable / blocked from this site.

The transparent sing-box path is not available to normal PodCIDR pods on
this cluster. ADR shared/0004's 2026-05-05 amendment is the load-bearing
fact: with Cilium BPF masquerade enabled, PodCIDR egress stays on the
BPF datapath and does not traverse the host netfilter prerouting hook
that sing-box `auto_redirect` depends on.

`CiliumEgressGatewayPolicy` is therefore not a fix for n8n in the
current cluster shape. It selects the egress node / SNAT path but still
does not deliver the packet into sing-box's netfilter capture path.

## Decision

n8n remains a PodCIDR workload and explicitly opts into the in-cluster
sing-box mixed proxy with environment variables:

```yaml
HTTP_PROXY: http://sing-box.network.svc.cluster.local:7890
HTTPS_PROXY: http://sing-box.network.svc.cluster.local:7890
NO_PROXY: ".svc,.svc.cluster.local,.svc.cluster.local.,cluster.local,cluster.local.,10.0.0.0/8,172.16.0.0/12,localhost,127.0.0.1"
```

Do not make n8n `hostNetwork: true` just to use transparent egress. n8n
does not need the CI/build-runner escape hatch, and host networking would
add port-collision and namespace-hardening risk for no practical benefit.

Do not add a production `CiliumEgressGatewayPolicy` for n8n unless a
future ADR changes the cluster's Cilium masquerade / datapath model.

## Verification

After adding the env vars:

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig \
  kubectl -n development rollout status deploy/n8n --timeout=15m

KUBECONFIG=/home/beacon/swarm/kubeconfig \
  kubectl -n development get deploy n8n \
  -o jsonpath='{.spec.template.spec.containers[0].env}'
```

Expected: `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` are present on the
n8n container.

Network-path sanity check:

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig \
  kubectl -n development run curl-n8n-proxy-test --rm -i \
  --restart=Never \
  --image=curlimages/curl \
  --env=HTTP_PROXY=http://sing-box.network.svc.cluster.local:7890 \
  --env=HTTPS_PROXY=http://sing-box.network.svc.cluster.local:7890 \
  --env=NO_PROXY=.svc,.svc.cluster.local,.svc.cluster.local.,cluster.local,cluster.local.,10.0.0.0/8,172.16.0.0/12,localhost,127.0.0.1 \
  -- curl -fsS --max-time 20 \
  https://matrix.beaco.works/_matrix/client/versions
```

Expected: Matrix versions JSON.

Workflow verification was execution `310` via n8n MCP, status `success`,
with the Matrix node returning an `event_id`.

## Runbook

If Matrix notifications fail again:

1. Check the latest n8n execution error first. `ETIMEDOUT` / Cloudflare
   IP errors point to egress; Matrix `M_FORBIDDEN` / `M_UNKNOWN_TOKEN`
   points to credentials instead.
2. Verify n8n still has the proxy env in both the HelmRelease and the
   rendered Deployment.
3. Verify `sing-box.network.svc.cluster.local:7890` is reachable from
   the `development` namespace.
4. Re-run the workflow test branch before rotating Matrix credentials.
