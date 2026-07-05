KIND_CLUSTER ?= besu-chaos
NAMESPACE    ?= besu
RELEASE      ?= sbx
CHART        ?= oci://ghcr.io/jaravan/besu-helmcharts/besu-sandbox
CHART_VERSION ?= 0.3.1
CONSENSUS    ?= qbft   # qbft | ibft2 — consensus engine to deploy/target

.PHONY: cluster-up cluster-down install uninstall test scenario-01 scenario-02 scenario-03 scenario-04 scenario-05 scenario-06 scenario-07 scenario-08 scenario-09 scenario-10

cluster-up:
	kind get clusters | grep -qx $(KIND_CLUSTER) || kind create cluster --name $(KIND_CLUSTER)

cluster-down:
	kind delete cluster --name $(KIND_CLUSTER)

# EPOCHLENGTH (optional) overrides the QBFT/IBFT epoch length in the generated
# genesis — e.g. EPOCHLENGTH=30 for the scenario-04 epoch test. Genesis is
# immutable, so changing it means a fresh chain (uninstall + delete PVCs first).
install:
	helm upgrade --install $(RELEASE) $(CHART) --version $(CHART_VERSION) \
		--set consensus=$(CONSENSUS) \
		$(if $(EPOCHLENGTH),--set consensusConfig.epochlength=$(EPOCHLENGTH),) \
		-n $(NAMESPACE) --create-namespace --timeout 900s
	# chart 0.3.x validator StatefulSets use updateStrategy=OnDelete, which helm
	# --wait does not gate (and config-change upgrades roll one-at-a-time via a
	# post-upgrade hook, needing the generous timeout above). Wait on pod readiness
	# explicitly, per the chart NOTES.
	kubectl -n $(NAMESPACE) wait --for=condition=Ready pod \
		-l app.kubernetes.io/instance=$(RELEASE),app.kubernetes.io/component=validator --timeout=300s

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE)

test:
	helm test $(RELEASE) -n $(NAMESPACE) --timeout 300s --logs

# Scenario 01 — validator loss. Runs steps 1 + 2 by default; STEP=1 (single
# validator loss), STEP=2 (quorum loss), STEP=3 (coordinated restart after a
# halt; opt-in, e.g. STEP=3 HALT_WINDOW=300), or STEP=4 (partial restart;
# STUCK_SURVIVORS=1|2) runs just one. CONSENSUS must match the deployed release
# (qbft | ibft2).
scenario-01:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) CONSENSUS=$(CONSENSUS) bash scenarios/01-validator-loss/run.sh

# Scenario 02 — network partition (split-brain). Splits the four validators into
# [1,2] | [3,4] with iptables DROP rules injected via privileged ephemeral debug
# containers, holds the halt for HALT_WINDOW (default 45s), then heals by
# flushing the rules. GROUP_A/GROUP_B override the split. CONSENSUS must match
# the deployed release (qbft | ibft2).
scenario-02:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) CONSENSUS=$(CONSENSUS) bash scenarios/02-network-partition/run.sh

# Scenario 03 — slow peer (network degradation). Degrades one validator's egress
# with tc netem in escalating steps (400ms; 800ms+25% loss; 12s past the
# round-change timeout), injected via the same privileged ephemeral debug
# container as scenario 02. The chain keeps producing on 3-of-4; once latency
# crosses requesttimeoutseconds the slow node's proposer slots round-change.
# TARGET_VALIDATOR overrides the degraded node. CONSENSUS must match the deployed
# release (qbft | ibft2).
scenario-03:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) CONSENSUS=$(CONSENSUS) bash scenarios/03-slow-peer/run.sh

# Scenario 04 — validator-set governance. The existing validators vote a member
# out of the set and back in at runtime via <engine>_proposeValidatorVote — no
# restart, no genesis/chart change. The chain keeps producing at N=3 (quorum 2)
# while the member is out; the durable counterpart to the transient loss in
# scenario 01. VOTERS overrides the voting majority. CONSENSUS must match the
# deployed release (qbft | ibft2).
scenario-04:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) CONSENSUS=$(CONSENSUS) bash scenarios/04-validator-governance/run.sh

