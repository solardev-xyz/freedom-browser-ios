# Ant chain transport through Freedom (iOS)

Port of desktop's `docs/ant-chain-bridge.md` / `ant-chain-bridge.js` (PR #419). Desktop runs `antd` as a process and hands it a loopback URL; iOS embeds `ant-ffi`, and ant v0.5.45 added a host callback for exactly that case (`ant_set_chain_transport`, ant #77). Freedom installs the callback, so the node's Gnosis reads and broadcasts go through the same chain-data router as the wallet (`docs/chain-data-router.md`) instead of the single pinned RPC in `BeeBootConfig`.

## Routing and authority

`AntChainBridge` (`Swarm/Node/AntChainBridge.swift`) receives a complete JSON-RPC request body from ant and returns a response body. Chain is fixed to Gnosis (100). The eight methods ant's chain module issues are allowed: the seven reads follow Gnosis's configured read policy (default Myotis → Colibri → RPC quorum → direct), `eth_sendRawTransaction` follows the broadcast policy and is accepted only for a transaction that is signed and carries chain id 100 (`SignedTransactionInspector`, legacy EIP-155 and typed 0x01–0x03). Anything else is answered with `-32601` / `-32600` / `-32602`.

Ant's reads are background work: `ChainDataRouter.Options.background` uses Myotis only when its single in-flight slot is idle and never queues for it, so the node's polling cannot push an interactive wallet or app read into queue-full fallback. Its log scans are routed differently (below).

## Log scans: the RPC quorum only, within each endpoint's range cap

Desktop freedom-browser #493 / #509, for #484. Ant finds its batches and chequebook by scanning the node wallet's xBZZ `Transfer(from)` logs and re-reads everything it finds with verified reads. A log it never receives is the one failure it cannot detect: a missing chequebook transfer would make it deploy a second chequebook. So `AntChainBridge.logScanOptions` sends `eth_getLogs` to the RPC quorum only (`Options.sources`), with a 30 s budget (`Options.quorumTimeout`); there is no direct fallback. Myotis serves no logs, and Colibri proves the logs it returns, not that none are missing.

Public Gnosis RPCs cap the span of one `eth_getLogs` differently (measured 2026-10-04: `rpc.gnosischain.com` serves the whole history, `gnosis-rpc.publicnode.com` 50,000 blocks, `gnosis.drpc.org` 10,000). `LogRangeMemory` learns each endpoint's cap from the number its refusal names (`AntLogScanErrors.rangeCap`; a range refusal without a number bounds the span asked), in memory, for 30 minutes. An endpoint that hung, refused the connection or throttled sits out for 30 s. A scan asks the first k endpoints whose cap covers its span; after a failed round, another quorum that can serve the same span is asked straight away.

When no quorum can serve the span, the wallet scan's shape (xBZZ, `topics` exactly `[Transfer, from]`, numeric ends) is checked against Blockscout (`BlockscoutTransferIndex`, `https://gnosisscan.io/api/v2`, redirects followed):

