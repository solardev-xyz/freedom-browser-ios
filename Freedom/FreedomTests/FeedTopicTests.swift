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

    // Cross-platform parity (iOS topic == desktop topic for the same input)
    // pinned at WP6 with a fixture captured against the running desktop
    // implementation — premature to fabricate one here.
}
