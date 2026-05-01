# Freedom Browser iOS — Adblocking Plan

## Strategic framing

Adblocking in Freedom is a **competitive feature for browsing the regular https web**, not a Swarm cosmetic. Today there's barely any content on Swarm; users will spend most of their time in Freedom on plain https sites. The goal is to make that experience materially better than Mobile Safari out of the box, in the same league as Brave iOS / AdGuard iOS / 1Blocker. Adblocking on `bzz://` content is a free side benefit (and tracker-blocking there is non-trivially valuable) but not the design center.

This re-prioritises a few things vs. a "minimum viable" plan:
- Cosmetic filtering matters more — many cosmetic rules target mainstream news/social/ecom sites users actually visit.
- Per-site allowlist + "Reload without blockers" are essential — the messy real web breaks constantly and users need an escape hatch.
- We're benchmarking against Brave iOS, not against not-having-adblock.

## License

Freedom Browser will be **MPL-2.0**. That rules out:

- **AdGuard SafariConverterLib (GPLv3)** — incompatible. We can't link it, and using it even at build-time ties us to a license we don't want to take a dependency on. Skip.

That leaves on the table:

- **Brave's adblock-rust (MPL-2.0)** — same license as Freedom. Production-tested on Brave iOS. Has a `content-blocking` Cargo feature that converts ABP/EasyList rules → Apple WebKit content-blocker JSON. Exposed to JS via `adblock-rs` on npm: `FilterSet.intoContentBlocking()` returns `[{trigger, action}, ...]`.
- **A reimplementation we own** — feasible, but the converter has a long tail of ABP/uBO syntax + WebKit regex limits + the iOS 17 size-crash workaround + EasyList format drift. Writing a quality version is 2-3 weeks; matching Brave's quality on the long tail is more.

