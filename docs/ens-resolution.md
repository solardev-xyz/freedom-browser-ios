# ENS Resolution (M4)

How the iOS Freedom Browser resolves `vitalik.eth` / `ens://foo.eth` / `https://foo.eth` into a navigable `bzz://<content-hash>` URL without letting a single malicious public RPC silently redirect the user.

The algorithm is a faithful Swift port of the desktop browser's `src/main/ens-resolver.js` → `consensusResolve()` path. This document captures the iOS-specific engineering decisions; the *why* of the algorithm itself lives at `/Users/florian/Git/freedom-dev/freedom-browser/research/ens-consensus-resolution.md` in the desktop repo and should be read alongside this one.

## Threat model (one-paragraph summary)

A user types `foo.eth`. Without cross-checking, we'd ask one public Ethereum RPC "what contenthash does `foo.eth` resolve to?", trust the answer, and load whatever `bzz://<hash>` it names. A single compromised or malicious public RPC in the default list could silently redirect any ENS name to attacker-chosen content. **We prevent this by requiring M-of-K public RPCs to return byte-identical Universal Resolver responses at a shared, corroborated block hash before any URL is loaded.** K=3, M=2 by default, configurable. In-scope: one lying RPC, flaky/timing-out RPCs, stale or forged block anchors. Out of scope: attacker-majority of the provider pool (K-of-M breaks structurally in that case — user must add their own provider or run a node). Users who configure their own RPC opt into single-source trust explicitly; users on the default pool get the quorum treatment.

## Pipeline

The code lives in a handful of files under `Freedom/Freedom/`. Call order, top-down:

```
ENSResolver.resolveContent("foo.eth")          // the public entry
 → ENSIP15.ensNormalized()                     // adraffy/ENSNormalize port
 → ENSNameEncoding.dnsEncode + .namehash
 → ENSResolver.consensusResolve(...)
      ├─ degraded?  → resolveSingleSource(url) // unverified trust label
      │      ↓
      │    QuorumLeg.run(url, ...)             // one UR.resolve() eth_call
      │
      ├─ AnchorCorroboration.getPinnedBlock    // median head + plurality-majority hash
      │     ↓ throws on disagreement (security signal)
      │     ↓ returns nil on infeasibility (degrade to single-source)
      │
      └─ QuorumWave.run(providers, ...)        // K parallel legs, M-of-K agreement
            ↓ second-wave escalation on all-errored
            ↓
         ContenthashDecoder.unwrapABIBytes + .decode
            ↓
         ENSResolvedContent { uri: bzz://<hash>, codec: .bzz, trust: ENSTrust }
```

`BrowserTab.resolveAndLoad` wraps this, interpreting the outcome against the user's `blockUnverifiedEns` setting and setting `pendingGate` for the UI to render an interstitial when appropriate.

## Layers

### Normalization — `ENSNameEncoding.swift` + `adraffy/ENSNormalize.swift`

Full ENSIP-15 (Unicode + emoji labels). We use `adraffy/ENSNormalize.swift`, the first-party Swift port of `@adraffy/ens-normalize.js` by the same author (Andrew Raffensperger). Pinned to a commit SHA. The Unicode tables (~MB of data) are warmed on a detached task at app launch so the first address-bar ENS navigation doesn't pay the deserialization cost on the main actor.

`dnsEncode` produces the length-prefixed wire format the Universal Resolver requires (`"foo.com"` → `03 f o o 03 c o m 00`). `namehash` is ENSIP-1 recursive keccak256. Neither utility is publicly exposed by `web3.swift`, so both are reimplemented — small, self-contained.

### RPC pool + quarantine — `EthereumRPCPool.swift`

Shuffles the user's (or default) provider list once per settings change; tracks per-URL failures with exponential backoff (60s × 2^failures, capped at 10min). When a provider is removed from settings it drops out of quarantine too (so re-adding gives it a fresh chance). `availableProviders()` returns the shuffled, non-quarantined list.

### Transport — `RPCSession.swift` + `QuorumLeg.swift`

A dedicated `URLSession` (not `.shared`) so our per-request timeouts actually bite — `URLSession.shared` silently raises short request timeouts to the 60s session default. Timeout is enforced via Task-group race (`Task.sleep` vs the HTTP call, first-wins, loser cancelled) rather than relying on URLRequest/URLSession timeout semantics, which vary by iOS version.

