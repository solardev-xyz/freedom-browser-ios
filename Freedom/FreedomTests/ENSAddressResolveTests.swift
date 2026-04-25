import XCTest
import web3
@testable import Freedom

@MainActor
final class ENSAddressResolveTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let bravo = URL(string: "https://bravo.example.com")!
    private let charlie = URL(string: "https://charlie.example.com")!

    private let vitalik: EthereumAddress = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"
    private let resolverAddress: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "ENSAddressResolveTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensPublicRpcProviders = [alpha, bravo, charlie].map(\.absoluteString)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = EthereumRPCPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    private func makeAnchor() -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
    }

    /// `addr(bytes32) returns (address)` — static return, so the leg
    /// receives just the 32-byte ABI-padded address. No extra `bytes`
    /// wrap (that's contenthash's shape since `bytes` is dynamic).
    private func addrOutcome(_ address: EthereumAddress) -> QuorumWave.LegRunner {
        let payload = paddedAddress(address)
        let resolver = resolverAddress
        return { url, _, _, _, _, _ in
            QuorumLeg.Outcome(
                url: url,
                kind: .data(resolvedData: payload, resolverAddress: resolver)
            )
        }
    }

    private func paddedAddress(_ address: EthereumAddress) -> Data {
        let raw = address.asString().web3.hexData!     // 20 bytes
        return Data(repeating: 0, count: 12) + raw     // left-padded to 32
    }

    // MARK: - Scenarios

    func testResolveAddressReturnsForwardAddress() async throws {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: addrOutcome(vitalik),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.resolveAddress("vitalik.eth")
        XCTAssertEqual(result.asString().lowercased(), vitalik.asString().lowercased())
    }

    /// Zero-address from `addr()` is ENS's "no record set". Surface as
    /// `.notFound(reason: .emptyAddress)` so callers distinguish "no name"
    /// from "name with no address".
    func testZeroAddressSurfacesAsEmptyAddress() async {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: addrOutcome(.zero),
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveAddress("noaddress.eth")
            XCTFail("expected emptyAddress notFound")
        } catch ENSResolutionError.notFound(let reason, _) {
            XCTAssertEqual(reason, .emptyAddress)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testInvalidNameThrowsBeforeNetworkCall() async {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: addrOutcome(vitalik),
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveAddress("foo..eth")
            XCTFail("expected invalidName")
        } catch ENSResolutionError.invalidName {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Cache-hit short-circuit: second call with the same name within the
    /// 15-minute TTL doesn't re-run the consensus wave.
    func testCacheHitSkipsConsensus() async throws {
        let tracker = ActorCallTracker()
        let payload = paddedAddress(vitalik)
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: { url, _, _, _, _, _ in
                await tracker.increment()
                return QuorumLeg.Outcome(
                    url: url, kind: .data(resolvedData: payload, resolverAddress: self.resolverAddress)
                )
            },
            clock: { [unowned self] in self.clock.now }
        )
        _ = try await resolver.resolveAddress("vitalik.eth")
        let firstCount = await tracker.value
        _ = try await resolver.resolveAddress("vitalik.eth")
        let secondCount = await tracker.value
        XCTAssertEqual(firstCount, secondCount, "second resolution should hit cache")
    }
}

private extension EthereumAddress {
    static let zero: EthereumAddress = "0x0000000000000000000000000000000000000000"
}
