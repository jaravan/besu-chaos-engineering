# Erratic block times / periodic stalls (degraded validator)

> Backed by scenario: [`03-slow-peer`](../scenarios/03-slow-peer/) — entries are
> added only after the recovery procedure has been executed and verified against
> a real network. Verified on **both QBFT and IBFT 2.0** (chart 0.2.3): the cliff
> appears once egress latency exceeds `requesttimeoutseconds`, the slow node's
> proposer slots commit at `Round=1`, and recovery is immediate when the
> degradation clears.

## Symptom

- Block production is **advancing but lumpy**: most blocks land on the normal
  cadence, then one block takes ~`requesttimeoutseconds` (≈10s here) before the
  next arrives, in a repeating pattern.
- Every validator pod is `Ready`; nothing is down. RPC works on the healthy
  nodes. **No alert fires** unless you alert on inter-block time / round number.
- One validator may be slow or unresponsive on RPC, and its peers may report
  retransmits or dropped connections to it.

The pattern repeats roughly every Nth block because the BFT engine rotates the
proposer (QBFT and IBFT 2.0 alike): the stall lands on the slots where the
degraded validator is the round-0 proposer and the round has to time out and
change to a healthy proposer.

## Likely Causes

Ordered by frequency in practice:

1. **One validator's network is degraded** — an underprovisioned node, a
   saturated NIC, or a WAN link between organisations/zones with high latency or
   loss. Its consensus messages arrive late.
2. **CPU/IO starvation on one validator** (noisy neighbour, throttled limits,
   slow disk) delaying its proposal/signing — same consensus symptom, different
   root cause.
3. **Asymmetric degradation** (egress slow, ingress fine, or vice versa): the
   node may still _follow_ the chain perfectly while failing as a _proposer_,
   which is why height-per-node can look healthy even though that node never
   successfully proposes.

## Diagnosis Steps

```sh
# The signature: blocks committing at Round > 0. Healthy round-0 blocks log on a
# plain "Imported #N" line (no round); a proposer slot that timed out and
# round-changed logs a separate "Importing ... block to chain ... Round=N" line.
# The text differs by engine (QBFT: "Importing proposed block to chain";
# IBFT 2.0: "Importing block to chain"), so match either — a recurring hit means
# round-changes are happening, and the Sequence values show which slots.
kubectl -n besu logs sbx-validator1-0 --since=120s \
  | grep -E 'Importing (proposed block|block to chain)' \
  | sed -E 's/.*(Sequence=[0-9]+, Round=[0-9]+).*/\1/'
# e.g. a recurring Round=1 every few sequences, on one proposer's slots

# Which validator is the laggard? Compare per-node height and peer count; the
# degraded node may be unreachable on RPC or behind.
for n in 1 2 3 4; do
  kubectl -n besu exec chaos-probe -- curl -s -m 5 -X POST \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://sbx-validator${n}:8545
done

# Confirm it is the network/infra of one node: latency/loss to peers, NIC and
# CPU saturation, disk latency.
kubectl -n besu exec sbx-validator4-0 -- /bin/sh -c 'true'   # then ping/iperf to a peer
kubectl top pod -n besu                                       # CPU/mem pressure
```

The decisive signal is **recurring `Round>0` commits on the same proposer's
slots** combined with **one node that is slow/unreachable**. Block height still
advancing rules out [quorum loss](02-chain-halted-quorum-loss.md).

## Recovery Procedure

1. **The chain is not down — do not panic-restart validators.** It is producing
   on 3-of-4; restarting the healthy ones only risks dropping below quorum.
2. **Fix the degraded node's underlying cause** — relieve the network/CPU/IO
   pressure, move it off a saturated node, or repair the WAN link. As soon as
   its message latency drops back under `requesttimeoutseconds`, its proposer
   slots stop timing out and block times return to normal.
3. **If the node cannot be fixed quickly and the lumpy cadence is unacceptable**,
   the honest options are operational, not magic:
   - Restart/reschedule that one validator onto healthy infrastructure (it
     resyncs as a follower; with egress-only degradation it was never actually
     behind).
   - Accept the degraded cadence until the infra is fixed — the chain is safe,
     just slower on that proposer's slots.
4. **Do not treat "its RPC is unreachable" as "the node is down."** A node whose
   egress is slow can be invisible on RPC while still following the chain; its
   recovery is immediate once the degradation clears (verified: gap returned to
   0 the instant the shaping was removed, no catch-up).

## Prevention

- **Alert on inter-block time and on `Round>0` commits**, not just on height
  advancing. A degraded validator keeps the chain moving, so plain liveness
  looks fine; the round number is what exposes it.
- **Capacity-plan validators for their consensus role**, including the WAN path
  between organisations. The tolerance is set by `requesttimeoutseconds` — keep
  worst-case inter-validator message latency comfortably under it.
- **Know that one degraded validator removes your fault tolerance.** At N=4 the
  healthy three are exactly quorum; a slow node plus one more fault is a halt.
  Treat a persistently degraded validator as an urgent (if quiet) issue.
- **Tuning `requesttimeoutseconds` is a trade-off**, not a fix: raising it
  tolerates slower links but lengthens every real round-change (and the
  [quorum-loss](02-chain-halted-quorum-loss.md) recovery curve); lowering it
  makes the network twitchier under jitter.

## Post-Incident

- Preserve the `Importing ... block to chain ... Round=N` lines (QBFT
  "Importing proposed block to chain", IBFT 2.0 "Importing block to chain")
  showing which proposer's slots round-changed — that identifies the degraded
  validator precisely.
- Record the measured inter-validator latency/loss and compare it to
  `requesttimeoutseconds`, so the capacity/SLO for that link is grounded in the
  observed cliff rather than a guess.
