# New/member node won't sync (genesis / config mismatch)

> Backed by scenario: [`10-genesis-config-drift`](../scenarios/10-genesis-config-drift/).
> Verified on chart 0.3.3 (QBFT, Besu 26.6.1, kind): a joiner with a drifted `chainId`
> stayed at height 0 with 0 useful peers for the whole window while the network advanced;
> the identical joiner with the correct genesis full-synced 7,060 blocks to head in 10s.

## Symptom

- A newly-deployed node (a new member's validator/RPC node, or a redeployed one) stays at
  block 0 (or far behind) and never catches up.
- It reports no useful peers despite bootnodes/static-nodes pointing at live validators;
  the log shows `Unable to find sync target. Waiting for N peers minimum. Currently
  checking 0 peers for usefulness`.
- The rest of the network is healthy and advancing; only the new node is stuck.

## Likely Causes

Ordered by likelihood when onboarding a member in a consortium (each org runs its own
node, so configs drift):

1. **`chainId` / network-id mismatch.** The node's genesis has a different `chainId` than
   the network. The eth-subprotocol handshake compares network id + genesis hash, so
   every peer is rejected as "a different network."
2. **Genesis hash mismatch** from any genesis difference (`alloc`, `extraData` (validator
   set), `gasLimit`, timestamp) even if `chainId` matches. Same effect: peers on a
   "different network."
3. **Fork-block drift** (e.g. a `londonBlock` present on one side, absent on the other).
   The nodes agree up to the fork height, then diverge, the subtlest variant, often
   surfacing later as an import/validation failure rather than a clean no-peer state.
4. **Genuinely can't reach peers** (DNS/bootnodes wrong, `--Xdns-*` off so DNS-based
   enodes are rejected): a connectivity problem, not config drift; distinguish via the
   logs (handshake-reject vs connection-refused).

## Diagnosis Steps

```sh
# The stuck node: height not climbing, no useful peers
cast block-number --rpc-url <new-node-rpc>            # stays 0 / far behind
kubectl -n besu logs <new-node> | grep -iE 'usefulness|different|network|genesis|fork'
# Besu's startup banner also names the identity it booted with: "Network Id: …"

# Compare the genesis the node booted from against the canonical one
kubectl -n besu exec <new-node> -- sh -c 'sha256sum /etc/genesis/genesis.json'
kubectl -n besu get configmap sbx-genesis -o jsonpath='{.data.genesis\.json}' | sha256sum
# differing hashes = config drift; eyeball chainId / forks / extraData

# Confirm the rest of the network is fine (rules out a network-wide fault)
kubectl -n besu exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://sbx-rpc-unified:8545
```

A stuck node + healthy network + a different genesis hash is conclusive: it's config
drift, not the network.

## Recovery Procedure

1. **Reconcile the genesis to the canonical one.** Redeploy the node with the exact
   `chainId`, fork blocks, `extraData`, and `alloc` of the network (same `genesis.json`
   byte-for-byte). There is no fix on the running network; a mismatched joiner can't be
   made to sync without correcting its own config.
2. **Wipe its data and let it resync.** A node that booted a different genesis has block
   0 = a different hash on disk; clear its data volume before restarting with the correct
   genesis, or it will refuse to start (genesis mismatch with its existing chaindata).
3. **Verify peering** once corrected: peer count climbs and height catches up to head (in
   the verified run a correct-genesis joiner reached head, 7,060 blocks, in 10s). With
   DNS-based enodes, ensure `--Xdns-enabled` / `--Xdns-update-enabled` are set (otherwise
   DNS enodes are rejected outright).

## Prevention

- Distribute one canonical `genesis.json` (and pin its hash) to every member; treat
  it as immutable config. A genesis-hash check in CI/onboarding catches drift before
  deploy.
- Version genesis with the chart so a member can't accidentally hand-edit
  `chainId`/forks. (This chart ships genesis in a ConfigMap derived from values; drift
  comes from a member changing those values, not from the chart.)
- Don't change `chainId` or forks on a live network. Genesis is immutable; changing
  it means a new network and a full reset for everyone.

## Post-Incident

- Record the drifted field(s) (`chainId`/fork/`extraData`) and the two genesis hashes;
  they identify exactly what diverged.
- If a member self-managed their genesis, move them onto the distributed canonical file
  so it can't recur.
