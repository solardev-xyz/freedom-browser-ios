import XCTest
@testable import Freedom

final class HDKeyTests: XCTestCase {
    // MARK: - BIP-32 Test Vector 1 (en.bitcoin.it/wiki/BIP_0032_TestVectors)

    private let bip32Seed = Data(hex: "0x000102030405060708090a0b0c0d0e0f")!

    func testBIP32Vector1Master() throws {
        let master = try HDKey(seed: bip32Seed)
        XCTAssertEqual(
            master.privateKey.hexString,
            "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        )
        XCTAssertEqual(
            master.chainCode.hexString,
            "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508"
        )
    }

    func testBIP32Vector1HardenedChild() throws {
        let child = try HDKey(seed: bip32Seed).derive(Path(rawPath: "m/0'"))
        XCTAssertEqual(
            child.privateKey.hexString,
            "edb2e14f9ee77d26dd93b4ecede8d16ed408ce149b6cd80b0715a2d911a0afea"
        )
        XCTAssertEqual(
            child.chainCode.hexString,
            "47fdacbd0f1097043b78c63c20c34ef4ed9a111d980047ad16282c7ae6236141"
        )
    }

    /// `m/0'/1` — exercises the hardened → non-hardened transition. The
    /// non-hardened step is the one that requires materializing the parent
    /// compressed public key.
    func testBIP32Vector1MixedPath() throws {
        let child = try HDKey(seed: bip32Seed).derive(Path(rawPath: "m/0'/1"))
        XCTAssertEqual(
            child.privateKey.hexString,
            "3c6cb8d0f6a264c91ea8b5030fadaa8e538b020f0a387421a12de9319dc93368"
        )
        XCTAssertEqual(
            child.chainCode.hexString,
            "2a7857631386ba23dacac34180dd1983734e444fdbf774041578e9b6adb37c19"
        )
    }

    func testBIP32Vector1DeepPath() throws {
        let child = try HDKey(seed: bip32Seed).derive(Path(rawPath: "m/0'/1/2'/2/1000000000"))
        XCTAssertEqual(
            child.privateKey.hexString,
            "471b76e389e528d6de6d816857e012c5455051cad6660850e58372a6c3e6e7c8"
        )
    }

    // MARK: - Ethereum address cross-check with the Hardhat/Foundry mnemonic

    /// Canonical dev mnemonic shared by Hardhat and Foundry. First 20 account
    /// addresses at `m/44'/60'/0'/0/i` are printed on every `hardhat node` /
    /// `anvil` startup — the de-facto gold standard for cross-tool agreement.
    /// (We vary the *account* index instead, so only i=0 lines up with theirs.)
    private let hardhatMnemonic = "test test test test test test test test test test test junk"

    private func hardhatHD(at index: Int) throws -> HDKey {
        try Mnemonic(phrase: hardhatMnemonic)
            .hdKey()
            .derive(index == 0 ? .mainUser : .userAccount(index))
    }

    func testHardhatAccount0MatchesKnownAddress() throws {
        XCTAssertEqual(
            try hardhatHD(at: 0).ethereumAddress,
            "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
        )
    }

    func testAccountsAreDistinct() throws {
        let main = try hardhatHD(at: 0)
        let a1 = try hardhatHD(at: 1)
        let a2 = try hardhatHD(at: 2)
        XCTAssertNotEqual(try a1.ethereumAddress, try main.ethereumAddress)
        XCTAssertNotEqual(try a2.ethereumAddress, try main.ethereumAddress)
        XCTAssertNotEqual(try a1.ethereumAddress, try a2.ethereumAddress)
    }

    func testEthereumAddressIsLowercaseHex() throws {
        let addr = try hardhatHD(at: 0).ethereumAddress
        XCTAssertTrue(addr.hasPrefix("0x"))
        XCTAssertEqual(addr.count, 42)
        XCTAssertEqual(addr, addr.lowercased())
    }

    // MARK: - Path

    func testMainUserAndBeeDontCollide() {
        XCTAssertNotEqual(Path.mainUser, Path.beeWallet)
    }

    func testUserAccountPathShape() {
        XCTAssertEqual(Path.userAccount(1).rawPath, "m/44'/60'/1'/0/0")
        XCTAssertEqual(Path.userAccount(7).rawPath, "m/44'/60'/7'/0/0")
    }

    func testUserAccountZeroAliasesMainUser() {
        XCTAssertEqual(Path.userAccount(0), Path.mainUser)
    }

    func testInvalidPathMissingMPrefix() {
        XCTAssertThrowsError(try Path(rawPath: "44'/60'/0'/0/0"))
    }

    func testInvalidPathNonNumericComponent() {
        XCTAssertThrowsError(try Path(rawPath: "m/foo'/60'/0'/0/0"))
    }

    func testDerivingStepwiseMatchesCombined() throws {
        let combined = try HDKey(seed: bip32Seed).derive(Path(rawPath: "m/0'/1"))
        let stepwise = try HDKey(seed: bip32Seed)
            .derive(Path(rawPath: "m/0'"))
            .derive(Path(rawPath: "m/1"))
        XCTAssertEqual(combined, stepwise)
    }
}

private typealias Path = HDKey.Path