- Blockscout is used only while `/main-page/indexing-status` reports `finished_indexing_blocks: true`. During a back-fill its newest block is current, but old transfers can be missing.
- H = min(`toBlock`, Blockscout's newest block − 64).
- The first endpoint whose cap covers `[fromBlock, H]` is asked for that span, and Blockscout's `token-transfers?filter=from&token=xBZZ` list is read alongside it: at most 100 pages, 15 s per page, 60 s in total.
- Both sides must list the same transfers: block, transaction, log index, recipient and amount, with duplicates counted. Every RPC log must be an xBZZ `Transfer` from the wallet, and every Blockscout item a transfer from the wallet.
- The tail `(H, toBlock]` goes through the quorum.
- Ant gets the RPC's own log objects. The log line is `… blocks verified by <rpc host> + Blockscout (<n> logs, indexed to <H>)`.

If they disagree, or Blockscout is down, slow or switched off (Settings → Chains → Gnosis → Indexer), Ant gets `-32005 query exceeds max block range N` at once, without any endpoint being asked. N is the widest span a quorum can still verify, and Ant halves its window towards it. Only when no quorum can serve any span does Ant get an error it does not halve on. Blockscout sees the node wallet's address together with the device's IP.

`rpc.gnosis.gateway.fm` is not in the Gnosis seed. It is the same Tenderly account as `rpc.gnosischain.com`, so a quorum of the two would be one backend agreeing with itself.

Exhausted sources come back as a JSON-RPC error, never as a fabricated empty result and never as `-32000`: on the FFI transport that code means "coverage gap, replay against the pinned URL", which for a broadcast would be a second send. A genuine `-32000` from an endpoint (`nonce too low`, `already known`, …) is re-coded to `-32002` with its wording kept. Reverts keep code 3 and their `data`; insufficient funds is `-32003`; an uncertain Myotis broadcast is reported as such and never re-broadcast.

The callback returns `nil` (ant then uses the pinned URL) only when the body is not a string at all; every other failure is an authoritative error.

## Which error ant sees: one ranking rule

Ant's `scan_logs` halves its `eth_getLogs` window when the error text matches one of its broad needles (`range`, `limit`, `exceed`, `10000`, …) and aborts batch and chequebook recovery otherwise. `AntLogScanErrors` ranks every failed attempt (desktop's `rankLogScanError`), and the router's `ErrorKeeper` keeps the most useful one across tiers:

| Rank | Meaning | Effect |
| --- | --- | --- |
| request | a coded reply naming the query's size (block range, result count, response size) | ends the walk; reaches ant with code and text intact |
| timeout | a source or endpoint timeout | kept; a later one replaces an earlier one; worded `query timeout (…)` if ant would not recognise it |
| hint | any other coded reply matching ant's needles that names neither a throttle nor a lagging endpoint (EIP-1474 `limit exceeded`) | kept over endpoint failures, later endpoints still asked, reaches ant verbatim |
| endpoint | everything else: throttles, transport failures, a source that is not ready, an endpoint behind the head | never displaces a better error; a throttle that finally reaches ant is reworded `endpoint unavailable` so ant does not halve on it |

Only `eth_getLogs` is ranked; wallet and app reads are unchanged.

## Lifecycle and threading

`SwarmNode.chainTransport` is set once in `FreedomApp` and installed right after `ant_init`, before the chequebook step and `ant_start_gateway` (the gateway captures its chain wiring at start). The callback runs on ant's blocking pool, possibly concurrently, and blocks that thread on a main-actor task; `SwarmNode` calls into ant only from detached tasks, so neither side waits on the other. `ant_shutdown` drains in-flight callbacks before returning, and the retained context is released after it.

Since ant v0.5.51 (#98) `ant_start_gateway` runs antd's startup chain block itself in the background — persisted-batch verification, owned-batch rediscovery, chequebook adoption — so `SwarmNode.start` no longer calls `ant_deploy_chequebook` or `ant_storage_discover`. The app always passes the Gnosis RPC (no ultra-light mode), so this runs on every launch through the router: one `eth_blockNumber` and two xBZZ log scans filtered by the node address.

Errors forwarded to ant are sanitized (URLs replaced by `[url]`, control characters removed, 500 characters) because ant logs them. Nothing else about a request is logged; the node log line is `[Ant chain] <method> via <source>`.

## Validation

`AntChainBridgeTests`: routed read with id echo, allowlist and envelope validation, signed-Gnosis-only broadcast (typed and legacy), `-32000` re-coding, revert data pass-through, transport failure as error, the four ranks with the wording rules, quorum-only log scans with the wide budget, range-cap parsing, background admission never queueing behind Myotis, and the RLP inspector.

`LogScanRoutingTests`: learned caps and the refusal Ant narrows to, no request once caps are known, cap expiry and cooldown, and the Blockscout check. It covers a match in one request, paging, disagreement on count, amount or sender, Blockscout down or switched off, the tail above its height going through the quorum, and eligibility.

Live check on the simulator: `log stream --predicate 'category == "AntChain" OR category == "ChainData"'` while the node starts — `eth_getLogs` / `eth_blockNumber` lines show `via myotis` / `colibri` / `quorum` / `direct`, and the node log shows "chain transport: routed through the app's chain-data router" followed by the batch discovery line.
