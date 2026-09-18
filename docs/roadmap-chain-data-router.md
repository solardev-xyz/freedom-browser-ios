# Roadmap: generic chain-data router with adaptive latency and per-chain policy settings

**Status:** implemented on `feat/chain-data-router` (2026-09-18); the design doc is `chain-data-router.md`, this file is the plan it followed. Deviations: Ethereum's quorum / prover values stay in the ENS settings keys and the chain policy reads them (no one-time copy into the record); the Name Resolution page got the same ordered-policy UI (desktop "Resolution order") instead of a cross-link only; custom-RPC name resolution stays fail-closed.
**Branch:** `feat/chain-data-router` off `main` at `d021563`
**Last updated:** 2026-09-18
**Desktop reference:** `src/main/networks/chain-data-router.js` (1,122 lines, 49 unit tests), `network-registry.js`, `src/shared/chains.json`, `endpoint-sources.json`, the per-chain detail page in `src/renderer/pages/settings.html` (≈ lines 3826–4110), commits `3e0caa5b` / `01dd4862` (adaptive read fallback), issue #221 (zSwap read lab).

## 1. Goal

One router answers every chain read on iOS the way desktop's does: walk the chain's configured source order (Myotis → Colibri → RPC quorum → direct), keep *who answered* on every result, adapt to read-heavy apps without reordering the user's policy, and let the user edit that policy per chain. Consumers: the dapp bridge (EIP-1193 reads), the wallet (balances, gas, nonce, receipts), transaction broadcast, the fee quote, and the onchain-app `html()` fetch. ENS name resolution keeps its own resolver but shares the mainnet policy record.

Three things this buys that iOS lacks today:

1. **Verified reads on chains without a light client** (Base, Arbitrum, any Chainlist add): M-of-K agreement labels the answer verified; today every read there is a single endpoint with no trust label at all.
2. **Conflict detection.** Two endpoints disagreeing is a visible state (hard block for onchain apps, red shield); today a lying endpoint on the direct tier is indistinguishable from an honest one.
3. **Read-heavy apps stay responsive** when Myotis or Colibri cannot serve their calls in time (the zSwap finding): 2 s interactive budgets, cooldowns, capacity memory and admission control, instead of a page stalling on a prover.

## 2. Current iOS architecture (what changes)

| Piece | Today | Problem |
| --- | --- | --- |
| `WalletRPC.fanOutBody` (`Wallet/RPC/WalletRPC.swift`) | `registry.verifiedSources` in order, then the chain's URL pool one by one, 8 s per URL. Returns the bare value. | No provenance, no per-source deadline, no interactive/internal distinction, no cooldowns, no quorum. |
| `ChainDataSource` protocol + `MyotisChainSource` / `ColibriChainSource` (`Wallet/RPC/ChainDataSource.swift`) | Params-aware `serves` gate (`ChainCallShape.servableCall`: only from/to/data/value, `latest`); Colibri for chains 1 and 100. | Fine as sources. No admission control: N concurrent heavy calls all hit the engine / prover. Colibri call is not cancellable. |
| `ChainRegistry` (`Wallet/Chains/ChainRegistry.swift`) | Per-chain `EthereumRPCPool` (shuffle + quarantine), one global `verifiedSources` list. | Policy is global, not per chain. |
| `ChainRecord` / `ChainStore` | id, names, explorer, poll interval, `isBuiltIn`, `rpcURLs`, sortOrder. | No read order, broadcast order, quorum params, prover URL, or "user-added URL" flag. |
| `OnchainAppLoader` (`Onchain/OnchainAppLoader.swift`) | Its own copy of the ladder with provenance, because `WalletRPC` strips it. | Duplicate to delete once the router returns provenance. |
| `RPCRouter` (`Wallet/Bridge/RPCRouter.swift`) | Dispatches `eth_call` / balance / blockNumber to `WalletRPC` for the tab's origin. | Doesn't pass the origin down, so the read cannot be treated as interactive. |
| `TransactionService.send` | `WalletRPC.sendRawTransaction` (Myotis source serves it when ready, then pool). | Works; keep, route through `broadcast(order:)`. |
| `GasOracle` | `eth_gasPrice` via `WalletRPC`, median over providers. | Desktop's fee quote takes both components from one source; note only, not a blocker. |
| ENS (`ENSResolver`, `QuorumWave`, `QuorumLeg`, `AnchorCorroboration`) | Universal-Resolver-specific quorum, block-pinned, `ens*` settings keys. | Stays. Its quorum K/M/timeout/anchor become mainnet's policy record (§6). |
| Settings | RPC page = chain list → per-chain URL editor; ENS page = method picker + quorum + safety + CCIP. | No per-chain source order, no broadcast order, no prover per chain. |

