# Chain halted, all pods Running/Ready (quorum loss)

> Backed by scenario: [`01-validator-loss`](../scenarios/01-validator-loss/)
> (Step 2 — halt + automatic recovery; Step 3 — coordinated-restart recovery;
> Step 4 — how much of the set must be restarted, the f+1 threshold) — entries are
> added only after the recovery procedure has been executed and verified against a
> real network.

## Symptom

- **Block height is frozen.** `eth_blockNumber` returns the same value on every
  poll, but RPC _still answers_ — reads work, the height just never increases.
- Pending transactions accumulate and never mine.
- **The trap:** `kubectl get pods` shows the surviving validators
  `Running`/`Ready`. Nothing is CrashLooping. To Kubernetes the network looks
  healthy while it is, in fact, down. This is the highest-stakes false-comfort
  state in the system.

## Likely Causes

Ordered by frequency in practice:

1. **Two or more validators down at once** (N=4, quorum 2f+1 = 3). Two
   simultaneous voluntary disruptions are the usual cause: a node drain or a
   rolling update that took two validators together (no/ineffective
   PodDisruptionBudget), or two validators co-scheduled on one failed node.
2. **Network partition** splitting the validators so no side has quorum (each
   side has ≤ 2 of 4). Same symptom — frozen height, RPC alive — but the pods
   are all `Running`. Distinguish by peer counts (see diagnosis); for the
   dedicated procedure see
   [chain halted, network partition](03-chain-halted-network-partition.md).
3. **Cluster-wide misconfiguration** preventing consensus (e.g. severe clock
   skew across the set, or a bad config rollout) — rare, but presents the same
   way.

## Diagnosis Steps

```sh
# Height frozen but RPC alive? Poll twice; value must be identical and RPC must
# answer both times.
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://sbx-rpc-unified:8545

# Reads still served confirms "halted", not "RPC down"
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://sbx-rpc-unified:8545

# How many validators are actually up?
kubectl -n besu get statefulset
kubectl -n besu get pods

# Down-validator case vs partition case: on a survivor, a low peer count that
# matches "lost N validators" points to nodes down; if all pods are Running but
# peers are split, suspect a partition.
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
  http://sbx-validator1:8545

# Round-change progression: the climbing round number AND its (doubling) timeout
# confirm the survivors are backing off, not hung. The RoundTimer log line states
# both directly, e.g. "Moved to round 2 which will expire in 40 seconds":
kubectl -n besu logs sbx-validator1-0 | grep -iE 'RoundTimer|expire in'

# Per-validator current round, whole set at once:
kubectl -n besu logs sbx-validator1-0 | grep -A5 'BFT round summary'
```

> **The inflated timeout is only in the logs.** There is no RPC or Prometheus
> metric for the live round or its current timeout — the `RoundTimer` log line is
> the only source. If you know the round you can compute it:
> `timeout = requesttimeoutseconds × 2^round` (with `requesttimeoutseconds: 10`:
> round 0 = 10s, 1 = 20s, 2 = 40s, 3 = 80s, 4 = 160s, 5 = 320s; ~300s of halt lands
> around round 5). **Caveat:** restarting a validator discards these logs, so read
> them from a node that has stayed up through the halt, before any restart.

## Recovery Procedure

1. **Restore the missing validators** — scale the StatefulSets back to 1,
   reschedule, or fix the node. Recovery is **fully automatic** once quorum
   returns; in all verified runs there was no stuck round-change loop and no
   manual intervention beyond bringing the validators back.

   ```sh
   kubectl -n besu scale statefulset/sbx-validator2 --replicas=1
   kubectl -n besu scale statefulset/sbx-validator3 --replicas=1
   ```

2. **Do not restart _individual_ "stuck" survivors.** They are not hung — they are
   climbing BFT round-change backoff (`requesttimeoutseconds` doubling
   10 → 20 → 40 → 80 → …; QBFT and IBFT 2.0 behave the same here). Restarting one
   or two of them piecemeal is _worse_ than doing nothing: the restarted node
   drops to round 0 while its peers stay on a high round, deepening the mismatch.
   (A _coordinated_ restart of the whole set is different — see step 4.)

