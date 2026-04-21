# Freedom Browser — iOS

A native iOS browser for websites hosted on the [Swarm](https://ethswarm.org) decentralized storage network. Every page is retrieved peer-to-peer over libp2p/QUIC by a full [bee](https://github.com/ethersphere/bee) light node embedded inside the app — no HTTP gateway, no remote proxy.

> **Status: pre-alpha.** Developer-only. Loads Swarm-hosted SPAs end-to-end on simulator and device with per-site origin isolation. Missing: browser chrome (tabs, history, bookmarks), keychain-backed key management, background-execution strategy, signing flow, App Store readiness. See [docs/architecture.md](docs/architecture.md) for the full picture and roadmap.

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

## Building

This repo is **not** clone-and-build — the `SwarmKit` package references `Mobile.xcframework` by a relative path into a sibling repository. You need both checkouts present:

```
<parent-dir>/
├── bee-lite-java/        ← https://github.com/flotob/bee-lite-java  (branch: ios-build-target)
│   └── build/Mobile.xcframework     ← built locally via `make build-ios`
└── swarm-mobile-ios/     ← this repo
    └── Freedom/          ← the Xcode project
```

Quick recipe (see [docs/architecture.md § 6](docs/architecture.md) for the full version):

```bash
# Toolchain (one-time)
brew install go
go install golang.org/x/mobile/cmd/gomobile@latest
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Clone both repos side by side
cd <parent-dir>
git clone -b ios-build-target git@github.com:flotob/bee-lite-java.git
git clone git@github.com:flotob/swarm-mobile-ios.git

# Build the xcframework (first run ~20 min)
cd bee-lite-java
export PATH="$HOME/go/bin:$PATH"
make build-ios

# Open and run
cd ../swarm-mobile-ios/Freedom
open Freedom.xcodeproj
# ⌘R
```

We'll switch to URL-based binary targets with a checksummed GitHub Release artifact later (see [architecture.md § 7 M5](docs/architecture.md)), which removes the cross-repo-on-disk requirement.

## Docs

- [**architecture.md**](docs/architecture.md) — full end-to-end picture: repo layout, gomobile build pipeline, the gotchas we hit, SwarmKit design, productization roadmap, operating notes.
- [**bootnode-resolution.md**](docs/bootnode-resolution.md) — why DoH is on the startup path, what we ship today, and the migration path to get off the Cloudflare dependency.

## Status of embedded features

| | Works on Simulator | Works on device |
|---|---|---|
| Node start in ultra-light mode | ✅ | ✅ |
| Connect to Swarm peers | ✅ | ✅ (via DoH-resolved bootnodes) |
| Load a Swarm-hosted SPA | ✅ | ✅ |
| Relative `/bzz/<ref>/` dynamic fetches from JS | ✅ | ✅ |
| Per-site origin isolation | ✅ | ✅ |
| Emoji rendering | ⚠️ simulator font gap | ✅ |

## License

TBD.
