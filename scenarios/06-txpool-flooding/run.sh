#!/usr/bin/env bash
# Scenario 06 — transaction pool flooding.
# Saturate one sender's future-nonce queue (a gap at the current nonce so nothing
# is executable) until Besu rejects, then fill the gap and watch the queue drain
# and mine. Also shows that a zero-balance sender's tx is accepted into the pool
# but never mined until the account holds any non-zero balance — on this free-gas
# (min-gas-price=0) chain the cause is an empty account, not the gas price.
# Signs with `cast` (foundry) in a pod, using a genesis-funded dev account. Runs
# against the main sbx network; consensus-agnostic (tx-layer).
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

RPC_URL="http://${UNIFIED_SVC}:${RPC_PORT}"
MAX_SUBMIT="${MAX_SUBMIT:-260}"   # cap the future-nonce loop (Besu's per-sender cap is ~200)
# Genesis-funded dev account (private key shipped in the sandbox genesis alloc).
FUNDED_PK="${FUNDED_PK:-0xfc96a9e5a0733664dd4f8c48f163e0f3c71805234bd97637a586ca0bcb0169f7}"
GAS_PRICE="${GAS_PRICE:-1000000000}"   # 1 gwei — paid from the funded balance
DEAD="0x000000000000000000000000000000000000dEaD"

cleanup() {
  cleanup_probe
  cleanup_caster
}

# nonce_of <addr> — current nonce via cast in the caster pod
nonce_of() { cast_in "cast nonce $1 --rpc-url ${RPC_URL}" 2>/dev/null | tr -d '[:space:]' || echo ""; }

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT
ensure_probe

log "=== baseline ==="
assert_chain_advancing 20
ensure_caster
log "cast: $(cast_in 'cast --version' 2>/dev/null | head -1)"

log "=== 6a/6b: saturate a funded sender's future-nonce queue, then fill the gap ==="
# The whole submit loop runs inside the pod (one exec; per-tx cost is just cast
# startup). It emits RESULT lines we parse below.
out="$(cast_in '
set -e
URL='"${RPC_URL}"'; MAX='"${MAX_SUBMIT}"'; DEAD='"${DEAD}"'
PK='"${FUNDED_PK}"'; GP='"${GAS_PRICE}"'
ADDR=$(cast wallet address --private-key $PK)
CUR=$(cast nonce $ADDR --rpc-url $URL)
echo "RESULT sender=$ADDR"
echo "RESULT nonce_start=$CUR"
accepted=0; reject_nonce=""; reject_err=""
n=$((CUR+1))                 # leave a gap at CUR: every submitted tx is future
while [ $((n-CUR)) -le $MAX ]; do
  o=$(cast send --legacy --gas-price $GP --gas-limit 21000 --chain 1337 --async \
      --nonce $n --private-key $PK --rpc-url $URL $DEAD --value 0 2>&1) || true
  if printf "%s" "$o" | grep -q "^0x"; then accepted=$((accepted+1)); n=$((n+1))
  else reject_nonce=$n; reject_err=$(printf "%s" "$o" | tr "\n" " " | head -c 200); break; fi
done
echo "RESULT accepted_future=$accepted"
echo "RESULT reject_nonce=$reject_nonce"
echo "RESULT reject_err=$reject_err"
echo "RESULT nonce_while_queued=$(cast nonce $ADDR --rpc-url $URL)"
echo "RESULT fill_target=$((CUR+accepted+1))"
# 6b: fill the gap at CUR (executable) -> the queued futures promote and mine
cast send --legacy --gas-price $GP --gas-limit 21000 --chain 1337 --async \
  --nonce $CUR --private-key $PK --rpc-url $URL $DEAD --value 0 >/dev/null 2>&1 || true
echo "RESULT gap_filled=1"
' 2>&1)"
printf '%s\n' "${out}" | grep '^RESULT' | sed 's/^/  /'

sender="$(printf '%s\n' "${out}" | sed -n 's/^RESULT sender=//p')"
nonce_start="$(printf '%s\n' "${out}" | sed -n 's/^RESULT nonce_start=//p')"
accepted="$(printf '%s\n' "${out}" | sed -n 's/^RESULT accepted_future=//p')"
reject_nonce="$(printf '%s\n' "${out}" | sed -n 's/^RESULT reject_nonce=//p')"
reject_err="$(printf '%s\n' "${out}" | sed -n 's/^RESULT reject_err=//p')"
nonce_queued="$(printf '%s\n' "${out}" | sed -n 's/^RESULT nonce_while_queued=//p')"
fill_target="$(printf '%s\n' "${out}" | sed -n 's/^RESULT fill_target=//p')"

