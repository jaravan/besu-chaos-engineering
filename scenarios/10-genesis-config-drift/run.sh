#!/usr/bin/env bash
# Scenario 10 — genesis / config drift (onboarding layer): the everyday "why
# won't the new member's node sync?" incident. In a consortium each member
# deploys their own node, so configuration drifts; a node booted from a genesis
# that doesn't match the network (chainId, fork block, extraData) is rejected at
# the eth-subprotocol handshake — peers see a different network — and sits at
# block 0 with no useful peers, while the running network is completely
# unaffected. The fix is config reconciliation on the joiner, not anything on
# the network.
#
#   STEP=1  control — a joiner with the CORRECT genesis peers and syncs to
#                     head. Proves the pod wiring (image, bootnodes, DNS
#                     enodes) works, so STEP 2's failure isolates the genesis
#                     as the only changed variable.
#   STEP=2  drift   — the same joiner booted from a drifted genesis (chainId
#                     changed) stays at block 0 with no sync progress and logs
#                     the handshake rejection; the main network never notices.
#
# Both joiners are plain member/RPC nodes (auto-generated key, not a
# validator); the image and bootnodes are read from the running network, so the
# joiner always matches the deployed Besu version and dials exactly what the
# network dials. Engine-independent: the gate is the devp2p/eth handshake, not
# consensus.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

# shellcheck disable=SC2206 # word-splitting is the interface: STEP is a space-separated list
STEPS=(${STEP:-1 2})                          # which steps to run (default both)
JOINER_POD="${JOINER_POD:-chaos-joiner}"
DRIFT_GENESIS_CM="${DRIFT_GENESIS_CM:-chaos-drift-genesis}"
DRIFT_CHAINID="${DRIFT_CHAINID:-1337001}"
CONTROL_TIMEOUT="${CONTROL_TIMEOUT:-180}"     # control joiner must reach head within this
DRIFT_SETTLE="${DRIFT_SETTLE:-75}"            # how long the drift joiner gets to (not) join
CATCHUP_GAP="${CATCHUP_GAP:-10}"              # control: max blocks behind head

genesis_tmp=""

cleanup() {
  cleanup_probe
  kubectl -n "${NAMESPACE}" delete pod "${JOINER_POD}" \
    --ignore-not-found --wait=false --grace-period=1 >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" delete configmap "${DRIFT_GENESIS_CM}" --ignore-not-found >/dev/null 2>&1 || true
  [[ -n "${genesis_tmp}" ]] && rm -f "${genesis_tmp}" "${genesis_tmp}.bak" 2>/dev/null || true
}

# launch_joiner <genesis-configmap> — standalone member node dialing the real
# network. Image and bootnodes come from the live validator1 pod so the joiner
# matches the network's Besu version and peer wiring exactly.
launch_joiner() {
  kubectl -n "${NAMESPACE}" delete pod "${JOINER_POD}" --ignore-not-found --wait=true --grace-period=1 >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${JOINER_POD}
  namespace: ${NAMESPACE}
  labels: { app: chaos-joiner }
spec:
  restartPolicy: Never
  containers:
  - name: besu
    image: ${BESU_IMG}
    command: ["besu"]
    args:
      - "--genesis-file=/etc/genesis/genesis.json"
      - "--data-path=/data"
      - "--p2p-enabled=true"
      - "--discovery-enabled=true"
      - "--bootnodes=${BOOTNODES}"
      - "--Xdns-enabled=true"
      - "--Xdns-update-enabled=true"
      - "--sync-min-peers=1"
      - "--rpc-http-enabled=true"
      - "--rpc-http-host=0.0.0.0"
      - "--rpc-http-port=${RPC_PORT}"
      - "--rpc-http-api=ETH,NET,WEB3"
      - "--host-allowlist=*"
      - "--min-gas-price=0"
    ports: [{ containerPort: ${RPC_PORT} }]
    volumeMounts:
    - { name: genesis, mountPath: /etc/genesis, readOnly: true }
    - { name: data, mountPath: /data }
  volumes:
  - name: genesis
    configMap: { name: $1 }
  - name: data
    emptyDir: {}
EOF
  wait_pod_ready "${JOINER_POD}" 300s
  JOINER_IP="$(kubectl -n "${NAMESPACE}" get pod "${JOINER_POD}" -o jsonpath='{.status.podIP}')"
  log "joiner up at ${JOINER_IP} (genesis from ConfigMap $1)"
}

# joiner_height — decimal height of the joiner, 0 if RPC not answering yet
joiner_height() {
  local hex
  hex="$(rpc_hex_retry eth_blockNumber "${JOINER_IP}" 2)" || { echo 0; return 0; }
  printf '%d\n' "${hex}" 2>/dev/null || echo 0
}

