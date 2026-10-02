import XCTest
@testable import Freedom

/// Desktop "Search settings": substring over label, helper line and
/// section, case-insensitive, grouped by section, with the chains that
/// exist at search time.
final class SettingsSearchTests: XCTestCase {
    private let entries = SettingsSearchIndex.entries(chains: [.gnosis, .mainnet])

    func testFindsControlsByLabelHelperLineAndKeyword() {
        XCTAssertEqual(SettingsSearchIndex.matches("private key", in: entries).map(\.id), ["wallet", "wallet.key"])
        XCTAssertTrue(SettingsSearchIndex.matches("ccip", in: entries).contains { $0.id == "ens.ccip" })
        XCTAssertTrue(SettingsSearchIndex.matches("MNEMONIC", in: entries).contains { $0.id == "wallet.phrase" })
        XCTAssertTrue(SettingsSearchIndex.matches("whitelist", in: entries).contains { $0.id == "adblock.allowlist" })
        XCTAssertTrue(SettingsSearchIndex.matches("searchTerms", in: entries).contains { $0.id == "search.custom" })
    }

    func testChainsAreSearchableAndOpenTheirEditor() throws {
        let gnosis = try XCTUnwrap(SettingsSearchIndex.matches("xdai", in: entries).first { $0.id == "chain:100" })
        XCTAssertEqual(gnosis.path, [.rpc, .chainEditor(100)])
        XCTAssertEqual(gnosis.section, "Chains")
        XCTAssertTrue(SettingsSearchIndex.matches("ethereum", in: entries).contains { $0.id == "chain:1" })
    }

    func testGroupsBySectionInIndexOrderAndIgnoresBlankQueries() {
        let groups = SettingsSearchIndex.grouped("endpoint", in: entries)
        XCTAssertEqual(groups.map(\.section), ["Name Resolution", "Swarm", "Chains"])
        XCTAssertTrue(groups.first { $0.section == "Chains" }?.entries.contains { $0.id == "chain:100" } == true)
        XCTAssertTrue(SettingsSearchIndex.matches("   ", in: entries).isEmpty)
        XCTAssertTrue(SettingsSearchIndex.grouped("zzzz-nothing", in: entries).isEmpty)
    }

    func testEveryEntryHasAPageAndUniqueID() {
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for entry in entries { XCTAssertFalse(entry.path.isEmpty, entry.id) }
    }
}
