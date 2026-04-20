# Freedom Browser — Architecture & Development Journal

Snapshot of the iOS Freedom Browser codebase as of the M2 commit (`73efa98`).
This document exists so the next person (or future-you) can pick up the thread without rebuilding context from scratch. It covers:

1. What the product is and how the pieces fit together
2. Every non-obvious engineering decision made so far, and why
3. What's missing before this can ship to users

---

## 1. What Freedom Browser is

A native iOS app that browses websites hosted on the [Swarm](https://ethswarm.org) decentralized storage network. There is no remote gateway — the app embeds a full Bee (Swarm) light node inside the app process. A user navigating to `bzz://<hash>/index.html` pulls content peer-to-peer over libp2p/QUIC from the Swarm network directly to their device.

**Why this is non-trivial**: Bee is a ~500 kLOC Go codebase (libp2p + QUIC + Ethereum + pion/WebRTC + pebble/leveldb). Making that run inside an iOS app, talk to Swarm mainnet, and serve content to a WKWebView is the interesting part.

---

## 2. Repo layout

The work spans four sibling directories under `/Users/florian/Git/freedom-dev/nodes/`:

```
nodes/
├── bee-lite-java/         ← Go wrapper over Solar-Punk-Ltd/bee-lite.
│                             Builds the Mobile.xcframework consumed by iOS.
│                             (Despite the name, it's now bound for iOS too.)
│                             Fork of github.com/Solar-Punk-Ltd/bee-lite-java
│                             on branch `ios-build-target`.
│
├── swarm-mobile-android/  ← Upstream reference Android app from Solar-Punk.
│                             Not modified by us; serves as a structural
│                             template for what Freedom does on iOS.
│
├── ios-probe/             ← Throwaway SwiftUI iOS app used to validate the
│                             Go↔Swift bridge end-to-end before investing in
│                             the real app. Reached 135 peers on Swarm
│                             mainnet from the iOS Simulator. Now dormant.
│
└── swarm-mobile-ios/      ← THIS REPO. The actual Freedom Browser iOS app.
```

**Git remotes**

- `bee-lite-java` — `origin` = your fork (`flotob/bee-lite-java`), `upstream` = Solar-Punk. Current branch `ios-build-target`, single commit ahead of `upstream/main` (`bad45ae`: "feat: add iOS xcframework build target").
- `swarm-mobile-ios` — `origin` = `flotob/swarm-mobile-ios`. Not yet pushed.
- `ios-probe` — local-only, no remote.

---

## 3. The xcframework pipeline (`bee-lite-java`)

`Solar-Punk-Ltd/bee-lite` is a thin Go library that wraps the full Bee node as a single `Beelite` struct (`Start`, `GetBzz`, `AddFileBzz`, `BuyStamp`, etc.). `bee-lite-java` is a gomobile-bind-friendly wrapper around that — exports a `MobileNode` interface with types that conform to gomobile's type restrictions.

Originally it only built for Android (`make build` → `mobile.aar`). We added iOS support:

### The build

```
make build-ios
  → go mod tidy && gomobile init
  → gomobile bind -target=ios,iossimulator -ldflags="-checklinkname=0" \
                  -o ./build/Mobile.xcframework
```

Output: `bee-lite-java/build/Mobile.xcframework` (304 MB). Contains:

- `ios-arm64/` — device, arm64 only (102 MB)
- `ios-arm64_x86_64-simulator/` — simulator, fat arm64+x86_64 (202 MB)

Xcode picks the right slice per build destination. Only one slice ships in the final `.app` bundle. Device-only IPA after stripping likely 50–90 MB.

### Non-obvious gotchas we hit

**gomobile emits `byte` (not a valid Obj-C type) for Go's `uint8`.** It's a known bug in `golang.org/x/mobile/bind/genobjc.go:1309` — the comment there even admits "the alias is lost". We worked around it by changing all scalar `byte`/`uint8` fields in the public API to `int32`:
- `StampData.BatchDepth`, `StampData.BucketDepth`
- `MobileNodeImp.Upload` and interface `MobileNode.Upload`'s `rLevel` parameter
- Internal `getRedundancyLevel` helper signature

`[]byte` is fine (maps to `NSData`), so file content payloads were untouched.

**Obj-C selectors encode parameter names.** The interface `MobileNode.Upload` had `rLevel` while the implementation `MobileNodeImp.Upload` had `redundancyLevel`. Swift-visible via Obj-C, this becomes two distinct selectors, and the impl fails to conform to the protocol. Fix: unify the names.

**Go `net` package needs `libresolv` on iOS.** Linker errors for `_res_9_nclose`, `_res_9_ninit`, `_res_9_nsearch`. These are BSD DNS resolver functions. Resolved by adding `.linkedLibrary("resolv")` to SwarmKit's `Package.swift`. (The probe app had to add `libresolv.tbd` manually; the package hides that from app targets now.)

**Xcode full install required, not just Command Line Tools.** `xcode-select` had to be pointed at `/Applications/Xcode.app/Contents/Developer`. Xcode.app itself must be installed.

### If bee-lite upstream gets bumped

When `Solar-Punk-Ltd/bee-lite` ships a new version and we want to pick it up:

1. In `bee-lite-java`, `go get github.com/Solar-Punk-Ltd/bee-lite@<new-version>` and `go mod tidy`.
2. Re-run `make build-ios`.
3. iOS app re-builds against the new xcframework transparently (relative path reference in `Package.swift`).

If upstream bee adds new methods you want to expose, you'd also update `mobile-wrapper.go` and remember that any new `byte`/`uint8` scalar or parameter-name mismatch will bite again.

---

## 4. SwarmKit — the Swift layer (`swarm-mobile-ios/Packages/SwarmKit/`)

A local Swift Package that wraps the xcframework and exposes a clean Swift API. Exists so app code never touches the auto-generated `MobileXxx` types directly.

### Structure

```
Packages/SwarmKit/
├── Package.swift                    (iOS 17, binaryTarget, linkerSettings)
└── Sources/SwarmKit/
    └── SwarmNode.swift              (public API)
```

### Key points in `Package.swift`

```swift
.binaryTarget(
    name: "Mobile",
    path: "../../../bee-lite-java/build/Mobile.xcframework"
),
.target(
    name: "SwarmKit",
    dependencies: ["Mobile"],
    linkerSettings: [.linkedLibrary("resolv")]
)
```

The `Mobile` binary target points at the sibling `bee-lite-java/build/` by relative path. The `resolv` link is declared once here so downstream app targets don't need to add `libresolv.tbd` manually.

### Public API

```swift
@MainActor @Observable
public final class SwarmNode {
    public private(set) var status: SwarmStatus       // idle, starting, running, ...
    public private(set) var peerCount: Int
    public private(set) var walletAddress: String
    public private(set) var log: [String]

    public init()
    public static func defaultDataDir() -> URL
    public func start(_ config: SwarmConfig)
    public func stop()
    public func download(hash: String) async throws -> SwarmFile
}

public struct SwarmConfig: Sendable {
    public var dataDir: URL
    public var password: String
    public var rpcEndpoint: String?   // nil → ultra-light mode
    public var bootnodes: String
    public var mainnet: Bool
    public var networkID: Int64
}

public struct SwarmFile: Sendable { public let name: String; public let data: Data }

public enum SwarmError: LocalizedError { case notRunning, notFound }
```

Design rationale:

- **`@Observable`** (iOS 17+) not `ObservableObject`. Cleaner call sites (`.environment(swarm)` + `@Environment(SwarmNode.self)`) and no `@Published` ceremony.
- **`@MainActor`** on the whole class. All state is UI-facing; letting Swift enforce single-actor access prevents data races. Background work (node startup, polling, `download`) is explicitly detached via `Task.detached` / `DispatchQueue.global().async` + `withUnsafeThrowingContinuation`.
- **`download(hash:)` is kept** even though M2 no longer uses it — the `BzzSchemeHandler` path is now the main route. `download()` remains useful for programmatic save-to-disk flows later (e.g. "Download this file" from a browser context menu).

---

## 5. The Freedom app (`swarm-mobile-ios/Freedom/`)

Standard iOS App target, SwiftUI, bundle `com.browser.Freedom`, min iOS 17.

### Files (main sources only)

```
Freedom/Freedom/
├── FreedomApp.swift         ← @main entry. Owns the SwarmNode, starts it
│                               on first appearance, injects via environment.
├── ContentView.swift        ← Top status bar, URL input, content area.
├── BrowserWebView.swift     ← UIViewRepresentable over WKWebView.
│                               Registers the bzz:// scheme handler on the
│                               WKWebViewConfiguration.
└── BzzSchemeHandler.swift   ← WKURLSchemeHandler. Translates bzz:// URLs
                                to http://127.0.0.1:1633/bzz/... and proxies
                                the bee HTTP API response back to WebKit.
```

### How a page load flows today

1. User hits **Go** → `ContentView.load()` parses the input into a `bzz://<hash>[/path]` URL and stores it in `@State currentURL`.
2. `BrowserWebView.updateUIView` notices the URL change, calls `webView.load(URLRequest(url: bzzURL))`.
3. WKWebView internally routes the request to our `BzzSchemeHandler.webView(_:start:)` because `bzz` is a registered custom scheme on its configuration.
4. The handler rewrites `bzz://<hash>/<path>` → `http://127.0.0.1:1633/bzz/<hash>/<path>` and hits the bee-lite HTTP API (already listening in-process on 1633).
5. Bee resolves the manifest, walks to the path, streams bytes + content type back.
6. Handler forwards those via `urlSchemeTask.didReceive(response)` + `didReceive(data)` + `didFinish()`.
7. Every subresource (CSS, JS, `<img>`, sub-page `<a>` clicks) recurses through the same path.

The crucial insight that made M2 a two-hour task instead of a two-day fork-of-bee-lite is: **bee-lite already runs the full Bee HTTP API on 127.0.0.1:1633** (default `APIAddr: ":1633"` in bee-lite's `start.go`). We don't need to expose a path-aware download method through gomobile — bee is already serving `/bzz/{hash}/{path}` locally.

### Current limitations

- **Single hardcoded password**. `"freedom-default"`. Usable for reads; for writes (upload/publish) we'd need real key management.
- **No browser chrome.** No back/forward/reload, no tabs, no history, no bookmarks. One URL at a time.
- **Ultra-light mode only.** `rpcEndpoint == nil` means no chequebook, no SWAP payments. Read-only. Enough for browsing public Swarm content.
- **No background execution strategy.** The app only runs while foregrounded. iOS backgrounds the process, libp2p connections die. Re-opening the app starts a fresh discovery cycle.
- **Simulator proven, device untested.** No technical reason device shouldn't work — no simulator-specific code paths — but we haven't verified.
- **Hash collision with the probe.** Both apps want port 1633. Running two at once on the same simulator fails; keep only one installed.

---

## 6. End-to-end build pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│ Solar-Punk-Ltd/bee-lite (Go module on GitHub, v0.0.13)              │
│   ├── core bee node as Beelite struct                               │
│   └── libp2p, geth, pion, quic-go, etc. (giant dep tree)            │
└─────────────────────────┬───────────────────────────────────────────┘
                          │  go mod require
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ bee-lite-java/ (Go, our fork of Solar-Punk-Ltd/bee-lite-java)       │
│   ├── MobileNode interface (mobile-wrapper.go, types.go, ...)       │
│   └── `make build-ios` → gomobile bind -target=ios,iossimulator     │
└─────────────────────────┬───────────────────────────────────────────┘
                          │  writes
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ bee-lite-java/build/Mobile.xcframework (304 MB, NOT committed)      │
│   ├── ios-arm64/Mobile.framework        (device, 102 MB)            │
│   └── ios-arm64_x86_64-simulator/...    (simulator, 202 MB)         │
└─────────────────────────┬───────────────────────────────────────────┘
                          │  binaryTarget path = "../../../bee-lite-java/build/..."
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ swarm-mobile-ios/Packages/SwarmKit/                                 │
│   Swift Package wrapping Mobile.xcframework + links libresolv       │
└─────────────────────────┬───────────────────────────────────────────┘
                          │  local package dependency
                          ▼
┌─────────────────────────────────────────────────────────────────────┐
│ swarm-mobile-ios/Freedom/ (Xcode app target)                        │
│   SwiftUI UI + WKWebView + BzzSchemeHandler                         │
│   → .app bundle → iOS Simulator / device                            │
└─────────────────────────────────────────────────────────────────────┘
```

### Clone-from-scratch recipe

```bash
# 1. Clone both repos as siblings
cd ~/some-parent-dir
git clone git@github.com:flotob/bee-lite-java.git
git clone git@github.com:flotob/swarm-mobile-ios.git

cd bee-lite-java
git checkout ios-build-target

# 2. Ensure toolchain
brew install go
go install golang.org/x/mobile/cmd/gomobile@latest
# Xcode full install + `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

# 3. Build the xcframework (takes ~20 min first time)
export PATH="$HOME/go/bin:$PATH"
make build-ios

# 4. Open Xcode and build
cd ../swarm-mobile-ios/Freedom
open Freedom.xcodeproj
# ⌘R
```

This only works if both repos are siblings. The `binaryTarget` path is relative.

---

## 7. Productization roadmap

Work remaining before this is something real users could install from the App Store.

### M3 — Browser essentials (next likely milestone)

- **Navigation controls**: back, forward, reload, stop. WKWebView provides the APIs; just need UI.
- **Address bar improvements**: show current URL, allow editing, handle page-load progress.
- **Tabs**: multiple concurrent pages. SwiftData-persisted list of `Tab(id, url, title)`.
- **History**: persist visited pages + titles. SwiftData model.
- **Bookmarks**: SwiftData model, simple UI.
- **Homepage / new tab page**: bookmarked hashes, recently visited.

### M4 — Platform maturity

- **Wallet / key management**. Replace hardcoded `"freedom-default"` password with a real secret derived and stored in Keychain. If we support uploads, also Keychain the Ethereum signing key.
- **Background execution strategy**. Pick one:
  - *Foreground-only*: accept that the node restarts every launch. Simplest. Arguably correct for a browser (you're not browsing in your pocket).
  - *`BGProcessingTask`*: keep the node alive during short background windows iOS grants. Worth it if we need to complete long uploads.
  - *No "foreground service" equivalent on iOS* — unlike Android, we can't keep the node alive indefinitely in background.
- **Privacy manifest** (`PrivacyInfo.xcprivacy`). Required for App Store submission (2024+). We'll need to declare what data types the app accesses and why. Most of ours is local-only, but we read `FileManager` paths.
- **App Transport Security**. Currently works because `localhost` is exempt from default ATS rules. If we ever point bee's API at a non-127.0.0.1 address, we'd need ATS exceptions in `Info.plist`.
- **Permissions / capabilities**. Probably none needed beyond "Outgoing Connections" (automatic). No camera, no location, no mic.
- **Code signing & provisioning**. Right now it builds with your personal team for Simulator. For device testing → personal team + free provisioning profile (7-day expiry). For TestFlight → paid Apple Developer account, real provisioning profile, signed distribution build.
- **App Store metadata**. Icon, launch screen, screenshots, description, keywords, support URL, privacy URL, age rating. App icon especially — currently using the Xcode placeholder.
- **Binary size**. `.ipa` on the order of 50–90 MB post-Apple-thinning. Acceptable but large. Things to explore:
  - Strip debug symbols aggressively on release builds (`-ldflags="-s -w"` in the gomobile invocation).
  - Audit bee-lite for unused features we can compile out (does the embedded node actually need `pion/webrtc`? Feed subsystem?). Each removed import shrinks the binary.
  - iOS App Thinning handles device-specific stripping automatically once submitted.

### M5 — xcframework distribution

Today the iOS repo cannot be built in isolation — it needs `bee-lite-java/build/Mobile.xcframework` to exist on disk at a sibling path. Fine for solo dev, broken for any collaborator or CI.

Plan:

1. Publish built xcframeworks as versioned releases on `flotob/bee-lite-java` (or wherever we end up hosting). Attach the `.xcframework` as a zipped release asset.
2. Switch `Packages/SwarmKit/Package.swift`'s binary target to a URL + checksum:
   ```swift
   .binaryTarget(
       name: "Mobile",
       url: "https://github.com/flotob/bee-lite-java/releases/download/v0.0.1-ios/Mobile.xcframework.zip",
       checksum: "<sha256>"
   )
   ```
   SwiftPM will download and cache on first build. Repo becomes clone-and-build.
3. CI: GitHub Action on bee-lite-java that runs `make build-ios` on a macOS runner, zips, uploads to the release. Then SwarmKit bumps the version + checksum in one commit.

Risk: GitHub Releases has a 2 GB per-asset limit. 304 MB zipped is ~150 MB, well under.

Alternative if the xcframework gets much bigger: host on S3 / Cloudflare R2.

### M6 — Beyond browsing

Freedom Browser is the first use case. The SwarmKit layer is designed so other Swarm-native iOS apps could reuse it. Natural follow-ons:

- **Publishing**: upload a site from the phone. Requires light mode (chequebook, stamps) and Ethereum signing. The Go `Upload` method and `BuyStamp` are already exposed; the Swift side just needs UI + key management.
- **Feeds**: Swarm Feed subscription (mutable pointers into immutable content). Requires wrapping `bee-lite.AddFeed` / feed lookup.
- **Access control**: ACT (Access Control Trie) encrypted content. Already supported in bee-lite (`actDecryptionHandler`), not yet exposed through our wrapper.

---

## 8. Upstream contribution possibilities

Two latent PRs sitting in our work, not yet filed:

### `Solar-Punk-Ltd/bee-lite-java`

A PR of our `ios-build-target` branch would add an iOS build target to upstream. **But it includes the `byte`/`uint8` → `int32` breaking change**, which upstream may not want (Android callers have to update too, and there's a known ReactNative consumer in the wild per `mobile-wrapper.go:181`). A cleaner path for a PR:

- Keep `uint8` in the Go source.
- Include a `replace` directive in `go.mod` pointing to a patched gomobile fork that emits `uint8_t` instead of `byte`.
- Or submit the 1-line fix to `golang.org/x/mobile` first (see below) and wait for it to merge.

We chose the `int32` route for speed — we don't care about preserving the Android aar's Java-`byte` API. If we ever want to upstream cleanly, we revisit.

### `golang.org/x/mobile`

One-line fix in `bind/genobjc.go:1309`:

```diff
- case types.Uint8:
-     // byte is an alias of uint8, and the alias is lost.
-     return "byte"
+ case types.Uint8:
+     return "uint8_t"
```

The matching `case elem == "byte"` check a few lines down (for `[]byte` → `NSData`) would need updating too to match against `"uint8_t"`. ~3 line patch. Would fix this class of bug for every Go project that binds to iOS with gomobile.

---

## 9. Key commits

- `bee-lite-java@bad45ae` — iOS build target added, byte→int32 fix, Obj-C selector param-name unification.
- `swarm-mobile-ios@a5f3d79` — initial SwarmKit scaffold.
- `swarm-mobile-ios@aa49aed` — M1: fetch-a-hash, render as HTML via `loadHTMLString`.
- `swarm-mobile-ios@73efa98` — M2: `bzz://` URL scheme handler; full asset resolution via bee's local HTTP API.

---

## 10. Operating notes

**Port 1633**. Bee's default HTTP API port. Only one instance at a time. If switching between `ios-probe` and `Freedom` in the Simulator, force-quit the previous app (swipe up in Simulator's app switcher, or delete the app) before launching the next one — otherwise the second node's `HTTP listen` fails silently and `bzz://` requests get refused connections.

**Simulator keyboard paste**. Menu `I/O → Keyboard → Connect Hardware Keyboard` (⇧⌘K) — otherwise ⌘V doesn't work inside text fields.

**Rebuilding the xcframework**. Run `make build-ios` in `bee-lite-java/`. First run after `go clean -cache` takes ~20 min. Incremental rebuilds after a small source change: <1 min (Go caches most compiles; only the final gomobile-bind step re-runs).

**`.gitignore`**. `build/` is ignored in `bee-lite-java/`. `Mobile.xcframework/` and `xcuserdata/`, `.swiftpm/`, `DerivedData/` are ignored in `swarm-mobile-ios/`. None of these should ever be committed.