## 3. Target design

### 3.1 Types

```swift
enum ChainSource: String, CaseIterable, Codable { case myotis, colibri, quorum, direct }

struct ChainAccessPolicy: Codable, Equatable {   // per chain, persisted
    var readOrder: [ChainSource]                  // default: [myotis, colibri, quorum, direct] on 1/100, [quorum, direct] elsewhere
    var broadcastOrder: [ChainSource]             // default: [myotis, direct] on 1/100, [direct] elsewhere
    var quorumK: Int, quorumM: Int, quorumTimeoutMs: Int   // defaults 3 / 2 / 5000
    var proverURL: String?                        // Colibri; nil → binding default for the chain
    var zkProof: Bool                             // Colibri
}

struct RoutingContext { let origin: String? }     // permission key of the page; nil = wallet-internal

struct ChainDataResult { let result: Any; let trust: ENSTrust; let source: ChainSource }
```

`ENSTrust` is reused as the trust object (level, method, block, agreed/dissented/queried, k/m); `ENSResolutionMethod` gains `.direct` (kept out of the ENS picker's `selectableCases`). `ENSTrustLevel.userConfigured` is used for a direct answer from a URL the user added.

### 3.2 `ChainDataRouter` (`Wallet/RPC/ChainDataRouter.swift`, `@MainActor`)

- `request(chainID:method:params:context:) async throws -> ChainDataResult` — normalizes params (hex quantities, `input`/`data` alias, exactly as `ChainCallShape` does), walks `policy.readOrder`, skips sources whose `serves` gate rejects the shape, applies the adaptive layer (§3.4), returns the first answer with trust. A deterministic answer (revert with data, `-32602`, insufficient funds) from any source ends the walk, as today. Every failure is logged per source (`[chain-data]` category, already used).
- `feeQuote(chainID:)` — Myotis fee estimate, else each source's `eth_gasPrice` + optional `eth_maxPriorityFeePerGas` from the **same** source, else direct from the same URL.
- `broadcast(chainID:rawTransaction:)` — `policy.broadcastOrder`; an uncertain Myotis outcome is terminal (never re-broadcast elsewhere), a node rejection keeps its JSON-RPC code.
- Direct-only methods (`web3_clientVersion`, `web3_sha3`, filters) skip the verified sources.

### 3.3 Sources

- **Myotis / Colibri:** existing `ChainDataSource` classes, unchanged interface, plus admission (§3.4).
- **Quorum (new `QuorumChainSource`):** K endpoints from the chain's pool queried concurrently with the raw JSON-RPC body; answers bucketed by a stable serialization of `result`; settle as soon as M agree; fail as soon as agreement is impossible; on failure hand the highest-priority successful member to the direct tier as its answer with the agreed/dissented evidence, so direct does not repeat the call. Trust: `verified` / method `.quorum` / k, m. **Unpinned**, as on desktop (block `nil`); honest endpoints at different heads can produce a spurious conflict, which the UI words as "try again". A later improvement can pin through the chain's `AnchorCorroboration` (make it take any pool).
- **Direct:** walk the pool (quarantining as `resolveDirect` does), trust `unverified`, or `userConfigured` when the URL is one the user added.

### 3.4 Adaptive layer (desktop `3e0caa5b`, `01dd4862`)

- **Interactive** = `context.origin != nil` (dapp bridge, onchain-app loader). Wallet-internal reads keep the chain's configured timeout.
- **Deadline:** an interactive read gives a source `min(configured, 2000 ms)` only when a later source exists in the order; the last source keeps the configured timeout.
- **Route key** = (source, chain, origin, method, target address). State per key, process-local, capped at 1,024 keys:
  - timeout → cooldown 15 s, then 30 s, then 60 s (bypass the source for that route);
  - capacity failure (`out of gas`, `execution … limit`) → session block for that route;
  - success clears timeouts, never a session block.
- **Admission:** Myotis 1 in flight per chain with a queue of 16 (the wait shares the caller's budget; a caller that falls through abandons its slot); Colibri 8 in flight total, 2 per route, refuse beyond. Colibri and Myotis work is not cancellable: the router bounds the *wait*, keeps the promise tracked until it settles, and releases the slot then.
- **Quorum under a deadline:** the interactive deadline caps how long the router waits for agreement; in-flight legs keep running to their own timeout so a late single answer can still serve the direct tier without a new request.

### 3.5 Consumers

- `WalletRPC` keeps its typed API (`call`, `balance`, `estimateGas`, …) as a thin wrapper over `router.request` with `context: nil`; the parse closures stay.
- `RPCRouter.handle` passes `RoutingContext(origin: origin.key)`; `eth_call` results for dapps therefore get the interactive treatment.
- `OnchainAppLoader` becomes `router.request(... context: origin, includeTrust)`; its private ladder and `directTrust` / `verifiedTrust` helpers go. `Gate.unverifiedOnchain` stays; add `Gate.conflictOnchain(document evidence)` (no Continue, "Try again" + "RPC settings") when the trust carries dissent.
- `TransactionService.send` → `router.broadcast`; `GasOracle` → `router.feeQuote` (median across sources is dropped in favour of source coherence, desktop parity).
- Trust shield: onchain apps already show trust; the wallet home could later show the balance's source. Not in scope.

## 4. Persistence and settings

### 4.1 Model

`ChainRecord` gains `readOrder: [String]`, `broadcastOrder: [String]`, `quorumK`, `quorumM`, `quorumTimeoutMs`, `proverURL: String?`, `zkProof: Bool`, `defaultRPCURLs: [String]` (seed snapshot, so "user-added" = not in the snapshot). SwiftData lightweight migration with defaults per chain (§3.1). `ChainStore.policy(forChainID:)` / `updatePolicy(forChainID:_:)` bump `version` so views refresh.

Mainnet seeds its quorum block from the existing `ensQuorumK/M/TimeoutMs` and `ensColibriProverUrl` / `ensColibriZkProof` keys once (marker in `SettingsStore`), then those keys are read from the record. The ENS resolver keeps `ensResolutionMethod`, `ensFallbackToQuorum`, `ensBlockAnchor`, `ensBlockAnchorTtlMs`, `blockUnverifiedEns`, `enableCcipRead` (name-resolution policy, desktop's separate "Resolution order").

### 4.2 UI (desktop parity, SwiftUI Form)

Settings → **Chains** (rename of RPC): list of chains with chain id subtitle, Add Chain. Per chain:

1. **Read and verification order** — reorderable rows (`.onMove`, edit mode) with a toggle each: Myotis P2P light client (status badge from `MyotisNode`: Ready / Syncing / Unsupported), Colibri cryptographic verification (Verified badge), RPC quorum ("2 of 3" badge; Require M of K steppers, timeout), Direct RPC (Public endpoint badge; a chain must keep at least one usable source). Rows for sources that cannot serve the chain (Myotis outside 1/100, Colibri outside its coverage) are shown disabled with the reason.
2. **Colibri prover endpoint** — on 1/100, empty = binding default; ZK proof toggle.
3. **Transaction broadcast** — reorderable Myotis / Direct.
4. **RPC endpoints** — existing editor, with "Your RPCs" (user-added, tried first) above "Public RPCs" (seed); reset to defaults.
5. Remove this chain (custom chains only).

ENS page: the quorum section shows the mainnet values from the chain record with a link "Edit on Chains → Ethereum" rather than a second editor.

Desktop's keyed commercial providers page (Alchemy / Infura / DRPC API keys) is **out of scope** here; the model leaves room (a URL list is a URL list).

## 5. Phases and commits

1. **Router core** — `ChainDataRouter`, `ChainAccessPolicy` (in-memory defaults, no persistence yet), sources wired, `WalletRPC` re-implemented on top with identical behaviour. Tests: existing wallet/router suites unchanged + router unit tests with fake sources. No user-visible change.
2. **Adaptive latency** — routing context from the bridge and onchain loader, deadlines, cooldowns, session blocks, Myotis slot, Colibri admission. Tests mirror desktop's: falls through after two seconds and bypasses a timed-out route; escalating cooldowns reset on success; capacity demotes only the matching app and target; serialized Myotis reads; queue-full refusal; last-source keeps the configured timeout; non-cancellable work does not starve fallbacks.
3. **Generic quorum + direct reuse** — `QuorumChainSource`, settle-early, agreement-impossible fail, direct fallback reuse, user-configured trust level. Tests: settles on M matching, does not extend past 2 s with a source after it, verified after budget for wallet reads, reuses a member as direct, no partial reuse when direct is absent.
4. **Consumers** — `OnchainAppLoader` on the router, `Gate.conflictOnchain`, broadcast and fee quote through the router, shield copy for `.direct`. Simulator smoke with `FREEDOM_DEBUG_OPEN_URL` on zSwap plus a quote, reading `[chain-data]` per-source latency; that log is the iOS equivalent of the desktop read lab.
5. **Persistence + settings UI** — `ChainRecord` fields, migration from `ens*` keys, Chains page and per-chain detail, ENS page cross-link. Tests: migration, policy round-trip, order validation (never empty, no duplicates, unsupported sources rejected for the chain).
6. **Docs + memory** — `docs/chain-data-router.md` (replaces the wallet-architecture read-path section), update `docs/onchain-apps.md` known-differences list, `docs/ens-resolution.md` settings table.

Each phase is one or two commits; user smoke after phase 4 (behaviour) and after phase 5 (settings).

## 6. Decisions to confirm before starting

- **ENS keeps its own resolver** and only shares the mainnet policy record (quorum K/M/timeout, prover, ZK). Merging ENS resolution into the generic router is possible later but is not needed for parity.
- **Generic quorum is unpinned** like desktop's. Pinning through `AnchorCorroboration` is a follow-up.
- **`ENSTrust` is reused** as the universal trust type rather than introducing a parallel `ChainTrust`.
- **Keyed commercial providers** stay out of scope.
- **Default order for chains outside Myotis/Colibri coverage** is `[quorum, direct]` (desktop's Base entry), so a fresh Chainlist add gets verified reads only when its pool has ≥ 3 endpoints; otherwise direct.

## 7. Smoke checklist (device)

- zSwap: page loads verified; a quote resolves within a few seconds even with Myotis synced (Myotis serialized, Colibri bounded, direct answers); the `[chain-data]` log shows fall-through with reasons; a second quote uses the cooldown (no repeated 2 s stall).
- Gnosis send: gas quote and broadcast unchanged.
- Base (Chainlist add, 3+ endpoints): balance shows; Chains → Base shows Quorum then Direct; dropping to one endpoint falls back to Direct with an unverified label on an onchain app.
- Chains → Ethereum: reorder to put Direct first → an onchain app gates on every load; disable Colibri → Myotis then quorum; ENS page reflects the same K/M.
