#!/usr/bin/env bash
# Scenario 04 — validator-set governance (vote-based remove/re-add + vote durability).
# The existing validators vote a member out of the set and back in at runtime via
# <engine>_proposeValidatorVote — no restart, no genesis/chart change. This is the
# durable counterpart to the *transient* validator loss in scenario 01: there a
# node went down and the set was unchanged; here the set itself is deliberately,
# consensus-changed. Then the governance state itself is probed:
#   4a  lifecycle  — vote out (applies on majority, not at an epoch boundary), chain
#                    holds at N=3, vote back in, and the re-added node is confirmed to
#                    PROPOSE again (blocks proposed since rejoin — not the noisy
#                    sliding-window proposedBlockCount, which oscillates near parity)
#   4b  restart    — a restart drops the node's in-memory intent (stops re-stamping)
#                    but does NOT retract a vote already on-chain, using a phantom 5th
#                    address: (i) stay silent -> the stamped vote still counts (4->5);
#                    (ii) vote the opposite -> overrides it (stays 4); (iii) cross an
#                    epoch boundary -> the abandoned vote is flushed (stays 4).
#   4c  vote scope — (i) getPendingVotes is per-node: a vote cast on one node is
#       & epoch       invisible from another (query every validator); (ii) on a
#                     short-epoch deploy a *live* proposal PERSISTS across an epoch
#                     boundary (the node re-adds it) — the converse of 4b(iii).
#   4d  forensics  — from ONE node, reconstruct who voted what/when by reading block
#                    headers (.miner = voter, .extraData = vote) — no peer RPC needed.
# Engine-independent — QBFT and IBFT 2.0 expose the same RPCs, only the namespace
# differs (qbft_* vs ibft_*), resolved from CONSENSUS via consensus_rpc_ns (lib.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

NS="$(consensus_rpc_ns)"               # qbft | ibft — RPC namespace for the deployed engine
# shellcheck disable=SC2206 # word-splitting is the interface: a space-separated list
VOTERS=(${VOTERS:-1 2 3})              # 3 of 4 = majority for N=4; each casts on its OWN node
APPLY_TIMEOUT="${APPLY_TIMEOUT:-60}"   # seconds to wait for a vote to apply at a block boundary
QUERY_SVC="$(validator_svc 1)"         # read the set from validator1 — stays a validator throughout
RESTART_VALIDATOR="${RESTART_VALIDATOR:-1}"   # node used for the 4b restart test (a voter, never the target)
RESTART_SVC="$(validator_svc "${RESTART_VALIDATOR}")"
RESTART_POD="${RELEASE}-validator${RESTART_VALIDATOR}-0"
VOTE_NODE="${VOTE_NODE:-2}"            # 4c caster (its own proposal); != PEER_NODE
PEER_NODE="${PEER_NODE:-1}"           # 4c peer — shows the vote is NOT visible here
RESUME_WINDOW="${RESUME_WINDOW:-40}"  # 4a: seconds to confirm the re-added node proposes again
# 4c epoch check only runs when the boundary is reachable in-session; a default
# 30000-block epoch (~16h at 2s) is skipped with guidance. EPOCH_WAIT caps the wait.
EPOCH_TEST_MAX="${EPOCH_TEST_MAX:-1000}"
EPOCH_WAIT="${EPOCH_WAIT:-300}"
# 4b uses a fake 5th-validator address (no node — just an address) so the experiment
# never touches the real four validators' membership; it is added/removed instead.
PHANTOM="${PHANTOM:-0xabcdef0123456789abcdef0123456789abcdef01}"

# Two voters other than the restarted node; restarted-stamped + these two = majority of 4.
OTHER2=()
for _v in 1 2 3 4; do [[ "${_v}" != "${RESTART_VALIDATOR}" ]] && OTHER2+=("${_v}"); done
OTHER2=("${OTHER2[@]:0:2}")
B_READER_SVC="$(validator_svc "${OTHER2[0]}")"   # 4b reads the set from a node it never restarts

