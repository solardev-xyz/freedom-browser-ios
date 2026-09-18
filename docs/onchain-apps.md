# Contract-hosted applications (ERC-8244) on iOS

Freedom iOS loads draft [ERC-8244](https://ethereum-magicians.org/t/erc-8244-contract-hosted-application-html/28407) apps: a whole document that lives in contract storage on an EVM chain, read with one `eth_call` of `html()` (`0x33c34ac3`), with no HTTP gateway and no page-selected RPC in the path. Desktop counterpart: `docs/protocols/onchain-apps.md` in freedom-browser (PRs #192 and #232).

Enter `web3://<contract>[:<chainId>]/` in the address bar; the chain ID defaults to Ethereum mainnet.

## URL shapes and origin

| Form | Where | Example |
| --- | --- | --- |
| friendly | address bar, history, bookmarks, approval sheets | `web3://0x00000095643CFfA7D9fae407a84dfCB6406456c6:100/swap` |
| canonical | what WebKit loads | `web3://0x00000095643cffa7d9fae407a84dfcb6406456c6.eip155-100/swap` |

`OnchainAppRef` (`Onchain/OnchainApp.swift`) parses both and produces both. The canonical hostname gives every contract-and-chain pair its own web origin for storage and permissions without putting the chain in the URL port, which the URL parser treats as a real port and WebKit's port blocklist refuses for small chain IDs. `BrowserTab.presented(_:)` maps WebKit's URL back to the friendly form for every user-facing surface.

The wallet permission key is desktop's `getPermissionKey` byte for byte: `web3://<addr>` on mainnet, `web3://<addr>:<chainId>` elsewhere, lowercase address, no path (`OriginIdentity.Scheme.web3`).

## Load path

```
BrowserURL.parse("web3://…")            → .onchain(app, path)
BrowserTab.navigate(.onchain)
 → OnchainAppLoader.load(app)           html() through Myotis → Colibri → direct pool, keeping provenance
 → verified?           → stage + load canonical URL
 → unverified          → Gate.unverifiedOnchain(document)  (ENSInterstitial)
        Continue once  → OnchainApprovals.approve(hash) → stage + load the same bytes
 → Web3SchemeHandler serves the staged document to WebKit
```

`OnchainAppLoader` (`Onchain/OnchainAppLoader.swift`) is the wallet's read ladder with the answer's source kept. The wallet's `WalletRPC.fanOut` strips it; the gate needs it. Verified sources (`ChainRegistry.verifiedSources`: Myotis, Colibri) label the document verified. The chain's direct RPC pool labels it unverified and names the endpoint, quarantining dead endpoints as it walks. A revert on any tier is the contract's answer ("not an ERC-8244 app"). The decoded document is capped at 8 MiB, checked on the encoded size before decoding; the whole load has a 30 s budget. An unregistered chain fails with a pointer to the wallet's network list.

## Gate

Desktop PR #232's boundary, without its token machinery:

- **verified** (Myotis, Colibri): loads directly.
- **unverified** (direct RPC): held at the interstitial showing network, chain, contract, endpoint and the document's keccak hash. "Continue once" runs exactly the bytes already fetched and remembers chain + contract + hash for the process lifetime (`OnchainApprovals`, bounded, never persisted). Changed bytes warn again.

There is no token, header or interstitial page in the web content because the scheme handler never fetches: the only way bytes reach WebKit under a `web3:` origin is `BrowserTab` staging them after fetching and gating. A hostile page that fetches or frames `web3://…` gets a 403 (the request's main document is not the app), so there is nothing to replay and nothing to pre-approve. Documents that fall out of the per-tab staging window (8 apps) come back through the tab on the next navigation, which fetches and gates again.

Known differences from desktop: iOS has no generic `eth_call` quorum, so desktop's "RPC servers disagreed" hard-block state cannot arise, and every direct-RPC answer is unverified (iOS does not track which endpoints the user added, so desktop's "user-configured RPC passes" carve-out is not applied).

## Response policy

`Web3SchemeHandler` attaches desktop's `ONCHAIN_APP_CSP` verbatim: `default-src 'none'`, inline scripts and styles allowed, `data:`/`blob:` media allowed, `connect-src 'none'`, no frames, workers, objects, base URL changes or form posts, `frame-ancestors 'none'`, and `sandbox allow-scripts allow-same-origin allow-forms allow-modals allow-downloads` so the contract+chain origin keeps app-local storage while popups and scripted top-level navigation are denied. Plus `Permissions-Policy` denying device capabilities, `nosniff`, `no-referrer`, `X-Frame-Options: DENY`, and no CORS headers (nothing cross-origin may read app bytes).

`OnchainAppPolicyTests` loads a staged document in a real `WKWebView` and checks that the inline script ran, `fetch` was denied, `location.origin` is the canonical host and `localStorage` works. `Web3SchemeHandlerTests` covers the request-shape refusals.

Page-created windows (`window.open`, `target=_blank`) return nothing for an onchain app. Genuine link clicks to other schemes leave the app normally; leaving the `web3:` origin clears the pinned chain and the shield.

## Wallet

The app gets the normal EIP-1193 / EIP-6963 provider. `OnchainChainPin`, shared between the tab and its `RPCRouter`, pins the chain to the one in the origin: `eth_chainId`, reads, gas estimates, signing and the `connect` event all use it, whatever the wallet's global active chain is. `wallet_switchEthereumChain` to another chain is refused (4200 with an explanation); global chain changes don't emit `chainChanged` into a pinned app. Each contract-and-chain pair has its own grants.

## Chrome

The trust shield reuses the ENS trust vocabulary (`ENSTrust`): verified via Myotis or Colibri, unverified via a named endpoint. Its sheet adds an "Onchain app" section with network, contract, loaded-from and HTML hash. While fetching, the loading pill reads "Fetching app 0x0000…56c6 from chain…". Pull-to-refresh re-fetches `html()` so a redeployed contract is picked up and, if unverified, re-gated.

## Scope

Direct contracts exposing `html()` only. Upgrade registries and resolver discovery, optional in the ERC, are not inferred (desktop parity). Runtime provenance (an app whose code was verified but whose later reads came from an unverified RPC) is not tracked yet on either platform.

## File map

```
Freedom/Freedom/Onchain/
├── OnchainApp.swift            — OnchainAppRef (URL forms, permission key, html() decode), provenance, document, errors
├── OnchainAppLoader.swift      — provenance-keeping html() ladder, OnchainApprovals, OnchainChainPin
└── Web3SchemeHandler.swift     — staged-document handler + response policy

Freedom/Freedom/
├── BrowserURL.swift            — .onchain case, both URL shapes
├── BrowserTab.swift            — navigate(.onchain), fetch-first gate, staging, pinned chain, presented(_:)
├── ENSInterstitial.swift       — Gate.unverifiedOnchain rendering
├── TrustShield.swift           — "Onchain app" section
└── Wallet/Bridge/{OriginIdentity,RPCRouter,EthereumBridge}.swift — web3 origin, pinned chain, switch refusal

Freedom/FreedomTests/
├── OnchainAppRefTests.swift, OnchainAppLoaderTests.swift, Web3SchemeHandlerTests.swift,
├── OnchainAppPolicyTests.swift (real WebKit), RPCRouterTests (pinning)
```
