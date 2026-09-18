# ENSv2 readiness verification (iOS)

Verification date: 2026-09-18. Environment: iPhone 17 Pro simulator, iOS 26.3.
Reference: [ENSv2 readiness guide](https://docs.ens.domains/web/ensv2-readiness/).
Desktop counterpart: freedom-browser PR #352 and `docs/audits/ensv2/README.md` there.

## What changed (branch `feat/ensv2-readiness`)

- **CCIP-Read on the proven tiers.** An `OffchainLookup` revert from the
  Universal Resolver used to fall through both Myotis and Colibri to the
  quorum path, so a name behind a gateway could never resolve with proven
  trust. The gateway hop now runs on the tier that produced the revert and
  every callback `eth_call` is re-executed through the same verifier,
  forward and reverse. `CCIPResolver` enforces the EIP-3668 sender check
  (nested lookups checked against their callback target), a 4 MiB
  per-gateway response cap and a 15 s per-gateway budget on the proven tiers.
- **Proven execution errors fall through.** Only `ResolverNotFound` /
  `ResolverNotContract` are a verified negative (`.noResolver`). Any other
  revert with data is the resolver running and failing (DNSSEC
  `SignatureNotValidYet`, a custom error) and lets the next method try
  instead of being cached as "no record" for 15 minutes.
- **Chain-scoped addresses and primary names.** `resolveAddress(_:chainID:)`
  keeps `addr(bytes32)` on mainnet and asks `addr(bytes32,uint256)` with the
  ENSIP-11 coin type elsewhere; caches are keyed per chain; an absent L2
  record is "no address record for this network", never the L1 address;
  WNS/GNS refuse off mainnet. `reverseResolve(address:chainID:)` passes the
  coin type to `UR.reverse` (ENSIP-19) and skips the NameNFT fallback off
  mainnet. The send flow re-resolves on a chain switch and drops a quote or
  reverse name that settled for the previous chain.
- **Any dot-separated string is a candidate.** The wallet recipient field,
  `ens://<name>` and `bzz://` / `ipfs://` name hosts accept DNS-imported
  names and Unicode labels. A bare DNS name in the address bar keeps HTTPS,
  `ipns://<dns-name>` keeps DNSLink, known gateway hosts in gateway-form
  `ipfs://` URLs are never claimed as names, and a DNS ENS name with an IPNS
  contenthash loads by content key so it can't be misread as DNSLink.
- **Bare text files render.** A top-level `ipfs://` load answered as
  `application/octet-stream`, complete, ≤ 4 KiB and valid UTF-8 is served as
  `text/plain` with `nosniff`. Subresources are untouched.
- **Direct tier walks the pool.** With quorum off or degraded, a dead first
  provider no longer fails the resolution; the tier iterates the
  non-quarantined pool and quarantines as it goes.

Freedom iOS reads addresses, primary names and contenthashes. There is no
registration, renewal or name-management code, so the guide's write-path
migration does not apply.

## Live results

`ENSv2ReadinessLiveTests` (opt-in, `TEST_RUNNER_ENSV2_LIVE=1`, plus
`TEST_RUNNER_COLIBRI_E2E=1` for the Colibri rows) resolves every fixture
through direct single-source, block-pinned quorum and Colibri-with-quorum-
fallback. All 15 address assertions passed, plus the checker contenthash and
the Base reverse lookup.

| Name                     | Destination chain | Expected and observed address                |
| ------------------------ | ----------------- | -------------------------------------------- |
| ur.integration-tests.eth | Ethereum          | `0x2222222222222222222222222222222222222222` |
| test.offchaindemo.eth    | Ethereum          | `0x779981590E7Ccc0CFAe8040Ce7151324747cDb97` |
| gregskril.com            | Ethereum          | `0x179A862703a4adfb29896552DF9e307980D19285` |
| test.ses.eth             | Ethereum          | `0x2B0F09F23193de2Fb66258a10886B9f06903276c` |
| test.ses.eth             | Base (8453)       | `0x7d3a48269416507E6d207a9449E7800971823Ffa` |

`ur.integration-tests.eth` contenthash → `ipfs://` codec, CID
`Qmaisz6NMhDB51cCvNWa1GMS7LU1pAxdF4Ld6Ft9kZEP2a` (the plain-text checker
fixture). Reverse of the Base address for coin type `0x80002105` → no primary
(the UR reverts with `ResolverError`; now a cached `.none`, not a provider
failure).

```sh
TEST_RUNNER_ENSV2_LIVE=1 TEST_RUNNER_COLIBRI_E2E=1 xcodebuild test \
  -project Freedom/Freedom.xcodeproj -scheme Freedom \
  -destination 'id=<sim-udid>' -only-testing FreedomTests/ENSv2ReadinessLiveTests
```

## Observations and limits

- **Colibri alone cannot resolve `gregskril.com`.** The proven CCIP callback
  reverts inside the verifier (the same DNSSEC `SignatureNotValidYet`
  desktop reported: Colibri executes the callback with a zero timestamp).
  With the execution-error fallthrough the quorum path answers correctly;
  the log line is `colibri-fallback error=proofFailed(message: "ccip callback
  reverted")`. Not fixable client-side; worth raising with corpus-core.
- **Five of the nine default public mainnet providers were unusable** during
  the run: `cloudflare-eth.com` (`-32046 Cannot fulfill request`),
  `eth.llamarpc.com` (HTTP 525), `eth.merkle.io` (HTTP 429),
  `rpc.flashbots.net` (HTTP 403 on a block-hash-pinned `eth_call`) and
  `rpc.ankr.com/eth` (API key now required). Quorum still reaches 2-of-3 from
  the four healthy ones (`ethereum.publicnode.com`, `1rpc.io`,
  `eth-mainnet.public.blastapi.io`, `eth.drpc.org`). The default list in
  `SettingsStore.defaultPublicRpcProviders` deserves a refresh; that is a
  configuration decision, not part of this change.
- **Myotis was not exercised live** in this run (the simulator node was not
  synced). Its tier shares the CCIP and revert code paths with Colibri and is
  covered by `ProvenTierCCIPTests` through the closure seam; the on-device
  smoke with a synced node is the remaining check.
- The Base row needs Base registered in the wallet's chain list on device
  (Chainlist add); the resolver itself only needs the chain ID.
