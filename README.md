# Besu Chaos Engineering

Chaos engineering suite and tested incident runbook for Hyperledger Besu
consortium networks.

> **Status: just getting started.** The harness and methodology are in place;
> the scenario catalogue and runbook are built up one scenario at a time. Every
> runbook entry is backed by a reproducible scenario — nothing here is
> hypothetical.

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
and feeds a runbook entry once its recovery procedure has actually been run and
verified.

Every scenario runs against my own published Helm chart,
[besu-sandbox](https://github.com/jaravan/besu-helmcharts) — installed straight
from its OCI registry, broken on purpose as each scenario specifies.

## Requirements

The scenarios run against a **Kubernetes cluster**. They're pure `kubectl` under
the hood, so any cluster you can reach will do — [kind](https://kind.sigs.k8s.io/)
is just the environment they were developed and run against, and what the
`make cluster-up` / `cluster-down` helpers drive. Bring your own cluster and you
can skip those targets.

- A [Kubernetes](https://kubernetes.io/) cluster — [kind](https://kind.sigs.k8s.io/) is used here; [minikube](https://minikube.sigs.k8s.io/) / [k3d](https://k3d.io/) / [k3s](https://k3s.io/) / any cluster works
- [kubectl](https://kubernetes.io/docs/reference/kubectl/) (>= 1.30 for the traffic-shaping scenarios; see below), pointed at that cluster
- [Helm](https://helm.sh/) >= 3.8 (OCI support)
- [Docker](https://www.docker.com/) (for kind, or any cluster that needs it)

**Local clusters work out of the box.** A few scenarios need cluster
_capabilities_ that a locked-down managed cluster may not grant — these are
properties of the cluster's policy, not of any one vendor:

- **Privileged ephemeral containers** — the network-partition and slow-peer
  scenarios attach a `NET_ADMIN` debug container (`kubectl debug
--profile=sysadmin`) to shape traffic in a node's network namespace. A cluster
  with restrictive PodSecurity admission will reject this.
- **Public image egress** — scenarios pull `curlimages/curl` and
  `nicolaka/netshoot`; air-gapped clusters need these mirrored.
- **A working StorageClass** — the snapshot/restore scenarios copy PVC volumes;
  behaviour depends on the cluster's storage provisioner.

## Quickstart

```sh
make cluster-up     # OPTIONAL — spins up a local kind cluster "besu-chaos"
                    # skip if you already have a cluster; just point kubectl at it
make install        # besu-sandbox from oci://ghcr.io/jaravan/besu-helmcharts
# make scenario-NN  # run a scenario (added one at a time — see Scenarios)
make cluster-down   # tear down the kind cluster (no-op if you brought your own)
```

## Scenarios

_The catalogue is added one scenario at a time and will appear here as it grows._

Each scenario lives in its own directory under [scenarios/](scenarios/) and
contains a `README.md` (hypothesis, method, expected and observed behaviour) and
a `run.sh` that executes the full inject → observe → recover → assert cycle.
Scenario numbers are stable IDs wired into the Makefile and the runbook.

## Runbook

[runbook/](runbook/) holds incident entries in a fixed format — symptom, likely
causes, diagnosis steps, recovery procedure, prevention. An entry is added only
after the corresponding scenario has been run and its recovery procedure
verified, so the runbook stays grounded in observed behaviour rather than
theory.

## Safety

These scenarios inject real failures and are intended only for disposable test
networks. As a guardrail the scripts refuse to run unless the current kubectl
context looks like a local/disposable cluster — `kind-*`, `minikube`, `k3d-*`,
`k3s`, or `docker-desktop`. Any other context (including a managed cluster)
requires `ALLOW_ANY_CONTEXT=1` to run, at your own risk.
