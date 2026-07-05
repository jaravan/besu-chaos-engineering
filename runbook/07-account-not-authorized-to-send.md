# Transactions denied by account permissioning (not authorized to send)

> Backed by scenario:
> [`07-account-permissioning`](../scenarios/07-account-permissioning/). Verified on
> chart 0.3.3 (Besu 26.6.1): a funded-but-not-allowlisted account was denied with `-32007`,
> allowlisting it on all four validators let it mine (nonce 0 → 1), and removing it
> denied again.

## Symptom

- A client's `eth_sendRawTransaction` is **rejected immediately** with
  `error code -32007: Sender account not authorized to send transactions`.
- The transaction **never appears as pending** and the sender's nonce does **not**
  advance — it was refused at the RPC, not queued.
- Block production and other accounts are unaffected.

This is distinct from the [zero-balance / stuck-pending](06-transactions-rejected-or-stuck-pending.md)
case, which _accepts_ the transaction (returns a hash) and then never mines it.
Here the submission itself is refused.

## Likely Causes

Ordered by likelihood on a permissioned network:

1. **The sender is not on the account allowlist.** Account permissioning is
   enabled (`permissions-accounts-config-file-enabled` — the file-based allowlist;
   Besu's onchain/contract permissioning was removed in 25.6.0) and the `from`
   address is not permitted.
2. **A new participant was funded but never allowlisted.** Authorization and
   funding are independent gates; onboarding did the balance half but not the
   permissioning half (or vice-versa).
3. **An allowlist change did not reach every validator.** With local (file-based)
   permissioning, `perm_*` changes are **per-node, in-memory** — if applied to
   only some validators, the receiving/proposing node may still reject.
4. **A node restarted and reverted to the file baseline**, dropping a runtime
   `perm_addAccountsToAllowlist` that was never written to the file.

## Diagnosis Steps

```sh
# The error itself is definitive (-32007). Confirm whether the sender is allowed:
kubectl -n <ns> exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"perm_getAccountsAllowlist","params":[],"id":1}' \
  http://<release>-validator1:8545
# -> is the sender's 0x address in the list? (check on EACH validator — state is per-node)

# Rule out the balance gate (a funded sender that is still denied = permissioning,
# not funds):
cast balance <sender> --rpc-url <rpc>      # non-zero, yet denied => authorization

# Confirm permissioning is actually on (vs some other -32xxx):
kubectl -n <ns> get configmap <release>-config-toml -o yaml | grep -i permissions-accounts
```

## Recovery Procedure

1. **Allowlist the sender on every validator.** Authorization changes are
   per-node, so apply to all (verified: adding on all four validators let the
   previously-denied funded account mine; removing on all denied it again):
   ```sh
   for n in 1 2 3 4; do
     kubectl -n <ns> exec chaos-probe -- curl -s -X POST -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","method":"perm_addAccountsToAllowlist","params":[["<sender>"]],"id":1}' \
       http://<release>-validator${n}:8545
   done
   ```
   The change is immediate — no restart; the next submission from the sender
   mines.
2. **Persist it.** `perm_add/removeAccountsToAllowlist` are **in-memory** — also
   update the allowlist file (the ConfigMap → staged writable copy) so the change
   survives a pod restart, or it will silently revert.
3. **Remember the other gate.** If the sender is now allowlisted but still does
   not mine, it is probably **unfunded** — see
   [transactions rejected / stuck pending](06-transactions-rejected-or-stuck-pending.md).

## Prevention

- **Make allowlisting part of onboarding, alongside funding.** A new participant
  needs **both**: allowlisted (this) **and** a non-zero balance (scenario 06).
  Document and automate both in one step.
- **Apply allowlist changes to all validators atomically**, and **write them to
  the source file** so they survive restarts — don't rely on in-memory `perm_*`
  alone. (Onchain/contract permissioning, which would have persisted on-chain, was
  removed from Besu in 25.6.0 — file-based is the only built-in option.)
- **Alert on a spike of `-32007`** at the RPC edge: it usually means a legitimate
  client lost (or never had) authorization, or an allowlist change was partial.
- **Treat the allowlist as privileged, audited config**, like the validator set
  ([scenario 04](../scenarios/04-validator-governance/)) — a wrong removal silently
  cuts a member off from transacting.

## Post-Incident

- Record the denied sender, the `-32007` occurrences, and which validators had it
  allowlisted (the per-node state often explains a partial outage).
- If the cause was a restart reverting an in-memory change, fix the source
  allowlist file so it is durable, not just live.
