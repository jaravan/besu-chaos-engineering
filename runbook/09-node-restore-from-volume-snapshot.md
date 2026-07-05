# Restoring a node from a volume snapshot

> Backed by scenario: [`09-snapshot-restore`](../scenarios/09-snapshot-restore/).
> Verified on chart 0.3.3 (QBFT, Besu 26.6.1, Bonsai, kind): a cold snapshot
> reopened with 0 DB errors and caught up to gap 0 (`Ready` in 21s); hot
> snapshots — idle and under sustained write load — reopened cleanly with 0
> restarts (`Ready` in 21–22s). The mid-write smear failure has not been
> reproduced on a small database (the copy completes between RocksDB flushes);
> treat hot file copies as best-effort regardless.

## Symptom

You need to rebuild or roll back a validator/RPC node from a volume backup and
are unsure whether the backup is safe to restore. After a restore, one of:

- Besu crash-loops on startup with a RocksDB error (`Corruption: …`, bad
  `MANIFEST`/`CURRENT`, missing SST) — the pod never reaches `Ready`.
- The node starts but logs WAL recovery / replay lines on open.
- The node starts cleanly and catches up — the case you want.

**Know which backup class you are holding** — "snapshot" hides three different
consistency guarantees, and the recovery odds differ per class:

1. **Cold copy** (node was stopped): quiesced, crash-consistent by
   construction — always reopens.
2. **Block-level point-in-time snapshot** (cloud volume snapshot, CSI
   `VolumeSnapshot`): crash-consistent — the power-failure image RocksDB's
   write-ahead log is designed to recover.
3. **File-walk copy of a live directory** (`tar`, `rsync`, restic-style
   file backup taken while Besu ran): _smeared_ — files captured at different
   instants, possibly an SST/MANIFEST set that never coexisted. Worse than a
   crash; the class most likely to produce the crash-loop above.

**This is not a freezer problem.** GoQuorum/Geth split chain data between a
live DB and a separate append-only freezer (ancient store) that can
desynchronise in a hot backup. Besu's **Bonsai** format keeps blockchain and
world state in a single RocksDB (`DATABASE_METADATA.json` →
`"format":"BONSAI"`), so there is no two-store split — a backup captures one
database, restored atomically as one unit.

## Likely Causes

Ordered by frequency in practice:

1. **A file-walk copy captured RocksDB mid-write.** On a small or low-write
   database the copy completes between RocksDB flushes and reopens fine
   (verified idle **and** under 100+ tx/block load on a small DB), but the
   smear window grows with database size and compaction frequency — and a
   smeared capture may be unopenable.
2. **The backup crossed a Besu/RocksDB storage-version boundary** — the
   snapshot was taken under a different Besu version than the one restoring
   it. Check `VERSION_METADATA.json` against the running image.
3. **Restored onto a node with a conflicting identity** — reusing one node's
   DB on another node without handling its node key / enode is an identity
   problem that presents as a restore failure.

## Diagnosis Steps

```sh
# Is the pod crash-looping, and on what?
kubectl -n besu get pod sbx-validator4-0                     # RESTARTS climbing?
kubectl -n besu logs sbx-validator4-0 --tail=80              # current attempt
kubectl -n besu logs sbx-validator4-0 --previous --tail=80   # last crash — the RocksDB error lands here

# What format/version was the backup taken at?
kubectl -n besu exec sbx-validator4-0 -- cat /data/DATABASE_METADATA.json
kubectl -n besu exec sbx-validator4-0 -- cat /data/VERSION_METADATA.json
```

A `Corruption` / `MANIFEST` / missing-SST error in `--previous` logs confirms
an inconsistent capture (class 3 above, or a partial restore). A clean start
with WAL-recovery lines means the image was crash-consistent and RocksDB
recovered it — nothing further to do.

## Recovery Procedure

1. **If the restored node starts (with or without WAL recovery): done.**
   Verify it rejoins and catches up — `net_peerCount` ≥ 3 and height within a
   few blocks of head. In the verified runs the node was `Ready` 21–31s after
   scale-up and at gap 0 within another 10s.
2. **If RocksDB won't open, stop restarting the same corrupt volume.** In
   order of preference:
   - **Wipe and resync.** Clear the data volume and let the node rebuild from
     peers. Keys and config are mounted from Secrets/ConfigMaps, not the PVC,
     so wiping the DB loses nothing but sync time — and a validator beyond
     quorum can be wiped with no impact on chain liveness.
     ```sh
     kubectl -n besu scale statefulset/sbx-validator4 --replicas=0
     kubectl -n besu wait --for=delete pod/sbx-validator4-0 --timeout=120s
     # mount data-sbx-validator4-0 in a throwaway pod and:
     #   rm -rf /data/database /data/DATABASE_METADATA.json /data/VERSION_METADATA.json
     kubectl -n besu scale statefulset/sbx-validator4 --replicas=1
     ```
     (Scenario 09's hot arms — STEPs 2 and 3 — execute exactly this path
     automatically when a hot restore fails to open.)
   - **Restore from a cold snapshot** if you have one (see Prevention) —
     deterministic, no WAL recovery, no risk.
3. **Restore the data directory as one atomic unit** — one tarball, one volume
   image. Never assemble it from per-file copies taken at different times;
   that recreates the smear you are recovering from.

## Prevention

- **Make anything you'll rely on as a restore source a cold snapshot.** Scale
  the node to 0 (or stop Besu) before snapshotting. The cost is brief downtime
  for one node — harmless at N-1 on a quorum network; a rolling backup
  schedule (one validator at a time) keeps it invisible.
- **Prefer block-level volume snapshots over file-walk copies** when hot
  backups are unavoidable (e.g. a cluster-wide Velero schedule): CSI/cloud
  volume snapshots are crash-consistent, which RocksDB is designed to recover;
  `tar`/`rsync`/restic over a live data dir is not. If only file-based backup
  is available, treat it as best-effort.
- **Validate restores periodically** instead of assuming them — run the
  scenario (or its cold arm) as the drill. A backup that has never been
  restored is a hypothesis, not a backup.
- **Record the Besu version with the backup** (`VERSION_METADATA.json`) so a
  restore never silently crosses a storage-version boundary.

## Post-Incident

- If a hot backup failed to restore, preserve the `--previous` logs showing
  the RocksDB error — the evidence that the backup, not the node, was the
  problem, and the trigger to move that backup job to cold (or block-level)
  snapshots.
- Record which recovery path won (restore vs wipe-and-resync) and how long
  catch-up took — those numbers are the RTO inputs for the next capacity
  conversation.
