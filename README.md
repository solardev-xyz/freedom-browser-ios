# Freedom Browser — iOS

A native iOS browser for websites hosted on the [Swarm](https://ethswarm.org) decentralized storage network. Every page is retrieved peer-to-peer over libp2p/QUIC by a full [bee](https://github.com/ethersphere/bee) light node embedded inside the app — no HTTP gateway, no remote proxy.

> **Status: pre-alpha.** Internal TestFlight distribution is live. Loads Swarm-hosted SPAs and resolves ENS names end-to-end on simulator and device, with per-site origin isolation, multi-tab browsing, and history/bookmarks. Missing before a public beta: Keychain-backed node key management, background-execution strategy, external TestFlight (privacy policy + Beta App Review), custom error pages. See [docs/architecture.md](docs/architecture.md) and [docs/ens-resolution.md](docs/ens-resolution.md) for the full picture and roadmap.

## How it works

```
Freedom (iOS app, SwiftUI)
       │ import SwarmKit
       ▼
SwarmKit (local Swift Package)
       │ .binaryTarget
       ▼
bee-lite-java → Mobile.xcframework (embeds the Go bee node)
```

1. On launch the app resolves the Swarm mainnet bootnode list from DNS TXT records (via Cloudflare DoH — see [docs/bootnode-resolution.md](docs/bootnode-resolution.md)), falls back to a shipped list if needed.
2. The embedded bee node starts in ultra-light mode, connects to peers.
3. A `WKURLSchemeHandler` for `bzz://` translates every request the `WKWebView` makes into a call on bee's local HTTP API (`http://127.0.0.1:1633`), so relative asset paths, sub-page links, and dynamic `fetch('/bzz/<ref>/')` calls all resolve correctly.
4. Origin isolation is preserved: `bzz://<siteHash>/` is the page origin; cookies, `localStorage`, and service workers stay scoped per Swarm site.
5. Typing an ENS name (bare `vitalik.eth`, `ens://foo.eth`, or `https://foo.eth`) triggers an **M-of-K consensus resolution** against public Ethereum RPCs: K parallel calls to the ENS Universal Resolver at a corroborated block hash, requiring M byte-identical responses before loading the resulting `bzz://<contenthash>`. Disagreements surface an interstitial rather than silently loading attacker-selected content. See [docs/ens-resolution.md](docs/ens-resolution.md).

## Building

Clone, open in Xcode, build. `Mobile.xcframework` (the embedded bee node) is fetched automatically by SPM from a pinned, SHA256-verified GitHub Release — no cross-repo checkout needed.

```bash
git clone git@github.com:solardev-xyz/freedom-browser-ios.git
cd freedom-browser-ios/Freedom
open Freedom.xcodeproj
# ⌘R
```

On first resolve, SPM downloads `Mobile.xcframework.zip` (~111 MB zipped, 304 MB unzipped) from [solardev-xyz/bee-lite-java releases](https://github.com/solardev-xyz/bee-lite-java/releases) and caches it per toolchain. Subsequent builds reuse the cached artifact.

**Rebuilding the xcframework** is only needed if you're touching the Go code in [solardev-xyz/bee-lite-java](https://github.com/solardev-xyz/bee-lite-java) (branch `ios-build-target`). See [docs/architecture.md § 6](docs/architecture.md) for the gomobile pipeline + release-cut steps.

## Docs

- [**architecture.md**](docs/architecture.md) — full end-to-end picture: repo layout, gomobile build pipeline, the gotchas we hit, SwarmKit design, productization roadmap, operating notes.
- [**ens-resolution.md**](docs/ens-resolution.md) — the M-of-K consensus resolution pipeline: threat model, anchor corroboration, trust tiers, CCIP-Read handling, settings.
- [**bootnode-resolution.md**](docs/bootnode-resolution.md) — why DoH is on the startup path, what we ship today, and the migration path to get off the Cloudflare dependency.

## Status of embedded features

| | Works on Simulator | Works on device |
|---|---|---|
| Node start in ultra-light mode | ✅ | ✅ |
| Connect to Swarm peers | ✅ | ✅ (via DoH-resolved bootnodes) |
| Load a Swarm-hosted SPA | ✅ | ✅ |
| Relative `/bzz/<ref>/` dynamic fetches from JS | ✅ | ✅ |
| Per-site origin isolation | ✅ | ✅ |
| ENS resolution (M-of-K consensus + anchor corroboration) | ✅ | ✅ |
| CCIP-Read (EIP-3668) offchain resolvers | ✅ (setting OFF by default) | ✅ (setting OFF by default) |
| Multi-tab browsing, history, bookmarks, favicons | ✅ | ✅ |
| Emoji rendering | ⚠️ simulator font gap | ✅ |

## License

TBD.
