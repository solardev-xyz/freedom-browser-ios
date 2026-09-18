import XCTest
import Colibri
import web3
@testable import Freedom

/// Live mainnet run of the ENSv2 readiness guide's fixtures
/// (https://docs.ens.domains/web/ensv2-readiness/) through the real
/// resolver: direct single-source, block-pinned quorum and, when the
/// Colibri gate is also set, the Colibri tier with quorum fallback.
/// Disabled by default; opt in via `TEST_RUNNER_ENSV2_LIVE=1`
/// (plus `TEST_RUNNER_COLIBRI_E2E=1` for the Colibri rows).
///
///   TEST_RUNNER_ENSV2_LIVE=1 TEST_RUNNER_COLIBRI_E2E=1 xcodebuild test \
///     -project Freedom/Freedom.xcodeproj -scheme Freedom \
///     -destination 'id=<sim-udid>' \
///     -only-testing FreedomTests/ENSv2ReadinessLiveTests
@MainActor
final class ENSv2ReadinessLiveTests: XCTestCase {
    private var stack: ChainStackBundle!
    private var storageDir: URL?

    private struct Fixture {
        let name: String
        let chainID: Int
        let address: String
    }

    /// The guide's fixtures plus the chain-specific pair desktop's audit
    /// verified. Ethereum rows use the legacy record, the Base row the
    /// ENSIP-11 multicoin record.
    private static let fixtures: [Fixture] = [
        Fixture(name: "ur.integration-tests.eth", chainID: 1, address: "0x2222222222222222222222222222222222222222"),
        Fixture(name: "test.offchaindemo.eth", chainID: 1, address: "0x779981590E7Ccc0CFAe8040Ce7151324747cDb97"),
        Fixture(name: "gregskril.com", chainID: 1, address: "0x179A862703a4adfb29896552DF9e307980D19285"),
        Fixture(name: "test.ses.eth", chainID: 1, address: "0x2B0F09F23193de2Fb66258a10886B9f06903276c"),
        Fixture(name: "test.ses.eth", chainID: 8453, address: "0x7d3a48269416507E6d207a9449E7800971823Ffa"),
    ]

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["ENSV2_LIVE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_ENSV2_LIVE=1 to run the live ENSv2 readiness suite")
        }
        executionTimeAllowance = 180
        stack = try ChainStackBundle()
        stack.settings.enableCcipRead = true
    }

    override func tearDown() async throws {
        if storageDir != nil { StorageBridge.implementation = nil }
        if let dir = storageDir { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    private func resolver(method: ENSResolutionMethod, quorum: Bool) -> ENSResolver {
        stack.settings.ensResolutionMethod = method
        stack.settings.enableEnsQuorum = quorum
        stack.settings.ensFallbackToQuorum = true
        var colibri: ColibriENSClient?
        if method == .colibri {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ensv2-colibri-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            ColibriDiskStorage.register(directory: dir)
            storageDir = dir
            colibri = ColibriENSClient(settings: stack.settings, chainStore: stack.chainStore)
        }
        return ENSResolver(pool: stack.mainnetPool, settings: stack.settings, colibri: colibri)
    }

    private func check(_ resolver: ENSResolver, label: String) async {
        for fixture in Self.fixtures {
            do {
                let address = try await resolver.resolveAddress(fixture.name, chainID: fixture.chainID)
                XCTAssertEqual(
                    address.asString().lowercased(), fixture.address.lowercased(),
                    "\(label): \(fixture.name) on chain \(fixture.chainID)"
                )
                print("[ensv2] \(label) \(fixture.name)@\(fixture.chainID) → \(address.toChecksumAddress())")
            } catch {
                XCTFail("\(label): \(fixture.name) on chain \(fixture.chainID) failed: \(ENSErrorFormatting.describe(error)) [\(error)]")
            }
        }
    }

    func testDirectSingleSource() async {
        await check(resolver(method: .quorum, quorum: false), label: "direct")
    }

    func testBlockPinnedQuorum() async {
        await check(resolver(method: .quorum, quorum: true), label: "quorum")
    }

    func testColibriWithQuorumFallback() async throws {
        guard ProcessInfo.processInfo.environment["COLIBRI_E2E"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_COLIBRI_E2E=1 for the Colibri rows")
        }
        await check(resolver(method: .colibri, quorum: true), label: "colibri")
    }

    /// The checker fixture's contenthash is the plain-text IPFS file the
    /// plain-text probe exists for.
    func testCheckerContenthashResolvesToTheIpfsFixture() async throws {
        let content = try await resolver(method: .quorum, quorum: true).resolveContent("ur.integration-tests.eth")
        XCTAssertEqual(content.codec, .ipfs)
        XCTAssertEqual(content.contentRef, "Qmaisz6NMhDB51cCvNWa1GMS7LU1pAxdF4Ld6Ft9kZEP2a")
        XCTAssertEqual(content.uri.absoluteString, "ipfs://ur.integration-tests.eth")
        print("[ensv2] contenthash ur.integration-tests.eth → \(content.uri) via \(content.trust.method) (\(content.trust.level))")
    }

    /// The reverse record of the Base fixture asks for the Base primary
    /// name (ENSIP-19); it may legitimately be unset, but the call must
    /// not fail and must never return an Ethereum primary for it.
    func testReverseOnBaseUsesTheChainCoinType() async throws {
        let resolver = resolver(method: .quorum, quorum: true)
        let onBase = try await resolver.reverseResolve(
            address: EthereumAddress("0x7d3a48269416507E6d207a9449E7800971823Ffa"), chainID: 8453
        )
        print("[ensv2] reverse 0x7d3a…3Ffa@8453 → \(onBase)")
        if case .unverified = onBase { XCTFail("Base reverse must not surface a mismatch: \(onBase)") }
    }
}
