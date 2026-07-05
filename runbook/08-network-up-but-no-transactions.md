# Network "up" but no transactions accepted (permissioning lockout)

> Backed by scenario:
> [`08-permissioning-outage`](../scenarios/08-permissioning-outage/). Verified on
> chart 0.3.3 (Besu 26.6.1): emptying the allowlist locked out the operational
> account (`-32007`) while the chain kept producing blocks, and re-adding it on
> all four validators cleared the outage with no restart.

## Symptom

- **Every** `eth_sendRawTransaction` is rejected with
  `error code -32007: Sender account not authorized to send transactions` —
  including from accounts that worked a moment ago.
- **Block height is still climbing** and all validator pods are `Ready`. Naive
  "is the chain up?" checks are green.
- No user transaction gets through; the chain is producing **empty** blocks.

This is the authorization-layer analogue of [quorum loss](02-chain-halted-quorum-loss.md):
there the chain halts; here the chain runs but is **frozen for users**. It is
worse for monitoring because even block production looks healthy.

## Likely Causes

Ordered by likelihood:

1. **The operational account was removed from the account allowlist** — a wrong
   admin change (intending to offboard a departed member, removed the wrong
   address) or a script targeting the wrong account.
2. **The allowlist was cleared / deployed empty** — a bad config rollout pushed
   an empty `permissioning.accounts.allowlist`, or a file edit emptied it.
3. **Allowlist change applied to only some validators** (file-based `perm_*` is
   per-node, in-memory) → intermittent `-32007` depending on which node received
   the submission / proposed the block.
4. **A node restart reverted an in-memory `perm_add`** that was never written to
   the source file.

## Diagnosis Steps

```sh
# Confirm it's authorization, not consensus: height IS advancing, but every send
# returns -32007.
kubectl -n <ns> exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://<release>-rpc-unified:8545      # climbing

# Inspect the allowlist — empty or missing your operational account is the smoking gun.
# Check EVERY validator (state is per-node for file-based):
for n in 1 2 3 4; do
  kubectl -n <ns> exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"perm_getAccountsAllowlist","params":[],"id":1}' \
    http://<release>-validator${n}:8545
done

# Rule out the balance gate: a funded sender that is denied at SUBMISSION (-32007,
# never pooled) is permissioning, not funds.
cast balance <sender> --rpc-url <rpc>
```

## Recovery Procedure

1. **Restore the allowlist on every validator** (verified: re-adding the
   operational account cleared the outage immediately, no restart):
   ```sh
   for n in 1 2 3 4; do
     kubectl -n <ns> exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","method":"perm_addAccountsToAllowlist","params":[["<account>"]],"id":1}' \
       http://<release>-validator${n}:8545
   done
   ```
   File-based permissioning's `perm_*` methods are an **RPC escape hatch** — they
   recover even a total lockout without a restart, because they are node-admin
   operations, not transactions.
2. **Persist it** — also fix the source allowlist (ConfigMap → staged file) so
   the change survives pod restarts; an in-memory-only fix silently reverts.
3. **Do not restart validators to "fix" it** — restarting reloads the allowlist
   from the (still-broken) source file and changes nothing; it only adds downtime.

> Note: Besu also _used_ to offer onchain (smart-contract) permissioning, whose
> lockout would have had **no** `perm_*` escape hatch (recovery via an admin
> transaction that is itself blocked). It was **removed from Besu in 25.6.0** (PR
> [besu#8597](https://github.com/hyperledger/besu/pull/8597)), so on current Besu
> file-based is the only built-in account permissioning — and its RPC escape hatch
> above is the recovery path.

## Prevention

- **Alert on transaction admission, not just block height.** Track the `-32007`
  rejection rate and "pending-tx throughput = 0 while height climbs". Height
  alone is the false-comfort signal.
- **Treat allowlist changes as privileged, reviewed, atomic, and audited** — like
  the validator set ([scenario 04](../scenarios/04-validator-governance/)). Apply
  to all validators together and write to the durable source.
- **Never let the allowlist reach empty** — validate that the operational /
  treasury accounts are always present before applying a change; reject empty
  allowlists in CI.
- **For M-of-N governed control of who may transact, do it at the application
  layer** (a gating contract your dApps call). Besu's built-in onchain
  permissioning is gone (removed 25.6.0), so don't plan around it; the
  client-level control on current Besu is the file-based allowlist.

## Post-Incident

- Record which accounts were removed, by whom/what, and on which validators
  (per-node state often explains a partial vs total outage).
- If the cause was an empty/wrong deploy, add an allowlist-non-empty + operational
  -accounts-present check to the deploy pipeline.
- Capture the duration: how long users were frozen while the chain "looked up" —
  that gap is the value of the height-plus-admission monitoring change.
