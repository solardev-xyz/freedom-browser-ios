import XCTest
import web3
@testable import Freedom

@MainActor
final class QuorumWaveTests: XCTestCase {
    private let alpha = URL(string: "https://alpha.example.com")!
    private let bravo = URL(string: "https://bravo.example.com")!
    private let charlie = URL(string: "https://charlie.example.com")!
    private let delta = URL(string: "https://delta.example.com")!
    private let echo = URL(string: "https://echo.example.com")!

    func testAgreedDataWhenMMatchingBytes() async {
        let bytes = Data([0xAA, 0xBB])
        let resolver: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: bytes, resolverAddress: resolver),
                bravo: .data(resolvedData: bytes, resolverAddress: resolver),
                charlie: .data(resolvedData: bytes, resolverAddress: resolver),
            ])
        )
        if case .data(let b, _, let urls, .verified) = wave.resolution {
            XCTAssertEqual(b, bytes)
            XCTAssertGreaterThanOrEqual(urls.count, 2)
        } else {
            XCTFail("expected verified data, got \(wave.resolution)")
        }
    }

    func testAgreedNotFoundWhenMMatchingReasons() async {
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .notFound(reason: .noResolver),
                bravo: .notFound(reason: .noResolver),
                charlie: .notFound(reason: .noResolver),
            ])
        )
        if case .notFound(let reason, _, .verified) = wave.resolution {
            XCTAssertEqual(reason, .noResolver)
        } else {
            XCTFail("expected verified notFound, got \(wave.resolution)")
        }
    }

    func testMixedNotFoundReasonsBucketSeparately() async {
        // 2 NO_RESOLVER + 1 NO_CONTENTHASH with M=2. If reasons were lumped
        // the wave would "agree" on not-found at count=3 — conflating a
        // CCIP-gateway flake with a real registration miss. Bucketing
        // separately means NO_RESOLVER bucket reaches 2 and wins; the
        // NO_CONTENTHASH is just dissent within the not-found family.
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .notFound(reason: .noResolver),
                bravo: .notFound(reason: .noResolver),
                charlie: .notFound(reason: .noContenthash),
            ])
        )
        if case .notFound(let reason, let urls, .verified) = wave.resolution {
            XCTAssertEqual(reason, .noResolver)
            XCTAssertEqual(urls.count, 2)
        } else {
            XCTFail("expected NO_RESOLVER agreement only, got \(wave.resolution)")
        }
    }

    func testConflictOnDistinctData() async {
        // Three distinct bytes responses, M=2. No bucket reaches threshold.
        let resolver: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: Data([0x01]), resolverAddress: resolver),
                bravo: .data(resolvedData: Data([0x02]), resolverAddress: resolver),
                charlie: .data(resolvedData: Data([0x03]), resolverAddress: resolver),
            ])
        )
        if case .conflict = wave.resolution {} else { XCTFail("expected conflict, got \(wave.resolution)") }
        XCTAssertEqual(wave.byData.count, 3, "three distinct buckets recorded")
    }

    func testUnverifiedDataOnSingleSemanticResponse() async {
        let bytes = Data([0xAA])
        let resolver: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: bytes, resolverAddress: resolver),
                bravo: .error(URLError(.timedOut)),
                charlie: .error(URLError(.timedOut)),
            ])
        )
        if case .data(let b, _, let urls, .unverified) = wave.resolution {
            XCTAssertEqual(b, bytes)
            XCTAssertEqual(urls, [alpha])
        } else {
            XCTFail("expected unverified data, got \(wave.resolution)")
        }
    }

    func testAllErroredWhenEveryLegFails() async {
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .error(URLError(.timedOut)),
                bravo: .error(URLError(.timedOut)),
                charlie: .error(URLError(.timedOut)),
            ])
        )
        if case .allErrored = wave.resolution {} else { XCTFail("expected allErrored, got \(wave.resolution)") }
    }

    func testConflictOnMixedDataAndNotFound() async {
        // 1 data + 1 NO_RESOLVER + 1 NO_CONTENTHASH, M=2. No bucket reaches 2.
        let resolver: EthereumAddress = "0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe"
        let wave = await QuorumWave.run(
            providers: [alpha, bravo, charlie],
            dnsEncodedName: Data(), callData: Data(),
            blockHash: "0xblock", timeout: 5, m: 2,
            legRunner: makeLegRunner([
                alpha: .data(resolvedData: Data([0xAA]), resolverAddress: resolver),
                bravo: .notFound(reason: .noResolver),
                charlie: .notFound(reason: .noContenthash),
            ])
        )
        if case .conflict = wave.resolution {} else { XCTFail("expected conflict, got \(wave.resolution)") }
        XCTAssertEqual(wave.byData.count, 1)
        XCTAssertEqual(wave.byNegative.count, 2)
    }
}