TARGET=""                              # address being voted out/in (filled at baseline)
REMOVED=0                              # 1 once TARGET is voted out, so cleanup can re-add it
PHANTOM_ADDED=0                        # 1 while PHANTOM is in the set, so cleanup can vote it out

# validator_set — raw JSON-RPC response listing the current validators
validator_set() { rpc "${NS}_getValidatorsByBlockNumber" '["latest"]' "${QUERY_SVC}"; }
# set_addrs — just the unique validator addresses, space-separated
set_addrs() { validator_set | grep -o '0x[0-9a-fA-F]\{40\}' | sort -u | tr '\n' ' '; }
# set_size — count of unique validator addresses
set_size() { validator_set | grep -o '0x[0-9a-fA-F]\{40\}' | sort -u | wc -l | tr -d ' '; }
# in_set <addr> — yes/no membership
in_set() { validator_set | grep -qi "$1" && echo yes || echo no; }
# pending_on <svc> — that node's standing (locally proposed) votes
pending_on() { rpc "${NS}_getPendingVotes" '[]' "$1"; }

# vote <addr> <true|false> — each voter proposes the change on its own node. A
# change applies once more than half of the CURRENT validators agree.
vote() {
  local v
  for v in "${VOTERS[@]}"; do
    rpc "${NS}_proposeValidatorVote" "[\"$1\", $2]" "$(validator_svc "$v")" >/dev/null
  done
}
# discard <addr> — clear any standing proposal for addr on every voter (clean tally)
discard() {
  local v
  for v in "${VOTERS[@]}"; do
    rpc "${NS}_discardValidatorVote" "[\"$1\"]" "$(validator_svc "$v")" >/dev/null 2>&1 || true
  done
}
# proposed_count <addr> — that validator's proposedBlockCount (decimal), or '?'.
# A removed validator's count stops climbing; it resumes after re-add.
proposed_count() {
  local hex
  hex="$(rpc "${NS}_getSignerMetrics" '[]' "${QUERY_SVC}" \
    | tr '}' '\n' | grep -i "$1" | grep -o 'proposedBlockCount":"0x[0-9a-fA-F]*"' \
    | grep -o '0x[0-9a-fA-F]*' | head -1)"
  [[ -n "${hex}" ]] && printf '%d' "${hex}" || printf '?'
}
# proposed_in_range <addr> <from-decimal> — blocks <addr> proposed in [from, latest].
# A cumulative count over an explicit range, unlike the default sliding window — so
# a value > 0 proves the node proposed after <from> (e.g. after rejoining the set).
proposed_in_range() {
  local addr="$1" from_hex hex
  from_hex="$(printf '0x%x' "$2")"     # getSignerMetrics needs hex-quoted block numbers
  hex="$(rpc "${NS}_getSignerMetrics" "[\"${from_hex}\", \"latest\"]" "${QUERY_SVC}" \
    | tr '}' '\n' | grep -i "${addr}" | grep -o 'proposedBlockCount":"0x[0-9a-fA-F]*"' \
    | grep -o '0x[0-9a-fA-F]*' | head -1)"
  if [[ -n "${hex}" ]]; then printf '%d\n' "${hex}"; else echo 0; fi
}
# epochlength — read from the deployed genesis configmap (engine-agnostic key).
# The configmap stores genesis as a JSON-escaped string (\"epochlength\": N), so
# match loosely on the key name and pull the number. Always returns 0 (|| true)
# so a parse miss is handled by the caller, not aborted by set -e/pipefail.
epochlength() {
  local data
  data="$(kubectl -n "${NAMESPACE}" get configmap "${RELEASE}-genesis" -o jsonpath='{.data}' 2>/dev/null || true)"
  printf '%s' "${data}" | tr ',' '\n' | grep -i epochlength | grep -oE '[0-9]+' | head -1 || true
}

