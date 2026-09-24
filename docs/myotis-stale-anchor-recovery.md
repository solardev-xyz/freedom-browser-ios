# Myotis stale-anchor recovery (iOS)

Port of desktop freedom-browser PR #353 ("use v0.1.10 with verified
checkpoint recovery") to the iOS app. Same trust policy, same state
machine, same user-visible outcomes; the process-supervisor half of the
desktop design collapses because iOS is single-process.

## The problem

Myotis v0.1.8+ enforces a weak-subjectivity gate. When both the embedded
checkpoint and the saved snapshot are older than the bound, the engine
parks the chain in `beaconState:"STALE_ANCHOR"` and refuses to sync: a
forged continuation signed by since-exited committee members would
otherwise BLS-verify.

| Chain | Bound | Effect |
| --- | --- | --- |
| Ethereum | 13 sync-committee periods (~14.7 days) | fresh install stale ~2 weeks after a release |
| Gnosis | 3 periods (~34 h) | fresh install stale ~1.5 days after a release, or after ~1.5 days closed |

Every fresh Gnosis install is therefore stale within a day and a half of
each engine release. Recovery is mandatory, not optional.

## The engine API (introduced in v0.1.10, ABI 26; the app now pins v0.1.12, ABI 32)

* `myotis_create_with_checkpoint(network, data_dir, root, slot)` —
  bootstraps a fresh directory from a caller-supplied beacon block root
  and header slot. The engine does **not** authenticate the root; it
  verifies forward from it exactly like the embedded checkpoint (BLS on
  every update, snapshot probation, weak-subjectivity gate on the
  supplied slot's age).
* The first call on a directory records the anchor in
  `sync-anchor[-gnosis].json`. The same root+slot later resumes that
  generation; a different anchor, embedded-anchor state, an unreadable
  marker, or a plain `myotis_create` on a marked directory returns `-3`
  (`ANCHOR_MISMATCH`). Nothing is deleted or rewritten.
* `myotis_accept_stale_anchor` / `myotis_set_ws_bound_periods` exist.
  **Freedom never calls them in release builds.** There is no
  risk-accept bypass in the UI.

## Trust policy (both checks required)

1. **External checkpoint quorum** (`MyotisCheckpointQuorum`). Ethereum:
   2 of 3 seats from seven checkpointz hosts (Sigma Prime, EthStaker,
   ChainSafe, Attestant, beaconcha.in, PietjePuk, Stakely), filled in
   stable order, unavailable candidates replaced. Gnosis: both of
   `checkpoint.gnosischain.com` and `checkpoint-sync-gnosis.dappnode.net`.
   A vote is a block root **plus** a finality endorsement covering the
   slot; dissent and contradictory evidence keep their seat; the
   threshold never drops.
2. **Colibri corroboration** (`ColibriCheckpointCorroborator`). A
   disposable Colibri verifier (fresh in-memory storage) verifies a zk
   proof for the latest block from the network's Colibri prover. The
   verifier's own checkpointz request (`GET
   /eth/v1/beacon/blocks/{slot}/root`) is intercepted and answered with
   the quorum's root for that slot; nothing else may be fetched. A
   successful verification binds the proof's committee history to the
   quorum root. Checkpoints must be at most one hour old.

Myotis then verifies forward from the root. Colibri does not
independently establish canonical finality or remove the external
checkpoint trust assumption (see desktop
`docs/audits/myotis-colibri-corroboration-2026-09.md`).

### iOS binding caveat

Desktop additionally decodes the proof (`decode_proof`) and re-hashes
the committee checkpoint header to check it equals the quorum root at
the quorum slot. The Colibri Swift package (2.0.2) exposes no proof
decoder, so iOS relies on the verifier's own Merkle binding instead and
fails closed unless the verifier consulted exactly one `(slot, root)`.
After bootstrap the node additionally cross-checks the engine's verified
`finalizedSlot`/`finalizedRootHex` against the record
(`MyotisRecoveryPolicy.canFinish` / `isAnchorMismatch`), which is the
same post-hoc guard desktop runs. Follow-up: ask corpus-core to export a
proof decoder in the Swift package and add the header re-hash.

## Recovery sequence (`MyotisNode`)

1. Poll sees `STALE_ANCHOR` → `recovery[chain] = checking`, verified
   reads off (the chain-data ladder silently falls through to Colibri /
   RPC — never a user-facing error).
2. `MyotisCheckpointAcquirer.acquire` (90 s deadline, 20 s per request,
   64 KiB metadata / 4 MiB proof caps, ≤ 8 intercepted requests).
3. `restarting`: stop the parked engine (`myotis_stop` is synchronous —
   the iOS "verified exit"), mint a new verified generation
   (`MyotisGenerationStore.replace`), `myotis_create_with_checkpoint`,
   start.
4. `restarting` clears when the engine reports `SYNCED` past the anchor
   (or at the anchor slot with the anchored root). Readiness then also
   needs a state peer that can serve at the verified head
   (`snapServingPeers ≥ 1`, engine ABI 31+ — a pooled peer that still
   lags the head does not count), the EL reader up and no EL hunt.

Retry ladder: transient failures (`unavailable`, `quorum-unavailable`,
`race`, `stale`) retry after 15 s, then 60 s, then block. Terminal
failures (`mismatch`, `quorum-conflict`, `clock`, `storage`,
`storage-io`, `ownership`, `unsupported`, `installation`, `startup`,
`stalled`) block immediately. A recovery episode longer than 60 s shows
"taking longer than expected"; a chain not ready for 5 minutes with no
recovery in flight blocks as `stalled` ("Syncing slowly").

Blocked chains offer **Retry sync** (storage/startup/stall reasons
restart the same owned generation; the rest run a fresh checkpoint
recovery) or **Repair sync data** (fresh bundled generation, old data
preserved), plus a short help text for storage / ownership /
installation / unsupported.

iOS-specific: recovery runs only in the foreground. `pause()` cancels
in-flight acquisition (the engine park is released by pause anyway and
the 90 s deadline exceeds background time); the first poll after
`resume()` observes the park again and restarts. Suspended time does not
count toward the stall watchdog.

## Persistence (`MyotisGenerationStore`)

```
Documents/myotis/<network>/
  verified-sync.json                 pointer {schemaVersion:1, chainId, generation}
  verified-sync-backup-<uuid>.json   old pointer (repair only)
  verified-sync/<uuid>/anchor.json   {origin: bundled|verified, nativeCheckpointApi: 26, checkpoint?}
  verified-sync/<uuid>/…             engine files incl. sync-anchor[-gnosis].json
```

Generations are append-only and never edited, copied or deleted. The
host never writes the engine's marker; it only refuses a generation
whose existing marker disagrees with its record (`.storage` → Repair).
Legacy v0.1.7 engine files directly in `<network>/` stay in place as a
retired bundled generation.

## Testing

* Offline: `MyotisCheckpointTests` (record rules, votes, quorum
  replacement/conflict, acquisition binding, interception policy),
  `MyotisGenerationStoreTests`, `MyotisRecoveryTests`.
* Simulator smoke: a fresh Gnosis install is naturally stale ~34 h after
  each engine release. To force it on Ethereum while its anchor is still
  in bound, set `FREEDOM_MYOTIS_WS_BOUND_PERIODS=1` in the scheme
  environment (DEBUG builds only; lowers the bound on bundled generations
  so the engine parks; the verified generation uses the network default).
  Watch the light-client log: `STALE_ANCHOR — anchor period …` →
  `checkpoint verified · slot …` → `recovery complete`.
* Simulator smoke, cold peer pool: `FREEDOM_MYOTIS_BOOT_ENODES_MAINNET`
  (or `_GNOSIS`) = a JSON array of `enode://<128 hex>@ip:port` strings
  hands the engine host seed pins (`myotis_set_boot_enodes`, ABI 31+;
  DEBUG builds only). The engine applies or refuses the list as a whole
  and dials the pins first. With `FREEDOM_DEBUG_RESOLVE=<name>` on top
  this is the cold-start check: `snapServingPeers` (status, the readiness
  gate since ABI 31) should turn positive within seconds and the name
  resolve via Myotis. `MyotisNode.setBootEnodes(chainId:enodes:)` is the
  same surface for product code; the app ships bundled lists — see
  `docs/myotis-seed-pins.md`.
* Engine log volume: every line the engine buffers is forwarded to the
  unified log (`log show --predicate 'subsystem == "com.browser.Freedom"'
  --info --debug`); `RUST_LOG=info,myotis_net::el=debug` in the scheme
  environment raises the engine's own filter.

## Peer caches carry over between generations (2026-09-20)

A new generation directory used to start empty, so after every checkpoint recovery the engine relearned its peers from scratch; a cold pool is exactly what makes the first minutes after "ready" fail every read (myotis #465). `MyotisGenerationStore.create` now copies the engine's learned peer lists — `peers[-net].cache` (execution layer, with the served / failed verdicts that order the next start's dials) and `cl-peers[-net].cache` (beacon side) — from the generation the pointer names, or from the legacy chain directory, into the new one. Only addresses travel: `anchor.json`, `sync-state.snapshot` and the native marker stay per generation, so the checkpoint trust model is unchanged. Best-effort: a missing or unreadable source just means a cold pool, as before.
