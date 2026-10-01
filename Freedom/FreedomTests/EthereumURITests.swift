import BigInt
import XCTest
@testable import Freedom

/// Mirrors desktop's `ethereum-uri.test.js`: the EIP-681 native-asset
/// subset, and what the Send form gets out of it.
final class EthereumURITests: XCTestCase {
    private let address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

    func testBareAddressDefaultsToMainnet() throws {
        let uri = try EthereumURI.parse("ethereum:\(address)").get()
        XCTAssertEqual(uri, EthereumURI(target: address, chainID: 1, valueWei: nil, label: nil))
    }

    func testNamesAreAccepted() throws {
        for name in ["vitalik.eth", "author.box", "alice.wei", "bob.gwei", "gregskril.com"] {
            XCTAssertEqual(try EthereumURI.parse("ethereum:\(name)").get().target, name, name)
        }
        // WebKit percent-encodes a non-ASCII label in an href.
        XCTAssertEqual(try EthereumURI.parse("ethereum:%F0%9F%A6%87.eth").get().target, "🦇.eth")
    }

    func testChainAndValueAndLabel() throws {
        let uri = try EthereumURI.parse("ETHEREUM:\(address)@100?value=1.5e18&label=Coffee+%26+cake").get()
        XCTAssertEqual(uri.chainID, 100)
        XCTAssertEqual(uri.valueWei, BigUInt("1500000000000000000"))
        XCTAssertEqual(uri.label, "Coffee & cake")
    }

    func testWeiValues() {
        XCTAssertEqual(EthereumURI.parseWei("1000000000000000000"), BigUInt("1000000000000000000"))
        XCTAssertEqual(EthereumURI.parseWei("1e18"), BigUInt("1000000000000000000"))
        XCTAssertEqual(EthereumURI.parseWei("1E18"), BigUInt("1000000000000000000"))
        XCTAssertEqual(EthereumURI.parseWei("1.5e17"), BigUInt("150000000000000000"))
        XCTAssertEqual(EthereumURI.parseWei("0"), 0)
        for bad in ["0.1", "1.5e0", "-1", "+1", "1e", "abc", "", "1e81", "1.e18", "١٢"] {
            XCTAssertNil(EthereumURI.parseWei(bad), bad)
        }
    }

    func testRefusals() {
        XCTAssertEqual(EthereumURI.parse("https://a.example/"), .failure(.notEthereumURI))
        XCTAssertEqual(EthereumURI.parse("ethereum:0xdac17f958d2ee523a2206206994597c13d831ec7/transfer?address=\(address)&uint256=1"),
                       .failure(.unsupportedFunction))
        for bad in ["ethereum:", "ethereum:\(address)@", "ethereum:\(address)@0", "ethereum:\(address)@1x",
                    "ethereum:0x1234", "ethereum:not a name", "ethereum:\(address)?value=0.5"] {
            XCTAssertEqual(EthereumURI.parse(bad), .failure(.malformed), bad)
        }
    }

    func testDecimalStringIsExact() {
        XCTAssertEqual(EthereumURI.decimalString(wei: BigUInt("1500000000000000000"), decimals: 18), "1.5")
        XCTAssertEqual(EthereumURI.decimalString(wei: BigUInt("1000000000000000001"), decimals: 18), "1.000000000000000001")
        XCTAssertEqual(EthereumURI.decimalString(wei: 1, decimals: 18), "0.000000000000000001")
        XCTAssertEqual(EthereumURI.decimalString(wei: BigUInt("2000000000000000000"), decimals: 18), "2")
        XCTAssertEqual(EthereumURI.decimalString(wei: 0, decimals: 18), "0")
    }

    func testSendRequestPrefillsTheForm() throws {
        let request = try SendRequest.make(from: "ethereum:vitalik.eth@100?value=250000000000000000", chain: Chain.find(id:)).get()
        XCTAssertEqual(request.chain, .gnosis)
        XCTAssertEqual(request.recipient, "vitalik.eth")
        XCTAssertEqual(request.amount, "0.25")
        // The form validates the amount it is handed the same way it
        // validates typing — round trip must be lossless.
        XCTAssertEqual(BalanceFormatter.parseAmount("0.25"), BigUInt("250000000000000000"))

        let bare = try SendRequest.make(from: "ethereum:\(address)", chain: Chain.find(id:)).get()
        XCTAssertEqual(bare.chain, .mainnet)
        XCTAssertNil(bare.amount)
        XCTAssertNil(try SendRequest.make(from: "ethereum:\(address)?value=0", chain: Chain.find(id:)).get().amount)
    }

    func testSendRequestRefusalsName() {
        XCTAssertEqual(SendRequest.make(from: "ethereum:\(address)@8453", chain: Chain.find(id:)), .failure(.unknownChain(8453)))
        XCTAssertEqual(SendRequest.make(from: "ethereum:x/transfer", chain: Chain.find(id:)), .failure(.unsupportedFunction))
        XCTAssertEqual(SendRequest.make(from: " ethereum:nope ", chain: Chain.find(id:)), .failure(.malformed("ethereum:nope")))
        XCTAssertTrue(SendRequest.Refusal.unknownChain(8453).message.contains("Settings → Chains"))
    }

    func testEthereumIsABrowserSchemeNotAnExternalApp() {
        XCTAssertFalse(ExternalLinks.isExternal(URL(string: "ethereum:\(address)@100?value=1")!))
        XCTAssertTrue(EthereumURI.isEthereumURI("  Ethereum:vitalik.eth"))
        XCTAssertFalse(EthereumURI.isEthereumURI("ethereumx:1"))
    }
}
