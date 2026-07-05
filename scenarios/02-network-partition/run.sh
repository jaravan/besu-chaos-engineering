#!/usr/bin/env bash
# Scenario 02 — network partition (split-brain).
# Split validators into [1,2] | [3,4] with iptables DROP rules so neither side
# has BFT quorum (2f+1=3). Expected: both sides HALT at the same block (QBFT and
# IBFT 2.0 both have immediate finality, so no fork), RPC keeps answering, all
# four pods stay Running/Ready. Heal by flushing the rules and measure recovery.
#
# The Besu containers lack iptables/NET_ADMIN, so rules are injected via
# privileged ephemeral debug containers (kubectl debug --profile=sysadmin) that
# share each pod's network namespace (ensure_netns_container / netns in lib.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

# shellcheck disable=SC2206 # word-splitting is the interface: space-separated lists
GROUP_A=(${GROUP_A:-1 2})   # side we add the DROP rules on
# shellcheck disable=SC2206
GROUP_B=(${GROUP_B:-3 4})   # IPs blocked from group A
HALT_WINDOW="${HALT_WINDOW:-45}"

# Indexed arrays keyed by validator number (1..4). Avoid `declare -A`
# (associative) — macOS ships bash 3.2, which doesn't support it.
POD=() IP=()
for n in 1 2 3 4; do
  POD[$n]="${RELEASE}-validator${n}-0"
done

PARTITIONED=0

build_rules() {           # $1 = add|del ; prints iptables command string for GROUP_B IPs
  local op="$1" flag ip out=""
  [[ "${op}" == add ]] && flag="-I" || flag="-D"
  for v in "${GROUP_B[@]}"; do
    ip="${IP[$v]}"
    out+="iptables ${flag} INPUT -s ${ip} -j DROP; iptables ${flag} OUTPUT -d ${ip} -j DROP; "
  done
  printf '%s' "${out}"
}

heal() {
  local rules; rules="$(build_rules del)"
  for v in "${GROUP_A[@]}"; do netns "${POD[$v]}" "${rules} true"; done
  PARTITIONED=0
}

cleanup() {
  cleanup_probe
  # Safety net: if we exited while partitioned, recreating the group-A pods
  # gives them a fresh netns with no DROP rules — guarantees the network is
  # never left partitioned by a failed run.
  if (( PARTITIONED )); then
    for v in "${GROUP_A[@]}"; do
      kubectl -n "${NAMESPACE}" delete pod "${POD[$v]}" --grace-period=0 --force >/dev/null 2>&1 || true
    done
  fi
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT
ensure_probe

log "=== baseline (consensus=${CONSENSUS}) ==="
assert_chain_advancing 20
for n in 1 2 3 4; do
  IP[$n]="$(kubectl -n "${NAMESPACE}" get pod "${POD[$n]}" -o jsonpath='{.status.podIP}')"
  log "validator${n}: pod=${POD[$n]} ip=${IP[$n]} height=$(block_height "$(validator_svc "$n")") peers=$(peer_count "$(validator_svc "$n")")"
done

log "=== inject: partition [${GROUP_A[*]}] | [${GROUP_B[*]}] (DROP rules on side A) ==="
add_rules="$(build_rules add)"
PARTITIONED=1
for v in "${GROUP_A[@]}"; do
  log "attaching netns container to ${POD[$v]}"
  ensure_netns_container "${POD[$v]}"
  log "adding DROP rules in ${POD[$v]} (block IPs: ${IP[${GROUP_B[0]}]}, ${IP[${GROUP_B[1]}]})"
  netns "${POD[$v]}" "${add_rules} true" >/dev/null
done

# RLPx connections need a few seconds to time out once their packets are
# dropped; at most one in-flight block may commit before consensus messages
# stop flowing. Let that settle, then take the halt baseline.
log "partition active; waiting for cross-partition connections to drop"
sleep 12
partition_height="$(block_height)"
log "halt baseline height ${partition_height}; expecting both sides frozen"

log "=== observe: halt, no fork, RPC alive, pods stay Ready ==="
assert_chain_halted "${HALT_WINDOW}"
# Both sides must agree on height (no split-brain) and keep serving RPC.
ha="$(block_height "$(validator_svc "${GROUP_A[0]}")")"
hb="$(block_height "$(validator_svc "${GROUP_B[0]}")")"
log "side-A head (validator${GROUP_A[0]})=${ha:-none}  side-B head (validator${GROUP_B[0]})=${hb:-none}"
[[ -n "${ha}" && -n "${hb}" ]] || fail "a partition side stopped answering RPC (expected halted, not down)"
(( ha == hb )) || fail "SPLIT-BRAIN: sides diverged (A=${ha}, B=${hb}) — unexpected for QBFT/IBFT 2.0"
pass "no fork: both sides at height ${ha} with RPC alive"
for n in 1 2 3 4; do
  phase="$(kubectl -n "${NAMESPACE}" get pod "${POD[$n]}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  log "validator${n}: phase=${phase} peers=$(peer_count "$(validator_svc "$n")")"
done
log "round-change activity (side A, validator${GROUP_A[0]}):"
kubectl -n "${NAMESPACE}" logs "${POD[${GROUP_A[0]}]}" --tail=200 2>/dev/null | grep -iE 'round|quorum|propos' | tail -5 || true

log "=== heal: flush DROP rules (no pod restart) and measure recovery ==="
heal
elapsed_after_heal="$(wait_for_height_above "${partition_height}" 900)"
pass "02: network resumed ${elapsed_after_heal}s after partition healed (no restart, no fork)"

log "=== post-recovery: steady state ==="
assert_chain_advancing 20
for n in 1 2 3 4; do
  log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
done

log "=== scenario 02 complete ==="
