OK here's the kubo vs helia picture and a revised position.

## Kubo (Go) vs Helia (JS) for our scheme-handler model

| Aspect               | Kubo (Go → gomobile xcframework)                                                                                           | Helia (JS bundle in WKWebView)                                                                                                                                                                                                                                      |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Architecture fit** | Identical to Swarm: native node on `127.0.0.1:<port>`, `WKURLSchemeHandler` proxies. Reuses every pattern we already have. | Doesn't fit. WKURLSchemeHandler runs in Swift; Helia runs in JS. To proxy `ipfs://` you'd need a hidden WKWebView running Helia, with `WKScriptMessageHandler` ferrying bytes per request. High latency, fragile.                                                   |
| **Connectivity**     | Full libp2p: TCP, QUIC, WebTransport, WebSockets, Noise, Yamux, KAD-DHT. Talks to the production IPFS swarm.               | Browser-restricted libp2p: WebRTC + WebSockets only. Most IPFS peers don't expose WebSocket transports. Helia leans heavily on `@helia/delegated-routing-v1-http-api-client` (a centralised HTTP gateway) and circuit-relay-v2. Reachability is meaningfully worse. |
| **Memory**           | ~200-300 MB resident for kubo lowpower.                                                                                    | Lives inside WKWebView's existing JS heap. Lighter incrementally — but the user's page also competes for that heap.                                                                                                                                                 |
| **Binary size**      | +70-90 MB unzipped device slice (overlaps with bee's pebble, libp2p, etc.)                                                 | A few MB of JS bundle, zero native.                                                                                                                                                                                                                                 |
| **Performance**      | UnixFS decoding native, no JSON marshalling per chunk.                                                                     | JS UnixFS decode + structured-clone bytes through JS↔Swift bridge. Bad for multi-MB pages.                                                                                                                                                                          |
| **Trust model**      | Full DHT participation by default; we verify content via CID.                                                              | Forced reliance on delegated routing endpoint = additional trust party (usually `delegated-ipfs.dev`). For a "decentralised browser" pitch this is a serious concession.                                                                                            |
| **Maturity**         | Reference implementation. Stable, what every IPFS pinning service runs.                                                    | Modern, browser-first, but the "first-class IPFS in iOS app" story has no proven precedent.                                                                                                                                                                         |
| **Effort**           | Mirror the bee-lite-java recipe; ~300 LOC Go wrapper exists in `freedom-node-mobile/mobile/ipfs-*.go`, bee-free.           | New rendering pipeline. Helia in iframe, MessagePort, byte streaming, etc. Substantial design + plumbing.                                                                                                                                                           |

**Helia rules itself out for our use case.** The whole point of Freedom is "browser that loads `ipfs://` and `bzz://` peer-to-peer with no remote gateway." Helia in an iOS WKWebView is *de facto* gateway-dependent (delegated routing) and has degraded peer reachability. It would also require significant new architecture.

**Kubo is the answer.** It's the same recipe we already know works.

## Revised recommendation: kubo, separate xcframework, separate Swift package

Your instinct to keep them separate is sound. To restate properly:

- **Combined (2-in-1):** one Go binary, one libp2p version (Go MVS picks max). bee and kubo *share* runtime state. The version both nodes end up running on is whatever upstream-tested combo MVS happened to converge to — that's a real risk, and it's the most likely root cause of the Android instability your colleague saw.
- **Separate xcframeworks:** two independent Go runtimes, two embedded libp2p stacks, zero shared state. They cannot interfere semantically — they only share TCP port namespace (already non-overlapping: bee `:1633/:1634`, kubo `:18080/:4001`) and the iOS process's memory/CPU budget. **Memory is the only real cost.**

So my Phase-0/Option-A pitch was wrong on the libp2p risk axis. Separate is safer.

## Where to source the Go wrapper

Three sub-options for the kubo-side iOS Go wrapper:

| Option  | What it is                                                                                                                                                                  | Pros                                                                                                                                                                                                                                                                                | Cons                                                                                                                                                  |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| **B.1** | New iOS-only repo (`solardev-xyz/kubo-mobile-ios` or similar), cherry-pick `mobile/ipfs-wrapper.go` + `mobile/ipfs-types.go` from `freedom-node-mobile`, drop the bee half. | ~300 LOC of proven, well-commented code. Plugin `sync.Once` guard, `ServeWithReady`-based gateway, clean shutdown — all already there. Clean single-purpose repo. Mirrors `bee-lite-java`'s shape. No `byte`/`uint8` quirk in the IPFS API (verified — only strings, ints, []byte). | New repo to maintain. Drift from your colleague's version over time.                                                                                  |
| **B.2** | Fork `freedom-node-mobile`, add iOS target alongside Android, but document/ship the iOS xcframework as kubo-only by gating bee-half symbols out for the iOS build.          | Single Go repo across platforms. Reuses colleague's CI eventually.                                                                                                                                                                                                                  | Have to gate bee out (build tags) without breaking Android — adds complexity. Inherits bee-half code we don't run on iOS, bloats the Go module graph. |
| **B.3** | Write a fresh, minimal kubo wrapper from scratch following `bee-lite-java`'s style.                                                                                         | Pristine code, no inherited bee assumptions.                                                                                                                                                                                                                                        | Throws away the colleague's plugin-init guard and gateway-readiness handling — both are non-trivial corners. Reinventing solved problems.             |

**Recommendation: B.1.** Cherry-pick the proven 300 LOC, package as a clean iOS-only repo, build a kubo-only xcframework. The bee half stays in `bee-lite-java@ios-build-target` (already shipping releases). Two repos, two artifacts, no entanglement.

## Concrete revised plan (Option B / B.1)

### Phase 0 — Validation (1–2 days)
- Create new repo `solardev-xyz/kubo-mobile-ios` (or your naming preference).
- Copy `mobile/ipfs-wrapper.go`, `mobile/ipfs-types.go`, `mobile/gomobile_deps.go`, `mobile/version.go` from `freedom-node-mobile`. Strip bee imports, fix `go.mod`.
- Adapt the `Makefile` from `bee-lite-java@ios-build-target`: `make build-ios` → `gomobile bind -target=ios,iossimulator -ldflags="-checklinkname=0"` → `build/Kubo.xcframework`.
- Adapt `cmd/ipfsprobe` for host-side smoke test.
- **Gate decision:** does the build succeed? does `ipfsprobe` reach IPFS mainnet from macOS? The interesting unknown is whether kubo's transitive deps (libp2p, boxo, pebble) cross-compile cleanly for `ios-arm64,iossimulator-arm64,iossimulator-x86_64`. Bee's deps did with `-checklinkname=0`; kubo's *should* given the dep overlap, but it's unverified.

### Phase 1 — Go side hardening (3–5 days)
- GitHub Action that runs `make build-ios` on macOS runner, attaches `Kubo.xcframework.zip` + SHA256 to releases (mirror bee-lite-java's pipeline).
- Ship `ios-v0.1.0`.
- Decide gateway port — propose `127.0.0.1:5050` (avoid kubo's traditional `:5001` admin API conflict, avoid Android's `:18080` since not load-bearing here).
- Pick default routing mode: `autoclient` (lightest, delegated routing fallback) for low-power, `dhtclient` if we want better peer reachability without serving DHT lookups. Both are configurable via `IpfsNodeOptions.RoutingMode`.

### Phase 2 — Swift package `IPFSKit` (2–3 days)
- New `Packages/IPFSKit/` mirroring `Packages/SwarmKit/`:
  ```swift
  .binaryTarget(
      name: "Kubo",
      url: "https://github.com/solardev-xyz/kubo-mobile-ios/releases/download/ios-v0.1.0/Kubo.xcframework.zip",
      checksum: "..."
  ),
  .target(name: "IPFSKit", dependencies: ["Kubo"], linkerSettings: [.linkedLibrary("resolv")])
  ```
  Module name `Kubo` keeps it from colliding with SwarmKit's `Mobile`.
- `IPFSNode.swift`: `@MainActor @Observable` class mirroring `SwarmNode` — start/stop, status, peerCount, peerID, gatewayURL, optional `add(_ data: Data) async throws -> String`.

### Phase 3 — Freedom app integration (1 week)
- `IpfsSchemeHandler.swift` mirroring `BzzSchemeHandler`: `ipfs://<cid>/<path>` → `http://127.0.0.1:5050/ipfs/<cid>/<path>`, IPNS likewise.
- `BrowserURL` extensions: `case ipfs(URL)`, `case ipns(URL)`, classify schemes, recognize bare CIDs (CIDv0 `Qm…` base58 / CIDv1 `b…` base32, ~30-line parser).
- `BrowserWebView`: register `ipfs` and `ipns` schemes on the `WKWebViewConfiguration` alongside `bzz`.
- `FreedomApp`: own an `IPFSNode` instance, start in parallel with `SwarmNode`, inject via environment.
- `BrowserTab.navigate`: handle `.ipfs` / `.ipns` content codecs returned by the existing `ENSResolver` (the decoder already produces these — they currently dead-end).
- `ContenthashDecoder`: already supports IPFS/IPNS — no change needed.
- `ENSContentCodec`: already has `.ipfs` and `.ipns` cases — no change needed.
- `MenuPill`: extend node-stats subtitle to show IPFS peer count alongside Swarm.
- `SettingsStore`: add `ipfsEnabled`, `ipfsRoutingMode`, `ipfsLowPower`. UI in SettingsView.
- `TrustShield`: extend to handle `.ipfs`/`.ipns` origins (CID immutability is a strong trust signal — green on direct CID, dependent-on-resolver on IPNS).

### Phase 4 — Polish (3–5 days)
- Memory monitoring; opt-in toggle if needed.
- History/bookmark de-dup for IPFS origins.
- Background-execution: same constraint as Swarm (foreground-only for now).

## Open questions (revised)

1. **Lock in B.1 (separate kubo-only iOS repo, cherry-pick wrapper)?**
2. **Repo name?** `kubo-mobile-ios` is mirror of `bee-lite-java`. Or `freedom-ipfs-mobile`. Or `kubo-lite-ios`.
3. **First user-visible feature.** I'd suggest: ENS-name → IPFS contenthash → browse. That's the smallest demoable path: literally just adds `IpfsSchemeHandler` + `BrowserURL.ipfs` case + IPFSNode startup. Bare `ipfs://<cid>` URL bar input is a tiny add on top.
4. **IPFS UX scope.** Browse-only first, "Save to IPFS"/publishing later? (The kubo wrapper already exposes `AddBytes`, so it's available, but UX is a separate project.)
5. **Memory target.** Are we OK with kubo always-on alongside bee, or should IPFS be off-by-default in settings until we validate iOS memory headroom?
6. **Routing default.** `autoclient` (lightest, leans on delegated routing) or `dhtclient` (more decentralised, no extra trust party, slightly heavier)? "Decentralised browser" branding probably argues for `dhtclient`.

Want me to start Phase 0 — create the repo skeleton, cherry-pick the wrapper, attempt the iOS build?