import XCTest
@testable import Freedom

@MainActor
final class NonceTrackerTests: XCTestCase {
    private let address = "0xabcdef"

    private func makeStubRPC(responses: [Data]) -> (WalletRPC, () -> Int) {
        let index = ResponseIndex()
        let registry = ChainRegistry(mainnetPool: EthereumRPCPool(settings: SettingsStore()))
        let rpc = WalletRPC(registry: registry) { _, _ in
            let i = index.next()
            XCTAssertLessThan(i, responses.count, "RPC called more times than stubbed")
            return responses[i]
        }
        return (rpc, index.snapshot)
    }

    /// Wrap the `Int` so we can mutate it safely from the Sendable transport closure.
    private final class ResponseIndex: @unchecked Sendable {
        private var i = 0
        func next() -> Int { defer { i += 1 }; return i }
        func snapshot() -> Int { i }
    }

    func testFirstCallFetchesFromChain() async throws {
        let (rpc, _) = makeStubRPC(responses: [try rpcResult("0x5")])
        let tracker = NonceTracker(rpc: rpc)
        let nonce = try await tracker.next(for: address, on: .gnosis)
        XCTAssertEqual(nonce, 5)
    }

    func testMarkSentBumpsCachedNonceAheadOfChain() async throws {
        // Chain reports 5 both times. After marking nonce 5 as sent, the
        // next call should return 6 (our optimistic next), not 5 (what the
        // chain still shows because the tx hasn't propagated).
        let (rpc, _) = makeStubRPC(responses: [
            try rpcResult("0x5"),
            try rpcResult("0x5"),
        ])
        let tracker = NonceTracker(rpc: rpc)
        _ = try await tracker.next(for: address, on: .gnosis)
        tracker.markSent(address: address, on: .gnosis, usedNonce: 5)
        let next = try await tracker.next(for: address, on: .gnosis)
        XCTAssertEqual(next, 6)
    }

    func testChainCatchUpSupersedesCache() async throws {
        // Chain eventually sees our broadcast and reports 7 (two sends
        // later). The cache shouldn't artificially hold nonce 6 back.
        let (rpc, _) = makeStubRPC(responses: [
            try rpcResult("0x5"),
            try rpcResult("0x7"),
        ])
        let tracker = NonceTracker(rpc: rpc)
        _ = try await tracker.next(for: address, on: .gnosis)
        tracker.markSent(address: address, on: .gnosis, usedNonce: 5)
        let next = try await tracker.next(for: address, on: .gnosis)
        XCTAssertEqual(next, 7)
    }

    func testInvalidateResetsToChain() async throws {
        let (rpc, _) = makeStubRPC(responses: [
            try rpcResult("0x5"),
            try rpcResult("0x5"),
        ])
        let tracker = NonceTracker(rpc: rpc)
        _ = try await tracker.next(for: address, on: .gnosis)
        tracker.markSent(address: address, on: .gnosis, usedNonce: 5)
        tracker.invalidate(address: address, on: .gnosis)
        let next = try await tracker.next(for: address, on: .gnosis)
        // After invalidate + re-fetch, we're back to whatever the chain
        // reports — the optimistic increment is gone.
        XCTAssertEqual(next, 5)
    }

    func testSeparateAccountsDontShareCache() async throws {
        let (rpc, _) = makeStubRPC(responses: [
            try rpcResult("0x5"),
            try rpcResult("0x10"),
        ])
        let tracker = NonceTracker(rpc: rpc)
        let a = try await tracker.next(for: "0xaa", on: .gnosis)
        let b = try await tracker.next(for: "0xbb", on: .gnosis)
        XCTAssertEqual(a, 5)
        XCTAssertEqual(b, 16)
    }

    func testCaseInsensitiveAddress() async throws {
        // 0xABCD and 0xabcd should hit the same cache entry — we lowercase
        // internally so the user's checksum casing doesn't fragment state.
        let (rpc, _) = makeStubRPC(responses: [
            try rpcResult("0x5"),
            try rpcResult("0x5"),
        ])
        let tracker = NonceTracker(rpc: rpc)
        _ = try await tracker.next(for: "0xABCD", on: .gnosis)
        tracker.markSent(address: "0xABCD", on: .gnosis, usedNonce: 5)
        let next = try await tracker.next(for: "0xabcd", on: .gnosis)
        XCTAssertEqual(next, 6, "mixed-case addresses should share cache")
    }
}
