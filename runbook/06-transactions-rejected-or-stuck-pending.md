# Transactions rejected or stuck pending under load

> Backed by scenario: [`06-txpool-flooding`](../scenarios/06-txpool-flooding/).
> Verified on chart 0.3.1 (Besu 26.6.0, free
> gas): a sender's future-nonce queue filled to the per-sender cap (199 accepted,
> **nonce 200 rejected** with `-32000: nonce is too distant`), filling the gap
> promoted the whole queue (nonce **0 → 200**), and a zero-balance sender's
> accepted-but-unmined tx mined the instant the account received **1 wei**.

## Symptom

One or more of:

- Clients get JSON-RPC errors on `eth_sendRawTransaction` —
  `-32000: Transaction nonce is too distant from current sender nonce`, or a
  pool-full / replacement-underpriced error — and conclude "the chain is down."
- Transactions are **accepted** (a hash comes back) but **never mine** — no
  receipt, the sender's nonce never advances, the tx sits pending indefinitely.
- A backlog of pending transactions that does not drain.

Block height is still advancing the whole time. This is a **transaction-pool /
client-side** problem, not a consensus outage.

## Likely Causes

Ordered by frequency in practice:

1. **A sender hit the per-sender future-nonce cap** (Besu default **200**). A
   transaction whose nonce is above the sender's next executable nonce is held as
   a non-executable "future" tx. With the sender's on-chain nonce `C` (the next
   expected nonce = last-mined + 1), Besu accepts a tx only if **`nonce < C + 200`**
   — the band `[C, C+200)` — and rejects anything beyond it with _"nonce is too
   distant"_. That band is a **sliding window, not a lifetime quota**: as the
   sender's transactions confirm, `C` advances and the band shifts forward, so a
   healthy sender streams far more than 200 over time. You only hit the ceiling
   when futures stack up against it — either `C` **isn't advancing** (nothing is
   mining for that sender), or you are **submitting faster than the band slides**.
   The usual triggers:
   - **a skipped or stuck low nonce** — one nonce never lands, so the executable
     nonce can't advance and everything above it stacks up as futures (elaborated
     in cause 3);
   - **parallel submitters racing nonces** — several workers/processes signing for
     the same account assign overlapping or out-of-order nonces, leaving gaps;
   - **a client firing far ahead of the confirmed nonce** — submitting hundreds
     before earlier ones confirm, outrunning the 200-wide window even while mining
     is healthy.
