# Ant chain transport through Freedom (iOS)

Port of desktop's `docs/ant-chain-bridge.md` / `ant-chain-bridge.js` (PR #419). Desktop runs `antd` as a process and hands it a loopback URL; iOS embeds `ant-ffi`, and ant v0.5.45 added a host callback for exactly that case (`ant_set_chain_transport`, ant #77). Freedom installs the callback, so the node's Gnosis reads and broadcasts go through the same chain-data router as the wallet (`docs/chain-data-router.md`) instead of the single pinned RPC in `BeeBootConfig`.

## Routing and authority

`AntChainBridge` (`Swarm/Node/AntChainBridge.swift`) receives a complete JSON-RPC request body from ant and returns a response body. Chain is fixed to Gnosis (100). The eight methods ant's chain module issues are allowed: the seven reads follow Gnosis's configured read policy (default Myotis → Colibri → RPC quorum → direct), `eth_sendRawTransaction` follows the broadcast policy and is accepted only for a transaction that is signed and carries chain id 100 (`SignedTransactionInspector`, legacy EIP-155 and typed 0x01–0x03). Anything else is answered with `-32601` / `-32600` / `-32602`.

Ant's reads are background work: `ChainDataRouter.Options.background` uses Myotis only when its single in-flight slot is idle and never queues for it, so the node's polling cannot push an interactive wallet or app read into queue-full fallback. `eth_getLogs` scans get a 60 s per-endpoint budget on the direct tier and the quorum legs (`Options.directTimeout`).

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

With the transport in place, `SwarmNode.start` also runs `ant_storage_discover` once the node serves (light mode only): antd's startup step 3, adopting funded batches this account owns on-chain but has no local issuer for (a reinstall, or a batch bought on desktop with the same vault). Best-effort, logged to the node log as `batch discovery: N owned batches registered`.

Errors forwarded to ant are sanitized (URLs replaced by `[url]`, control characters removed, 500 characters) because ant logs them. Nothing else about a request is logged; the node log line is `[Ant chain] <method> via <source>`.

## Validation

`AntChainBridgeTests`: routed read with id echo, allowlist and envelope validation, signed-Gnosis-only broadcast (typed and legacy), `-32000` re-coding, revert data pass-through, transport failure as error, the four ranks with the wording rules, the wide log-scan budget, background admission never queueing behind Myotis, and the RLP inspector.

Live check on the simulator: `log stream --predicate 'category == "AntChain" OR category == "ChainData"'` while the node starts — `eth_getLogs` / `eth_blockNumber` lines show `via myotis` / `colibri` / `quorum` / `direct`, and the node log shows "chain transport: routed through the app's chain-data router" followed by the batch discovery line.
