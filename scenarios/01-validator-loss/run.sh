#!/usr/bin/env bash
# Scenario 01 — validator loss.
#
# Step 1 (single validator loss): with N=4 QBFT validators, quorum is 2f+1 = 3,
#   so losing one validator must not interrupt block production.
#   1a SIGKILLs one validator (force delete); the StatefulSet restarts it.
#   1b holds a sustained scale-to-0 outage, then scales back.
#   Verify the chain never depends on the node and it rejoins + catches up.
#
# Step 2 (quorum loss): take down 2 of 4 validators (f=1 exceeded). QBFT cannot
#   reach quorum, so the chain must halt at the last committed block while RPC
#   reads keep working. Restore both validators and measure the actual RTO:
#   time from quorum restored to the first new block.
#
# Step 3 (coordinated restart): the round-change timer that Step 2 waits out is
#   in-memory state — only the blockchain is persisted. After a deep halt the
#   surviving validators sit on a high round with a hugely inflated timeout. This
#   step holds the same quorum-loss halt, then instead of waiting the backoff out
#   it restarts ALL validators together (recovered pair + survivors), resetting
#   the whole set to round 0, and measures time to the first block — the operator
#   lever for a halt that has dragged on. Contrast its RTO with the Step 2 control
#   at the same HALT_WINDOW.
#
# Step 4 (partial restart — negative-coordination control): same as Step 3 but
#   leaves STUCK_SURVIVORS survivors at their high round instead of restarting
#   them. Tests the threshold: the wait persists only when >= f+1 validators stay
#   stuck (N=4 -> f=1, so 1 stuck still recovers fast, 2 stuck waits it out).
#
# STEP selects which steps run: "1", "2", "3", "4", or "default" (= steps 1 + 2,
# the non-destructive observation pair). "3"/"4" are opt-in — they restart
# validators — so they are never part of the default run; request them explicitly.
set -euo pipefail
# Run from the repo root so `source scripts/lib.sh` and the relative paths
# resolve no matter where the script is invoked from.
cd "$(dirname "$0")/../.."
source scripts/lib.sh

STEP="${STEP:-default}"
TARGET_VALIDATOR="${TARGET_VALIDATOR:-2}"        # step 1: single target
# shellcheck disable=SC2206 # word-splitting is the interface: a space-separated list
TARGET_VALIDATORS=(${TARGET_VALIDATORS:-2 3})    # step 2: the pair taken down
OUTAGE_WINDOW="${OUTAGE_WINDOW:-30}"             # step 1b sustained outage
HALT_WINDOW="${HALT_WINDOW:-45}"                 # step 2 halt observation

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup_probe EXIT     # always remove the probe pod, even on failure
ensure_probe                # long-lived in-cluster curl pod for RPC calls

log "=== baseline (consensus=${CONSENSUS}) ==="
assert_chain_advancing 20
for n in 1 2 3 4; do
  log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
done

