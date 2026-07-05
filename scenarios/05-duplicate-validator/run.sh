#!/usr/bin/env bash
# Scenario 05 — duplicate validator key (HA failover gone wrong).
# A member accidentally runs a *second* node carrying the *same* validator key
# (a misconfigured active/active failover). Two nodes can now sign consensus messages
# for one validator address. Address-level quorum is unchanged ({v1,v2,v3,v4} is
# still four addresses); the question is whether the duplicate causes disruption
# — round-changes, equivocation, a stall — or is simply shut out.
#
# Two steps, both realistic accident conditions:
#   STEP=1  devp2p dedupe   — deploy the duplicate alongside the LIVE real node.
#                             devp2p identity dedupe (same node ID) keeps the copy
#                             from holding peer connections: 0 peers, block 0.
#   STEP=2  partition trap  — isolate the real node, THEN deploy the duplicate.
#                             Peers still dial the StatefulSet DNS -> real pod IP,
#                             so the copy still can't take the slot.
#   STEP=3  replica scale   — the literal "bump replicas" HA accident: scale the
#                             validator StatefulSet to 2 (opt-in). The replica still
#                             can't join consensus (same node ID, dedupe), but its
#                             readiness probe (/liveness = RPC-up, not synced) lets it
#                             into the client-facing RPC Service endpoints at block 0,
#                             polluting eth_* reads with stale/zero heights until sync.
# Both report "no incident": the duplicate never joins consensus. NOTE this is a
# DEPLOYMENT-level property (devp2p dedupe + StatefulSet DNS anchoring), NOT a
# QBFT/IBFT guarantee against equivocation — see the README caveat.
#
# The duplicate is a throwaway pod built from the chart's own key secret, genesis
# and config; it is removed on exit. STEP 2 reuses the same privileged ephemeral
# debug container as scenario 02 (ensure_netns_container / netns) to DROP traffic.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

# shellcheck disable=SC2206 # word-splitting is the interface: STEP is a space-separated list
STEPS=(${STEP:-1 2})                                  # which steps to run (default both)
TARGET="${TARGET:-2}"                                 # validator to duplicate
DUP_POD="${DUP_POD:-chaos-dup-validator${TARGET}}"
KEY_SECRET="${KEY_SECRET:-${RELEASE}-validator${TARGET}-key}"
OBSERVE="${OBSERVE:-60}"
SETTLE="${SETTLE:-12}"

TARGET_POD="${RELEASE}-validator${TARGET}-0"
# Match the network's Besu version exactly (read from the running target), so the
# duplicate never straddles a version boundary. Override with BESU_IMG.
BESU_IMG="${BESU_IMG:-$(kubectl -n "${NAMESPACE}" get pod "${TARGET_POD}" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)}"
BESU_IMG="${BESU_IMG:-hyperledger/besu:26.6.1}"
# The duplicated validator's on-chain address, derived from the shared node key
# (the key secret holds only `nodekey`, no address). Used to detect
# double-signing via getSignerMetrics: any block this address proposes while the
# real node is isolated (STEP 2) was proposed by the duplicate. Resolved lazily
# in STEP 2 (needs the foundry caster), cached here.
TARGET_ADDR=""

# resolve_target_addr — derive the target validator's address from its node key
# via `cast` (the QBFT/IBFT validator identity is the secp256k1 address of the
# node key). Sets TARGET_ADDR; needs the caster pod.
resolve_target_addr() {
  [[ -n "${TARGET_ADDR}" ]] && return 0
  local nodekey
  nodekey="$(kubectl -n "${NAMESPACE}" get secret "${KEY_SECRET}" -o jsonpath='{.data.nodekey}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [[ -n "${nodekey}" ]] || { log "could not read nodekey from ${KEY_SECRET}"; return 0; }
  ensure_caster
  TARGET_ADDR="$(cast_in "cast wallet address --private-key 0x${nodekey}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' || true)"
}

# Indexed arrays keyed by validator number (1..4) — macOS bash 3.2 has no
# associative arrays (declare -A); follow the scenario-02 pattern.
POD=() IP=()
for n in 1 2 3 4; do POD[$n]="${RELEASE}-validator${n}-0"; done

PARTITIONED=0
SCALED=0

