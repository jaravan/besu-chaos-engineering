# Scenario 01 — Validator Loss

One scenario, four steps. The first two move along a single axis: how a
4-validator BFT set behaves as validators are lost, first **below** the fault
threshold (safe) and then **above** it (a halt). The last two turn to recovery.
Once a halt has dragged on and the round-change timer has backed off, a
coordinated restart of all validators can reset that backoff and resume block
production immediately (Step 3), and Step 4 finds how much of the set must
actually be restarted to get there.

With N=4, both of Besu's BFT engines tolerate `f = floor((N-1)/3) = 1` faulty
validators and need quorum `2f+1 = 3` to commit a block. Step 1 stays inside that
budget (one down); Step 2 exceeds it (two down). Same cluster, one validator
either side of the line: "nothing happened" versus "the chain stops."

**Consensus:** run against both **QBFT** and **IBFT 2.0**. The fault model is
identical and the measured behaviour is near-identical (see the
[comparison](#consensus-comparison) below). Select the engine with `CONSENSUS`
(it must match the deployed release):

```sh
make install  CONSENSUS=ibft2     # deploy IBFT 2.0 (default: qbft)
make scenario-01 CONSENSUS=ibft2  # run the scenario against it
```

Run the default steps (1 + 2), or pick one:

```sh
make scenario-01            # steps 1 + 2
STEP=1 make scenario-01     # single validator loss only
STEP=2 make scenario-01     # quorum loss only
STEP=3 HALT_WINDOW=300 make scenario-01                    # coordinated restart (opt-in)
STEP=4 STUCK_SURVIVORS=1 HALT_WINDOW=300 make scenario-01  # partial restart / f+1 threshold (opt-in)
```

---

## Step 1 — Single validator loss (network healthy)

```mermaid
graph LR
    v1[validator1]
    v2[validator2]
    v3[validator3]
    v4["validator4 — down ✕"]:::down
    v1 & v2 & v3 -->|"3 of 4 ≥ quorum 3"| ok(["✓ chain keeps advancing<br/>node rejoins and catches up"])
    class ok good
    classDef down fill:#fdd,stroke:#c00,color:#900
    classDef good fill:#dfd,stroke:#270,color:#150
```

### Hypothesis

Losing one validator must not interrupt block production. A killed validator
should rejoin cleanly and catch up to head without manual intervention.

### Method

Two injections against the besu-sandbox network (validator 2 by default, override
with `TARGET_VALIDATOR`):

- **1a** — ungraceful kill. `kubectl delete pod sbx-validator2-0
--grace-period=0 --force` (SIGKILL semantics, no graceful shutdown). The
  StatefulSet recreates the pod immediately, exercising crash + automatic restart +
  rejoin.
- **1b** — sustained outage. Scale the `sbx-validator2` StatefulSet to 0, hold for
  `OUTAGE_WINDOW` (default 30s), then scale back to 1. Prolonged N-1 operation and
  catch-up after recovery.

### Expected

- Block production continues throughout both injections (sampled via
  `eth_blockNumber` against the unified RPC service).
- During 1b, surviving validators drop to 2 validator peers each.
- After recovery the restarted validator reports ≥ 3 peers and is within a few
  blocks of head.
- RPC clients pinned to the dead validator see connection errors, so alerting keyed
  on RPC errors alone fires even though the network is healthy.

### Observed

Both engines behaved as hypothesised. Block production never paused while one
validator was down, and the validator rejoined at head with no manual intervention.
Verified on chart **0.3.3** (Besu 26.6.1, kind on macOS/arm64, 2s block period), one
run per engine, from a full `3/3/3/3` baseline mesh on both.

**QBFT:**

- 1a (force delete): chain kept advancing during the restart with no observable
  pause at the 2s sampling resolution (kill at height 19; next block 19 → 20 within
  2s). Pod back to Ready in 21s; on rejoin it reported 3 peers and was already at
  head (height 27).
- 1b (30s sustained outage): block production continued uninterrupted at 3-of-4.
  After scaling back, the validator was at head with catch-up gap 0 by the time it
  reported Ready + 10s (node=head=42).

**IBFT 2.0:**

- 1a (force delete): chain kept advancing with no pause at the sampling resolution.
  Pod back to Ready in 30s; on rejoin it reported 3 peers at height 24.
- 1b (30s sustained outage): uninterrupted at 3-of-4, though one ~10s inter-block
  gap appeared during the window, the proposer round-change when a proposer slot
  lands on the absent validator (10s = `requesttimeoutseconds`). After scaling back,
  catch-up gap 0 (node=head=42).
- Cold start: IBFT 2.0 commits its first block only after a few round-changes while
  peering settles (block 1 at round ~3 ≈ 10+20+40s of backoff), so
  `make install --wait` returning on pod-readiness precedes first-block production.
  Wait for the chain to actually advance, not just for pods `Ready`.

The operational takeaway is the same either way: full-mesh peering lags node
readiness after a restart (RLPx connections re-form on their own schedule), so
monitoring that alerts on peer count immediately after a deploy/restart will
false-positive.

---

## Step 2 — Quorum loss (chain halts)

```mermaid
graph LR
    v1[validator1]
    v2[validator2]
    v3["validator3 — down ✕"]:::down
    v4["validator4 — down ✕"]:::down
    v1 & v2 -->|"2 of 4 &lt; quorum 3"| halt(["✕ chain HALTS<br/>round-change backoff grows"])
    class halt stop
    classDef down fill:#fdd,stroke:#c00,color:#900
    classDef stop fill:#fee,stroke:#c00,color:#900
```

### Hypothesis

Taking down two validators simultaneously must halt block production at the last
committed block. Immediate finality means no forks and no rollback, just a stop.
RPC reads should keep working on the surviving nodes, and the network should recover
without manual intervention once quorum is restored.

The number that matters is the **RTO**: how long after the failed validators return
does the first new block appear? The BFT round-change timeout (QBFT and IBFT 2.0
alike) doubles on every failed round. With this chart's `requesttimeoutseconds: 10`
that is 10 → 20 → 40 → 80 seconds, so the surviving validators climb to higher
rounds for as long as the outage lasts. Recovery is not instant, and the longer the
halt, the longer the wait for the round timers to resynchronise.

### Method

Scale validators 2 and 3 (override with `TARGET_VALIDATORS="2 3"`) to 0 replicas,
hold the outage for `HALT_WINDOW` (default 45s), then scale both back and measure
time to the first new block.

Assertions: chain advancing at baseline → height frozen for the full halt window
(sampled every 2s, RPC must keep answering) → first block above the halt height
within 900s of recovery → steady state restored on all four validators.

### Expected

- Chain halts at the last committed height; no forks, no divergent heights between
  surviving validators.
- `eth_blockNumber` and the validator-set query
  (`qbft_getValidatorsByBlockNumber`, or `ibft_getValidatorsByBlockNumber` under
  IBFT 2.0) keep answering during the halt: chain halted ≠ RPC down. This matters
  for monitoring (block-height-stalled is the signal, not RPC errors) and for
  read-only workloads that keep functioning.
- Recovery is automatic but not immediate: expect tens of seconds beyond pod
  readiness for round-change resynchronisation after a 45s halt, and worse after
  longer halts.

### Observed

Both engines behaved identically in kind. The chain froze at the last committed
block for the full halt window (every 2s sample identical, no forks, surviving
validators at the same height) while `eth_blockNumber` and the validator-set query
kept answering and validator1 dropped to 1 peer. Pods stayed Running/Ready
throughout, so to Kubernetes the outage was invisible. Recovery was fully automatic
in every run: no stuck round-change loop, no manual intervention, no divergent
heights afterwards.

RTO grows with halt duration, superlinearly and near-identically on both engines. One
run per cell, verified on chart **0.3.3** (Besu 26.6.1, kind on macOS/arm64, 2s block
period, `requesttimeoutseconds` 10). The absolute seconds are environment-specific
(single-node kind, serial pod restarts) and carry round-quantised noise: recovery
waits out whatever remains of the current doubled timer, so a cell lands early or late
in a 10→20→40→80→160s window (the 120s cells caught opposite ends of it). What
transfers is the _shape_: the superlinear curve, and the f+1 threshold in
[Step 4](#step-4). Reproduce any cell with
`HALT_WINDOW=<window> STEP=2 make scenario-01 CONSENSUS=<engine>`. All values in
seconds:

| `HALT_WINDOW` | Engine   | Halt duration | First block after Ready | RTO |
| ------------- | -------- | ------------- | ----------------------- | --- |
| 45s           | QBFT     | 76            | 58                      | 78  |
| 45s           | IBFT 2.0 | 71            | 58                      | 79  |
| 120s          | QBFT     | 178           | 286                     | 306 |
| 120s          | IBFT 2.0 | 150           | 138                     | 159 |
| 300s          | QBFT     | 340           | 590                     | 611 |
| 300s          | IBFT 2.0 | 342           | 586                     | 607 |

The three measured columns start _and_ stop at different moments, which is why RTO
can exceed halt duration. Mapped onto one timeline:

```
│ both validators scaled to 0 → quorum lost, block production halts
│                                            ┐
│   ... validators absent for ~HALT_WINDOW ...│  halt duration
│                                             │  (inject → pods Ready)
├─ scale-up issued              ┐             │
│   ~20s: pods recreate & resync│ RTO         │
├─ both pods report Ready       │ (scale-up   ┘   ┐
│                               │  → first        │ first block
│   round-change backoff being  │  block)         │ after Ready
│   waited out (can be minutes) │                 │ (pods Ready
└─ first block produced         ┘                 ┘  → first block)
```

- **`HALT_WINDOW`** — the input knob: how long the validators are held at 0.
  Everything else is measured.
- **Halt duration** — injection → both pods Ready. Stops the moment Kubernetes reports
  Ready, so it excludes the round-change backoff that follows.
- **First block after Ready** — pods Ready → first new block: the backoff tail still
  being waited out after Kubernetes reports healthy. This is why RTO exceeds halt
  duration (590s of tail at the 300s window, small at 45s). The true end-to-end stall
  is halt duration + this, ~930s at the 300s window.
- **RTO** — scale-up → first block: total operator-felt recovery (first block after
  Ready + the ~20s pod-restart gap; e.g. 590 + 21 = 611 at `HALT_WINDOW=300s`).

That tail is BFT round-change backoff (`requesttimeoutseconds` doubling per failed
round, as in the Hypothesis): a longer outage climbs to a higher round, and recovery
must wait out the current inflated timer before the set agrees on a block. A
~5.5-minute outage cost nearly 10 minutes of extra downtime after all pods were Ready.
Blocks resuming minutes after Kubernetes reports healthy is normal, not a hang.

The current round and its inflated timeout are not exposed by any RPC or Prometheus
metric; the only source is the validator's `RoundTimer` log line, which states both:
`Moved to round 2 which will expire in 40 seconds`. Equivalently it is
`requesttimeoutseconds × 2^round`. Read it from a node that stayed up through the
halt, since a restart discards the log
(`kubectl -n besu logs sbx-validator1-0 | grep -iE 'RoundTimer|expire in'`).

Restarting individual "stuck" nodes during this window only makes the outage longer:
the restarted node drops to round 0 while its peers sit on a high round, deepening
the mismatch. A coordinated restart of all validators at once is a different lever:
it resets the whole set's in-memory round state together, so the backoff is cleared
rather than deepened. [Step 3](#step-3) isolates and measures exactly that.

<a id="consensus-comparison"></a>

**Consensus comparison.** Under validator loss, QBFT and IBFT 2.0 are behaviourally
near-indistinguishable: same fault threshold, same halt-on-quorum-loss, same
superlinear RTO curve (the 45s and 300s cells within a few seconds of their
counterparts; the 120s pair differs only by where each run landed in the round-timer
window). The only differences observed were at startup: IBFT 2.0's slower cold-start
and its ~10s post-kill block in Step 1 (proposer round-change), neither of which
affects the quorum-loss RTO. Both engines were measured on the same chart (0.3.3) and
cluster.

---

<a id="step-3"></a>

## Step 3 — Coordinated restart resets round-change backoff

Step 2 showed that recovery from a halt is automatic but slow: the surviving
validators have backed off to a high round, and the set must wait the inflated round
timer out before the first block (590s after a 300s halt). That is the _automatic_
path. This step tests the _operator_ path, deliberately resetting the backoff with a
coordinated restart, and measures how much of that tail it removes.

### Hypothesis

The round number and its doubling timeout are in-memory consensus state; only the
blockchain itself is persisted. So:

- Restarting a validator's **process** (not its data) drops it back to round 0 with
  the base `requesttimeoutseconds`. The PVC is untouched, so the node reloads the
  last committed block. This is a restart, not a resync.
- A coordinated restart of all four validators together (the recovered pair and the
  two survivors) resets the whole set to round 0 at once, so the first block follows
  within roughly the base timeout, far below the Step 2 backoff tail at the same
  halt depth.
- The survivors hold the inflated round, so they must be restarted too. Bringing back
  only the downed pair (the Step 2 control) leaves the survivors on a high round and
  the long wait intact.
- Restarting only a subset, or staggering the restarts, should be worse than waiting:
  restarted nodes drop to round 0 while peers stay high, deepening the mismatch (the
  cautionary case in Step 2).
- No fork, no rollback, no divergent heights: immediate finality means the last
  committed block is final, and every node restarts from it.

### Method

Reuse the Step 2 quorum-loss injection (scale `TARGET_VALIDATORS="2 3"` to 0) and
hold for `HALT_WINDOW=300s`, the deepest point Step 2 measured, where waiting it out
costs ~590s. Then, instead of waiting:

1. Scale the downed pair back to 1, and in parallel `kubectl delete pod` the two
   survivors (process restart, PVC retained), so all four re-enter consensus at round
   0 close to simultaneously.
2. Wait for all four pods Ready, then measure time to the first block above the halt
   height.

```sh
STEP=3 HALT_WINDOW=300 make scenario-01 CONSENSUS=<engine>
```

The headline number is first-block-after-Ready for the coordinated restart vs. the
Step 2 control (590 / 586s) at the same `HALT_WINDOW`.

### Expected

- First block within roughly the base round timeout plus pod-restart churn (tens of
  seconds), not the ~590s control. Because a pod restart (~20s) is longer than the
  10s base round-0 timer, expect a little churn: the set likely re-forms at round
  ~1–2, not a clean round 0, but nowhere near the pre-restart round.
- All four validators converge on the same height; no forks, no divergence.
- The previously-down nodes catch up to head within a few blocks.

### Observed

The coordinated restart cleared almost the entire backoff tail on both engines. One
run each, verified on chart **0.3.3** (Besu 26.6.1, kind on macOS/arm64, 2s block
period, `requesttimeoutseconds` 10), `HALT_WINDOW=300s`, validators 2 + 3 downed,
survivors 1 + 4 restarted alongside the recovered pair. The control column is the
Step 2 "wait it out" result at the same halt depth:

| Engine   | First block after Ready | RTO from restart | Step 2 control (after Ready / RTO) |
| -------- | ----------------------- | ---------------- | ---------------------------------- |
| QBFT     | **0s**                  | **71s**          | 590s / 611s                        |
| IBFT 2.0 | **8s**                  | **70s**          | 586s / 607s                        |

- After a 300s halt the survivors had backed off to roughly round 5 (cumulative
  `10+20+40+80+160`s of doubling, the arithmetic of `requesttimeoutseconds × 2^round`
  whose climb is visible in any surviving validator's `RoundTimer` log lines). After
  the coordinated restart the first block followed pods-Ready immediately (0s QBFT /
  8s IBFT 2.0), collapsing the ~590s backoff tail by ~99%: the inflated timer was gone
  and the set re-formed at a low round within the pod-restart churn the hypothesis
  predicted.
- RTO is now dominated by pod startup, not consensus. RTO from restart was 71s (QBFT)
  / 70s (IBFT 2.0), of which the pod-restart gap was 71s / 62s, far more than Step
  2's ~20s two-pod recovery. Cause: all four pods restart together, and validators
  2–4 gate their startup on validator1's liveness init-container, itself a restarted
  survivor, so bringup serialises behind validator1. The consensus part of recovery
  (first block after Ready) is only 0–8s; the rest is Kubernetes bringing pods back.
  Budget ~1 minute of pod churn for a full-set restart.
- No fork, no divergence. All four validators converged on the same height and
  resumed steady 2s block production immediately; the previously-down pair caught up
  within a few blocks.
- The engine difference is negligible: 0s vs 8s to the first block and RTOs within a
  second of each other, the same recovery behaviour, differing only in where
  pods-Ready landed relative to the re-formed set's first proposal.

> **Negative control →** [Step 4](#step-4) isolates _how much_ coordination is
> actually required by leaving some survivors stuck at their high round, showing the
> active ingredient is reaching quorum at a low round, not the restart itself.

This verifies the remedy documented in runbook
[02](../../runbook/02-chain-halted-quorum-loss.md): for a chain halted long enough
that recovery is dragging, a coordinated restart of all validators (process restart,
data volumes retained) resets the round-change backoff and restores block production
in about the time it takes the pods to come back.

---

<a id="step-4"></a>

## Step 4 — How many validators must be restarted (the f+1 threshold)

Step 3 restarted _all_ validators and recovered fast. Does recovery need the whole
set, or just enough of it? This step leaves some survivors at their high round on
purpose and finds the boundary.

### Hypothesis

Recovery is fast as soon as 2f+1 validators sit at a low round together: that is
quorum, and quorum can commit regardless of what the rest are doing. Round timers are
per-node, not global, so the fresh nodes run on their own reset (base) timers and do
not wait out the stuck node's inflated timer; they reach quorum among themselves and
commit. The failure mode is symmetric: a node fast-forwards to a higher round only
when it sees f+1 round-change messages for it. So with N=4 (f=1, quorum=3):

- The downed pair always returns fresh at round 0 (2 nodes). Restart one survivor too
  → 3 fresh nodes = quorum at a low round → expect fast recovery, like Step 3. The
  single remaining stuck survivor is only 1 round-change message, below f+1 = 2, so
  it cannot drag the quorum up.
- Restart no survivors → only the 2 fresh downed nodes, below quorum, and the 2 stuck
  survivors are exactly f+1, so they fast-forward the fresh pair up to the high round
  and the wait persists. (This is the Step 2 control, ~590s.)

The rule: the wait persists if and only if ≥ f+1 validators remain stuck at the high
round. You may leave up to _f_ survivors un-restarted and still recover fast.
"Restart at least one survivor," not "restart everyone," is the operative rule for
N=4.

### Method

Same injection and `HALT_WINDOW=300s` as Step 3, but leave `STUCK_SURVIVORS` of the
survivors running at their high round (don't restart them):

```sh
STEP=4 STUCK_SURVIVORS=1 HALT_WINDOW=300 make scenario-01 CONSENSUS=<engine>  # 1 stuck → expect fast
STEP=4 STUCK_SURVIVORS=2 HALT_WINDOW=300 make scenario-01 CONSENSUS=<engine>  # 2 stuck → expect the full wait
```

### Expected

- `STUCK_SURVIVORS=1`: first block within seconds-to-tens-of-seconds of pods Ready
  (comparable to Step 3), committed at a low round, confirming one stuck survivor is
  tolerated.
- `STUCK_SURVIVORS=2`: first block only after the full backoff tail (~590s), matching
  the Step 2 control, confirming f+1 stuck validators force the wait.

### Observed

One stuck survivor is tolerated: recovery is fast and at a low round, exactly as the
f+1 rule predicts, and identically on both engines. `STUCK_SURVIVORS=1`,
`HALT_WINDOW=300s`, verified on chart **0.3.3** (same cluster as Step 3): validators
2 + 3 downed, validator 4 restarted, validator1 left stuck at its high round.

- First block 0s after pods Ready, RTO 22s from the restart, identical on QBFT and
  IBFT 2.0. The three fresh nodes formed quorum at a low round and ignored
  validator1's lone high-round round-change (1 message, below the f+1 = 2 needed to
  fast-forward the set). The ~590s backoff tail was skipped.
- The fresh quorum did not wait for the stuck node's timer. Validator1 sat on a ~320s
  round-5 timer (the `10+20+40+80+160`s doubling climb, readable in its own
  `RoundTimer` log lines, which survive precisely because it was not restarted), yet
  the first block arrived with pods-Ready: the fresh nodes ran on their own reset
  timers, not its inflated one. The quorum committed among themselves and validator1
  caught up afterwards by syncing.
- Faster than the full restart (Step 3: 0s/8s, RTO 71s/70s). Leaving validator1 up
  meant only three pods restarted and none had to wait on validator1's liveness
  init-container, so the pod-restart gap was 22s, not ~62–71s. Not restarting the
  bootnode/liveness-gate survivor is both sufficient and faster.

| `STUCK_SURVIVORS` | Nodes fresh at low round | QBFT             | IBFT 2.0         |
| ----------------- | ------------------------ | ---------------- | ---------------- |
| 0 (= Step 3)      | 4 (all)                  | RTO 71s          | RTO 70s          |
| 1                 | 3 (quorum)               | **0s / RTO 22s** | **0s / RTO 22s** |
| 2 (= Step 2 ctrl) | 2 (below quorum)         | ~590s            | ~586s            |

The `STUCK_SURVIVORS=2` row is the Step 2 control (restart no survivors = bring the
downed pair back only); it was not re-run here, as it is identical to that
measurement. The threshold is confirmed on both engines: the wait persists if and
only if ≥ f+1 = 2 validators remain stuck. Up to f = 1 survivor may be left
un-restarted.

**Operational takeaway.** "Restart the whole set" is the simple safe rule, but the
minimum that works is "get 2f+1 validators to a fresh low round." For N=4 that means
restarting the recovered pair plus at least one survivor, and skipping the
liveness-gate node (validator1) makes recovery faster, not slower.

---

## Conclusion

Under the failures this scenario exercises, QBFT and IBFT 2.0 are interchangeable
(see the [comparison](#consensus-comparison) above), differing only in
startup/proposer timing. That equivalence is scoped to availability and fault
tolerance, not a blanket "QBFT ≈ IBFT 2.0": the designed differences between them
simply don't surface under validator loss.

- Validator-set management: QBFT supports both vote/header-based and
  smart-contract-based validator management, while IBFT 2.0 is vote/header only. That
  is the biggest functional gap, and it takes exercising validator governance to see it.
- Proposer selection and message format: QBFT is the newer engine, positioned as the
  recommended one going forward, with a more extensible message structure.

To actually distinguish the two engines, exercise validator governance, not
validator loss.

---

## Variations

- Kill the bootnode (`TARGET_VALIDATOR=1`). Validators 2–4 gate their _startup_ on
  validator1's liveness endpoint (init container), so a running network should tolerate
  the loss, but pod restarts elsewhere during the outage will block. Worth a dedicated run.
- Longer halts (`HALT_WINDOW=600` and up) extend the RTO curve beyond the measured
  45/120/300 points; at some round the residual timer dominates. The "wait vs.
  restart-all-validators-together" half of that question is now [Step 3](#step-3).
- Ungraceful double kill: force-delete both pods in Step 2 instead of scaling, then let
  the StatefulSets restart them. This checks crash-recovery under quorum loss rather than
  clean shutdown.

## Runbook entries backed by this scenario

- [Validator down, network healthy (false-positive alert
  storm)](../../runbook/01-validator-down-network-healthy.md) — Step 1.
- [Chain halted, all pods Running/Ready (quorum
  loss)](../../runbook/02-chain-halted-quorum-loss.md) — Step 2. Steps 3 and 4 add
  the verified recovery levers (coordinated restart, and the f+1 minimum) to that
  entry's recovery procedure.
