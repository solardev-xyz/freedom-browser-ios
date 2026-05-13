# Email draft: follow-up to Corpus.core on UR.resolve sub-request routing

Follow-up to the earlier `partner-email-colibri-swift-package.md` — once
they've responded on the Swift package release ask, send this. It's a
concrete bug report we hit while integrating the v1.1.24 binding into
`swarm-mobile-ios` (`feature/kolibri`).

Context for our own records: the Step 2 ENSResolver integration is fully
plumbed, but the actual Colibri path doesn't complete because the v1.1.24
Swift binding emits a sub-request typed `eth_rpc` during UR.resolve proof
generation. With `eth_rpcs = []` (the trust-model-correct prover-only
config that JS v1.1.25 uses), the wrapper returns "No servers available."
Diagnosed via `Freedom/FreedomTests/ColibriDiagnosticTests.swift` —
`RequestHandler` interception logs exactly one `type=eth_rpc method=post
url=` per UR.resolve call.

---

**Subject:** Swift binding: UR.resolve emits `eth_rpc` sub-request, can't go prover-only

Hi Simon,

Quick concrete follow-up while we're integrating the v1.1.24 Swift binding
on iOS (mirroring the desktop Colibri integration from
solardev-xyz/freedom-browser#71). The Step 1 smoke worked great
(`eth_getBalance` prover-only, ~300ms), but `eth_call` against the
Universal Resolver does not.

**Repro**: prover-only config (matching what desktop runs):

```swift
let client = Colibri()
client.chainId = 1
client.provers = ["https://mainnet1.colibri-proof.tech"]
client.zkProof = true
client.privacyMode = .basic
// No client.eth_rpcs — Colibri's trust model is "prover only."

// UR.resolve(dnsEncode("vitalik.eth"), addr(namehash("vitalik.eth")))
try await client.rpc(method: "eth_call", params: <UR.resolve calldata>)
// => proofError("RPC error for method eth_call: No servers available")
```

Intercepting via `requestHandler` shows the C library emits exactly one
sub-request during proof generation, typed `eth_rpc` (not `prover`, not
`beacon_api`). The Swift wrapper's dispatcher routes that to `eth_rpcs`,
which is empty by design — so we get "No servers available."

This works on desktop JS v1.1.25 because that wrapper exposes
`proofStrategy: Strategy.VerifiedOnly`, which (we presume) forces
sub-requests through the prover. The Swift v1.1.24 binding doesn't have a
`Strategy` enum or `proofStrategy` field, and the C header has no
`VERIFY_FLAG_VERIFIED_ONLY` or equivalent — only `VERIFY_FLAG_PAP`
(privacy_mode basic) and `C4_PROVER_REQ_FLAG_{INCLUDE_CODE,ZK_PROOF}`.

Could the Swift binding gain:

1. **A `Strategy.VerifiedOnly` equivalent** so UR.resolve (and other
   contract calls) route their `eth_rpc`-typed sub-requests back to the
   prover the way JS v1.1.25 does. Or —

2. **`eth_rpc`-typed sub-requests honor `useProverFallback`** the way
   `beacon_api`-typed ones do today (`Colibri.swift` line ~561).

Either flip preserves the iOS trust model ("prover is the only external
trust assumption beyond Ethereum consensus") and would let us delete the
public-RPC fallback we'd otherwise need on iOS.

For reference, our config + the diagnostic test that captures the
sub-request type are in:

- `Packages/ColibriKit/Sources/Colibri/Colibri.swift` (vendored from your
  v1.1.24 `colibri-swift-package.zip`)
- `Freedom/Freedom/ColibriENSClient.swift`
- `Freedom/FreedomTests/ColibriDiagnosticTests.swift` (intercepts via
  `requestHandler`)

No urgency — we've landed the iOS plumbing with quorum as the default and
loud-fallback to quorum on Colibri error, so production is fine. When you
ship a fix we'd just flip the default and likely delete the fallback
branch entirely.

Thanks!
[your name]
