import XCTest
@testable import Freedom

final class TokenRegistryTests: XCTestCase {
    /// Native always first; ERC-20s preserve declaration order so the UI
    /// is stable across runs (no shuffling per session).
    func testTokensForGnosisListsNativeFirst() {
        let tokens = TokenRegistry.tokens(for: .gnosis)
        XCTAssertEqual(tokens.first?.symbol, "xDAI")
        XCTAssertNil(tokens.first?.address, "native must have nil address")
        XCTAssertEqual(tokens.map(\.symbol), ["xDAI", "xBZZ", "EURe"])
    }

    func testTokensForMainnetListsNativeFirst() {
        let tokens = TokenRegistry.tokens(for: .mainnet)
        XCTAssertEqual(tokens.first?.symbol, "ETH")
        XCTAssertNil(tokens.first?.address)
        XCTAssertEqual(tokens.map(\.symbol), ["ETH", "USDC", "USDT", "DAI", "EURC", "BZZ"])
    }

    /// Decimals are deliberately heterogeneous — USDC/USDT/EURC are 6,
    /// BZZ/xBZZ are 16, the rest 18. Anything that defaults to 18
    /// silently is a bug.
    func testDecimalsMatchDesktopRegistry() {
        let mainnet = TokenRegistry.tokens(for: .mainnet)
        XCTAssertEqual(mainnet.first { $0.symbol == "USDC" }?.decimals, 6)
        XCTAssertEqual(mainnet.first { $0.symbol == "USDT" }?.decimals, 6)
        XCTAssertEqual(mainnet.first { $0.symbol == "EURC" }?.decimals, 6)
        XCTAssertEqual(mainnet.first { $0.symbol == "DAI" }?.decimals, 18)
        XCTAssertEqual(mainnet.first { $0.symbol == "BZZ" }?.decimals, 16)

        let gnosis = TokenRegistry.tokens(for: .gnosis)
        XCTAssertEqual(gnosis.first { $0.symbol == "xBZZ" }?.decimals, 16)
        XCTAssertEqual(gnosis.first { $0.symbol == "EURe" }?.decimals, 18)
    }

    func testNativeLookup() {
        XCTAssertEqual(TokenRegistry.native(for: .gnosis).symbol, "xDAI")
        XCTAssertEqual(TokenRegistry.native(for: .mainnet).symbol, "ETH")
    }
}