2. **The sender has zero balance.** Besu's
   [`SenderBalanceChecker`](https://github.com/hyperledger/besu/blob/26.6.0/ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/layered/SenderBalanceChecker.java#L86)
   — part of the layered **transaction pool** — checks each pending tx's sender
   balance against the chain-head world state and holds back any from a zero-balance
   sender: the tx is admitted to the pool (even ranked in it) but never put in a
   block, so it sits pending forever. This bites hardest on a **free-gas**
   network (`min-gas-price=0`), where "no fee" is misread as "no funding needed":
   an unfunded account's tx stays pending and mines only once the account is
   funded, while a _funded_ account's tx mines at `gasPrice: 0`. It is the empty
   balance, not the gas price, that strands the tx. The check is **binary**
   (`balance == 0` vs `> 0`), not "can afford the fee": **1 wei is enough** to
   clear it (verified), and on a free-gas chain that wei is not even spent — so it
   is a one-time onboarding nudge, not ongoing funding. Full evidence and scope:
   [scenario 06, step 6c](../scenarios/06-txpool-flooding/README.md#observed).
3. **A stuck low-nonce transaction blocking the sender's queue.** One
   non-mineable tx at nonce K (e.g. from a sender that was unfunded when it was
   submitted, or genuinely underpriced) makes every higher nonce from that sender
   non-executable; they queue behind it and eventually hit the cap.
4. **Global pool saturation** (the layered pool's memory budget,
   `tx-pool-layer-max-capacity`, ~50 MB) from many senders at once — lowest-priority
   / most-future txs get evicted. Reaching this needs many accounts,
   because the per-sender cap stops any single account from filling the pool.

## Diagnosis Steps

```sh
# Chain is fine? Height advancing rules out a consensus problem.
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://sbx-rpc-unified:8545     # call twice; must increase

# Is the tx accepted-but-pending, or rejected? Compare the sender's confirmed
# nonce (latest) with its pending nonce — a gap means txs are queued, not mined.
cast nonce <sender> --rpc-url <url>                 # latest (mined)
cast nonce <sender> --block pending --rpc-url <url> # includes pending
# nonce not advancing while pending > latest = stuck pending, not mining.

# Inspect a specific stuck tx: a receipt of null but the tx exists = pending.
cast tx <hash> --rpc-url <url>        # blockNumber null => not mined
cast receipt <hash> --rpc-url <url>   # (will not return until mined)

# Is the stuck sender funded? On a free-gas chain a zero-balance sender's tx is
# accepted but never mined. Check the balance; a funded account mines fine even
# at gasPrice 0.
cast balance <sender> --rpc-url <url>     # 0 => that is why it is stuck
```

To see the exact reason from the node, raise the block-selection log level
temporarily (then revert) and look for `SenderBalanceChecker`:

```sh
# enable TRACE on the txpool package where SenderBalanceChecker lives
curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"admin_changeLogLevel","params":["TRACE",["org.hyperledger.besu.ethereum.eth.transactions"]],"id":1}' \
  http://sbx-validator1:8545
kubectl -n besu logs sbx-validator1-0 --since=30s | grep SenderBalanceChecker
#   => "Sender has zero balance for transaction {… gp: 0 wei …}"
# revert to INFO afterwards (same call with "INFO")
```

Note: this network does not enable the `TXPOOL` RPC API
(`rpc-http-api=["DEBUG","ETH","ADMIN","WEB3","QBFT","NET"]`, no `TXPOOL`), so
`txpool_besuStatistics` / `txpool_besuPendingTransactions` are unavailable —
diagnose via nonces and receipts as above. **Why it's off:** Besu's RPC namespaces
are opt-in (anything not listed returns `-32604 Method not enabled`), and the chart
ships a minimal API set; `TXPOOL` is a non-standard Besu diagnostic namespace that
dumps the full pending-tx set (a privacy/exposure surface on a shared endpoint) and
isn't needed for normal client operation, so it's left off. To opt in for richer
visibility, add `TXPOOL` to `rpc-http-api` and **restart** the node (it's a startup
flag, not runtime-toggleable).

### Enabling TXPOOL — what direct pool inspection looks like

If the nonce/receipt diagnosis above isn't enough, enable the `TXPOOL` namespace and
you can read the pool directly. It is **per-node** (each validator has its own pool)
and a **startup flag**, so enable it on the node(s) you intend to query and restart
them — patching the config without a restart changes nothing.

```sh
# add TXPOOL to rpc-http-api (a startup-only config.toml setting):
#   rpc-http-api=["DEBUG","ETH","ADMIN","WEB3","QBFT","NET","TXPOOL"]
# chart 0.3.x checksums config.toml, so a `helm upgrade` rolls all validators one at a
# time to pick it up. To restart a single node instead, delete the pod — the validator
# StatefulSets are OnDelete, so `kubectl rollout restart` does NOT work:
kubectl -n besu delete pod sbx-validator4-0    # one node, beyond quorum
```

Then the `TXPOOL` methods answer (verified on this chart against a validator holding a
stuck future-nonce tx):

```sh
# 1) pool counts
txpool_besuStatistics
#   => {"maxSize":-1,"localCount":1,"remoteCount":0}
#      maxSize -1   = layered pool (Besu default) is memory-bounded, not count-bounded,
#                     so the count cap tx-pool-max-size is N/A here — NOT "unlimited"
#                     (layered defaults: 50 MB/layer, 5000 prioritized, 200 future/sender)
#      localCount   = txs submitted to THIS node;  remoteCount = txs gossiped in from peers

# 2) the actual pending/queued transactions (full tx objects)
txpool_besuPendingTransactions          # optional integer arg caps the count, e.g. [10]
#   => [{ "hash":"0x9793…", "from":"0x57f2…", "nonce":"0xce",   # 0xce = 206
#         "to":"0x…dead", "gasPrice":"0x0", "value":"0x0",
#         "blockHash":null, "blockNumber":null,                 # null => not mined (pending)
#         … }]

# 3) a compact view — one line per tx (hash, where it came from, when it entered)
txpool_besuTransactions
#   => [{"hash":"0x9793…","isReceivedFromLocalSource":true,"addedToPoolAt":"2026-…Z"}, …]
#      isReceivedFromLocalSource: true = submitted here; false = gossiped in from a peer
```

Reading it: `blockNumber: null` confirms the tx is **in the pool, not mined**; comparing
its `nonce` to the sender's confirmed nonce (`cast nonce <sender>`) tells you whether it
is *executable* (next in line) or a *future* tx behind a gap — the example's `nonce`
0xce (206) sat ahead of the sender's confirmed 201, i.e. a future tx stuck behind the
missing 201–205. For a full network picture, enable TXPOOL on every validator and query
each (the pool is per-node); revert by removing it from `rpc-http-api` and restarting,
since a node restart also clears the in-memory pool.

The layered-pool defaults referenced above (50 MB/layer, 5000 prioritized, 200
future-per-sender) are Besu's, from
[`TransactionPoolConfiguration`](https://github.com/hyperledger/besu/blob/26.6.0/ethereum/eth/src/main/java/org/hyperledger/besu/ethereum/eth/transactions/TransactionPoolConfiguration.java)
(`DEFAULT_PENDING_TRANSACTIONS_LAYER_MAX_CAPACITY_BYTES`,
`DEFAULT_MAX_PRIORITIZED_TRANSACTIONS`, `DEFAULT_MAX_FUTURE_BY_SENDER`; `LAYERED` is
`DEFAULT_TX_POOL_IMPLEMENTATION`), pinned to the version this chart runs.

## Recovery Procedure

1. **Do not restart validators.** The chain is producing; this is a client/pool
   issue and node restarts do not help.
2. **Stuck-pending because the sender has zero balance:** the tx will not mine
   until the account holds any balance. **Send the sender a tiny amount** — even
   **1 wei** is enough (verified: the moment a 1-wei transfer landed, the
   previously-stuck tx mined, nonce 0 → 1, no resubmission needed; on a free-gas
   chain the wei is not spent). (If instead the tx is genuinely underpriced for
   the chain's policy, resubmit at the **same nonce** with an acceptable gas
   price — a "replacement" must exceed the old one by the pool's bump threshold.)
3. **Rejected with "nonce too distant" (future-cap hit):** the client is running
   ahead of the executable nonce. Fix the **gap** — submit the missing low nonce
   so the queue drains (verified: filling the gap promoted all 199 queued txs and
   they mined in order, nonce 0 → 200). Then have the client throttle / track
   confirmed nonce instead of firing 200+ ahead.
4. **Global saturation (many senders):** there is no node-side rescue beyond
   waiting for the pool to drain or raising its memory budget
   (`tx-pool-layer-max-capacity`); the real fix is **per-org fair-share** rate-limiting
   of submitters and, for sustained demand, more throughput (see Prevention).

## Prevention

- **Clients must track the confirmed nonce and not submit unboundedly ahead** of
  it. Staying within the per-sender future cap (200) avoids the "nonce too
  distant" rejections entirely.
- **Give every new sending account a non-zero balance once, even on a free-gas
  network.** "Free gas" removes the _fee_, not the requirement that the sender be
  non-empty: the proposer will not mine a tx from a zero-balance account. The
  amount is irrelevant (1 wei works and is not spent), so seed accounts from the
  genesis `alloc`, a faucet, or a treasury account as part of onboarding —
  "gasPrice 0 is fine _once the account holds any balance_." **Migrating from
  GoQuorum?** This is a behavioural divergence: Geth-derived Quorum mines
  zero-balance accounts' transactions, Besu does not (the gate applies to
  transfers, contract calls, and contract creations alike). A Quorum-era "issue
  a fresh account and transact immediately" workflow silently stalls on Besu.
- **Alert on a growing pending-but-not-mining backlog** (pending nonce pulling
  ahead of confirmed nonce), not just on RPC errors. Accepted-yet-stuck is the
  failure that produces no error and no page.
- **Rate-limit per submitter, not globally.** If several orgs share the network, a
  single global throttle penalises every member for one member's burst — enforce a
  **per-org / per-account fair share** at each edge (or a shared ingress). Per-account
  caps already isolate one sender's future queue from others, so the edge limit is for
  fairness and burst-smoothing.
- **Sustained overload is a capacity problem, not a policing one.** If legitimate
  aggregate demand exceeds mining throughput, raise it (block gas limit / block period)
  and size the pool (`tx-pool-layer-max-capacity`); rate-limiting only smooths bursts.
  See [scenario 06 — concurrent submitters](../scenarios/06-txpool-flooding/README.md#concurrent-submitters-consortium-reality).

## Post-Incident

- Capture the exact rejection error, the stuck tx hashes / nonces, and the
  sender's balance — these distinguish "future-cap hit" from "zero-balance
  sender" from "genuinely underpriced," which have different fixes.
- If the cause was a zero-balance sender on a free-gas chain, fix the client's
  account provisioning — this recurs because "free gas" is widely misread as
  "an unfunded account can transact."