# --- duplicate pod ------------------------------------------------------------
# Match the chart's invocation: the key + Xdns flags are passed as CLI args (not
# in config.toml); --Xdns-* is required to accept the DNS-based static-nodes. The
# same node ID as the real validator is exactly what we expect to limit peering —
# that isolation is the thing being measured.
bootnodes_arg() {
  kubectl -n "${NAMESPACE}" get pod "${TARGET_POD}" \
    -o jsonpath='{.spec.containers[0].args[0]}' 2>/dev/null \
    | grep -oE '\-\-bootnodes=[^ \\]+' | head -1 | cut -d= -f2- || true
}

deploy_duplicate() {
  local bootnodes; bootnodes="$(bootnodes_arg)"
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${DUP_POD}
  namespace: ${NAMESPACE}
  labels: { app: chaos-dup-validator }
spec:
  restartPolicy: Never
  containers:
  - name: besu
    image: ${BESU_IMG}
    command: ["besu"]
    args:
      - "--node-private-key-file=/secrets/nodekey"
      - "--config-file=/etc/besu/config.toml"
      - "--Xdns-enabled=true"
      - "--Xdns-update-enabled=true"
$( [[ -n "${bootnodes}" ]] && printf '      - "--bootnodes=%s"\n' "${bootnodes}" )
    volumeMounts:
    - { name: key, mountPath: /secrets, readOnly: true }
    - { name: genesis, mountPath: /etc/genesis, readOnly: true }
    - { name: config, mountPath: /etc/besu, readOnly: true }
    - { name: data, mountPath: /data }
  volumes:
  - name: key
    secret: { secretName: ${KEY_SECRET} }
  - name: genesis
    configMap: { name: ${RELEASE}-genesis }
  - name: config
    configMap: { name: ${RELEASE}-config-toml }
  - name: data
    emptyDir: {}
EOF
}

