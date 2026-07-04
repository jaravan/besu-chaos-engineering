# Validator down, network healthy (false-positive alert storm)

> Backed by scenario: [`01-validator-loss`](../scenarios/01-validator-loss/) (Step 1).

## Symptom

- Alerts firing on RPC connection errors, peer-disconnect events, or a dropped
  peer count on one or more nodes.
- One validator pod is not `Ready`, is restarting, or has briefly vanished.
- **Block height keeps advancing the whole time.** `eth_blockNumber` against
  the unified RPC service still climbs every block period.

This is the harmless version of [chain halted, quorum
loss](02-chain-halted-quorum-loss.md): here the alerts look alarming but the
network never lost quorum. With N=4 validators, quorum is 2f+1 = 3, so a single
validator down leaves consensus fully functional.

## Likely Causes

Ordered by frequency in practice:

1. **A single validator crashed and is being recreated** — OOM kill, node
   drain/eviction, SIGKILL, image re-pull. For a validator **you** operate, the
   StatefulSet recreates it automatically. First establish **whose validator it
   is**: in a consortium the down node may belong to another member, on their own
   infrastructure — you have no StatefulSet, no logs, and no recovery lever for
   it, only the quorum math (still N-1, healthy) and a notification to that
   member. The auto-recovery and diagnosis steps below apply to nodes you run.
2. **Cross-member / cross-cloud connectivity loss (consortium topology).** In a
   real consortium each validator is run by a different organization, often in a
   different cloud, VPC, or region — so the validators reach each other over
   inter-org links, not a single flat cluster network. A member can drop off the
   set while its pod stays perfectly `Running`/`Ready`: a VPN or VPC-peering
   flap, an egress firewall / security-group change on either side, a NAT /
   public-IP or DNS change, a cert or enode-allowlist rotation, or cross-region
   link degradation. From consensus it looks like one validator gone (still
   N-1, quorum holds); from Kubernetes nothing is wrong at all. **If a link
   outage isolates two or more members at once it escalates to a partition /
   [quorum loss](02-chain-halted-quorum-loss.md).**
3. **Sustained single-validator outage** — PVC unavailable, scheduling failure,
   stuck image pull. Pod stays down until the underlying cause is fixed, but the
   chain still runs at N-1.
4. **Pure false positive** — an RPC client had a connection pinned to the
   restarted validator and logged connection errors; nothing in consensus was
   ever affected.
5. **Transient peer-count dip after a restart** — a rejoining validator (or
   even a healthy one shortly after deploy) reports fewer peers than full mesh
   for minutes; alerting keyed on an absolute peer-count threshold fires even
   though consensus is fine.

## Diagnosis Steps

```sh
# Which validator, how many restarts, what phase
kubectl -n besu get pods -o wide

# Confirm the chain is still advancing (run twice, a few seconds apart;
# the value must increase)
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://sbx-rpc-unified:8545

# Confirm 3 of 4 validators are up (quorum intact)
kubectl -n besu get statefulset

# Peer count on a surviving validator (expect it to drop by one while the
# target is down; do not treat a transient dip as an incident)
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://sbx-validator1:8545
```

If `eth_blockNumber` is increasing and 3 of 4 validators are up, the network is
healthy — the page is a false positive. The real question is only _why the one
validator went down_, which you diagnose without time pressure.

**Crash vs. connectivity.** The distinction tells you where to look. If the pod
is **not** `Running`/`Ready` (restarts, `Init:Error`, gone), it's a crash/outage
(causes 1, 3) — check its events and previous logs. If the pod is **`Running`
and healthy but its peer count is low**, it's reachable to Kubernetes but not to
the other members — a connectivity problem (cause 2), common in cross-cloud
consortiums:

```sh
# Pod healthy locally but isolated? Query the suspect validator's OWN peer count
# (not a survivor's). Running pod + low/zero peers = a network/connectivity issue,
# not a crash.
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://sbx-validator2:8545

# Its view of the peers it still has (or doesn't) — confirms which members it
# can reach across the inter-org links.
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
  http://sbx-validator2:8545
```

For the connectivity case the fix is at the network layer (VPN/peering,
firewall/security-group, DNS/NAT, enode allowlist), not on the node — and the
urgency is whether the outage might widen to a second member (→ quorum loss).

## Recovery Procedure

1. **No liveness action is required.** At N-1 = 3 of 4, quorum holds and block
   production never paused. Healthy nodes must not be restarted.
2. **Crash case:** let the StatefulSet recreate the pod (it does this on its
   own). In the verified run the pod was back to `Ready` in **20s** after a
   force-delete and rejoined at head.
3. **Stuck-pod case:** if the pod is not coming back, diagnose the underlying
   cause and fix it:
   ```sh
   kubectl -n besu describe pod sbx-validator2-0   # events: PVC, scheduling, image
   kubectl -n besu logs sbx-validator2-0 --previous # last crash, if any
   ```
4. **Verify rejoin** once the pod is `Ready`:
   - peer count ≥ 3 on the rejoined node, and
   - its height within a few blocks of head.
   - in the verified run the rejoined validator was already at head (zero
     catch-up gap) by `Ready` + 10s.
5. **Tolerate the peer-count lag.** Full-mesh peering can take _minutes_ to
   re-establish after a restart — a node reporting 2 peers immediately after
   `Ready` while others report 3 is expected and self-heals. It must not be
   acted on.

## Prevention

- **Alert on block-height-stall, not on RPC errors or peer-count dips.** Height
  not advancing for > N block periods is the signal that the _network_ is in
  trouble. RPC connection errors and single-node peer drops are not.
- **Add hysteresis/grace to peer-count alerts** (e.g. only alert if below
  threshold for several minutes). Full mesh lags pod readiness by minutes after
  any deploy or restart.
- **PodDisruptionBudget `maxUnavailable: 1`** on the validators so node drains
  and rolling updates can never take two validators down at once — which would
  turn this benign scenario into [quorum
  loss](02-chain-halted-quorum-loss.md).
- **Monitor inter-member connectivity, not just local pod health** (consortium
  topology). A `Running` pod tells you nothing about whether it can still reach
  the other organizations' validators. Alert on a validator's **own peer count
  staying below the expected mesh for several minutes** (sustained, to ride out
  the post-restart lag above) — that is your detector for a cross-cloud link,
  firewall, or allowlist problem before it widens to a second member. Pair it
  with reachability checks on the inter-org links themselves (VPN/peering health,
  enode/port reachability) owned outside the chain.

## Post-Incident

- Capture the dead pod's logs **before** they age out:
  `kubectl -n besu logs <pod> --previous`.
- Record the restart cause (OOM? eviction? node failure?) — recurring OOM means
  the validator memory request/limit needs raising.
- If an alert paged on RPC errors or a peer-count dip while height was
  advancing, that alert is misconfigured; fix the rule, not the network.
