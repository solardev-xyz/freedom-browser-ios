import XCTest
import WebKit
@testable import Freedom

/// Per-site permission decisions: origin keys, remembered answers, the
/// dismissal embargo, revocation.
@MainActor
final class SitePermissionStoreTests: XCTestCase {
    /// Main-actor objects must not be deallocated synchronously inside a
    /// test body (known runner abort); fixtures live until teardown.
    private var keep: [SitePermissionStore] = []

    private func store(defaults: UserDefaults? = nil) -> SitePermissionStore {
        let defaults = defaults ?? UserDefaults(suiteName: "SitePermissionStoreTests-\(UUID().uuidString)")!
        let s = SitePermissionStore(defaults: defaults)
        keep.append(s)
        return s
    }

    func testOriginKeyIsSchemeHostPort() {
        XCTAssertEqual(SitePermissionStore.origin(for: URL(string: "https://Example.com/path?q=1")!), "https://example.com")
        XCTAssertEqual(SitePermissionStore.origin(for: URL(string: "http://localhost:8080/")!), "http://localhost:8080")
        XCTAssertEqual(SitePermissionStore.origin(for: URL(string: "bzz://vitalik.eth/blog")!), "bzz://vitalik.eth")
        XCTAssertNil(SitePermissionStore.origin(for: URL(string: "about:blank")!))
    }

    func testMediaCaptureTypesMapToKinds() {
        XCTAssertEqual(SitePermissionKind.kinds(for: .camera), [.camera])
        XCTAssertEqual(SitePermissionKind.kinds(for: .microphone), [.microphone])
        XCTAssertEqual(SitePermissionKind.kinds(for: .cameraAndMicrophone), [.camera, .microphone])
    }

    func testUnknownSiteMustBeAskedAndRememberedAnswersSettle() {
        let s = store()
        XCTAssertNil(s.settled(origin: "https://a.example", kinds: [.camera]))
        s.remember(origin: "https://a.example", kinds: [.camera], decision: .allow)
        XCTAssertEqual(s.settled(origin: "https://a.example", kinds: [.camera]), .allow)
        // Camera + microphone needs BOTH allowed; one unknown → ask.
        XCTAssertNil(s.settled(origin: "https://a.example", kinds: [.camera, .microphone]))
        s.remember(origin: "https://a.example", kinds: [.microphone], decision: .block)
        // Any remembered block wins.
        XCTAssertEqual(s.settled(origin: "https://a.example", kinds: [.camera, .microphone]), .block)
        XCTAssertNil(s.settled(origin: "https://b.example", kinds: [.camera]), "decisions are per site")
    }

    func testThirdDismissalInARowEmbargoesForTheSession() {
        let s = store()
        XCTAssertFalse(s.noteDismissal(origin: "https://a.example", kinds: [.camera]))
        XCTAssertFalse(s.noteDismissal(origin: "https://a.example", kinds: [.camera]))
        XCTAssertNil(s.settled(origin: "https://a.example", kinds: [.camera]), "two dismissals still ask")
        XCTAssertTrue(s.noteDismissal(origin: "https://a.example", kinds: [.camera]))
        XCTAssertEqual(s.settled(origin: "https://a.example", kinds: [.camera]), .block)
        XCTAssertTrue(s.isSessionBlocked(origin: "https://a.example", kind: .camera))
        XCTAssertTrue(s.origins.contains("https://a.example"), "embargoes are listed")
        // Nothing was persisted: a fresh store on the same defaults has no decision.
        XCTAssertNil(s.decision(origin: "https://a.example", kind: .camera))
        // Revoking lifts the embargo so the site can ask again.
        s.revoke(origin: "https://a.example", kind: .camera)
        XCTAssertNil(s.settled(origin: "https://a.example", kinds: [.camera]))
    }

    func testAnsweringResetsTheDismissalStreak() {
        let s = store()
        s.noteDismissal(origin: "https://a.example", kinds: [.microphone])
        s.noteDismissal(origin: "https://a.example", kinds: [.microphone])
        s.noteAnswered(origin: "https://a.example", kinds: [.microphone])
        XCTAssertFalse(s.noteDismissal(origin: "https://a.example", kinds: [.microphone]))
        XCTAssertFalse(s.isSessionBlocked(origin: "https://a.example", kind: .microphone))
    }

    func testDecisionsPersistAndRemoveAllClears() {
        let defaults = UserDefaults(suiteName: "SitePermissionStoreTests-persist-\(UUID().uuidString)")!
        let first = store(defaults: defaults)
        first.remember(origin: "https://a.example", kinds: [.camera, .motion], decision: .allow)
        let second = store(defaults: defaults)
        XCTAssertEqual(second.decision(origin: "https://a.example", kind: .camera), .allow)
        XCTAssertEqual(second.decision(origin: "https://a.example", kind: .motion), .allow)
        second.revoke(origin: "https://a.example", kind: .camera)
        XCTAssertNil(second.decision(origin: "https://a.example", kind: .camera))
        XCTAssertEqual(second.decision(origin: "https://a.example", kind: .motion), .allow)
        second.removeAll()
        XCTAssertTrue(second.origins.isEmpty)
        XCTAssertTrue(store(defaults: defaults).origins.isEmpty)
    }
}