wait_duplicate_up() {
  local i phase
  for i in $(seq 1 60); do
    phase="$(kubectl -n "${NAMESPACE}" get pod "${DUP_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${phase}" == "Running" || "${phase}" == "Failed" || "${phase}" == "Succeeded" ]] && break
    sleep 2
  done
  log "duplicate pod phase=$(kubectl -n "${NAMESPACE}" get pod "${DUP_POD}" -o jsonpath='{.status.phase}' 2>/dev/null)"
  for i in $(seq 1 45); do
    kubectl -n "${NAMESPACE}" logs "${DUP_POD}" 2>/dev/null | grep -q 'Ethereum main loop is up' && return 0
    sleep 2
  done
  log "duplicate Besu startup (errors / last lines):"
  kubectl -n "${NAMESPACE}" logs "${DUP_POD}" --tail=20 2>/dev/null | grep -iE 'ERROR|Failed|Illegal|main loop is up' | tail -8 || true
  fail "duplicate pod did not start Besu (check configmap/secret names and --Xdns-* flags)"
}

# report_duplicate <step-label> — log the copy's peers/height (0/0 => shut out)
# and scan for any equivocation/round-change signal on the real validators.
report_duplicate() {
  local label="$1" dup_ip dup_peers dup_height
  dup_ip="$(kubectl -n "${NAMESPACE}" get pod "${DUP_POD}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  dup_peers="$(peer_count "${dup_ip}" 2>/dev/null)"; dup_peers="${dup_peers:-?}"
  dup_height="$(rpc_hex_retry eth_blockNumber "${dup_ip}" 2 2>/dev/null || true)"
  dup_height="$(printf '%d' "${dup_height:-0x0}" 2>/dev/null || echo '?')"
  log "duplicate node: peers=${dup_peers} height=${dup_height} (0 peers / block 0 => shut out at the P2P layer)"
  log "duplicate peering/sync (last lines):"
  kubectl -n "${NAMESPACE}" logs "${DUP_POD}" --tail=40 2>/dev/null \
    | grep -iE 'peer|Connected|sync|duplicate|equivocat|disconnect|bootnode|main loop|Moved to round' | tail -8 || true
  log "real validators — any duplicate/equivocation/round-change signal during the window:"
  for n in 1 2 3 4; do
    [[ "${n}" -eq "${TARGET}" && "${PARTITIONED}" -eq 1 ]] && continue
    kubectl -n "${NAMESPACE}" logs "${POD[$n]}" --since="${OBSERVE}s" 2>/dev/null \
      | grep -iE 'duplicate|equivocat|conflict|Moved to round|gossip' | sed "s/^/  v${n}: /" | tail -3 || true
  done
  # round-changed blocks during the window = consensus disruption indicator (Round>0).
  local rc
  rc="$(kubectl -n "${NAMESPACE}" logs "${RELEASE}-validator1-0" --since="$(( OBSERVE + 35 ))s" 2>/dev/null \
    | grep 'Importing proposed block' | grep -cvE 'Round=0' || true)"
  log "${label}: blocks committed at Round>0 during/after injection: ${rc}"
  DUP_PEERS="${dup_peers}" DUP_HEIGHT="${dup_height}" ROUND_GT0="${rc}"
}

# proposed_by_target_since <from-block-decimal> <query-svc> — how many blocks the
# TARGET address proposed from <from-block> to head, per a healthy validator's
# getSignerMetrics. This is the authoritative double-sign signal in STEP 2: with
# the real node isolated, any block proposed by its address came from the
# duplicate. (A log grep is unreliable — Besu has no single "produced" line.)
proposed_by_target_since() {
  local svc="$2" from_hex hex
  [[ -n "${TARGET_ADDR}" ]] || { echo '?'; return 0; }
  from_hex="$(printf '0x%x' "$1")"
  hex="$(rpc "$(consensus_rpc_ns)_getSignerMetrics" "[\"${from_hex}\", \"latest\"]" "${svc}" \
    | tr '}' '\n' | grep -i "${TARGET_ADDR#0x}" | grep -o 'proposedBlockCount":"0x[0-9a-fA-F]*"' \
    | grep -o '0x[0-9a-fA-F]*' | head -1)"
  [[ -n "${hex}" ]] && printf '%d\n' "${hex}" || echo 0
}

remove_duplicate() {
  kubectl -n "${NAMESPACE}" delete pod "${DUP_POD}" --ignore-not-found --wait=true --grace-period=1 >/dev/null 2>&1 || true
}

# --- STEP 2 partition: isolate the real TARGET from the other validators -------
# DROP both directions on the target pod AND on each peer (so neither side keeps
# the connection), mirroring scenario 02's bidirectional rules.
isolate_target() {                 # $1 = add|del
  local op="$1" flag self_rules="" n
  [[ "${op}" == add ]] && flag="-I" || flag="-D"
  for n in 1 2 3 4; do
    [[ "${n}" -eq "${TARGET}" ]] && continue
    self_rules+="iptables ${flag} INPUT -s ${IP[$n]} -j DROP; iptables ${flag} OUTPUT -d ${IP[$n]} -j DROP; "
  done
  ensure_netns_container "${TARGET_POD}"
  netns "${TARGET_POD}" "${self_rules} true" >/dev/null
  for n in 1 2 3 4; do
    [[ "${n}" -eq "${TARGET}" ]] && continue
    ensure_netns_container "${POD[$n]}"
    netns "${POD[$n]}" "iptables ${flag} INPUT -s ${IP[$TARGET]} -j DROP; iptables ${flag} OUTPUT -d ${IP[$TARGET]} -j DROP; true" >/dev/null
  done
}

cleanup() {
  remove_duplicate
  cleanup_probe
  cleanup_caster
  # Safety net: if we exited while the target is partitioned, recreating the
  # affected pods gives them a fresh netns with no DROP rules — guarantees the
  # network is never left partitioned by a failed run.
  if (( PARTITIONED )); then
    kubectl -n "${NAMESPACE}" delete pod "${TARGET_POD}" --grace-period=0 --force >/dev/null 2>&1 || true
    for n in 1 2 3 4; do
      [[ "${n}" -eq "${TARGET}" ]] && continue
      kubectl -n "${NAMESPACE}" delete pod "${POD[$n]}" --grace-period=0 --force >/dev/null 2>&1 || true
    done
    PARTITIONED=0
  fi
  # Safety net: if we exited while scaled up, return the StatefulSet to one replica
  # and drop the orphaned replica PVC the volumeClaimTemplate leaves behind.
  if (( SCALED )); then
    kubectl -n "${NAMESPACE}" scale statefulset "${RELEASE}-validator${TARGET}" --replicas=1 >/dev/null 2>&1 || true
    kubectl -n "${NAMESPACE}" delete pvc "data-${RELEASE}-validator${TARGET}-1" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    SCALED=0
  fi
}

step_dedupe() {        # STEP 1: devp2p dedupe
  log "=== STEP 1: devp2p dedupe — duplicate validator${TARGET} alongside the LIVE node ==="
  local addr; addr="$(kubectl -n "${NAMESPACE}" get secret "${KEY_SECRET}" -o jsonpath='{.data.address}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  log "duplicating validator${TARGET} (key secret ${KEY_SECRET}, address ${addr:-unknown})"
  deploy_duplicate
  wait_duplicate_up
  log "observing ${OBSERVE}s with two validator${TARGET}s on the network…"
  sleep "${OBSERVE}"
  report_duplicate "STEP 1"
  assert_chain_advancing 30
  [[ "${DUP_PEERS}" == "0" && "${DUP_HEIGHT}" == "0" ]] \
    && pass "05/1: duplicate shut out by devp2p dedupe — peers=0 height=0 while the real node holds the slot; chain unaffected (round>0=${ROUND_GT0})" \
    || log "05/1: duplicate not fully isolated (peers=${DUP_PEERS} height=${DUP_HEIGHT}); inspect logs above"
  remove_duplicate
}

step_partition_trap() {   # STEP 2: partition trap
  log "=== STEP 2: partition trap — isolate the real node, then deploy the duplicate ==="
  for n in 1 2 3 4; do
    IP[$n]="$(kubectl -n "${NAMESPACE}" get pod "${POD[$n]}" -o jsonpath='{.status.podIP}')"
  done
  log "isolating real ${TARGET_POD} (ip=${IP[$TARGET]}) from validators $(for n in 1 2 3 4; do [[ $n -ne $TARGET ]] && printf '%s ' "$n"; done)"
  PARTITIONED=1
  isolate_target add
  log "partition active; waiting ${SETTLE}s for RLPx connections to drop"
  sleep "${SETTLE}"
  log "real validator${TARGET} peers=$(peer_count "$(validator_svc "${TARGET}")") (expect drop toward 0)"

  # Baseline for the double-sign check: the head as a HEALTHY validator sees it,
  # captured before the duplicate can propose anything. Any block validator${TARGET}'s
  # ADDRESS proposes from here on (while the real node is isolated) is the duplicate.
  resolve_target_addr
  local base_h; base_h="$(block_height "$(validator_svc 1)")"

  # CONTROL (SKIP_DUP=1): isolate the real node but deploy NO duplicate, and
  # confirm the target address proposes 0 blocks — i.e. the iptables isolation
  # genuinely cuts the real node out (its slots round-change). This is the
  # disambiguation for the finding below: with the control at 0 and the
  # duplicate run > 0, the extra blocks can only be the duplicate.
  if [[ -n "${SKIP_DUP:-}" ]]; then
    log "CONTROL: no duplicate deployed; observing ${OBSERVE}s whether the ISOLATED real node still proposes"
    sleep "${OBSERVE}"
    local ctl_proposed rc_ctl
    ctl_proposed="$(proposed_by_target_since "${base_h:-0}" "$(validator_svc 1)")"
    rc_ctl="$(kubectl -n "${NAMESPACE}" logs "${RELEASE}-validator1-0" --since="$(( OBSERVE + 35 ))s" 2>/dev/null | grep 'Importing proposed block' | grep -cvE 'Round=0' || true)"
    log "CONTROL: validator${TARGET}'s address proposed ${ctl_proposed} block(s) while isolated with NO duplicate (round>0=${rc_ctl})"
    [[ "${ctl_proposed}" == "0" ]] \
      && pass "05/2 CONTROL: isolation is effective — the real node proposed 0 blocks while cut off (its slots round-changed); any blocks in the duplicate run are the copy's" \
      || fail "05/2 CONTROL: isolated real node still proposed ${ctl_proposed} block(s) — isolation leaked, the partition-trap finding would be unsound"
    log "=== heal: flush DROP rules, restore validator${TARGET} ==="
    isolate_target del
    PARTITIONED=0
    sleep "${SETTLE}"
    assert_chain_advancing 60
    return 0
  fi
  log "double-sign baseline: head=${base_h:-?} at validator1; target address=${TARGET_ADDR:-unknown}"

  log "deploying duplicate validator${TARGET} (same key) while the real node is isolated…"
  deploy_duplicate
  wait_duplicate_up
  log "observing ${OBSERVE}s: can the duplicate take the isolated node's slot?"
  sleep "${OBSERVE}"
  report_duplicate "STEP 2"
  # Authoritative double-sign check: over the isolation window, how many blocks
  # did the target ADDRESS propose (per a healthy validator's getSignerMetrics)?
  # Real node is isolated, so any such block was proposed by the DUPLICATE.
  local tgt_proposed; tgt_proposed="$(proposed_by_target_since "${base_h:-0}" "$(validator_svc 1)")"
  log "STEP 2: blocks proposed by validator${TARGET}'s address since baseline (=duplicate, real node isolated): ${tgt_proposed}"
  # Three outcomes:
  #  - shut out at P2P (peers 0 / block 0): copy never reached the mesh (old-chart result);
  #  - joined the mesh as a FOLLOWER (peers>0) but proposed 0 blocks: syncs, never signs;
  #  - proposed >0 blocks under the shared key while peered: genuine DOUBLE-SIGNING.
  if [[ "${DUP_PEERS}" == "0" && "${DUP_HEIGHT}" == "0" ]]; then
    pass "05/2: partition trap — duplicate shut out at P2P (peers=0 height=0); round>0=${ROUND_GT0} is the missing validator, not double-signing"
  elif [[ "${tgt_proposed}" == "0" ]]; then
    pass "05/2: partition trap — duplicate PEERED and synced as a FOLLOWER (peers=${DUP_PEERS} height=${DUP_HEIGHT}) but proposed 0 blocks under validator${TARGET}'s key — it never signs as the validator; round>0=${ROUND_GT0} is the isolated real node's slots round-changing"
  else
    log "05/2: FINDING — duplicate PROPOSED ${tgt_proposed} block(s) under validator${TARGET}'s key while the real node was isolated (peers=${DUP_PEERS} height=${DUP_HEIGHT}): the copy took over the isolated validator's slot — active participation under one key, not merely a follower. Consensus did not halt or fork, but this is the boundary the caveat describes, now reached WITHOUT the manual DNAT the old chart needed."
    pass "05/2: partition trap characterized — duplicate proposed ${tgt_proposed} block(s) (took the isolated slot); network recovered on heal below"
  fi

  log "=== heal: remove duplicate, flush DROP rules, restore validator${TARGET} ==="
  remove_duplicate
  isolate_target del
  PARTITIONED=0
  sleep "${SETTLE}"
  assert_chain_advancing 60
  pass "05/2: network recovered after heal (no restart, no fork)"
}

step_scale_replica() {    # the literal "bump replicas" HA accident (opt-in)
  local sts="${RELEASE}-validator${TARGET}" rep_pod="${RELEASE}-validator${TARGET}-1"
  local read_svc; read_svc="$(validator_svc 1)"   # validator1 svc selects only v1 — a clean read host, never polluted
  log "=== STEP 3: replica scale — scale StatefulSet ${sts} to 2 (same key, StatefulSet-managed) ==="
  local base; base="$(block_height "${read_svc}")"
  log "scaling ${sts} --replicas=2 (creates ${rep_pod}, same nodekey secret + its own PVC)"
  SCALED=1
  kubectl -n "${NAMESPACE}" scale statefulset "${sts}" --replicas=2 >/dev/null
  local i
  for i in $(seq 1 90); do
    kubectl -n "${NAMESPACE}" get pod "${rep_pod}" >/dev/null 2>&1 \
      && kubectl -n "${NAMESPACE}" logs "${rep_pod}" 2>/dev/null | grep -q 'Ethereum main loop is up' && break
    sleep 2
  done
  log "replica ${rep_pod}: phase=$(kubectl -n "${NAMESPACE}" get pod "${rep_pod}" -o jsonpath='{.status.phase}' 2>/dev/null) ready=$(kubectl -n "${NAMESPACE}" get pod "${rep_pod}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  log "observing ${OBSERVE}s with a StatefulSet-managed duplicate (subject to the validator Services)…"
  sleep "${OBSERVE}"

  # The replica's own peers/height (read by pod IP — bypasses the Services).
  local rep_ip rep_peers rep_height
  rep_ip="$(kubectl -n "${NAMESPACE}" get pod "${rep_pod}" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  rep_peers="$(peer_count "${rep_ip}" 2>/dev/null)"; rep_peers="${rep_peers:-?}"
  rep_height="$(rpc_hex_retry eth_blockNumber "${rep_ip}" 2 2>/dev/null || true)"
  rep_height="$(printf '%d' "${rep_height:-0x0}" 2>/dev/null || echo '?')"
  log "replica node: peers=${rep_peers} height=${rep_height} (consensus: same node ID -> deduped, never proposes)"

  # Did the readiness probe (/liveness = RPC-up only) admit it to the RPC endpoints?
  local in_ep
  in_ep="$(kubectl -n "${NAMESPACE}" get endpoints "${UNIFIED_SVC}" -o jsonpath='{range .subsets[*].addresses[*]}{.targetRef.name}{"\n"}{end}' 2>/dev/null | grep -c "${rep_pod}" || true)"
  (( in_ep > 0 )) \
    && log "${rep_pod} IS in ${UNIFIED_SVC} endpoints — client RPC now round-robins to an un-synced replica" \
    || log "${rep_pod} is NOT in ${UNIFIED_SVC} endpoints (readiness kept it out)"

  # Demonstrate the read-path pollution: sample the unified service and count stale/zero reads.
  local head samples=12 stale=0 hx h
  head="$(block_height "${read_svc}")"
  for _ in $(seq 1 "${samples}"); do
    hx="$(rpc eth_blockNumber '[]' "${UNIFIED_SVC}" | rpc_result)"
    [[ -n "${hx}" ]] || continue
    h="$(printf '%d' "${hx}" 2>/dev/null || echo 0)"
    (( h == 0 || h + 5 < head )) && (( stale++ )) || true
  done
  log "unified-service sampling: ${stale}/${samples} reads returned a stale/zero height (real head ~${head})"

  # Real network unaffected at the consensus layer — verified via validator1 (clean host).
  local now rc; now="$(block_height "${read_svc}")"
  (( now > base )) \
    && pass "05/3: chain advanced ${base} -> ${now} on the real set (read via validator1); the replica did not join consensus (peers=${rep_peers} height=${rep_height})" \
    || log "05/3: chain did not advance via validator1 (${base} -> ${now}); inspect"
  rc="$(kubectl -n "${NAMESPACE}" logs "${RELEASE}-validator1-0" --since="$(( OBSERVE + 20 ))s" 2>/dev/null | grep 'Importing proposed block' | grep -cvE 'Round=0' || true)"
  log "STEP 3: blocks committed at Round>0 during window: ${rc} (no equivocation from the replica)"
  (( in_ep > 0 && stale > 0 )) \
    && pass "05/3: replica polluted the RPC read path — ${stale}/${samples} unified-service reads were stale/zero while it sat un-synced in the endpoints (consensus untouched)" \
    || log "05/3: no RPC read pollution observed (in_endpoints=${in_ep}, stale=${stale}/${samples})"

  log "=== revert: scale ${sts} back to 1 and delete the orphan replica PVC ==="
  kubectl -n "${NAMESPACE}" scale statefulset "${sts}" --replicas=1 >/dev/null
  kubectl -n "${NAMESPACE}" wait --for=delete "pod/${rep_pod}" --timeout=120s >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete pvc "data-${rep_pod}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  SCALED=0
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT
ensure_probe

log "=== baseline (consensus=${CONSENSUS}) ==="
assert_chain_advancing 20
for n in 1 2 3 4; do
  log "validator${n}: pod=${POD[$n]} peers=$(peer_count "$(validator_svc "$n")") height=$(block_height "$(validator_svc "$n")")"
done

for s in "${STEPS[@]}"; do
  case "${s}" in
    1) step_dedupe ;;
    2) step_partition_trap ;;
    3) step_scale_replica ;;
    *) fail "unknown STEP='${s}' (use 1, 2, 3, or e.g. '1 2')" ;;
  esac
done

log "=== post-run: steady state ==="
for n in 1 2 3 4; do
  log "validator${n}: height=$(block_height "$(validator_svc "$n")") peers=$(peer_count "$(validator_svc "$n")")"
done

log "=== scenario 05 complete (duplicate removed on exit) ==="
