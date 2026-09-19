# Chain-data router

Every chain read on iOS — wallet balances, gas and nonce, dapp `eth_call`s over the EIP-1193 bridge, the onchain-app `html()` fetch, transaction broadcast — goes through one router, `ChainDataRouter` (`Wallet/RPC/`). It is the iOS port of desktop's `src/main/networks/chain-data-router.js` (PR #181 and the adaptive-latency commits `3e0caa5b` / `01dd4862`). ENS name resolution keeps its own resolver (`docs/ens-resolution.md`) and shares Ethereum's chain policy with it.

Three things this gives over the previous single-shot `WalletRPC` walk:

1. **Verified reads on chains without a light client.** M-of-K agreement across the chain's RPC pool labels an answer verified on Base, Arbitrum or any Chainlist add.
2. **Conflict detection.** Endpoints disagreeing is a visible state: an onchain app is hard-blocked, the trust sheet shows who dissented.
3. **Read-heavy apps stay responsive.** A page-driven read gives a slow verified source two seconds before falling through, remembers the route and cools it down, and never queues unbounded work behind a stuck prover or engine.

## Sources and policy

| Source | What it is | Chains | Trust it mints |
| --- | --- | --- | --- |
| `myotis` | embedded P2P light client (`MyotisChainSource`) | 1, 100 | `verified`, method `.myotis`, block = engine head when it stayed stable around the call |
| `colibri` | remote prover, sync-committee proof (`ColibriChainSource`) | 1, 100 | `verified`, method `.colibri`, agreed = prover host |
| `quorum` | K endpoints of the pool, M byte-identical answers (`QuorumRun`) | any | `verified`, method `.quorum`, agreed / dissented / queried hosts, k, m; unpinned |
| `direct` | first endpoint of the pool that answers | any | `unverified`, or `userConfigured` when the URL is one the user added; method `.direct` |

`ChainAccessPolicy` (`ChainAccessPolicy.swift`) is the per-chain policy: `readOrder`, `broadcastOrder`, `quorumK` / `quorumM` / `quorumTimeoutMs`, `proverURL`, `zkProof`. Desktop's defaults: `[myotis, colibri, quorum, direct]` and `[myotis, direct]` on Ethereum and Gnosis, `[quorum, direct]` and `[direct]` elsewhere; K 3, M 2, 5 s. `sanitized(forChainID:)` drops duplicates and sources the chain cannot use and never returns an empty order, so a stored policy from an older build or a bad edit cannot leave a chain unreadable.

The policy lives on `ChainRecord` (`readOrder`, `broadcastOrder`, quorum fields, `proverURL`, `zkProof`) and is read through `ChainStore.policy(forChainID:)`. Ethereum's quorum, prover and ZK values are the ENS settings keys in `SettingsStore` — one value edited from both the Name Resolution page and the Chains → Ethereum page — the record holds them for every other chain. `ChainRecord.defaultRPCURLs` snapshots the URLs the chain shipped with, so "Your RPCs" (user-added, tried first, `userConfigured` trust) and "Public RPCs" are distinguishable; `ChainStore.refreshSeedsIfNeeded` brings records from older builds up to the current seed, keeping the user's own endpoints and leaving a deliberately private list alone.

## Request walk

```
ChainDataRouter.request(chainID:method:params:context:options:)
  normalize params           input→data alias, decimal quantities → hex (every tier sees the same bytes)
  for source in policy.readOrder:
    direct-only method?      filters, web3_* skip the verified tiers
    route bypassed?          cooldown / session block for (source, chain, origin, method, target)
    wait = interactive && a later source exists ? min(configured, 2 s) : configured
    myotis  → slot (1 in flight per chain, queue 16, wait shares the budget) → engine call
    colibri → admission (8 in flight, 2 per route) → prover call
    quorum  → K legs, settle at M, fail when agreement is impossible; keep members running for a following direct tier
    direct  → reuse the quorum's best member if any, else walk the pool skipping endpoints already asked
    deterministic answer (revert with data, -32602, insufficient funds, M agreeing reverts) → throw, walk ends
    anything else                                                                             → next source
  → ChainDataResult { result, trust: ENSTrust, source }
```

