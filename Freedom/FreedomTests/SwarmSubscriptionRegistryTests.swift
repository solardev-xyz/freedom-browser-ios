import XCTest
@testable import Freedom

/// Registry semantics: pipeline sharing, per-origin cap, node-pool
/// error mapping, teardown scopes, and the SubscriptionMessage shape.
/// All async — the registry is `@MainActor` and its deinit must not
/// run from a synchronous XCTest method (see SwarmReadBudgetTests).
@MainActor
final class SwarmSubscriptionRegistryTests: XCTestCase {
    private final class Harness {
        var handles: [String: StubSubscriptionHandle] = [:]
        var dialCount = 0

        @MainActor
        func makeRegistry(cap: Int = 4) -> SwarmSubscriptionRegistry {
            SwarmSubscriptionRegistry(
                connect: { kind, key in
                    self.dialCount += 1
                    let handle = StubSubscriptionHandle()
                    self.handles["\(kind):\(key)"] = handle
                    return handle
                },
                maxSubscriptionsPerOrigin: cap
            )
        }
    }

    private let owner = ObjectIdentifier(NSObject())
    private static let key = String(repeating: "ab", count: 32)

    func testSameKeySharesOnePipelineAndFansOut() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        var received: [String: [[String: Any]]] = [:]

        let first = try await registry.subscribe(
            origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
            deliver: { received["first", default: []].append($0) }
        )
        let second = try await registry.subscribe(
            origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
            deliver: { received["second", default: []].append($0) }
        )
        XCTAssertEqual(harness.dialCount, 1, "same (kind, key) must share a pipeline")
        XCTAssertNotEqual(first, second, "each subscription independently addressable")

        harness.handles["gsoc:\(Self.key)"]?.push(Data("hello".utf8))
        XCTAssertEqual(received["first"]?.count, 1)
        XCTAssertEqual(received["second"]?.count, 1)

        // SWIP SubscriptionMessage shape.
        let message = try XCTUnwrap(received["first"]?.first)
        XCTAssertEqual(message["type"] as? String, "swarm_subscription")
        XCTAssertEqual(message["subscription"] as? String, first)
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        XCTAssertEqual(result["kind"] as? String, "gsoc")
        XCTAssertEqual(result["key"] as? String, Self.key)
        XCTAssertEqual(result["encoding"] as? String, "base64")
        XCTAssertEqual(result["data"] as? String, Data("hello".utf8).base64EncodedString())
        XCTAssertNotNil(result["receivedAt"] as? Int)
    }

    func testUnsubscribeIsOriginScopedAndReleasesLastPipeline() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        let id = try await registry.subscribe(
            origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
            deliver: { _ in }
        )
        // Another origin can't close it.
        XCTAssertFalse(registry.unsubscribe(origin: "https://b.example", id: id))
        XCTAssertFalse(registry.unsubscribe(origin: "https://a.example", id: "nope"))
        XCTAssertTrue(registry.unsubscribe(origin: "https://a.example", id: id))
        XCTAssertTrue(
            try XCTUnwrap(harness.handles["gsoc:\(Self.key)"]).cancelled,
            "last subscriber gone → pipeline released"
        )
        // Idempotent-ish: second close reports not-found.
        XCTAssertFalse(registry.unsubscribe(origin: "https://a.example", id: id))
    }

    func testPerOriginCapCountsPerOrigin() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry(cap: 2)
        for i in 0..<2 {
            _ = try await registry.subscribe(
                origin: "https://a.example", owner: owner,
                kind: "gsoc", key: String(repeating: "0\(i)", count: 32),
                deliver: { _ in }
            )
        }
        do {
            _ = try await registry.subscribe(
                origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
                deliver: { _ in }
            )
            XCTFail("expected tooManySubscriptions")
        } catch SwarmSubscriptionRegistry.RegistryError.tooManySubscriptions {
        }
        // A different origin still has budget.
        _ = try await registry.subscribe(
            origin: "https://b.example", owner: owner, kind: "gsoc", key: Self.key,
            deliver: { _ in }
        )
    }

    func testNodePoolExhaustionMapsDistinctlyAndFreesSlot() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        harness.handles["seed"] = StubSubscriptionHandle()  // unused; keeps map non-empty

        let limited = StubSubscriptionHandle()
        limited.establishError = .nodeSubscriptionLimit
        let registry2 = SwarmSubscriptionRegistry(
            connect: { _, _ in limited }, maxSubscriptionsPerOrigin: 4
        )
        do {
            _ = try await registry2.subscribe(
                origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
                deliver: { _ in }
            )
            XCTFail("expected nodeSubscriptionLimit")
        } catch SwarmSubscriptionRegistry.RegistryError.nodeSubscriptionLimit {
        }
        XCTAssertTrue(limited.cancelled, "failed dial must not leak the pipeline slot")
        XCTAssertEqual(registry2.activeCount(origin: "https://a.example"), 0)
        _ = registry  // silence unused warning
    }

    func testCancelByOwnerAndByOrigin() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry(cap: 8)
        let otherOwner = ObjectIdentifier(NSString())
        _ = try await registry.subscribe(
            origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
            deliver: { _ in }
        )
        _ = try await registry.subscribe(
            origin: "https://a.example", owner: otherOwner,
            kind: "pss", key: String(repeating: "cd", count: 32),
            deliver: { _ in }
        )
        registry.cancelByOwner(owner)
        XCTAssertEqual(registry.activeCount(origin: "https://a.example"), 1)
        XCTAssertTrue(try XCTUnwrap(harness.handles["gsoc:\(Self.key)"]).cancelled)

        registry.cancelByOrigin("https://a.example")
        XCTAssertEqual(registry.activeCount(origin: "https://a.example"), 0)
    }

    func testRevocationNotificationTearsDownOrigin() async throws {
        let harness = Harness()
        let registry = harness.makeRegistry()
        _ = try await registry.subscribe(
            origin: "https://a.example", owner: owner, kind: "gsoc", key: Self.key,
            deliver: { _ in }
        )
        NotificationCenter.default.post(
            name: .swarmPermissionRevoked, object: nil,
            userInfo: ["origin": "https://a.example"]
        )
        XCTAssertEqual(registry.activeCount(origin: "https://a.example"), 0)
        XCTAssertTrue(try XCTUnwrap(harness.handles["gsoc:\(Self.key)"]).cancelled)
    }
}
