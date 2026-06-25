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

How a BFT validator set behaves as validators are lost, isolated, or degraded.

| #                                     | Scenario          | Failure injected                                                                                                                                                                                                                                                                                        | Consensus       |
| ------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------- |
| [01](scenarios/01-validator-loss/)    | Validator loss    | Two steps along the fault threshold: one validator down (N-1, network stays healthy), then two down (f=1 exceeded → chain halts, RTO grows superlinearly with halt)                                                                                                                                     | QBFT · IBFT 2.0 |
| [02](scenarios/02-network-partition/) | Network partition | Split the validators `[1,2] \| [3,4]` with iptables DROP rules so neither side has quorum: both sides halt at the same block (no split-brain) while every pod stays Running/Ready; heal by flushing the rules                                                                                           | QBFT · IBFT 2.0 |
| [03](scenarios/03-slow-peer/)         | Slow peer         | Degrade one validator's egress with `tc netem` (400ms; 800ms+25% loss; 12s past the round-change timeout). Chain keeps producing on 3-of-4, but past `requesttimeoutseconds` the slow node's proposer slots round-change — a silent degradation that leaves zero fault tolerance, every pod still Ready | QBFT · IBFT 2.0 |

## Runbook

[runbook/](runbook/) holds incident entries in a fixed format — symptom, likely
causes, diagnosis steps, recovery procedure, prevention. An entry is added only
after the corresponding scenario has been run and its recovery procedure
verified, so the runbook stays grounded in observed behaviour rather than theory.

| Entry                                                                                   | Backed by scenario                             |
| --------------------------------------------------------------------------------------- | ---------------------------------------------- |
| [Validator down, network healthy](runbook/01-validator-down-network-healthy.md)         | [01](scenarios/01-validator-loss/) (Step 1)    |
| [Chain halted, quorum loss](runbook/02-chain-halted-quorum-loss.md)                     | [01](scenarios/01-validator-loss/) (Steps 2–4) |
| [Chain halted, network partition](runbook/03-chain-halted-network-partition.md)         | [02](scenarios/02-network-partition/)          |
| [Erratic block times, slow validator](runbook/04-erratic-block-times-slow-validator.md) | [03](scenarios/03-slow-peer/)                  |

## Safety

These scenarios inject real failures and are intended only for disposable test
networks. As a guardrail the scripts refuse to run unless the current kubectl
context looks like a local/disposable cluster — `kind-*`, `minikube`, `k3d-*`,
`k3s`, or `docker-desktop`. Any other context (including a managed cluster)
requires `ALLOW_ANY_CONTEXT=1` to run, at your own risk.