step_single_validator_loss() {
  local target_sts="${RELEASE}-validator${TARGET_VALIDATOR}"
  local target_pod="${target_sts}-0"
  local target_svc kill_height_before kill_t0 kill_t1 rejoin_peers rejoin_height
  local outage_start_height surviving_peers head_height node_height gap
  target_svc="$(validator_svc "${TARGET_VALIDATOR}")"

  log "=== STEP 1: single validator loss (target validator ${TARGET_VALIDATOR}) ==="

  log "--- 1a: ungraceful kill (force delete ${target_pod}) ---"
  kill_height_before="$(block_height)"
  kubectl -n "${NAMESPACE}" delete pod "${target_pod}" --grace-period=0 --force >/dev/null 2>&1
  kill_t0=$(date +%s)
  log "pod force-deleted at height ${kill_height_before}; chain must keep advancing while it restarts"
  assert_chain_advancing 30
  wait_pod_ready "${target_pod}" 300s
  kill_t1=$(date +%s)
  log "${target_pod} Ready again after $(( kill_t1 - kill_t0 ))s"
  # Ready precedes P2P re-discovery, so poll instead of sampling once — a slow
  # re-dial is latency, not a lost peer.
  rejoin_peers="$(wait_for_peers "${target_svc}" 3 60)" \
    || fail "restarted validator only reached ${rejoin_peers} peers in 60s (expected >= 3)"
  rejoin_height="$(block_height "${target_svc}")"
  pass "1a: restarted validator rejoined (peers=${rejoin_peers}, height=${rejoin_height})"

  log "--- 1b: sustained outage (scale ${target_sts} to 0 for ${OUTAGE_WINDOW}s) ---"
  kubectl -n "${NAMESPACE}" scale "statefulset/${target_sts}" --replicas=0 >/dev/null
  kubectl -n "${NAMESPACE}" wait --for=delete "pod/${target_pod}" --timeout=120s >/dev/null
  outage_start_height="$(block_height)"
  log "validator down; observing for ${OUTAGE_WINDOW}s from height ${outage_start_height}"
  sleep "${OUTAGE_WINDOW}"
  assert_chain_advancing 20
  surviving_peers="$(peer_count "$(validator_svc 1)")"
  log "surviving validator peer count: ${surviving_peers} (expected 2 of remaining 3 + any RPC peers)"

  log "--- recovery: scale ${target_sts} back to 1 ---"
  kubectl -n "${NAMESPACE}" scale "statefulset/${target_sts}" --replicas=1 >/dev/null
  wait_pod_ready "${target_pod}" 300s
  sleep 10  # give the rejoined node a moment to catch up before measuring the gap
  head_height="$(block_height)"
  node_height="$(block_height "${target_svc}")"
  [[ -n "${node_height}" ]] || fail "restarted validator not answering RPC"
  gap=$(( head_height - node_height ))
  (( gap <= 5 )) || fail "restarted validator is ${gap} blocks behind head (${node_height}/${head_height})"
  pass "1b: validator caught up (node=${node_height}, head=${head_height}, gap=${gap})"
}

step_quorum_loss() {
  local inject_t0 halt_height validators_hex surviving_peers
  local recover_t0 ready_t halt_duration elapsed_after_ready total_rto v

  log "=== STEP 2: quorum loss (scale validators ${TARGET_VALIDATORS[*]} to 0) ==="
  log "--- inject: take down 2 of 4 (quorum 3 of 4 broken) ---"
  inject_t0=$(date +%s)
  # Scale both down first, THEN wait for both to be gone — so quorum breaks as
  # close to simultaneously as possible. A scale+wait per validator would take
  # them down one at a time, briefly leaving the set at a recoverable N-1.
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" scale "statefulset/${RELEASE}-validator${v}" --replicas=0 >/dev/null
  done
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" wait --for=delete "pod/${RELEASE}-validator${v}-0" --timeout=120s >/dev/null
  done
  log "both validators gone; expecting halt"

  log "--- observe: halt + RPC behaviour during outage ---"
  assert_chain_halted "${HALT_WINDOW}"
  halt_height="$(block_height)"
  # Validator-set query proves RPC reads still work mid-halt. The namespace is
  # engine-specific: qbft_* for QBFT, ibft_* for IBFT 2.0 (see consensus_rpc_ns).
  validators_hex="$(rpc "$(consensus_rpc_ns)_getValidatorsByBlockNumber" '["latest"]')"
  log "RPC reads still served during halt: height=${halt_height}, validator set query answered: ${validators_hex:0:120}..."
  surviving_peers="$(peer_count "$(validator_svc 1)")"
  log "surviving validator1 peer count during outage: ${surviving_peers}"

  log "--- recover: scale both back, measure RTO ---"
  recover_t0=$(date +%s)
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" scale "statefulset/${RELEASE}-validator${v}" --replicas=1 >/dev/null
  done
  for v in "${TARGET_VALIDATORS[@]}"; do
    wait_pod_ready "${RELEASE}-validator${v}-0" 300s
  done
  ready_t=$(date +%s)
  # Three timings worth separating:
  #   halt_duration       — quorum-broken → both pods Ready again
  #   elapsed_after_ready  — the surprising wait for the FIRST block after Ready,
  #                          i.e. round-change backoff (grows with halt_duration)
  #   total_rto            — full operator-felt recovery (scale-up → first block)
  # 900s timeout on wait_for_height_above is generous for long halts (round
  # timers can climb into the hundreds of seconds).
  halt_duration=$(( ready_t - inject_t0 ))
  log "both pods Ready after $(( ready_t - recover_t0 ))s; waiting for first block above ${halt_height}"
  elapsed_after_ready="$(wait_for_height_above "${halt_height}" 900)"
  total_rto=$(( ready_t - recover_t0 + elapsed_after_ready ))
  pass "halt duration ${halt_duration}s -> first new block ${elapsed_after_ready}s after pods Ready (RTO from scale-up: ${total_rto}s)"

  log "--- post-recovery: steady state ---"
  assert_chain_advancing 20
  for n in 1 2 3 4; do
    log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
  done
}

