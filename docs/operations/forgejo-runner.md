# Forgejo Actions runner — talos-ii operations runbook

## What this is

Operations runbook for the Forgejo Actions runner on talos-ii — the
DinD `act_runner` Pod in the `forgejo-runner` namespace. The
runner is a job-pulling client (no Service, no public exposure, no
tailnet exposure); it executes workflows from `git.beaco.works`
(primarily `nix-fleet`'s `build-and-push.yaml`).

For the **why** behind the architecture (DinD vs. host-mode,
hostNetwork, Phase 1 / Phase 2 zot mirror split, the act_runner
env-propagation finding, the kernel-level transparent egress
contract), see
[ADR 0013 — Forgejo Actions runner on talos-ii](../decisions/talos-ii/0013-forgejo-runner-talos-ii.md).
For the original spec walkthrough — every gotcha tagged back as
fold-back — see
[`specs/003-forgejo-runner-talos-ii/`](../../specs/003-forgejo-runner-talos-ii/).

The egress contract this runner consumes is documented in
[ADR shared/0004](../decisions/shared/0004-cluster-egress-gateway.md)
and [`sing-box-egress.md`](sing-box-egress.md). The image pull
chain is documented in [`zot-mirror.md`](zot-mirror.md) (LAN host,
Phase 1) and [`zot-restore.md`](zot-restore.md) (in-cluster,
Phase 2 target).

## Pre-flight checks

Run these before any first-deploy or DR rebuild of the runner.

```bash
# 1. sing-box DS healthy on all three MS-01 nodes (auto_redirect
#    is the runner's egress capture path).
kubectl -n network get ds sing-box -o wide
kubectl -n network logs -l app=sing-box --tail=50 | grep -i auto_redirect
# expect: 3/3 ready, no netfilter table conflict errors

# 2. Cluster-local Service-name targets resolve.
kubectl get svc -n development forgejo-http   # expect Port 3000
kubectl get svc -n nix         attic          # expect Port 8080
kubectl get svc -n registry    zot            # expect Port 5000 (Phase 2 only)

# 3. LAN zot reachable from a talos-ii node.
kubectl debug node/<ms01-a> -it --image=curlimages/curl -- \
  curl -sf http://172.16.80.240:5000/v2/_catalog
# expect: a non-empty repositories list
```

If any check fails, do not proceed — the runner cannot register
or pull its images otherwise.

## Token mint procedure

The chart's `forgejo-runner-init-config` Job consumes a registration
token via SOPS Secret `forgejo-runner-secret`
(`stringData: {CONFIG_TOKEN, CONFIG_INSTANCE, CONFIG_NAME}`).
Bootstrap-only — once the runner registers successfully, the
chart's `upload-config` container patches a persistent credential
into `forgejo-runner-config`, and `CONFIG_TOKEN` is no longer
referenced. Default upstream token validity is **~7 days**; if
debug stretches past that window, re-mint and re-encrypt before
the Job re-runs.

Two paths to mint:

1. **CLI inside the Forgejo Pod** (preferred — scriptable):

   ```bash
   kubectl -n development exec deploy/forgejo -c forgejo -- \
     forgejo actions generate-runner-token
   # stdout: a token string. Capture it; do NOT paste into any
   # file in this repo unencrypted.
   ```

2. **Admin UI**: Site Administration → Actions → Runners →
   Create new runner → copy token (one-shot, do not navigate
   away).

After mint, encrypt + commit:

```bash
# Edit registration-token.sops.yaml — set CONFIG_TOKEN to the
# minted value. (CONFIG_INSTANCE and CONFIG_NAME are stable.)
sops kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml

# Belt-and-suspenders re-encrypt; round-trip-decrypt to verify
# recipient correctness (per project memory
# feedback_sops_cross_repo_cwd.md — ENC[…] markers prove
# encryption, not recipient correctness).
cd ~/swarm
task encrypt-secrets
sops -d kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml | head -5

git add kubernetes/apps/forgejo-runner/forgejo-runner/app/registration-token.sops.yaml
git commit -m "chore(forgejo-runner): rotate registration token"
git push
```

`CONFIG_INSTANCE` value is
`http://forgejo-http.development.svc.cluster.local:3000` (cluster-
local plain HTTP — NO_PROXY exempts `.svc.cluster.local`, so the
log-stream goes direct, no sing-box round-trip). `CONFIG_NAME` is
`forgejo-runner-talos-ii`.

## Cutover (talos-i → talos-ii)

**Done as of 2026-05-05.** This section is for DR-style rebuilds
or a future re-cutover.

```bash
# 1. Decommission talos-i runner — scale to zero, do NOT
#    unregister yet (preserve the registration row in case of
#    rollback).
#    Against the swarm-01 / talos-i kubeconfig:
kubectl -n development scale deploy forgejo-runner --replicas=0

# 2. Mint registration token (above), commit + push the SOPS
#    Secret, wait for Flux on talos-ii to reconcile.

# 3. Verify (next section). Do NOT proceed past this until
#    Story 1 (full nix-fleet matrix) is green.

# 4. Unregister talos-i runner in Forgejo UI:
#    Site Administration → Actions → Runners → talos-i row → Delete.

# 5. Open swarm-01 cleanup PR removing
#    kubernetes/apps/development/forgejo-runner/ (separate repo,
#    separate PR — outside this runbook's repo).
```

## Verify procedure

After Flux reconciles `kubernetes/apps/forgejo-runner/`, run these
to satisfy spec 003's verification checklist (FR-006 / FR-007 /
FR-012 / FR-022 / FR-023 / SC-007).

