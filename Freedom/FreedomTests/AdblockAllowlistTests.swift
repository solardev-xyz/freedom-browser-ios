import XCTest
@testable import Freedom

/// The per-site switch in the site-settings sheet: which allowlist entry
/// turns blocking off for a host, and turning it back on.
@MainActor
final class AdblockAllowlistTests: XCTestCase {
    /// Main-actor fixtures outlive the test body (see SitePermissionStoreTests).
    private var keep: [AnyObject] = []

    private func service(allowlist: [String] = []) -> AdblockService {
        let defaults = UserDefaults(suiteName: "adblock-allowlist-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.adblockAllowlist = allowlist
        let service = AdblockService(settings: settings)
        keep.append(settings)
        keep.append(service)
        return service
    }

    func testEntryCoveringAHostIsItselfOrAParent() {
        let adblock = service(allowlist: ["youtube.com", "news.example.org"])
        XCTAssertEqual(adblock.allowlistEntry(covering: "m.youtube.com"), "youtube.com")
        XCTAssertEqual(adblock.allowlistEntry(covering: "www.youtube.com"), "youtube.com")
        XCTAssertEqual(adblock.allowlistEntry(covering: "news.example.org"), "news.example.org")
        XCTAssertNil(adblock.allowlistEntry(covering: "example.org"), "a child entry doesn't cover its parent")
        XCTAssertNil(adblock.allowlistEntry(covering: "notyoutube.com"))
    }

    func testTurningBlockingOffAddsTheHostAndOnRemovesEveryCoveringEntry() {
        let adblock = service(allowlist: ["youtube.com", "m.youtube.com", "other.org"])
        adblock.removeAllowlist(covering: "m.youtube.com")
        XCTAssertEqual(adblock.allowlistDomains, ["other.org"], "the parent entry goes too, or the switch would stay off")
        XCTAssertFalse(adblock.isAllowlisted(host: "m.youtube.com"))

        adblock.addAllowlist(domain: "www.spiegel.de")
        XCTAssertEqual(adblock.allowlistDomains, ["other.org", "spiegel.de"], "stored without www")
        XCTAssertTrue(adblock.isAllowlisted(host: "www.spiegel.de"))
    }

    func testPerSiteSwitchIsMootWithEveryListOff() {
        let adblock = service()
        for category in AdblockService.Category.allCases { adblock.setEnabled(category, false) }
        XCTAssertFalse(adblock.isAnyCategoryEnabled)
        adblock.setEnabled(.ads, true)
        XCTAssertTrue(adblock.isAnyCategoryEnabled)
    }
}