step_coordinated_restart() {
  local inject_t0 halt_height restart_t0 ready_t elapsed_after_ready total_rto v n downed
  local all=(1 2 3 4) survivors=()

  # survivors = every validator NOT in the downed pair (they hold the inflated
  # in-memory round state, so they are the ones that must be restarted to reset it).
  for n in "${all[@]}"; do
    downed=0
    for v in "${TARGET_VALIDATORS[@]}"; do [[ "${n}" == "${v}" ]] && downed=1; done
    (( downed )) || survivors+=("${n}")
  done

  log "=== STEP 3: coordinated restart after quorum loss (reset round backoff) ==="
  log "--- inject: take down validators ${TARGET_VALIDATORS[*]} (quorum broken) ---"
  inject_t0=$(date +%s)
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" scale "statefulset/${RELEASE}-validator${v}" --replicas=0 >/dev/null
  done
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" wait --for=delete "pod/${RELEASE}-validator${v}-0" --timeout=120s >/dev/null
  done

  # Hold the halt long enough that round-change has backed off substantially —
  # HALT_WINDOW=300 is the deepest point Step 2 measured (~588s wait if you just
  # wait it out). This step does NOT wait it out.
  log "--- hold: let round-change back off for ${HALT_WINDOW}s ---"
  assert_chain_halted "${HALT_WINDOW}"
  halt_height="$(block_height)"
  log "chain halted at height ${halt_height} after ${HALT_WINDOW}s of backoff"

  log "--- coordinated restart: bring back ${TARGET_VALIDATORS[*]} + restart survivors ${survivors[*]} together ---"
  restart_t0=$(date +%s)
  # Bring the downed pair back up...
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" scale "statefulset/${RELEASE}-validator${v}" --replicas=1 >/dev/null
  done
  # ...and restart the survivors in parallel. A plain pod delete is a PROCESS
  # restart: the PVC (chain data) is untouched, so each node reloads the last
  # committed block — not a resync — and re-enters consensus at round 0.
  for v in "${survivors[@]}"; do
    kubectl -n "${NAMESPACE}" delete pod "${RELEASE}-validator${v}-0" --grace-period=5 >/dev/null 2>&1 &
  done
  wait
  for n in "${all[@]}"; do
    wait_pod_ready "${RELEASE}-validator${n}-0" 300s
  done
  ready_t=$(date +%s)
  # Same RTO decomposition as Step 2, but measured from the coordinated restart.
  # The headline comparison is elapsed_after_ready here vs. Step 2's control at
  # the same HALT_WINDOW (waiting the backoff out).
  log "all four pods Ready ${ready_t} - ${restart_t0} = $(( ready_t - restart_t0 ))s after restart; waiting for first block above ${halt_height}"
  elapsed_after_ready="$(wait_for_height_above "${halt_height}" 900)"
  total_rto=$(( ready_t - restart_t0 + elapsed_after_ready ))
  pass "coordinated restart: first new block ${elapsed_after_ready}s after pods Ready (RTO from restart: ${total_rto}s)"

  log "--- post-recovery: steady state ---"
  assert_chain_advancing 20
  for n in "${all[@]}"; do
    log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
  done
}

