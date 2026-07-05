# shellcheck shell=bash
# Shared helpers for chaos scenarios. Source from run.sh; requires bash.

NAMESPACE="${NAMESPACE:-besu}"
RELEASE="${RELEASE:-sbx}"
PROBE_POD="${PROBE_POD:-chaos-probe}"
RPC_PORT="${RPC_PORT:-8545}"
UNIFIED_SVC="${UNIFIED_SVC:-${RELEASE}-rpc-unified}"
# Active consensus engine. Must match the chart's `consensus` value for the
# deployed release (besu-sandbox: qbft | ibft2). Drives the validator-set RPC
# namespace below — the fault model is identical, only the namespace differs.
CONSENSUS="${CONSENSUS:-qbft}"

# validator_svc <n> — per-validator Service name (chart names are release-prefixed)
validator_svc() { printf '%s-validator%s\n' "${RELEASE}" "$1"; }

# consensus_rpc_ns — Besu RPC namespace for the active consensus engine
# (qbft_* for QBFT, ibft_* for IBFT 2.0).
consensus_rpc_ns() {
  case "${CONSENSUS}" in
    qbft)  echo "qbft" ;;
    ibft2) echo "ibft" ;;
    *) fail "unknown CONSENSUS='${CONSENSUS}' (use qbft or ibft2)" ;;
  esac
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }

# Chaos scripts inject real failures — refuse anything that isn't a local,
# disposable cluster. Recognized local contexts: kind, minikube, k3d, k3s,
# docker-desktop. Anything else (incl. managed clusters) needs ALLOW_ANY_CONTEXT=1.
guard_local_context() {
  local ctx
  ctx="$(kubectl config current-context)"
  case "${ctx}" in
    kind-*|k3d-*|minikube|k3s|docker-desktop) return 0 ;;
  esac
  [[ -n "${ALLOW_ANY_CONTEXT:-}" ]] && return 0
  fail "current context '${ctx}' is not a recognized local cluster (set ALLOW_ANY_CONTEXT=1 to override)"
}

# Long-lived curl pod so each RPC call is an exec, not a pod cold-start.
# A leftover probe that is terminating or not Running would die mid-scenario
# and masquerade as an RPC outage — replace it instead of reusing it.
ensure_probe() {
  local phase deleting
  if kubectl -n "${NAMESPACE}" get pod "${PROBE_POD}" >/dev/null 2>&1; then
    # The pod may vanish between these checks (e.g. a previous run's cleanup
    # finishing) — treat any failed query as "not Running" and fall through.
    phase="$(kubectl -n "${NAMESPACE}" get pod "${PROBE_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    deleting="$(kubectl -n "${NAMESPACE}" get pod "${PROBE_POD}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"
    if [[ -n "${deleting}" || "${phase}" != "Running" ]]; then
      log "replacing stale probe pod (phase=${phase:-gone}, terminating=${deleting:+yes})"
      kubectl -n "${NAMESPACE}" delete pod "${PROBE_POD}" --ignore-not-found --wait=true --grace-period=1 >/dev/null 2>&1 || true
    fi
  fi
  if ! kubectl -n "${NAMESPACE}" get pod "${PROBE_POD}" >/dev/null 2>&1; then
    log "starting probe pod ${PROBE_POD}"
    kubectl -n "${NAMESPACE}" run "${PROBE_POD}" --image=curlimages/curl:latest \
      --restart=Never --command -- sleep 7200 >/dev/null
  fi
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${PROBE_POD}" --timeout=120s >/dev/null
}

cleanup_probe() {
  # Short grace period: the probe runs `sleep`, which never handles SIGTERM,
  # so a default 30s termination just leaves a stale pod for the next run.
  kubectl -n "${NAMESPACE}" delete pod "${PROBE_POD}" --ignore-not-found --wait=false --grace-period=1 >/dev/null 2>&1 || true
}

# --- transaction signing (scenarios 06 txpool, 07/08 permissioning) -----------
# A long-lived foundry pod so each `cast` call is an exec, not a pod cold-start —
# the tx-layer counterpart to the curl probe. Runs in ${NAMESPACE}, so a scenario
# that targets its own network just exports NAMESPACE before sourcing this lib.
CASTER_POD="${CASTER_POD:-chaos-caster}"
FOUNDRY_IMG="${FOUNDRY_IMG:-ghcr.io/foundry-rs/foundry:latest}"

ensure_caster() {
  if ! kubectl -n "${NAMESPACE}" get pod "${CASTER_POD}" >/dev/null 2>&1; then
    log "starting caster pod ${CASTER_POD} (${FOUNDRY_IMG})"
    kubectl -n "${NAMESPACE}" run "${CASTER_POD}" --image="${FOUNDRY_IMG}" \
      --restart=Never --command -- sleep 1800 >/dev/null
  fi
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${CASTER_POD}" --timeout=240s >/dev/null
}

cleanup_caster() {
  kubectl -n "${NAMESPACE}" delete pod "${CASTER_POD}" --ignore-not-found --wait=false --grace-period=1 >/dev/null 2>&1 || true
}

# cast_in <sh-command> — run a shell snippet (cast …) inside the caster pod
cast_in() { kubectl -n "${NAMESPACE}" exec "${CASTER_POD}" -- sh -c "$1"; }

# --- network-namespace injection (scenario 02 partition, 03 slow-peer) --------
# Besu containers ship without iptables/tc or NET_ADMIN, so traffic rules are
# added from a privileged ephemeral debug container that shares the target pod's
# netns (scenario 02 uses iptables, scenario 03 uses tc netem).
NETSHOOT_IMG="${NETSHOOT_IMG:-nicolaka/netshoot}"
# Per-run unique name: ephemeral containers can neither be removed nor
# restarted once terminated, so a leftover chaos-net from an earlier scenario
# run (its sleep expired) would silently block re-attaching under the same
# name. Old ones linger in the pod spec until the pod restarts — harmless.
NETNS_CTR="${NETNS_CTR:-chaos-net-$(date +%s)}"

# netns_container_running <pod> — prints the debug container's startedAt if up
netns_container_running() {
  kubectl -n "${NAMESPACE}" get pod "$1" \
    -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='${NETNS_CTR}')].state.running.startedAt}" 2>/dev/null
}

