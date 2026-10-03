# Freedom Browser for iOS — Security Audit

**Target:** `freedom-browser-ios` — a SwiftUI / WKWebView browser for the decentralized web, with a built-in crypto wallet, Swarm integration, and a native (FFI) IPFS client.
**Branch / commit:** `main` @ `4da76e0` (native-FFI-only IPFS transport)
**Date:** 2026-06-10
**Scope:** Full source audit of `Freedom/Freedom/` (273 Swift files, ~41k LOC) and the `Packages/SwarmKit` + `IPFSKit` Swift packages, plus `Info.plist`. The pinned `FreedomIpfs.xcframework` (v0.4.0) binary is not vendored — claims about the Rust side are cross-referenced to the `freedom-ipfs` audit.
**Method:** Five parallel subsystem reviews — (1) WKWebView/scheme-handlers/JS bridge, (2) wallet provider/signing/permissions, (3) vault/Keychain/crypto, (4) Swarm subsystem, (5) FFI consumer/networking/storage/adblock — followed by hand-verification of every Critical/High finding against the source.

---

## Executive summary

The iOS app is, like its desktop sibling, **carefully built** in most respects: CryptoKit AES-GCM with random nonces, `SecRandomCopyBytes` everywhere, a correct Secure-Enclave tier, BIP-32/39/44 + SLIP-0010 with per-chain key isolation, strict Swarm path/hex validation, native-FFI-only IPFS (no cleartext loopback gateway), bundled (not remote-fetched) adblock rules, no `NSAllowsArbitraryLoads`, no `WKUIDelegate`/`UIApplication.open` (closing the deeplink-abuse surface), and HTML-escaped error pages. Several things the desktop app got wrong are *right* here — notably `wallet_addEthereumChain` is refused (no attacker-RPC injection), and the wallet bridge is **per-tab**, so the desktop's "active address bar" background-tab confusion does **not** apply.

But the audit found **one Critical, five High, and a series of Medium/Low** issues. Two themes dominate:

1. **The same origin-confusion class as the desktop app, via a different vector.** Both the Ethereum and Swarm provider bridges inject `window.ethereum`/`window.swarm` into **every frame** (`forMainFrameOnly: false`) yet derive the requesting origin from the **top page's address bar** (`displayURL`), never from `message.frameInfo`. So a **cross-origin `<iframe>`** inside a trusted, connected dapp is attributed to the parent origin — it can read the connected account silently and trigger signing/transaction/publish/spend prompts that display the *trusted* origin (or, with auto-approve, fire with no prompt). This is **IOS-01 (Critical)**, the headline.

2. **Vault confidentiality and re-auth depend on app-layer logic, not the Keychain/Secure-Enclave hardware boundary.** The shipping default tier (`.cloudSynced`) puts the data-encryption key and the sealed seed in **iCloud Keychain** behind only a bypassable `LAContext` check (**IOS-03, High**), and the fallback tier (`.deviceBound`) requires **no re-auth at all** to unlock the wallet or reveal the 24-word recovery phrase (**IOS-04, High**).

### Findings by severity

