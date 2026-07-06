# Changing the validator set (offboard / onboard a member)

> Backed by scenario: [`04-validator-governance`](../scenarios/04-validator-governance/).
> Verified on both QBFT and IBFT 2.0 (chart 0.3.3, Besu 26.6.1): a majority vote removed
> a validator in ~9s and re-added it in ~6s, no restart and no pause in block production;
> a standing proposal proved in-memory only, dropped on a node restart but not expired by
> the epoch boundary. The mechanism is engine-independent (substitute `ibft_` for `qbft_`
> below).

## Symptom

Either an intended operation or an unexpected event:

- **Intended:** you need to permanently remove a validator (a member left, or a node is
  dead and won't return, the durable fix after the transient
  [validator down](01-validator-down-network-healthy.md)) or add one (a new member's
  validator joins).
- **Unexpected:** `qbft_getValidatorsByBlockNumber` shows the set changed, a validator
  appeared or disappeared, with no planned change. That means votes reached a majority,
  intentionally or not.

## Likely Causes

For an _unexpected_ change, ordered by likelihood:

1. **Votes reached majority.** Someone cast `qbft_proposeValidatorVote` on enough nodes
   (> 50% of the current validators) for the same address; the engine applied it at a
   block boundary.
2. **Automation / config management** re-applying a vote on several nodes at once (an
   onboarding script targeting the wrong address, or run against more nodes than
   intended).
3. **Stale standing proposals** that were never discarded crossing the threshold after
   another change shifted the validator count.

## Diagnosis Steps

```sh
# Current set and size
kubectl -n besu exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://sbx-validator1:8545

# Who is proposing. getSignerMetrics gives a proposedBlockCount per signer, but the
# default (no-args) value is a NOISY sliding window that drifts +/-1 — pass an
# explicit [from,to] block range for a meaningful count, or read recent blocks'
# .miner directly (see the header forensic below) for the precise current proposers.
kubectl -n besu exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"qbft_getSignerMetrics","params":[],"id":1}' \
  http://sbx-validator1:8545

# Standing votes that could still apply — check on EACH validator (votes are
# per-node); a non-empty result is a pending change
for n in 1 2 3 4; do
  kubectl -n besu exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"qbft_getPendingVotes","params":[],"id":1}' \
    http://sbx-validator${n}:8545
done
```

(IBFT 2.0: replace `qbft_` with `ibft_` in every method above.)

### Who voted — and what you can see from where

`getPendingVotes` returns only the queried node's own standing proposals; a vote cast on
one validator is invisible from another. So how you find "who voted" depends on which
nodes you operate:

- You run the whole set (lab / single-org cluster). Poll `getPendingVotes` on every
  validator and union the results; that gives each node's current outgoing intent. (The
  `for n in 1 2 3 4` loop above.)
- You run one node (real consortium). You cannot reach the other orgs' RPC, but you
  don't need to. Every vote is on-chain, replicated to your node: each block's `miner` is
  its proposer (the voter), and the vote rides in the block's `extraData`. Reconstruct
  the change from your own node alone:

```sh
# 1. Pin the block where the set changed (binary-search by block number):
qbft_getValidatorsByBlockNumber("0x<n>")        # find where size goes 4 -> 3

# 2. Read the votes out of the headers just before that block:
eth_getBlockByNumber("0x<n>", false)            # → .miner (the voter) and .extraData
```

In `extraData` the vote is RLP `[recipient, type]`, appearing as
`d694<20-byte-address><type>` where `<type>` is `80` = DROP on QBFT, `00` = DROP on
IBFT 2.0 (an empty vote field is `c0` on QBFT, `80` on IBFT 2.0). A non-empty vote in a
block means that block's `miner` voted on that address. The on-chain record is
authoritative and complete for anything that affects the tally: a forgotten vote that
vanished from `getPendingVotes` (restart, see Prevention) but was already stamped into a
header is still visible here.

## Recovery Procedure

Votes are cast per node (each validator votes on its own RPC) and apply when more than
half of the current validators agree. Verified timing on this network: the change
applied a few blocks (~6–9s) after the majority vote, with no restart and no pause in
block production.

**To remove a validator `X` (e.g. a dead member):**

```sh
# On a MAJORITY of the CURRENT validators (3 of 4, 3 of 5, 2 of 3 …):
qbft_proposeValidatorVote(X, false)        # on validatorN's own RPC, for each chosen N
# Poll until the set drops and X is gone:
qbft_getValidatorsByBlockNumber("latest")
# Then DISCARD the now-applied proposal on each voter so the tally is clean:
qbft_discardValidatorVote(X)
```

Keep `N` after removal at or above your fault-tolerance target; removing down to 3
leaves quorum 2 (zero fault tolerance). Do not remove two at once toward a sub-quorum
set: that is [quorum loss](02-chain-halted-quorum-loss.md).

**To add a validator `X` (onboard a member's node):**

```sh
# Ensure X's node is running, synced, and peered FIRST.
qbft_proposeValidatorVote(X, true)         # on a majority of current validators
qbft_getValidatorsByBlockNumber("latest")  # poll until X appears
qbft_discardValidatorVote(X)               # clear the applied proposal
```

**To revert an unwanted change:** cast the opposite vote on a majority (and discard any
standing proposals that caused it). The set change is reversible with no restart, as
verified.

## Prevention

- Audit and restrict `proposeValidatorVote`. A majority casting the same vote
  silently changes consensus membership. Restrict who can reach validator RPC; log every
  vote.
- Discard after every applied change. An undiscarded standing proposal can re-trigger
  a change later when the validator count shifts. Make `discardValidatorVote` part of
  every vote.
- `discardValidatorVote` is not an undo. It stops a node re-stamping, but a vote
  already written into a header keeps counting toward the tally for the rest of the epoch.
  To reverse an in-flight change, cast the opposite vote on a majority.
- Standing proposals are in-memory per node. A pending vote is dropped when its node
  restarts (upgrade, crash, reschedule) and is not persisted, so `getPendingVotes` shows
  only each node's current intent. Check it on every validator, and re-check after any
  restart during a change. A reboot still rebuilds the correct set from the chain; the
  node only forgets its own pending vote.
- Never drop below your quorum/fault-tolerance target. Plan set-size changes so quorum
  holds at every intermediate step.
- Onboard before voting in. Vote `add` only once the new node is running, synced, and
  peered, or it joins as a non-producing member.
- Funding is separate from membership. A new member's validator is governed here;
  their wallet must also hold a balance to transact (on a free-gas chain a never-funded
  account's transactions are accepted but never mined).
- `epochlength` does not gate application. Contrary to some third-party guides, a
  change applies the moment a majority agrees (verified 9–12s on a 30000-block epoch), not
  at the epoch boundary. The epoch is a periodic vote-tally reset (Besu: _"the number of
  blocks after which to reset all votes"_), not an application delay; shortening it does
  not speed validator rotation.

## Post-Incident

- Record which addresses were voted, by which validators, and the block at which the
  change applied. You can reconstruct all of this from a single node's chain data: pin
  the boundary with `getValidatorsByBlockNumber`, then read each preceding block's
  `miner` (voter) and `extraData` (vote) per the forensic above.
- Confirm `getPendingVotes` is empty on every validator you operate afterwards; a
  lingering proposal is a latent future change.
- If the change was unexpected, the header forensic tells you which validators stamped
  the votes; then chase how those votes were cast (RPC access, automation) before
  reverting.
