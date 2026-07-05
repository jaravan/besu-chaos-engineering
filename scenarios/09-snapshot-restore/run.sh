#!/usr/bin/env bash
# Scenario 09 — snapshot restore (storage layer): can a node be rebuilt from a
# data-volume backup, and does the answer depend on how the backup was taken?
#
#   STEP=1  cold restore    — stop the node, snapshot the quiesced RocksDB,
#                             restore, restart. Crash-consistent by construction;
#                             must reopen with zero DB errors. The procedure to
#                             rely on — and a rehearsed restore drill with RTO.
#   STEP=2  hot restore     — snapshot while Besu is running and writing (the
#                             tar/rsync-style backup), restore, restart. Usually
#                             reopens via RocksDB WAL recovery; not guaranteed.
#   STEP=3  hot under load  — same, but under sustained tx write pressure, taking
#                             several copies and restoring the worst one (a copy
#                             tar flagged as changed-while-read if there is one).
#                             The arm that can genuinely fail; if the restored DB
#                             won't open, the runbook recovery (wipe + resync
#                             from peers) is EXECUTED, so the run ends with a
#                             healthy node either way and records which path won.
#
# The target validator (default 4) is beyond quorum, so the chain keeps
# producing at 3-of-4 through every stop/restore/restart cycle. Storage-layer
# and engine-independent: nothing here touches consensus.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh

# shellcheck disable=SC2206 # word-splitting is the interface: STEP is a space-separated list
STEPS=(${STEP:-1 2 3})                        # which steps to run (default all)
TARGET_VALIDATOR="${TARGET_VALIDATOR:-4}"     # must be beyond quorum (any one of 4)
TARGET_STS="${RELEASE}-validator${TARGET_VALIDATOR}"
TARGET_POD="${TARGET_STS}-0"
TARGET_SVC="$(validator_svc "${TARGET_VALIDATOR}")"
PVC="data-${TARGET_POD}"
HELPER_POD="${HELPER_POD:-chaos-snap-helper}"
DOWN_WINDOW="${DOWN_WINDOW:-20}"              # extra downtime so a catch-up gap builds
HOT_TARS="${HOT_TARS:-3}"                     # STEP 3: hot copies taken under load
READY_TIMEOUT="${READY_TIMEOUT:-180}"         # restored node must be Ready within this
RESYNC_TIMEOUT="${RESYNC_TIMEOUT:-300}"       # wipe+resync path: catch-up budget
CATCHUP_GAP="${CATCHUP_GAP:-10}"              # max blocks behind head after recovery
RPC_URL="http://${UNIFIED_SVC}:${RPC_PORT}"
# Genesis-funded dev account (same as scenario 06) drives STEP 3's write load.
FUNDED_PK="${FUNDED_PK:-0xfc96a9e5a0733664dd4f8c48f163e0f3c71805234bd97637a586ca0bcb0169f7}"
GAS_PRICE="${GAS_PRICE:-1000000000}"
DEAD="0x000000000000000000000000000000000000dEaD"

LOAD_PID=""
load_out=""

cleanup() {
  cleanup_probe
  [[ -n "${LOAD_PID}" ]] && kill "${LOAD_PID}" 2>/dev/null || true
  cleanup_caster            # deleting the caster also stops a still-running load loop
  kubectl -n "${NAMESPACE}" delete pod "${HELPER_POD}" \
    --ignore-not-found --wait=false --grace-period=1 >/dev/null 2>&1 || true
  # Safety net: never leave the target scaled down. If the run died mid-restore
  # the volume holds either the old DB, a restored copy, or a wiped directory —
  # Besu starts (or resyncs fresh) from any of those; a half-extracted copy is
  # the one case needing the runbook's wipe step by hand.
  kubectl -n "${NAMESPACE}" scale "statefulset/${TARGET_STS}" --replicas=1 >/dev/null 2>&1 || true
  [[ -n "${load_out}" ]] && rm -f "${load_out}" 2>/dev/null || true
}

# db_error_lines — DB-corruption signals in the target's current log
db_error_lines() {
  kubectl -n "${NAMESPACE}" logs "${TARGET_POD}" 2>/dev/null \
    | grep -ciE 'corrupt|RocksDBException|Unable to load|Failed to start' || true
}