| ID | Severity | Title |
|----|----------|-------|
| IOS-01 | **Critical** | Cross-origin iframe origin confusion in both wallet & Swarm bridges (provider injected into all frames; origin from address bar, not `frameInfo`) |
| IOS-02 | High | Transaction auto-approve binds only `(origin,contract,selector,chain)` — not spender/amount → unlimited-approval token drain |
| IOS-03 | High | Default `.cloudSynced` vault tier stores DEK + seed in iCloud Keychain behind a bypassable app-layer auth gate |
| IOS-04 | High | `.deviceBound` fallback tier requires zero re-auth to unlock vault or reveal recovery phrase |
| IOS-05 | High | `swarm.getUploadStatus({tagUid})` → `Int(Double)` trap → pre-auth remote tab/app crash (DoS) |
| IOS-06 | Medium | Custom-scheme (ipfs/bzz) responses omit `nosniff`/CSP, trust gateway `Content-Type`, and set `ACAO: *` |
| IOS-07 | Medium | `decidePolicyFor` allows `data:`/`file:`/all schemes by default; `target=_blank` loads in place |
| IOS-08 | Medium | EIP-712 approval sheet collapses domain to one field — `verifyingContract`/`chainId` hidden |
| IOS-09 | Medium | Biometric gate never checks `evaluatedPolicyDomainState` — newly-enrolled biometrics silently trusted |
| IOS-10 | Medium | Auto-lock only on `.background`; no idle timeout — seed resident through app-switcher/interruptions |
| IOS-11 | Medium | Manual custom-RPC entry performs no scheme/host validation (cleartext-HTTP downgrade / SSRF) |
| IOS-12 | Medium | IPFS block cache stored in iCloud-backed `Documents/` with no file protection / backup exclusion |
| IOS-13 | Medium | Shared global `WKWebsiteDataStore`; no per-origin/per-tab isolation; no incognito boundary |
| IOS-14 | Low | `personal_sign` of raw 32-byte hashes shown as hex with no blind-signing warning |
| IOS-15 | Low | Full IPFS/IPNS gateway paths logged `privacy: .public` (browsing history in device logs) |
| IOS-16 | Low | Bee keystore file written with no explicit file-protection class / backup exclusion |
| IOS-17 | Low | Recovery-phrase copy uses the general pasteboard (60s expiry mitigates) |
| IOS-18 | Low | FFI per-handle cancel/free race; safety depends on unverified Rust contract |
| IOS-19 | Low | Bridge replies always execute in the main frame regardless of requesting frame |
| IOS-20 | Low | Favicon fetch follows page-controlled cross-origin URL; cache keyed by host only |
| IOS-21 | Low | `readFeedEntry`/`listFeeds` unauthenticated and unrated-limited against the local node |

---

## Critical

### IOS-01 — Cross-origin iframe origin confusion in the wallet and Swarm provider bridges

**Severity:** Critical
**Files:** `Wallet/Bridge/EthereumBridge.swift:98,115` · `Swarm/Bridge/SwarmBridge.swift:99,118` · `Wallet/Bridge/OriginIdentity.swift:43` · `Wallet/UI/ApprovalComponents.swift:5-14`

Both bridges inject their provider preload into **all frames** and resolve the requesting origin from the **top document's URL**, ignoring the WebKit-attested sending frame:

```swift
// EthereumBridge.swift
forMainFrameOnly: false                                      // line 98 — injected into every iframe
let origin = OriginIdentity.from(displayURL: tab?.displayURL) // line 115 — top address bar, NOT message.frameInfo
// SwarmBridge.swift: identical pattern at lines 99 and 118
```

`message.frameInfo.securityOrigin` / `message.frameInfo.isMainFrame` are read **nowhere** in either bridge (verified by grep). So when a cross-origin `<iframe>` posts a provider request, the native side authorizes it against the **parent page's** origin, connection grant, and permissions, and the approval sheet (`ApprovalOriginStrip(origin: approval.origin)`) renders the **parent** origin as the requester.

