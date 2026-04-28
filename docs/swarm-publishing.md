# Swarm Publishing Architecture (M6 — draft)

A sketch of the Swarm publishing surface for the iOS Freedom Browser: identity injection from the user's BIP-39 seed into the embedded Bee node, ultralight↔light upgrade, postage-stamp purchase + management, and the `window.swarm` provider for dapps. Parallel in spirit to the desktop browser's publishing surface (`/Users/florian/Git/freedom-dev/freedom-browser/src/main/swarm/` + `src/main/identity/`) but native throughout — no bee-js port, no Electron IPC, no JS-side key handling. This document is a starting point to iterate on, not a committed plan.

> **Status (2026-04-28)**: WP1 (identity injection), WP2 (light-mode upgrade + one-tx funding), WP3 (stamp management) shipped on `feature/swarm-publishing`, plus the chequebook auto-top-up follow-on. WP4–6 (`window.swarm` bridge) not started. Several deviations from the original plan along the way — module layout (§4), readiness state model (§6.5), and the buy state machine (§7.3) all simplified during implementation. See §9 for the actual commit trail.

> **Reading order**: read after [`wallet-architecture.md`](./wallet-architecture.md) — this assumes the BIP-39 vault, HD-derivation, and approval-sheet patterns from M5 are already in your head, and reuses them throughout. Cross-reference [`architecture.md`](./architecture.md) §3-5 for the SwarmKit / bee-lite-java pipeline (the embedded Bee node is the substrate every section here builds on). The desktop browser is the reference implementation — the SWIP draft `/Users/florian/Git/freedom-dev/SWIPs/SWIPs/swip-draft_provider_api.md` is the wire-format spec.

## 1. What publishing needs to do

Three audiences, same engine:

1. **The embedded Bee node** — must boot with a private key the user controls (so the node's xBZZ balance, chequebook, and on-chain identity all derive from the user's BIP-39 seed and survive device replacement).
2. **The user** — sees and manages the Bee wallet's xDAI/xBZZ balances, upgrades from ultralight to light when ready to publish, buys and tops up postage stamps.
3. **Dapps loaded in a BrowserTab's WKWebView** — see a `window.swarm` provider following the SWIP-draft method surface, route `swarm_requestAccess` / `swarm_publishData` / `swarm_publishFiles` / `swarm_createFeed` / `swarm_writeFeedEntry` / `swarm_readFeedEntry` etc. through it.

### 1.1 Scope vs. desktop parity

What desktop (`freedom-browser`) ships today and we port here:

- Single-mnemonic identity for the Bee node, derived at the same BIP-44 slot (`m/44'/60'/0'/0/1`) so a user's mnemonic produces the same Swarm overlay address on iOS and desktop.
- Per-origin Swarm publisher keys at `m/44'/73406'/{originIndex}'/0/0` (secp256k1, dedicated namespace, never funded).
- Ethereum V3 keystore JSON at `{beeDataDir}/keys/swarm.key`, decrypted by Bee on boot.
- Stamp UI (list, buy, extend duration, extend size) talking to the Bee HTTP API.
- The 10-method `window.swarm` surface, two-tier permission model (connection grant + per-origin feed grant), per-origin auto-approve toggles for publish + feed writes.
- Light-mode readiness classification + funding gate.

**v1 iOS-specific divergences**:

- **One-tx funding via `SwarmNodeFunder`** for the ultralight→light upgrade, replacing desktop's 5-step manual checklist (xDAI → CowSwap xDAI→xBZZ → xBZZ to node). Single transaction from the main wallet does it all on Gnosis: swap via UniswapV3 BZZ/WXDAI 0.3% pool + forward xDAI for chequebook gas + forward xBZZ to the Bee wallet. Contract at `0x508994B55C53E84d2d600A55da05f751aEf658d2` (deployed 2026-04-24, verified on Blockscout). This is the meaningful improvement over desktop's flow and the user-facing reason to upgrade *here* rather than wait for the next desktop release.
- The funding gate itself stays mandatory — a Bee node without funding can't connect to peers in light mode (Bee's design, not ours). Users physically *cannot* skip funding; we just shrink it from 5 steps + 3 signatures to 1 step + 1 signature.
- Stamp purchase stays in the Bee API for v1 (the funder contract has a stamp-purchase tuple in `fundNodeAndBuyStamp` but the renderer passes `depth=0` to skip — keeps stamp-buy logic uniform with the existing stamp-extension flows that go through Bee anyway).

**Out of scope for v1**:

- Radicle / IPFS identity surfaces (desktop reserves `m/44'/73404'` and `m/44'/73405'` but we don't expose them — iOS has no Radicle/IPFS node).
- ACT (Access Control Trie) encrypted publishing — bee-lite supports it, our wrapper doesn't expose it yet.
- Manual stamp-batch selection on publish (we always pick the best-fitting usable batch automatically — same as desktop).
- A "dilute" UX surface (technically separate from "extend size" in Bee's API, but the bee-js wrapper conflates them and so do we; depth grows as needed during extend-size).
- Non-Gnosis chequebook chains — light mode is Gnosis-only.

What v1 **does** share with desktop: the keystore format (V3 JSON, scrypt + AES-128-CTR), the per-origin publisher namespace, the SWIP-draft wire format bit-for-bit, the topic-derivation hash, and the auto-approve permission shape. A user with the same mnemonic on iOS and desktop sees the same overlay address, the same publisher key per origin, and can read/write the same feeds.

## 2. Threat model

We guard against:

- **Bee-key impersonation across devices**: the Bee wallet private key is derived in-process from the user's BIP-39 seed (which lives behind the same biometric/Keychain gate as the main user wallet — see wallet-architecture.md §5). The keystore file on disk is encrypted with a random 32-byte password held in Keychain `.whenUnlockedThisDeviceOnly`. An attacker with the keystore file alone cannot decrypt it without device + biometric.
- **Key-swap state drift**: when the Bee key changes (vault create / wipe / new mnemonic import), Bee's overlay address derivation changes — but auxiliary state (`statestore`, `localstore`, `keys/libp2p_v2.key`, etc.) was tied to the old key. We *must* wipe this state on key swap; skipping it produces a node that boots with new identity but stale routing/peer state, which Bee handles by silently failing to gossip. §5.4 handles this explicitly.
- **Cross-origin tag snooping**: dapps creating uploads receive a `tagUid` they can poll for progress. Tag UIDs are sequentially-assigned integers in Bee — without scoping, origin A could guess origin B's tag IDs and snoop on B's upload progress. We hold a session-scoped `[tagUid: origin]` map and reject `swarm_getUploadStatus` calls where the requesting origin doesn't match the tag's owner. Map is in-memory only — not persisted across app launches.
- **Cross-origin feed forgery**: feed topics are derived as `keccak256(normalizedOrigin + "/" + feedName)` — origin A can never write to a feed under origin B's namespace because the topic incorporates the (normalized, address-bar-derived) origin. The feed signing key is also separate per origin (when in `app-scoped` identity mode), so even if origin A guessed origin B's topic, A's signatures wouldn't verify under B's owner address.
- **Origin spoofing for publish/feed grants**: same rule as the Ethereum bridge — permissions bind to the address-bar identity (e.g. `ens://foo.eth`), not the resolved bzz hash. A Swarm-content-hash rotation cannot silently transfer a publish grant to new content under a name the user trusted.
- **Stamp-batch drain by malicious dapps**: every `swarm_publishData` / `swarm_publishFiles` requires either a foregrounded approval **or** a pre-existing per-origin auto-approve toggle. Auto-approve is opt-in per origin and never the default. A dapp cannot silently mint chunks against the user's stamp.
- **Funding-tx phishing on light-mode upgrade**: the `SwarmNodeFunder` contract address is hardcoded in-app (not user-configurable, not dapp-supplied). The upgrade tx signs through the same `eth_sendTransaction` approval sheet pattern as any other send — the user sees `to: 0x508994…`, the resolved label "Fund Bee node (one-tx)", and the xDAI amount. It's a normal Ethereum send from the user's perspective; the contract is just the destination.
- **Replay across mnemonics on re-import**: re-importing the *same* mnemonic must not wipe state (no key changed). We compare derived bee address against current `walletAddress` before deciding to wipe. §5.6.

Out of scope:

- A compromised SwarmNodeFunder contract. The contract is admin-less and stateless (per the contributor's PR notes); we treat it as a vetted constant. If a future audit finds an issue, we ship a new address in a point release.
- Front-running / MEV on the funder swap. The user picks the xDAI amount they're committing; UniswapV3's slippage is bounded by the pool's geometry. For ~$2K TVL and small per-user funding amounts (sub-$10 typically), this is acceptable.
- A malicious local Bee node. The Bee node runs in-process under our control; if it's compromised, the whole app is.

## 3. Library posture

**Bee is talked to over HTTP**, not via a Swift-port of bee-js. Reasons:

1. The Bee node already exposes a full HTTP API on `127.0.0.1:1633` (see `architecture.md` §5 — `BzzSchemeHandler` already proxies through it). Talking HTTP is simpler than wrapping the Go binding for every endpoint we need.
2. bee-js (`@ethersphere/bee-js`) is ~10k LoC of TypeScript. Porting it is not in scope; reusing the parts we need would require running JS, which we don't have a runtime for outside WKWebView.
3. The HTTP surface is small and stable: ~6 endpoints for stamps, 2 for uploads, 4 for feeds. We hand-roll a thin `BeeAPIClient`.

**No Multicall, no batching libraries.** Same posture as the wallet RPC — we keep things simple and explicit.

**Crypto we already have**: `secp256k1` (from the wallet target — for publisher-key signing), `CryptoKit` (for SHA-256 / HMAC), `web3.swift`'s `.web3.keccak256` (for the keystore MAC), `CommonCrypto`'s `CCCryptorCreateWithMode + kCCModeCTR` (for AES-128-CTR keystore-body cipher — Apple primitive, no new dep). All vetted. None hand-rolled.

**Crypto we add**: `CryptoSwift` (`https://github.com/krzyzanowskim/CryptoSwift`, MIT, ~9k stars, since 2014) for **scrypt**. Scrypt is the V3 keystore KDF that Bee mandates — `bee/v2@v2.7.0/pkg/keystore/file/key.go:211` rejects every other KDF. Apple ships nothing for scrypt (`CryptoKit`, `swift-crypto`, `CommonCrypto` all lack it). CryptoSwift exposes `Scrypt(password:salt:dkLen:N:r:p:)` as a first-class API. Adds ~600KB-1MB to binary; acceptable given the 304MB embedded Bee node already in the app. We use only the `Scrypt` type from CryptoSwift; everything else (AES, ChaCha, BLAKE) is dead weight on our side but standard with SPM whole-library imports. Argent's `web3.swift` already vendors a private subset of CryptoSwift (`Internal_CryptoSwift_PBDKF2`) for its PBKDF2 fallback path — they trust the project; we follow.

**The SwarmKit Swift package stays exactly as it is.** We don't touch its `Package.swift` or its `MobileMobileNodeOptions` surface. We drive identity by writing files into `dataDir` *before* calling `SwarmNode.start(_:)`, and we drive light/ultralight by setting `SwarmConfig.rpcEndpoint`. No new gomobile bindings needed.

**What we build in-repo**: V3 keystore encoder (~80 LoC of plumbing — `CryptoSwift.Scrypt` + `CommonCrypto` AES-CTR + `web3.swift` keccak + `JSONEncoder`; we do not implement any primitive ourselves), Bee state-dir wiper, `BeeAPIClient`, `StampService`, `SwarmBridge` + preload script, `SwarmRouter`, `SwarmPermissionStore` (SwiftData), `SwarmFeedStore` (SwiftData), `SwarmPublishService`, `SwarmFeedService`, the `SwarmNodeFunder` ABI binding (one method, hand-encoded — no new ABI tooling). All mechanical, all small, threat model matches line-for-line.

## 4. Module layout

Actual shape (post-WP3) alongside the existing `Wallet/` tree under `Freedom/Freedom/`. `✅` = shipped; `🚧` = deferred / future WP; unmarked = WP4–6 planned.

```
Freedom/
├── Wallet/                              ✅ (M5, see wallet-architecture.md)
│   ├── Vault/HDKey.swift                ✅ publisherKey(originIndex:) deferred to WP6
│   └── Transactions/TransactionService.swift
│                                        ✅ Used as-is by funder via direct
│                                            (to, value, data) tuple — no
│                                            buildFundNode helper needed.
└── Swarm/                               ── new tree at M6
    ├── Identity/
    │   ├── BeeKeystore.swift            ✅ V3 JSON encoder (scrypt + AES-128-CTR)
    │   ├── BeeIdentityInjector.swift    ✅ inject / revertToAnonymous / restartForMode
    │   ├── BeeIdentityCoordinator.swift ✅ in-flight swap state machine + switchMode
    │   │                                    (orchestration that the original plan
    │   │                                    placed in BeeNodeController)
    │   ├── BeeStateDirs.swift           ✅ filesystem layout + wipe rules
    │   ├── BeePassword.swift            ✅ random 32-byte hex, Keychain-backed
    │   └── BeeBootConfig.swift          ✅ password+mode → SwarmConfig builder
    ├── Node/
    │   ├── BeeNodeMode.swift            ✅ .ultraLight | .light enum
    │   ├── BeeReadiness.swift           ✅ /chainstate-driven, see §6.5
    │   └── BeeWalletInfo.swift          ✅ polls /wallet + /chequebook/balance
    │                                       (replaces the planned BeeWalletCard
    │                                       service-side; UI lives in NodeHomeView)
    ├── Funder/
    │   ├── SwarmFunderConstants.swift   ✅ pinned addresses, decimals, slippage
    │   ├── SwarmFunderQuote.swift       ✅ spot from sqrtPriceX96, expected/min BZZ
    │   ├── SwarmFunderPool.swift        ✅ slot0() reader via WalletRPC
    │   └── FundNodeBuilder.swift        ✅ hand-rolled ABI encoder for
    │                                       fundNodeAndBuyStamp (selector 0x834aeb80)
    ├── API/
    │   └── BeeAPIClient.swift           ✅ URLSession wrapper. GET + POST (with
    │                                       optional query params for endpoints
    │                                       like /chequebook/deposit?amount=…).
    │                                       BeeError shaped as a typed enum inside
    │                                       this file rather than a separate file.
    ├── Stamps/
    │   ├── StampService.swift           ✅ list/buy + chequebook auto-top-up
    │   │                                    (see §7.5). State machine in §7.3.
    │   ├── PostageBatch.swift           ✅ normalized model
    │   ├── StampMath.swift              ✅ depth/amount/cost — replicates bee-js's
    │   │                                    getDepthForSize + getAmountForDuration
    │   │                                    (bee has no /stamps/cost endpoint
    │   │                                    despite the original §7.3 plan)
    │   └── StampUSDPricing.swift        🚧 deferred (UI shows xBZZ only)
    ├── Bridge/                          (WP4)
    │   ├── SwarmBridge.swift            WKScriptMessageHandler, parallel to EthereumBridge
    │   ├── SwarmBridge.js               preload script, injects window.swarm
    │   ├── SwarmRouter.swift            10-method dispatch, parallel to RPCRouter
    │   └── SwarmErrorPayload.swift      4001 / 4100 / 4200 / 4900 / -32602 / -32603
    ├── Permissions/                     (WP4 / WP6)
    │   ├── SwarmPermission.swift        @Model: origin, autoApprovePublish, autoApproveFeeds
    │   ├── SwarmPermissionStore.swift   parallel to PermissionStore
    │   ├── SwarmFeedRecord.swift        @Model: origin, name, topic, owner, manifestRef, ...
    │   └── SwarmFeedStore.swift         @Query-friendly access
    ├── Publish/                         (WP5)
    │   ├── SwarmPublishService.swift    bee.uploadFile / uploadFiles
    │   └── TagOwnership.swift           session-scoped [tagUid: origin]
    ├── Feeds/                           (WP6)
    │   ├── SwarmFeedService.swift       create/update/write/read with per-topic actor
    │   ├── FeedTopic.swift              keccak256(origin + "/" + name)
    │   └── PublisherKeyAllocator.swift  manages nextPublisherKeyIndex
    └── UI/
        ├── NodeHomeView.swift           ✅ status + node wallet + chequebook
        │                                    + stamps row + log link. Hosts the
        │                                    inline mode toggle that the original
        │                                    plan called NodeModeView.
        ├── NodeLogView.swift            ✅ separate diagnostic surface
        ├── PublishSetupView.swift       ✅ 4-step checklist (fund → sync →
        │                                    chequebook deployed → buy stamp).
        │                                    Hosts the funder UI inline that the
        │                                    original plan split into FundNodeFlow
        │                                    + FundNodeReviewView.
        ├── PublishStepRow.swift         ✅ checklist row component
        ├── StampsView.swift             ✅ list + empty state
        ├── StampPurchaseView.swift      ✅ preset chips + cost + buy
        ├── StampExtendView.swift        🚧 deferred — extend duration / size
        ├── SwarmConnectSheet.swift      (WP4)
        ├── SwarmPublishSheet.swift      (WP5)
        └── SwarmFeedAccessSheet.swift   (WP6)
```

Nothing here imports anything outside `Wallet/` and `SwarmKit` except what's already in `architecture.md`'s graph.

## 5. Identity injection

### 5.1 Derivation paths

Add to `HDKey.Path` (matching desktop's `derivation.js` exactly):

| Purpose | Path | v1 status |
|---|---|---|
| Main user wallet | `m/44'/60'/0'/0/0` | ✅ shipped (M5.1) |
| **Bee wallet (node)** | `m/44'/60'/0'/0/1` | ✅ slot reserved (M5.1); **surfaced at M6/WP1** |
| **Swarm publisher (per origin)** | `m/44'/73406'/{originIndex}'/0/0` | new at M6/WP1 |
| Additional user wallets | `m/44'/60'/{i}'/0/0`, `i ≥ 1` | reserved (multi-account, future) |

Naming: we keep "Bee wallet" (matches desktop `derivation.js:23` and existing iOS `HDKey.Path.beeWallet:117`), not "Swarm node identity". One name, one slot, two platforms.

Publisher keys are dedicated secp256k1 — separate namespace from `60'` so they're cryptographically isolated from the user's funded wallet (a publisher key compromise can't drain the user wallet, and vice versa). The `73406` coin type is in the unregistered range; desktop picked it at `derivation.js:32` and we adopt it verbatim.

`HDKey.Path` factory:

```swift
extension HDKey.Path {
    /// Bee node wallet. Surfaced at M6 — the Bee node's keystore is
    /// derived from this slot.
    static let beeWallet = try! Path(rawPath: "m/44'/60'/0'/0/1")  // already exists

    /// Per-origin Swarm publisher key for feed signing. `originIndex`
    /// is allocated sequentially by `PublisherKeyAllocator` and held in
    /// `SwarmFeedStore.nextPublisherKeyIndex`.
    static func publisherKey(originIndex: Int) -> Path {
        precondition(originIndex >= 0 && originIndex < 0x8000_0000)
        return try! Path(rawPath: "m/44'/73406'/\(originIndex)'/0/0")
    }
}
```

### 5.2 Keystore format (V3 JSON)

Bee reads the keystore at `{beeDataDir}/keys/swarm.key` as the **Ethereum V3 keystore JSON** ([Web3 Secret Storage Definition](https://github.com/ethereum/wiki/wiki/Web3-Secret-Storage-Definition)) with **scrypt** as the mandatory KDF. Bee's Go decoder hard-rejects any other KDF (`bee/v2@v2.7.0/pkg/keystore/file/key.go:211`: `if v.KDF != keyHeaderKDF { return ... unsupported KDF }`, `keyHeaderKDF = "scrypt"`). Same format `ethers.Wallet.encrypt(privateKey, password)` produces with default options. Fields:

```json
{
  "version": 3,
  "id": "<random uuid v4>",
  "address": "<20-byte hex, no 0x>",
  "crypto": {
    "ciphertext": "<aes-128-ctr ciphertext, hex>",
    "cipherparams": { "iv": "<16-byte hex>" },
    "cipher": "aes-128-ctr",
    "kdf": "scrypt",
    "kdfparams": {
      "dklen": 32,
      "salt": "<32-byte hex>",
      "n": 32768, "r": 8, "p": 1
    },
    "mac": "<keccak256(derivedKey[16:32] ++ ciphertext), hex>"
  }
}
```

Encoder lives in `BeeKeystore.swift` — pure plumbing, ~80 LoC. The KDF call is `CryptoSwift.Scrypt(password: ..., salt: ..., dkLen: 32, N: 32768, r: 8, p: 1).calculate()`; the cipher is AES-128-CTR (`CommonCrypto`) with the first 16 bytes of the scrypt-derived key; the MAC is `web3.swift`'s keccak256 over `derivedKey[16..32] ++ ciphertext`; the random IV / salt / UUID come from `Data+SecureRandom`. We write **compact JSON** (no whitespace) for stable byte output across re-encodes.

Bee's MAC verifier accepts both keccak256 and SHA3-256 (`key.go:176-186` — the keccak path is explicitly there as "loading an ethereum V3 keyfile"). We use keccak256 to match `ethers.Wallet.encrypt`'s output; either would work, no functional difference for our integration test.

Cross-platform parity at WP1 is at the **derivation level**, not the keystore-format level: a given mnemonic must produce the same `m/44'/60'/0'/0/1` private key on iOS and desktop, which is a property of `HDKey.swift`'s BIP-32 implementation (already covered by `HDKeyTests.swift`). The keystore wrapper is local to each platform's encoder; the file Bee writes after our injection is byte-different from the file desktop produces (different salt / iv / uuid every encode), but Bee accepts both because the V3 spec allows arbitrary `n/r/p/salt/iv` per file. The load-bearing test is **"encrypt with our code, decrypt with Bee's Go scrypt path"** — round-trip against the actual Bee binary, asserting the recovered private key matches our input. Test fixtures committed under `FreedomTests/Fixtures/`.

### 5.3 Bee password

Random per-install, 32 bytes, hex-encoded — matches desktop's "defense in depth" posture. Storage:

- Keychain item, key `swarm.bee.keystore-password`
- Protection: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (this-device-only — the Bee password is regenerable; we'd rather not sync it)
- Generated lazily on first identity injection; cached in-memory after for the app session

`BeePassword.swift`:

```swift
enum BeePassword {
    static func loadOrCreate() throws -> String { ... }
    static func wipe() throws { ... }   // called on vault wipe
}
```

This **replaces** the hardcoded `"freedom-default"` password at `FreedomApp.swift:102` (the existing `TODO: Keychain in M4` comment). Removing the hardcode is part of WP1.

### 5.4 State cleanup on key swap

On any of these events, the Bee node's auxiliary state must be wiped before restart:

- Vault create (first wallet, replaces the implicit anonymous Bee identity).
- Vault wipe (back to anonymous default — wipe everything).
- Vault import where the derived Bee address differs from the current `walletAddress` (§5.6).

Directories/files to remove inside `{beeDataDir}` (matches desktop `identity-manager.js:412-429`):

```
statestore/
localstore/
kademlia-metrics/
stamperstore/
keys/libp2p_v2.key
keys/pss.key
```

We **keep** the `bee-data/` parent directory, the `config.yaml` if any, and any other future config files. The `swarm.key` keystore is rewritten in step 1 of injection, not deleted then re-created.

`BeeStateDirs.wipe()` is the single function that does this. It's idempotent (paths that don't exist are silently skipped).

### 5.4.1 In-process restart and bee's leveldb LOCK (added during WP2 smoke)

Stopping bee with `MobileStopNode` and immediately restarting it on the same `dataDir` initially failed with `init state store: resource temporarily unavailable` (the leveldb LOCK fcntl from the prior bee was still held). Two underlying bee bugs surfaced in sequence:

1. `pkg/storage/cache/cache.go::Close()` purged the in-memory cache but never closed the wrapped LevelDB store.
2. After fixing (1), the same shape was hit on Kademlia's metrics `shed.DB`, which `Kad.Close()` flushed but didn't close.

Both were patched in [`flotob/bee@v2.7.0-freedom.2`](https://github.com/flotob/bee) and re-bundled as [`bee-lite-java@ios-v0.1.2`](https://github.com/solardev-xyz/bee-lite-java/releases/tag/ios-v0.1.2). `Packages/SwarmKit/Package.swift` pins this binary target. The originally-planned retry-with-backoff workaround in `restartForMode` has been removed — `shutdown()` now releases the LOCK synchronously and the next `start()` succeeds immediately.

### 5.5 Restart sequencing

On vault create:

```
1. Derive bee wallet from mnemonic   (HDKey.Path.beeWallet)
2. Load-or-create Bee password       (BeePassword.loadOrCreate)
3. Encode V3 keystore                (BeeKeystore.encrypt)
4. Stop SwarmNode (await .stopped)
5. Wipe stale state                  (BeeStateDirs.wipe)
6. Write keys/swarm.key              (BeeKeystore output)
7. Start SwarmNode with new password (SwarmNode.start(config))
8. Poll status → .running            (existing SwarmNode polling)
```

Steps 4-7 are atomic from the user's perspective: a single overlay covers vault-create completion, and the user lands on the wallet home only after the node is back up. The whole sequence typically takes 2-4 seconds (most of it in Bee's startup).

UX: a "Setting up your Swarm node…" overlay during steps 4-8, with a progress indicator. If step 4 or 7 fails, surface a `VaultFailureView` with retry. We do not roll back the keystore write on Bee start failure — the user can retry, and if it persists, wipe + retry.

`BeeIdentityInjector.swift` orchestrates this. It depends on `SwarmNode` (to stop/start), `BeeKeystore`, `BeeStateDirs`, `BeePassword`, and the vault.

### 5.6 Same-mnemonic re-import optimization

If the user imports the same mnemonic they already have (rare but legal — e.g. recovering from a wipe), the derived Bee address is identical to the current `SwarmNode.walletAddress`. Skip steps 4-7 entirely:

```swift
let derivedAddress = try beeWallet.ethereumAddress
if derivedAddress.lowercased() == swarm.walletAddress.lowercased() {
    return  // no-op, identity unchanged
}
// else: full restart
```

Saves 2-4 seconds + a stale-state wipe that would have been pointless.

## 6. Light-mode upgrade

### 6.1 Mode setting

`BeeNodeMode` enum (`.ultraLight | .light`) persisted in `SettingsStore`. Default `.ultraLight`. Setting maps directly to `SwarmConfig.rpcEndpoint`:

| Mode | `rpcEndpoint` | `swapEnable` | Funded? |
|---|---|---|---|
| ultraLight | `nil` | false | not required |
| light | Gnosis RPC URL | true | required |

The mapping is already in `SwarmNode.swift:183-184` (`o.swapEnable = c.rpcEndpoint != nil`). We just add the mode setting and the upgrade flow.

### 6.2 Gnosis RPC

**Pinned**: we hand bee-lite a single Gnosis RPC URL — hardcoded, not user-configurable. Reuses the same Gnosis RPC list `ChainRegistry` already has for Gnosis chain (gnosis.blockpi.network, etc.) but flattened to one URL bee-lite can use. Bee handles its own retries internally — we don't need to feed it our pool.

If the pinned URL goes flaky, the symptom is "the user's light node has connectivity issues". We can ship a new pinned URL in a point release. Future work: surface this as an advanced setting in RPC settings page (parallel to the existing custom-RPC override for the wallet RPC).

### 6.3 Funding gate

Mandatory. Light mode without funding produces a node that can't pay for chunk retrieval and silently fails — Bee's design, not ours.

**Shipped gate**: `settings.beeNodeMode` itself, plus the publish-setup checklist at `PublishSetupView`. Users in `.ultraLight` see the `publishSetupCTA` banner on the node sheet and can only enter `.light` by going through the funder (step 1 of the checklist). The dual chequebook+xDAI check the original plan called for didn't ship — by the time the user is past step 1's tx confirmation, the chequebook deploy is in flight regardless of any client-side check, so an in-app "is this funded?" probe would just race bee's own state.

The publish-setup banner stays visible until the user has a usable stamp (`StampService.hasUsableStamps == true`) — covers fresh-ultralight, mid-sync, and the light+ready+no-stamps gap, so the setup is "done" only when the user can actually publish.

### 6.4 One-tx funding via SwarmNodeFunder

The contributor's `SwarmNodeFunder` contract at `0x508994B55C53E84d2d600A55da05f751aEf658d2` (Gnosis, deployed 2026-04-24, verified on Blockscout) takes a single tx from the user's main wallet and:

1. Receives xDAI as `msg.value`.
2. Swaps part of it to xBZZ via UniswapV3 BZZ/WXDAI 0.3% pool (`0x7583b9…`).
3. Forwards the chosen xDAI portion to the Bee wallet (for chequebook-deploy gas).
4. Hands the xBZZ to the Bee wallet.
5. Optionally buys a stamp in the same tx (we pass `depth=0` to skip — stamp purchase stays in the Bee API for v1, see §7).

Method (best guess from the user's PR notes — confirm at WP2 implementation time):

```
fundNodeAndBuyStamp(
    address beeWallet,
    uint256 xdaiToForward,    // amount to forward as xDAI
    uint256 xbzzMinOut,       // slippage protection on the swap
    uint8   stampDepth,       // 0 = skip stamp
    uint256 stampAmount       // 0 if depth=0
) external payable
```

We model it as a normal Ethereum send through the existing `TransactionService`:

- `to = 0x508994B55C53E84d2d600A55da05f751aEf658d2`
- `value = totalXdai (the user's chosen funding amount)`
- `data = abi.encode(fundNodeAndBuyStamp(...))` — hand-encoded selector + ABI args, no new tooling
- `chain = .gnosis`

**Shipped path**: `FundNodeBuilder.build(...)` returns a `(to, value, data)` tuple consumed directly by the existing `TransactionService.prepare → send → awaitConfirmation` pipeline — no `buildFundNode` helper on `TransactionService`, no new `ApprovalRequest.Kind.fundBeeNode`. The funder tx uses the standard `eth_sendTransaction` approval sheet; the funding context is communicated via `PublishSetupView`'s checklist + step-1 copy ("One transaction from your main wallet swaps xDAI for xBZZ and forwards a small amount of xDAI…").

After the tx confirms (`PublishSetupView.fundAndUpgrade`):

1. `beeIdentity.switchMode(to: .light, swarm:)` → persists `beeNodeMode = .light` and runs the restart through `BeeIdentityInjector.restartForMode`.
2. The restart blocks (gomobile-bound) for the duration of bee's full init — `swarm.status` flips to `.running` only at the end. `BeeReadiness` polls `/chainstate` during `.starting` to surface the live percent (see §6.5).
3. The publish-setup checklist auto-advances through steps 2 → 3 → 4 as `BeeReadiness.state` and `StampService.hasUsableStamps` change.

UI: the mode toggle lives inline in `NodeHomeView.statusCard.modeRow` (visible once `settings.hasCompletedPublishSetup` is true). The funder flow itself is `PublishSetupView` step 1, not a dedicated `NodeModeView` / `FundNodeReviewView` pair.

### 6.5 Readiness classification

`BeeReadiness` is the single source of truth for "what's the node busy with", driving the status-bar suffix in `ContentView` and the publish-setup checklist progression. The shipped state machine differs materially from the original sketch:

```swift
enum State: Equatable {
    case browsingOnly
    case initializing                     // swarm.status not in {.starting, .running}
    case startingUp                       // bee alive, /chainstate not yet reachable
    case syncingPostage(percent: Int, lastSynced: Int, chainHead: Int)
    case ready
}
```

Notable shape changes:

- **`noUsableStamps` was dropped from this enum.** Stamps are tracked separately in `StampService.hasUsableStamps`; consumers compose the two signals.
- **Progress comes from `/chainstate`, not `/status`.** During the bundled-snapshot ingest (the bulk of the ~5 min wait), every other endpoint returns `503 "Node is syncing"`. `/chainstate` stays available the whole time and returns `{block, chainTip, …}` directly, giving us a smooth real-time percent (`block / chainTip`) without a separate Gnosis chain-head poll. This drops `walletRPC` as a `BeeReadiness` dependency and removes the 60s `cachedChainHead` cache the original plan needed.
- **`/readiness` is the master gate.** Only when bee says `"ready"` do we transition to `.ready`; on that transition we also fetch `/chequebook/address` once and stash it for the publish-setup "Chequebook deployed" row.
- **Adaptive polling**: 3s while light + not-ready, 30s once `.ready` (sticky). Replaces the per-endpoint cadences in the original plan. `StampService` polls separately (5s during a buy, 30s otherwise); `BeeWalletInfo` polls `/wallet` + `/chequebook/balance` at a flat 30s.
- **`swarm.status == .starting` matters too.** `MobileStartNode` is a blocking gomobile call that doesn't return — so doesn't flip status to `.running` — until bee's full init completes (~5 min for a fresh light boot). Bee's HTTP server is up the whole time. The readiness loop polls during both `.starting` and `.running` so the percent is visible from the start.

The publish-setup checklist in `PublishSetupView` reads `BeeReadiness.state` directly (no `NodeModeView` shipped):
- step 2 = `.startingUp` or `.syncingPostage(N%)` → "Light · syncing N%"
- step 3 (chequebook deployed) = auto-completes on `.ready`
- step 4 (stamp) = pending until `.ready`, then active or completed depending on `StampService.hasUsableStamps`

## 7. Stamps

### 7.1 BeeAPIClient

Thin URLSession wrapper, base URL `http://127.0.0.1:1633`. Handles JSON encode/decode, distinguishes 404 (notFound) from 500 (transient). Used by stamps + publish + feed services. No retries — we let the caller decide.

### 7.2 PostageBatch model

Normalize the Bee response shape into our domain:

```swift
struct PostageBatch: Equatable, Identifiable {
    let batchID: String           // hex
    let usable: Bool              // can be used for uploads
    let isMutable: Bool           // immutableFlag === false
    let depth: Int
    let amount: String            // PLUR per chunk
    let sizeBytes: UInt64         // total capacity
    let remainingBytes: UInt64    // unused
    var usagePercent: Double { ... }
    let ttlSeconds: TimeInterval
    var expiresApprox: Date? { ... }
}
```

Field meanings + math match desktop `stamp-service.js:27-72`. Helper conversions (depth ↔ size in bytes, amount ↔ ttl) live in `PostageBatch.swift` as static methods.

### 7.3 Purchase flow

State machine in `StampService` (post-WP3 + `/simplify`):

```
.idle
    ↓ user picks preset (Try it out / Small project / Standard) and taps Buy
.estimating
    ↓ fetch /chainstate.currentPrice (cached 10s for preset toggling)
    ↓ depth   = StampMath.depthForSize(bytes:)
    ↓ amount  = StampMath.amountForDuration(seconds:, pricePerBlock:)
.purchasing
    ↓ POST /stamps/{amount}/{depth} → batchID  (bee blocks until tx confirms,
    ↓                                            5min timeout matching desktop)
.waitingForUsable
    ↓ poll GET /stamps every 5s; flips to .usable when batch.usable == true
.usable
```

Differences from the original sketch:

- **No `/stamps/cost` endpoint.** Bee does not expose one. We replicate bee-js's `getDepthForSize` + `getAmountForDuration` + `getStampCost` exactly in `StampMath.swift` (with the same effective-size breakpoint table and the `+1` safety margin), so iOS and desktop pay the same for the same preset. Golden-vector tests in `StampMathTests` pin the math.
- **No `.readyToBuy` case.** It was implemented initially, then dropped during `/simplify` because it was set then synchronously overwritten before any UI tick — never observable.
- **No `.insufficientFunds`** branch. A pre-check rejection would be a UX nicety; today the user sees the actual bee error if the wallet can't cover the buy. Worth revisiting later, deferred.
- **No `.timedOut` branch.** The "waitingForUsable" timeout we'd guard against is a corner case (bee's batch takes longer than 120s to flip usable) that we haven't observed; can be added if it surfaces in real-world use.
- **Custom-input form is deferred** — presets-only for v1 (see §10).

Presets ([`StampService.swift`](../Freedom/Freedom/Swarm/Stamps/StampService.swift)) mirror desktop `stamp-manager.js:14-19` exactly:
- Try it out — 1 GB / 7 days
- Small project — 1 GB / 30 days *(default)*
- Standard — 5 GB / 30 days

### 7.4 Extension flows — 🚧 deferred

Originally part of WP3, deferred in the actual ship. Cheap presets last 7-30 days; users won't hit expiry for weeks/months and the UI would compete for attention with the WP4-6 publishing payoff. Pick this back up when usage signals a need (or when a real user's batch gets close to expiry).

When we do implement, the shape is straightforward — endpoints already exist:

- **Extend duration**: `PATCH /stamps/topup/{batchId}/{amount}` — adds amount to the existing batch. Cost = `2^depth × additionalAmount`. Presets: +7d, +30d, +90d.
- **Extend size**: `PATCH /stamps/dilute/{batchId}/{depth}` — bumps depth. **Bee semantic gotcha**: depth is the *absolute* new depth, not a delta. UI presets ("1 GB → 5 GB → 25 GB") compute the depth target via `StampMath.depthForSize`.

`StampMath.costPlur(depth:amount:)` already gives us cost client-side, same as the buy flow — no new math needed. New file would be `StampExtendView.swift` with two tabs.

### 7.5 UI

`StampsView.swift` — empty state ("No stamps yet — buy one to start publishing") if list is empty, else cards with usability badge / size / TTL / usage%. "Buy stamp" CTA pushes `StampPurchaseView.swift`.

Stamps surface lives under the **node sheet**, not "Wallet → Storage" as originally planned. A dedicated "Storage stamps" row in `NodeHomeView` pushes `StampsView`; the row is gated on `settings.hasCompletedPublishSetup` (same gate as the inline mode toggle). The publish-setup checklist also pushes `StampPurchaseView` from step 4 — single destination, two ways in.

### 7.6 Chequebook auto-top-up

Bee uses xBZZ in the chequebook to pay peers via SWAP for relaying content. With the chequebook at zero, peers won't actually serve published content — a hard prerequisite for the upcoming WP4–6 publish flow. After **every** successful stamp purchase, `StampService.topUpChequebookIfBelowFloor` runs:

1. Read `/chequebook/balance.availableBalance`.
2. If `available >= floor` (0.1 xBZZ in PLUR = `BigUInt(10).power(15)`) → no-op.
3. Compute `shortfall = floor - available`.
4. If node wallet xBZZ < shortfall → no-op (silent — the user can top up manually later when we add that surface).
5. `POST /chequebook/deposit?amount={shortfall}` with the same 5-min timeout as the stamp-purchase POST.
6. Kick `BeeWalletInfo.refresh()` so the node sheet's chequebook card snaps to the new balance instead of waiting for the next 30 s poll tick.

Fires as a fire-and-forget `Task` so the buy state machine doesn't wait on the deposit's chain tx (~30 s on Gnosis). Mirrors desktop's `autoDepositChequebookIfEmpty` semantically, but with the stricter top-up-to-floor rule (desktop only deposits when chequebook is empty; we keep it at the floor across all subsequent buys).

## 8. The `window.swarm` bridge

### 8.1 Method surface

10 methods, three permission tiers. Mirrors SWIP-draft bit-for-bit.

| Method | Permission tier |
|---|---|
| `swarm_getCapabilities` | none |
| `swarm_readFeedEntry` | none |
| `swarm_listFeeds` | none (origin-scoped) |
| `swarm_requestAccess` | grants connection |
| `swarm_publishData` | requires connection (+ approval or auto-approve) |
| `swarm_publishFiles` | requires connection (+ approval or auto-approve) |
| `swarm_getUploadStatus` | requires connection (+ tag-ownership match) |
| `swarm_createFeed` | requires connection + feed-grant |
| `swarm_updateFeed` | requires connection + feed-grant |
| `swarm_writeFeedEntry` | requires connection + feed-grant |

Connection grants and feed grants are **separate** — having one doesn't imply the other. Approval flow:

- Connection: one-time approval at `swarm_requestAccess`. Persisted in `SwarmPermissionStore`.
- Feed: one-time approval the first time an origin calls `swarm_createFeed` / `swarm_updateFeed` / `swarm_writeFeedEntry`. Includes identity-mode picker (§8.6). Persisted in `SwarmFeedStore`.
- Per-call publish/feed-write: foregrounded approval **unless** auto-approve is enabled for the origin. Auto-approve is two flags: `autoApprovePublish` and `autoApproveFeeds`, opt-in per origin, set during the connect or feed-grant approval modal.

### 8.2 Origin normalization

Reuse `OriginIdentity.from(displayURL:)` — already shipped. The address-bar URL is the source of truth (`bzz://hash/`, `ens://foo.eth/`, `https://app.example.com/`), not `window.location` (which is usually `http://127.0.0.1:1633/...` because of `BzzSchemeHandler`'s rewrite).

### 8.3 Routing

`SwarmRouter` parallels `RPCRouter` exactly:

```swift
@MainActor
func handle(method: String, params: [Any], origin: OriginIdentity) async throws -> Any
```

Dispatches by method name; permission checks happen before any service call. Error codes: 4001 (user rejected), 4100 (unauthorized — "connect first"), 4200 (unsupported method), 4900 (resource unavailable — Bee not running / not ready), -32602 (invalid params), -32603 (internal error). Codes are in `SwarmErrorPayload.Code` constants (no string literals in handlers).

### 8.4 Approval sheets

Three new `ApprovalRequest.Kind` cases:

- `.swarmConnect(displayURL: String)` — one row, "Connect to {origin}", auto-approve toggles disclosed below.
- `.swarmPublish(origin: String, sizeBytes: UInt64, fileCount: Int?)` — "{origin} wants to publish {N} files / {M} bytes", auto-approve toggle if not already on.
- `.swarmFeedAccess(origin: String, feedName: String, identityModeChoice: Bool)` — feed grant, includes identity picker (§8.6) when `identityModeChoice == true`.

Each reuses the existing `ApprovalOriginStrip`, `ApprovalUnlockStrip`, `ApprovalLabeledRow` components. Slide-to-approve pattern matches `eth_sendTransaction`.

### 8.5 Tag ownership

`TagOwnership.swift` holds an in-memory `[tagUid: OriginIdentity]` map, populated when `swarm_publishData` / `swarm_publishFiles` returns a tag. `swarm_getUploadStatus` rejects calls where the requesting origin doesn't match the recorded owner (returns `-32602` with `data.reason = "tag_not_owned"`). Map is wiped on app launch — tags don't survive Bee restarts anyway.

### 8.6 Feed identity modes

Two choices per origin, picked **once at the first feed grant**:

- **`app-scoped`** (recommended in the SWIP, default-selected in our UI): a dedicated publisher key derived at `m/44'/73406'/{originIndex}'/0/0`. Never funded, cryptographically isolated from the user's wallet. `originIndex` is allocated sequentially via `PublisherKeyAllocator` (which holds `nextPublisherKeyIndex` in `SwarmFeedStore`).
- **`bee-wallet`**: signs with the Bee node's main key (`m/44'/60'/0'/0/1`). Useful when an origin needs a known, funded publisher identity (rare).

We surface both options in `SwarmFeedAccessSheet.swift` (per the user's call — match desktop). UI: a segmented picker, app-scoped pre-selected, with a one-line explainer per option. We may revisit and default to app-scoped silently in a future iteration if user feedback shows confusion (per the user's note about user research).

The choice is **immutable per origin** once made (changing it would orphan existing feeds). Stored on `SwarmPermission.identityMode`.

### 8.7 Topic derivation

```swift
func feedTopic(origin: OriginIdentity, feedName: String) -> Data {
    let s = "\(origin.normalizedKey)/\(feedName)"
    return Data(s.utf8).web3.keccak256
}
```

`origin.normalizedKey` is the same string used as the SwiftData primary key in `SwarmPermission`. Cross-platform check at WP6: feed `("ens://foo.eth", "posts")` through both desktop and iOS, assert byte-identical 32-byte topic. Test fixture committed.

### 8.8 Write serialization

Feed writes to the same topic must not race — concurrent writes both targeting "next index" produce one successful write and one collision (the second fails with `index_already_exists` from the SOC layer, which surfaces as `-32602` `data.reason = "index_already_exists"`).

`SwarmFeedService` holds a per-topic actor lock (Swift `Actor` keyed by topic hex string). Every `writeFeedEntry` acquires the topic's actor before performing the write. This is local to a single app instance — cross-device concurrent writes still race, but that's a Bee-layer property the spec already notes. Within one app, we serialize.

## 9. Work-package lineup

Originally six WPs, one PR each. WP1–3 shipped on `feature/swarm-publishing`. Builds + tests + `/simplify` between every WP, smoke-test before commit.

### Shipped (`feature/swarm-publishing`)

- **WP1 ✅ — Bee identity injection** (`a4877fb`).
  Added CryptoSwift to SwiftPM for `Scrypt`. New: `BeeKeystore`, `BeeStateDirs`, `BeePassword`, `BeeIdentityInjector`. Wired into `VaultCreateView` / `VaultImportView` / wallet-wipe completion. Replaced `FreedomApp`'s hardcoded `"freedom-default"` password with the random per-install Keychain-backed one. Legacy migration on first launch detects Keychain absence and wipes the bee data dir. `HDKey.Path.publisherKey(originIndex:)` deferred to WP6 since it's only needed for feed signing.

- **WP1.5 ✅ — Decouple wallet UX from Bee identity swap** (`797d526`).
  In-flight refactor — `BeeIdentityCoordinator` runs the inject/revert/restart state machine in the background so the user sees the wallet land in ~1 s while bee restarts under the cover. Replaced what the original plan called `BeeNodeController`.

- **WP1.6 ✅ — Node sheet** (`2a9de23`).
  `NodeHomeView` plus the navigation stack hosting it. Status, wallet card, log preview, mode-toggle row.

- **WP2 ✅ — Light-mode upgrade + one-tx funding** (`1e181ec`).
  New: `BeeNodeMode`, `SwarmFunderConstants`/`Quote`/`Pool`, `FundNodeBuilder` (hand-rolled ABI for `fundNodeAndBuyStamp`, selector `0x834aeb80`), `BeeBootConfig`, `PublishSetupView` (4-step checklist hosting the funder UI inline rather than the planned `FundNodeFlow` + `FundNodeReviewView` split), `PublishStepRow`. The mode toggle moved into `NodeHomeView.statusCard.modeRow` rather than a separate `NodeModeView`.
  Bumped `bee-lite-java` to `ios-v0.1.2` for the leveldb LOCK fix (see §5.4.1).

- **(refactor) ✅ — `restartForMode` retry loop drop** (`1e626d7`).
  After the bee statestore + Kademlia metrics close fixes landed, the retry-with-backoff was dead weight — collapsed back to `ensureStopped → start`.

- **(fix) ✅ — Test isolation** (`0001a55`).
  `BeeIdentityCoordinatorTests` was constructing `SettingsStore(defaults: .standard)` and clobbering the user's persisted `beeNodeMode`. `BeePasswordTests.tearDown` was also wiping production Keychain on every skip. Both fixed (UUID-suite UserDefaults + tearDown wipe removal).

- **(refactor) ✅ — `/chainstate`-driven readiness with live sync %** (`9b8ed09`).
  Replaced the planned `/health` 1s + `/readiness` 2s + `/stamps` 5s + Gnosis chain-head poll with a single localhost `/chainstate` query (returns `{block, chainTip}` directly, available throughout the syncing window). Adaptive polling 3 s / 30 s. `.deployingChequebook` → `.startingUp`. `walletRPC` dependency dropped from `BeeReadiness`. See §6.5 for the full state-machine update.

- **WP3 ✅ — Stamp management** (`d9df664`).
  New: `BeeAPIClient`, `StampService`, `PostageBatch`, `StampMath` (replicates bee-js's depth/amount/cost math; bee has no `/stamps/cost` endpoint), `StampsView`, `StampPurchaseView`, `StampMathTests`. Stamps surface lives under the node sheet (`StampsView`), not "Wallet → Storage" as originally planned. Stamp extend (`StampExtendView`) deferred (§7.4).

- **(feat) ✅ — Node sheet wallet/chequebook + diagnostic logs** (`9481787`).
  `BeeWalletInfo` polls `/wallet` + `/chequebook/balance` every 30 s. Replaced the bare wallet card with structured "Node wallet" (xDAI / xBZZ / shortened address with tap-to-copy) and "Chequebook" (xBZZ / shortened address) cards. The inline log preview moved to a separate `NodeLogView` reachable via a tertiary "View logs" link.

- **(feat) ✅ — Chequebook auto-top-up** (`2f94afc`).
  After every stamp purchase, top up chequebook to a 0.1 xBZZ floor from the node wallet. Hard prerequisite for WP4–6 to actually publish (peers won't serve content with an unfunded chequebook). See §7.6.

### Not started

- **WP4 — `window.swarm` bridge foundation**.
  New: `SwarmBridge` + preload, `SwarmRouter`, `SwarmErrorPayload`, `SwarmPermission` + `SwarmPermissionStore`, `SwarmConnectSheet`. Methods 1-3: `getCapabilities`, `requestAccess`, `readFeedEntry` + `listFeeds`. Extend `ApprovalRequest.Kind` with `.swarmConnect`. Tests: router dispatch, permission gating, origin normalization. ~600-800 LoC.

- **WP5 — Publish path**.
  Methods 4-6: `publishData`, `publishFiles`, `getUploadStatus`. New: `SwarmPublishService`, `TagOwnership`, `SwarmPublishSheet`. Extend `ApprovalRequest.Kind` with `.swarmPublish`. Per-origin `autoApprovePublish` toggle. Stamp auto-selection (best fit). Tests: publish round-trips against a local Bee, tag scoping rejects cross-origin reads. ~500-700 LoC.

- **WP6 — Feed path**.
  Methods 7-10: `createFeed`, `updateFeed`, `writeFeedEntry`. (`readFeedEntry` shipped at WP4.) New: `SwarmFeedRecord` + `SwarmFeedStore`, `SwarmFeedService`, `FeedTopic`, `PublisherKeyAllocator`, `SwarmFeedAccessSheet`. Extend `ApprovalRequest.Kind` with `.swarmFeedAccess`. Per-origin `autoApproveFeeds` toggle. Add `HDKey.Path.publisherKey(originIndex:)`. Tests: topic byte-identity vs desktop, per-topic write actor serialization, allocator monotonicity, identity mode immutability. ~700-900 LoC.

## 10. Out of scope (don't propose without re-discussing)

- **Multi-account on the Bee node** — single bee identity per device, derived from the active mnemonic. Multi-account support comes when the wallet UI does (see wallet-architecture.md §11).
- **Publisher identity rotation** — once an origin picks `app-scoped` vs `bee-wallet`, it's permanent. Rotation orphans feeds.
- **Manual stamp selection on publish** — we always auto-pick the best-fitting usable batch. Surface for advanced users only if user feedback demands it.
- **Stamp dilute as separate UX** — folded into "extend size" (the Bee API endpoint is `dilute` but the user-facing word is "size").
- **Non-Gnosis chequebook** — Gnosis only.
- **CowSwap / 1inch fallback for funding** — `SwarmNodeFunder` is the only path. If the funder contract goes down, we ship a new address.
- **In-place key rotation in Bee** — we always do full stop/wipe/start. No "graceful reload" path; bee-lite doesn't expose one.
- **`swarm_subscribeFeed` or push-based feed updates** — SWIP-draft is poll-only. We follow.
- **ACT (Access Control Trie) encrypted publishing** — bee-lite supports it, our wrapper doesn't. Future SWIP, future WP.
- **Radicle / IPFS identity surfaces** — derivation paths exist on desktop; iOS doesn't have those nodes. Out.

## 11. Open items

Resolved during WP1–3:

- ~~**The exact `fundNodeAndBuyStamp` ABI**~~ — confirmed at WP2 against the deployed contract; selector pinned at `0x834aeb80` in `FundNodeBuilder` with a regression test.
- ~~**`xbzzMinOut` slippage policy**~~ — defaulted to 5% (`SwarmFunderConstants.defaultSlippageBps = 500`). Hardcoded for now; will surface as an advanced setting if real users hit slippage failures.
- ~~**`/health` vs. `/readiness` polling cadence**~~ — replaced with a single `/chainstate`-driven loop at adaptive 3 s / 30 s (see §6.5).

Still open:

- **Stamp price USD estimate**. UI shows xBZZ only. Add a USD/EUR conversion when there's user-facing pricing demand.
- **Feed-write retry on transient errors**. WP6 — explicit retry vs. surface failure to dapp? Lean toward surfacing; dapps can retry with their own backoff.
- **Wallet-doc updates**. After WP1 shipped, `wallet-architecture.md` §5.1 should mark `m/44'/60'/0'/0/1` as "surfaced" and add the publisher-key row when WP6 lands. Cross-reference this doc.
- **Top-up flows for node wallet + chequebook**. Currently the only deposit path is the funder (one-tx) and the auto-top-up (post-stamp-buy). Real management surface (top-up node wallet from main wallet; manual top-up of chequebook from node wallet) deferred until users hit balance floors in practice.
- **`BeePasswordTests` re-enablement**. Currently `XCTSkipIf`'d because a test wipe of the production Keychain entry triggers `FreedomApp`'s legacy migration on next launch. Proper fix: parameterize `BeePassword` to use a `.test` Keychain account and remove the skip.