# Scenario 05 — duplicate validator key (HA failover gone wrong). A second node
# runs the same validator key. STEP=1 (devp2p dedupe: copy deployed alongside the
# live node) and STEP=2 (partition trap: real node isolated first, then the copy)
# run by default; the copy is shut out at the P2P layer (0 peers / block 0) in both
# — a deployment-level safety property, not a consensus guarantee (see the README
# caveat). STEP=3 (opt-in, not in the default) scales the validator StatefulSet to 2:
# the replica still can't join consensus, but its readiness probe admits it to the
# RPC Service endpoints un-synced, polluting client reads. TARGET overrides the
# duplicated validator. CONSENSUS must match the deployed release (qbft | ibft2).
scenario-05:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) CONSENSUS=$(CONSENSUS) bash scenarios/05-duplicate-validator/run.sh

# Scenario 06 — transaction pool flooding. Drives `cast` (foundry) from a pod
# against the unified RPC, signing with a genesis-funded dev account. Saturates a
# sender's future-nonce queue until Besu rejects with an error (not a silent
# drop), fills the gap to promote the queue, and shows a zero-balance sender's tx
# is accepted but unmined until the account holds any balance. Consensus-agnostic
# (tx-layer); runs against the main network. MAX_SUBMIT caps the future-nonce loop.
scenario-06:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) bash scenarios/06-txpool-flooding/run.sh

# Scenario 07 — account permissioning. Stands up its OWN permissioned network
# (namespace besu-perm, release sbxperm) with permissioning.accounts.enabled, then
# shows a funded-but-not-allowlisted sender is DENIED at submission (-32007),
# allowlisting it (perm_addAccountsToAllowlist on every validator) lets it mine,
# and removing it denies again. Consensus-agnostic; self-contained (installs and
# tears down its own network — KEEP_NETWORK=1 to inspect). Chart pin from the repo.
scenario-07:
	CHART=$(CHART) CHART_VERSION=$(CHART_VERSION) bash scenarios/07-account-permissioning/run.sh

# Scenario 08 — permissioning outage (allowlist lockout). Same own-network install
# as 07, then removes the OPERATIONAL account from the allowlist on every validator:
# every sender is locked out (-32007) while QBFT keeps producing empty blocks — the
# "network looks healthy but is frozen for users" trap. Recovers via
# perm_addAccountsToAllowlist (RPC escape hatch), no restart. Self-contained.
scenario-08:
	CHART=$(CHART) CHART_VERSION=$(CHART_VERSION) bash scenarios/08-permissioning-outage/run.sh

# Scenario 09 — snapshot restore (storage layer). Restores a validator from a
# data-volume snapshot three ways: STEP=1 cold (node stopped — crash-consistent,
# the procedure to rely on), STEP=2 hot while idle (usually reopens via RocksDB
# WAL recovery), STEP=3 hot under sustained tx load (a file-walk copy is a
# smeared capture — the arm that can fail; a failed open triggers the runbook's
# wipe+resync recovery automatically). All three by default. The target (default
# validator4, TARGET_VALIDATOR overrides) is beyond quorum, so the chain keeps
# producing at 3-of-4 throughout. Engine-independent (storage layer).
scenario-09:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) bash scenarios/09-snapshot-restore/run.sh

# Scenario 10 — genesis / config drift (onboarding layer). A standalone joiner
# node dials the running network: STEP=1 (control) boots it from the real
# genesis and it must full-sync to head; STEP=2 (drift) boots it from the same
# genesis with chainId changed (DRIFT_CHAINID, default 1337001) and it must stay
# at block 0 with no useful peers — rejected at the eth handshake — while the
# network is unaffected. Both by default. Image and bootnodes are read from the
# live validator1 pod. Engine-independent (handshake layer).
scenario-10:
	NAMESPACE=$(NAMESPACE) RELEASE=$(RELEASE) bash scenarios/10-genesis-config-drift/run.sh
