import XCTest
import BigInt
import web3
@testable import Freedom

/// ENSv2 readiness: address lookups carry the destination chain
/// (ENSIP-11 coin type, `addr(bytes32,uint256)`), caches are chain-scoped,
/// an absent L2 record never falls back to the Ethereum address, and
/// reverse lookups ask for the chain's primary name (ENSIP-19).
@MainActor
final class ENSChainScopedResolveTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let base = 8453
    private let baseCoinType = BigUInt(2_147_492_101) // 0x80000000 | 8453
    private let l1: EthereumAddress = "0x2B0F09F23193de2Fb66258a10886B9f06903276c"
    private let l2: EthereumAddress = "0x7d3a48269416507E6d207a9449E7800971823Ffa"
    private let resolverAddress: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "ENSChainScopedResolveTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensResolutionMethod = .quorum
        settings.enableEnsQuorum = false
        settings.ensPublicRpcProviders = [alpha.absoluteString]
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = mainnetPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    private func makeAnchor() -> AnchorCorroboration {
        AnchorCorroboration(
            pool: pool, settings: settings,
            clock: { [unowned self] in self.clock.now },
            fetchHead: { _, _, _ in 1000 },
            fetchHash: { _, _, _ in "0xblock" }
        )
    }

    nonisolated private func paddedAddress(_ address: EthereumAddress) -> Data {
        Data(repeating: 0, count: 12) + address.asString().web3.hexData!
    }

    // MARK: - ABI helpers

    func testCoinTypeFollowsENSIP11() {
        XCTAssertEqual(UniversalResolverABI.coinType(forChainID: 1), 60)
        XCTAssertEqual(UniversalResolverABI.coinType(forChainID: base), baseCoinType)
        XCTAssertEqual(UniversalResolverABI.coinType(forChainID: 100), BigUInt(0x8000_0064))
        XCTAssertNil(UniversalResolverABI.coinType(forChainID: 0))
        XCTAssertNil(UniversalResolverABI.coinType(forChainID: 0x8000_0000))
    }

    func testAddrCallDataSelectsLegacyOrMulticoinRecord() throws {
        let node = Data(repeating: 0xAB, count: 32)
        XCTAssertEqual(
            UniversalResolverABI.addrCallData(node: node, chainID: 1),
            UniversalResolverABI.addrSelector + node
        )
        let multicoin = try XCTUnwrap(UniversalResolverABI.addrCallData(node: node, chainID: base))
        XCTAssertEqual(multicoin.prefix(4), Data([0xf1, 0xcb, 0x7e, 0x06]))
        XCTAssertEqual(multicoin.count, 4 + 32 + 32)
        XCTAssertEqual(BigUInt(multicoin.suffix(32)), baseCoinType)
    }

    func testDecodeAddrResponseHandlesBothShapes() {
        XCTAssertEqual(
            UniversalResolverABI.decodeAddrResponse(paddedAddress(l1), chainID: 1)?.asString().lowercased(),
            l1.asString().lowercased()
        )
        let bytes = abiEncodeBytes(l2.asString().web3.hexData!)
        XCTAssertEqual(
            UniversalResolverABI.decodeAddrResponse(bytes, chainID: base)?.asString().lowercased(),
            l2.asString().lowercased()
        )
        XCTAssertEqual(UniversalResolverABI.decodeAddrResponse(abiEncodeBytes(Data()), chainID: base), .zero)
        // A non-EVM-sized payload is malformed for an EVM coin type.
        XCTAssertNil(UniversalResolverABI.decodeAddrResponse(abiEncodeBytes(Data([1, 2, 3])), chainID: base))
    }

    // MARK: - Forward

    /// Same name, two chains, two records (the `test.ses.eth` guide
    /// fixture): each chain gets its own record and its own cache entry.
    func testResolveAddressUsesTheDestinationChainRecord() async throws {
        let l1Payload = paddedAddress(l1)
        let l2Payload = abiEncodeBytes(l2.asString().web3.hexData!)
        let seen = CallDataLog()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: { url, _, callData, _, _, _, _ in
                await seen.append(callData)
                let multicoin = callData.prefix(4) == UniversalResolverABI.multicoinAddrSelector
                return QuorumLeg.Outcome(
                    url: url,
                    kind: .data(resolvedData: multicoin ? l2Payload : l1Payload, resolverAddress: self.resolverAddress)
                )
            },
            clock: { [unowned self] in self.clock.now }
        )
        let onL1 = try await resolver.resolveAddress("test.ses.eth")
        let onBase = try await resolver.resolveAddress("test.ses.eth", chainID: base)
        XCTAssertEqual(onL1.asString().lowercased(), l1.asString().lowercased())
        XCTAssertEqual(onBase.asString().lowercased(), l2.asString().lowercased())

        let calls = await seen.entries
        XCTAssertEqual(calls.count, 2, "distinct chains must not share a cache entry")
        XCTAssertEqual(calls[0].prefix(4), UniversalResolverABI.addrSelector)
        XCTAssertEqual(calls[1].prefix(4), UniversalResolverABI.multicoinAddrSelector)
        XCTAssertEqual(BigUInt(calls[1].suffix(32)), baseCoinType)

        // Second Base lookup hits the chain-scoped cache.
        _ = try await resolver.resolveAddress("test.ses.eth", chainID: base)
        let after = await seen.entries
        XCTAssertEqual(after.count, 2)
    }

    /// No L2 record ⇒ `.emptyAddress`, never the Ethereum address.
    func testAbsentL2RecordDoesNotFallBackToL1() async {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: { url, _, callData, _, _, _, _ in
                let multicoin = callData.prefix(4) == UniversalResolverABI.multicoinAddrSelector
                return QuorumLeg.Outcome(
                    url: url,
                    kind: .data(
                        resolvedData: multicoin ? abiEncodeBytes(Data()) : self.paddedAddress(self.l1),
                        resolverAddress: self.resolverAddress
                    )
                )
            },
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveAddress("l1only.eth", chainID: base)
            XCTFail("expected emptyAddress")
        } catch ENSResolutionError.notFound(let reason, _) {
            XCTAssertEqual(reason, .emptyAddress)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testNameNftSystemsRefuseOffMainnet() async {
        let hits = ActorCallTracker()
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: { url, _, _, _, _, _, _ in
                await hits.increment()
                return QuorumLeg.Outcome(url: url, kind: .data(resolvedData: self.paddedAddress(self.l1), resolverAddress: self.resolverAddress))
            },
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveAddress("wns.wei", chainID: base)
            XCTFail("expected notSupportedOnChain")
        } catch ENSResolutionError.notSupportedOnChain(let system, let chainID) {
            XCTAssertEqual(system, .wns)
            XCTAssertEqual(chainID, base)
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let n = await hits.value
        XCTAssertEqual(n, 0, "must refuse before any network call")
    }

    func testUnrepresentableChainIsRejected() async {
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            legRunner: makeLegRunner([:]),
            clock: { [unowned self] in self.clock.now }
        )
        do {
            _ = try await resolver.resolveAddress("vitalik.eth", chainID: 0x8000_0000)
            XCTFail("expected unsupportedChain")
        } catch ENSResolutionError.unsupportedChain(let chainID) {
            XCTAssertEqual(chainID, 0x8000_0000)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Reverse

    func testReverseCarriesTheChainCoinTypeAndScopesTheCache() async throws {
        let bodies = CallDataLog()
        let encoder = ABIFunctionEncoder("_")
        try encoder.encode("base.eth")
        try encoder.encode(resolverAddress)
        try encoder.encode(resolverAddress)
        let tuple = Data(try encoder.encoded().dropFirst(4)).web3.hexString
        let envelope = try rpcResult(tuple)
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            reverseTransport: { _, body, _ in
                await bodies.append(body)
                return envelope
            },
            clock: { [unowned self] in self.clock.now }
        )
        let onBase = try await resolver.reverseResolve(address: l2, chainID: base)
        XCTAssertEqual(onBase, .verified(name: "base.eth"))
        let first = await bodies.entries
        XCTAssertEqual(first.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first[0]) as? [String: Any])
        let params = try XCTUnwrap(json["params"] as? [Any])
        let call = try XCTUnwrap(params[0] as? [String: String])
        let data = try XCTUnwrap(call["data"]?.web3.hexData)
        // reverse(bytes,uint256): selector, offset word, coinType word, then the bytes tail.
        XCTAssertEqual(BigUInt(data[36..<68]), baseCoinType)

        // Mainnet lookup for the same address is a different cache entry.
        _ = try await resolver.reverseResolve(address: l2)
        let second = await bodies.entries
        XCTAssertEqual(second.count, 2)
        let json2 = try XCTUnwrap(JSONSerialization.jsonObject(with: second[1]) as? [String: Any])
        let call2 = try XCTUnwrap((json2["params"] as? [Any])?[0] as? [String: String])
        let data2 = try XCTUnwrap(call2["data"]?.web3.hexData)
        XCTAssertEqual(BigUInt(data2[36..<68]), 60)
    }

    /// The WNS/GNS reverse fallback only knows mainnet records: off
    /// mainnet, `.none` from ENS is final and the registries are not
    /// consulted.
    func testContractBackedReverseFallbackSkippedOffMainnet() async throws {
        let hits = ActorCallTracker()
        let encoder = ABIFunctionEncoder("_")
        try encoder.encode("")
        try encoder.encode(resolverAddress)
        try encoder.encode(resolverAddress)
        let empty = try rpcResult(Data(try encoder.encoded().dropFirst(4)).web3.hexString)
        let resolver = ENSResolver(
            pool: pool, settings: settings, anchor: makeAnchor(),
            reverseTransport: { _, _, _ in
                await hits.increment()
                return empty
            },
            clock: { [unowned self] in self.clock.now }
        )
        let result = try await resolver.reverseResolve(address: l2, chainID: base)
        XCTAssertEqual(result, .none)
        let n = await hits.value
        XCTAssertEqual(n, 1, "only the UR reverse call; no NameNFT registry probes")
    }
}

private actor CallDataLog {
    private(set) var entries: [Data] = []
    func append(_ data: Data) { entries.append(data) }
}