3. **Wait. Recovery is automatic but not immediate, and the wait grows
   superlinearly with how long the network was without quorum.** Measured on
   the verified network (2s block period, default `requesttimeoutseconds`; QBFT
   figures below — IBFT 2.0 reproduces them within a few seconds):

   | Halt duration | First new block _after_ both pods `Ready` |
   | ------------- | ----------------------------------------- |
   | 71s           | 60s                                       |
   | 154s          | 134s                                      |
   | 341s          | **588s** (~10 min)                        |

   A ~5.5-minute outage cost nearly **10 minutes** of additional downtime
   _after_ Kubernetes already reported every pod `Ready`. **Block production
   resuming minutes after the cluster looks healthy is normal, not a hang.**
   The longer the halt ran, the higher the round the survivors reached, and
   recovery must wait out the current inflated round timer (plus any further
   failed rounds while the restored validators resync).

4. **If the automatic wait is unacceptable, force recovery with a _coordinated_
   restart of _all_ validators.** The round-change timer is in-memory state — only
   the blockchain is persisted — so restarting every validator's process together
   resets the whole set to round 0 and skips the backoff tail. Restart the
   survivors **at the same time** as you bring the downed ones back, so all nodes
   re-enter consensus near round 0 together. Use a plain pod delete (process
   restart) — **do not delete the data volumes**, or you force a resync:

   ```sh
   # bring the downed pair back AND restart the non-bootnode survivor(s), together.
   # Leave validator1 (the liveness gate) running — one stuck survivor is tolerated
   # and skipping it avoids serialising the others' startup behind it.
   kubectl -n besu scale statefulset/sbx-validator2 --replicas=1
   kubectl -n besu scale statefulset/sbx-validator3 --replicas=1
   kubectl -n besu delete pod sbx-validator4-0                    # survivor (not v1)
   ```

   Verified on both engines after a 300s halt (where waiting it out costs ~588s):
   the first block came **6s (QBFT) / 22s (IBFT 2.0)** after pods were `Ready`, at
   round 1 / round 2 instead of the pre-restart ~round 5 — total recovery **77s /
   84s** from the restart, almost all of it pod startup. Only do this when the
   residual round timer clearly dominates (a deep/long halt).

   You do **not** strictly need to restart the _whole_ set — only enough that
   **2f+1 validators (here 3 of 4) are at a fresh low round**. The recovered nodes
   come back fresh, so restarting the downed pair plus **one** survivor is already
   quorum; up to _f_ survivors may be left untouched. A single stuck survivor can't
   drag the set back up (that needs f+1 high-round nodes). Verified on **both
   engines** (`STUCK_SURVIVORS=1`): leaving validator1 stuck recovered in **2s after
   Ready (RTO 23s)** — _faster_ than the full-set restart, because skipping
   validator1 means the other pods don't wait on its liveness init-container. So in
   practice: restart the downed pair plus the non-bootnode survivors, and leave
   validator1 (the liveness gate) running.

5. **Verify recovery:** confirm a new block appears above the halt height, then
   confirm steady advance and that all four validators are at the same height.

## Prevention

- **PodDisruptionBudget `maxUnavailable: 1`** on the validator pods. This is the
  single most important control: it stops a node drain or rolling update from
  evicting two validators at once, which is the most common way to trip from
  [single validator down](01-validator-down-network-healthy.md) into this state.
- **Pod anti-affinity** so no two validators share a node — one node failure
  must not remove two validators.
- **Alert on block-height-stall, never on pod health alone.** Pods
  `Running`/`Ready` is precisely the false comfort here. Height-not-advancing
  for > N block periods is the only reliable detector of this failure.
- **Keep detection + recovery fast to stay on the cheap part of the RTO
  curve.** Because RTO grows superlinearly with halt duration, every minute you
  shave off detection saves disproportionately more on recovery.

## Post-Incident

- Preserve survivor logs showing the round-change progression — this is the
  evidence that the network was backing off, not hung, and justifies the
  "wait, don't restart" decision.
- Record the halt duration and the post-`Ready` recovery time; add the data
  point to the RTO curve so your RTO commitment reflects measured behaviour, not
  the block period.
- If two validators were taken down by a drain or rolling update, the
  PodDisruptionBudget was missing or ineffective — fix that before the next
  maintenance window.
