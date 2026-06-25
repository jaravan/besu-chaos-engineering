#!/usr/bin/env bash
# Scenario 03 — slow peer (network degradation).
# Degrade one validator's egress with `tc netem` (latency, then latency+loss,
# then past the round-change timeout). With N=4 the other three are exactly
# quorum (2f+1=3), so the chain must keep producing; the slow node disrupts only
# the rounds where it is proposer and silently removes the network's fault
# tolerance. Shaping is egress-only via a privileged ephemeral container sharing
# the pod's netns (ensure_netns_container / netns in lib.sh — same mechanism as
# scenario 02's partition, tc instead of iptables).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

TARGET_VALIDATOR="${TARGET_VALIDATOR:-4}"  # which validator to degrade
TARGET_POD="${RELEASE}-validator${TARGET_VALIDATOR}-0"
TARGET_SVC="$(validator_svc "${TARGET_VALIDATOR}")"
HEALTHY_SVC="$(validator_svc 1)"          # liveness reference (not degraded)
HEALTHY_POD="${RELEASE}-validator1-0"
DEGRADE_WINDOW="${DEGRADE_WINDOW:-40}"     # seconds to hold each degradation step (3a/3b)
IFACE="${IFACE:-eth0}"                      # pod interface to shape

SHAPED=0  # tracks whether netem is currently applied, so cleanup can undo it

shape()   { netns "${TARGET_POD}" "tc qdisc replace dev ${IFACE} root netem $1"; SHAPED=1; }
unshape() { netns "${TARGET_POD}" "tc qdisc del dev ${IFACE} root netem 2>/dev/null || true"; SHAPED=0; }

cleanup() {
  cleanup_probe
  # Safety net: never leave the validator shaped if the run exits early.
  (( SHAPED )) && netns "${TARGET_POD}" "tc qdisc del dev ${IFACE} root netem 2>/dev/null || true" >/dev/null 2>&1 || true
}

# assert_advancing_via <svc> <window> — liveness against a specific (healthy) node,
# so the slow node's own degraded RPC never skews the reading.
assert_advancing_via() {
  local svc="$1" window="${2:-30}" start now waited=0
  start="$(block_height "${svc}")"
  [[ -n "${start}" ]] || fail "no RPC response from ${svc} while checking liveness"
  while (( waited < window )); do
    sleep 3; (( waited += 3 ))
    now="$(block_height "${svc}")"
    if [[ -n "${now}" ]] && (( now > start )); then
      pass "chain advancing via ${svc} (${start} -> ${now} in ${waited}s)"
      return 0
    fi
  done
  fail "chain did not advance via ${svc} within ${window}s"
}

# round_changes <window> — count blocks committed at round > 0 on the healthy
# node within the window. A non-zero round means a proposer slot timed out and
# consensus round-changed to the next proposer — here, the slow node's slot
# round-changing to a healthy node. Both engines stamp the committed round on the
# block-import line (`Sequence=X, Round=Y`), but the line text differs:
#   QBFT     "QbftRound | Importing block to chain ..." (older builds:
#            "Importing proposed block ... Round=N")
#   IBFT 2.0 "IbftRound | Importing block to chain. round=ConsensusRoundIdentifier{...}"
# Match either phrasing and count the ones at Round>=1.
round_changes() {
  kubectl -n "${NAMESPACE}" logs "${HEALTHY_POD}" --since="$1s" 2>/dev/null \
    | grep -E 'Importing (proposed block|block to chain)' \
    | grep -cE 'Round=[1-9]' || true
}

# slow_gap — blocks the degraded node is behind head (healthy node = head)
slow_gap() {
  local head node
  head="$(block_height "${HEALTHY_SVC}")"
  node="$(block_height "${TARGET_SVC}")"
  if [[ -n "${head}" && -n "${node}" ]]; then printf '%d (node=%d head=%d)' "$(( head - node ))" "${node}" "${head}"
  else printf 'unknown (node=%s head=%s)' "${node:-?}" "${head:-?}"; fi
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT          # always run cleanup (unshape + probe teardown) on exit
ensure_probe

# Confirm the chain is healthy before we degrade anything, so later failures
# are attributable to the shaping rather than a pre-existing problem.
log "=== baseline (consensus=${CONSENSUS}) ==="
assert_chain_advancing 20
log "attaching netns container to ${TARGET_POD}"
ensure_netns_container "${TARGET_POD}"  # privileged sidecar that runs tc in the pod's netns

log "=== 3a: latency only (netem delay 400ms on validator${TARGET_VALIDATOR} ${IFACE}) ==="
shape "delay 400ms"
sleep "${DEGRADE_WINDOW}"
assert_advancing_via "${HEALTHY_SVC}" 30
log "3a: slow node gap = $(slow_gap); round-changes on healthy node in ~${DEGRADE_WINDOW}s = $(round_changes "${DEGRADE_WINDOW}")"

log "=== 3b: latency + loss (netem delay 800ms loss 25%) ==="
shape "delay 800ms loss 25%"
sleep "${DEGRADE_WINDOW}"
assert_advancing_via "${HEALTHY_SVC}" 40
log "3b: slow node gap = $(slow_gap); round-changes on healthy node in ~${DEGRADE_WINDOW}s = $(round_changes "${DEGRADE_WINDOW}")"

# 3c crosses the BFT round-change timeout. requesttimeoutseconds=10 here, so a
# 12s egress delay means the slow node's proposal can never arrive before the
# healthy nodes' round timer fires: its proposer slots round-change while the
# other three (exactly quorum) keep committing. This is "effectively excluded
# without formal removal" — and the network now has zero fault tolerance.
HEAVY_WINDOW="${HEAVY_WINDOW:-50}"
log "=== 3c: delay 12s (> requesttimeoutseconds=10) — cross the round-change cliff ==="
shape "delay 12000ms"
sleep "${HEAVY_WINDOW}"
assert_advancing_via "${HEALTHY_SVC}" 40
rc="$(round_changes "${HEAVY_WINDOW}")"
log "3c: slow node gap = $(slow_gap); round-changed blocks (Round>0) on healthy node in ~${HEAVY_WINDOW}s = ${rc}"
log "recent block-import rounds on healthy node (Round>0 = proposer slot that round-changed):"
kubectl -n "${NAMESPACE}" logs "${HEALTHY_POD}" --since="${HEAVY_WINDOW}s" 2>/dev/null \
  | grep -E 'Importing (proposed block|block to chain)' \
  | sed -E 's/.*(Sequence=[0-9]+, Round=[0-9]+).*/\1/' | tail -6 || true
(( rc > 0 )) || fail "expected round-changes once egress delay exceeds requesttimeoutseconds, saw none"
pass "3c: chain kept advancing on 3-of-4 while the slow node's proposer slots round-changed (${rc} blocks at Round>0)"

log "=== recover: remove netem, verify slow node catches up ==="
unshape
# Poll until the slow node is within 3 blocks of head: 60 tries x 3s sleep = 180s budget.
caught=0
for i in $(seq 1 60); do
  head="$(block_height "${HEALTHY_SVC}")"; node="$(block_height "${TARGET_SVC}")"
  if [[ -n "${head}" && -n "${node}" ]] && (( head - node <= 3 )); then
    pass "03: degraded validator recovered (gap $(( head - node )), node=${node}, head=${head})"
    caught=1; break
  fi
  sleep 3
done
(( caught )) || fail "degraded validator did not catch up within 180s of removing netem"

log "=== post-recovery: steady state ==="
assert_chain_advancing 20
for n in 1 2 3 4; do
  log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
done

log "=== scenario 03 complete ==="
