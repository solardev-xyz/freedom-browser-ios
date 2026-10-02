import MyotisKit
import XCTest
@testable import Freedom

/// Ethereum and Gnosis light clients switch separately under the master.
@MainActor
final class SettingsStoreMyotisTests: XCTestCase {
    private var defaults: UserDefaults!
    /// Main-actor objects must not be deallocated inside a test body
    /// (known runner abort); fixtures live until teardown.
    private var keep: [SettingsStore] = []

    override func setUp() {
        defaults = UserDefaults(suiteName: "SettingsStoreMyotisTests-\(UUID().uuidString)")
    }

    private func store() -> SettingsStore {
        let s = SettingsStore(defaults: defaults)
        keep.append(s)
        return s
    }

    func testBothNetworksDefaultOnUnderTheMaster() {
        let settings = store()
        XCTAssertTrue(settings.myotisNodeEnabled)
        XCTAssertEqual(settings.myotisEnabledNetworks, [.mainnet, .gnosis])
        XCTAssertTrue(settings.isMyotisEnabled(chainID: 1))
        XCTAssertTrue(settings.isMyotisEnabled(chainID: 100))
        XCTAssertFalse(settings.isMyotisEnabled(chainID: 8453))
    }

    func testOneNetworkOffPersistsAndTheMasterWins() {
        let settings = store()
        settings.setMyotisNetworkEnabled(.gnosis, false)
        XCTAssertEqual(settings.myotisEnabledNetworks, [.mainnet])
        XCTAssertFalse(settings.isMyotisEnabled(chainID: 100))
        XCTAssertTrue(settings.isMyotisEnabled(chainID: 1))
        XCTAssertEqual(store().myotisEnabledNetworks, [.mainnet])
        settings.myotisNodeEnabled = false
        XCTAssertTrue(settings.myotisEnabledNetworks.isEmpty)
        XCTAssertFalse(settings.isMyotisEnabled(chainID: 1))
    }
}
