import XCTest
@testable import Freedom

/// Back/Forward onto an ENS-backed history entry re-verifies the name
/// (desktop #86). The classification of what counts as ENS-backed is
/// pure; the traversal itself is WebKit's.
final class HistoryReverifyTests: XCTestCase {
    func testENSBackedEntriesAreRecognizedInEveryCodecForm() {
        for raw in ["bzz://vitalik.eth/", "bzz://vitalik.eth/blog/post?x=1", "ipfs://vitalik.eth/",
                    "ipns://vitalik.eth/docs", "ens://vitalik.eth", "https://vitalik.eth/"] {
            XCTAssertEqual(BrowserTab.ensNameToReverify(URL(string: raw)!), "vitalik.eth", raw)
        }
        XCTAssertEqual(BrowserTab.ensNameToReverify(URL(string: "bzz://Swarm.ETH/")!), "swarm.eth", "names are lowercased")
    }

    func testPlainEntriesAreNotReverified() {
        for raw in ["https://example.com/", "bzz://" + String(repeating: "ab", count: 32) + "/",
                    "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/",
                    "http://localhost:8080/", "about:blank"] {
            XCTAssertNil(BrowserTab.ensNameToReverify(URL(string: raw)!), raw)
        }
    }
}