**Important scoping (what is and isn't vulnerable):**
- **Background tabs are NOT vulnerable** — there is one bridge instance per `BrowserTab`, each closed over its own `displayURL`, so a background tab acts only as its own origin. This is genuinely better than the desktop app's shared "active address bar" model (desktop FB-01).
- **Cross-origin iframes ARE vulnerable** — this is the iOS incarnation of the same origin-confusion class.

**Exploit.** A trusted dapp `app.example` (connected; account granted; possibly with a tx/publish auto-approve grant) embeds — or is induced via a sub-frame XSS to embed — `<iframe src="https://evil.example">`. The iframe runs `window.ethereum`/`window.swarm` and:
- calls `eth_accounts` → silently reads the connected wallet address (no prompt — `RPCRouter.swift:64`);
- calls `personal_sign` / `eth_signTypedData_v4` / `eth_sendTransaction` / `swarm.publishData` / `writeFeedEntry` → the user sees a prompt attributed to **app.example** (the trusted origin), defeating the origin-based trust decision; and
- if the parent origin has an auto-approve grant (IOS-02), the malicious iframe's transaction / publish / stamp-spend executes with **no prompt at all**, under the parent's identity.

A related correctness defect (IOS-19): bridge replies are delivered via `evaluateJavaScript` with no frame argument (`BridgeReplyChannel.swift:49`), so they run in the main frame — but the **side effect (signature, broadcast, publish, capacity spend) has already occurred** before the promise fails to resolve in the iframe.

**Fix.** In both `userContentController(_:didReceive:)`, derive the origin from `message.frameInfo.securityOrigin` and require `message.frameInfo.isMainFrame == true` (reject privileged methods from sub-frames, or key permissions on the sub-frame's own distinct origin). Inject the provider `forMainFrameOnly: true` unless sub-frame dapps are an explicit requirement. Pass the true sender origin into the approval sheet and reply to the originating frame via `evaluateJavaScript(_:in:contentWorld:)`. Apply identically to `EthereumBridge` and `SwarmBridge`.

---

## High

### IOS-02 — Transaction auto-approve binds only the selector, not the arguments

**Severity:** High
**Files:** `Wallet/Permissions/AutoApproveRule.swift:42` · `Wallet/Bridge/ApprovalRequest.swift:76-101` · `Wallet/Bridge/EthereumBridge.swift:313-329`

The auto-approve rule key is `(origin, contract, selector, chainID)` with no calldata-argument binding; eligibility only requires `valueWei == 0` and a non-zero 4-byte selector, and the labeled selectors include `approve(spender,amount)` (`0x095ea7b3`), `transfer` (`0xa9059cbb`), and `transferFrom` (`0x23b872dd`). Once the user ticks "always approve … on this contract" for a token, **any** later `approve` to that token auto-fires with no sheet — and the dapp controls `spender` and `amount`.

**Exploit.** User approves a benign `approve(goodRouter, 100)` and enables auto-approve. The site (or, via IOS-01, an iframe attributed to it) submits `approve(attacker, 2^256-1)` to the same token → silent unlimited allowance → full token drain. `transfer(attacker, balance)` works identically.

**Fix.** Exclude `approve`/`transferFrom`/`setApprovalForAll`/`transfer` from auto-approve eligibility, or bind the rule to decoded arguments (exact spender/recipient + a max-amount cap) and re-prompt outside that envelope.

### IOS-03 — Default `.cloudSynced` vault tier stores the seed in iCloud Keychain behind a bypassable gate

**Severity:** High
**Files:** `Wallet/Vault/VaultCrypto.swift:48,82-95` · `Wallet/Vault/KeychainItem.swift:85-91`

The shipping default is `preferred: VaultSecurityLevel = .cloudSynced` (`VaultCrypto.swift:48`). In that tier the raw AES data-encryption key (DEK) **and** the AES-GCM-sealed mnemonic blob are stored with `kSecAttrAccessibleWhenUnlocked` + `kSecAttrSynchronizable: true` — i.e. they **sync to iCloud Keychain and enter iCloud escrow/backup**. iCloud-synced items cannot carry a `SecAccessControl`, so the *only* thing gating the DEK read is an app-layer `LAContext.evaluatePolicy` call (`if resolvedLevel == .cloudSynced { try await prompter.prompt() }`). That check is pure app logic: on a jailbroken device, a re-signed binary, or any direct Keychain read, it is simply skipped and `dekBytes = storedDek` decrypts the seed.

**Impact.** By default, the app's highest-value secret reduces to **Apple-ID/iCloud security** (exfiltratable via Apple-ID compromise) and is unprotected by hardware on a compromised device.

**Fix.** Do not default a seed vault to the iCloud-synced, non-hardware-gated tier. Default to `.protected` (Secure Enclave) when available, else `.deviceBound`; make `.cloudSynced` an explicit, clearly-labeled opt-in. If cloud backup must remain, additionally encrypt the seed blob under a user-supplied passphrase (Argon2/scrypt) so iCloud compromise alone is insufficient.

### IOS-04 — `.deviceBound` fallback tier requires no re-authentication

**Severity:** High
**Files:** `Wallet/Vault/VaultCrypto.swift:82-97` · `Wallet/Vault/Vault.swift:98-106`

The biometric prompt fires **only** for `.cloudSynced` (`VaultCrypto.swift:82`). On the `.deviceBound` tier (the fallback whenever the preferred tier can't be realized, including when `.cloudSynced` falls back on a passcode-less device), `load()` skips the prompt and reads the DEK in the clear. Consequently `Vault.unlock()` and **`Vault.revealMnemonic()`** succeed with **no biometric/passcode challenge** — anyone with the unlocked phone can open the wallet and reveal the 24-word phrase via Settings. The `revealMnemonic` doc comment claiming "always costs an explicit re-auth" is false for this tier.

**Fix.** Make `prompter.prompt()` unconditional on every `load()` path (it is the only auth on `.deviceBound`), and force a fresh prompt specifically before revealing the recovery phrase regardless of tier. For `.deviceBound`, use `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` + a `SecAccessControl(.userPresence)` so the Keychain enforces presence in hardware.

### IOS-05 — `tagUid` from web content triggers a trapping `Int(Double)` conversion (remote DoS)

**Severity:** High
**Files:** `Swarm/Bridge/SwarmBridge.swift:698` → `Swarm/API/BeeAPIClient.swift:357`

```swift
// BeeAPIClient.intFromAnyJSON
if let double = value as? Double { return Int(double) }   // line 357 — TRAPS on huge / Infinity / NaN
```

`swarm_getUploadStatus` passes the page-supplied `params["tagUid"]` straight into this helper (`SwarmBridge.swift:698`). WKWebView bridges large/fractional JS numbers as `Double`, and `Int(1e30)` / `Int(.infinity)` / `Int(.nan)` is a **trapping** conversion → fatal runtime error → content-process/app crash. Reachable from any eligible origin (and, via IOS-01, any iframe) with no connection/permission: `window.swarm.getUploadStatus({ tagUid: 1e30 })`.

**Fix.** Use a range-guarded failable conversion: `if let d = value as? Double, d.isFinite, d >= Double(Int.min), d <= Double(Int.max) { return Int(d) }` — or `Int(exactly:)` on the `NSNumber`. Audit the other `Int64`/`String` branches similarly.

---

## Medium

### IOS-06 — Custom-scheme responses lack `nosniff`/CSP, trust gateway `Content-Type`, and set `ACAO: *`
**Severity:** Medium · **Files:** `BzzSchemeHandler.swift:152-160` · `IpfsSchemeHandler.swift:70-76,759-783`
Neither scheme handler sets `X-Content-Type-Options: nosniff` or any CSP, and both forward the gateway/Bee `Content-Type` verbatim while overlaying `Access-Control-Allow-Origin: *`. WebKit MIME-sniffing can promote attacker bytes to `text/html` (script execution within the content's own CID/name origin), and `ACAO: *` lets any dweb page read any other CID's bytes/feed headers. This is the iOS analogue of desktop **FB-05** and freedom-ipfs **FI-03** — the same missing-hardening pattern across all three codebases. *Fix:* always add `nosniff`; add a restrictive default CSP for dweb content; reconsider `ACAO: *`; don't forward a gateway-supplied `text/html` for raw reads.

### IOS-07 — Navigation policy allows `data:`/`file:`/all schemes; `target=_blank` loads in place
**Severity:** Medium · **File:** `BrowserTab.swift:860-887`
`decidePolicyFor` special-cases only ENS and ipfs/ipns and then `decisionHandler(.allow)` for everything else, every frame — including top-level `data:text/html` (origin-less script context for address-bar-spoof phishing) and `file:`. `navigationAction.targetFrame == nil` falls through to `.allow`, so `target=_blank` clicks silently replace the current page. *Mitigating:* no `WKUIDelegate`/`UIApplication.open`, so external deeplinks aren't forwarded, and WebKit blocks `javascript:` itself. *Fix:* allowlist navigable schemes (`http(s)`, `bzz`, `ipfs`, `ipns`, `ens`, `about:blank`); `.cancel` `file:`/top-level `data:`/unknown app schemes; handle `targetFrame == nil` deliberately.

### IOS-08 — EIP-712 approval sheet hides `verifyingContract` and `chainId`
**Severity:** Medium · **File:** `Wallet/UI/ApproveSignSheet.swift:166-175`
`formatDomain()` returns the first of `name` → `verifyingContract` → `chainId`, so the sheet's "Domain" row shows only the attacker-chosen `name` (e.g. "USD Coin") while the security-critical `verifyingContract`/`chainId` are not shown. A malicious Permit2/permit can name-spoof while pointing `verifyingContract` at an attacker contract. (The full message JSON *is* shown — good — but the domain separator is where the spoof lives.) *Fix:* render `name`, `verifyingContract`, and `chainId` as separate rows; flag when `domain.chainId` ≠ active chain; warn on `Permit`-family primaryTypes.

### IOS-09 — Biometric gate never checks `evaluatedPolicyDomainState`
**Severity:** Medium · **File:** `Wallet/Vault/BiometricPrompter.swift:12-35`
A fresh `LAContext` is used per prompt but `evaluatedPolicyDomainState` / `.biometryCurrentSet` is never compared to a baseline, so an attacker who knows the passcode and enrolls a new Face/fingerprint is silently trusted. *Fix:* persist `evaluatedPolicyDomainState` (device-only) on first unlock and require passcode + warn on change; for the SE `.protected` tier use the `.biometryCurrentSet` ACL flag.

### IOS-10 — Auto-lock only on `.background`; no idle timeout
**Severity:** Medium · **Files:** `ContentView.swift:215-233` · `Vault.swift:65-68`
The vault zeroes its seed only on `.background`, not `.inactive`, and there is no inactivity timer, so the decrypted seed stays in memory through control-center/notification/app-switcher and indefinitely while foregrounded. Combined with IOS-04 (no re-auth on `.deviceBound`) an unlocked session is broadly exposed. *Fix:* add an idle timeout (record resign-active time, relock on resume past N minutes); keep the `.background` lock.

### IOS-11 — Manual custom-RPC entry has no URL validation
**Severity:** Medium · **Files:** `Wallet/.../ChainRPCDetailView.swift:76-92` → `Wallet/Chains/ChainStore.swift:62`
Unlike the chainlist import path (which enforces scheme and rejects `${API_KEY}` placeholders), the manual "add provider" field appends any string. A user can be social-engineered into a cleartext `http://` endpoint (on-path attacker reads address↔balance queries and can return forged gas/nonce to grief tx construction) or an SSRF target (`http://169.254.169.254/...`); `WalletRPC` does not enforce TLS. *Fix:* require `https` (allow `http` only for loopback) and reject non-loopback private/link-local hosts at the store boundary.

### IOS-12 — IPFS block cache in iCloud-backed `Documents/`, no file protection
**Severity:** Medium · **File:** `Packages/SwarmKit/Sources/IPFSKit/IPFSNode.swift:159-162`
`defaultDataDir()` returns `Documents/freedom-ipfs`. The block store (from which browsed CIDs/history are reconstructable) is therefore backed up to iCloud (no `isExcludedFromBackup`) and carries no `NSFileProtection` (readable while locked on a compromised device). *Fix:* move to `Library/Caches/` (or App Support), set `isExcludedFromBackup = true`, apply `.completeUnlessOpen`.

### IOS-13 — Shared `WKWebsiteDataStore`; no per-origin isolation
**Severity:** Medium · **File:** `BrowserTab.swift:179-211`
Every tab uses the default persistent `WKWebsiteDataStore.default()`; cookies/localStorage/IndexedDB/cache are shared across all mutually-untrusted dweb sites, with no per-tab `WKProcessPool` and no `nonPersistent()` incognito boundary. *Fix:* give each tab (or top-level origin) a dedicated data store; offer a non-persistent mode.

---

## Low

- **IOS-14** — `personal_sign` of a non-UTF-8 32-byte hex payload is previewed as raw hex with only a generic caption, no blind-signing warning. (`Wallet/Bridge/PersonalSignCoder.swift:58`, `ApproveSignSheet.swift:97`). *Good:* raw `eth_sign`/`eth_signTransaction` are rejected (`RPCRouter.swift:83`). *Fix:* warn explicitly on unreadable raw-hash payloads.
- **IOS-15** — `IpfsSchemeHandler.swift:461,464` log full `/ipfs/<cid>/<path>` with `privacy: .public`, leaking browsing history into unified logs / sysdiagnose. *Fix:* drop `.public` (default redacts) or log only a CID prefix/hash.
- **IOS-16** — `BeeIdentityInjector.swift:186` writes the (encrypted) Bee keystore with the default protection class and no backup exclusion. Risk bounded by the device-only Keychain password. *Fix:* `.completeFileProtection` + `isExcludedFromBackup`.
- **IOS-17** — Recovery-phrase copy uses `UIPasteboard.general` (`RecoveryPhraseView.swift:48`); mitigated by 60s expiry + `.localOnly` and scene-phase auto-hide (good practice). *Fix:* shorten expiry / use a named pasteboard.
- **IOS-18** — `FreedomIpfsReader` is `@unchecked Sendable`; `cancelActiveNative`/`invalidate` (MainActor) can call `free()` on a per-request handle while a dispatcher worker is mid-`read()` on the same id. Safety depends on the Rust contract that per-handle `free` is safe concurrently with an in-flight `read`. The `markTerminated()`-before-free pattern narrows but doesn't fully close the window. **Cross-check:** confirm against `freedom-ipfs/docs/native-gateway-api.md`; if not guaranteed, serialize per-handle FFI calls. (Ties to freedom-ipfs FI-01/FI-13.)
- **IOS-19** — Bridge replies run in the main frame regardless of the requesting frame (`BridgeReplyChannel.swift:49`); correctness/scoping issue that compounds IOS-01. JSON-encoded replies are injection-safe (good). *Fix:* reply via `evaluateJavaScript(_:in:contentWorld:)` to the originating frame.
- **IOS-20** — `FaviconStore.swift:48-116` runs page JS and fetches the returned `href` (bounded to https/bzz; image-validated), a tracker-beacon/SSRF-to-Bee vector; cache keyed by bare host. *Fix:* restrict to same-origin; key by scheme+host.
- **IOS-21** — `swarm_readFeedEntry`/`listFeeds` are intentionally unauthenticated (public data) but unrate-limited against the local node, allowing a page to issue unbounded reads. *Fix:* lightweight per-origin rate limit.

---

## Strong practices observed (preserve these)

- **No `allowFileAccessFromFileURLs`/`allowUniversalAccessFromFileURLs`; no `NSAllowsArbitraryLoads`; no `WKUIDelegate`/`UIApplication.open`** — untrusted content can't read local files, downgrade TLS, or trigger external-app deeplinks.
- **`wallet_addEthereumChain` refused** (`RPCRouter.swift:83`) and `wallet_switchEthereumChain` limited to already-stored chains — the desktop FB-style attacker-RPC injection is **not present**. RPC URLs come only from seeded defaults or user edits, never dapp input.
- **Per-tab bridge instances** keyed to each tab's committed URL — the desktop's background-tab "active address bar" confusion does not apply (only the iframe vector remains, IOS-01).
- **Wallet correctness:** `matchesGrantedAccount` binds the tx `from` to the connected account (no cross-account signing); single in-flight approval (no stacking races); chainId mismatch rejected pre-sign; plaintext-`http`/`ipfs`/`rad` origins refused wallet access.
- **Crypto/Keychain done right where used:** CryptoKit `AES.GCM.seal` (random nonces, authenticated); all key/salt/nonce/mnemonic randomness via `SecRandomCopyBytes`; Secure-Enclave `.protected` tier with `.userPresence` + `WhenUnlockedThisDeviceOnly`; device-only items `...ThisDeviceOnly` + `synchronizable:false`; BIP-39 PBKDF2-SHA512/2048 + NFKD; per-coin-type key isolation (user/Bee/publisher/IPFS); recovery screen hides words on `scenePhase != .active`; no secret logging (except IOS-15's path).
- **Swarm input hygiene:** strict path validation (rejects `..`/`.`/leading-`/`/backslash/control chars, UTF-8 byte-cap), strict fixed-length hex for owner/topic (no path injection into Bee URLs), size/count caps before allocation, `name` percent-encoded via `URLComponents`, Bee client hardcoded to `127.0.0.1:1633` (no SSRF from the bridge), per-origin tag ownership.
- **Scheme handlers** carefully avoid use-after-stop / double-completion via `NativePending` state flags under a lock; error-page HTML fully escaped; FFI returns null-checked (no force-unwraps); `exportCar` validates pointer+length.
- **FFI consumer** lifecycle (generation counter, dispatcher tombstone/stash, post-`await` teardown guards) is well-engineered — no use-after-free/double-free of the node handle found.
- **Native-FFI-only IPFS** (no loopback HTTP gateway) eliminates the cleartext-loopback surface entirely; **bundled adblock** rules (no runtime remote-list fetch → no rule-injection/ReDoS); chainlist import validates scheme and rejects placeholder/tracking URLs; scoped permission strings (FaceID, local network for p2p) with no over-broad background modes or inbound URL schemes.

---

## Recommended remediation order

1. **IOS-01** (Critical) — origin from `message.frameInfo` + main-frame-only injection in both bridges; show the true sender origin in approval sheets; reply to the originating frame. Resolves the security core of IOS-19 too.
2. **IOS-03 + IOS-04** — make the biometric prompt unconditional in `load()`, force re-auth before revealing the phrase, and demote `.cloudSynced` from the default. Both stem from auth living in app logic instead of on the Keychain/SE item.
3. **IOS-02** (auto-approve argument binding) and **IOS-05** (one-line `tagUid` DoS fix).
4. **IOS-06** (`nosniff`/CSP/CORS) and **IOS-07** (scheme allowlist).
5. Remaining Mediums (IOS-08–IOS-13) and Lows.

---

## Scope & limitations

- Reviewed `main` only; static review plus hand-verification of every Critical/High against the source. **No dynamic testing** (no device run, no live dapp/iframe exploitation) was performed — recommended to confirm IOS-01's iframe attribution and IOS-05's crash on-device.
- The `FreedomIpfs.xcframework` v0.4.0 C header is a pinned binary not vendored here; IOS-18's residual race and the UTF-8/NUL FFI assumptions must be confirmed against the `freedom-ipfs` native-gateway contract.
- No automated dependency/SCA scan of the Swift package graph was performed.

---

## Appendix — cross-codebase patterns (all three audits)

Two systemic issues recur across the desktop app, the Rust IPFS client, and this iOS app — worth fixing as shared design decisions, not one-offs:

1. **Provider-bridge origin confusion.** The injected wallet/Swarm provider determines the authorizing origin from a renderer/UI-supplied value (desktop: the active address bar — **FB-01, Critical**; iOS: the top-frame `displayURL`, exploitable via iframes — **IOS-01, Critical**) instead of the authenticated frame the request came from. Both ignore an authoritative origin that is already available (`event.senderFrame` / `message.frameInfo`). The correct pattern already exists in-repo on each platform (desktop's Swarm provider uses `getDisplayUrlForWebview`; iOS could use `frameInfo`). **Fix the origin authority at the native boundary on both platforms.**
2. **No CSP / `nosniff` on rendered decentralized content.** The dweb content path ships without a baseline CSP or MIME-sniffing protection in all three: desktop protocol handlers (**FB-05**), the Rust gateway (**FI-03**), and the iOS scheme handlers (**IOS-06**). Add `X-Content-Type-Options: nosniff` and a restrictive default CSP wherever ipfs/ipns/bzz responses are produced, and pursue per-CID origin isolation.

Beyond those, the **wallet auto-approve / blind-signing** weaknesses (desktop FB-02; iOS IOS-02/IOS-08/IOS-14) and the **local-daemon/RPC SSRF** family (desktop FB-06/FB-13; freedom-ipfs FI-02; iOS IOS-11) are parallel and should be hardened with a consistent policy (argument-bound approvals; reject loopback/private/link-local targets derived from untrusted input).
