# Roadmap: Per-Chain RPC Provider Settings

**Status:** planned, not started
**Branch:** `feature/rpc-providers`
**Last updated:** 2026-05-19

## 1. Goal

Today Settings → RPC shows a single flat list of RPC providers. That list
is Ethereum-mainnet-only, and Gnosis providers are hardcoded and invisible
to the user. The goal:

- Settings → RPC shows a **list of chains** (Ethereum mainnet + Gnosis by
  default).
- Tapping a chain opens a page showing **that chain's** RPC providers,
  editable (add / remove / reset) — the editing UX that exists today,
  parameterized per chain.
- The main RPC page lets the user **add new chains**, two ways:
  1. Search `https://chainlist.org/rpcs.json` and add a result.
  2. Add a fully custom chain by hand.
- The per-chain token registry has to follow — a chain must be able to
  carry its own native asset.

## 2. Current architecture

Precise inventory of what exists and therefore what must change.

### 2.1 `Chain` — compile-time value type

`Freedom/Freedom/Wallet/Chains/Chain.swift`

- `struct Chain: Equatable, Hashable, Identifiable` — fields: `id` (EIP-155
  chain ID), `displayName`, `explorerBase`, `nativeSymbol`, `pollInterval`.
- `static let mainnet` (id 1), `static let gnosis` (id 100).
- `static let all: [Chain] = [.gnosis, .mainnet]`.
- `static let defaultChain: Chain = .gnosis`.
- `static func find(id:) -> Chain?` — linear scan of `all`.

Every field is a compile-time constant. The whole 2-chain universe is
fixed at build time.

### 2.2 RPC provider sourcing

**Mainnet:** `SettingsStore.ensPublicRpcProviders` (`[String]` in
UserDefaults, editable in `RPCSettingsView`) →
`EthereumRPCPool` (`Freedom/Freedom/EthereumRPCPool.swift`: shuffle +
exponential-backoff quarantine) → consumed by:

- `ENSResolver` / `AnchorCorroboration` — ENS quorum resolution.
- `ColibriENSClient` — sets `client.eth_rpcs = settings.ensPublicRpcProviders`
  (the Colibri verifier's storage-proof source).
- `ChainRegistry.rpcURLs(for: .mainnet)` → `mainnetPool.availableProviders()`
  — mainnet **wallet** reads.

One `EthereumRPCPool` instance is built in `FreedomApp.init` and injected
into both `ENSResolver` and `ChainRegistry`, so ENS and wallet share
mainnet quarantine state. `EthereumRPCPool.effectiveProviders()` reads
`settings.ensPublicRpcProviders`, falling back to
`SettingsStore.defaultPublicRpcProviders` (9 hardcoded mainnet URLs) when
the user's list is empty/malformed.

**Gnosis:** `ChainRegistry.gnosisURLs` — a `static let [URL]` with three
hardcoded endpoints (`rpc.gnosischain.com`, `rpc.ankr.com/gnosis`,
`gnosis-mainnet.public.blastapi.io`). No pool, no quarantine, not
user-editable. `ChainRegistry.markSuccess/markFailure` are explicit
no-ops for Gnosis.

`ChainRegistry.rpcURLs(for:)` is a hardcoded `switch` over
`Chain.mainnet` / `Chain.gnosis` with a `default: assertionFailure`.

### 2.3 Token registry

`Freedom/Freedom/Wallet/Tokens/TokenRegistry.swift`

- `static let builtins: [Token]` — hardcoded, every token tagged with a
  `chainID`. Mainnet: ETH, USDC, USDT, DAI, EURC, BZZ. Gnosis: xDAI,
  xBZZ, EURe.
- `tokens(for: Chain)` — `builtins.filter { $0.chainID == chain.id }`.
- `native(for: Chain)` — **`preconditionFailure`** if the chain has no
  native (`address == nil`) entry. A user-added chain with no native
  row would crash here.

`Token` (`Freedom/Freedom/Wallet/Tokens/Token.swift`) — `chainID`,
optional `address` (nil = native), `symbol`, `name`, `decimals`,
`logoAsset`.

### 2.4 Chain consumers

- `WalletHomeView` — `@AppStorage(WalletDefaults.activeChainID)`, chain
  picker `ForEach(Chain.all)`.
- `AssetPickerView` — `ForEach(Chain.all)` and a balance-aggregation loop
  `for chain in Chain.all`.
- `EthereumBridge.handleSwitchChain` — `Chain.find(id:)`; returns `4902`
  (`unrecognizedChain`) for unknown IDs. Comment: "we don't implement
  `wallet_addEthereumChain` in v1."
- `RPCRouter` — `wallet_addEthereumChain` is in the 4200-unsupported set.
- `BrowserTab` — reads `WalletDefaults.activeChainID`, `Chain.find`.
- `WalletDefaults.activeChainID` — UserDefaults `Int`.
- `WalletRPC` (`Freedom/Freedom/Wallet/RPC/WalletRPC.swift`) — single-shot
  JSON-RPC with fall-through over `registry.rpcURLs(for: chain)`. Not
  consensus (a lying RPC yields a wrong balance, not an attacker-chosen
  redirect — so RPC endpoints are treated as untrusted-but-not-adversarial).

### 2.5 Swarm — explicitly independent, out of scope

`SwarmFunderConstants.pinnedGnosisRPC` (`https://rpc.gnosischain.com`) is
used by `BeeBootConfig` for bee-lite's `blockchainRpcEndpoint` in light
mode. The code comments state it is deliberately decoupled from
`ChainRegistry`'s Gnosis pool. **This roadmap does not touch the Swarm
RPC path.**

## 3. Core architectural change

`Chain` must stop being a compile-time constant and become **runtime
data**. A new SwiftData-backed `ChainStore` owns the chain records and
their per-chain RPC endpoint lists. `Chain` remains a value type, vended
from the store, so the wide blast radius of call sites that pass `Chain`
around is unaffected.

Mainnet and Gnosis are seeded as **built-in, non-deletable** chains.
Mainnet must always exist — the ENS registry and Colibri are
mainnet-only; deleting it would break ENS resolution.

## 4. Scope decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Persistence | **SwiftData `@Model`** | Matches the app's pattern for all structured/relational data (tabs, history, bookmarks, permissions). Chains → providers is relational. |
| Custom-chain tokens | **Native token only** | Custom chains get their native asset from chainlist data / the manual form. User-managed ERC-20s on custom chains is a separate follow-up. Built-in ERC-20 lists stay for mainnet/Gnosis. |
| `wallet_addEthereumChain` (EIP-3085) | **Deferred** | Dapp-initiated add-chain stays unsupported for now. Once the chain store exists it's a clean separate change (decode params + approval sheet + store write). |
| chainlist.org data | **Live fetch + cache** | The list is community-maintained and changes constantly; bundling a snapshot would rot. Fetch on demand, cache locally. |

## 5. Phase 1 — Chain data model

No visible UI change. This is the foundation and the riskiest phase —
its blast radius reaches ENS and Colibri.

### 5.1 SwiftData model

New `@Model final class ChainRecord`:

- `id: Int` — EIP-155 chain ID, unique.
- `displayName: String`
- `nativeName: String`, `nativeSymbol: String`, `nativeDecimals: Int`
- `explorerBase: String` (URL string)
- `pollIntervalSeconds: Int`
- `isBuiltIn: Bool` — true for mainnet + Gnosis; gates deletion.
- `rpcURLs: [String]` — ordered provider list. Stored inline as a string
  array on the record (mirrors today's `ensPublicRpcProviders` shape;
  simpler than a child `@Model`, and ordering + dedup logic already
  exists in `EthereumRPCPool.normalize`).
- `sortOrder: Int` — stable display order in the chain list.

Register `ChainRecord.self` in the `ModelContainer` schema in
`FreedomApp.init` (alongside `TabRecord`, `HistoryEntry`, etc.).

### 5.2 `ChainStore`

New `@MainActor @Observable final class ChainStore`:

- Wraps the `ModelContext`.
- On first launch (no `ChainRecord` rows), **seeds** mainnet + Gnosis as
  `isBuiltIn = true`. Mainnet RPC URLs seed from
  `SettingsStore.defaultPublicRpcProviders`; Gnosis from the current
  `ChainRegistry.gnosisURLs`.
- Vends `Chain` value types: `allChains() -> [Chain]`,
  `chain(id:) -> Chain?`.
- CRUD: `addChain(...)`, `updateRPCURLs(chainID:, [String])`,
  `deleteChain(id:)` (rejects `isBuiltIn`).
- `Chain` value type extends to carry `nativeName` / `nativeDecimals`
  (chainlist provides both; needed so the native token derives from the
  chain — see 5.4).

### 5.3 `EthereumRPCPool` becomes per-chain

- `EthereumRPCPool` takes a `chainID` and reads its provider list from
  `ChainStore` instead of `settings.ensPublicRpcProviders`.
- `ChainRegistry` holds `[chainID: EthereumRPCPool]`, lazily created.
  Every chain (built-in and custom) gets a pool — uniform shuffle +
  quarantine, replacing Gnosis's bare-list special case.
- The **mainnet** pool instance is still shared with `ENSResolver` /
  `AnchorCorroboration` (preserve the ENS↔wallet shared-quarantine
  behavior the current `ChainRegistry` doc comment describes).
- `ChainRegistry.rpcURLs(for:)` / `markSuccess` / `markFailure` become
  data-driven — no `switch` over chain identity.

### 5.4 Token registry

- The **native** token derives from the `Chain` itself
  (`nativeName` / `nativeSymbol` / `nativeDecimals`), not from
  `TokenRegistry.builtins`. Removes the `native(for:)`
  `preconditionFailure` — a custom chain can never be missing a native.
- `TokenRegistry.builtins` keeps the **ERC-20** rows for mainnet + Gnosis
  only. `tokens(for:)` returns `[native] + builtins-filtered-ERC20s`.
- Custom chains return just `[native]` until per-chain ERC-20 management
  ships (follow-up).

### 5.5 Rewiring

- `ENSResolver`, `AnchorCorroboration`, `ColibriENSClient` source mainnet
  RPCs from the mainnet `ChainRecord` via the store. ENS/Colibri stay
  hard-pinned to chain ID 1 — they are mainnet-only by protocol.
- `ColibriENSClient.currentClient()` sets `eth_rpcs` from the mainnet
  record's `rpcURLs` instead of `settings.ensPublicRpcProviders`.
- Replace every `switch chain { case Chain.mainnet ... }` /
  `case .gnosis` identity switch with `.id` comparisons.
- `FreedomApp.init` constructs `ChainStore` early and threads it into
  `ChainRegistry`, `ENSResolver`'s pool, and `ColibriENSClient`.

### 5.6 Migration

One-time, marker-flagged (same pattern as the Colibri
`ensResolutionMethodMigrated` migration):

- If no `ChainRecord` rows exist, seed mainnet + Gnosis.
- Mainnet's `rpcURLs` ← existing `settings.ensPublicRpcProviders` if the
  user had customized it; otherwise `defaultPublicRpcProviders`.
- Gnosis's `rpcURLs` ← `ChainRegistry.gnosisURLs`.
- `settings.ensPublicRpcProviders` is left in place but becomes unused;
  remove it in a later cleanup once the store is proven.

### 5.7 Phase 1 acceptance

- App builds; full test suite green.
- ENS resolution (quorum + Colibri) still works — mainnet RPCs now come
  from the store.
- Wallet balances on mainnet + Gnosis still work.
- No UI change visible to the user yet.

## 6. Phase 2 — RPC settings UI

- `RPCSettingsView` becomes a **chain list**: one row per `ChainStore`
  chain, showing name + provider count. Built-in chains flagged
  (non-deletable); custom chains swipe-to-delete.
- Tapping a chain → `ChainRPCDetailView`: the existing add / remove /
  reorder / reset-to-defaults provider editor from today's
  `RPCSettingsView`, parameterized by chain. Writes back via
  `ChainStore.updateRPCURLs`.
- On settings dismiss, invalidate the affected chain's pool (today
  `SettingsView.finish()` already calls `resolver.invalidate()`; extend
  to invalidate `ChainRegistry` pools).