stop_target() {
  kubectl -n "${NAMESPACE}" scale "statefulset/${TARGET_STS}" --replicas=0 >/dev/null
  kubectl -n "${NAMESPACE}" wait --for=delete "pod/${TARGET_POD}" --timeout=120s >/dev/null
  log "validator${TARGET_VALIDATOR} down; chain must keep advancing at 3-of-4"
  assert_chain_advancing 20
}

# helper_exec <sh-script> — run a shell snippet in a throwaway pod that mounts
# the target's PVC at /data (the node must be stopped; PVC access is exclusive).
helper_exec() {
  kubectl -n "${NAMESPACE}" delete pod "${HELPER_POD}" --ignore-not-found --grace-period=1 >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${HELPER_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: helper
    image: busybox:1.36
    command: ["sh", "-c", "sleep 600"]
    volumeMounts:
    - { name: data, mountPath: /data }
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${PVC}
EOF
  wait_pod_ready "${HELPER_POD}" 120s
  kubectl -n "${NAMESPACE}" exec "${HELPER_POD}" -- sh -c "$1"
  kubectl -n "${NAMESPACE}" delete pod "${HELPER_POD}" --wait=true --grace-period=1 >/dev/null
}

# restore_snapshot <tarball> — boot-from-backup: wipe the live DB on the PVC and
# extract the snapshot in its place (all chaos tarballs are removed afterwards).
restore_snapshot() {
  helper_exec '
    set -e
    cd /data
    rm -rf database DATABASE_METADATA.json VERSION_METADATA.json
    tar -xzf '"$1"' -C /data
    rm -f /data/chaos-snap*.tgz
    echo "restored contents:"; ls -la /data'
}

# hot_tar <tarball> — file-walk copy of the RocksDB from INSIDE the running
# node: the tar/rsync-style hot backup. GNU tar exits 1 ("file changed as we
# read it") if RocksDB wrote during the copy — that is the hazard under test,
# so the exit code is captured, not treated as a failure. Echoes the exit code.
hot_tar() {
  local rc out
  set +e
  # -c: without it kubectl prints "Defaulted container …" to stderr, which
  # would drown the one signal that matters here — tar's own warnings.
  out="$(kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -c "${TARGET_STS}" -- sh -c '
    cd /data
    FILES="DATABASE_METADATA.json database"
    [ -f VERSION_METADATA.json ] && FILES="$FILES VERSION_METADATA.json"
    tar -czf '"$1"' --warning=no-file-changed $FILES' 2>&1)"
  rc=$?
  set -e
  # Callers capture stdout (the exit code) — keep the log line on stderr.
  [[ -n "${out}" ]] && log "tar messages: ${out}" >&2
  echo "${rc}"
}

# restart_target — scale back to 1; returns non-zero if not Ready in time
restart_target() {
  kubectl -n "${NAMESPACE}" scale "statefulset/${TARGET_STS}" --replicas=1 >/dev/null
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${TARGET_POD}" --timeout="${READY_TIMEOUT}s" >/dev/null 2>&1
}

# assert_caught_up <label> [timeout] — poll until the target is within
# CATCHUP_GAP of head; logs the final gap/peers
assert_caught_up() {
  local label="$1" timeout="${2:-60}" waited=0 node_h head_h gap peers
  while :; do
    node_h="$(block_height "${TARGET_SVC}")"
    head_h="$(block_height)"
    if [[ -n "${node_h}" && -n "${head_h}" ]]; then
      gap=$(( head_h - node_h ))
      (( gap <= CATCHUP_GAP )) && break
    fi
    (( waited < timeout )) || fail "${label}: target still ${gap:-?} blocks behind head after ${timeout}s (${node_h:-?}/${head_h:-?})"
    sleep 5; (( waited += 5 ))
  done
  peers="$(peer_count "${TARGET_SVC}")"
  log "${label}: height=${node_h} head=${head_h} gap=${gap} peers=${peers} (caught up in ${waited}s)"
}

# recover_wipe_resync <label> — the runbook recovery for a restore that will not
# open: clear the volume, keep keys/config (they are mounted, not on the PVC),
# and let the node rebuild from peers. Safe at N-1 on a quorum network.
recover_wipe_resync() {
  local label="$1" t0 t1
  log "${label}: executing runbook recovery — wipe the volume, resync from peers"
  kubectl -n "${NAMESPACE}" scale "statefulset/${TARGET_STS}" --replicas=0 >/dev/null
  kubectl -n "${NAMESPACE}" wait --for=delete "pod/${TARGET_POD}" --timeout=120s >/dev/null 2>&1 || true
  helper_exec 'cd /data && rm -rf database DATABASE_METADATA.json VERSION_METADATA.json chaos-snap*.tgz && ls -la /data'
  t0=$(date +%s)
  kubectl -n "${NAMESPACE}" scale "statefulset/${TARGET_STS}" --replicas=1 >/dev/null
  wait_pod_ready "${TARGET_POD}" "${RESYNC_TIMEOUT}s"
  assert_caught_up "${label} (resync)" "${RESYNC_TIMEOUT}"
  t1=$(date +%s)
  log "${label}: wipe + resync recovered the node in $(( t1 - t0 ))s"
}

# observe_restart <label> <tar-note> — the shared tail of every arm: restart on
# the restored volume, then either report a clean open + catch-up, or (hot arms)
# record the failed open as the FINDING and run the wipe+resync recovery.
observe_restart() {
  local label="$1" tar_note="$2" t0 t1 restarts errs
  t0=$(date +%s)
  if restart_target; then
    t1=$(date +%s)
    restarts="$(kubectl -n "${NAMESPACE}" get pod "${TARGET_POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
    errs="$(db_error_lines)"
    log "${label}: Ready $(( t1 - t0 ))s after restart (startup restarts=${restarts}, DB-error lines=${errs})"
    sleep 10
    assert_caught_up "${label}"
    pass "${label}: restored volume reopened and caught up (restarts=${restarts}, db-errors=${errs}${tar_note})"
    return 0
  fi
  # The restored DB did not come up — for a hot copy this is the result the
  # scenario exists to catch, and the recovery is part of the loop.
  restarts="$(kubectl -n "${NAMESPACE}" get pod "${TARGET_POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo '?')"
  log "${label}: FINDING — restored volume did NOT reopen within ${READY_TIMEOUT}s (restarts=${restarts}${tar_note}); RocksDB error:"
  kubectl -n "${NAMESPACE}" logs "${TARGET_POD}" --tail=40 2>/dev/null | grep -iE 'corrupt|RocksDB|exception|error' | tail -8 || true
  kubectl -n "${NAMESPACE}" logs "${TARGET_POD}" --previous --tail=40 2>/dev/null | grep -iE 'corrupt|RocksDB|exception|error' | tail -8 || true
  recover_wipe_resync "${label}"
  pass "${label}: hot copy failed to reopen (the finding${tar_note}) — recovered via wipe + resync"
}

step_cold() {   # STEP 1: quiesce, snapshot, restore, restart — deterministic
  log "=== STEP 1: COLD restore — stop the node, snapshot the quiesced RocksDB ==="
  local snap_h
  snap_h="$(block_height "${TARGET_SVC}")"
  log "snapshot reference height: ${snap_h:-?}"
  stop_target
  helper_exec '
    set -e
    cd /data
    FILES="DATABASE_METADATA.json database"
    [ -f VERSION_METADATA.json ] && FILES="$FILES VERSION_METADATA.json"
    tar -czf /data/chaos-snap.tgz $FILES
    echo "cold snapshot: $(ls -la /data/chaos-snap.tgz)"'
  log "holding ${DOWN_WINDOW}s so the chain advances past the snapshot (catch-up gap)"
  sleep "${DOWN_WINDOW}"
  restore_snapshot /data/chaos-snap.tgz
  # Cold is held to a hard standard: crash-consistent by construction, so any
  # DB-error line or failed open is a scenario failure, not a finding.
  local t0 t1 errs
  t0=$(date +%s)
  restart_target || fail "STEP 1: cold-restored node not Ready in ${READY_TIMEOUT}s — a quiesced snapshot must reopen cleanly"
  t1=$(date +%s)
  errs="$(db_error_lines)"
  log "STEP 1: Ready $(( t1 - t0 ))s after restart (DB-error lines=${errs})"
  (( errs == 0 )) || fail "STEP 1: cold restore logged ${errs} DB-error line(s) (expected none for a quiesced snapshot)"
  sleep 10
  assert_caught_up "STEP 1"
  pass "STEP 1: cold snapshot reopened CLEANLY (0 DB errors) and caught up — the procedure to rely on"
}

step_hot_idle() {   # STEP 2: tar the RocksDB under the running node, restore it
  log "=== STEP 2: HOT restore, idle — snapshot while Besu is running and writing ==="
  local snap_h tar_rc
  snap_h="$(block_height "${TARGET_SVC}")"
  tar_rc="$(hot_tar /data/chaos-snap.tgz)"
  log "hot tar exit=${tar_rc} at height ${snap_h:-?} (1 = changed-while-read: a mid-write capture)"
  stop_target
  restore_snapshot /data/chaos-snap.tgz
  observe_restart "STEP 2" ", tar_exit=${tar_rc}"
}

step_hot_load() {   # STEP 3: hot copies under sustained write pressure
  log "=== STEP 3: HOT restore under LOAD — sustained tx writes during the copy ==="
  ensure_caster
  load_out="$(mktemp)"
  log "starting write load (sequential-nonce transfers from the dev account; every block mines txs)"
  cast_in '
    URL='"${RPC_URL}"'; PK='"${FUNDED_PK}"'; GP='"${GAS_PRICE}"'; DEAD='"${DEAD}"'
    ADDR=$(cast wallet address --private-key $PK)
    N=$(cast nonce $ADDR --rpc-url $URL)
    rm -f /tmp/chaos-load-stop
    i=0
    while [ ! -f /tmp/chaos-load-stop ] && [ $i -lt 2000 ]; do
      cast send --legacy --gas-price $GP --gas-limit 21000 --chain 1337 --async \
        --nonce $((N+i)) --private-key $PK --rpc-url $URL $DEAD --value 1 >/dev/null 2>&1 || true
      i=$((i+1))
    done
    echo "LOAD sent=$i"' > "${load_out}" 2>&1 &
  LOAD_PID=$!
  sleep 10   # let the load reach steady state before copying

  local i rc pick="" rc_list="" pick_rc=""
  for (( i = 1; i <= HOT_TARS; i++ )); do
    rc="$(hot_tar "/data/chaos-snap-${i}.tgz")"
    rc_list="${rc_list}${rc_list:+,}${rc}"
    # Prefer a copy tar caught mid-write (exit 1) — the genuinely smeared one.
    if [[ -z "${pick_rc}" || ( "${pick_rc}" != "1" && "${rc}" == "1" ) ]]; then
      pick="/data/chaos-snap-${i}.tgz"; pick_rc="${rc}"
    fi
  done
  log "hot tars under load: exits=[${rc_list}] — restoring ${pick} (exit ${pick_rc})"
  [[ "${rc_list}" == *1* ]] \
    || log "note: no copy was caught mid-write (all exits 0) — this run bounds the quiet case only"

  cast_in 'touch /tmp/chaos-load-stop' >/dev/null 2>&1 || true
  wait "${LOAD_PID}" 2>/dev/null || true
  LOAD_PID=""
  log "write load stopped ($(grep -o 'LOAD sent=[0-9]*' "${load_out}" || echo 'LOAD sent=?'))"

  stop_target
  restore_snapshot "${pick}"
  observe_restart "STEP 3" ", tar_exits=[${rc_list}], restored_exit=${pick_rc}"
}

guard_local_context        # refuse to run outside a local/disposable cluster
trap cleanup EXIT
ensure_probe

log "=== baseline ==="
assert_chain_advancing 20
kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -c "${TARGET_STS}" -- sh -c 'test -f /data/DATABASE_METADATA.json' \
  || fail "no /data/DATABASE_METADATA.json in ${TARGET_POD} — data layout differs from the chart this scenario was written for"
log "target validator${TARGET_VALIDATOR} DB: $(kubectl -n "${NAMESPACE}" exec "${TARGET_POD}" -c "${TARGET_STS}" -- cat /data/DATABASE_METADATA.json 2>/dev/null | tr -d ' \n' || echo '?')"

for s in "${STEPS[@]}"; do
  case "${s}" in
    1) step_cold ;;
    2) step_hot_idle ;;
    3) step_hot_load ;;
    *) fail "unknown STEP='${s}' (use 1, 2, 3, or e.g. '1 3')" ;;
  esac
done

log "=== post-run: steady state ==="
assert_chain_advancing 20
for n in 1 2 3 4; do
  log "validator${n}: height=$(block_height "$(validator_svc "${n}")") peers=$(peer_count "$(validator_svc "${n}")")"
done
log "=== scenario 09 complete ==="
