import XCTest
@testable import Freedom

final class FeedTopicTests: XCTestCase {
    func testReturnsSixtyFourLowercaseHexChars() {
        let topic = FeedTopic.derive(origin: "ens://foo.eth", name: "posts")
        XCTAssertEqual(topic.count, 64)
        XCTAssertTrue(topic.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
    }

    func testIsDeterministic() {
        let a = FeedTopic.derive(origin: "ens://foo.eth", name: "posts")
        let b = FeedTopic.derive(origin: "ens://foo.eth", name: "posts")
        XCTAssertEqual(a, b)
    }

    func testDifferentOriginsDifferentTopics() {
        let foo = FeedTopic.derive(origin: "ens://foo.eth", name: "posts")
        let bar = FeedTopic.derive(origin: "ens://bar.eth", name: "posts")
        XCTAssertNotEqual(foo, bar)
    }

    func testDifferentNamesDifferentTopics() {
        let posts = FeedTopic.derive(origin: "ens://foo.eth", name: "posts")
        let comments = FeedTopic.derive(origin: "ens://foo.eth", name: "comments")
        XCTAssertNotEqual(posts, comments)
    }

    /// Cross-platform parity: a user with the same mnemonic on iOS and
    /// desktop must read/write the same feed on both — which means
    /// `FeedTopic.derive` must produce byte-identical output to bee-js's
    /// `Topic.fromString(origin + "/" + name).toHex()`. Fixture captured
    /// against `freedom-browser/node_modules/@ethersphere/bee-js` (WP6).
    /// Covers canonical inputs, length boundaries, and multi-byte UTF-8
    /// in both fields.
    func testMatchesDesktopBeeJSFixture() {
        let cases: [(origin: String, name: String, topic: String)] = [
            ("ens://foo.eth", "posts",
             "f757932a4cab2ba386df56c48cff6abd0515ed9e4ca464d44facb942bf1790b5"),
            ("ens://foo.eth", "journal",
             "60d17d8f03ee0085dd7992bd428517ae3f0e0464532820180561c17b402353ed"),
            ("https://app.example.com", "updates",
             "854786e1e3f3ea0b18380554fca413c2e2a350005bd788be3ac65e5462207d98"),
            ("bzz://1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", "log",
             "f11a3eee60dc5d82336eb78af5f39fd6aee1182186e65da402801c40363c6903"),
            ("ens://foo.eth", "a",
             "27343de2ae5846aa6e47fd8c627a508942c1467f8039380421519ea54b12923a"),
            ("ens://foo.eth", String(repeating: "x", count: 64),
             "c152c9f94ff5d3a3b4123cefa946b9968861f713603cc7e295b1b57b81eaf17c"),
            ("ens://föö.eth", "posts",
             "2226bfbe0287a712265b6f708c5b177767db94352137dd31e104b5c39140afbb"),
            ("ens://foo.eth", "日記",
             "08f699fc5e141e7b9ed82843ef8a812a0ad505695b012baf7452f25012cd2c45"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                FeedTopic.derive(origin: testCase.origin, name: testCase.name),
                testCase.topic,
                "iOS topic drifted from desktop bee-js for (origin=\(testCase.origin), name=\(testCase.name))"
            )
        }
    }
}