```bash
# Reconciliation status
kubectl -n flux-system get kustomization forgejo-runner
kubectl -n forgejo-runner get all
flux get hr -n forgejo-runner forgejo-runner
# expect: Kustomization Ready=True, Pod 1/1 (or 2/2 with init), Job Complete

# Pod-level health: two long-running containers (runner + dind)
kubectl -n forgejo-runner get pod -o wide
kubectl -n forgejo-runner get pod -o yaml | yq '.items[].spec.containers[].name'
# expect: [runner, dind]

# dockerd healthy + bridge subnet correct (FR-012)
POD=$(kubectl -n forgejo-runner get pod -l app.kubernetes.io/name=forgejo-runner -o jsonpath='{.items[0].metadata.name}')
kubectl -n forgejo-runner exec -c dind $POD -- docker ps
kubectl -n forgejo-runner exec -c dind $POD -- docker network inspect bridge | grep Subnet
# expect: empty docker ps; "Subnet": "10.250.0.0/16"

# act_runner registered + online
kubectl -n forgejo-runner logs $POD -c runner --tail=50 | grep -i register
# expect: a "registered as runner …" line, then steady poll loop

# sing-box coexistence (FR-023 / SC-007) — runner Pod is hostNetwork,
# so its egress SHOULD be captured by auto_redirect.
NODE=$(kubectl -n forgejo-runner get pod $POD -o jsonpath='{.spec.nodeName}')
kubectl -n network logs -l app=sing-box --tail=200 | \
  grep -i "$(kubectl -n forgejo-runner exec -c runner $POD -- hostname -i 2>/dev/null || echo unknown)"
# expect: sing-box journal contains entries for runner egress
#         destinations (e.g. proxy.golang.org, cache.nixos.org)
#         during a workflow run

# Forgejo UI: Site Administration → Actions → Runners → expect
# exactly one online runner named `forgejo-runner-talos-ii` with
# labels `ubuntu-latest` and `nix-builder`.
```

## Common debug paths

### sing-box auto_redirect not capturing egress

Symptom: workflow's `nix build` Go-fetcher times out on
`proxy.golang.org`; runner Pod logs show direct connection
attempts that hang.

Sequence to check:

```bash
# Is the runner Pod actually on hostNetwork?
kubectl -n forgejo-runner get pod $POD -o yaml | yq '.spec.hostNetwork'
# expect: true. If false, postRenderer patch didn't apply —
# kubectl get hr -n forgejo-runner forgejo-runner -o yaml | yq '.spec.postRenderers'

# Is sing-box DS healthy on the runner's node?
kubectl -n network logs -l app=sing-box --tail=200 \
  --field-selector spec.nodeName=$NODE
# expect: no panics, no rule-set EEXIST loops

# auto_redirect rules installed?
talosctl -n $NODE read /proc/net/nf_tables 2>/dev/null | grep sing-box
# or via debug pod:
kubectl debug node/$NODE -it --image=alpine/nftables -- nft list ruleset | grep -A5 sing-box
```

If sing-box is healthy but auto_redirect rules are missing, check
the sing-box config in `/etc/nixos`'s `k8s-sing-box-oci`
derivation for the `route_exclude_address` static list (per ADR
0013 "discovered during impl" — the rule-set form has upstream
bugs).

### nix sandbox DNS failure