`QuorumLeg.run(url, ...)` is one `eth_call` at a pinned `blockHash` (EIP-1898). Because `web3.swift`'s `EthereumBlock` enum doesn't surface EIP-1898, we issue the JSON-RPC POST directly. `web3.swift` still does the ABI encode/decode and provides keccak256. Leg outcomes classify into `.data`, `.notFound(.noResolver)`, `.notFound(.noContenthash)`, or `.error`. **`.noResolver` (the UR custom error for "name isn't registered") and `.noContenthash` (any other resolver revert — typically a CCIP gateway failure) bucket separately** — otherwise a transient CCIP failure could combine with a real registration miss to forge a "verified not-found" verdict.

### Anchor corroboration — `AnchorCorroboration.swift`

Before the quorum wave runs, we need every leg to query at the same block hash. Honest providers at slightly different chain heights would otherwise return legitimately different ENS data and produce false conflicts. **Two-phase**:

1. **Head probe across the full pool** (not just K). Every available provider is asked for its head. Median of ≥3 responses — tolerates one outlier on either side. Fewer than 3 responses → caller degrades to single-source unverified (no false "verified" badge).
2. **Hash quorum at `median − safetyDepth`.** The head-responders are asked for the block hash at the target number. **Plurality winner must also clear strict majority** (`> ⌊total/2⌋`), not just the user's M. Plurality alone would let two colluding providers satisfy `M=2` against a larger honest bucket that happened to disagree with itself — attacker-plurality is in scope even though attacker-majority isn't. Genuine disagreement throws `AnchorError.hashDisagreement`, which propagates up to `ENSResolutionError.anchorDisagreement` and surfaces as the `.anchorDisagreement` interstitial. Not cached longer than 10s.

Safety depths: `.latest` → 8 blocks (~1.5min), `.latestMinus32` → 32 blocks (~6.5min), `.finalized` → 0 (chain-consensus finalized). Anchor choice is configurable via `SettingsStore.ensBlockAnchor`. Pinned block cached per `ensBlockAnchorTtlMs` (default 30s).

### Quorum wave — `QuorumWave.swift`

K parallel `UR.resolve()` legs at the pinned block. Each successful response buckets by `resolvedData` bytes; each `.notFound` by reason. **Early-resolve on M agreement**: as soon as any bucket reaches M, the remaining tasks are cancelled and the outcome is tagged as `.verified` (trust tier). If no bucket reaches M:
- `≥1 semantic responses in a single kind` but below M → `.unverified` data/notFound (only one provider answered meaningfully)
- `≥2 semantic responses across distinct buckets` → `.conflict` (real disagreement)
- `0 semantic responses` → `.allErrored`

Second-wave escalation fires **only on `.allErrored`** — conflict and unverified mean honest providers already gave us answers and retrying wouldn't flip the verdict. The second wave runs against whatever pool members weren't in the first selection.

### Contenthash decode — `ContenthashDecoder.swift` + `Base58.swift`

The UR returns `bytes` from the resolver's `contenthash(bytes32)` call, wrapped in one more ABI `bytes` layer. We unwrap it via `ABIDecoder.decodeData`, then parse the EIP-1577 codec prefix:

- `e40101fa011b20 + 32 bytes` → `bzz://<hex>` (Swarm)
- `e3010170 + multihash` → `ipfs://<CIDv0>` (IPFS; base58-encoded multihash, produces `"Qm…"`)
- `e5010172 + multihash` → `ipns://<CIDv0>` (IPNS)

Everything else is `unsupportedCodec`. Only `bzz://` content actually loads; `ipfs://` and `ipns://` decode correctly but navigation surfaces an "IPFS/IPNS not yet supported on iOS" message. `Base58.swift` is a ~30-line Bitcoin-alphabet encoder, hand-rolled because no dependency in our tree provides it.

### Caching — inside `ENSResolver`

`resolveContent` caches outcomes per normalized name with trust-tier TTLs:

| outcome                                      | TTL           |
|----------------------------------------------|---------------|
| success, `.verified` / `.userConfigured`    | 15 minutes    |
| success, `.unverified`                       | 60 seconds    |
| `.notFound(.verified)`                       | 15 minutes    |
| `.notFound(.unverified)`                     | 60 seconds    |
| `.conflict`, `.anchorDisagreement`           | 10 seconds    |
| transient upstream failure (allErrored, etc) | not cached    |

