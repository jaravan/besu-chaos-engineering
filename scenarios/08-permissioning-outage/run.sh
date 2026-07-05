#!/usr/bin/env bash
# Scenario 08 — permissioning outage (allowlist lockout).
# With account permissioning enabled, removing the operational account from the
# allowlist (a wrong/accidental admin change, or a cleared allowlist) locks every
# sender out: eth_sendRawTransaction returns -32007 for ALL accounts and no user
# transaction can be processed — yet QBFT keeps producing (empty) blocks, so the
# network looks healthy. The transaction layer is frozen while consensus is fine.
# Recover by restoring the allowlist (perm_addAccountsToAllowlist on every node).
#
# Self-contained: installs its own permissioned network and tears it down.
# Requires the besu-sandbox chart >= 0.2.1.
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

# The operational account: genesis-funded AND allowlisted at install (the account
# that was working — removing it is the outage).
OP_ADDR=0x57f2faa6a15f9ae1e91a54cc03e41fcb12027c47
OP_PK=0xfc96a9e5a0733664dd4f8c48f163e0f3c71805234bd97637a586ca0bcb0169f7

cleanup() {
  kubectl -n "${NAMESPACE}" delete pod "${CASTER_POD}" "${PROBE_POD}" --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true
  if (( ! KEEP_NETWORK )); then
    log "tearing down ${RELEASE} / namespace ${NAMESPACE}"
    helm uninstall "${RELEASE}" -n "${NAMESPACE}" >/dev/null 2>&1 || true
    kubectl delete namespace "${NAMESPACE}" --wait=false >/dev/null 2>&1 || true
  fi
}

op_nonce() { cast_in "cast nonce ${OP_ADDR} --rpc-url ${RPC_URL}" | tr -d '[:space:]'; }

# submit_op — try a 0-gas tx from the operational account; echo MINED / DENIED <err>
submit_op() {
  local n out i
  n="$(op_nonce)"
  out="$(cast_in "cast send --legacy --gas-price 0 --gas-limit 21000 --chain 1337 --async --nonce ${n} --private-key ${OP_PK} --rpc-url ${RPC_URL} ${DEAD} --value 0 2>&1" || true)"
  if printf '%s' "${out}" | grep -qiE '0x[0-9a-f]{64}'; then
    for i in $(seq 1 8); do [[ "$(op_nonce)" -gt "${n}" ]] && { echo MINED; return; }; sleep 2; done
    echo ACCEPTED_NOT_MINED
  else printf 'DENIED %s' "$(printf '%s' "${out}" | tr '\n' ' ')"; fi
}

# perm_all <add|remove> — toggle the operational account on every validator
perm_all() {
  local m v; [[ "$1" == add ]] && m=perm_addAccountsToAllowlist || m=perm_removeAccountsFromAllowlist
  for v in 1 2 3 4; do rpc "${m}" "[[\"${OP_ADDR}\"]]" "$(validator_svc "${v}")" >/dev/null; done
}
allowlist() { rpc perm_getAccountsAllowlist '[]' "$(validator_svc 1)"; }

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT

log "=== install permissioned network: ${RELEASE} (chart ${CHART_VERSION}) in ns ${NAMESPACE} ==="
ensure_namespace_ready
helm upgrade --install "${RELEASE}" "${CHART}" --version "${CHART_VERSION}" \
  -n "${NAMESPACE}" --create-namespace \
  --set permissioning.accounts.enabled=true \
  --set "permissioning.accounts.allowlist={${OP_ADDR}}" \
  --wait --timeout 600s >/dev/null
ensure_probe
log "waiting for the fresh network to produce its first block…"
wait_for_height_above 0 180 >/dev/null
assert_chain_advancing 20
ensure_caster

log "=== baseline: operational account (allowlisted + funded) can transact ==="
r="$(submit_op)"
[[ "${r}" == MINED ]] || fail "baseline: operational account should transact, got '${r}'"
pass "baseline: operational account's tx MINED; allowlist=$(allowlist)"

log "=== INJECT: remove the operational account from the allowlist on ALL validators ==="
perm_all remove
log "allowlist now: $(allowlist)"

log "=== observe outage: every sender locked out, yet consensus keeps running ==="
r="$(submit_op)"
case "${r}" in
  DENIED*) pass "outage: the previously-working account is now DENIED — ${r#DENIED }" ;;
  *)       fail "expected lockout, got '${r}'" ;;
esac
# The decisive point: the transaction layer is frozen, but QBFT still produces
# (empty) blocks — pods Ready, height climbing — the false-comfort of a
# permissioning outage.
assert_chain_advancing 20
pass "outage: transaction layer FROZEN (all senders -32007) while QBFT keeps producing blocks — pods Ready + height climbing = false comfort"

log "=== recover: restore the allowlist via perm_addAccountsToAllowlist (RPC escape hatch) ==="
perm_all add
log "allowlist now: $(allowlist)"
r="$(submit_op)"
[[ "${r}" == MINED ]] || fail "recovery: operational account still denied after re-add — '${r}'"
pass "recover: operational account transacts again — outage cleared, no restart"

log "NOTE: file-based permissioning has an RPC escape hatch — perm_* recovers even"
log "      from a total lockout. Besu's onchain permissioning (which had no such"
log "      escape hatch) was removed in 25.6.0 (besu PR #8597), so file-based is"
log "      the only built-in account permissioning on current Besu."

log "=== scenario 08 complete (network torn down on exit; KEEP_NETWORK=1 to inspect) ==="
