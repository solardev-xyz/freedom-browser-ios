import BigInt
import XCTest
import web3
@testable import Freedom

/// The wallet's balance cache: last known balances show at once, the
/// refresh is silent, a failed refresh keeps the cache, a new holder
/// starts fresh. Plus the typed-name recipient fallback rule.
@MainActor
final class WalletBalanceStoreTests: XCTestCase {
    private var answers: [Int: [Token: BigUInt]] = [:]
    private var calls = 0
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var keep: [AnyObject] = []
    private let holder = "0x1111111111111111111111111111111111111111"
    private let other = "0x2222222222222222222222222222222222222222"

    private func store() -> WalletBalanceStore {
        let s = WalletBalanceStore(fetch: { [unowned self] _, chain, _ in
            calls += 1
            return answers[chain.id] ?? [:]
        }, now: { [unowned self] in now })
        keep.append(s)
        return s
    }

    private var native: Token { TokenRegistry.native(for: .gnosis) }

    func testRefreshCachesAndReusesWithinTheInterval() async {
        answers[100] = [native: 5]
        let s = store()
        XCTAssertNil(s.balances(on: .gnosis))
        let first = await s.refresh(holder: holder, chain: .gnosis)
        XCTAssertEqual(first?[native], 5)
        XCTAssertEqual(s.balance(of: native, on: .gnosis), 5)
        XCTAssertEqual(calls, 1)
        // A screen re-appearing seconds later does not refetch.
        now = now.addingTimeInterval(5)
        _ = await s.refresh(holder: holder, chain: .gnosis)
        XCTAssertEqual(calls, 1)
        // A forced refresh, or a stale snapshot, does.
        _ = await s.refresh(holder: holder, chain: .gnosis, minInterval: 0)
        XCTAssertEqual(calls, 2)
        now = now.addingTimeInterval(WalletBalanceStore.defaultMinInterval + 1)
        _ = await s.refresh(holder: holder, chain: .gnosis)
        XCTAssertEqual(calls, 3)
    }

    func testFailedRefreshKeepsTheSnapshot() async {
        answers[100] = [native: 5]
        let s = store()
        _ = await s.refresh(holder: holder, chain: .gnosis)
        answers[100] = [:]
        let result = await s.refresh(holder: holder, chain: .gnosis, minInterval: 0)
        XCTAssertEqual(result?[native], 5, "every call failed: the last known balances stay")
        XCTAssertEqual(s.balance(of: native, on: .gnosis), 5)
        XCTAssertFalse(s.isRefreshing(.gnosis))
    }

    func testNewHolderClearsEverything() async {
        answers[100] = [native: 5]
        let s = store()
        _ = await s.refresh(holder: holder, chain: .gnosis)
        answers[100] = [native: 9]
        let result = await s.refresh(holder: other, chain: .gnosis)
        XCTAssertEqual(result?[native], 9)
        XCTAssertEqual(s.holder, other)
        XCTAssertEqual(calls, 2)
    }

    func testRecipientFallsBackToTheEthereumAddressOffMainnet() async throws {
        let mainnetAddress = EthereumAddress("0x3333333333333333333333333333333333333333")
        var asked: [Int] = []
        let lookup: RecipientNameResolution.Lookup = { _, chainID in
            asked.append(chainID)
            if chainID == Chain.mainnetID { return mainnetAddress }
            throw ENSResolutionError.notFound(reason: .emptyAddress, trust: ENSTrust(
                level: .verified, method: .quorum, block: ENSBlock(number: 1, hash: "0x"), agreed: [], dissented: [], queried: [], k: 3, m: 2
            ))
        }
        let gnosis = try await RecipientNameResolution.resolve(name: "vitalik.eth", chain: .gnosis, lookup: lookup)
        XCTAssertEqual(gnosis.address, mainnetAddress)
        XCTAssertEqual(gnosis.note, "No Gnosis Chain address on this name — using its Ethereum address.")
        XCTAssertEqual(asked, [100, 1])

        asked = []
        let mainnet = try await RecipientNameResolution.resolve(name: "vitalik.eth", chain: .mainnet, lookup: lookup)
        XCTAssertNil(mainnet.note)
        XCTAssertEqual(asked, [1])

        // Contract-backed names have no per-chain record to fall back from.
        do {
            _ = try await RecipientNameResolution.resolve(name: "wns.wei", chain: .gnosis, lookup: lookup)
            XCTFail("expected the empty-address error to surface")
        } catch ENSResolutionError.notFound(.emptyAddress, _) {}

        // Other failures pass through untouched.
        do {
            _ = try await RecipientNameResolution.resolve(name: "vitalik.eth", chain: .gnosis) { _, _ in throw ENSResolutionError.allProvidersErrored }
            XCTFail("expected the error to surface")
        } catch ENSResolutionError.allProvidersErrored {}
    }
}
