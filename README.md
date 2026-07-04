# Besu Chaos Engineering

Chaos engineering suite and tested incident runbook for Hyperledger Besu
consortium networks.

## What this is

Most operational knowledge about running Besu consortium networks lives in
incident tickets and the heads of the people who ran them. This repo makes it
public and reproducible: controlled failure injection against real
permissioned networks, observed behaviour, and step-by-step recovery
procedures.

Besu supports several Byzantine-fault-tolerant consensus mechanisms for
permissioned deployments — QBFT and IBFT 2.0. Some failure modes are
consensus-agnostic (a node loss, a bad genesis, a flooded txpool); others depend
on the protocol (how a BFT set behaves when quorum is lost). Scenarios note which
consensus they target and, where it matters, how the behaviour differs across
them.

Each scenario follows the same loop — **inject → observe → recover → assert** —
and backs a runbook entry once its recovery procedure has actually been run and
verified.

Every scenario runs against my own published Helm chart,
[besu-sandbox](https://github.com/jaravan/besu-helmcharts) — installed straight
from its OCI registry.

## Requirements

The scenarios run against a **Kubernetes cluster**. They're pure `kubectl` under
the hood, so any cluster you can reach will do — [kind](https://kind.sigs.k8s.io/)
is just the environment they were developed and run against, and what the
`make cluster-up` / `cluster-down` helpers drive. Bring your own cluster and you
can skip those targets.

- A [Kubernetes](https://kubernetes.io/) cluster — [kind](https://kind.sigs.k8s.io/) is used here; [minikube](https://minikube.sigs.k8s.io/) / [k3d](https://k3d.io/) / [k3s](https://k3s.io/) / any cluster works
- [kubectl](https://kubernetes.io/docs/reference/kubectl/) (>= 1.30), pointed at that cluster
- [Helm](https://helm.sh/) >= 3.8 (OCI support)
- [Docker](https://www.docker.com/) (for kind, or any cluster that needs it)

**Local clusters work out of the box.** Many scenarios need nothing beyond a
working cluster and outbound image pulls; others need cluster _capabilities_ that
a locked-down managed cluster may not grant — properties of the cluster's policy,
not of any one vendor. For example:

- **Privileged ephemeral containers** — the network-partition and slow-peer
  scenarios attach a `NET_ADMIN` debug container (`kubectl debug --profile=sysadmin`) to shape traffic in a node's network namespace (`iptables` DROP rules / `tc netem`); a cluster with restrictive PodSecurity admission will reject this.
- **Public image egress** — scenarios pull `curlimages/curl`, and the traffic-shaping scenarios add `nicolaka/netshoot`; air-gapped clusters need these mirrored.

## Quickstart

```sh
make cluster-up     # OPTIONAL — spins up a local kind cluster "besu-chaos"
                    # skip if you already have a cluster; just point kubectl at it
make install        # besu-sandbox from oci://ghcr.io/jaravan/besu-helmcharts
make scenario-01    # validator loss (STEP=1 single / STEP=2 quorum / both)
make cluster-down   # tear down the kind cluster (no-op if you brought your own)
```

## Scenarios

Each scenario lives in its own directory under [scenarios/](scenarios/) and
contains a `README.md` (hypothesis, method, expected and observed behaviour) and
a `run.sh` that executes the full inject → observe → recover → assert cycle.
Scenario numbers are stable IDs wired into the Makefile and the runbook.

> **Cross-cutting note — cold-start peering.** On chart ≤ 0.2.2 a fresh
> simultaneous deploy could leave the validators in a sparse hub-and-spoke mesh
> (`net_peerCount` `3/1/1/1`) even though every pod is `Running`/`Ready` and blocks
> are flowing — a Kubernetes/P2P startup-timing artifact, independent of QBFT vs
> IBFT 2.0. **Fixed in chart 0.2.3** (`publishNotReadyAddresses` on the validator
> Services): fresh installs now cold-start to a full `3/3/3/3` mesh.

### Consensus & availability

How a BFT validator set behaves as validators are lost, isolated, degraded, or
deliberately reconfigured.

| #                                        | Scenario                | Failure injected                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Consensus       |
| ---------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------- |
| [01](scenarios/01-validator-loss/)       | Validator loss          | Two steps along the fault threshold: one validator down (N-1, network stays healthy), then two down (f=1 exceeded → chain halts, RTO grows superlinearly with halt)                                                                                                                                                                                                                                                                                                                                                                                                                                                            | QBFT · IBFT 2.0 |
| [02](scenarios/02-network-partition/)    | Network partition       | Split the validators `[1,2] \| [3,4]` with iptables DROP rules so neither side has quorum: both sides halt at the same block (no split-brain) while every pod stays Running/Ready; heal by flushing the rules                                                                                                                                                                                                                                                                                                                                                                                                                  | QBFT · IBFT 2.0 |
| [03](scenarios/03-slow-peer/)            | Slow peer               | Degrade one validator's egress with `tc netem` (400ms; 800ms+25% loss; 12s past the round-change timeout). Chain keeps producing on 3-of-4, but past `requesttimeoutseconds` the slow node's proposer slots round-change — a silent degradation that leaves zero fault tolerance, every pod still Ready                                                                                                                                                                                                                                                                                                                        | QBFT · IBFT 2.0 |
| [04](scenarios/04-validator-governance/) | Validator governance    | Vote a member out of the validator set and back in at runtime via `<engine>_proposeValidatorVote` (majority of current validators, no restart, no genesis change). Chain keeps producing at N=3 while the member is out; the removed node stays Running as a non-proposing peer. The durable counterpart to scenario 01's transient loss                                                                                                                                                                                                                                                                                       | QBFT · IBFT 2.0 |
| [05](scenarios/05-duplicate-validator/)  | Duplicate validator key | Run a second node carrying the same validator key (misconfigured HA failover). Deploy the duplicate alongside the live node (devp2p identity dedupe shuts it out), then isolate the real node first and try again (StatefulSet DNS still anchors peers to the real pod); an opt-in third step scales the validator StatefulSet to 2. The duplicate never joins consensus — 0 peers, block 0 — a deployment-level safety property, not a protocol guarantee against equivocation; a StatefulSet-scaled copy does, though, slip into the RPC Service endpoints un-synced and pollute client reads. No incident, no runbook entry | QBFT · IBFT 2.0 |

### Transaction layer

What gates, strands, or rejects a transaction while consensus stays healthy. These
scenarios are engine-agnostic — they exercise the transaction pipeline, not the
validator set.

| #                                         | Scenario                  | Failure injected                                                                                                                                                                                                                                                                                                                                                                                                                           | Consensus      |
| ----------------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------- |
| [06](scenarios/06-txpool-flooding/)       | Transaction pool flooding | Saturate one sender's future-nonce queue (gap at the current nonce) until Besu rejects with `-32000` (not a silent drop), then fill the gap and watch the 199 queued txs promote and mine. A zero-balance sender's tx is accepted but never mined until the account holds any balance (1 wei is enough) — on a free-gas chain it's the empty account, not the gas price, that strands it. Reads and block production unaffected throughout | Any (tx-layer) |
| [07](scenarios/07-account-permissioning/) | Account permissioning     | Spin up its own permissioned network and show a funded-but-not-allowlisted sender is DENIED at submission (`-32007`, never pooled, nonce unmoved) — the opposite shape to 06's accepted-then-stranded balance gate. `perm_addAccountsToAllowlist` on every validator lets it mine; removing it denies again. The two gates a new participant must clear: allowlisted **and** funded                                                        | Any (tx-layer) |
| [08](scenarios/08-permissioning-outage/)  | Permissioning outage      | Empty the allowlist on every validator (a wrong admin change / bad deploy) and watch **every** sender get `-32007` while QBFT keeps producing empty blocks — pods Ready, height climbing, network frozen for users. The authorization-layer false comfort, worse than quorum loss because the chain doesn't even halt. Recover via the `perm_*` RPC escape hatch, no restart                                                               | Any (tx-layer) |

### State & storage

Whether a node can be rebuilt from what's on disk — and which backups deserve
the trust. These scenarios operate on one node's data volume; consensus stays
healthy throughout (the target is beyond quorum).

| #                                    | Scenario         | Failure injected                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Consensus           |
| ------------------------------------ | ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- |
| [09](scenarios/09-snapshot-restore/) | Snapshot restore | Restore a validator from a data-volume snapshot, three ways: cold (node stopped — crash-consistent by construction, the procedure to rely on), hot while idle (usually reopens via RocksDB WAL recovery), and hot under sustained tx load (a file-walk copy is a _smeared_ capture that can fail to reopen). A failed hot restore triggers the runbook recovery — wipe + resync — automatically, so the loop closes either way. Also retires the GoQuorum "freezer desync" fear: Bonsai is one RocksDB, no two-store split | Any (storage-layer) |

## Runbook

[runbook/](runbook/) holds incident entries in a fixed format — symptom, likely
causes, diagnosis steps, recovery procedure, prevention. An entry is added only
after the corresponding scenario has been run and its recovery procedure
verified, so the runbook stays grounded in observed behaviour rather than theory.

| Entry                                                                                          | Backed by scenario                             |
| ---------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| [Validator down, network healthy](runbook/01-validator-down-network-healthy.md)                | [01](scenarios/01-validator-loss/) (Step 1)    |
| [Chain halted, quorum loss](runbook/02-chain-halted-quorum-loss.md)                            | [01](scenarios/01-validator-loss/) (Steps 2–4) |
| [Chain halted, network partition](runbook/03-chain-halted-network-partition.md)                | [02](scenarios/02-network-partition/)          |
| [Erratic block times, slow validator](runbook/04-erratic-block-times-slow-validator.md)        | [03](scenarios/03-slow-peer/)                  |
| [Changing the validator set](runbook/05-validator-set-governance.md)                           | [04](scenarios/04-validator-governance/)       |
| [Transactions rejected or stuck pending](runbook/06-transactions-rejected-or-stuck-pending.md) | [06](scenarios/06-txpool-flooding/)            |
| [Account not authorized to send](runbook/07-account-not-authorized-to-send.md)                 | [07](scenarios/07-account-permissioning/)      |
| [Network "up" but no transactions](runbook/08-network-up-but-no-transactions.md)               | [08](scenarios/08-permissioning-outage/)       |
| [Restoring a node from a volume snapshot](runbook/09-node-restore-from-volume-snapshot.md)     | [09](scenarios/09-snapshot-restore/)           |

## Safety

These scenarios inject real failures and are intended only for disposable test
networks. As a guardrail the scripts refuse to run unless the current kubectl
context looks like a local/disposable cluster — `kind-*`, `minikube`, `k3d-*`,
`k3s`, or `docker-desktop`. Any other context (including a managed cluster)
requires `ALLOW_ANY_CONTEXT=1` to run, at your own risk.

> **`ALLOW_ANY_CONTEXT`** It is not a Kubernetes or Helm setting — it's an
> environment-variable escape hatch defined by this repo's own guard
> (`guard_local_context` in [`scripts/lib.sh`](scripts/lib.sh)). The guard reads
> your current kubectl context and, if it isn't one of the recognised local
> prefixes above, aborts the run. Setting `ALLOW_ANY_CONTEXT=1` tells the guard to
> skip that check and proceed against whatever context is active. Use it only when
> you have _deliberately_ pointed kubectl at a cluster you are certain is safe to
> break — pass it per-invocation so it never lingers, e.g.
> `ALLOW_ANY_CONTEXT=1 make scenario-01`.

## License

Copyright 2026 John Aravanis. Licensed under the Apache License, Version 2.0.
See [LICENSE](LICENSE) and [NOTICE](NOTICE).
