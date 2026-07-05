# Scenario 10 — Genesis / Config Drift (the member node that won't sync)

Every scenario so far broke something that was _in_ the network — a validator
([01](../01-validator-loss/)–[05](../05-duplicate-validator/)), a transaction
pipeline ([06](../06-txpool-flooding/)–[08](../08-permissioning-outage/)), a
data volume ([09](../09-snapshot-restore/)). This one is about the node that
never manages to get in. In a consortium each member deploys their own node
from their own config repo, so configuration **drifts** — and the everyday
onboarding incident is a new member's node that starts fine, dials the right
peers, and then sits at **block 0 forever**. Nothing is down; nothing errors
loudly; the node is simply on a different network and nobody told the
operator.

**Consensus:** engine-independent (**QBFT · IBFT 2.0**). The gate sits _below_
consensus: after the devp2p (RLPx) connection, the eth-subprotocol handshake
exchanges network id and genesis hash, and a peer whose identity differs is
disconnected as "a different network" before a single block or consensus
message is exchanged. The running network is a bystander throughout.

## Hypothesis

A node booted from a genesis that doesn't match the network — a different
`chainId`, fork block, or validator set in `extraData` — **cannot join**:
every peer rejects it at the eth handshake, so it reports no useful peers and
stays at block 0, while the running network is completely unaffected (a
wrong-genesis joiner can't poison it; it is simply ignored). The fix is
config reconciliation on the joiner — there is nothing to recover on the
network side.

Two steps, and the control comes first for a reason:

- **STEP 1 — control.** The same throwaway joiner pod, booted from the
  network's **real** genesis, must peer and full-sync to head. This pins the
  wiring (image, DNS enodes, bootnodes) as working, so STEP 2's failure
  isolates the genesis as the **only changed variable** — without it, "stuck
  at block 0" could be blamed on the pod, not the config.
- **STEP 2 — drift.** The identical joiner booted from the network's genesis
  with one field drifted (`chainId` → `DRIFT_CHAINID`) must stay at block 0
  with no sync progress and log the operator-facing signal.

## Method

The joiner is a standalone member/RPC node (auto-generated key, not a
validator) that dials the real network. Everything it needs is **read from
the running network, not assumed**: the Besu image and the `--bootnodes`
enode list are taken from the live validator1 pod, so the joiner always
matches the deployed Besu version and dials exactly what the network dials
(`--Xdns-*` on, since the chart's enodes carry pod DNS names). The drifted
genesis is derived from the chart's own `<release>-genesis` ConfigMap with
`chainId` rewritten, into a throwaway ConfigMap that is removed on exit.

```sh
make scenario-10                    # STEP 1 (control) then STEP 2 (drift)
make scenario-10 STEP=2             # drift only
make scenario-10 DRIFT_CHAINID=99   # drift to a different chainId
```

Assertions: the control joiner must reach head (gap ≤ `CATCHUP_GAP`, default 10) within `CONTROL_TIMEOUT` (default 180s); the drift joiner must still be
at height ≤ 1 after `DRIFT_SETTLE` (default 75s); the main network must be
advancing before, during, and after. Cleanup removes the joiner pod and the
drift ConfigMap.

## Expected

- **STEP 1:** the joiner peers and full-syncs to head — on a young chain in
  seconds, which is itself a useful onboarding RTO reference.
- **STEP 2:** the drift joiner starts Besu normally (a drifted genesis is
  still a _valid_ genesis — it boots its own one-node network of one), dials
  the validators, and is rejected at the eth handshake by every one of them:
  **0 useful peers, height 0**, and a log that says so
  (`Unable to find sync target … checking 0 peers for usefulness`).
- **The main network never notices.** No round-changes, no stalls — the
  mismatched joiner is invisible to consensus.

## Observed

Verified against the [besu-sandbox](https://github.com/jaravan/besu-helmcharts)
chart (**0.3.1**, Besu 26.6.0, QBFT, 2s block period) on kind
(`kind-besu-chaos`), drifting `chainId` 1337 → 1337001:

- **STEP 1 — control:** the joiner full-synced **1,921 blocks from genesis in
  10s** (gap 0, 2 peers) — wiring proven, and a concrete onboarding
  time-to-sync datapoint for a young chain.
- **STEP 2 — drift:** the identical pod with the drifted genesis stayed at
  **height 0, 0 peers** for the full 75s window while the main network
  advanced past head 1960. Besu's startup banner names the drifted identity
  (`Network Id: 1337001`) and the log shows the operator-facing signal:
  `Unable to find sync target. Waiting for 1 peers minimum. Currently
checking 0 peers for usefulness` — dialing succeeds, the handshake doesn't.
- **The main network was unaffected throughout** — advancing at baseline,
  during the drift window, and after teardown.

The diagnostic shape an operator should recognize: a new node **stuck at
block 0 with no useful peers while the rest of the network is healthy** is
almost always a genesis/`chainId`/fork mismatch against the canonical
genesis — a config problem on the joiner, not a network fault. One hash
comparison settles it (see the
[runbook entry](../../runbook/10-member-node-wont-sync-genesis-mismatch.md)).

## Variations

- **Drift the validator set (`extraData`)** instead of `chainId`: the genesis
  _hash_ still differs, but this is the drift a member most plausibly
  introduces by regenerating genesis from different values.
- **Drift a fork block** (e.g. a `londonBlock` difference): the nodes agree
  until the fork height, then diverge — the subtlest variant, surfacing later
  as import/validation failures rather than a clean no-peer state.

## Runbook entries backed by this scenario

- [New/member node won't sync (genesis / config mismatch)](../../runbook/10-member-node-wont-sync-genesis-mismatch.md)
