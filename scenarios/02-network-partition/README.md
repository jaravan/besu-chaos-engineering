# Scenario 02 — Network Partition (split-brain)

## Hypothesis

Split the four validators into two pairs — `[validator1, validator2]` and
`[validator3, validator4]` — that cannot reach each other, while the probe can
still reach every node's RPC. Each side now sees only 2 of 4 validators, below
the BFT quorum of 2f+1 = 3.

The name "split-brain" is borrowed from databases, where a partition can let two
sides accept conflicting writes and diverge. **Besu's BFT engines cannot
split-brain.** Block commitment requires a 2f+1 quorum *and* both QBFT and
IBFT 2.0 have immediate finality, so neither 2-validator side can commit a block.
The expected outcome is therefore the same as quorum loss
([scenario 01, Step 2](../01-validator-loss/#step-2--quorum-loss-chain-halts)):
both sides **halt** at the last committed block — no fork, no divergent heights,
nothing to reconcile when the partition heals.

What makes this distinct from quorum loss, and worse for an operator: in a
partition **all four pods stay `Running`/`Ready`**. Quorum loss at least had two
pods missing; here Kubernetes sees a fully healthy deployment while the network
is dead. It is the strongest possible case for "alert on block-height-stall, not
on pod health."

## Method

Inject the partition with `iptables` `DROP` rules in the validator pods'
network namespaces. The Besu containers have neither `iptables` nor `NET_ADMIN`,
so the rules are added via **privileged ephemeral debug containers**
(`kubectl debug --profile=sysadmin`, image `nicolaka/netshoot`) that share each
target pod's netns — a non-invasive technique that needs no chart change
(`ensure_netns_container` / `netns` in [`scripts/lib.sh`](../../scripts/lib.sh)).

Rules are added on the `[1,2]` side only (sufficient: TCP/UDP need both
directions, so dropping all traffic to/from the `[3,4]` pod IPs there fully
isolates the groups). RPC is unaffected because the probe pod's IP is not in the
drop set.

```sh
make scenario-02                  # QBFT (default)
make scenario-02 CONSENSUS=ibft2  # IBFT 2.0 (must match the deployed release)
```

Healing flushes those rules (no pod restart), so the run observes whether the
network resumes on its own. A safety net in the script force-recreates the
`[1,2]` pods if it exits before healing, so a failed run never leaves the
network partitioned.

Assertions: chain advancing at baseline → frozen for the full `HALT_WINDOW`
(default 45s) with both sides reporting the **same** height (no fork) and RPC
still answering → first new block within 900s of healing → steady state on all
four validators.

## Expected

- Both partitions halt at the last committed block; identical heights across all
  four nodes throughout (proves no split-brain).
- Peer counts collapse: each validator drops to 1 peer (only its same-side
  partner) as the cross-partition RLPx connections time out.
- `eth_blockNumber` keeps answering on every node — halted ≠ RPC down.
- All four pods remain `Running`/`Ready` for the entire outage.
- On heal, automatic recovery (subject to the same BFT round-change backoff
  measured in [scenario 01, Step 2](../01-validator-loss/#step-2--quorum-loss-chain-halts)
  — recovery is not instant after a long partition).

## Observed

Both engines behaved exactly as hypothesised — the partition halted the chain at
the last committed block with **no fork**, every pod stayed `Running`/`Ready`, and
the network recovered automatically on heal with no pod restart and no divergence.
Recorded on kind v0.32.0 (macOS/arm64, kubectl 1.36.1, chart 0.2.2, Besu 26.6.0,
2s block period, `HALT_WINDOW=45`, split `[1,2] | [3,4]`). One run per engine —
the absolute recovery seconds are timing-specific (they depend on where the heal
lands in the current round timer); what transfers is the shape.

| Engine   | Halt height | Sides agree (no fork) | Pods during halt | Peers v1/v2/v3/v4 | Max round | Recovery after heal |
| -------- | ----------- | --------------------- | ---------------- | ----------------- | --------- | ------------------- |
| QBFT     | 66          | yes (66 = 66)         | all 4 Running    | 1/1/1/1           | 2         | **10s**             |
| IBFT 2.0 | 35          | yes (35 = 35)         | all 4 Running    | 1/1/0/0           | 2         | **82s**             |

The **Peers** column is each validator's `net_peerCount` during the halt, written
in validator-number order `v1/v2/v3/v4`. So `1/1/0/0` means validator1 and
validator2 each kept 1 peer while validator3 and validator4 had 0. A healthy
4-node mesh is 3 peers each; the `[1,2] | [3,4]` split caps every node at its one
same-side partner (→ 1), and a node drops to 0 when even that partner was never a
live peer (the IBFT 2.0 case below).

**QBFT:**

- **Halts, does not split-brain.** With `[1,2] | [3,4]` partitioned the chain
  froze at block 66 for the full 45s window; both sides reported the **same**
  height (66) throughout and RPC answered on every node — no fork, nothing to
  reconcile.
- **All four pods stayed `Running`.** Kubernetes saw a fully healthy deployment
  while the network was dead. Peer counts collapsed to **1 on every validator**
  (each saw only its same-side partner) as the cross-partition RLPx connections
  timed out — pod health never changed.
- **Round-change backoff visible in the logs**, the same mechanism as quorum
  loss: `RoundTimer | Moved to round 2 which will expire in 40 seconds` and
  `RoundChangeManager | BFT round summary (quorum = 3)` on the side-A validators
  while they proposed without ever reaching quorum (round climbed to 2 over the
  ~57s partition).
- **Recovery on heal was automatic and fast: 10s** to the first block above the
  halt height after flushing the DROP rules — no pod restart, no manual
  intervention, no divergence. Fast because the partition was short (round only 2)
  *and* healing reconnects four already-running, already-in-sync nodes — unlike
  quorum loss, where recovery also waits for restarted validators to resync.

**IBFT 2.0:**

- **Identical invariants — halt, no fork, pods all `Running`.** Chain froze at
  block 35 for the full window; both sides stayed at 35 with RPC alive; round
  climbed to 2 (`Moved to round 2 which will expire in 40 seconds`).
- **Peer collapse was 1/1/0/0, not 1/1/1/1** — i.e. validator1 = 1 peer,
  validator2 = 1, validator3 = 0, validator4 = 0. Side B (validators 3, 4) dropped
  to **0** peers rather than 1. This is the IBFT 2.0 cold-start peering lag scenario
  01 documents: at baseline the mesh had not fully formed (validators 2–4 each had
  only 1 peer, all pointing at validator1), so once validator1 was partitioned
  away, the side-B pair had no surviving link to fall back on. The collapse is
  still symmetric in effect (each side isolated), just starting from a sparser
  mesh.
- **Recovery on heal was slower: 82s** vs QBFT's 10s, though both climbed only to
  round 2. The gap is timing plus engine cadence: the heal landed early in a fresh
  40s round-2 timer (two round-2 entries logged, the second ~7s before heal), and
  IBFT 2.0's slower proposer/round-change startup — the same tendency seen in
  scenario 01 — meant the set waited out that timer and re-established the sparser
  mesh before committing. Still fully automatic, no restart, no divergence.

**Consensus comparison.** The *invariants* are engine-independent: both halt at
the last committed block, neither forks, both leave every pod `Running`/`Ready`,
both show the round-change backoff, and both recover automatically on heal with no
restart. The only difference was recovery latency (QBFT 10s vs IBFT 2.0 82s),
which tracks IBFT 2.0's slower round-change/proposer startup and a less-settled
peer mesh — consistent with scenario 01, and not a different recovery behaviour.
As in quorum loss, a longer partition would climb to higher rounds and inherit the
same superlinear backoff curve scenario 01 measured.

**Peer-mesh lag on heal** reproduced on both engines: validators re-established the
full mesh over the following minutes (some nodes still at 1 peer immediately after
recovery while others climbed back to 2–3) — the same monitoring caveat as
scenario 01 (peer-count alerts false-positive right after a topology change).

## Variations

- **Asymmetric split `[1,2,3] | [4]`** — the majority side keeps quorum (3 of 4)
  and should keep producing while the lone validator is isolated; tests "does a
  minority partition stall the majority?" (it should not).
- **Partition during a pending transaction** — submit a tx, then partition;
  confirm it neither commits nor is lost, and mines after heal. Needs a
  signing-capable client.
- **Heal by restart vs heal by flush** — compare automatic recovery after
  flushing the rules (no restart) against recovery after recreating the pods, to
  separate "partition healed" from "nodes restarted."

## Runbook entries fed by this scenario

- [Chain halted, all pods Running/Ready, validators split (network
  partition)](../../runbook/03-chain-halted-network-partition.md).