Symptom: workflow step inside `nixos/nix:latest` errors with
`getaddrinfo failed: Name or service not known` for upstream
hosts (cache.nixos.org, github.com).

Cause: nix's fixed-output sandbox isolates `/etc` by default;
glibc can't read `nsswitch.conf` / `hosts` / `services` /
`protocols`, so name resolution fails.

Fix: ensure the workflow's `nix.conf` snippet sets
`extra-sandbox-paths = /etc/nsswitch.conf /etc/hosts /etc/services /etc/protocols`.
This is set in the `nix-fleet` workflow today; if it ever drifts,
this is the symptom.

### attic push 502 — endpoint URL conflict

Symptom: `attic push` from a runner job returns HTTP 502.

Cause: attic's `api-endpoint` config option (if set) forces all
clients to use the same URL. The in-cluster + tailnet topology
needs different URLs per client (cluster-local for runner,
`tail5d550.ts.net` for fleet hosts), so `api-endpoint` is
**unset** on the server (commit `748fbad`). Each client config
must therefore carry its own endpoint URL.

Fix: in the runner job's `attic` client config / env, point at
the cluster-local URL `http://attic.nix.svc.cluster.local:8080`.
Do NOT re-set `api-endpoint` on the attic server (would break
the fleet hosts).

### QQ / wechat-uos build steps reset by WAF

Symptom: `nix build` of `qq` or `wechat-uos` derivations errors
with TLS connection reset / 403 from upstream
`im.qq.com.cn` / `weixin.qq.com`.

Cause: upstream WAF anti-bot uses TLS fingerprint detection;
neither the runner's outbound (sing-box vmess → Beaco Teleport)
nor a direct connection from CN passes the fingerprint check.
Not proxy-related.

Mitigation today: those derivations are **disabled** in the
`nix-fleet` matrix. Re-enable when a uTLS / fingerprint-rotating
client is wired into the egress chain (tracked separately, not in
spec 003 scope).

### Token expired

Symptom: `forgejo-runner-init-config` Job's `generate-config`
container fails with `invalid token` and the Job's `status.failed`
counter increments.

Cause: registration token's ~7-day expiry hit during prolonged
debug. The token is **only** consumed on first registration; once
the runner has registered successfully (and the chart's
`forgejo-runner-config` Secret carries the persistent credential),
the token is unused.

Fix: re-mint per "Token mint procedure" above. If a prior
registration succeeded, the persisted credential survives — the
re-mint just unblocks the Job's idempotent re-run. If no prior
registration succeeded, the re-mint is the actual unblock.

## Rollback

Different shapes depending on how far the change has progressed:

- **Pre-T045 (talos-i runner still scaled to zero, not yet
  unregistered):**
  Re-scale talos-i back up against the swarm-01 kubeconfig:
  ```bash
  kubectl -n development scale deploy forgejo-runner --replicas=1
  ```
  The talos-i registration row is still in Forgejo because we
  did NOT unregister yet. Restores previous runner availability
  in <2 minutes. Then suspend the talos-ii Flux Kustomization to
  stop reconciling the new shape:
  ```bash
  kubectl -n flux-system patch kustomization forgejo-runner \
    -p '{"spec":{"suspend":true}}' --type=merge
  ```

- **Post-T045 (talos-i runner unregistered, manifests removed
  on swarm-01):**
  Re-create the registration row on Forgejo UI (Site
  Administration → Actions → Runners → Create new runner), mint
  a fresh token, restore the swarm-01 manifests in a revert PR,
  and let the talos-i Flux reconciler land it. Suspend or delete
  the talos-ii HelmRelease in parallel:
  ```bash
  kubectl -n flux-system patch kustomization forgejo-runner \
    -p '{"spec":{"suspend":true}}' --type=merge
  kubectl -n forgejo-runner scale deploy forgejo-runner --replicas=0
  ```

- **Reconciliation itself failing** (Job error, Pod CrashLoop,
  HelmRelease stuck):
  Suspend the Flux Kustomization (above), debug under
  `kubectl logs $POD -c runner` / `-c dind`, fix in a follow-up
  commit, push, unsuspend.

## Image bump procedure

Both runner and dind images are pulled through the LAN zot
pull-through cache (`172.16.80.240:5000`). Bumping is a HelmRelease
values edit; zot fills the cache on first pull.