# --- 4d single-node forensics helpers ------------------------------------------
# Everything here reads only QUERY_SVC (validator1) — the data a consortium operator
# has from their own node, with no access to peers' RPC.
# set_size_at <blockhex> — validator-set size as of a specific historical block.
set_size_at() {
  rpc "${NS}_getValidatorsByBlockNumber" "[\"$1\"]" "${QUERY_SVC}" \
    | grep -o '0x[0-9a-fA-F]\{40\}' | sort -u | wc -l | tr -d ' '
}
# block_field <blockhex> <miner|extraData> — read one header field from a block.
block_field() {
  rpc eth_getBlockByNumber "[\"$1\", false]" "${QUERY_SVC}" \
    | grep -o "\"$2\":\"0x[0-9a-fA-F]*\"" | grep -o '0x[0-9a-fA-F]*' | head -1
}

# --- 4b helpers (phantom add/remove; reads via a node we never restart) ---------
# set_size_via <svc> — current validator-set size, read from a specific node.
set_size_via() {
  rpc "${NS}_getValidatorsByBlockNumber" '["latest"]' "$1" \
    | grep -o '0x[0-9a-fA-F]\{40\}' | sort -u | wc -l | tr -d ' '
}
# clear_phantom — discard any standing PHANTOM proposal on every node (no-op if none).
clear_phantom() {
  local v
  for v in 1 2 3 4; do
    rpc "${NS}_discardValidatorVote" "[\"${PHANTOM}\"]" "$(validator_svc "$v")" >/dev/null 2>&1 || true
  done
}
# phantom_stamped <since-block> — echo the first block > since whose header carries a
# vote about PHANTOM, else empty. PHANTOM is not in the set, so ANY appearance of its
# address in a header is a vote about it — engine-agnostic, no add/remove decode needed.
phantom_stamped() {
  local since="$1" ph="${PHANTOM#0x}" head b
  head="$(block_height "${B_READER_SVC}")"; [[ -n "${head}" ]] || return 0
  for (( b = head; b > since; b-- )); do
    if rpc eth_getBlockByNumber "[\"$(printf '0x%x' "${b}")\", false]" "${B_READER_SVC}" \
        | grep -qi "${ph}"; then echo "${b}"; return 0; fi
  done
}
# wait_phantom_stamped <since> — poll until PHANTOM appears in a header; echo block or empty.
wait_phantom_stamped() {
  local since="$1" r i
  for (( i = 0; i < 20; i++ )); do
    r="$(phantom_stamped "${since}")"; [[ -n "${r}" ]] && { echo "${r}"; return 0; }
    sleep 2
  done
}
# remove_phantom — vote PHANTOM back out (majority of the 5-set) and confirm set == 4.
remove_phantom() {
  local v w=0
  clear_phantom
  for v in "${OTHER2[@]}" "${RESTART_VALIDATOR}"; do
    rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", false]" "$(validator_svc "$v")" >/dev/null 2>&1 || true
  done
  while (( w < APPLY_TIMEOUT )); do
    sleep 3; (( w += 3 ))
    [[ "$(set_size_via "${B_READER_SVC}")" == "4" ]] && { PHANTOM_ADDED=0; break; }
  done
  clear_phantom
}

# wait_set <want_size> <addr> <yes|no> — poll until the set matches; echo elapsed.
# The change lands a few blocks after the majority vote, not instantly.
wait_set() {
  local want_size="$1" addr="$2" want_present="$3" waited=0
  while (( waited < APPLY_TIMEOUT )); do
    sleep 3; (( waited += 3 ))
    if [[ "$(set_size)" == "${want_size}" && "$(in_set "${addr}")" == "${want_present}" ]]; then
      echo "${waited}"; return 0
    fi
  done
  return 1
}

