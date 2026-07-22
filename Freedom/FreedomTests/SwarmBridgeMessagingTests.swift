import XCTest
@testable import Freedom

/// Bridge-level messaging behavior: the -32602 reason vocabulary the
/// swarm-kit compliance suite asserts, the messaging-tier grant flow,
/// per-send consent + auto-approve, and result shapes.
@MainActor
final class SwarmBridgeMessagingTests: XCTestCase {
    private var fixture: SwarmBridgeTestFixture!
    private let origin = OriginIdentity.from(
        displayURL: URL(string: "https://dapp.example/page")
    )!

    override func setUp() async throws {
        fixture = try await SwarmBridgeTestFixture()
        fixture.permissionStore.grant(origin: origin.key)
    }

    override func tearDown() async throws {
        try await fixture.tearDownAsync()
        fixture = nil
    }

    private func grantMessaging() {
        fixture.permissionStore.grantMessaging(origin: origin.key)
    }

    private func lastErrorReason() -> String? {
        ((fixture.recorder.errors.last?.dict["data"]) as? [String: Any])?["reason"] as? String
    }

    private func lastErrorCode() -> Int? {
        fixture.recorder.errors.last?.dict["code"] as? Int
    }

    private var usableStamp: PostageBatch {
        PostageBatch(
            batchID: String(repeating: "ee", count: 32),
            usable: true, usage: 0.1,
            effectiveBytes: 10_000_000, ttlSeconds: 86_400,
            isMutable: true, depth: 22, amount: "1000", label: nil
        )
    }

    // MARK: - Capabilities

    func testCapabilitiesAdvertiseMessaging() async throws {
        await fixture.dispatch(method: "swarm_getCapabilities", origin: origin)
        let dict = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(dict["features"] as? [String], ["messaging"])
        let limits = try XCTUnwrap(dict["limits"] as? [String: Any])
        XCTAssertEqual(limits["maxMessageBytes"] as? Int, 4000)
        XCTAssertEqual(limits["maxTargetDepth"] as? Int, 3)
        XCTAssertEqual(limits["maxSubscriptions"] as? Int, 32)
    }

    // MARK: - Param validation (compliance reason vocabulary)