# ensure_netns_container <pod> — attach the netns container if absent, wait Ready
ensure_netns_container() {
  local pod="$1" i
  if [[ -z "$(netns_container_running "${pod}")" ]]; then
    kubectl -n "${NAMESPACE}" debug "pod/${pod}" --image="${NETSHOOT_IMG}" \
      --profile=sysadmin -c "${NETNS_CTR}" -q -- sleep 3600 >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 90); do
    [[ -n "$(netns_container_running "${pod}")" ]] && return 0
    sleep 2
  done
  fail "netns container ${NETNS_CTR} did not start in ${pod}"
}

# netns <pod> <sh-command> — run a command in the pod's netns (iptables, tc, …)
netns() {
  kubectl -n "${NAMESPACE}" exec "$1" -c "${NETNS_CTR}" -- sh -c "$2"
}

# ensure_namespace_ready [ns] — a namespace left Terminating by a previous
# run's teardown (scenarios 07/08 delete theirs with --wait=false) refuses new
# content, which breaks a back-to-back install. Wait out the deletion; leave a
# healthy existing namespace (e.g. KEEP_NETWORK=1) untouched.
ensure_namespace_ready() {
  local ns="${1:-${NAMESPACE}}" phase
  phase="$(kubectl get namespace "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Terminating" ]]; then
    log "namespace ${ns} is Terminating from a previous run — waiting for deletion to finish"
    kubectl wait --for=delete "namespace/${ns}" --timeout=180s >/dev/null \
      || fail "namespace ${ns} is stuck Terminating — inspect and delete it, then re-run"
  fi
}

# rpc <method> <params-json> [host]  — host defaults to the unified RPC service
rpc() {
  local method="$1" params="${2:-[]}" host="${3:-${UNIFIED_SVC}}"
  kubectl -n "${NAMESPACE}" exec "${PROBE_POD}" -- curl -s -m 5 -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" \
    "http://${host}:${RPC_PORT}" 2>/dev/null
}

# Extract "result" from a JSON-RPC response (string results only, no jq dependency)
rpc_result() {
  sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# rpc_hex_retry <method> <host> [attempts] — hex result with retries; a single
# failed call is usually a stale endpoint mid-churn, not an RPC outage.
rpc_hex_retry() {
  local method="$1" host="$2" attempts="${3:-3}" hex i
  for (( i = 1; i <= attempts; i++ )); do
    hex="$(rpc "${method}" '[]' "${host}" | rpc_result)"
    [[ -n "${hex}" ]] && { printf '%s\n' "${hex}"; return 0; }
    (( i < attempts )) && sleep 1
  done
  return 1
}

# block_height [host] — decimal block number, empty string on RPC failure
# shellcheck disable=SC2120 # scenario scripts pass a host; in-lib callers use the default (SC2120 fires on older shellcheck, e.g. CI's)
block_height() {
  local hex
  hex="$(rpc_hex_retry eth_blockNumber "${1:-${UNIFIED_SVC}}")" || return 0
  printf '%d\n' "${hex}" 2>/dev/null || true
}

# peer_count <host> — decimal peer count, empty string on RPC failure
peer_count() {
  local hex
  hex="$(rpc_hex_retry net_peerCount "$1")" || return 0
  printf '%d\n' "${hex}" 2>/dev/null || true
}

# assert_chain_advancing [seconds] — fail unless height increases within the window
assert_chain_advancing() {
  local window="${1:-20}" start now waited=0
  start="$(block_height)"
  [[ -n "${start}" ]] || fail "no RPC response while checking chain liveness"
  while (( waited < window )); do
    sleep 2; (( waited += 2 ))
    now="$(block_height)"
    if [[ -n "${now}" ]] && (( now > start )); then
      pass "chain advancing (${start} -> ${now} in ${waited}s)"
      return 0
    fi
  done
  fail "chain did not advance from block ${start} within ${window}s"
}

# assert_chain_halted [seconds] — fail if height increases anywhere in the window
assert_chain_halted() {
  local window="${1:-30}" start now waited=0
  start="$(block_height)"
  [[ -n "${start}" ]] || fail "no RPC response while checking for chain halt"
  while (( waited < window )); do
    sleep 2; (( waited += 2 ))
    now="$(block_height)"
    [[ -n "${now}" ]] || fail "RPC stopped responding during halt window"
    (( now == start )) || fail "chain advanced during expected halt (${start} -> ${now} after ${waited}s)"
  done
  pass "chain halted at block ${start} for ${window}s"
}

# wait_pod_ready <pod> [timeout]
wait_pod_ready() {
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/$1" --timeout="${2:-300s}" >/dev/null
}

# wait_for_height_above <height> [timeout] — echoes elapsed seconds until a new block
wait_for_height_above() {
  local target="$1" timeout="${2:-300}" now elapsed=0
  while (( elapsed < timeout )); do
    now="$(block_height)"
    if [[ -n "${now}" ]] && (( now > target )); then
      echo "${elapsed}"
      return 0
    fi
    sleep 2; (( elapsed += 2 ))
  done
  fail "no block above ${target} within ${timeout}s"
}