cleanup() {
  # Safety net: if we voted TARGET out but never got it back in (early exit),
  # re-add it so the run never leaves the validator set short.
  if (( REMOVED )) && [[ -n "${TARGET}" ]]; then
    discard "${TARGET}"; vote "${TARGET}" true >/dev/null 2>&1 || true
  fi
  # Clear any standing minority proposal left by 4c on every node (no-op if none).
  if [[ -n "${TARGET}" ]]; then
    for v in 1 2 3 4; do
      rpc "${NS}_discardValidatorVote" "[\"${TARGET}\"]" "$(validator_svc "$v")" >/dev/null 2>&1 || true
    done
  fi
  # 4b phantom: drop any standing proposals; if PHANTOM ended up in the set, vote it out.
  clear_phantom 2>/dev/null || true
  (( PHANTOM_ADDED )) && remove_phantom 2>/dev/null || true
  cleanup_probe
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT
ensure_probe

log "=== baseline (consensus=${CONSENSUS}, rpc-ns=${NS}) ==="
assert_chain_advancing 20
base_size="$(set_size)"
log "validator set (${base_size}): $(set_addrs)"
(( base_size == 4 )) || fail "expected 4 validators at baseline, got ${base_size}"
BASE_H="$(block_height "${QUERY_SVC}")"   # a block known to hold the full set — lower bracket for 4d
# Vote out the last address in the (sorted) set — arbitrary but deterministic.
TARGET="$(validator_set | grep -o '0x[0-9a-fA-F]\{40\}' | sort -u | tail -1)"
log "target to vote out/in: ${TARGET} (proposedBlockCount=$(proposed_count "${TARGET}"))"

# --- 4a: lifecycle — vote a member out and back in -----------------------------
log "=== 4a: remove — vote '${TARGET}' OUT on validators ${VOTERS[*]} (majority of 4) ==="
discard "${TARGET}"                    # start from a clean tally
vote "${TARGET}" false
elapsed="$(wait_set 3 "${TARGET}" no)" \
  || fail "set did not drop to 3 without ${TARGET} within ${APPLY_TIMEOUT}s (set=$(validator_set))"
REMOVED=1
RM_APPLIED_H="$(block_height "${QUERY_SVC}")"   # height once removal applied (size==3) — upper bracket for 4d
pass "4a: validator removed by vote in ${elapsed}s — set now 3, ${TARGET} gone"
# Quorum held (N=3 -> quorum 2): the chain must still be producing.
assert_chain_advancing 20
log "removed validator still a node, no longer proposing (proposedBlockCount=$(proposed_count "${TARGET}")); set=$(set_addrs)"

log "=== 4a: re-add — vote '${TARGET}' IN on validators ${VOTERS[*]} (majority of 3) ==="
discard "${TARGET}"
vote "${TARGET}" true
elapsed="$(wait_set 4 "${TARGET}" yes)" \
  || fail "set did not return to 4 with ${TARGET} within ${APPLY_TIMEOUT}s (set=$(validator_set))"
REMOVED=0
pass "4a: validator re-added by vote in ${elapsed}s — set back to 4, ${TARGET} present"
assert_chain_advancing 20
# Confirm it actually PROPOSES again. The sliding-window proposedBlockCount only
# oscillates near parity (~N/total), so count blocks it proposes strictly after
# rejoining instead — a value > 0 is unambiguous.
readd_block="$(block_height "${QUERY_SVC}")"
log "4a: re-added at block ${readd_block}; waiting ${RESUME_WINDOW}s to confirm it proposes again…"
sleep "${RESUME_WINDOW}"
proposed_since="$(proposed_in_range "${TARGET}" "${readd_block}")"
(( proposed_since > 0 )) \
  && pass "4a: re-added validator resumed proposing — ${proposed_since} block(s) since rejoining at ${readd_block}" \
  || fail "4a: re-added validator proposed no block in ${RESUME_WINDOW}s after rejoining"

# Discard the now-applied standing proposal so the tally is clean before 4b.
discard "${TARGET}"
pending=""
for i in $(seq 1 10); do
  pending="$(rpc "${NS}_getPendingVotes" '[]' "${QUERY_SVC}")"
  echo "${pending}" | grep -q '"result":{}' && break
  sleep 2
done
echo "${pending}" | grep -q '"result":{}' \
  && pass "4a: pending votes cleared — validator set left clean at 4" \
  || fail "pending votes did not clear after discard: ${pending}"

# --- 4b: a restart drops INTENT, but does not retract an already-cast vote -------
# Two experiments with a phantom 5th-validator address (no node). N=4 -> majority 3.
# The restarted node is RESTART_VALIDATOR (default 1); OTHER2 are two other voters.
# Reads use B_READER_SVC (a node we never restart) so RPC stays available throughout.
restart_rv() {  # restart the RESTART_VALIDATOR pod and wait until it is Ready again
  kubectl -n "${NAMESPACE}" delete pod "${RESTART_POD}" --wait=true --grace-period=10 >/dev/null
  wait_pod_ready "${RESTART_POD}"; sleep 8
}

log "=== 4b(i): restart, then stay silent — does the node's already-cast vote still count? ==="
clear_phantom
(( $(set_size_via "${B_READER_SVC}") == 4 )) || fail "4b(i): expected a clean 4-validator set to start"
cb="$(block_height "${B_READER_SVC}")"
rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", true]" "${RESTART_SVC}" >/dev/null
log "4b(i): validator${RESTART_VALIDATOR} voted add(PHANTOM); waiting for it to be STAMPED into a header…"
sb="$(wait_phantom_stamped "${cb}")"
[[ -n "${sb}" ]] || fail "4b(i): add(PHANTOM) was never stamped into a header — cannot run the test"
log "4b(i): stamped at block ${sb}; restarting validator${RESTART_VALIDATOR} (quorum holds on the other 3)…"
restart_rv
ap="$(pending_on "${RESTART_SVC}")"
echo "${ap}" | grep -q '"result":{}' \
  && log "4b(i): after restart, getPendingVotes on validator${RESTART_VALIDATOR} = {} — intent dropped, it will not re-stamp" \
  || fail "4b(i): expected validator${RESTART_VALIDATOR} pending to be empty after restart, got: ${ap}"
log "4b(i): the other two validators (${OTHER2[*]}) now vote add(PHANTOM) — 2 live + 1 restarted-stamped…"
for v in "${OTHER2[@]}"; do rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", true]" "$(validator_svc "$v")" >/dev/null; done
added=0 waited=0
while (( waited < APPLY_TIMEOUT )); do
  sleep 3; (( waited += 3 ))
  (( $(set_size_via "${B_READER_SVC}") == 5 )) && { added=1; PHANTOM_ADDED=1; break; }
done
(( added )) \
  && pass "4b(i): PHANTOM added (set 4->5) in ${waited}s — the restarted node's already-stamped vote STILL COUNTED (2 live + 1 restarted-stamped = majority). A restart stops future stamping; it does not retract a vote already on-chain." \
  || fail "4b(i): set never reached 5 — the restarted node's stamped vote was not counted (unexpected)"
remove_phantom
(( $(set_size_via "${B_READER_SVC}") == 4 )) || fail "4b(i): cleanup failed to restore the 4-set"
log "4b(i): cleanup — PHANTOM voted back out, set = 4"

log "=== 4b(ii): restart, then vote the OPPOSITE — does it override the already-cast vote? ==="
clear_phantom
cb="$(block_height "${B_READER_SVC}")"
rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", true]" "${RESTART_SVC}" >/dev/null
sb="$(wait_phantom_stamped "${cb}")"
[[ -n "${sb}" ]] || fail "4b(ii): add(PHANTOM) was never stamped — cannot run the test"
log "4b(ii): validator${RESTART_VALIDATOR} stamped add(PHANTOM) at block ${sb}; restarting…"
restart_rv
echo "$(pending_on "${RESTART_SVC}")" | grep -q '"result":{}' \
  || fail "4b(ii): expected validator${RESTART_VALIDATOR} pending empty after restart"
log "4b(ii): after restart, validator${RESTART_VALIDATOR} votes the OPPOSITE remove(PHANTOM)…"
cb2="$(block_height "${B_READER_SVC}")"
rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", false]" "${RESTART_SVC}" >/dev/null
wait_phantom_stamped "${cb2}" >/dev/null     # let the opposite vote land in a header
echo "$(pending_on "${RESTART_SVC}")" | grep -qi "${PHANTOM#0x}" \
  || fail "4b(ii): expected validator${RESTART_VALIDATOR} to hold the opposite remove(PHANTOM) proposal"
log "4b(ii): the other two validators (${OTHER2[*]}) now vote add(PHANTOM)…"
for v in "${OTHER2[@]}"; do rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", true]" "$(validator_svc "$v")" >/dev/null; done
stayed=1 waited=0
while (( waited < 40 )); do                  # the set must STAY 4 — opposite overrode the stamped add
  sleep 3; (( waited += 3 ))
  (( $(set_size_via "${B_READER_SVC}") != 4 )) && { stayed=0; PHANTOM_ADDED=1; break; }
done
(( stayed )) \
  && pass "4b(ii): PHANTOM NOT added (set stayed 4 for ${waited}s) — the post-restart opposite vote OVERRODE the earlier stamped add (a validator's latest vote wins). This is the real way to retract: vote the opposite." \
  || fail "4b(ii): set changed to $(set_size_via "${B_READER_SVC}") — the opposite vote did not override (unexpected)"
clear_phantom
assert_chain_advancing 20

# 4b(iii): same as (i), but the restarted node's vote must survive an EPOCH BOUNDARY.
# The node restarts (stops re-stamping), so its vote exists only in the PRE-epoch
# headers; once the boundary flushes the collected tally and the node never re-adds it,
# the two live votes alone are a minority and PHANTOM is NOT added. This is the converse
# of 4c(ii) (a *live* proposal survives the epoch because the node keeps re-adding it).
# Needs to cross a boundary in-session, so it only runs on a short-epoch deploy.
EP4B="$(epochlength || true)"
if [[ -z "${EP4B}" ]] || (( EP4B > EPOCH_TEST_MAX )); then
  log "4b(iii) skipped: epochlength=${EP4B:-unknown} too large to cross in-session (deploy EPOCHLENGTH=50 to run it)."
else
  log "=== 4b(iii): restart, then cross an epoch boundary — is the abandoned vote flushed? ==="
  clear_phantom
  # Cast early in an epoch so the stamp is well clear of the boundary the restart will cross.
  while :; do cur="$(block_height "${B_READER_SVC}")"; (( EP4B - (cur % EP4B) >= 20 )) && break; sleep 2; done
  cb="$(block_height "${B_READER_SVC}")"
  rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", true]" "${RESTART_SVC}" >/dev/null
  sb="$(wait_phantom_stamped "${cb}")"
  [[ -n "${sb}" ]] || fail "4b(iii): add(PHANTOM) was never stamped — cannot run the test"
  log "4b(iii): validator${RESTART_VALIDATOR} stamped add(PHANTOM) at block ${sb}; restarting (it will stop re-stamping)…"
  restart_rv
  echo "$(pending_on "${RESTART_SVC}")" | grep -q '"result":{}' \
    || fail "4b(iii): expected validator${RESTART_VALIDATOR} pending empty after restart"
  boundary=$(( (sb / EP4B + 1) * EP4B ))     # first epoch boundary after the stamp
  log "4b(iii): waiting for the chain to cross epoch boundary ${boundary} (the vote at ${sb} is in the prior epoch)…"
  wait_for_height_above "${boundary}" "${EPOCH_WAIT}" >/dev/null
  sleep 4
  log "4b(iii): boundary crossed (now $(block_height "${B_READER_SVC}")); the other two (${OTHER2[*]}) vote add(PHANTOM)…"
  for v in "${OTHER2[@]}"; do rpc "${NS}_proposeValidatorVote" "[\"${PHANTOM}\", true]" "$(validator_svc "$v")" >/dev/null; done
  stayed=1 waited=0
  while (( waited < 40 )); do
    sleep 3; (( waited += 3 ))
    (( $(set_size_via "${B_READER_SVC}") != 4 )) && { stayed=0; PHANTOM_ADDED=1; break; }
  done
  (( stayed )) \
    && pass "4b(iii): PHANTOM NOT added (set stayed 4 for ${waited}s) — the restarted node's vote was cast in the PRIOR epoch and never re-stamped, so the epoch boundary FLUSHED it; only the 2 live votes remained (< majority). The epoch retracts an abandoned stamped vote — the converse of 4c(ii)." \
    || fail "4b(iii): set changed to $(set_size_via "${B_READER_SVC}") — the prior-epoch abandoned vote unexpectedly still counted across the boundary"
  clear_phantom
  assert_chain_advancing 20
fi

# --- 4c: vote scope (per-node) and epoch durability -----------------------------
log "=== 4c: vote visibility (per-node) and epoch durability ==="
VOTE_SVC="$(validator_svc "${VOTE_NODE}")"
PEER_SVC="$(validator_svc "${PEER_NODE}")"
# Cast a MINORITY vote on one node so it never applies; we use it to probe (i) who
# can see it and (ii) whether it survives an epoch boundary.
rpc "${NS}_discardValidatorVote" "[\"${TARGET}\"]" "${VOTE_SVC}" >/dev/null 2>&1 || true
rpc "${NS}_proposeValidatorVote" "[\"${TARGET}\", false]" "${VOTE_SVC}" >/dev/null
sleep 14                               # let the caster propose a block carrying the vote
caster="$(pending_on "${VOTE_SVC}")"
peer="$(pending_on "${PEER_SVC}")"
log "4c(i): pending on caster (validator${VOTE_NODE}): ${caster}"
log "4c(i): pending on peer   (validator${PEER_NODE}): ${peer}"
echo "${caster}" | grep -qi "${TARGET}" || fail "4c(i): caster should report its own proposal, got: ${caster}"
echo "${peer}" | grep -q '"result":{}' \
  && pass "4c(i): getPendingVotes is per-node — only the casting node reports the proposal; validator${PEER_NODE} shows {} (a vote cast on one node is invisible from another, so you must query every validator)" \
  || fail "4c(i): expected validator${PEER_NODE} to show no pending vote (got: ${peer})"

# (ii) epoch boundary — only reachable on a short-epoch deploy.
EPOCH="$(epochlength || true)"
if [[ -z "${EPOCH}" ]] || (( EPOCH > EPOCH_TEST_MAX )); then
  log "4c(ii) skipped: epochlength=${EPOCH:-unknown} is too large to cross in-session."
  log "    To run it, deploy a short epoch (genesis is immutable, so this is a fresh chain):"
  log "    make install CONSENSUS=${CONSENSUS} EPOCHLENGTH=50   # then: make scenario-04 CONSENSUS=${CONSENSUS}"
else
  start="$(block_height)"
  boundary=$(( (start / EPOCH + 1) * EPOCH ))     # next block that is a multiple of epochlength
  log "4c(ii): epochlength=${EPOCH}; at block ${start}, next epoch boundary is block ${boundary}"
  log "4c(ii): waiting for the chain to cross block ${boundary} (cap ${EPOCH_WAIT}s)…"
  elapsed="$(wait_for_height_above "${boundary}" "${EPOCH_WAIT}")"
  sleep 4
  after="$(pending_on "${VOTE_SVC}")"
  log "4c(ii): crossed epoch boundary after ${elapsed}s (now $(block_height)); pending on caster: ${after}"
  # Matches the Besu docs: an epoch transition "discards all pending votes collected
  # from received blocks" (internal, not exposed by getPendingVotes), but "existing
  # proposals remain in effect and validators re-add their vote" — so the caster's
  # OWN standing proposal rides across the boundary. Only discard or a restart (4b)
  # clears it; the epoch does not.
  echo "${after}" | grep -qi "${TARGET}" \
    && pass "4c(ii): caster's own proposal PERSISTED across the epoch boundary (matches docs: existing proposals remain and are re-added) — so a standing proposal is bounded only by discard or a restart, never by the epoch" \
    || fail "4c(ii): caster's proposal cleared at the epoch boundary (got: ${after}) — revisit the README"
  (( $(set_size) == 4 )) || fail "4c(ii): set changed unexpectedly across the epoch boundary"
  assert_chain_advancing 20
fi
rpc "${NS}_discardValidatorVote" "[\"${TARGET}\"]" "${VOTE_SVC}" >/dev/null 2>&1 || true

# --- 4d: single-node forensics — reconstruct WHO voted WHAT from headers alone ---
log "=== 4d: single-node forensics — who voted, from one node's chain data ==="
# A real consortium operator runs ONE node and cannot read peers' getPendingVotes.
# But every vote is on-chain: a block's `miner` is its proposer (= the voter) and its
# `extraData` carries the vote. Using ONLY validator1's RPC, reconstruct 4a's removal —
# find the block where the set dropped 4->3, then read the votes from the preceding
# headers. The vote rides in extraData as RLP [recipient, type]; a DROP for the
# target is `d694<address><type>`, where <type> is 80 (QBFT, RLP false) or 00
# (IBFT 2.0, literal byte) — both verified on this build. So match either.
tgt="$(printf '%s' "${TARGET#0x}" | tr 'A-F' 'a-f')"
lo="${BASE_H}" hi="${RM_APPLIED_H}"
if (( hi > lo )) && (( $(set_size_at "$(printf '0x%x' "${lo}")") == 4 )); then
  # Binary-search the 4->3 transition: invariant size_at(lo)=4, size_at(hi)=3.
  while (( hi - lo > 1 )); do
    mid=$(( (lo + hi) / 2 ))
    if (( $(set_size_at "$(printf '0x%x' "${mid}")") >= 4 )); then lo="${mid}"; else hi="${mid}"; fi
  done
  change="${hi}"
  log "4d: set dropped 4->3 at block ${change} (pinned via getValidatorsByBlockNumber on validator1 alone)"
  # Read the drop-votes for TARGET out of the headers preceding the change. Votes
  # accumulate over several blocks (one per voter's proposer slot), so scan a window.
  voters="" floor=$(( change > 20 ? change - 20 : 1 ))
  for (( b = change - 1; b >= floor; b-- )); do
    hx="$(printf '0x%x' "${b}")"
    if printf '%s' "$(block_field "${hx}" extraData)" | tr 'A-F' 'a-f' | grep -qE "d694${tgt}(80|00)"; then
      m="$(block_field "${hx}" miner)"
      log "4d:   block ${b}: proposer ${m} stamped DROP(${TARGET})"
      case " ${voters} " in *" ${m} "*) : ;; *) voters="${voters}${m} " ;; esac
    fi
  done
  nv="$(printf '%s' "${voters}" | wc -w | tr -d ' ')"
  (( nv >= 2 )) \
    && pass "4d: reconstructed the offboarding from ONE node — ${nv} distinct validators stamped DROP(${TARGET}) into headers before block ${change}; voters: ${voters}" \
    || fail "4d: expected to read >=2 distinct drop-voters from headers, found ${nv} (voters: ${voters:-none})"
else
  log "4d skipped: could not bracket the removal (BASE_H=${BASE_H}, RM_APPLIED_H=${RM_APPLIED_H})"
fi

log "=== post-recovery: steady state ==="
for n in 1 2 3 4; do
  log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
done

log "=== scenario 04 complete ==="