## 7. Phase 3 — Add a custom chain manually

- "Add chain" entry on the main RPC page → a form:
  chain ID, display name, native currency (name / symbol / decimals),
  ≥1 RPC URL, explorer base URL.
- Validation: chain ID must not collide with an existing chain; RPC URLs
  must be well-formed `http(s)`; native decimals in a sane range.
- Writes a non-built-in `ChainRecord`.

## 8. Phase 4 — chainlist.org integration

- "Search chainlist" entry → fetch `https://chainlist.org/rpcs.json`
  (multi-MB; cache to disk with a TTL, fail gracefully offline).
- Client-side search by name / chain ID.
- Selecting a result pre-fills a chain: name, chain ID, native currency,
  explorer, and the RPC list.
- **Filter the RPC list**: drop endpoints with API-key templating
  (`${INFURA_API_KEY}` etc.) and, where the data marks it, tracking
  endpoints — keep open, no-key, no-tracking URLs.

## 9. Potential issues / risks

1. **`Chain` identity switches** — non-exhaustive struct `switch`es on
   `.mainnet` / `.gnosis` exist across the wallet + bridge; all must move
   to `.id` comparison. Easy to miss one.
2. **ENS is mainnet-only** — the mainnet chain must be non-deletable, and
   `ENSResolver` / `ColibriENSClient` must stay pinned to chain ID 1.
3. **`EthereumRPCPool` refactor blast radius** — it currently feeds ENS
   and Colibri directly. Repointing its source is the highest-risk edit
   in Phase 1.