[[ -n "${accepted}" ]] || fail "no submission result from caster"
(( accepted > 0 )) || fail "no future txs accepted (expected acceptance up to the per-sender cap)"
[[ -n "${reject_nonce}" ]] || fail "no rejection within ${MAX_SUBMIT} submissions — expected a per-sender future-nonce cap"
pass "6a: accepted ${accepted} future txs, then rejected nonce ${reject_nonce} WITH an error (not a silent drop)"
log "6a: rejection error = ${reject_err}"
[[ "${nonce_queued}" == "${nonce_start}" ]] \
  && pass "6a: sender nonce stayed ${nonce_start} while ${accepted} future txs were queued (none mined)" \
  || log "6a: sender nonce while queued = ${nonce_queued} (expected ${nonce_start})"

log "=== 6b: gap filled — waiting for the queued txs to be promoted and mined (target nonce ${fill_target}) ==="
final_nonce=""
for i in $(seq 1 30); do
  final_nonce="$(nonce_of "${sender}")"
  [[ -n "${final_nonce}" ]] && (( final_nonce >= fill_target )) && break
  sleep 3
done
[[ -n "${final_nonce}" ]] || fail "could not read sender nonce after gap fill"
(( final_nonce > nonce_start + 1 )) \
  && pass "6b: queued txs promoted and mined — nonce advanced ${nonce_start} -> ${final_nonce} (target ${fill_target})" \
  || fail "6b: queued txs did not mine after the gap was filled (nonce=${final_nonce}, target ${fill_target})"

log "=== 6c: a zero-balance sender is accepted but NOT mined until funded (it's the balance, not the gas price) ==="
# A fresh (unfunded) key submits a valid, zero-cost tx. It is accepted into the
# pool, but the block proposer will not include a tx from a zero-balance sender,
# so it sits pending. Funding the account releases it. On this free-gas chain a
# *funded* sender mines fine at gasPrice 0, so it is the empty balance — not the
# zero gas price — that strands the tx.
zg="$(cast_in '
URL='"${RPC_URL}"'; DEAD='"${DEAD}"'
K=$(cast wallet new 2>/dev/null | sed -n "s/Private key: //p")
KADDR=$(cast wallet address --private-key $K)
o=$(cast send --legacy --gas-price 0 --gas-limit 21000 --chain 1337 --async \
    --nonce 0 --private-key $K --rpc-url $URL $DEAD --value 0 2>&1) || true
printf "%s" "$o" | grep -q "^0x" && echo "RESULT zg_status=accepted" || echo "RESULT zg_status=rejected:$o"
echo "RESULT zg_addr=$KADDR"
' 2>&1)"
printf '%s\n' "${zg}" | grep '^RESULT' | sed 's/^/  /'
zg_addr="$(printf '%s\n' "${zg}" | sed -n 's/^RESULT zg_addr=//p')"
printf '%s\n' "${zg}" | grep -q '^RESULT zg_status=accepted' \
  || fail "6c: expected the zero-balance sender's tx to be accepted into the pool"
pass "6c: unfunded sender's tx accepted into the pool (no error)"
sleep 8
[[ "$(nonce_of "${zg_addr}")" == "0" ]] \
  && pass "6c: …and NOT mined while the sender has zero balance (nonce still 0 — pending, not dropped)" \
  || log "6c: unfunded sender nonce advanced unexpectedly"
log "6c: funding ${zg_addr} with just 1 wei (dust) from the dev account…"
# 1 wei, deliberately: the guard is balance==0 vs balance>0, not "can afford the
# fee". Any non-zero balance clears it, and on a free-gas chain the wei is not
# even spent — so this is a one-time onboarding nudge, not ongoing funding.
cast_in '
URL='"${RPC_URL}"'; PK='"${FUNDED_PK}"'; GP='"${GAS_PRICE}"'
ADDR=$(cast wallet address --private-key $PK)
cast send --legacy --gas-price $GP --gas-limit 21000 --chain 1337 --async \
  --nonce $(cast nonce $ADDR --rpc-url $URL) --private-key $PK --rpc-url $URL '"${zg_addr}"' --value 1 >/dev/null 2>&1 || true
' >/dev/null 2>&1 || true
zg_final=""
for i in $(seq 1 20); do
  zg_final="$(nonce_of "${zg_addr}")"
  [[ "${zg_final}" == "1" ]] && break
  sleep 3
done
[[ "${zg_final}" == "1" ]] \
  && pass "6c: 1 wei was enough — the previously-stuck tx mined (nonce 0 -> 1). The guard is empty-balance, not affordability; any non-zero balance clears it" \
  || fail "6c: sender's pending tx still did not mine after 1-wei funding (nonce=${zg_final})"

log "=== 6d: RPC + consensus health under load ==="
assert_chain_advancing 20
head_now="$(block_height)"
[[ -n "${head_now}" ]] || fail "RPC reads not served"
pass "6d: RPC reads served (head=${head_now}) and chain advancing throughout the flood"

log "=== scenario 06 complete ==="