Capped at 500 entries (matches desktop); on overflow, expired entries evict first. In-flight dedup: concurrent `resolveContent` calls for the same name share one underlying consensus pass via a `[String: Task<CachedOutcome, Never>]` map.

## Settings ↔ resolver

All runtime configuration lives in `SettingsStore`, persisted to `UserDefaults`. Keys mirror desktop's `settings-store.js` one-to-one:

| Key                       | Default | Purpose |
|---------------------------|---------|---------|
| `enableEnsCustomRpc`      | false   | Use `ensRpcUrl` as single-source (user-configured trust) |
| `ensRpcUrl`               | ""      | User's own RPC endpoint |
| `enableEnsQuorum`         | true    | Master toggle; off ⇒ single-source unverified |
| `ensQuorumK`              | 3       | Target providers per wave (clamped [2, 9]) |
| `ensQuorumM`              | 2       | Required agreement count |
| `ensQuorumTimeoutMs`      | 5000    | Per-leg timeout |
| `ensBlockAnchor`          | `latest`| `latest` / `latest-32` / `finalized` |
| `ensBlockAnchorTtlMs`     | 30000   | Pinned block cache TTL |
| `ensPublicRpcProviders`   | 9 URLs  | Editable public-RPC pool |
| `blockUnverifiedEns`      | true    | Route unverified outcomes through the interstitial |

Sub-minimum `ensQuorumK` or `ensQuorumM` values route through the single-source unverified path instead of producing a `.verified` badge we can't defend.

Plus one advanced flag not mirrored from desktop:

| Key                | Default | Purpose |
|--------------------|---------|---------|
| `enableCcipRead`   | false   | Follow EIP-3668 OffchainLookup reverts (CCIP-Read). Off by default because it silently relays queries to third-party gateways. |

`SettingsView.swift` is the UI — a Form reached from the ⋯ menu with sections for Custom RPC, Quorum (K/M/timeout/anchor), Public RPC Providers (editable list), Safety, and Advanced. Tapping Done calls `ENSResolver.invalidate()` which clears the name cache, cancels in-flight Tasks, and resets both the anchor cache and provider pool — so the next navigation runs against the new config.

## UI surface (M4.8 → M4.11)

- **Address bar input**: `BrowserURL.parse` detects bare `name.eth`, `ens://name.eth` literal, and `https://name.eth` (no DNS `.eth` TLD exists, so routing to ENS is unambiguous).
- **Resolve banner**: "Resolving `name.eth`…" above the progress bar while the consensus pass is in flight.
- **Trust shield** (`TrustShield.swift`): small colored shield icon to the left of the address-bar text field, bound to `tab.currentTrust`. Tap opens a sheet listing agreed / dissented / silent providers + the pinned block.
- **Interstitials** (`ENSInterstitial.swift`): replace the webview area (not overlay) when `tab.pendingGate` is set.
  - `.unverifiedUntrusted` — amber. "Continue once" + "Go back". One-shot bypass, not remembered (cache TTL for unverified is 60s, so a second attempt within the minute re-gates).
  - `.conflict` — red. Lists each `ENSConflictGroup` with its hosts + a short hex preview of the disputed bytes. "Go back" only.
  - `.anchorDisagreement` — red. Shows bucket/threshold counts. "Go back" only.

**History and bookmarks store the `ens://name.eth` form**, not the resolved `bzz://<hash>`. Revisits re-resolve and pick up any content-hash rotation by the ENS record owner. Favicons key on the same form, so a cached favicon survives rotation.

### CCIP-Read (EIP-3668) — `CCIPResolver.swift`

When a resolver reverts with the `OffchainLookup` custom error (selector `0x556f1830`), our existing `QuorumLeg` detects it and, if the user has `enableCcipRead` on, hands off to `CCIPResolver`. The retry loop does the three things EIP-3668 requires:

