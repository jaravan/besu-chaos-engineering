KIND_CLUSTER ?= besu-chaos
NAMESPACE    ?= besu
RELEASE      ?= sbx
CHART        ?= oci://ghcr.io/jaravan/besu-helmcharts/besu-sandbox
CHART_VERSION ?= 0.2.3
CONSENSUS    ?= qbft   # qbft | ibft2 — consensus engine to deploy/target

.PHONY: cluster-up cluster-down install uninstall test scenario-01 scenario-02

cluster-up:
	kind get clusters | grep -qx $(KIND_CLUSTER) || kind create cluster --name $(KIND_CLUSTER)

cluster-down:
	kind delete cluster --name $(KIND_CLUSTER)

install:
	helm upgrade --install $(RELEASE) $(CHART) --version $(CHART_VERSION) \
		--set consensus=$(CONSENSUS) \
		-n $(NAMESPACE) --create-namespace --wait --timeout 600s

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