```bash
# 1. Decide target tags. Spot-check upstream tag lists:
#    code.forgejo.org/forgejo/runner    (runner)
#    https://hub.docker.com/_/docker     (dind: look for
#                                          NN.N.N-dind multi-arch
#                                          unsuffixed tag)
# Do NOT use -amd64-suffixed tags — those literals don't exist
# upstream (per ADR 0013 §3 "discovered" item).

# 2. Edit kubernetes/apps/forgejo-runner/forgejo-runner/app/helmrelease.yaml
#    - .spec.values.image.tag         (runner)
#    - .spec.values.dind.image.tag    (dind)

# 3. Commit + push. Flux reconciles; chart's HelmRelease
#    triggers a Recreate strategy rollout (chart-default).
git add kubernetes/apps/forgejo-runner/forgejo-runner/app/helmrelease.yaml
git commit -m "fix(forgejo-runner): bump runner to <ver>, dind to <ver>"
git push

# 4. Verify post-reconcile.
kubectl -n forgejo-runner get pod -o yaml | yq '.items[].spec.containers[].image'
```

The kubectl image (chart's registration Job) is also pinned to LAN
zot — bump the `kubectl.image.tag` value the same way if the
upstream `alpine/kubectl` minor moves.

## Phase 2 mirror cutover (deferred)

Phase 2 flips dockerd's registry mirror from the LAN zot
(`172.16.80.240:5000`, anonymous) to the in-cluster zot
(`zot.registry.svc.cluster.local:5000`, htpasswd-auth). Gated on
spec 002's 7-day burn-in close (per ADR 0012 §10).

When ready:

```bash
# 1. Add SOPS Secret carrying docker config.json:
cat <<EOF > /tmp/dockerd-zot-auth.yaml
apiVersion: v1
kind: Secret
metadata:
  name: dockerd-zot-auth
  namespace: forgejo-runner
type: Opaque
stringData:
  config.json: |
    {
      "auths": {
        "zot.registry.svc.cluster.local:5000": {
          "auth": "$(printf 'admin:%s' "$ZOT_ADMIN_PW" | base64)"
        }
      }
    }
EOF
mv /tmp/dockerd-zot-auth.yaml \
   kubernetes/apps/forgejo-runner/forgejo-runner/app/dockerd-zot-auth.sops.yaml
sops -e -i kubernetes/apps/forgejo-runner/forgejo-runner/app/dockerd-zot-auth.sops.yaml

# 2. Edit kubernetes/apps/forgejo-runner/forgejo-runner/app/dockerd-config.yaml:
#    .data."daemon.json" =
#      {
#        "registry-mirrors": ["http://zot.registry.svc.cluster.local:5000"],
#        "insecure-registries": ["zot.registry.svc.cluster.local:5000"],
#        "bip": "10.250.0.1/16"
#      }

# 3. Edit helmrelease.yaml's postRenderer to add a fourth patch:
#    - op: add
#      path: /spec/template/spec/containers/1/volumeMounts/-
#      value: { name: dockerd-zot-auth, mountPath: /root/.docker/config.json, subPath: config.json }
#    - op: add
#      path: /spec/template/spec/volumes/-
#      value:
#        name: dockerd-zot-auth
#        secret:
#          secretName: dockerd-zot-auth
#          items: [{ key: config.json, path: config.json }]
#  (subPath is mandatory — without it the mount replaces /root/.docker/.)

# 4. Add ./dockerd-zot-auth.sops.yaml to app/kustomization.yaml resources.

# 5. Commit + push. Verify after reconcile:
kubectl -n forgejo-runner exec -c dind $POD -- cat /etc/docker/daemon.json
kubectl -n forgejo-runner exec -c dind $POD -- docker info | grep -i "registry mirror"
kubectl -n forgejo-runner exec -c dind $POD -- docker pull node:20.12-bookworm
# expect: image-pull traffic in zot.registry logs, NOT in
#         172.16.80.240:5000 logs.
```

Rotation of the zot admin password requires lock-step updates of
`dockerd-zot-auth.sops.yaml` and the zot side
(`kubernetes/apps/registry/zot/app/secret.sops.yaml` plus
`cluster-secrets`'s `ZOT_PROBE_AUTH_HEADER`). Per the same
multi-SOPS-file rotation pattern attic and zot already follow.

## Status

- 2026-05-05: First-deploy verified end-to-end. Runner online in
  Forgejo UI as `forgejo-runner-talos-ii`; nix-fleet
  `build-and-push.yaml` matrix succeeds for non-flaky derivations
  (QQ / wechat-uos disabled per Common debug paths). talos-i
  runner unregistered + scaled to zero; swarm-01 cleanup PR
  pending as a follow-up.