1. **Parse** the revert into `(address, string[] urls, bytes callData, bytes4 callbackFunction, bytes extraData)`. We go through web3.swift's public `ABIRevertError` / `ABIFunctionEncodable.decode(_:expectedTypes:filteringEmptyEntries:)` API because the library's `OffchainLookup.init?(decoded:)` is internal.
2. **Hop** through each gateway URL in order. `{sender}` and `{data}` are substituted; `{data}` present ⇒ GET, otherwise POST with `{"sender": ..., "data": ...}` body. Per the EIP, **4xx from any gateway terminates the whole lookup** (deterministic client error); **5xx, transport failures, or unparseable bodies fall through to the next gateway**. Response is `{"data": "0x..."}`.
3. **Callback** — re-issue `eth_call` against `callbackFunction(bytes response, bytes extraData)` on `address`, **at the same pinned `blockHash`** that anchor corroboration chose. The return value is the true `(bytes, address)` pair we'd have gotten without CCIP.

A callback may itself revert with `OffchainLookup` (ethers.js compat); recursion is capped at `maxRedirects = 4` so a hostile gateway can't loop us forever. Callback encoding is `callbackFunction (4) || abi.encode(bytes, bytes)` — we use `ABIFunctionEncoder` with a throwaway name and strip its 4-byte method id prefix, since `OffchainLookup.encodeCall(withResponse:)` is internal.

CCIP failures (all gateways unreachable, 4xx, too many redirects, parse error) surface as `CCIPError.*` out of the leg. Each leg then reports `.error(…)` to consensus, which aggregates: if every leg hits the same failure, we get `allErrored` and the user sees the standard all-providers-failed banner; if a subset succeed with `.data(…)`, that bucket can still reach M. We deliberately do not bucket CCIP failures as `NO_CONTENTHASH` — that would falsely pin a verified not-found when the gateway is merely broken.

## What's deliberately not in M4

- **Reverse resolution** (`addr` → `name`). Lands with the wallet.
- **Speculative gateway prefetch**. Desktop does it; it's a latency optimization, not a trust property. Skipped.
- **Persistent resolution cache**. Desktop is in-memory only; we match.
- **Operator diversity indicator**. The default 9 providers are distinct URLs but some may proxy the same backend (Alchemy, Infura). Users concerned about this edit the list manually or set their own RPC.

## File map

```
Freedom/Freedom/
├── ENSResolver.swift              — public entry, cache, in-flight dedup, consensusResolve orchestrator
├── ENSNameEncoding.swift          — dnsEncode + namehash
├── ENSResult.swift                — ENSResolvedContent, ENSResolutionError, ENSConflictGroup
├── ENSTrust.swift                 — ENSTrust, ENSTrustLevel, ENSBlock
├── AnchorCorroboration.swift      — getPinnedBlock (head+hash), EthereumHeadFetcher defaults
├── QuorumWave.swift               — runConsensusWave, TrustTier, Resolution
├── QuorumLeg.swift                — single UR.resolve at a pinned blockHash, JSON-RPC transport
├── ContenthashDecoder.swift       — ABI unwrap + codec dispatch (bzz/ipfs/ipns)
├── Base58.swift                   — encoder for multihash → CIDv0
├── CCIPResolver.swift             — EIP-3668 gateway hop + callback eth_call
├── RPCSession.swift               — shared URLSession, generic Response<R>, withTimeout
├── EthereumRPCPool.swift          — shuffle + quarantine
├── SettingsStore.swift            — the 10 ENS keys, UserDefaults-backed
├── TrustShield.swift              — address-bar shield icon + details sheet
└── ENSInterstitial.swift          — full-webArea gates

Freedom/FreedomTests/
├── ConsensusResolveTests.swift    — orchestrator: degraded paths, second-wave escalation, conflict
├── AnchorCorroborationTests.swift — median, plurality+majority, cache, infeasibility, partial failure
├── QuorumWaveTests.swift          — bucket isolation, early resolve shapes, conflict variants
├── EthereumRPCPoolTests.swift     — shuffle + quarantine + orphan cleanup
├── ContenthashDecoderTests.swift  — codec coverage + Base58 vector
├── CCIPResolverTests.swift        — OffchainLookup round-trip, gateway fallback, redirect cap
├── ENSResolverTests.swift         — resolveContent end-to-end, cache, dedup, error mapping
└── BrowserURLTests.swift          — parse rules (bare .eth, ens://, .eth redirect, case)
```

92 tests. Every security-critical invariant has a test.