    func testSubscribeRejectsInvalidKind() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "feed", "topic": "t"], origin: origin
        )
        XCTAssertEqual(lastErrorCode(), -32602)
        XCTAssertEqual(lastErrorReason(), "invalid_kind")
    }

    func testSubscribeRejectsTopicPlusAddress() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "gsoc", "topic": "t",
                     "address": String(repeating: "ab", count: 32)],
            origin: origin
        )
        XCTAssertEqual(lastErrorCode(), -32602)
    }

    func testSubscribeRejectsBadAddress() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "gsoc", "address": "not-hex"], origin: origin
        )
        XCTAssertEqual(lastErrorReason(), "invalid_address")
    }

    func testSubscribeRejectsPssWithAddress() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "pss", "address": String(repeating: "ab", count: 32)],
            origin: origin
        )
        XCTAssertEqual(lastErrorCode(), -32602)
    }

    func testSubscribeRejectsUnknownOption() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "gsoc", "topic": "t", "options": ["future": true]],
            origin: origin
        )
        XCTAssertEqual(lastErrorReason(), "unsupported_option")
    }

    func testSendPssRejectsBadRecipientAndTargets() async {
        grantMessaging()
        let base: [String: Any] = [
            "topic": "t", "recipient": "02" + String(repeating: "ab", count: 32),
            "targets": "aabb", "data": Data("x".utf8).base64EncodedString(),
        ]

        var params = base
        params["recipient"] = "zz"
        await fixture.dispatch(method: "swarm_sendPss", params: params, origin: origin)
        XCTAssertEqual(lastErrorReason(), "invalid_recipient")

        params = base
        params.removeValue(forKey: "targets")
        await fixture.dispatch(method: "swarm_sendPss", params: params, origin: origin)
        XCTAssertEqual(lastErrorReason(), "invalid_target")

        params = base
        params["targets"] = "aabbccdd"  // 4 bytes > maxTargetDepth 3
        await fixture.dispatch(method: "swarm_sendPss", params: params, origin: origin)
        XCTAssertEqual(lastErrorReason(), "invalid_target")

        params = base
        params["targets"] = "aa"  // 1 byte < floor 2 (too shallow to store)
        await fixture.dispatch(method: "swarm_sendPss", params: params, origin: origin)
        XCTAssertEqual(lastErrorReason(), "invalid_target")
    }

    func testSendGsocRejectsRawAddressAndEmptyPayload() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_sendGsoc",
            params: ["address": String(repeating: "ab", count: 32),
                     "data": Data("x".utf8).base64EncodedString()],
            origin: origin
        )
        XCTAssertEqual(lastErrorReason(), "invalid_address")

        await fixture.dispatch(
            method: "swarm_sendGsoc",
            params: ["topic": "t", "data": ""], origin: origin
        )
        XCTAssertEqual(lastErrorReason(), "invalid_payload")
    }

    func testSendGsocRejectsOversizedPayload() async {
        grantMessaging()
        let oversized = Data(repeating: 0x78, count: 4001).base64EncodedString()
        await fixture.dispatch(
            method: "swarm_sendGsoc",
            params: ["topic": "t", "data": oversized], origin: origin
        )
        XCTAssertEqual(lastErrorReason(), "payload_too_large")
    }

    func testUnsubscribeUnknownIdIsSubscriptionNotFound() async {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_unsubscribe",
            params: ["subscriptionId": "nonexistent-subscription"], origin: origin
        )
        XCTAssertEqual(lastErrorCode(), -32602)
        XCTAssertEqual(lastErrorReason(), "subscription_not_found")
    }

    // MARK: - Grant flow

    func testFirstMessagingCallPromptsAndDenialIs4001() async {
        fixture.stubs.getAddresses = { ("02" + String(repeating: "ab", count: 32),
                                        String(repeating: "cd", count: 32)) }
        fixture.setNextDecision(.denied)
        await fixture.dispatch(method: "swarm_getMessagingIdentity", origin: origin)
        XCTAssertEqual(lastErrorCode(), 4001)
        XCTAssertFalse(fixture.permissionStore.hasMessagingGrant(origin.key))
    }

    func testIdentityReturnsTruncatedTargetAfterGrant() async throws {
        fixture.stubs.getAddresses = { ("02" + String(repeating: "ab", count: 32),
                                        String(repeating: "cd", count: 32)) }
        // Sheet contract: approval writes the grant before resolving.
        fixture.setNextDecision(.approved, sideEffect: { [fixture] request in
            fixture!.permissionStore.grantMessaging(origin: request.origin.key)
        })
        await fixture.dispatch(method: "swarm_getMessagingIdentity", origin: origin)
        let dict = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(dict["pssPublicKey"] as? String, "02" + String(repeating: "ab", count: 32))
        XCTAssertEqual(dict["pssTarget"] as? String, "cdcd", "2-byte overlay prefix (L=16), never the full overlay")
        XCTAssertEqual(dict["identityMode"] as? String, "bee-wallet")

        // Grant persisted — second call must not prompt (no decision
        // queued; a park would XCTFail in onParked).
        await fixture.dispatch(method: "swarm_getMessagingIdentity", origin: origin, id: 2)
        XCTAssertEqual(fixture.recorder.results.count, 2)
    }

    func testUnconnectedOriginIs4100() async {
        let stranger = OriginIdentity.from(
            displayURL: URL(string: "https://stranger.example")
        )!
        await fixture.dispatch(method: "swarm_subscribe",
                               params: ["kind": "gsoc", "topic": "t"],
                               origin: stranger)
        XCTAssertEqual(lastErrorCode(), 4100)
    }

    // MARK: - Subscribe / message delivery / send

    func testSubscribeLifecycleAndMessageEvent() async throws {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "gsoc", "topic": "room:test"], origin: origin
        )
        let result = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        let subscriptionId = try XCTUnwrap(result["subscriptionId"] as? String)
        let key = try XCTUnwrap(result["key"] as? String)
        XCTAssertEqual(result["kind"] as? String, "gsoc")
        XCTAssertEqual(key.count, 64)

        // Push through the stubbed pipeline → page event.
        let handle = try XCTUnwrap(fixture.stubs.subscriptionHandles["gsoc:\(key)"])
        handle.push(Data("ping".utf8))
        let event = try XCTUnwrap(fixture.recorder.events.last)
        XCTAssertEqual(event.name, "message")
        let payload = try XCTUnwrap(event.data as? [String: Any])
        XCTAssertEqual(payload["subscription"] as? String, subscriptionId)

        await fixture.dispatch(
            method: "swarm_unsubscribe",
            params: ["subscriptionId": subscriptionId], origin: origin, id: 2
        )
        let unsub = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(unsub["unsubscribed"] as? Bool, true)
        XCTAssertTrue(handle.cancelled)
    }

    func testPssSubscribeKeyIsHashedTopic() async throws {
        grantMessaging()
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "pss", "topic": "dm:alice"], origin: origin
        )
        let result = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(
            result["key"] as? String,
            SwarmMessagingService.pssTopicHex("dm:alice")
        )
    }

    func testNodePoolExhaustionIsRetryable4900() async {
        grantMessaging()
        fixture.stubs.nodePipelineCapacity = 0
        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "pss", "topic": "t"], origin: origin
        )
        XCTAssertEqual(lastErrorCode(), 4900)
        XCTAssertEqual(lastErrorReason(), "node_subscription_limit")
    }

    func testSendGsocReturnsDerivedAddressAndSignsWithMinedKey() async throws {
        grantMessaging()
        fixture.stubs.stamps = [usableStamp]
        var uploaded: (owner: String, identifier: String)?
        fixture.stubs.chunkUploadSOC = { owner, identifier, _, _, _ in
            uploaded = (owner, identifier)
            return (reference: "ref", tagUid: nil)
        }
        // Grant exists, auto-approve off → per-send prompt.
        fixture.setNextDecision(.approved)
        await fixture.dispatch(
            method: "swarm_sendGsoc",
            params: ["topic": "room:doc-42",
                     "data": Data("hello room".utf8).base64EncodedString()],
            origin: origin
        )
        let result = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(result["sent"] as? Bool, true)
        // Pinned bee-js vector for "room:doc-42" (see SwarmGsocTests).
        XCTAssertEqual(
            result["address"] as? String,
            "457d444476f6de5d990d9465662d55462efd4be2ef34303bf922cedc7d89b1a9"
        )
        XCTAssertEqual(uploaded?.owner, "f63f237c68718f939483f321c843b9b96a7e62f3")
        XCTAssertEqual(
            uploaded?.identifier,
            "5aaa9322a34420597442f65b3f3ef3e5aba895e844f77e53cf92f20d709b26c5"
        )
    }

    func testSendGsocAddressMatchesSubscribeKey() async throws {
        grantMessaging()
        fixture.stubs.stamps = [usableStamp]
        fixture.stubs.chunkUploadSOC = { _, _, _, _, _ in ("ref", nil) }
        fixture.permissionStore.setAutoApproveMessaging(origin: origin.key, enabled: true)

        await fixture.dispatch(
            method: "swarm_subscribe",
            params: ["kind": "gsoc", "topic": "same-room"], origin: origin
        )
        let sub = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        await fixture.dispatch(
            method: "swarm_sendGsoc",
            params: ["topic": "same-room",
                     "data": Data("x".utf8).base64EncodedString()],
            origin: origin, id: 2
        )
        let sent = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(sent["address"] as? String, sub["key"] as? String)
    }

    func testSendPssAllowsEmptyPayloadAndHashesTopic() async throws {
        grantMessaging()
        fixture.stubs.stamps = [usableStamp]
        fixture.permissionStore.setAutoApproveMessaging(origin: origin.key, enabled: true)
        var sent: (topicHex: String, targets: String, recipient: String, body: Data)?
        fixture.stubs.sendPss = { topicHex, targets, recipient, body, _ in
            sent = (topicHex, targets, recipient, body)
        }
        await fixture.dispatch(
            method: "swarm_sendPss",
            params: ["topic": "dm:alice",
                     "recipient": "02" + String(repeating: "AB", count: 32),
                     "targets": "AABB", "data": ""],
            origin: origin
        )
        let result = try XCTUnwrap(fixture.recorder.results.last?.value as? [String: Any])
        XCTAssertEqual(result["sent"] as? Bool, true)
        XCTAssertEqual(sent?.topicHex, SwarmMessagingService.pssTopicHex("dm:alice"))
        XCTAssertEqual(sent?.targets, "aabb", "targets normalized to lowercase")
        XCTAssertEqual(sent?.recipient, "02" + String(repeating: "ab", count: 32))
        XCTAssertEqual(sent?.body, Data(), "PSS zero-byte message is valid")
    }

    func testPerSendDenialIs4001() async {
        grantMessaging()
        fixture.stubs.stamps = [usableStamp]
        fixture.setNextDecision(.denied)
        await fixture.dispatch(
            method: "swarm_sendGsoc",
            params: ["topic": "t", "data": Data("x".utf8).base64EncodedString()],
            origin: origin
        )
        XCTAssertEqual(lastErrorCode(), 4001)
    }
}