step_control() {   # STEP 1: correct genesis — the joiner must sync to head
  log "=== STEP 1: CONTROL — joiner with the network's real genesis must sync to head ==="
  launch_joiner "${RELEASE}-genesis"
  local waited=0 jh head_h gap
  while :; do
    jh="$(joiner_height)"
    head_h="$(block_height)"
    if [[ -n "${head_h}" ]] && (( jh > 0 )); then
      gap=$(( head_h - jh ))
      (( gap <= CATCHUP_GAP )) && break
    fi
    (( waited < CONTROL_TIMEOUT )) || fail "STEP 1: control joiner did not reach head in ${CONTROL_TIMEOUT}s (height=${jh}, head=${head_h:-?}) — fix the joiner wiring before reading anything into STEP 2"
    sleep 5; (( waited += 5 ))
  done
  log "STEP 1: joiner synced to ${jh} (head ${head_h}, gap ${gap}) in ${waited}s, peers=$(peer_count "${JOINER_IP}")"
  pass "STEP 1: control joiner peered and synced — the wiring works; the only variable STEP 2 changes is the genesis"
  kubectl -n "${NAMESPACE}" delete pod "${JOINER_POD}" --wait=true --grace-period=1 >/dev/null
}

step_drift() {   # STEP 2: drifted chainId — the joiner must NOT join
  log "=== STEP 2: DRIFT — same joiner, genesis chainId ${ORIG_CHAINID} -> ${DRIFT_CHAINID} ==="
  genesis_tmp="$(mktemp)"
  kubectl -n "${NAMESPACE}" get configmap "${RELEASE}-genesis" -o jsonpath='{.data.genesis\.json}' > "${genesis_tmp}"
  sed -i.bak "s/\"chainId\" *: *${ORIG_CHAINID}/\"chainId\": ${DRIFT_CHAINID}/" "${genesis_tmp}"
  grep -q "\"chainId\": ${DRIFT_CHAINID}" "${genesis_tmp}" || fail "could not drift chainId in the genesis copy"
  kubectl -n "${NAMESPACE}" delete configmap "${DRIFT_GENESIS_CM}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" create configmap "${DRIFT_GENESIS_CM}" --from-file=genesis.json="${genesis_tmp}" >/dev/null
  launch_joiner "${DRIFT_GENESIS_CM}"

  log "letting the drift joiner try to join for ${DRIFT_SETTLE}s"
  sleep "${DRIFT_SETTLE}"
  local jh peers head_h
  jh="$(joiner_height)"
  peers="$(peer_count "${JOINER_IP}")"
  head_h="$(block_height)"
  log "drift joiner: height=${jh} peers=${peers:-?} | main network head=${head_h}"
  log "drift joiner log — handshake-rejection signal:"
  kubectl -n "${NAMESPACE}" logs "${JOINER_POD}" 2>/dev/null \
    | grep -iE 'usefulness|different|network id|genesis|fork|disconnect' | tail -6 || true

  (( jh <= 1 )) || fail "STEP 2: drift joiner synced to height ${jh} — a genesis mismatch should have kept it at block 0"
  pass "STEP 2: drift joiner stuck at height ${jh} while the network advanced to ${head_h} — the mismatched genesis isolates it"

  log "=== main network unaffected by the mismatched joiner ==="
  assert_chain_advancing 20
  kubectl -n "${NAMESPACE}" delete pod "${JOINER_POD}" --wait=true --grace-period=1 >/dev/null
  kubectl -n "${NAMESPACE}" delete configmap "${DRIFT_GENESIS_CM}" --ignore-not-found >/dev/null 2>&1 || true
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT
ensure_probe

log "=== baseline ==="
assert_chain_advancing 20

# Everything the joiner needs is read from the running network, not assumed.
BESU_IMG="${BESU_IMG:-$(kubectl -n "${NAMESPACE}" get pod "${RELEASE}-validator1-0" -o jsonpath='{.spec.containers[0].image}')}"
BOOTNODES="${BOOTNODES:-$(kubectl -n "${NAMESPACE}" get pod "${RELEASE}-validator1-0" -o jsonpath='{.spec.containers[0].args[*]}' \
  | tr -s ' \n' '\n\n' | grep '^--bootnodes=' | head -1 | cut -d= -f2-)}"
[[ -n "${BESU_IMG}" && -n "${BOOTNODES}" ]] || fail "could not read image/bootnodes from ${RELEASE}-validator1-0"
ORIG_CHAINID="$(kubectl -n "${NAMESPACE}" get configmap "${RELEASE}-genesis" -o jsonpath='{.data.genesis\.json}' \
  | grep -oE '"chainId" *: *[0-9]+' | grep -oE '[0-9]+' | head -1)"
[[ -n "${ORIG_CHAINID}" ]] || fail "could not read chainId from ConfigMap ${RELEASE}-genesis"
log "joiner image=${BESU_IMG}, network chainId=${ORIG_CHAINID}, bootnodes=$(printf '%s' "${BOOTNODES}" | tr ',' '\n' | grep -c 'enode://' || true) entries"

JOINER_IP=""
for s in "${STEPS[@]}"; do
  case "${s}" in
    1) step_control ;;
    2) step_drift ;;
    *) fail "unknown STEP='${s}' (use 1, 2, or e.g. '1 2')" ;;
  esac
done

log "=== post-run: steady state ==="
assert_chain_advancing 20
log "=== scenario 10 complete (joiner removed on exit) ==="
