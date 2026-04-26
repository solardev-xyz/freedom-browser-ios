# Wallet Architecture (M5 — draft)

A sketch of the baked-in Ethereum wallet for the iOS Freedom Browser. Parallel in spirit to the desktop browser's wallet (`/Users/florian/Git/freedom-dev/freedom-browser/src/main/wallet/`) but native throughout — no Electron IPC, no ethers.js, no web3 framework doing heavy lifting on our behalf. This document is a starting point to iterate on, not a committed plan.

> **Reading order**: read alongside [`architecture.md`](./architecture.md) (overall app shape) and [`ens-resolution.md`](./ens-resolution.md) (the ENS pipeline we'll reuse for `eth_call`-style reads). The desktop wallet is the reference implementation — its injected-provider + approval-modal model is what we're porting, adapted to WKWebView + Swift.

## 1. What the wallet needs to do

Two audiences, same engine:

1. **The user** — manages keys/addresses, views balances, initiates sends. Treated as a first-class app feature, not a settings-panel afterthought.
2. **Dapps loaded in a BrowserTab's WKWebView** — see a `window.ethereum` provider (EIP-1193) and an EIP-6963 announce, route `eth_requestAccounts` / `personal_sign` / `eth_signTypedData_v4` / `eth_sendTransaction` / `eth_call` / `wallet_switchEthereumChain` through it.

### 1.1 Scope vs. desktop parity

The desktop browser's "wallet" is really a **full identity surface**: user Ethereum wallet, Bee wallet (xBZZ, chequebook, postage-stamp funding), Swarm publisher identities, per-origin Swarm-permissions, etc. See `src/renderer/lib/wallet-ui.js` and `src/main/identity/derivation.js`.

**v1 iOS scope is the Ethereum wallet only.** Out of scope for v1:

- Bee-wallet / xBZZ / chequebook UI (iOS runs a Bee light node via `SwarmKit` but the Bee wallet is managed inside the node, not surfaced in user UI).
- Publisher identities and Swarm permissions (no on-device publishing yet).
- Hardware-wallet connectors, WalletConnect-as-client, NFT galleries, token-price feeds, swap/bridge UI.
- Multi-account UI (single-account v1, but derivation paths are reserved for future expansion — see §5.1).

What v1 **does** share with desktop: the BIP-39 seed, BIP-44 derivation scheme (so addresses line up when the user uses the same mnemonic on both platforms), the approval-modal UX pattern, and the injected `window.ethereum` compat surface.

## 2. Threat model

We guard against:

- **Dapp-initiated silent signing**: signatures always require a foregrounded user approval — *never* auto-approve. Transactions require either a foregrounded approval **or** a pre-existing, user-configured `AutoApproveRule` scoped to the specific `(origin, contract, selector, chainID)` combination (see §7). The EIP-1193 bridge itself never auto-approves; any auto-approve path is a consented-in-advance user decision, not a machine decision.
- **Origin spoofing across tabs**: a request coming from tab X can only act on permissions granted to tab X's *display identity* (see §6.1), not to whatever URL the WebView happens to be loading. Cross-tab permission bleed is a bug.
- **Permission rotation attacks**: permissions bind to the address-bar identity (e.g. `ens://foo.eth`), not to the currently-loaded resolved URL (`bzz://<hash>`), so a content-hash rotation doesn't silently transfer grants to new content — the user's ENS authorization still describes *which name* they trusted, not which hash happened to resolve at grant time.
- **Key exfiltration via memory dump**: raw private keys never sit in memory longer than a single signing operation. Seed is encrypted at rest behind a biometric-gated Keychain ACL (iCloud-synced) or, on opt-in, a Secure-Enclave-wrapped DEK; the decrypted seed is zeroed after lock or idle timeout.
- **Phishing via visual confusion**: approval sheets display the origin prominently, render typed-data human-readably (domain/primaryType/fields), and decode common tx intents (transfer/approve/etc.) when selector is known.
- **Dapp-crafted RPC spoofing**: every wallet RPC (`eth_call`, `eth_getBalance`, `eth_estimateGas`, `eth_feeHistory`, `eth_getTransactionCount`, `eth_sendRawTransaction`) goes through our `EthereumRPCPool` — the same provider list ENS uses, with the same quarantine state — **not** a dapp-supplied URL. The dapp never gets to pick which RPC we talk to.
- **iOS state-restoration leaks**: the approval sheet and any pending-tx scratch state are excluded from NSUserActivity restoration payloads.

Out of scope:

- A compromised device with an unlocked vault (the user's passcode/biometric is the trust root; OS-level compromise ends the game).
- A malicious OS keyboard capturing the vault password (we rely on the system's secure text entry).
- MEV, front-running, gas-griefing at the network level — those are dapp-layer concerns.

## 3. Library posture

**We keep Argent's `web3.swift` and lean on it more than we do today.** Today it's doing <200 lines of ABI / keccak256 work for ENS. For the wallet we also use:

- `EthereumAccount.sign(message:)` — personal_sign (EIP-191 prefix + keccak256 + secp256k1)
- `EthereumAccount.signMessage(message: TypedData)` — EIP-712 v4
- `EthereumAccount.sign(transaction:)` — EIP-1559 + EIP-155 tx signing
- `TypedData` — EIP-712 struct-hash computation

This covers all three signing operations without us reaching for curve ops directly. The `secp256k1.swift` C binding that Argent depends on transitively (`GigaBitcoin/secp256k1.swift` @ 0.19.0, now redirected to `21-DOT-DEV/swift-secp256k1`) is reused — no duplicate copy in the binary.

**We do not adopt wagmi-swift**: solo author, no tagged releases, local-path SPM dependency on viem-swift, no CCIP-Read/wildcard ENS, no EIP-1193 bridge (see wagmi-swift evaluation notes, 2026-04-23). Its viem-swift primitives layer is worth watching — if it matures we can vendor what we need.

**We expose the existing `secp256k1` module to the `Freedom` target, without adding a new package reference.** For BIP-32 CKDpriv (child-key derivation with non-hardened steps) we need scalar-add on the curve — `PrivateKey.add(_:)` — which Argent's public surface doesn't expose. The `GigaBitcoin/secp256k1.swift` package is already in the SwiftPM graph as Argent's transitive dep (pinned at 0.19.0 via `Package.resolved`), but having a package in the graph doesn't make its module importable from a target — the target needs an explicit `XCSwiftPackageProductDependency`. We added that entry to `Freedom.xcodeproj` so `import secp256k1` resolves inside our code. No new package reference, no duplicate copy of libsecp256k1 in the binary — we're reusing the exact module Argent already links.

**What we build in-repo**: BIP-39 mnemonic (word list + PBKDF2-SHA512), BIP-32 HD derivation, the EIP-1193 bridge, the approval sheets, the permission store, the chain registry, the nonce tracker. All mechanical, all small, and keeping them in-repo means the threat model matches line-for-line rather than inheriting whatever a library author thought was reasonable.

## 4. Module layout

Target shape, under `Freedom/Freedom/Wallet/`. `✅` = shipped; unmarked = planned for the milestone shown. Source of truth for what's actually in the tree is the filesystem — see §10 for WP-by-WP progress.

```
Wallet/
├── Vault/
│   ├── Vault.swift                  ✅ @Observable, lock/unlock, revealMnemonic
│   ├── VaultCrypto.swift            ✅ three-tier at-rest encryption (§5.2)
│   ├── BiometricPrompter.swift      ✅ LAContext adapter for cloudSynced gate
│   ├── Mnemonic.swift               ✅ BIP-39
│   ├── BIP39English.swift           ✅ canonical wordlist
│   ├── HDKey.swift                  ✅ BIP-32 + reserved paths (§5.1)
│   ├── KeychainItem.swift           ✅ SecItem wrapper with Protection enum
│   └── Data+SecureRandom.swift      ✅ SecRandomCopyBytes helper
├── Chains/
│   ├── Chain.swift                  ✅ id, name, explorer, native symbol, poll interval
│   └── ChainRegistry.swift          ✅ Gnosis/Mainnet, fixed set (§6.4)
├── RPC/
│   └── WalletRPC.swift              ✅ single-shot-with-fallback + callOptional
├── Transactions/                    ✅ WP6
│   ├── TransactionService.swift     ✅ @Observable orchestrator
│   ├── NonceTracker.swift           ✅ per-(account,chain) optimistic cache
│   ├── GasOracle.swift              ✅ eth_gasPrice wrapper (EIP-1559 ⇒ M5.7)
│   └── HDKeyStorage.swift           ✅ web3.swift signing adapter
├── Hex.swift                        ✅ shared 0x-hex parser
├── UI/                              ✅ WP4/5/7 all here
│   ├── WalletSheet.swift            ✅ state dispatcher + closeWalletSheet env
│   ├── WalletComponents.swift       ✅ SetupStage, AddressPill, VaultResultView,
│   │                                   VaultFailureView, PrimaryActionButton,
│   │                                   PrimaryActionStyle, WalletAdvancedSection,
│   │                                   WipeWalletButton, SecurityLevelBadge,
│   │                                   WalletDefaults
│   ├── VaultSetupView.swift         ✅ Create / Import chooser
│   ├── VaultCreateView.swift        ✅ quick-option create
│   ├── VaultImportView.swift        ✅ paste + validate phrase
│   ├── WalletLockedView.swift       ✅ unlock + advanced/wipe
│   ├── WalletHomeView.swift         ✅ address, chain picker, balance, send
│   ├── RecoveryPhraseView.swift     ✅ 24-word grid, auto-hide on background
│   ├── BalanceFormatter.swift       ✅ format + parseAmount
│   ├── SendFlowView.swift           ✅ form with debounced quote
│   └── SendReviewView.swift         ✅ review + inline progress / confirmation
├── Bridge/                          (M5.4)
│   ├── EthereumBridge.swift         WKUserContentController + WKScriptMessageHandler;
│   │                                   regenerates the __FREEDOM_PROVIDER_CONFIG__
│   │                                   preamble per navigation (§6.3).
│   ├── EthereumBridge.js            single preload — EIP-6963 announce plus
│   │                                   window.ethereum (EIP-1193 + legacy compat).
│   ├── RPCRouter.swift              method → handler dispatch
│   └── OriginIdentity.swift         displayURL → permission key
├── Permissions/                     (M5.4/M5.5)
│   ├── DappPermission.swift         @Model: origin, account, chainID
│   ├── PermissionStore.swift        SwiftData-backed grant/revoke
│   └── AutoApproveRule.swift        (M5.7) opt-in per origin+selector rules
└── UI/ (M5.5 adds)
    ├── ApproveConnectSheet.swift    eth_requestAccounts
    ├── ApproveSignSheet.swift       personal_sign / signTypedData_v4
    └── ApproveTxSheet.swift         (M5.6) eth_sendTransaction
```

Shipping note: the standalone `Signing/Signer.swift` originally sketched here didn't pan out as a separate file — signing lives in `TransactionService.swift` which feeds `web3.swift`'s `EthereumAccount` via `HDKeyStorage`. When M5.5 lands `personal_sign` and `signTypedData_v4`, the expectation is we extend that same pattern rather than introduce a new `Signer` shell.

Nothing here imports anything outside `Wallet/` except `EthereumRPCPool` (for `eth_call` reads and gas/nonce queries) and `SettingsStore`.

## 5. The vault

### 5.1 Shape

- **One seed, multiple reserved derivation paths** (port of desktop's `src/main/identity/derivation.js`):

  | Purpose | Path | v1 status |
  |---|---|---|
  | Main user wallet | `m/44'/60'/0'/0/0` | **surfaced in UI** |
  | Bee wallet (node) | `m/44'/60'/0'/0/1` | reserved — derived but not surfaced |
  | Additional user wallets | `m/44'/60'/{i}'/0/0`, `i ≥ 1` | reserved for multi-account (§11) |
  | Publisher identities | (desktop-only namespace, TBD) | not in v1 |

  Keeping this layout identical to desktop means **the same mnemonic produces the same addresses on iOS and desktop** — the whole reason to align schemes. `HDKey.swift` exposes all four reservations as named constants so nothing ever writes `m/44'/60'/0'/0/1` as a "user account 2" by accident.

- **Locked by default at app launch**. First unlock every app session requires biometric (Face ID / Touch ID) with passcode fallback. Subsequent unlocks within the session are free until the idle timer fires.
- **Idle auto-lock**: configurable (1 min / 5 min / 15 min / never), default 5. Timer resets on any **wallet UI interaction** *and* on any **successful privileged dapp operation** (`personal_sign`, `eth_signTypedData_v4`, `eth_sendTransaction`) — an active dapp session shouldn't relock mid-flow. Matches desktop `wallet-ipc.js:289`. Plain RPC reads (`eth_call`, `eth_getBalance`, etc.) do **not** reset the timer — otherwise a polling dapp keeps the wallet unlocked indefinitely.
- **No seed view without re-auth**. "Show recovery phrase" is the only path; it re-prompts biometric every time. The phrase is never shown at setup.

### 5.2 At-rest encryption

Three tiers. `VaultCrypto` is constructed with a **preferred tier** and silently falls back to `.deviceBound` whenever the preferred tier can't be created on the current device.

1. **cloudSynced** (v1 default):
   - Data encryption key (AES-256-GCM, 32 random bytes) and blob both stored in Keychain with `kSecAttrAccessibleWhenUnlocked` + `kSecAttrSynchronizable = true`. **No `SecAccessControl`** — iCloud Keychain silently refuses to sync items that carry one (access control is a device-local concept; sync is device-agnostic; the two are mutually exclusive by Apple's design).
   - Biometric/passcode gate is therefore **applied at the app layer**: on unlock, `VaultCrypto` calls `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)` via a `BiometricPrompter` abstraction. If the user authenticates, we proceed to read the DEK; if they cancel, we throw.
   - At create, `prompter.canPrompt()` gates which tier we land on — no usable biometric/passcode means falling back to `.deviceBound` so we never store a plaintext DEK into iCloud Keychain.
   - Recovery story: **iCloud Keychain carries the DEK and blob**. User replaces device, signs into iCloud on the new one, Face-IDs on the first unlock, vault is there.
   - Trades vs `.protected`: slightly weaker — a jailbroken device can bypass the app-level gate since iOS can no longer enforce it at the kernel, and Apple-ID compromise is a theoretical path (mitigated by iCloud Keychain's trusted-device approval for new sign-ins). For a browser wallet with typically-modest balances, we take this trade for dramatically better UX — matches what MetaMask-mobile and Rainbow do.
2. **protected** (code path retained, not selected by default):
   - Secure Enclave ECC P-256 key with `.privateKeyUsage + .userPresence` ACL. Key literally cannot leave the chip.
   - Random 32-byte DEK, encrypted to the SE public key via ECIES (`.eciesEncryptionCofactorVariableIVX963SHA256AESGCM`). Wrapped DEK lives in Keychain `.whenUnlockedThisDeviceOnly, synchronizable=false`.
   - Blob encrypted AES-GCM with the DEK, same Keychain constraints.
   - Unlock = SE decrypts DEK (triggers biometric at the kernel level) → blob decrypts → seed in memory.
   - Strictly this-device-only. SE keys don't migrate; device loss means needing the recovery phrase.
   - Available for a later "advanced security" opt-in; not on the v1 surface.
3. **deviceBound** (fallback):
   - DEK stored in Keychain with `.whenUnlockedThisDeviceOnly`, no ACL. Blob same.
   - The fallback the store path takes when the preferred tier can't be realised — typically a device with no passcode (both `.cloudSynced`'s `.userPresence` ACL and `.protected`'s SE key need one).

Lock = zero the seed buffer via `memset_s`, drop the reference. DEK reappears only on the next unlock.

The chosen tier is written alongside the blob as a plain-text marker (see §5.3) and honored on subsequent loads.

### 5.3 Recovery

- **BIP-39 24-word mnemonic**, always. Matches desktop. At setup, the user does not see it — "quick option" flow is literally generate → encrypt → done.
- **Primary backup story**: iCloud Keychain, via the `.cloudSynced` tier (§5.2). Lose the device, restore from iCloud on the new one, biometric-unlock the vault. No user action needed at setup beyond having iCloud Keychain enabled (which most users already do).
- **Secondary / power-user backup**: "Show recovery phrase" in the wallet's Settings re-prompts biometric and displays the 24 words for off-device storage (paper, password manager, etc.). Not forced at setup — users who want belt-and-braces can retrieve it later.
- Import flow accepts any valid BIP-39 phrase (12, 15, 18, 21, or 24 words). Warns-but-allows if the phrase matches a well-known test vector (dev convenience).
- On a device with no passcode (rare), the store path falls back to `.deviceBound`: no iCloud backup possible. Surface a one-line notice at setup ("Enable a device passcode for iCloud backup — otherwise save your recovery phrase") so the user isn't surprised later.

## 6. The EIP-1193 bridge

### 6.1 Origin identity (the permission key)

**Permissions bind to the address-bar identity, not to `WKWebView.url`.** This is a subtle but critical point that desktop already got right (`src/shared/origin-utils.js`). The key shapes match desktop *exactly* — ENS keys are bare lowercased names (no scheme), dweb/web keys carry their scheme:

- User navigates to `foo.eth`. ENS resolves to `bzz://abc123.../`. **Identity is `foo.eth`** (bare, lowercased — no `ens://` prefix).
- ENS owner rotates the content-hash to `bzz://def456.../`. **Identity is still `foo.eth`.** Permissions survive rotation because the user granted them to *the name*, not to a particular hash.
- User navigates directly to `https://app.uniswap.org/pool/123`. **Identity is `https://app.uniswap.org`** — `URL.origin`, path stripped.
- User navigates to `bzz://abc123.../path/`. **Identity is `bzz://abc123`** — scheme + root ref, path stripped, case preserved (multi-base encoded hashes are case-sensitive).

Display vs. storage: approval sheets and the "Connected sites" list are free to render ENS identities with an `ens://` scheme marker for visual consistency with `bzz://` / `https://`, but the **storage key is the bare name**. Rendering is a UI concern; the key shape is a contract with desktop.

`OriginIdentity.swift` derives this from `BrowserTab.displayURL` (which already prefers `ensURL` when present, exactly for this reason — see `BrowserTab.swift:54`). The native side reads it fresh at every message-receive; the JS side never gets to supply it.

Why this matters: if we keyed permissions on `webView.url`, a user who granted Uniswap access to `app.uniswap.eth` would see their grant silently break whenever the resolved `bzz://<hash>` rotated, forcing a reconnect every deploy. That's wrong-by-construction.

**iOS and desktop produce byte-identical origin keys for the same displayed URL.** `OriginIdentityTests.swift` mirrors the fixtures above and any further cases desktop's `origin-utils.js` handles — a drift on either side should fail that suite.

### 6.2 Shape

WKWebView talks to native via `WKScriptMessageHandler` (one direction) and evaluated-JS callbacks (the other). The bridge lives on a per-`BrowserTab` basis so each tab carries its own origin context.

```
┌────────────────────────────────────────────────────────┐
│ WKWebView (loaded dapp page at https://app.uniswap.org)│
│                                                        │
│   ┌──────────────────────────────────────────────┐     │
│   │ EthereumBridge.js (injected at doc-start)    │     │
│   │                                              │     │
│   │  window.ethereum = new EIP1193Provider()     │     │
│   │  dispatchEvent("eip6963:announceProvider")   │     │
│   │                                              │     │
│   │  .request({method, params}) => postMessage  ─┼──┐  │
│   │  Promise resolved via pending-id registry    │  │  │
│   └──────────────────────────────────────────────┘  │  │
│                                                     │  │
└─────────────────────────────────────────────────────┼──┘
                                                      │
                       WKScriptMessageHandler         │
                                                      ▼
┌────────────────────────────────────────────────────────┐
│ EthereumBridge.swift (per BrowserTab)                  │
│                                                        │
│   - verifies message shape                             │
│   - OriginIdentity.of(tab) — from displayURL, not url  │
│   - RPCRouter.handle(method, params, origin) async     │
│       → permission-check                               │
│       → approval sheet (user-gated methods)            │
│       → execute (signer / WalletRPC / chain state)     │
│       → reply via webView.evaluateJavaScript           │
│           ("__freedomResolve__(id, result)")           │
└────────────────────────────────────────────────────────┘
```

### 6.3 The injected JS (`EthereumBridge.js`)

Hand-written, ~250 lines. The surface **matches desktop's `webview-preload-ethereum-inject.js`** — that surface was shaped by real-world dapp testing, and iOS diverging from it means some dapps that work on desktop would silently break here.

#### 6.3.1 EIP-6963 is the primary discovery path

Modern wallet-connection stacks (Wagmi, Web3Modal / Reown, RainbowKit, ConnectKit) discover providers by listening for `eip6963:announceProvider` events — *not* by grabbing whoever sat on `window.ethereum` first. EIP-6963 is the standard, and it's the mechanism that lets Freedom show up in a wallet picker **as Freedom**, with our own name and icon, rather than masquerading as something else. Desktop already does this (`src/main/webview-preload-ethereum-inject.js:164-189` + `src/main/ipc-handlers.js:240-251`) and it works well.

Shape on iOS:

- Native prepends a `window.__FREEDOM_PROVIDER_CONFIG__ = {uuid, name, icon, rdns}` preamble to `EthereumBridge.js` at every load. Fresh UUID per page session (stable across re-announces within that session), `name = "Freedom Browser"`, `icon = data:image/png;base64,…` (small inlined PNG loaded once at app start), `rdns = "baby.freedom.browser"` (matches desktop's `brand.appId`; keeping the same rdns means a user who connected on desktop is recognizably the same wallet on iOS).
- The preload freezes both `info` and the wrapping `detail` object, then dispatches `CustomEvent('eip6963:announceProvider', { detail: { info, provider: window.ethereum } })` immediately, and again on every `eip6963:requestProvider`.
- Injection of the preamble escapes `<` as `<` so a future config-value containing `</script>` can't break out of the injected `<script>` tag.
- If the preamble is missing (bridge-setup race / bug), log and skip the 6963 announce — `window.ethereum` is still installed and `ethereum#initialized` still fires, so dapps degrade to the legacy path rather than losing provider access entirely.

#### 6.3.2 `window.ethereum` is the legacy compat path

Pre-EIP-6963 dapps grab `window.ethereum` directly and sniff `isMetaMask: true` as a feature gate. We install the provider object and set the flag so those dapps keep working — it's **explicitly a compat shim**, not our wallet identity. The name and icon a user sees in a modern picker come from the EIP-6963 announce above; everything on `window.ethereum` is about keeping older code paths functional.

Specifically we ship (shape matches desktop):

- **EIP-1193 core**: `request({method, params})`, `on`/`removeListener`/`addListener`/`removeAllListeners`, `isConnected()`, and the event types `connect` / `disconnect` / `accountsChanged` / `chainChanged` / `message`. The event plumbing is wired but individual events only fire as their underlying state machines come online — `chainChanged` with M5.7's per-origin chain state, `accountsChanged`/`connect`/`disconnect` with M5.5's connect sheet.
- **Legacy method shims (still widely checked)**: `enable()` (calls `eth_requestAccounts`), `send(methodOrPayload, paramsOrCallback)` handling both forms, `sendAsync(payload, callback)`.
- **Legacy properties**: `selectedAddress`, `networkVersion` (decimal chainID), `chainId` (hex).
- **Identity flags**: `isMetaMask: true`, `isFreedomBrowser: true`.
- **Legacy init signal**: `window.dispatchEvent(new Event('ethereum#initialized'))` after wiring.

The deliberate refusals (below in §6.4) are *semantic*, not surface — the provider exists and accepts calls to `eth_sign`/`eth_signTransaction`, it just rejects them with an error payload. Dapps that feature-detect by trying-and-catching get a clean signal.

Injected via `WKUserScript(source:, injectionTime: .atDocumentStart, forMainFrameOnly: false)` on a `WKUserContentController` shared across tabs (messages carry the tab identifier; the handler looks up the tab's `OriginIdentity` at dispatch time).

### 6.4 Method routing

| Method | Gated? | Handler |
|---|---|---|
| `eth_chainId` | no | returns current chain for origin (Gnosis unless switched — §11) |
| `eth_accounts` | no | returns `[]` if origin not connected, else `[account]` |
| `net_version` | no | legacy alias for `eth_chainId` decimal — some older dapps still ask |
| `eth_requestAccounts` / `enable` | **user** | ApproveConnectSheet → grants `DappPermission` |
| `wallet_switchEthereumChain` | **user** | switches only to chains in our `ChainRegistry`; unknown chainID → error `4902` "Unrecognized chain" |
| `personal_sign` | **user** | ApproveSignSheet |
| `eth_signTypedData_v4` | **user** | ApproveSignSheet (typed-data render) |
| `eth_sendTransaction` | **user** | ApproveTxSheet (or matching `AutoApproveRule`, §7) |
| `eth_call`, `eth_getBalance`, `eth_blockNumber`, `eth_getTransactionCount`, `eth_estimateGas`, `eth_feeHistory`, `eth_sendRawTransaction`, `eth_getTransactionReceipt`, `eth_getTransactionByHash`, `eth_getLogs`, `eth_getBlockByNumber`, `eth_gasPrice` | no | `WalletRPC` — single-shot with fallback over `EthereumRPCPool` (§9), **not** a dapp-supplied URL |
| `wallet_addEthereumChain` | **refused** | v1 ships a fixed `ChainRegistry`. Respond with error `4200 "Method not supported"`. Per-origin chain installs have a large trust/RPC-validation surface for little early value; matches desktop. |
| `eth_sign`, `eth_signTransaction` | **refused** | footgun methods; never implement |
| unknown | **refused** | respond with `{code: 4200, message: "Method not supported"}` |

All gated methods check `PermissionStore` first. If the origin isn't connected, the RPCRouter responds with EIP-1193 error `{code: 4100, message: "Unauthorized"}` — dapp is expected to call `eth_requestAccounts` first.

### 6.5 Which origins can call the wallet

- **`https://...`** — full wallet access.
- **`ens://...`** — full wallet access. A core Freedom differentiator: a dapp served from `foo.eth` via Swarm gets the same EIP-1193 treatment as one on a centralized CDN, because the ENS name is a stable identity the user can grant permissions to. Matches desktop.
- **`bzz://<hash>`** (path stripped) — full wallet access. Treated as a first-class content-addressed identity, matching desktop's `origin-utils.js`. The hash itself *is* the identity — immutable by construction — so a grant to `bzz://abc123…` describes exactly what the user authorized. No rotation question (unlike ENS, where the name points at a moving target).
- **`http://...`** — refused. Plaintext origin, no wallet access.
- Any other scheme — refused.

## 7. Permissions

`DappPermission` is a `@Model` with `(origin, account, chainID, grantedAt, lastUsedAt)`. Granted via the connect sheet. Visible in a "Connected sites" settings screen (mirror of the desktop app's) where the user can revoke individually or clear all.

**Auto-approve rules** (lifted from desktop): `AutoApproveRule` with `(origin, contractAddress, functionSelector, chainID, expiresAt?)`. User opts in per-transaction via a checkbox on `ApproveTxSheet` — "Always approve transfers to this contract on Gnosis". Defaults: never offered for `eth_sendTransaction` with zero selector (plain ETH sends), never offered for value > threshold, never offered for unknown selectors. This is cautious by design — we'd rather have the user tap approve a second time than silently greenlight a selector we can't decode.

Signatures never auto-approve. Full stop. The asymmetry with transactions is intentional: a signed typed-data payload can be weaponized off-chain in ways the user can't reason about, so we always re-gate.

## 8. Approval UX

Three sheets, shared visual language:

1. **Origin strip** at top: favicon + `OriginIdentity` string + scheme marker.
   - `ens://foo.eth` — name prominent, "via Swarm" subtitle.
   - `bzz://abc123…def` — first+last 6 chars of the hash, "Swarm content-address" subtitle. Full hash available on tap for belt-and-braces verification.
   - `https://app.uniswap.org` — standard lock + host.
2. **Action body** middle:
   - Connect: requested account + chainID
   - Sign: decoded message (utf8 if printable, hex otherwise) or typed-data tree
   - Tx: to + value (in native units only — no USD in v1, per §11) + decoded data (selector + args if known ABI) + estimated fee + network
3. **Confirm row** bottom: tap-to-approve for connect / sign / send in v1; slide-to-approve for tx is M5.7 polish (custom gesture component, deferred). The vault's biometric-gated unlock (§5.1) is the auth step; signing within an unlocked session is tap-only, matching mobile-wallet convention (MetaMask, Rainbow, Trust). Idle auto-lock (M5.7) handles the "unlocked too long" case. A per-operation biometric re-prompt is a possible opt-in for the advanced-security tier.

(Origin-eligibility rules for which schemes can even reach these sheets live in §6.5.)

## 9. Integration with existing pieces

- **`BrowserTab`** (pending, M5.4): will gain `walletBridge: EthereumBridge`. Wired up at tab construction, listens on the tab's `WKUserContentController`. The bridge derives `OriginIdentity` from `BrowserTab.displayURL` at message-receive time (§6.1).
- **`FreedomApp`** ✅ constructs + injects `Vault`, `ChainRegistry`, `TransactionService` (which owns `NonceTracker` + `GasOracle` internally). `WalletRPC` is exposed lazily via `ChainRegistry.walletRPC`. `PermissionStore` lands in M5.4 alongside the bridge. Auto-lock on app background fires `vault.lock()` from `ContentView`'s scenePhase observer. `TODO: Keychain in M4` at `FreedomApp.swift:72` (Swarm bootnode password) is unrelated rot, still open.
- **`SettingsStore`**: not extended yet. `WalletDefaults.activeChainID` ( `@AppStorage`) covers the one persisted wallet preference in v1; `walletIdleLockMinutes` + `walletRequireBiometric` are M5.7.
- **`ContentView`** ✅ adds a `creditcard.fill` toolbar button that presents `WalletSheet`. `Info.plist` declares `NSFaceIDUsageDescription` so iOS permits Face ID instead of silently falling back to passcode.

### 9.1 Why the wallet doesn't consensus-resolve RPC

**The wallet reuses `EthereumRPCPool`'s provider list and quarantine state, but not its consensus algorithm.** Two different jobs:

| Use case | Transport | Why |
|---|---|---|
| ENS resolution | **M-of-K consensus wave** (`QuorumWave`) with anchor-corroborated block | A single lying RPC can forge a content-hash that sends the user to attacker-chosen content. The attack is cheap, the consequence is catastrophic. |
| Wallet reads / tx broadcast | **Single-shot with fallback** (`WalletRPC`) — first available provider, next on transport / malformed-envelope failure or non-deterministic RPC quirk; short-circuits on EIP-474 reverts, `-32602`, and `insufficient funds` (matches desktop `provider-manager.js`, `quorum: 1`) | A lying RPC can report a wrong balance or wrong gas estimate. Wrong balance is noticed by the user; wrong gas estimate makes the tx revert, not execute maliciously. Transport/malformed failures feed pool quarantine; JSON-RPC error envelopes don't (the provider responded correctly per spec, the answer just isn't useful). |

Running a K-wide consensus per `eth_call` would mean 3-5 RPCs for every balance poll a dapp does. That's slow and wasteful for a risk profile that doesn't warrant it. `WalletRPC.swift` shares the pool's `availableProviders()` list and walks it sequentially, distinguishing protocol-deterministic answers (which short-circuit) from provider quirks (which iterate).

`eth_sendRawTransaction` specifically: broadcast to one provider; the tx hash we get back is the one we show the user. If the first provider errors, fall through to the next. We don't fan out to all providers in parallel — redundant broadcasts are fine for propagation but create UX weirdness ("which provider's hash do we display?") for no real benefit.

- **`ENSResolver`** ✅ (WP14, WP18): forward and reverse lookup with CCIP-Read on both. `resolveAddress(name:)` calls `addr(bytes32)` through the same `QuorumWave` consensus pipeline as the browser's contenthash path — same threat model (ENS-forge), same M-of-K verification, forward CCIP retry already shipped. `reverseResolve(address:)` is single-shot via the Universal Resolver's `reverse(bytes,uint256)`, iterating the pool's providers on transport / RPC-error failure (Cloudflare's `-32603`, Ankr's missing-API-key `-32000`, etc.) so a single flaky RPC doesn't poison the cache; only an empty `primary` after a successful response is a definitive nil. UR self-verifies forward(name) == address per ENSIP-1, so reverse doesn't need its own consensus wave — it's decorative on the UI side anyway. **CCIP-Read on reverse** (WP18): when a provider's `eth_call` reverts with `OffchainLookup` (off-chain primary name like `avsa.eth` via Namestone or ENS V3 CCIP) and `settings.enableCcipRead` is on, hand off to `CCIPResolver.resolve(...)` — same gateway hop + callback eth_call the forward path uses, callback at `"latest"` (no block-pinning since reverse is decorative). On gateway failure, fall through to the next provider. CCIP-Read is on by default.

## 10. Milestones

The wallet is a first-class feature — no global feature flag. Each milestone lands as a stand-alone commit series; the earliest ones put the wallet icon in the bottom toolbar but clicking it just shows an empty "Not set up yet" state until M5.2.

**Current state (as of WP19 ship):** M5.1–M5.6 + WP12–WP19 all shipped on `feature/wagmi`. Wallet supports vault setup, user-initiated send (with ENS forward + reverse + CCIP-Read on both for the recipient field), the full EIP-1193 dapp surface — connect, sign (`personal_sign` + `eth_signTypedData_v4`), send (`eth_sendTransaction`), chain switch (`wallet_switchEthereumChain`) — active-tab-scoped connected-site UI with a per-site detail view, per-`(origin, contract, selector, chainID)` auto-approve rules (gated to value=0, non-zero selector), and slide-to-approve on `ApproveTxSheet`. CCIP-Read is on by default. WalletRPC iterates on provider-quirk RPC errors (Cloudflare/Ankr-style), short-circuits only on protocol-deterministic answers (revert, `-32602`, `insufficient funds`), and feeds quarantine only from transport/malformed failures. Remaining M5.7 WP is biometric fallbacks (WP17b, deferred). Test count: 273 passing.

- **M5.1 — Vault primitives** ✅. Mnemonic + HD derivation (WP1), Secure Enclave + Keychain three-tier storage with iCloud-synced default (WP2). BIP-39/BIP-32 vectors, Hardhat cross-check. No UI.
- **M5.2 — Wallet Home UI (read-only)** ✅. Chain registry + single-shot-with-fallback WalletRPC (WP3), create/import setup flow behind app-level biometric gate (WP4), real wallet home with Gnosis/Mainnet balance, chain picker, recovery-phrase reveal, wipe, security-level badge (WP5). Plus vault auto-lock on app backgrounding.
- **M5.3 — User-initiated send** ✅. Build → sign → broadcast → confirm-poll tx pipeline with nonce tracker + gas oracle via `eth_gasPrice` (WP6), SendFlowView + SendReviewView UI with inline pending/confirmed/timed-out progress (WP7). **Legacy (pre-EIP-1559) tx shape** — Argent's `EthereumTransaction` is legacy-only and writing type-2 RLP by hand has real bug surface; EIP-1559 + `eth_feeHistory` re-evaluated as part of M5.7 (deferred — see lineup below). **Hex recipients only in v1** — ENS forward + reverse lookup land in M5.7 WP14.
- **M5.4 — EIP-1193 bridge (read-only)** ✅. `window.ethereum` injection with EIP-6963 announce as the primary discovery path (WP8), `OriginIdentity` matching desktop `origin-utils.js` byte-for-byte, `RPCRouter` dispatching `eth_chainId` / `eth_accounts` / `net_version` / `eth_blockNumber` / `eth_getBalance` / `eth_call` through `ChainRegistry.walletRPC`. Signing + connect return 4100 until M5.5 lands the sheets.
- **M5.5 — Connect + sign** ✅. Connect flow (WP9): `DappPermission` @Model + `PermissionStore`, `ApproveConnectSheet`, bridge intercepts `eth_requestAccounts` / `enable`, emits `accountsChanged` / `connect` on grant, `chainChanged` on chain switch via `.walletActiveChainChanged` notification, `disconnect` on revoke via `.walletPermissionRevoked`; locked-vault unlock flow lives inside the sheet; connected-sites list + per-row revoke on `WalletHomeView`; tab-close resolves parked approvals as denied via fire-once `ApprovalResolver` so bridge tasks can't leak. Sign flow (WP10): `ApproveSignSheet` + `MessageSigner`, `personal_sign` (with order-tolerant + hex-vs-utf8 param decode) and `eth_signTypedData_v4` (domain + primaryType + flat-rendered message) — account-mismatch rejects with `-32602 "Invalid params"`, vault unlock is the auth gate (no biometric re-prompt per signature).
- **M5.6 — Send from dapps** ✅. WP11: bridge intercepts `eth_sendTransaction`, `TransactionParamsCoder` decodes the dapp's tx object, `ApproveTxSheet` shows recipient (EIP-55 checksum) + value + contract-call card with byte count + hex prefix + fee + total (hidden when `valueWei == 0`). Reuses the WP6 pipeline (`TransactionService.prepare` + `.send`) — `prepare` and `send` extended with a required `data:` parameter (no default — silent omission would broadcast a value-only tx). `composeQuote` skips the 3-RPC `prepare` when the dapp supplied `nonce + gasPrice + gas`. Account mismatch and chain mismatch reject with `-32602`. Bridge returns the tx hash immediately after broadcast — dapp handles its own "submitted" UI.
- **WP12 — cleanup sweep** ✅. `WalletServices` bag (vault/chainRegistry/permissionStore/transactionService) threaded through `FreedomApp` → `TabStore` → `BrowserTab` → `EthereumBridge`, dropping 3-4 params from each constructor; `SignKind` sub-enum makes `ApproveSignSheet` exhaustive over only sign kinds (routing bugs become compile errors); `Hex.isAddressShape` + `Hex.optionalBigUInt` / `optionalInt` + `Hex.Error` consolidate the three inline `0x + 40 hex` copies and the per-coder optional-helpers.
- **M5.7 — Polish**. Sequenced WPs, deferred items called out below.
  - **WP13 — `wallet_switchEthereumChain`**. `ApproveChainSwitchSheet`; auto-approve when chain matches; `4902 "Unrecognized chain"` for chains not in `ChainRegistry`.
  - **WP14 — ENS recipient resolution + reverse lookup** ✅. Forward (`vitalik.eth → 0x…`) via `addr(bytes32)` through the same `QuorumWave` consensus pipeline as content resolution; SendFlowView debounces ENS-shaped input, recipient footer shows "→ 0x…" subtitle. Reverse (`0x… → vitalik.eth`) via UR's `reverse(bytes,uint256)`, single-shot but iterating providers on transport / RPC-error failure so a flaky head-of-pool doesn't poison the cache (the cache pins only definitive answers — empty `primary` for "no name", successful `primary` for hits). Recipient footer shows symmetric "Looking up name…" spinner during reverse, then the name on hit (silent on miss). `WalletServices` grew an `ensResolver` field threaded through to the bridge + send views; `WalletHomeView` reverse-resolves the user's own address via `.task(id: address)`; bridge's `eth_sendTransaction` runs reverse in parallel with `composeQuote` (async let) so the sheet doesn't pay sequential latency. **CCIP-Read on reverse deferred** — addresses whose primary name lives off-chain (EIP-3668 OffchainLookup revert) silently show no subtitle; wiring CCIP into reverse mirrors what `CCIPResolver.swift` already does for forward content, gated behind `settings.enableCcipRead`. Tracked in §9 ENSResolver note.
  - **WP15 — Active-tab connected-site card + per-site detail view** ✅. Replaces the global "Connected sites" list from WP9 with a single card on `WalletHomeView` scoped to the active tab's origin, hidden when the active tab isn't connected (or isn't eligible per `OriginIdentity.isEligibleForWallet`). Tap pushes `ConnectedSiteDetailView`: favicon + display string + scheme label header, granted/last-used relative dates, connected account, destructive "Revoke connection" with confirmation dialog. Revoke fires `permissionStore.revoke(origin:)` which already cascades `accountsChanged: []` + `disconnect` to the live tab via `.walletPermissionRevoked`. The original WP17 ("dedicated ConnectedSitesView with bulk Disconnect-all") is absorbed — list-all-grants surfaced grants the user couldn't act on without context, the per-site view is a better fit for the rule UX. WP15 wires the layout for WP16's "auto" chip without yet rendering it (no `AutoApproveStore` to query).
  - **WP16 — Auto-approve rules** ✅. `@Model AutoApproveRule` keyed on `{origin}|{contract}|{selector}|{chainID}` (composite stored as `.unique String` since SwiftData has no native compound unique). `AutoApproveStore` mirrors `PermissionStore` (SwiftData backing + in-memory `Set<String>` for the bridge's hot path — `eth_sendTransaction` consults `matches(_:)` synchronously before parking the sheet; match → silent broadcast). Eligibility for the toggle: ≥4 data bytes, non-zero selector, `valueWei == 0` — a payable variant of an otherwise-trusted selector re-prompts. Toggle copy: "Always approve {label} on this contract" (or "this function" for unknown selectors), with a subtitle pinning selector + contract + "this site only". `ApproveTxSheet` calls `autoApproveStore.grant(offer)` on approve+toggle-on, threading the `AutoApproveOffer` end-to-end so `EthereumAddress` stays typed. `ConnectedSiteDetailView` switched from ScrollView+cards to `List` with `.insetGrouped` to get native swipe-to-delete on the rules subsection. Bridge's `broadcast(...)` helper is shared by the parked-approve and silent auto-approve paths — the latter still gas-estimates but skips reverse-lookup and the sheet park. Sign methods never auto-approve (§7 invariant). Tiny `ERC20Selectors` label map (transfer / transferFrom / approve) for legibility on common selectors.
  - **WP17a — Slide-to-approve** ✅. `SlideToApprove` SwiftUI component, `ApproveTxSheet` only (connect / sign / chain-switch stay tap-to-approve per §8). 85% drag threshold, light haptic on threshold cross, success haptic on commit, ~250ms checkmark hold then fires the action. Post-commit `Task` is cancellable on `.onDisappear` so a mid-hold sheet dismissal (swipe / app backgrounding) doesn't fire the action against a torn-down sheet. Accessibility: VoiceOver / Switch Control bypass the gesture entirely via `.accessibilityAction(named: "Approve", …)`.
  - **WP18 — CCIP-Read on reverse** ✅. `ENSResolver.fetchReverseName` detects `OffchainLookup` reverts in the RPC error envelope (`error.data` selector `0x556f1830`) and hands off to `CCIPResolver.resolve(...)` — same path the forward consensus wave uses. Callback eth_call uses `"latest"` (reverse is decorative; block-pinning isn't worth the extra RPC). Gateway failure or CCIP disabled → fall through to the next provider as if the envelope was a transient provider quirk. `enableCcipRead` default flipped from `false` → `true`. Future cleanup: `ccipRetry` and `QuorumLeg.callAndMaybeFollowCCIP` could share a `CCIPResolver.runRetry` helper, and `reverseEthCall` and `QuorumLeg.ethCallAtBlockHash` could share a block-aware `EthCallBody`. Out of WP18 scope.
  - **WP17b — Biometric fallbacks** (deferred). LAContext availability check, clearer copy when Face ID is disabled, passcode-only fallback path after 3 biometric failures. Split out from the original WP17 — slide-to-approve was self-contained UI; bio fallbacks touch vault-unlock UX and need their own scope (what does "after 3 failures" do — re-prompt? auto-lock? wipe?).
  - **WP19 — WalletRPC reliability + balance refresh fix** ✅. Two visible bugs (ETH fee estimation always failing on a 0-balance sender; balance pull-to-refresh hanging or immediately erroring) traced to a tangle of provider quirks and a SwiftUI gesture conflict. Fixes: (1) `fanOutBody` iterates URLs on transport / malformed-envelope failure but **doesn't quarantine on JSON-RPC error envelopes** — a provider returning `error: …` is transport-healthy by definition, the answer just isn't useful. (2) Short-circuits only on protocol-deterministic answers: EIP-474 execution reverts (`error.data` populated), `-32602 invalid params`, and `insufficient funds` precheck failures from `eth_estimateGas` (substring match — geth/erigon/anvil all carry "insufficient funds" in the message). (3) Cooperative cancellation via `Task.checkCancellation()` at the top of each loop iteration. (4) New typed `WalletRPC.Error.insufficientFunds(message:)` that `TransactionService.prepare` rewraps as `Error.insufficientBalance` so `SendFlowView` surfaces a real "Not enough X to cover the amount plus the network fee." instead of a generic "Check connection." (5) `WalletHomeView.refreshBalance` adds a generation token + chain snapshot to discard stale terminal writes (e.g., from a tab-switch racing with a button-tap). (6) Pull-to-refresh removed and replaced with a small `arrow.clockwise` button in the balance card header — `.refreshable` inside an iOS sheet has a gesture-arbiter conflict with drag-to-dismiss that cancels the refresh task before it can complete. Pre-fix the cancellation manifested as either stuck `.loading` (with the old `Task.isCancelled` guard) or immediate `.failed` (without it); the button eliminates the gesture path entirely.
  - **Deferred — EIP-1559 fee-tier picker**. The legacy `gasPrice` path exists only because Argent's `EthereumTransaction` is legacy-only; building a fee-tier UX on legacy compounds the debt. Gating task: evaluate Swift libraries with type-2 RLP (`viem-swift` evolution worth re-checking later) or roll our own type-2 encoder with a Hardhat-cross-checked vector test rig. Returns to the lineup once the wire format is in shape — `eth_feeHistory` percentiles + slow/normal/fast picker land at the same time.
  - **Deferred — `idle-lock-while-foregrounded` timer**. Background lock (already shipped) is the v1 security floor; foreground idle-lock would resume on any wallet UI / gated dapp op anyway, so the marginal security gain is small relative to the implementation + UX cost. Out of v1 scope.
  - **Deferred — stable dapp-facing error messages**. Bundle with telemetry / Sentry work post-M5.
  - **Deferred — `ApproveTxSheet` full ABI decode**. Desktop doesn't decode either (only shows raw selector); matching that for v1 is sufficient. Optional WP15 ERC-20 selector-label map covers the legibility gap on common selectors.

Each milestone gets its own commit series and /simplify pass.

## 11. Decisions

Settled 2026-04-23:

- **Default chain**: **Gnosis**. Mainnet is pre-added so one-tap `wallet_switchEthereumChain` works, but we surface Gnosis first — matches the overall Freedom posture (cheap, fast, where the ecosystem lives). Most dapps default to Mainnet; the cost of the user tapping switch once on first encounter is outweighed by the benefit of Gnosis-first for the long-tail flow.
- **Fee display unit**: **native only** (ETH / xDAI). No USD in v1 — a price feed is another RPC and another trust question. Revisit when we have a trusted source.
- **Mnemonic length**: **24 words** (matches desktop). The user should never see it unless they explicitly ask. The point of 24 over 12 isn't usability — it's that the user never handles it at all: iCloud Keychain + Face ID automates backup away (§5.3), the same "quick option" the desktop macOS app offers. "Show recovery phrase" remains available in settings for users who want belt-and-braces off-device backup.
- **Multi-account**: **single account in v1** (the main user wallet at `m/44'/60'/0'/0/0`). Additional accounts would derive at `m/44'/60'/{i}'/0/0` for `i ≥ 1` — plumbing ready, UI not. See §5.1 for the full path reservation table.
- **EIP-5792 batch calls (`wallet_sendCalls`)**: **not in v1**. Interesting but early; dapp adoption is thin. Revisit when we see a real dapp that wants it.
- **Testnet support**: **not in v1**. Once custom-chain plumbing exists, a user can add Sepolia by hand — no reason to ship it baked in.
- **WalletConnect as a client** (scan a QR on desktop, sign from iOS): **out of scope**. Our iOS app *is* the wallet. Being a WalletConnect signer for other browsers is a whole different feature, maybe later.

## 12. Open risks

- **Secure Enclave ECC key gating on older hardware**: devices without Secure Enclave (there aren't many supported iOS 17+ ones, but we should confirm) would need to fall back to Keychain-only biometric gating. Needs a capability check at setup.
- **WKWebView → WKScriptMessageHandler async throughput**: every dapp RPC crosses the JS/Swift boundary. For heavy read-heavy dapps this could be slow. Mitigation: bypass the bridge for pure reads that don't require auth — run them in JS against a `window.ethereum.request` that proxies to `fetch` against our RPC (if we expose a bounded proxy endpoint). Probably over-engineering for v1.
- **ENS-name send + on-chain race**: if the user sends to `foo.eth` and the content-hash rotates between resolution and tx-sign, we've resolved the *address* not the content — this is fine, address rotation isn't a threat. Just noting for clarity.
- **Biometric-less users**: a non-trivial fraction of users disable Face ID / Touch ID. The `.userPresence` ACL accepts passcode as a fallback, so they still get the gate — but the UX of "enter your device passcode" pops up where other users tap once.
- **No-passcode devices**: the store path silently falls back to `.deviceBound` (§5.3). Users lose iCloud backup. Need to surface the trade-off clearly at setup — a once-per-lifetime nudge, not a blocking error.
- **`.userPresence` ACL propagation**: documented iOS behavior is that access-control flags apply on the device the item is read from, even when the item was synced via iCloud Keychain. Worth confirming on a real second device during M5.2 — if the ACL isn't enforced on the receiving device, iCloud Keychain encryption is still in place but we'd want to add a LAContext-gated re-derivation step.

---

**Next action**: decide on the open questions in §11, then start on M5.1.
