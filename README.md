# Freedom Browser — iOS

A native iOS browser for websites hosted on the [Swarm](https://ethswarm.org) and [IPFS](https://ipfs.tech) decentralized storage networks. Every page is retrieved peer-to-peer over libp2p/QUIC by full nodes embedded inside the app — no HTTP gateway, no remote proxy.

> **Status: pre-alpha.** Internal TestFlight distribution is live. Loads Swarm- and IPFS-hosted SPAs and resolves ENS names end-to-end on simulator and device, with per-site origin isolation, multi-tab browsing, history/bookmarks, and vault-derived node identities matching desktop Freedom. Missing before a public beta: background-execution strategy, external TestFlight (privacy policy + Beta App Review), custom error pages. See [docs/architecture.md](docs/architecture.md) and [docs/ens-resolution.md](docs/ens-resolution.md) for the full picture and roadmap.

## How it works

```
Freedom (iOS app, SwiftUI)
       │ import SwarmKit / IPFSKit
       ▼
Packages/SwarmKit (one Swift package, two library products)
       │ shared .binaryTarget (URL + SHA256)
       ▼
freedom-node-mobile → Mobile.xcframework
       (single Go runtime, embeds both bee + kubo)
```

A single combined `Mobile.xcframework` is required because two separately-bound gomobile xcframeworks cannot coexist in one iOS process — each Go runtime tries to claim the same TLS slot at module init and crashes the second one. Kubo and bee live inside one Go binary, sharing one runtime, with the iOS-side `SwarmKit` and `IPFSKit` packages exposing each node's surface independently.

1. On launch the app starts both nodes in parallel — bee (Swarm) on `:1633`, kubo (IPFS) on `:5050`.
2. Swarm bootnodes are resolved from DNS TXT records (via Cloudflare DoH — see [docs/bootnode-resolution.md](docs/bootnode-resolution.md)), with a shipped fallback list. IPFS uses kubo's autoclient routing (delegated routing + a light DHT client) by default — configurable in Settings.
3. Three custom `WKURLSchemeHandler`s — `bzz://`, `ipfs://`, `ipns://` — translate every WKWebView request into a call on the respective local HTTP gateway, so relative asset paths, sub-page links, and dynamic `fetch()` calls all resolve correctly.
4. Origin isolation is preserved per scheme: `bzz://<siteHash>/`, `ipfs://<cid>/`, and `ipns://<name>/` are each their own page origin; cookies, `localStorage`, and service workers stay scoped per site.
5. Typing an ENS name (bare `vitalik.eth`, `ens://foo.eth`, or `https://foo.eth`) triggers an **M-of-K consensus resolution** against public Ethereum RPCs at a corroborated block hash. The decoded EIP-1577 contenthash routes to `bzz://`, `ipfs://`, or `ipns://` depending on the codec; disagreements surface an interstitial rather than silently loading attacker-selected content. See [docs/ens-resolution.md](docs/ens-resolution.md).
6. Both node identities are deterministically derived from the user's BIP-39 mnemonic — the Swarm wallet via BIP-44 secp256k1 at `m/44'/60'/0'/0/1`, the IPFS PeerID via SLIP-0010 Ed25519 at `m/44'/73405'/0'/0'/0'`. Same seed phrase on iOS and desktop Freedom yields the same on-network identities on both platforms.

## Building

Clone, open in Xcode, build. `Mobile.xcframework` (the combined bee + kubo node) is fetched automatically by SPM from a pinned, SHA256-verified GitHub Release — no cross-repo checkout needed.

```bash
git clone git@github.com:solardev-xyz/freedom-browser-ios.git
cd freedom-browser-ios/Freedom
open Freedom.xcodeproj
# ⌘R
```

On first resolve, SPM downloads `Mobile.xcframework.zip` (~171 MB zipped, 533 MB unzipped) from [solardev-xyz/freedom-node-mobile releases](https://github.com/solardev-xyz/freedom-node-mobile/releases) and caches it per toolchain. Subsequent builds reuse the cached artifact.

**Rebuilding the xcframework** is only needed if you're touching the Go code in [solardev-xyz/freedom-node-mobile](https://github.com/solardev-xyz/freedom-node-mobile) (branch `ios-build-target`). See [docs/architecture.md § 6](docs/architecture.md) for the gomobile pipeline + release-cut steps.

## Docs

- [**architecture.md**](docs/architecture.md) — full end-to-end picture: repo layout, gomobile build pipeline, the gotchas we hit, SwarmKit / IPFSKit design, productization roadmap, operating notes.
- [**ens-resolution.md**](docs/ens-resolution.md) — the M-of-K consensus resolution pipeline: threat model, anchor corroboration, trust tiers, CCIP-Read handling, settings.
- [**bootnode-resolution.md**](docs/bootnode-resolution.md) — why DoH is on the startup path, what we ship today, and the migration path to get off the Cloudflare dependency.
- [**ipfs-identity-golden-vectors.md**](docs/ipfs-identity-golden-vectors.md) — byte-level expected outputs of the BIP-39 → SLIP-0010 → libp2p PrivKey / PeerID chain, captured from desktop Freedom and used to cross-validate the iOS implementation.

## Status of embedded features

| | Works on Simulator | Works on device |
|---|---|---|
| Bee node start in ultra-light mode | ✅ | ✅ |
| Kubo node start in lowpower + autoclient mode | ✅ | ? |
| Connect to Swarm peers | ✅ | ✅ (via DoH-resolved bootnodes) |
| Connect to IPFS peers | ✅ | ? |
| Load a Swarm-hosted SPA | ✅ | ✅ |
| Load an IPFS-hosted CID / IPNS name | ✅ | ? |
| Relative `/bzz/<ref>/` and `/ipfs/<cid>/` dynamic fetches | ✅ | ? |
| Per-site origin isolation (per scheme) | ✅ | ✅ |
| ENS resolution → bzz contenthash | ✅ | ✅ |
| ENS resolution → ipfs / ipns contenthash (EIP-1577 spec-grounded) | ✅ | ? |
| CCIP-Read (EIP-3668) offchain resolvers | ✅ (setting OFF by default) | ✅ (setting OFF by default) |
| Multi-tab browsing, history, bookmarks, favicons | ✅ | ✅ |
| Vault-derived bee identity (BIP-44 secp256k1) | ✅ | ✅ |
| Vault-derived IPFS identity (SLIP-0010 Ed25519, matches desktop) | ✅ | ? |
| Emoji rendering | ⚠️ simulator font gap | ✅ |

## License

TBD.
