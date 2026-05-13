# Email draft: ask Corpus.core for a published Colibri Swift Package

Context — we're bringing the Colibri integration we shipped on Freedom desktop
(`feature/kolibri`, PR solardev-xyz/freedom-browser#71) to iOS. On desktop we
consume `@corpus-core/colibri-stateless` straight from npm; on iOS the
equivalent dependency channel is a Git-hostable Swift Package.

The prebuilt Swift package is currently distributed only as the
`colibri-swift-package.zip` release asset of `corpus-core/colibri-stateless`.
The bindings README points at `https://github.com/corpus-core/colibri-stateless-swift.git`
as the canonical SwiftPM URL, but that repository does not exist yet.

We can ship by vendoring the zip into our repo in the meantime, but a real
Git-tagged Swift Package would let us pin via SwiftPM the same way we pin
every other native dependency (bee-lite-java, freedom-ipfs) — and would line
the iOS story up with the npm story you already maintain.

The draft below is what we'd send. Fill in the recipient name(s) (Simon
Jentzsch / Steffen Kux from the npm package metadata) before sending.

---

**Subject:** Could you publish `corpus-core/colibri-stateless-swift` so we can pin from SwiftPM?

Hi Simon (and team),

Quick context: we've just landed Colibri as the default ENS verifier in the
Electron build of Freedom Browser (PR
[freedom-browser#71](https://github.com/solardev-xyz/freedom-browser/pull/71)),
and we're now porting the same change to our iOS browser
([swarm-mobile-ios](https://github.com/solardev-xyz/swarm-mobile-ios),
`feature/kolibri`). We're delighted with how Colibri turned out on desktop —
the cryptographic-verification story is exactly the upgrade we wanted over
public-RPC quorum, and reverse-record spoof detection is a really nice bonus.

To wire it into the iOS app the cleanest path would be a published Swift
Package we can reference from `Package.swift`. The bindings README (and the
iOS quick-start in `bindings/swift/doc.md`) already points at:

```swift
.package(url: "https://github.com/corpus-core/colibri-stateless-swift.git", from: "1.0.0")
```

…but that repo doesn't exist yet, and the prebuilt artifact lives only as the
`colibri-swift-package.zip` release asset of `corpus-core/colibri-stateless`
itself. We can unpack that zip locally for now, but it leaves us re-vendoring
~7 MB of binary on every release bump and re-deriving the SHA256 by hand —
SwiftPM's binary-target pinning would do all that for us automatically if the
package were Git-hosted.

Concretely we'd love to consume either:

1. **A standalone repo at `corpus-core/colibri-stateless-swift`** with `Package.swift`
   + `c4_swift.xcframework` (the same contents your release-asset zip ships
   today), tagged on each Colibri release. Same shape as your published npm
   package, just for SwiftPM. Or —

2. **A `binaryTarget`-friendly XCFramework on a tagged release** of the main
   `colibri-stateless` repo, with a checksum in the release notes. We'd
   reference it as `.binaryTarget(url:, checksum:)` and write a thin Swift
   wrapper ourselves (the same pattern we use today for
   [`bee-lite-java`](https://github.com/solardev-xyz/bee-lite-java) and
   [`freedom-ipfs`](https://github.com/solardev-xyz/freedom-ipfs)).

Option 1 is the smoothest for us because it also gives us your `Colibri.swift`
+ `swift_storage_bridge.c` adapter code, which we'd otherwise have to vendor
ourselves and keep in sync. But either works.

Either way, no time pressure — we'll vendor the current release zip into our
iOS repo as a stopgap. We just wanted to flag the ask while we're actively
integrating, in case there's already a queued release on your side, or
publishing the standalone repo is a small lift you'd be happy to do anyway.

Happy to chat through specifics on a call if helpful, or look at a draft
package layout together. Thanks again for the great work on Colibri — it's
been a delight to integrate.

Best,
[your name]
