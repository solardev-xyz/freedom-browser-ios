# Bootnode Resolution on iOS

Background: what changed, why, and how to get off the Cloudflare dependency.

Status as of 2026-04-21 (`6655bcc`): we resolve Swarm mainnet bootnodes on app launch via Cloudflare's DNS-over-HTTPS endpoint, with a hardcoded IP-literal fallback list baked into SwarmKit. This works but introduces a runtime dependency on Cloudflare that we want to eliminate.

---

## 1. The problem

`go-libp2p`'s internal DNS resolver fails on real iOS devices when asked to expand `/dnsaddr/mainnet.ethswarm.org` (a multiaddr that expects a DNS TXT record chain to be walked).

Concretely: the log shows

```
"discover to bootnode failed" "bootnode_address"="/dnsaddr/mainnet.ethswarm.org"
```

on device, repeatedly. Peer count stays at zero. The same build on the iOS Simulator works — Simulator inherits the Mac host's full network stack including `/etc/resolv.conf`, so libp2p's internal resolver finds DNS servers the normal way. Real iOS has no `/etc/resolv.conf`; DNS is provided by the system via `mDNSResponder`/`getaddrinfo`, which libp2p doesn't talk to.

We verified this isn't a general network issue. Device is on the same Wi-Fi as the Mac. Regular HTTPS from Swift works fine. Info.plist keys (`NSLocalNetworkUsageDescription`, `NSBonjourServices` for `_p2p._udp`/`_p2p._tcp`) are set correctly — they made no difference. The failure is specifically libp2p's DNS path.

## 2. What we ship today

Two layers:

### Layer A — DNS-over-HTTPS resolution at startup (`BootnodeResolver.swift`)

Before starting the bee node, Swift makes an HTTPS request to Cloudflare's public DNS-JSON endpoint:

```
GET https://cloudflare-dns.com/dns-query?name=_dnsaddr.mainnet.ethswarm.org&type=TXT
Accept: application/dns-json
```

The resolver walks the `/dnsaddr/` chain — each TXT record is `dnsaddr=/dnsaddr/<subdomain>` or `dnsaddr=/ip4/.../tcp/.../p2p/...`. Recurse up to 4 levels, collect the leaf IP-literal multiaddrs, return them to the caller.

Constraints:
- Overall timeout: 3 seconds (total walk across all DNS hops).
- Per-query timeout: 2 seconds.
- Any failure (network error, malformed JSON, non-NOERROR status, empty result) returns `[]`.

### Layer B — Hardcoded fallback (`SwarmConfig.defaultBootnodes`)

Five IP-literal multiaddrs captured on 2026-04-21 via `dig TXT _dnsaddr.<region>.mainnet.ethswarm.org`. If Layer A returns `[]`, we pass this list to bee instead. Keeps the app working if:

- The device has no internet yet (new install, airplane mode, captive portal),
- Cloudflare DoH is blocked/unreachable,
- The DoH response is corrupted,
- Solar-Punk's DNS zone is temporarily broken.

The trade-off is that the hardcoded list goes stale if Solar-Punk rotates bootnodes between app releases.

## 3. Why DoH, why Cloudflare

**DoH over direct DNS.** We need DNS TXT resolution. Options were:
1. **DoH over URLSession** (our choice). Uses iOS's HTTPS path, which always works regardless of VPNs, Private Relay, carrier networks, etc.
2. **Native `DNSServiceQueryRecord`** from the dnssd framework. No third party, same path Safari uses. ~150 lines of C-API bridging with raw rdata parsing. More code, more edge cases.
3. **Pure Swift DNS library**. Adds a dependency; wouldn't help — same underlying network issues that libp2p hits.

We picked #1 for shipping speed. It's ~50 lines, hard to get wrong, and fails cleanly.

**Cloudflare specifically.** `1.1.1.1` / `cloudflare-dns.com` is the most widely-tested public DoH endpoint. It has strong TLS (passes iOS ATS without exception), returns well-formed JSON, no rate limit at our traffic level, and is reachable from most networks including ones that block other DoH providers.

Google DoH (`dns.google`) would also work. Quad9 (`dns.quad9.net`) too. We picked Cloudflare because it's the default DoH for Firefox and iOS 14+ supports it natively as an encrypted DNS profile — it's the best-understood data point.

## 4. Why we want off Cloudflare

Freedom Browser is, by design, a censorship-resistant decentralized browser. Every runtime dependency on a central service dilutes that. Today:

- **Every launch** makes an HTTPS request to Cloudflare that reveals "this device is about to connect to Swarm mainnet". Small metadata leak, but real. Cloudflare's privacy statement is fine; that doesn't eliminate the capability to correlate.
- **A single ISP or network can block `cloudflare-dns.com`** and force us onto the hardcoded fallback forever, which will eventually become wrong.
- **Cloudflare outage** (has happened) → fallback-only until they recover.
- **Product philosophy**: we're replacing HTTP gateways with peer-to-peer retrieval. It's ideological dissonance to then phone home to Cloudflare just to find out where to start.

None of these are fires. But they accumulate.

## 5. Migration paths

Roughly in order of effort / ambition.

### Option A — Race multiple DoH providers *(lowest effort, partial fix)*