step_partial_restart() {
  # Negative-coordination control for Step 3: leave STUCK_SURVIVORS of the
  # survivors at their high round (do NOT restart them) and see whether recovery
  # still skips the backoff. The rule under test: the wait persists iff >= f+1
  # validators remain at the high round (N=4 -> f=1 -> 2 stuck pulls the rest up;
  # 1 stuck cannot). STUCK_SURVIVORS=1 (default) -> 3 fresh nodes (quorum at low
  # round, expect fast); STUCK_SURVIVORS=2 -> 2 fresh (below quorum, expect the
  # full Step 2 wait).
  local inject_t0 halt_height restart_t0 ready_t elapsed_after_ready total_rto v n downed
  local all=(1 2 3 4) survivors=() restart_targets=() keep_stuck=()
  local stuck="${STUCK_SURVIVORS:-1}"

  for n in "${all[@]}"; do
    downed=0
    for v in "${TARGET_VALIDATORS[@]}"; do [[ "${n}" == "${v}" ]] && downed=1; done
    (( downed )) || survivors+=("${n}")
  done
  (( stuck <= ${#survivors[@]} )) || fail "STUCK_SURVIVORS=${stuck} exceeds survivor count ${#survivors[@]}"
  # First `stuck` survivors stay at their high round; the rest get restarted.
  keep_stuck=("${survivors[@]:0:stuck}")
  restart_targets=("${survivors[@]:stuck}")

  log "=== STEP 4: partial restart (leave ${stuck} survivor(s) stuck at high round) ==="
  log "downed=${TARGET_VALIDATORS[*]}  restart=${restart_targets[*]:-none}  left-stuck=${keep_stuck[*]:-none}"
  log "--- inject: take down validators ${TARGET_VALIDATORS[*]} (quorum broken) ---"
  inject_t0=$(date +%s)
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" scale "statefulset/${RELEASE}-validator${v}" --replicas=0 >/dev/null
  done
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" wait --for=delete "pod/${RELEASE}-validator${v}-0" --timeout=120s >/dev/null
  done

  log "--- hold: let round-change back off for ${HALT_WINDOW}s ---"
  assert_chain_halted "${HALT_WINDOW}"
  halt_height="$(block_height)"
  log "chain halted at height ${halt_height} after ${HALT_WINDOW}s of backoff"

  log "--- partial restart: bring back ${TARGET_VALIDATORS[*]} + restart ${restart_targets[*]:-none}; leave ${keep_stuck[*]:-none} stuck ---"
  restart_t0=$(date +%s)
  for v in "${TARGET_VALIDATORS[@]}"; do
    kubectl -n "${NAMESPACE}" scale "statefulset/${RELEASE}-validator${v}" --replicas=1 >/dev/null
  done
  for v in "${restart_targets[@]}"; do
    kubectl -n "${NAMESPACE}" delete pod "${RELEASE}-validator${v}-0" --grace-period=5 >/dev/null 2>&1 &
  done
  wait
  # Wait only on the downed pair + the survivors we restarted; the left-stuck
  # survivors were never taken down, so they are already Ready.
  for v in "${TARGET_VALIDATORS[@]}" "${restart_targets[@]}"; do
    wait_pod_ready "${RELEASE}-validator${v}-0" 300s
  done
  ready_t=$(date +%s)
  log "restarted pods Ready $(( ready_t - restart_t0 ))s after restart; waiting for first block above ${halt_height}"
  elapsed_after_ready="$(wait_for_height_above "${halt_height}" 900)"
  total_rto=$(( ready_t - restart_t0 + elapsed_after_ready ))
  pass "partial restart (${stuck} stuck): first new block ${elapsed_after_ready}s after pods Ready (RTO from restart: ${total_rto}s)"

  log "--- post-recovery: steady state ---"
  assert_chain_advancing 20
  for n in "${all[@]}"; do
    log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
  done
}

case "${STEP}" in
  1)   step_single_validator_loss ;;
  2)   step_quorum_loss ;;
  3)   step_coordinated_restart ;;
  4)   step_partial_restart ;;
  default) step_single_validator_loss; step_quorum_loss ;;
  *)   fail "unknown STEP='${STEP}' (use 1, 2, 3, 4, or default)" ;;
esac

log "=== scenario 01 complete ==="