`WalletRPC` is the typed façade (`call`, `callOptional`, `balance`, `estimateGas`, …) with `RoutingContext.wallet`; `RPCRouter` (the dapp bridge) passes the page's permission key; `OnchainAppLoader` passes the app's. Errors reaching callers are only `WalletRPC.Error` (deterministic answers, `allProvidersFailed` with the endpoints' errors, `noProviders`, `broadcastUncertain`) or `CancellationError`.

### Adaptive layer (`ChainDataAdmission.swift`)

- **Interactive deadline.** Only a read with a page origin, and only when a later source exists in the order, gives a source `min(configured, 2000 ms)`. Wallet reads and the last source keep the configured timeout, so verification is never traded away where nobody is waiting on a frame and a working read is never turned into a failure.
- **Route memory** (`AdaptiveRouting`, process-local, 1024 routes, FIFO). Key: (source, chain, origin, method, target contract or account). A timeout opens 15 s, then 30 s, then 60 s cooldowns that a success clears. An execution-limit failure (`out of gas`, `execution … limit`) blocks the route for the session and is never cleared by a lighter call succeeding. Nothing here reorders the user's policy or survives a restart.
- **Admission** (`SourceAdmission`). Myotis executes one read at a time per chain with a queue of 16; the wait shares the caller's budget, an abandoned waiter leaves the queue, a slot handed over as the deadline fired is passed along. Colibri keeps 8 in flight and 2 per route and refuses beyond. Neither source's work can be cancelled, so `withSourceDeadline` bounds the *wait* through a first-settled continuation (awaiting a `Task`'s value is not interruptible, which is why it is not a task-group race), keeps the work tracked and releases the slot when it settles.

### Quorum (`QuorumChainTier.swift`)

`QuorumRun` asks the first K available endpoints concurrently with the same bytes, buckets answers by a stable serialization of `result` (`StableJSON`), settles as soon as M agree and fails as soon as agreement is impossible. Under an interactive deadline the wait is capped but, when a direct tier follows, each leg keeps the configured endpoint timeout: a late single answer then serves the direct tier as `DirectFallback` (with the agreed / dissented / queried evidence) instead of a new request, and endpoints the quorum already asked are not asked again. An "Out of gas" from M members is a capacity failure for the route. Unlike desktop, M members agreeing on a revert is a verified revert rather than a lost answer. The generic quorum is unpinned, as on desktop; pinning through the chain's `AnchorCorroboration` is a follow-up.

### Broadcast and fee quote

`broadcast(chainID:rawTransaction:)` walks `policy.broadcastOrder`. An uncertain Myotis outcome (`WalletRPC.Error.broadcastUncertain`) is terminal — the transaction may be propagating over devp2p, so it is never re-broadcast elsewhere. A direct node rejection keeps its JSON-RPC code inside `allProvidersFailed`. `feeQuote(chainID:)` takes `eth_gasPrice` and the latest header from one source — on direct, from one URL — and a source that can only give one of the two falls through whole, so `GasOracle`'s base-fee floor is never computed against another endpoint's head.

## Consumers

- **Onchain apps** (`docs/onchain-apps.md`): `OnchainAppLoader` reads `html()` with the app's permission key; `.verified` and `.userConfigured` load, `.unverified` gates (`Gate.unverifiedOnchain`), unverified with dissent hard-blocks (`Gate.conflictOnchain`, Try again re-fetches).
- **Dapp bridge**: `eth_blockNumber`, `eth_getBalance`, `eth_call` are interactive reads.
- **Wallet**: balances, token balances, nonce, gas estimate, receipts through `WalletRPC`; broadcast and fee quote through the router.
- **Trust sheet** (`TrustShield`): direct answers show the endpoint, the agreement attempted and any dissent.

## Settings

Settings → **Chains** lists the chains; each chain's page has the read and verification order (a native drag-to-reorder list with a switch and status badge per source — Myotis readiness, "2 of 3" for quorum, "Your endpoint" for direct; tapping a source opens its options: the Colibri prover + ZK, the quorum M-of-K + timeout, Direct RPC's endpoint list), the transaction broadcast order, "Your RPCs" above "Public RPCs" with reset, and removal for custom chains. Settings → **Name Resolution** is the same pattern for ENS (`docs/ens-resolution.md`), sharing Ethereum's quorum and prover values.

## Observability

Category `ChainData`, prefix `[chain-data]`: one line per tier attempt with the elapsed time and reason, `via <source> <ms>ms` on success, `bypassed for this app workload: cooling down for Ns`, `direct reuses quorum member <host>`, `broadcast chain=… via …`, `feeQuote … via …`. On a simulator, `FREEDOM_DEBUG_OPEN_URL=web3://…` plus `log stream --predicate 'category == "ChainData"'` is the iOS equivalent of desktop's read lab.

## Differences from desktop

- Quorum agreement on a revert is a verified revert (desktop loses it when every member reverts).
- Custom-RPC name resolution stays fail-closed: the user's node is the only RPC method after migration (desktop's legacy order adds quorum).
- Keyed commercial providers (Alchemy / Infura / DRPC pages) are not ported; the model leaves room (a URL list is a URL list).

## File map

```
Freedom/Freedom/Wallet/RPC/
├── ChainAccessPolicy.swift     — ChainSource, ChainAccessPolicy (+ defaults, sanitize), RoutingContext, ChainDataResult
├── ChainDataRouter.swift       — request / broadcast / feeQuote, verified-source dispatch, direct tier, envelope parsing, param normalization
├── ChainDataAdmission.swift    — AdaptiveRouting, SourceAdmission, FirstSettled, withSourceDeadline
├── QuorumChainTier.swift       — QuorumRun, DirectFallback, StableJSON
├── ChainDataSource.swift       — ChainDataSource protocol, MyotisChainSource, ColibriChainSource, ChainCallShape
└── WalletRPC.swift             — typed façade
Freedom/Freedom/Wallet/Chains/
├── ChainRecord.swift           — persisted policy fields + defaultRPCURLs snapshot
├── ChainStore.swift            — policy(forChainID:), updatePolicy, seeds + refresh, user-added vs shipped
└── ChainRegistry.swift         — pools, sources, policy access, isUserConfigured
Freedom/Freedom/
├── ChainDetailView.swift       — Settings → Chains → chain
├── RPCSettingsView.swift       — Settings → Chains list
├── ENSSettingsView.swift       — Settings → Name Resolution
└── ChainSourceRows.swift       — shared row / badge / field views
Tests: ChainDataRouterTests, ChainDataAdaptiveTests, ChainDataQuorumTests, ChainDataConsumerTests, ChainPolicyStoreTests, ENSResolutionOrderTests
```
