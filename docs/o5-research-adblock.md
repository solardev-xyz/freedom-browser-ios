yes. for your iOS browser, the clean model is:

EasyList / EasyPrivacy
        ↓
download or bundle as text
        ↓
convert ABP/uBO-style filter syntax
        ↓
Apple WebKit content-blocker JSON
        ↓
WKContentRuleListStore.compileContentRuleList(...)
        ↓
attach compiled list to WKWebViewConfiguration.userContentController

Apple’s actual primitive is WKContentRuleListStore. It compiles JSON rule lists and manages them for filtering content inside a WKWebView; Apple explicitly describes these as content blockers inside your app.  ￼

recommended architecture

For Freedom iOS, I’d do hybrid bundled + runtime updates.

Meaning:

App bundle
  Resources/
    adblock/
      easylist-fallback.json
      easyprivacy-fallback.json
      metadata.json
Runtime
  Application Support/
    Adblock/
      sources/
        easylist.txt
        easyprivacy.txt
      compiled-json/
        easylist.json
        easyprivacy.json
      state.json

The app ships with a known-good compiled ruleset so adblocking works on first launch and offline. Then, at runtime, the app periodically fetches the upstream text lists, converts them, compiles them, and swaps them in after successful compilation.

Do not make the app depend on live conversion during first launch. Compilation/conversion can fail, lists can be temporarily malformed, the network can be down, and Apple’s compiler can reject rules. Treat updated filters like software updates: download → validate → compile → activate only if successful.

licensing note

EasyList’s repository is dual-licensed under GPLv3-or-later or Creative Commons Attribution-ShareAlike 3.0-or-later, and asks for attribution to “The EasyList authors” when required.  ￼

That means: don’t just silently bundle the lists as if they’re yours. Add an in-app “Filter list credits / licenses” screen. Something like:

Ad blocking uses filter data derived from EasyList and EasyPrivacy.
Source: https://easylist.to/
Copyright: The EasyList authors.
License: GPLv3+ or CC BY-SA 3.0+.

Also check this with counsel if Freedom’s app licensing matters. Using the data is different from incorporating GPL code, but you still need to respect the list licenses.

converter options

You have three practical choices.

option A — use an existing converter in your build/update pipeline

There are existing converters:

* Adblock Plus abp2blocklist converts ABP filter lists to WebKit block lists and notes that WebKit content blockers are limited, so not all filters convert perfectly. It was used for Adblock Plus for iOS.  ￼
* AdGuard SafariConverter converts AdGuard-style filter rules to Safari content-blocker format.  ￼
* Older/smaller tools like ab2cb also convert ABP lists to Safari JSON, but describe themselves as imperfect/work-in-progress.  ￼

This is the fastest path.

For an MVP I’d probably start with AdGuard’s converter or ABP’s abp2blocklist, then wrap it in your own script.

option B — write your own minimal converter

For v1, this is actually feasible if you only support a useful subset:

Support first:

||domain.com^
||domain.com/path
|https://example.com/ad.js
*/ads/*
@@||allowlisted.com^
example.com##.ad-banner
example.com###sponsored

Skip initially:

scriptlet injection
procedural cosmetic filters
advanced uBO modifiers
redirect rules
removeparam
csp rules
trusted-scriptlet stuff

uBlock Origin itself supports most EasyList syntax but extends it with its own syntax, so a full uBO-compatible parser is non-trivial.  ￼

option C — server-side compilation

This is probably what I’d do for production.

You run a small CI job/server that fetches EasyList/EasyPrivacy daily, converts them into Apple JSON, validates them, signs/version-stamps the result, and your app downloads the compiled JSON.

That gives you:

GitHub Action / backend cron
  fetch filter lists
  convert
  split by category
  validate JSON
  publish signed artifact
iOS app
  check manifest
  download JSON
  compile with WKContentRuleListStore
  activate

This is better than doing heavy list parsing on-device. The iPhone still has to compile the JSON into WebKit’s internal format, but your app does not need to ship a full adblock parser/compiler.

best plan

I’d structure it like this.

phase 1 — static bundled proof of concept

Create a tiny freedom-basic-blocklist.json manually:

[
  {
    "trigger": {
      "url-filter": ".*doubleclick\\.net.*"
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*googlesyndication\\.com.*"
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "resource-type": ["image", "script"],
      "if-domain": ["example.com"]
    },
    "action": {
      "type": "block"
    }
  },
  {
    "trigger": {
      "url-filter": ".*",
      "if-domain": ["example.com"]
    },
    "action": {
      "type": "css-display-none",
      "selector": ".ad, .ads, .sponsored, [class*='ad-container']"
    }
  }
]

Then compile and attach:

import WebKit
final class ContentBlockerManager {
    static let shared = ContentBlockerManager()
    private let store = WKContentRuleListStore.default()
    private let identifier = "freedom-basic-adblock"
    func loadBundledRuleList(into configuration: WKWebViewConfiguration) {
        guard let url = Bundle.main.url(
            forResource: "freedom-basic-blocklist",
            withExtension: "json"
        ) else {
            print("Missing bundled content blocker JSON")
            return
        }
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { ruleList, error in
                if let error = error {
                    print("Failed to compile content blocker:", error)
                    return
                }
                guard let ruleList else { return }
                DispatchQueue.main.async {
                    configuration.userContentController.add(ruleList)
                }
            }
        } catch {
            print("Failed to read bundled content blocker:", error)
        }
    }
}

Usage:

let config = WKWebViewConfiguration()
ContentBlockerManager.shared.loadBundledRuleList(into: config)
let webView = WKWebView(frame: .zero, configuration: config)

Important: the rule list needs to be attached to the WKWebViewConfiguration before the WKWebView is created or at least before the relevant page load.

phase 2 — offline build script

Add a repo script:

scripts/
  update-content-blockers/
    package.json
    convert.js
    sources.json

sources.json:

{
  "lists": [
    {
      "id": "easylist",
      "url": "https://easylist.to/easylist/easylist.txt",
      "category": "ads"
    },
    {
      "id": "easyprivacy",
      "url": "https://easylist.to/easylist/easyprivacy.txt",
      "category": "privacy"
    }
  ]
}

The script:

fetch easylist.txt
fetch easyprivacy.txt
convert to WebKit JSON
split into:
  freedom-ads.json
  freedom-privacy.json
  freedom-cosmetic.json
write metadata:
  generatedAt
  sourceCommit/hash
  ruleCount
  sourceUrls

Then commit generated JSON into the app bundle for now.

phase 3 — runtime update manifest

Publish a manifest somewhere you control:

{
  "version": 12,
  "generatedAt": "2026-05-01T12:00:00Z",
  "lists": [
    {
      "id": "easylist",
      "url": "https://updates.freedom.example/adblock/easylist.webkit.json",
      "sha256": "abc...",
      "ruleCount": 84321
    },
    {
      "id": "easyprivacy",
      "url": "https://updates.freedom.example/adblock/easyprivacy.webkit.json",
      "sha256": "def...",
      "ruleCount": 42110
    }
  ]
}

The app flow:

on app launch, or once per day:
  fetch manifest
  compare version/hash
  download changed JSON
  verify sha256
  compile with WKContentRuleListStore
  if compile succeeds:
    save active version
    attach new compiled lists to new webviews
  if compile fails:
    keep previous compiled version

phase 4 — split content blockers by category

Safari/WebKit content blockers have practical rule limits. AdGuard documents the current Safari content-blocker limit as 150,000 rules per content-blocking extension, and they work around it by splitting rules into multiple content blockers/categories.  ￼

For your app, split like this:

freedom-ads
freedom-privacy
freedom-annoyances
freedom-social
freedom-security
freedom-custom-user-rules

Then attach multiple compiled lists:

configuration.userContentController.add(adsRuleList)
configuration.userContentController.add(privacyRuleList)
configuration.userContentController.add(annoyancesRuleList)

This also gives you nice UI toggles:

[✓] Block ads
[✓] Block trackers
[ ] Block cookie banners / annoyances
[ ] Block social widgets
[+] Custom rules

phase 5 — per-site allowlist

This is the part people expect.

You cannot easily “turn off one rule” in a compiled content blocker. Instead, generate variants or use ignore-previous-rules rules.

Simple v1:

User disables blocking on example.com
  save example.com in allowlist
  regenerate small allowlist content blocker
  attach allowlist blocker before/after according to WebKit semantics

A conceptual allow rule:

{
  "trigger": {
    "url-filter": ".*",
    "if-domain": ["example.com", "*.example.com"]
  },
  "action": {
    "type": "ignore-previous-rules"
  }
}

You’ll need to test ordering carefully. For a browser, I’d keep this as its own freedom-allowlist ruleset.

app-side Swift skeleton

Something like this:

final class AdblockService {
    static let shared = AdblockService()
    private let store = WKContentRuleListStore.default()
    enum ListID: String, CaseIterable {
        case ads = "freedom-ads"
        case privacy = "freedom-privacy"
        case annoyances = "freedom-annoyances"
        case allowlist = "freedom-allowlist"
    }
    func configure(_ configuration: WKWebViewConfiguration) {
        let group = DispatchGroup()
        var loadedLists: [WKContentRuleList] = []
        for id in ListID.allCases {
            group.enter()
            loadRuleList(id: id.rawValue) { ruleList in
                if let ruleList {
                    loadedLists.append(ruleList)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            for list in loadedLists {
                configuration.userContentController.add(list)
            }
        }
    }
    private func loadRuleList(
        id: String,
        completion: @escaping (WKContentRuleList?) -> Void
    ) {
        store.lookUpContentRuleList(forIdentifier: id) { [weak self] existing, error in
            if let existing {
                completion(existing)
                return
            }
            guard let self else {
                completion(nil)
                return
            }
            guard let json = self.loadBundledJSON(id: id) else {
                completion(nil)
                return
            }
            self.store.compileContentRuleList(
                forIdentifier: id,
                encodedContentRuleList: json
            ) { compiled, error in
                if let error {
                    print("Compile failed for \(id):", error)
                }
                completion(compiled)
            }
        }
    }
    private func loadBundledJSON(id: String) -> String? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

Then:

let config = WKWebViewConfiguration()
AdblockService.shared.configure(config)
let webView = WKWebView(frame: .zero, configuration: config)

In practice, because configure is async, I’d make webview creation itself async or preload/compile blockers at app startup before opening the first tab.

update service pseudocode

final class AdblockUpdateService {
    func updateIfNeeded() async {
        guard shouldCheckForUpdates() else { return }
        do {
            let manifest = try await fetchManifest()
            for list in manifest.lists {
                guard list.hash != localHash(for: list.id) else { continue }
                let jsonData = try await download(list.url)
                guard sha256(jsonData) == list.sha256 else {
                    throw AdblockUpdateError.invalidHash
                }
                let jsonString = String(decoding: jsonData, as: UTF8.self)
                try await compile(id: list.id, json: jsonString)
                try saveJSON(jsonData, id: list.id)
                saveHash(list.sha256, id: list.id)
            }
            saveLastUpdateCheck(Date())
        } catch {
            print("Adblock update failed, keeping old lists:", error)
        }
    }
    private func compile(id: String, json: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: id,
                encodedContentRuleList: json
            ) { ruleList, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

do not convert huge lists on every launch

Bad:

launch app
fetch EasyList
parse EasyList
convert to JSON
compile JSON
create webview

Good:

launch app
use already compiled local rule lists immediately
background-check update maybe once/day
compile only if source hash changed
activate next tab/session after compile success

Compilation can be expensive, and WebKit’s compiled rule-list cache should be treated as valuable. A third-party SDK guide also notes that compiling a ruleset can be expensive and recommends caching by ID.  ￼

what I’d put in the engineering plan

# Freedom iOS Adblocking Plan
## Goal
Implement native ad/tracker blocking in Freedom iOS using WebKit content blockers, with bundled baseline rules and runtime-updatable filter lists.
## Non-goals for v1
- No full uBlock Origin engine.
- No Chrome/Firefox extension support.
- No scriptlet injection.
- No procedural cosmetic filtering.
- No VPN/DNS-level system blocker.
## Rule sources
Initial filter sources:
- EasyList: baseline ad blocking.
- EasyPrivacy: tracker blocking.
Future optional sources:
- Fanboy Annoyances / cookie banners.
- AdGuard DNS/security filters.
- Freedom custom decentralized-web allow/block rules.
## Architecture
The app uses Apple `WKContentRuleListStore` to compile WebKit JSON content-blocking rules and attaches compiled `WKContentRuleList` objects to each `WKWebViewConfiguration`.
Filter-list conversion happens outside the critical path. The app ships with bundled generated JSON rules and updates them at runtime from Freedom-controlled update artifacts.
## Pipeline
1. Fetch upstream ABP-compatible filter lists.
2. Convert filter syntax to Safari/WebKit content-blocker JSON.
3. Split rules into categories:
   - `freedom-ads`
   - `freedom-privacy`
   - `freedom-annoyances`
   - `freedom-social`
   - `freedom-security`
   - `freedom-custom`
4. Validate JSON.
5. Count rules and enforce per-list limits.
6. Generate manifest with hashes and metadata.
7. Publish JSON artifacts and manifest.
8. App downloads updated artifacts.
9. App verifies hash.
10. App compiles with `WKContentRuleListStore`.
11. App activates only after successful compile.
## Runtime behavior
On first launch:
- Use bundled fallback rule lists.
- Compile once and cache using stable identifiers.
- Attach compiled lists to all new tabs.
On later launches:
- Look up compiled lists by identifier.
- Attach immediately.
- Check for updates in background if older than 24 hours.
On update success:
- Compile new rules.
- Replace stored active version.
- New tabs use updated rules.
- Existing tabs may continue using previous configuration until reload.
On update failure:
- Keep previous known-good compiled rules.
- Log failure.
- Retry later.
## User controls
Settings:
- Block ads: on/off.
- Block trackers: on/off.
- Block cookie banners / annoyances: optional.
- Per-site disable.
- Custom user rules: later.
Site menu:
- “Disable blocking on this site”
- “Reload without blockers”
- “Report broken site”
## Legal / attribution
The app includes an attribution screen for EasyList/EasyPrivacy and displays source URLs, authors, and licenses.
## Implementation phases
### Phase 1
Hardcoded JSON proof of concept.
### Phase 2
Bundled EasyList/EasyPrivacy converted at build time.
### Phase 3
Runtime update manifest and signed/hash-verified downloads.
### Phase 4
Per-site allowlist and UI.
### Phase 5
Cosmetic filtering improvements and annoyance lists.
### Phase 6
Optional advanced protection: DNS/proxy mode, if App Store review risk is acceptable.

my actual recommendation

Do this:

v1:
  bundled compiled JSON from EasyList + EasyPrivacy
  generated during build / CI
  no runtime subscriptions yet
v2:
  runtime update manifest from your own server
  app downloads already-converted WebKit JSON
  app compiles locally with WKContentRuleListStore
v3:
  per-site allowlist + categories + cosmetic cleanup

The key design choice: do not make the iOS app itself a full EasyList/uBO parser unless you really need to. Build or reuse the converter in CI, publish WebKit-native artifacts, and keep the app’s job simple: verify, compile, attach.