Query Cloudflare and Google (and optionally Quad9, NextDNS) in parallel, take the first non-empty response. Eliminates single-vendor outage risk but the metadata leak is now across two providers instead of one. No privacy gain, small availability gain.

Estimated effort: **~20 lines** of Swift. A `withTaskGroup` racing a few `queryTXT` calls across endpoints.

Ship-readiness: immediate. Could land next PR.

### Option B — Native iOS DNS via `DNSServiceQueryRecord` *(real fix)*

Use the system resolver directly — whatever DNS the user has configured (ISP, VPN, Private Relay, custom profile, encrypted DNS, all of it). No third party at the app level.

Implementation shape:

```swift
func queryTXT(_ name: String) async throws -> [String] {
    await withCheckedContinuation { cont in
        var sdRef: DNSServiceRef?
        let ctx = /* boxed storage for the callback to write into */
        DNSServiceQueryRecord(
            &sdRef, kDNSServiceFlagsTimeout, 0,
            name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
            { _, _, _, errorCode, _, _, _, rdlen, rdata, _, context in
                // Parse raw TXT rdata bytes: [len][string] pairs, concatenate.
                // Write result into ctx.
            },
            ctx
        )
        // Pump events until timeout or result — DNSServiceProcessResult on a
        // dispatch queue, or dispatch_source_t wrap.
    }
}
```

Subtleties:
- Raw TXT rdata is binary: `<uint8 length><N bytes of string>`, repeated. Multi-part TXT records need concatenation.
- Callback is C, so context pointer → `Unmanaged<Box>` boilerplate.
- Need to pump events (`DNSServiceProcessResult`) or attach to a runloop / dispatch queue via `DNSServiceSetDispatchQueue`.
- Recursion, timeout, and error handling mirror Layer A exactly.

Estimated effort: **~150 lines** of Swift, plus careful testing across network setups (plain Wi-Fi, VPN, Private Relay, cellular, captive portal).

Ship-readiness: medium-term. Would replace Layer A entirely; Layer B (hardcoded fallback) still valuable for offline cold starts.

### Option C — Persistent cache across launches *(orthogonal, cheap)*

Write the last successful resolution to `UserDefaults` (or a file) on success. On startup, read the cached list first. Only hit the network to refresh if the cache is older than N hours, *and* do it asynchronously while starting bee with the cached list.

Benefits:
- First-launch network trip becomes the only slow path. Subsequent launches start instantly with last-known-good addresses.
- An offline cold start after ≥1 successful prior launch still has fresh-ish data.
- Reduces DoH (or system DNS) query volume to ~once a day.

Estimated effort: **~30 lines**. Uncomplicated `Codable` list + `Date` timestamp in UserDefaults.

Should land whether or not we move off Cloudflare. Pair it with whichever network resolution strategy we end up with.

### Option D — On-chain bootnode registry *(ambitious)*

Swarm already uses Gnosis Chain for postage stamps and chequebooks. A deployed smart contract could expose the current bootnode set, and we'd resolve it via JSON-RPC — the same Gnosis RPC we already talk to for other reasons.

Upsides: "decentralized all the way down" — bootnode discovery uses the chain we're already anchored to, no DNS, no HTTP, no Cloudflare.

Downsides:
- The Gnosis RPC endpoint itself is a centralized dependency (mitigated by a user-configurable endpoint, or Alchemy/public RPCs).
- Governance: who can update the contract? Solar-Punk? A DAO? Upgradeable proxy?
- Bootstrap problem: a smart contract doesn't solve "how do you connect to Gnosis RPC" — but that's an ordinary HTTPS call, which works on iOS fine.

This is the philosophically-correct end state for Freedom. Not today's work.

Estimated effort: days of design + contract deployment + Swift integration.

### Option E — Peer-exchange cold start *(research-y)*

Cache *peers we've seen recently*, not just bootnodes. Libp2p already does this — peerstore survives process restarts. On cold start, try reconnecting to recently-seen peers in addition to bootnodes; any one of them acts as a bootstrap source.

Won't help a fresh install, but dramatically reduces bootnode dependence after the first run.

Not strictly a DNS migration — worth noting because it shifts where the brittleness sits. Combine with Option C (persistent cache) for full offline cold-start resilience.

---

## 6. Recommended short-term sequence

1. **Option C (persistent cache)** — lands first. Small, clearly beneficial, orthogonal to the resolution strategy.
2. **Option A (multi-provider DoH race)** — lands second. Cheap hedge against Cloudflare outages. Buys time.
3. **Option B (native iOS DNS)** — replaces Option A once we've validated it across VPN / Private Relay / cellular edge cases.
4. **Option D (on-chain registry)** — revisit when we're shipping Ethereum signing anyway (needed for light-mode publishing). Natural synergy.

The aim is: by the time Freedom ships to real users, the startup path has zero third-party dependencies *beyond* ordinary HTTPS to Gnosis (which the user already depends on for the product's stated purpose — reading on-chain state).

---

## 7. Why this doc exists

Context preservation. The DoH implementation is small and unremarkable to read (`BootnodeResolver.swift`, ~60 lines). The *reasoning* — why Swift and not Go, why DoH and not dnssd, why Cloudflare and not Google, and why we know we need to leave — is what's worth writing down. When the next milestone picks up Option B, the author shouldn't have to rebuild this context from git-blame archaeology.
