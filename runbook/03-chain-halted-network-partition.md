# Chain halted, all pods Running/Ready, validators split (network partition)

> Backed by scenario: [`02-network-partition`](../scenarios/02-network-partition/)
> — entries are added only after the recovery procedure has been executed and
> verified against a real network.

## Symptom

Identical to [quorum loss](02-chain-halted-quorum-loss.md) on the surface, but
one degree more deceptive:

- **Block height frozen**, RPC still answering reads on every node.
- **Every validator pod is `Running`/`Ready`.** Nothing is down, nothing is
  CrashLooping — there isn't even a missing pod to notice. Kubernetes reports a
  perfectly healthy deployment while the network is completely halted.
- **Peer counts have collapsed** — each validator sees only the nodes on its own
  side of the partition (in the verified 2/2 split, ~1 peer each; fewer if the
  peer mesh had not fully formed before the partition, e.g. a side dropping to 0).

This is the strongest possible case for **alerting on block-height-stall, not on
pod health**: every pod-level and container-level signal is green.

## Likely Causes

Ordered by frequency in practice:

1. **Network partition between validators** — a NetworkPolicy change, CNI fault,
   security-group/firewall edit, or WAN link failure between the
   organisations/zones hosting the validators. Splits the set so no side has the
   2f+1 = 3 quorum.
2. **DNS / service-discovery breakage** that stops validators resolving each
   other's enodes after a restart — looks like a partition (peers can't
   connect) even though the network path is fine.
3. **Asymmetric partition** isolating a minority (e.g. one validator cut off):
   this does **not** halt the chain — the majority keeps quorum and keeps
   producing. If height is still advancing, you have a minority partition, not
   this incident.

## Diagnosis Steps

```sh
# Frozen height but RPC alive, and — the distinguishing signal — every pod Ready
kubectl -n besu get pods            # all Running/Ready (vs quorum loss: pods missing)
kubectl -n besu exec chaos-probe -- curl -s -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://sbx-rpc-unified:8545        # same value on repeat

# Peer counts: a partition shows every side with a reduced, symmetric count
# (e.g. 1 peer each in a 2/2 split). This is what separates "partition" from
# "validators down".
for n in 1 2 3 4; do
  kubectl -n besu exec chaos-probe -- curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
    http://sbx-validator${n}:8545
done

# Confirm no fork: heights on each side must be identical (QBFT and IBFT 2.0
# cannot split-brain; divergent heights would mean something is very wrong)
kubectl -n besu exec chaos-probe -- curl -s ... http://sbx-validator1:8545   # side A
kubectl -n besu exec chaos-probe -- curl -s ... http://sbx-validator3:8545   # side B

# Round-change progression confirms the survivors are proposing without quorum,
# not hung:
kubectl -n besu logs sbx-validator1-0 --tail=200 | grep -iE 'round|quorum'
# e.g. "Moved to round N which will expire in M seconds" / "BFT round summary (quorum = 3)"

# Find the partition itself
kubectl -n besu get networkpolicy
kubectl -n besu exec sbx-validator1-0 -- /bin/sh -c 'true'  # then test connectivity to a peer IP/port 30303
```

## Recovery Procedure

1. **Heal the partition** — revert the NetworkPolicy/firewall change, restore
   the CNI/link, or fix DNS. **You do not need to restart the validators.** In the
   verified runs (short 2/2 partition, round only climbed to 2), flushing the
   blocking rules with no pod restart brought the network back **10s (QBFT) / 82s
   (IBFT 2.0)** later — automatic, no manual intervention. The spread is normal:
   recovery waits out wherever the surviving validators are in their current
   round-change timer, and IBFT 2.0's round-change/proposer startup is slower.
2. **Do not "fix" it by restarting validators.** They are not hung — they are in
   BFT round-change backoff. Restarting them adds resync time on top of the
   round-change wait and lengthens the outage (see
   [quorum loss](02-chain-halted-quorum-loss.md) for the measured backoff
   curve).
3. **Recovery is automatic once connectivity returns.** Because the validators
   stayed in sync at the same height (BFT never forked), there is nothing to
   reconcile — they resume from the last committed block. Expect the same
   round-change backoff as a quorum-loss outage of equal duration: short
   partitions recover in seconds, long ones take proportionally (super-linearly)
   longer.
4. **Verify:** a new block appears above the halt height, all four validators
   advance together, and the peer mesh re-forms (allow minutes for full mesh —
   the peer-count lag is expected and self-heals).

## Prevention

- **Alert on block-height-stall, full stop.** A partition leaves every pod
  `Ready` and every RPC endpoint live; height-not-advancing is the _only_
  reliable detector.
- **Add a cross-validator connectivity / peer-count probe** to monitoring: a
  symmetric collapse in peer counts across the validator set is the signature of
  a partition and distinguishes it from "validators down".
- **Review NetworkPolicy and firewall changes as production-affecting.** A
  policy that accidentally blocks the p2p port (30303) between validators is a
  full network outage with zero pod-level symptoms — the highest-risk,
  lowest-visibility change class for a consortium.
- **Spread validators across failure domains deliberately, and know your quorum
  math per domain.** If a single WAN link or zone boundary can isolate ≥ f+1
  validators, that link is a single point of total outage.

## Post-Incident

- Preserve the round-change logs from both sides — they prove the network was
  backing off (not hung) and that no side ever reached quorum, which justifies
  the "heal the network, don't restart nodes" decision.
- Confirm and record that heights never diverged (no fork). If they ever did,
  that is a far more serious finding than the outage itself and warrants a
  separate investigation.
- Record the partition duration and recovery time; feed it into the same RTO
  curve as quorum loss.
