import XCTest
import web3
@testable import Freedom

private func gatewayResponse(payloadHex: String = "0x01020304") -> CCIPResolver.GatewayResponse {
    let body = try! JSONSerialization.data(withJSONObject: ["data": payloadHex])
    return CCIPResolver.GatewayResponse(status: 200, body: body)
}

@MainActor
final class ENSReverseResolveTests: XCTestCase {
    private var settings: SettingsStore!
    private var pool: EthereumRPCPool!
    private var clock: MutableClock!

    private let alpha = URL(string: "https://alpha.example.com")!
    private let vitalik: EthereumAddress = "0xd8da6bf26964af9d7eed9e03e53415d37aa96045"
    private let resolverAddress: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"

    override func setUp() async throws {
        try await super.setUp()
        let defaults = UserDefaults(suiteName: "ENSReverseResolveTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        settings.ensPublicRpcProviders = [alpha].map(\.absoluteString)
        clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        pool = EthereumRPCPool(settings: settings, clock: { [unowned self] in self.clock.now })
    }

    private func makeResolver(
        transport: @escaping ENSResolver.ReverseTransport,
        ccipHTTP: @escaping CCIPResolver.HTTPClient = CCIPResolver.defaultHTTP
    ) -> ENSResolver {
        ENSResolver(
            pool: pool, settings: settings, anchor: nil,
            reverseTransport: transport,
            reverseCCIPHTTP: ccipHTTP,
            clock: { [unowned self] in self.clock.now }
        )
    }

    /// Build a JSON-RPC envelope wrapping an eth_call result, the same shape
    /// the bridge gets back from a real provider.
    private func envelope(resultHex: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "result": resultHex,
        ])
    }

    private func errorEnvelope(message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1,
            "error": ["code": -32000, "message": message],
        ])
    }

    /// EIP-474/1474 revert envelope: `error.data` carries the revert hex.
    /// CCIP detection gates on this field.
    private func revertEnvelope(dataHex: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1,
            "error": ["code": 3, "message": "execution reverted", "data": dataHex],
        ])
    }

    private func encodedOffchainLookupHex(gateway: String) -> String {
        encodeOffchainLookupRevert(address: resolverAddress, urls: [gateway]).web3.hexString
    }

    /// Encode a `(string primary, address resolver, address reverseResolver)`
    /// tuple — the UR's `reverse(bytes,uint256)` return shape.
    private func encodedTuple(name: String) -> String {
        var data = Data()
        // Heads: 3 words.
        data.append(uint256(0x60))                              // offset to string
        data.append(addressWord(resolverAddress))
        data.append(addressWord(resolverAddress))
        // Tail: string length + 32-byte-padded UTF-8.
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

    private func addressWord(_ address: EthereumAddress) -> Data {
        Data(repeating: 0, count: 12) + address.asString().web3.hexData!
    }

    // MARK: - Scenarios

    func testReverseReturnsPrimaryName() async throws {
        let response = envelope(resultHex: encodedTuple(name: "vitalik.eth"))
        let resolver = makeResolver { _, _, _ in response }
        let name = try await resolver.reverseResolve(address: vitalik)
        XCTAssertEqual(name, "vitalik.eth")
    }

    func testReverseEmptyNameReturnsNil() async throws {
        let response = envelope(resultHex: encodedTuple(name: ""))
        let resolver = makeResolver { _, _, _ in response }
        let name = try await resolver.reverseResolve(address: vitalik)
        XCTAssertNil(name)
    }

    /// RPC error envelopes (Cloudflare's -32603, Ankr's -32000, etc.) are
    /// provider quirks, not UR reverts — the modern UR catches inner
    /// reverts and returns empty bytes, never bubbles them up. Treat all
    /// `error` envelopes as transient and iterate to the next provider.
    func testReverseRPCErrorIteratesProviders() async throws {
        var callCount = 0
        let success = envelope(resultHex: encodedTuple(name: "vitalik.eth"))
        let error = errorEnvelope(message: "Internal error")
        let resolver = makeResolver { _, _, _ in
            callCount += 1
            return callCount == 1 ? error : success
        }
        // Single provider in the test setup, so we synthesize "next provider"
        // by retrying on the same closure. The first call gets the error
        // (continues), then transport runs out → throws ReverseError.
        do {
            _ = try await resolver.reverseResolve(address: vitalik)
            XCTFail("expected throw — single test provider returned an error envelope")
        } catch ENSResolver.ReverseError.allProvidersFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }


    /// Transport failure is transient — should throw, not cache, so the
    /// next attempt re-tries the network instead of returning a stale nil.
    func testReverseAllProvidersFailedThrows() async {
        let resolver = makeResolver { _, _, _ in
            throw URLError(.timedOut)
        }
        do {
            _ = try await resolver.reverseResolve(address: vitalik)
            XCTFail("expected ReverseError.allProvidersFailed")
        } catch ENSResolver.ReverseError.allProvidersFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Transport failures don't poison the cache: a follow-up call after
    /// a network blip can still resolve the name on retry.
    func testReverseTransportFailureNotCached() async throws {
        var callCount = 0
        let response = envelope(resultHex: encodedTuple(name: "vitalik.eth"))
        let resolver = makeResolver { _, _, _ in
            callCount += 1
            if callCount == 1 { throw URLError(.timedOut) }
            return response
        }
        // First call throws (transport failure across all providers).
        do {
            _ = try await resolver.reverseResolve(address: vitalik)
            XCTFail("expected throw on first attempt")
        } catch {}
        // Second call succeeds — proves we didn't cache the failure.
        let name = try await resolver.reverseResolve(address: vitalik)
        XCTAssertEqual(name, "vitalik.eth")
    }

    /// Provider's `eth_call` reverts with `OffchainLookup` (off-chain
    /// primary name like `avsa.eth`); CCIP retry hits the gateway, the
    /// callback returns the encoded `(string,address,address)` tuple,
    /// resolver decodes the primary name.
    func testReverseCCIPRetrySuccess() async throws {
        settings.enableCcipRead = true
        let lookupHex = encodedOffchainLookupHex(gateway: "https://gateway.example/{sender}/{data}.json")
        let revert = revertEnvelope(dataHex: lookupHex)
        let success = envelope(resultHex: encodedTuple(name: "avsa.eth"))
        var transportCalls = 0
        let transport: ENSResolver.ReverseTransport = { _, _, _ in
            transportCalls += 1
            // First hit is the reverse() call → OffchainLookup revert.
            // Second is the CCIP callback eth_call → the real tuple.
            return transportCalls == 1 ? revert : success
        }
        let http: CCIPResolver.HTTPClient = { _, _ in gatewayResponse() }
        let resolver = makeResolver(transport: transport, ccipHTTP: http)
        let name = try await resolver.reverseResolve(address: vitalik)
        XCTAssertEqual(name, "avsa.eth")
        XCTAssertEqual(transportCalls, 2, "one for the reverse(), one for the CCIP callback")
    }

    /// `enableCcipRead = false`: OffchainLookup revert is treated as
    /// any other provider error → fall through to the next provider.
    /// Single-provider test setup ⇒ exhausts the list ⇒ throws.
    func testReverseCCIPDisabledFallsThrough() async {
        settings.enableCcipRead = false
        let lookupHex = encodedOffchainLookupHex(gateway: "https://gateway.example/{data}")
        let revert = revertEnvelope(dataHex: lookupHex)
        let resolver = makeResolver(transport: { _, _, _ in revert })
        do {
            _ = try await resolver.reverseResolve(address: vitalik)
            XCTFail("expected ReverseError.allProvidersFailed when CCIP is off")
        } catch ENSResolver.ReverseError.allProvidersFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Gateway hop fails (HTTP throws); CCIP retry returns nil; provider
    /// iteration falls through. Same single-provider setup as above ⇒
    /// `allProvidersFailed`.
    func testReverseCCIPGatewayFailureFallsThrough() async {
        settings.enableCcipRead = true
        let lookupHex = encodedOffchainLookupHex(gateway: "https://broken.example/{data}")
        let revert = revertEnvelope(dataHex: lookupHex)
        let resolver = makeResolver(
            transport: { _, _, _ in revert },
            ccipHTTP: { _, _ in throw URLError(.cannotConnectToHost) }
        )
        do {
            _ = try await resolver.reverseResolve(address: vitalik)
            XCTFail("expected ReverseError.allProvidersFailed when gateway is unreachable")
        } catch ENSResolver.ReverseError.allProvidersFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testReverseCacheHitSkipsTransport() async throws {
        let tracker = ActorCallTracker()
        let response = envelope(resultHex: encodedTuple(name: "vitalik.eth"))
        let resolver = makeResolver { _, _, _ in
            await tracker.increment()
            return response
        }
        _ = try await resolver.reverseResolve(address: vitalik)
        let firstCount = await tracker.value
        _ = try await resolver.reverseResolve(address: vitalik)
        let secondCount = await tracker.value
        XCTAssertEqual(firstCount, secondCount, "second lookup should hit cache")
    }
}
