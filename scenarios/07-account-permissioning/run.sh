#!/usr/bin/env bash
# Scenario 07 — account permissioning (transaction authorization).
# Spins up its OWN permissioned network (separate namespace/release) so it does
# not perturb the main sbx network or scenario 06's balance-gate demo. With
# account permissioning enabled, a FUNDED but non-allowlisted account is DENIED
# at submission (-32007, never pooled); allowlisting it (perm_addAccountsToAllowlist)
# lets its txs mine; removing it denies again. The test account is genesis-funded,
# so the denial is purely authorization — isolated from scenario 06's balance gate.
#
# Requires the besu-sandbox chart >= 0.2.1 (account permissioning with a writable
# allowlist staging mount; see the chart's doc/account-permissioning.md).
set -euo pipefail
cd "$(dirname "$0")/../.."

export NAMESPACE="${PERM_NAMESPACE:-besu-perm}"
export RELEASE="${PERM_RELEASE:-sbxperm}"
CHART="${CHART:-oci://ghcr.io/jaravan/besu-helmcharts/besu-sandbox}"
CHART_VERSION="${CHART_VERSION:-0.3.2}"
source scripts/lib.sh

RPC_URL="http://${UNIFIED_SVC}:${RPC_PORT}"
DEAD=0x000000000000000000000000000000000000dEaD
KEEP_NETWORK="${KEEP_NETWORK:-0}"

# Genesis-funded dev accounts (keys ship in the chart's genesis alloc).
TREASURY_ADDR=0x57f2faa6a15f9ae1e91a54cc03e41fcb12027c47   # allowlisted at install (lowercase — avoid checksum validation surprises)
T_ADDR=0xe2e0352c8337aaa764f15b47635694f13fb3547d          # funded but NOT allowlisted
T_PK=0xba45bb6bbddcbacc159894e4b6a74457fd9b29fe173424729993c8c363d72293

cleanup() {
  kubectl -n "${NAMESPACE}" delete pod "${CASTER_POD}" "${PROBE_POD}" --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true
  if (( ! KEEP_NETWORK )); then
    log "tearing down ${RELEASE} / namespace ${NAMESPACE}"
    helm uninstall "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
    kubectl delete namespace "${NAMESPACE}" --wait=false >/dev/null 2>&1 || true
  fi
}

t_nonce()  { cast_in "cast nonce ${T_ADDR} --rpc-url ${RPC_URL}" | tr -d '[:space:]'; }

# submit_from_T <nonce> — echoes "SUBMITTED" or "DENIED <error>"
submit_from_T() {
  local out
  out="$(cast_in "cast send --legacy --gas-price 0 --gas-limit 21000 --chain 1337 --async --nonce $1 --private-key ${T_PK} --rpc-url ${RPC_URL} ${DEAD} --value 0 2>&1" || true)"
  if printf '%s' "${out}" | grep -qiE '0x[0-9a-f]{64}'; then echo "SUBMITTED"
  else printf 'DENIED %s' "$(printf '%s' "${out}" | tr '\n' ' ')"; fi
}

# perm_all <add|remove> — toggle T on every validator (each node keeps its own state)
perm_all() {
  local m v; [[ "$1" == add ]] && m=perm_addAccountsToAllowlist || m=perm_removeAccountsFromAllowlist
  for v in 1 2 3 4; do rpc "${m}" "[[\"${T_ADDR}\"]]" "$(validator_svc "${v}")" >/dev/null; done
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT

log "=== install permissioned network: ${RELEASE} (chart ${CHART_VERSION}) in ns ${NAMESPACE} ==="
helm upgrade --install "${RELEASE}" "${CHART}" --version "${CHART_VERSION}" \
  -n "${NAMESPACE}" --create-namespace \
  --set permissioning.accounts.enabled=true \
  --set "permissioning.accounts.allowlist={${TREASURY_ADDR}}" \
  --wait --timeout 600s >/dev/null
ensure_probe
# Fresh install: helm --wait returns when pods are Ready, which does not require
# the chain to have produced yet. Give the new network time to peer and commit
# its first block before asserting liveness.
log "waiting for the fresh network to produce its first block (peering + first round)…"
wait_for_height_above 0 180 >/dev/null
assert_chain_advancing 30
ensure_caster
log "cast: $(cast_in 'cast --version' | head -1)"

log "=== setup check: T funded (genesis) and NOT allowlisted ==="
t_bal="$(cast_in "cast balance ${T_ADDR} --rpc-url ${RPC_URL}" | tr -d '[:space:]')"
log "T (${T_ADDR}) balance=${t_bal}"
log "allowlist: $(rpc perm_getAccountsAllowlist '[]' "$(validator_svc 1)")"
[[ -n "${t_bal}" && "${t_bal}" != "0" ]] || fail "test account T is not funded — cannot isolate permissioning from the balance gate"

log "=== 7a: T (funded, NOT allowlisted) submits — expect DENIED ==="
n="$(t_nonce)"
r="$(submit_from_T "${n}")"
case "${r}" in
  DENIED*) pass "7a: non-allowlisted account DENIED at submission — ${r#DENIED }" ;;
  *)       fail "7a: expected denial, got '${r}'" ;;
esac
[[ "$(t_nonce)" == "${n}" ]] && pass "7a: nonce unchanged (rejected at RPC, never pooled)" || log "7a: nonce moved unexpectedly"

log "=== 7b: allowlist T on all validators — expect MINED ==="
perm_all add
log "allowlist now: $(rpc perm_getAccountsAllowlist '[]' "$(validator_svc 1)")"
n="$(t_nonce)"
r="$(submit_from_T "${n}")"
[[ "${r}" == SUBMITTED ]] || fail "7b: still rejected after allowlisting — ${r}"
mined=0
for i in $(seq 1 15); do [[ "$(t_nonce)" -gt "${n}" ]] && { mined=1; break; }; sleep 3; done
(( mined )) && pass "7b: allowlisted account's tx MINED (nonce ${n} -> $(t_nonce))" || fail "7b: accepted but did not mine"

log "=== 7c: remove T from allowlist — expect DENIED again ==="
perm_all remove
n="$(t_nonce)"
r="$(submit_from_T "${n}")"
case "${r}" in
  DENIED*) pass "7c: after removal, DENIED again — ${r#DENIED }" ;;
  *)       fail "7c: expected denial after removal, got '${r}'" ;;
esac

log "=== scenario 07 complete (network torn down on exit; KEEP_NETWORK=1 to inspect) ==="
