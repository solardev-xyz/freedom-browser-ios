import XCTest
import web3
@testable import Freedom

// File-scope helpers so the @Sendable ReverseTransport closures can use
// them without tripping MainActor isolation.

private func rpcEnvelope(resultHex: String) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "result": resultHex,
    ])
}

/// ABI-encode a single `string` return the way `reverseResolve` does.
private func abiEncodeStringReturn(_ s: String) -> Data {
    let encoder = ABIFunctionEncoder("_")
    try! encoder.encode(s)
    return Data(try! encoder.encoded().dropFirst(4))
}

/// The `to` address of an eth_call request body — used to tell the UR
/// reverse call apart from the WNS/GNS `reverseResolve` calls in a
/// shared transport stub.
private func ethCallTarget(of body: Data) -> String? {
    guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let params = obj["params"] as? [Any],
          let call = params.first as? [String: Any],
          let to = call["to"] as? String else { return nil }
    return to.lowercased()
}

/// Records which NameNFT registries the transport stub was asked about.
private actor ContractQueryLog {
    private(set) var systems: [NameSystem] = []
    func record(_ system: NameSystem) { systems.append(system) }
}

/// Coverage for the NameNFT-backed name systems (WNS `.wei`, GNS `.gwei`)
/// added in parity with desktop PR #130. The consensus machinery is shared
/// with ENS; these tests pin the system routing, the direct-contract call
/// shape, and the reverse-resolution fallback with forward verification.
@MainActor
final class WeiGweiNameTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let alice: EthereumAddress = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"
    private let other: EthereumAddress = "0x00000000000000000000000000000000deadbeef"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "WeiGweiNameTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensPublicRpcProviders = [alpha].map(\.absoluteString)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = mainnetPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    // MARK: - NameSystem mapping

    func testForNameRoutesBySuffix() {
        XCTAssertEqual(NameSystem.forName("wns.wei"), .wns)
        XCTAssertEqual(NameSystem.forName("Apoorv.GWEI"), .gns)
        XCTAssertEqual(NameSystem.forName("vitalik.eth"), .ens)
        XCTAssertEqual(NameSystem.forName("myapp.box"), .ens)
        // Suffix match must be dot-anchored: "gwei" contains "wei" but
        // routes to GNS, and a suffix-less string is ENS.
        XCTAssertEqual(NameSystem.forName("foo.gwei"), .gns)
        XCTAssertEqual(NameSystem.forName("somethingwei"), .ens)
    }

    func testSupportedNameSuffixes() {
        XCTAssertTrue(NameSystem.isSupportedName("a.eth"))
        XCTAssertTrue(NameSystem.isSupportedName("a.box"))
        XCTAssertTrue(NameSystem.isSupportedName("a.wei"))
        XCTAssertTrue(NameSystem.isSupportedName("a.gwei"))
        XCTAssertFalse(NameSystem.isSupportedName("a.com"))
    }

    func testContractBackedSystemsHaveContracts() {
        XCTAssertNil(NameSystem.ens.contractAddress)
        for system in NameSystem.contractBacked {
            XCTAssertNotNil(system.contractAddress, "\(system) must carry a registry contract")
        }
    }

    // MARK: - Helpers

    private func makeAnchor() -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
    }

    /// EIP-1577 ipfs-ns contenthash carrying a CIDv1 raw CID — the live
    /// `wns.wei` record shape (raw codec 0x55, not dag-pb).
    private func ipfsCidV1RawContenthash() -> Data {
        Data([0xe3, 0x01, 0x01, 0x55, 0x12, 0x20]) + Data(repeating: 0xab, count: 32)
    }

    /// Captures what the wave hands each leg so tests can pin the
    /// system/calldata routing.
    private actor LegCapture {
        var nameSystem: NameSystem?
        var callData: Data?
        func record(system: NameSystem, callData: Data) {
            self.nameSystem = system
            self.callData = callData
        }
    }

    private func dataLegRunner(returning bytes: Data, capture: LegCapture? = nil) -> QuorumWave.LegRunner {
        let resolver = NameSystem.wns.contractAddress!
        return { url, _, callData, _, _, _, system in
            if let capture { await capture.record(system: system, callData: callData) }
            return QuorumLeg.Outcome(
                url: url,
                kind: .data(resolvedData: bytes, resolverAddress: resolver)
            )
        }
    }

    private func paddedAddressWord(_ address: EthereumAddress) -> Data {
        Data(repeating: 0, count: 12) + address.asString().web3.hexData!
    }

    /// Encode the UR `reverse()` `(string, address, address)` tuple.
    private func encodedReverseTuple(name: String) -> String {
        var data = Data()
        data.append(uint256(0x60))
        data.append(paddedAddressWord(alice))
        data.append(paddedAddressWord(alice))
        let nameBytes = Data(name.utf8)
        data.append(uint256(UInt64(nameBytes.count)))
        if !nameBytes.isEmpty {
            let padding = (32 - nameBytes.count % 32) % 32
            data.append(nameBytes + Data(repeating: 0, count: padding))
        }
        return "0x" + data.web3.hexString.web3.noHexPrefix
    }

    private func uint256(_ n: UInt64) -> Data {
        var data = Data(repeating: 0, count: 32)
        var v = n
        for i in 0..<8 {
            data[31 - i] = UInt8(v & 0xff)
            v >>= 8
        }
        return data
    }

    /// Transport stub routing by eth_call target: UR reverse → an empty
    /// (or named) primary tuple; WNS/GNS registries → the given claimed
    /// names as `reverseResolve` string returns. Queries to the
    /// registries are recorded in `log`.
    private func routedTransport(
        urPrimary: String = "",
        wnsClaim: String = "",
        gnsClaim: String = "",
        log: ContractQueryLog? = nil
    ) -> ENSResolver.ReverseTransport {
        let wns = NameSystem.wns.contractAddress!.asString().lowercased()
        let gns = NameSystem.gns.contractAddress!.asString().lowercased()
        let urResponse = rpcEnvelope(resultHex: encodedReverseTuple(name: urPrimary))
        let wnsResponse = rpcEnvelope(resultHex: abiEncodeStringReturn(wnsClaim).web3.hexString)
        let gnsResponse = rpcEnvelope(resultHex: abiEncodeStringReturn(gnsClaim).web3.hexString)
        return { _, body, _ in
            switch ethCallTarget(of: body) {
            case wns:
                await log?.record(.wns)
                return wnsResponse
            case gns:
                await log?.record(.gns)
                return gnsResponse
            default:
                return urResponse
            }
        }
    }

    // MARK: - Forward content resolution

    func testResolveWeiContentRoutesToWNSAndKeepsNameHostURI() async throws {
        let capture = LegCapture()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: dataLegRunner(
                returning: abiEncodeBytes(ipfsCidV1RawContenthash()), capture: capture
            ),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.resolveContent("wns.wei")

        // Origin stays name-keyed (same rationale as .eth): storage
        // survives contenthash rotation, and the scheme handler
        // re-resolves via the name host.
        XCTAssertEqual(result.uri.absoluteString, "ipfs://wns.wei")
        XCTAssertEqual(result.codec, .ipfs)
        // CIDv1 raw renders as multibase-'b' base32 — never the CIDv0 form.
        XCTAssertTrue(result.contentRef.hasPrefix("baf"), "raw CID must render as CIDv1 base32, got \(result.contentRef)")
        XCTAssertEqual(result.trust.system, .wns)

        let system = await capture.nameSystem
        let callData = await capture.callData
        XCTAssertEqual(system, .wns, "leg must target the WNS registry, not the UR")
        XCTAssertEqual(callData?.prefix(4), UniversalResolverABI.contenthashSelector)
    }

    func testResolveGweiAddressRoutesToGNS() async throws {
        let capture = LegCapture()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: dataLegRunner(returning: paddedAddressWord(alice), capture: capture),
            clock: { [unowned self] in self.clock.now }
        )
        let address = try await resolver.resolveAddress("apoorv.gwei")
        XCTAssertEqual(address.asString().lowercased(), alice.asString().lowercased())

        let system = await capture.nameSystem
        let callData = await capture.callData
        XCTAssertEqual(system, .gns)
        XCTAssertEqual(callData?.prefix(4), UniversalResolverABI.addrSelector)
    }

    // MARK: - Reverse fallback

    /// ENS has no primary → WNS claims a name → forward-resolution round-
    /// trips to the same address → `.verified`. GNS is never consulted
    /// once WNS verifies.
    func testReverseFallsBackToWNSAndForwardVerifies() async throws {
        let log = ContractQueryLog()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: dataLegRunner(returning: paddedAddressWord(alice)),
            reverseTransport: routedTransport(wnsClaim: "alice.wei", log: log),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.reverseResolve(address: alice)
        XCTAssertEqual(result, .verified(name: "alice.wei"))
        let queried = await log.systems
        XCTAssertEqual(queried, [.wns], "verified WNS claim must short-circuit GNS")
    }

    /// The NameNFT reverse record is NOT verified on-chain — a claim whose
    /// forward resolution lands on a different address surfaces as
    /// `.unverified` with the claimed name (the spoof warning).
    func testReverseFallbackClaimFailingForwardVerifyIsUnverified() async throws {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            // Forward resolution returns a DIFFERENT address than the one
            // being reverse-resolved.
            legRunner: dataLegRunner(returning: paddedAddressWord(other)),
            reverseTransport: routedTransport(wnsClaim: "alice.wei"),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.reverseResolve(address: alice)
        XCTAssertEqual(result, .unverified(claimedName: "alice.wei"))
    }

    /// A registry claiming a name outside its own suffix (WNS claiming a
    /// `.eth`) is inherently unverifiable — surfaced as `.unverified`
    /// without a forward-resolution round-trip.
    func testReverseFallbackForeignSuffixClaimIsUnverified() async throws {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([:]),  // forward resolve must not be needed
            reverseTransport: routedTransport(wnsClaim: "bob.eth"),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.reverseResolve(address: alice)
        XCTAssertEqual(result, .unverified(claimedName: "bob.eth"))
    }

    /// No system claims anything → the ENS `.none` stands.
    func testReverseFallbackNoClaimsStaysNone() async throws {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([:]),
            reverseTransport: routedTransport(),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.reverseResolve(address: alice)
        XCTAssertEqual(result, .none)
    }

    /// An ENS primary name wins outright — the fallback never runs.
    func testReverseENSPrimaryShortCircuitsFallback() async throws {
        let log = ContractQueryLog()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([:]),
            reverseTransport: routedTransport(urPrimary: "alice.eth", log: log),
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.reverseResolve(address: alice)
        XCTAssertEqual(result, .verified(name: "alice.eth"))
        let queried = await log.systems
        XCTAssertTrue(queried.isEmpty, "ENS primary must skip the NameNFT registries")
    }
}
