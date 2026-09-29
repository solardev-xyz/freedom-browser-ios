# Tezos Domains (`.tez`) website resolution

Port of desktop's `src/main/tezos-domains-resolver.js` + `content-name-resolver.js`. A `.tez` name typed into the address bar, followed from a link, or used as the host of an `ipfs://` / `ipns://` URL is resolved natively from the Tezos Domains mainnet registry, never through ENS.

## Pipeline

`ContentNameResolver` (`ContentNameResolver.swift`) is the one entry point for every name the browser resolves: `.tez` → `TezosDomainsResolver`, everything else → `ENSResolver`. It conforms to `ENSResolving`, so the tab, the bzz / ipfs scheme handlers, the favicon store and the Swarm manifest fetcher all take it unchanged.

`TezosDomainsResolver` (`Tezos/TezosDomainsResolver.swift`), per uncached name:

1. **Heads.** `chain_id` (must be mainnet `NetXdQprcVkpaWU`) and the head level from each of the three public endpoints (`tezos-mainnet.octez.io`, `rpc.tzkt.io/mainnet`, `rpc.tzbeta.net`), concurrently, 8 s each. A head more than 60 blocks from the median is excluded. If the retained set is not a strict majority of responders (two providers that disagree), the result is a **conflict** with one group per claimed head.
2. **Anchor.** Every retained provider is asked for the hash of block `min(head) − 8`. Providers are grouped by hash; the largest group must be a strict majority, otherwise **conflict** with one group per hash.
3. **Registry discovery** (cached 10 min per endpoint): the proxy `KT1F7JKNqwaoLzRsMio1MQC7zv3jG9dHcDdJ` script's `%contract`, then that registry's `%records` / `%expiry_map` big-map ids and the record type, all read at the anchor block.
4. **Record.** `big_maps/<records>/<expr…>` where the key is `TezosDomains.scriptExprHash(name)` (BLAKE2b-256 of the Micheline-packed bytes, base58check with the `expr` prefix — `Tezos/Blake2b.swift`). 404 → not registered. The `%expiry_key` is followed into the expiry map; an expiry in the past → expired. `web:redirect_url` wins over `web:content_url`; `td:ttl` bounds the cache.
5. **Agreement.** Answers are grouped by their semantic key (type, protocol, URI, decoded host, base path, redirect flag, expiry, ttl). A strict-majority winner with ≥ 2 members is `verified`; a lone responder is `unverified`; an even split is a **conflict** listing each answer's URI and hosts. Trust is an `ENSTrust` with `system: .tezos`, `method: .quorum`, the anchor block, agreed / dissented / queried hosts and k / m.

Caching: verified `ok` for the record's `td:ttl` (default 5 min, at most 60 min, never past the domain's expiry); unverified `ok` 30 s; negative answers 30 s; concurrent resolutions of one name share a round; 500 names at most.

## Website records

`TezosDomains.parsePublishedURI` (desktop `parsePublishedUri`): a redirect must be HTTP(S); a content URL may be HTTP(S), `ipfs://` or `ipns://`. A content URL must point at content (a CID, an IPNS key, a DNSLink host), never at a dweb *name* — `ipns://self.tez`, `ipfs://other.tez` and `ipns://vitalik.eth` are refused, including the trailing-dot and percent-encoded-dot spellings — so a domain owner cannot build a resolve→navigate loop.

| Record | Navigation |
| --- | --- |
| HTTP(S) redirect or content URL | The tab navigates to it directly; the page is ordinary web (no name trust). |
| `ipfs://<cid>[/base]`, `ipns://<key>[/base]` | Served **under the name**: the tab loads `ipfs://name.tez/…`, so the page origin (permissions, wallet grants) stays `name.tez`; `IpfsSchemeHandler` resolves the host through the façade and prepends the record's base path (`/ipfs/<cid>/base/page`). |

An `ipfs://name.tez/…` request for a name whose record is HTTP(S) gets the handler's error page (`TezosDomainsError.notContent`). `bzz://name.tez` cannot match (a Tezos record is never Swarm) and gets the codec-mismatch page.

## URL and origin rules

- `BrowserURL.tez(name:path:)`: a bare `name.tez[/path]`, `tez://name.tez/…` (the display form, like `ens://` for ENS), and any `ipfs://` / `ipns://` / `bzz://` / `http(s)://` URL whose host is a `.tez` name classify as a Tezos Domains name. `ens://name.tez` is deliberately not a name.
- `OriginIdentity`: `name.tez` keys bare (`scheme: .tez`), the same key for `tez://`, `ipfs://name.tez/…` and the bare form; wallet-eligible like ENS names.
- Back/Forward onto a `.tez`-backed entry re-verifies the name like ENS (desktop #86).
- Conflicts render in the existing ENS interstitial; Tezos groups carry a human-readable `value` (the URI or the claimed head / anchor) instead of contenthash bytes.

## Not ported

- `TEZOS_RPC` override and the settings surface: the three endpoints are fixed.
- Reverse resolution / address records: `.tez` is website resolution only, as on desktop.

## Validation

`TezosDomainsTests`: name rules, BLAKE2b vectors, the canonical ScriptExpr hash (`awesome-tezos.tez` → `exprusUkj4PJBxvW1zeyb2JWiGTWF77vDLxMzPBv8LKtHrKGbDzmeB`), website-record parsing incl. the dweb-name refusal, verified 3-of-3 preferring the redirect, IPNS content with base path, record conflict, expired / unregistered / no record, head outlier exclusion, head conflict, anchor conflict, lone provider unverified + short cache, coalesced rounds, discovery reuse, all providers down, the façade's mapping to navigation, and the URL / origin rules.
