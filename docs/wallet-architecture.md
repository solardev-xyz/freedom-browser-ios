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

New code, all under `Freedom/Freedom/Wallet/`:

```
Wallet/
├── Vault/
│   ├── Vault.swift                  ← @Observable root: locked/unlocked state, accounts
│   ├── VaultCrypto.swift            ← three-tier at-rest encryption (§5.2)
│   ├── Mnemonic.swift               ← BIP-39 (generate, validate, seed derivation)
│   ├── HDKey.swift                  ← BIP-32; see §5.1 for the exact paths we
│   │                                   reserve across user/Bee/multi-account
│   └── KeychainItem.swift           ← thin SecItem wrapper (get/set/delete)
├── Signing/
│   └── Signer.swift                 ← thin wrapper over EthereumAccount:
│                                      personal_sign / signTypedData_v4 / tx
│                                    delegates to web3.swift; exists to hold
│                                    the authZ guard ("is vault unlocked for
│                                    this origin right now?") and to zero the
│                                    key buffer after each op.
├── Bridge/
│   ├── EthereumBridge.swift         ← WKUserContentController + WKScriptMessageHandler
│   ├── EthereumBridge.js            ← injected at document-start, the window.ethereum shim
│   ├── EIP6963.js                   ← announce-provider event on load
│   ├── RPCRouter.swift              ← maps incoming method calls to handlers
│   └── OriginIdentity.swift         ← maps a BrowserTab to its permission-key
│                                       origin (see §6.1). Swift port of desktop's
│                                       shared/origin-utils.js — keep them
│                                       semantically identical so permissions
│                                       stay portable.
├── RPC/
│   └── WalletRPC.swift              ← single-shot-with-fallback over EthereumRPCPool
│                                       (not the ENS consensus wave — see §9)
├── Permissions/
│   ├── DappPermission.swift         ← @Model: origin, account, chainID, grantedAt
│   ├── PermissionStore.swift        ← check/grant/revoke, SwiftData-backed
│   └── AutoApproveRule.swift        ← @Model: origin + contract + selector + chainID
├── Transactions/
│   ├── TransactionService.swift     ← build/sign/broadcast, nonce fetch, gas estimate
│   ├── GasOracle.swift              ← eth_feeHistory + EIP-1559 fee suggestion
│   └── NonceTracker.swift           ← per-(account,chain) in-memory nonce, invalidate on error
├── Chains/
│   ├── Chain.swift                  ← id, name, rpcPool, explorer, nativeSymbol
│   └── ChainRegistry.swift          ← fixed set (Gnosis [default], Mainnet);
│                                       no dapp-added chains in v1 — see §6.3
└── UI/
    ├── WalletHomeView.swift         ← top-level: accounts, balance, receive/send buttons
    ├── VaultSetupView.swift         ← create/import mnemonic flow
    ├── VaultUnlockView.swift        ← biometric + passcode fallback
    ├── ApproveConnectSheet.swift    ← dapp → eth_requestAccounts
    ├── ApproveSignSheet.swift       ← personal_sign / signTypedData_v4
    ├── ApproveTxSheet.swift         ← eth_sendTransaction
    └── SendFlowView.swift           ← user-initiated send
```

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

**Permissions bind to the address-bar identity, not to `WKWebView.url`.** This is a subtle but critical point that desktop already got right (`src/shared/origin-utils.js`):

- User navigates to `foo.eth`. ENS resolves to `bzz://abc123.../`. **Identity is `ens://foo.eth`.**
- ENS owner rotates the content-hash to `bzz://def456.../`. **Identity is still `ens://foo.eth`.** Permissions survive rotation because the user granted them to *the name*, not to a particular hash.
- User navigates directly to `https://app.uniswap.org/pool/123`. **Identity is `https://app.uniswap.org`** — path stripped.
- User navigates to `bzz://abc123.../path/`. **Identity is `bzz://abc123`** — path stripped, raw-hash surface.

`OriginIdentity.swift` derives this from `BrowserTab.displayURL` (which already prefers `ensURL` when present, exactly for this reason — see `BrowserTab.swift:53`). The native side reads it fresh at every message-receive; the JS side never gets to supply it.

Why this matters: if we keyed permissions on `webView.url`, a user who granted Uniswap access at `ens://app.uniswap.eth` would see their grant silently break whenever the resolved `bzz://<hash>` rotated, forcing a reconnect every deploy. That's wrong-by-construction.

**iOS and desktop should produce byte-identical origin strings for the same displayed URL.** Keep the Swift and JS normalizations aligned; add round-trip tests against known desktop fixtures.

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

Hand-written, ~250 lines. The surface **matches desktop's `webview-preload-ethereum-inject.js`** — that surface was shaped by real-world dapp testing, and iOS diverging from it means some dapps that work on desktop would silently break here. Specifically we ship:

- **EIP-1193 standard**: `request({method, params})`, `on`/`removeListener`/`removeAllListeners`, events `connect` / `disconnect` / `accountsChanged` / `chainChanged` / `message`.
- **Legacy compat (still widely checked)**: `enable()` (calls `eth_requestAccounts`), `send(methodOrPayload, paramsOrCallback)` handling both forms, `sendAsync(payload, callback)`, `selectedAddress`, `networkVersion`.
- **Wallet-identity flags**: `isMetaMask: true` (pragmatic — many dapps gate features on this; we spoof to match MM's feature envelope, same as desktop), `isFreedomBrowser: true`, `isFreedom: true`.
- **Discovery signals**: EIP-6963 `announceProvider` on `eip6963:requestProvider`, and the legacy `ethereum#initialized` `Event` dispatched on window once the provider is wired up.

The deliberate refusals (below in §6.4) are *semantic*, not surface — the provider object exists and accepts calls to `eth_sign`/`eth_signTransaction`, it just rejects them with an error payload. Dapps that feature-detect by trying-and-catching get a clean signal.

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
3. **Confirm row** bottom: slide-to-approve for tx (prevents fat-finger), tap-to-approve for connect/sign. Biometric fires at approval moment, not sheet-open — so the user can inspect and dismiss without burning a biometric prompt.

(Origin-eligibility rules for which schemes can even reach these sheets live in §6.5.)

## 9. Integration with existing pieces

- **`BrowserTab`**: gains `walletBridge: EthereumBridge`. Wired up at tab construction, listens on the tab's `WKUserContentController`. The bridge derives `OriginIdentity` from `BrowserTab.displayURL` at message-receive time (§6.1).
- **`FreedomApp`**: constructs a single `Vault`, `PermissionStore`, `TransactionService`, `ChainRegistry`, `WalletRPC`, injects them into the environment. `TODO: Keychain in M4` at `FreedomApp.swift:72` (Swarm bootnode password) can ride the same Keychain plumbing we build here.
- **`SettingsStore`**: gains `walletIdleLockMinutes`, `walletDefaultChainID` (Gnosis), `walletRequireBiometric`.

### 9.1 Why the wallet doesn't consensus-resolve RPC

**The wallet reuses `EthereumRPCPool`'s provider list and quarantine state, but not its consensus algorithm.** Two different jobs:

| Use case | Transport | Why |
|---|---|---|
| ENS resolution | **M-of-K consensus wave** (`QuorumWave`) with anchor-corroborated block | A single lying RPC can forge a content-hash that sends the user to attacker-chosen content. The attack is cheap, the consequence is catastrophic. |
| Wallet reads / tx broadcast | **Single-shot with fallback** (`WalletRPC`) — first available provider, next on failure (matches desktop `provider-manager.js`, `quorum: 1`) | A lying RPC can report a wrong balance or wrong gas estimate. Wrong balance is noticed by the user; wrong gas estimate makes the tx revert, not execute maliciously. The quarantine state from the ENS path is still applied — a provider we've flagged as flaky won't be our first pick. |

Running a K-wide consensus per `eth_call` would mean 3-5 RPCs for every balance poll a dapp does. That's slow and wasteful for a risk profile that doesn't warrant it. `WalletRPC.swift` is a thin ~50-line module that shares the pool's `availableProviders()` list and walks it on error, nothing fancier.

`eth_sendRawTransaction` specifically: broadcast to one provider; the tx hash we get back is the one we show the user. If the first provider errors, fall through to the next. We don't fan out to all providers in parallel — redundant broadcasts are fine for propagation but create UX weirdness ("which provider's hash do we display?") for no real benefit.

- **`ENSResolver`**: the wallet's Send-to-ENS-name flow reuses this directly. `vitalik.eth` in the To: field resolves through the same hardened pipeline as an address-bar ENS navigation — no duplicate code path. ENS-name resolution of the recipient is the one place the wallet still uses the full consensus wave, because the threat model there *is* ENS-forge.

## 10. Milestones

The wallet is a first-class feature — no global feature flag. Each milestone lands as a stand-alone commit series; the earliest ones put the wallet icon in the bottom toolbar but clicking it just shows an empty "Not set up yet" state until M5.2.

- **M5.1 — Vault primitives** ✅. Mnemonic + HD derivation (WP1), Secure Enclave + Keychain three-tier storage (WP2). Tested against BIP-39/BIP-32 vectors and Hardhat cross-check. No UI.
- **M5.2 — Wallet Home UI (read-only)**. Create/import flow, unlock flow, show account + ETH balance + xDAI balance. No signing.
- **M5.3 — User-initiated send**. Build + sign + broadcast an EIP-1559 tx from the Wallet Home. Recipient can be address or ENS name. Gas estimate via `eth_estimateGas`, fee suggestion via `eth_feeHistory`.
- **M5.4 — EIP-1193 bridge (read-only)**. Inject `window.ethereum`. Wire up `eth_chainId`, `eth_accounts`, `eth_call`, `eth_getBalance`, `eth_blockNumber`. No signing yet. Permission store scaffolding, but no connect sheet — dapps see `eth_accounts: []` for now.
- **M5.5 — Connect + sign**. ApproveConnectSheet, ApproveSignSheet, `personal_sign`, `eth_signTypedData_v4`. Enable wallet flag by default.
- **M5.6 — Send from dapps**. ApproveTxSheet, `eth_sendTransaction`, nonce/gas pipeline. End-to-end tx on Gnosis with a live dapp.
- **M5.7 — Polish**. Auto-approve rules, chain-switch UX, connected-sites settings, idle-lock tuning, biometric failure fallbacks.

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