**Recommendation: use adblock-rs (the npm bindings to Brave's adblock-rust).** Same license, production quality, one dependency, runs anywhere Node runs. Keep "reimplement in TS" on the table as a fallback if we hit something we hate, but don't do it preemptively.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ Freedom-controlled server (already runs a Swarm node)               │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │ filter-update service (Node/TS, long-running)               │   │
│   │   every 12–24h:                                             │   │
│   │     1. fetch easylist.txt + easyprivacy.txt + ...           │   │
│   │     2. adblock-rs → WebKit JSON, split per category         │   │
│   │     3. cap each output at ~2 MB (iOS 17 size limit)         │   │
│   │     4. publish JSON blobs to Swarm                          │   │
│   │     5. update Swarm Feed (manifest = list of refs + hashes) │   │
│   │        signed with feed-write key held on this server       │   │
│   └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  │ (Swarm peer-to-peer)
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Freedom iOS app                                                     │
│                                                                     │
│   bundled in Resources/adblock/                                     │
│     easylist.json, easyprivacy.json, metadata.json                  │
│     ← used on first launch & if Swarm Feed unreachable              │
│                                                                     │
│   AdblockService                                                    │
│     - on launch: compile bundled lists if WKContentRuleListStore    │
│       cache miss; attach to webviews                                │
│     - in background: read Swarm Feed (via embedded bee), compare    │
│       manifest version to local; if newer, fetch JSON refs from     │
│       Swarm, verify hash, compile, hot-swap on next webview create  │
└─────────────────────────────────────────────────────────────────────┘
```

Two delivery paths into the app, both shipping the same JSON shape:

1. **Bundled** (`Freedom/Resources/adblock/*.json`) — refreshed manually before app releases by running the same converter locally. Acts as the offline / first-launch / fallback baseline. Doesn't need to be cutting-edge — just "good enough that adblock works on a fresh install with no network".
2. **Runtime via Swarm Feed** — the live channel. Service on the server pushes updates every 12-24h; app picks them up in the background.

**No GitHub Actions in the loop.** The bundled JSON refresh is a manual local script run a few times a year. The runtime updates are the service on our server.

## Technical fundamentals (reference)

- **API**: `WKContentRuleListStore.compileContentRuleList(forIdentifier:encodedContentRuleList:)` compiles JSON → internal bytecode and caches under the identifier. `lookUpContentRuleList(forIdentifier:)` returns the cached compiled list instantly. Attached via `WKWebViewConfiguration.userContentController.add(_:)` before the webview loads.
- **Action types**: `block`, `block-cookies`, `css-display-none` (requires `selector`), `ignore-previous-rules`. **No allowlist primitive** — allowlists are `ignore-previous-rules` rules placed *after* block rules, in a separate list attached after the block lists.
- **Trigger fields**: `url-filter` (regex subset), `url-filter-is-case-sensitive`, `if-domain` / `unless-domain` (mutually exclusive), `resource-type`, `load-type` (first-party / third-party).
- **Regex subset**: character match, ranges `[a-b]`, quantifiers `? + *`, groups, anchors `^ $` only at start/end. URLs are canonicalised to lowercase ASCII before matching.
- **Size limit**: documented as 150K rules, but iOS 17+ has an undocumented size-based crash that hits well below that (AdGuard reported crashes at 40-60K rules depending on content). Tune by JSON byte size; ~2 MB per blocker is safe. adblock-rs doesn't auto-honour this — we do the splitting in our service.
- **`bzz://` interaction**: content blockers match the resource URL the page requests, not the page's own URL. A `bzz://<hash>` page issuing `fetch('https://google-analytics.com/...')` is matched normally by EasyPrivacy. Worth a smoke test in phase 1, no surprise expected.

## Phased plan

### Phase 1 — App-side plumbing & toggles (~1-2 days)

New folder `Freedom/Freedom/Adblock/`:
- `AdblockService.swift` — `@MainActor @Observable`. Owns `[CategoryID: WKContentRuleList]`. `compileBundledIfNeeded()` runs once at app start. `attach(to: WKWebViewConfiguration)` adds active lists.
- `AdblockSettingsView.swift` — toggles per category, "About filter lists" section with EasyList attribution.

`SettingsStore` extension:
- `adblockAdsEnabled`, `adblockPrivacyEnabled`, `adblockAnnoyancesEnabled`, `adblockSocialEnabled`, `adblockAllowlist: [String]`.

Wire-up:
- `FreedomApp.swift`: instantiate `AdblockService`, `.task { await adblockService.compileBundledIfNeeded() }`.
- `BrowserWebView.swift` (`makeUIView`): call `adblockService.attach(to: configuration)` before creating the `WKWebView`.
- `MenuPill` / `SettingsView`: entry to open `AdblockSettingsView`.

Bundle two tiny hand-written JSONs in `Resources/adblock/` (a dozen rules each — `doubleclick.net`, `google-analytics.com`, etc.) so phase 1 ships a working visible feature without phase 2.

### Phase 2 — Bundled lists from real EasyList/EasyPrivacy (~1-2 days)

`tools/adblock-builder/` — small Node/TS package:
- Depends on `adblock-rs` from npm.
- `npm run build` fetches `easylist.txt` + `easyprivacy.txt` (and any other lists we want), runs `FilterSet.intoContentBlocking()`, splits output per category, caps each file at ~2 MB (auto-shards into `easylist-1.json`, `easylist-2.json` if needed), writes to `Freedom/Resources/adblock/` plus `metadata.json` (`{ source_url, source_sha256, generated_at, rule_count, lib_version }`).
- A `make adblock-bundle` (or just documented `npm run build`) — run manually before app releases. Diff is committed to the repo.

`AdblockAttributionView` (license + source URLs, reachable from settings): EasyList wants attribution. adblock-rs is MPL-2.0 — attribution per its license too.

### Phase 3 — Server service + Swarm Feed runtime updates (~3-5 days)

Server-side service (Node/TS, runs alongside the existing Swarm node):
- Cron loop, every 12-24h.
- Same converter logic as `tools/adblock-builder/` (likely literally the same package, imported as a module).
- After producing JSON files: upload each to Swarm (via local bee), then write a manifest entry to a known Swarm Feed:
  ```json
  {
    "version": 17,
    "generated_at": "2026-05-12T03:00:00Z",
    "lists": [
      { "id": "easylist", "ref": "<bzz hash>", "sha256": "...", "rule_count": 41200, "byte_size": 1948672 },
      { "id": "easyprivacy", "ref": "<bzz hash>", "sha256": "...", "rule_count": 23110, "byte_size": 1041280 }
    ]
  }
  ```
- Feed signed with a dedicated key held on the server (not a personal key).

App-side update flow:
- `AdblockUpdateService` runs in background (not at first launch — bundled rules cover that).
- Read manifest from the known Swarm Feed via embedded bee.
- Compare `version` to local; if newer:
  - For each changed list: download JSON ref via bee, verify SHA256, call `compileContentRuleList(forIdentifier: id, encodedContentRuleList: …)` (overwrites the cached compiled list under the same identifier).
  - Persist new manifest version locally only after all compiles succeed.
  - New tabs use updated rules immediately; existing tabs roll over on next reload.
- On any failure: keep previous compiled rules, log, retry next launch.

The feed address (Swarm pubkey) is hardcoded in the app — that's our trust anchor. Compromise of the server's feed-write key would let an attacker push arbitrary rules to Freedom users. Mitigations: dedicated key with no other authority, monitoring/alerting on unexpected feed updates, eventually a key-rotation story.

### Phase 4 — Per-site allowlist (~1 day)

Separate `freedom-allowlist` rule list, regenerated whenever the user toggles disable-on-site:
```json
{ "trigger": { "url-filter": ".*", "if-domain": ["foo.com", "*.foo.com"] },
  "action":  { "type": "ignore-previous-rules" } }
```
Attached AFTER the block lists (rule-list attach order is preserved).
UI: "Disable blocking on this site" entry in `MenuPill` action menu, plus list management in `AdblockSettingsView`.

### Phase 5 — Custom user rules (later, optional)

Small text editor in settings. User rules will typically be tiny, so a hand-rolled ABP-subset parser (~200 LOC) is sufficient. Falls back to "drop with error" for syntax we don't support.

## Open decisions

1. **Cosmetic rules in v1?** Lean yes — adblock-rs converts EasyList's `##` rules to `css-display-none` for free, and given the https-web positioning they pull weight on real news/social/ecom sites. Cost: ~30-40% more rule count, easy to keep under the size cap.
2. **Default-enabled categories.** Recommend `ads + privacy` ON, `annoyances + social` OFF — privacy-positive default without surprising users by hiding cookie banners or social embeds.
3. **Telemetry.** Per-tab "X requests blocked" counter visible somewhere (MenuPill or NodeSheet)? Cheap to add via a `WKContentRuleListAction` no-op trick or by parsing the resource-load delegate. Nice user feedback. Not required for v1.
4. **Filter-list set beyond EasyList + EasyPrivacy.** Worth considering: Fanboy Annoyances (cookie banners), AdGuard URL Tracking Protection (fingerprinting URL params — though most need `removeparam` which Safari doesn't support), uBlock filters – unbreak. Decision can be deferred to phase 2.
5. **Feed trust model details.** Single-key signing for v1 is fine; do we want a key-rotation/multi-sig story documented before we ship the runtime channel? Probably yes, even if v1 is single-key — so we don't paint into a corner.

## Dropped from earlier drafts (record of why)

- **AdGuard SafariConverterLib** — GPLv3, incompatible with our MPL-2.0 plan.
- **Build-time conversion in Swift** — was an artifact of choosing SafariConverterLib; with adblock-rs the converter is Node/TS and the Swift project doesn't gain anything from also being the build language.
- **GitHub Actions cron pipeline** — over-engineered. Bundled JSON refresh is manual + occasional; runtime updates are the server service publishing to Swarm Feed. No CI cron in either path.
- **GitHub Releases as a v2 update transport** — replaced by direct Swarm Feed delivery. We control the server, we already run a Swarm node there, no reason to detour through GitHub.
- **adblock-rust integrated directly into the Swift app** — would require Rust→Swift FFI plumbing (cbindgen + xcframework) for no benefit, since on-device list conversion is slow and unnecessary if the server pushes pre-converted JSON.

## Sources

- [brave/adblock-rust](https://github.com/brave/adblock-rust) — Rust engine, MPL-2.0, has `content-blocking` feature.
- [adblock-rs on npm](https://www.npmjs.com/package/adblock-rs) — Node bindings; `FilterSet.intoContentBlocking()` exposes the iOS conversion.
- [WebKit Content Blockers: First Look](https://webkit.org/blog/3476/content-blockers-first-look/) — JSON format spec, action types, regex subset.
- [AdGuard v4.5.1 for iOS — iOS 17 size-based limit writeup](https://adguard.com/en/blog/adguard-v4-5-1-for-ios.html).
- [Apple WKContentRuleList docs](https://developer.apple.com/documentation/webkit/wkcontentrulelist).
- [EasyList project](https://easylist.to/) — filter list source, dual-licensed GPLv3+ / CC BY-SA 3.0+.
- [AdguardTeam/SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib) — referenced as the comparison point we ruled out (GPLv3).