4. **chainlist.org `rpcs.json` size** — multi-MB; needs disk caching, a
   refresh TTL, and graceful offline behavior. Parsing must skip
   key-templated / tracking RPC entries.
5. **Chain ID collision** — manual-add and chainlist-add must reject IDs
   that already exist.
6. **`AssetPickerView` balance loop** — `for chain in Chain.all`
   fetching balances becomes N custom chains × RPC round-trips; may need
   to scope to chains that actually hold tokens, or parallelize/bound it.
7. **Migration correctness** — existing users' customized
   `ensPublicRpcProviders` must transfer to the mainnet record exactly
   once; a bug here silently resets a user's provider list.
8. **`SettingsStore.defaultPublicRpcProviders`** — stays as the seed
   source for mainnet; don't delete it during the `ensPublicRpcProviders`
   cleanup.

## 10. Future phases (deferred — not part of phases 1–4)

These are intentionally out of the initial scope but specified here so
the design isn't lost. Both depend on Phase 1's `ChainStore`.

### Phase 5 — `wallet_addEthereumChain` (EIP-3085)

Dapp-initiated add-chain. Today `wallet_addEthereumChain` sits in the
`RPCRouter` 4200-unsupported set; `EthereumBridge.handleSwitchChain`
returns `4902` for unknown chains expecting the dapp to "add it first."
Once `ChainStore` exists, wire the real handler.

- **Params coder** — new decoder (sibling to `SwitchChainParamsCoder`)
  for the EIP-3085 shape:
  `[{ chainId, chainName, nativeCurrency: { name, symbol, decimals },
  rpcUrls, blockExplorerUrls, iconUrls? }]`.
- **Validation**:
  - `chainId` is well-formed hex.
  - `rpcUrls` non-empty and well-formed `http(s)`.
  - `nativeCurrency` decimals in a sane range.
  - **If the chain ID already exists**: per EIP-3085, do **not** mutate
    the stored chain. Treat as a no-op (or fall through to a switch).
    Critically — a dapp must never be able to overwrite a built-in
    chain's RPC list; that would let an untrusted dapp redirect mainnet
    RPC traffic.
- **Approval sheet** — new `ApproveAddChainSheet` showing the dapp-
  supplied chain (name, ID, RPC URLs, explorer) so the user sees exactly
  what they're adding. Frame the data as untrusted dapp input.
- **On approve** — write a non-built-in `ChainRecord` via `ChainStore`;
  per spec the flow commonly continues into a chain switch.
- **`RPCRouter`** — move `wallet_addEthereumChain` out of the
  4200-unsupported set; **`EthereumBridge`** gains `handleAddChain`.
- The chain a dapp adds is an ordinary custom chain afterwards —
  editable and deletable in Settings → RPC like any other.

### Phase 6 — User-managed ERC-20 tokens

Lets the user add ERC-20s to any chain (custom chains in particular,
which Phase 1 leaves with only their native asset).

- **`@Model TokenRecord`** — `chainID`, `address`, `symbol`, `name`,
  `decimals`. Registered in the `ModelContainer` schema. Persists
  user-added tokens; built-in ERC-20s stay in `TokenRegistry.builtins`.
- **`TokenRegistry.tokens(for:)`** merges `[native]` + built-in ERC-20s
  + the chain's `TokenRecord`s.
- **Add-token UI** — per-chain (under the chain detail page or the asset
  picker): the user pastes a contract address; fetch `symbol()`,
  `decimals()`, `name()` on-chain via `WalletRPC.callJSON` `eth_call`
  against that chain.
- **Validation** — valid address; not already known (builtin or user);
  the `eth_call`s actually return ERC-20-shaped data (reject EOAs /
  non-token contracts); graceful failure when the chain is unreachable.
- **Logos** — custom tokens have no bundled asset. `Token.logoAsset` is
  already optional; `TokenLogo` needs a placeholder/monogram fallback.
- **Remove token** — swipe-to-delete, user-added tokens only; built-ins
  are not removable.

## 11. Other follow-ups (minor)

- **Remove `SettingsStore.ensPublicRpcProviders`** — once the chain store
  is proven in production, delete the now-unused key. Keep
  `SettingsStore.defaultPublicRpcProviders` (it's the mainnet seed
  source).
- **Swarm's pinned Gnosis RPC** — `SwarmFunderConstants.pinnedGnosisRPC`
  stays independent of `ChainStore` by design; no change planned.

## 12. Delivery cadence

Same as the Colibri workstream: implement a phase → user smoke-tests →
`/simplify` → commit → next phase. Phase 1 lands behind no UI change, so
it is verified via the existing test suite plus a manual ENS + wallet
smoke before Phase 2 begins.
