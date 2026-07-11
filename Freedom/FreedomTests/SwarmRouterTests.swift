import XCTest
import web3
@testable import Freedom

@MainActor
final class SwarmRouterTests: XCTestCase {
    /// Set per test before calling `makeRouter`.
    private var connected: Set<String> = []
    private var feedsByOrigin: [String: [[String: Any]]] = [:]
    private var nodeReason: String?
    private var chunksByAddress: [String: Data] = [:]
    private var readBudget = SwarmReadBudget()

    private let connectedOrigin = OriginIdentity.from(string: "ens://foo.eth")!

    override func setUp() {
        super.setUp()
        connected = []
        feedsByOrigin = [:]
        nodeReason = nil
        chunksByAddress = [:]
        readBudget = SwarmReadBudget()
    }

    private func makeRouter() -> SwarmRouter {
        // Snapshot the per-test state so the router's closures don't
        // hold back-references to the XCTestCase instance — XCTest's
        // sync-test teardown timing tripped a malloc fault when a class
        // captured `self` via either `[unowned self]` or `[weak self]`.
        let connected = self.connected
        let feeds = self.feedsByOrigin
        let reason = self.nodeReason
        return SwarmRouter(
            isConnected: { connected.contains($0) },
            listFeedsForOrigin: { feeds[$0] ?? [] },
            nodeFailureReason: { reason },
            feedOwner: { _, _ in nil },
            readFeed: { _, _, _ in throw SwarmRouter.FeedReadError.notFound },
            readChunkRaw: { [chunks = self.chunksByAddress] address in
                guard let data = chunks[address] else {
                    throw SwarmRouter.ChunkReadError.notFound
                }
                return data
            },
            readBudget: readBudget
        )
    }

    // MARK: - getCapabilities

    func testCapabilitiesReportsNotConnectedBeforeGrant() async {
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertFalse(caps.canPublish)
        XCTAssertEqual(caps.reason, "not-connected")
    }

    func testCapabilitiesReportsNodeFailureWhenConnectedButNodeNotReady() async {
        connected.insert(connectedOrigin.key)
        nodeReason = SwarmRouter.ErrorPayload.Reason.ultraLightMode
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertFalse(caps.canPublish)
        XCTAssertEqual(caps.reason, "ultra-light-mode")
    }

    func testCapabilitiesGreenWhenConnectedAndNodeReady() async {
        connected.insert(connectedOrigin.key)
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertTrue(caps.canPublish)
        XCTAssertNil(caps.reason)
    }

    func testCapabilitiesPrioritizesNotConnectedOverNodeFailure() async {
        // SWIP §"swarm_getCapabilities" — `not-connected` shadows node-side
        // reasons so the dapp shows "connect first" instead of "your bee
        // node is in ultralight mode" before the user has ever connected.
        nodeReason = SwarmRouter.ErrorPayload.Reason.nodeStopped
        let caps = makeRouter().capabilities(origin: connectedOrigin)
        XCTAssertEqual(caps.reason, "not-connected")
    }

    // MARK: - listFeeds

    func testListFeedsEmptyForUngrantedOrigin() async {
        let result = makeRouter().listFeeds(origin: connectedOrigin)
        XCTAssertEqual(result.count, 0)
    }

    func testListFeedsScopedToCallingOrigin() async {
        feedsByOrigin[connectedOrigin.key] = [["name": "posts"]]
        feedsByOrigin["bar.eth"] = [["name": "posts"]]
        let result = makeRouter().listFeeds(origin: connectedOrigin)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["name"] as? String, "posts")
    }

    // MARK: - dispatch

    func testHandleDispatchesGetCapabilities() async throws {
        let result = try await makeRouter().handle(
            method: "swarm_getCapabilities", params: [:], origin: connectedOrigin
        )
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["specVersion"] as? String, "1.0")
        XCTAssertEqual(dict["reason"] as? String, "not-connected")
    }

    func testHandleDispatchesListFeeds() async throws {
        let result = try await makeRouter().handle(
            method: "swarm_listFeeds", params: [:], origin: connectedOrigin
        )
        XCTAssertEqual((result as? [[String: Any]])?.count, 0)
    }

    func testHandleRejectsUnknownMethodAs4200() async {
        do {
            _ = try await makeRouter().handle(
                method: "swarm_doesNotExist", params: [:], origin: connectedOrigin
            )
            XCTFail("Expected unsupportedMethod")
        } catch SwarmRouter.RouterError.unsupportedMethod(let method) {
            XCTAssertEqual(method, "swarm_doesNotExist")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHandleRejectsPublishMethodsAs4200ForNow() async {
        // WP4 ships only the read-only methods. Publish/feed-write methods
        // surface as 4200 until WP5/WP6 land — explicit guard so a half-
        // wired bridge can't accidentally call into a missing handler.
        let methods = [
            "swarm_publishData", "swarm_publishFiles", "swarm_getUploadStatus",
            "swarm_createFeed", "swarm_updateFeed", "swarm_writeFeedEntry",
        ]
        for method in methods {
            do {
                _ = try await makeRouter().handle(method: method, params: [:], origin: connectedOrigin)
                XCTFail("Expected \(method) to throw unsupportedMethod")
            } catch SwarmRouter.RouterError.unsupportedMethod {
            } catch {
                XCTFail("\(method) threw unexpected: \(error)")
            }
        }
    }

    // MARK: - swarm_readChunk / swarm_readSingleOwnerChunk

    private func expectInvalidParams(
        method: String, params: [String: Any], reason: String? = nil,
        file: StaticString = #file, line: UInt = #line
    ) async {
        do {
            _ = try await makeRouter().handle(
                method: method, params: params, origin: connectedOrigin
            )
            XCTFail("Expected invalidParams", file: file, line: line)
        } catch SwarmRouter.RouterError.invalidParams(let thrownReason, _) {
            if let reason {
                XCTAssertEqual(thrownReason, reason, file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testReadChunkRejectsInvalidReference() async {
        await expectInvalidParams(
            method: "swarm_readChunk",
            params: ["reference": "nope"],
            reason: SwarmRouter.ErrorPayload.Reason.invalidReference
        )
    }

    func testReadChunkRejectsUnknownOption() async {
        await expectInvalidParams(
            method: "swarm_readChunk",
            params: [
                "reference": String(repeating: "a", count: 64),
                "options": ["cache": true],
            ],
            reason: SwarmRouter.ErrorPayload.Reason.unsupportedOption
        )
    }

    func testReadChunkMissingChunkReturnsChunkNotFound() async {
        await expectInvalidParams(
            method: "swarm_readChunk",
            params: ["reference": String(repeating: "a", count: 64)],
            reason: SwarmRouter.ErrorPayload.Reason.chunkNotFound
        )
    }

    func testReadChunkRoundTripAndTypeValidation() async throws {
        let payload = Data("chunk payload".utf8)
        let cac = try SwarmSOC.makeCAC(payload: payload)
        let referenceHex = cac.address.web3.hexString.web3.noHexPrefix
        chunksByAddress[referenceHex] = SwarmSOC.socBody(cac: cac)

        let result = try await makeRouter().handle(
            method: "swarm_readChunk",
            params: ["reference": referenceHex],
            origin: connectedOrigin
        )
        let dict = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(dict["encoding"] as? String, "base64")
        XCTAssertEqual(dict["span"] as? Int, payload.count)
        XCTAssertEqual(
            Data(base64Encoded: dict["data"] as? String ?? ""), payload
        )
    }

    func testReadChunkRejectsBytesNotMatchingAddress() async {
        // Valid-shaped chunk stored at the wrong address — BMT
        // recompute must reject with chunk_type_mismatch.
        let wrongAddress = String(repeating: "b", count: 64)
        chunksByAddress[wrongAddress] = SwarmChunkCodec.spanBytes(5) + Data("hello".utf8)
        await expectInvalidParams(
            method: "swarm_readChunk",
            params: ["reference": wrongAddress],
            reason: SwarmRouter.ErrorPayload.Reason.chunkTypeMismatch
        )
    }

    func testReadSOCRejectsBothAddressAndPair() async {
        await expectInvalidParams(
            method: "swarm_readSingleOwnerChunk",
            params: [
                "address": String(repeating: "a", count: 64),
                "owner": "0x1111111111111111111111111111111111111111",
                "identifier": String(repeating: "b", count: 64),
            ]
        )
    }

    func testReadSOCRejectsMissingOwnerWithIdentifier() async {
        await expectInvalidParams(
            method: "swarm_readSingleOwnerChunk",
            params: ["identifier": String(repeating: "b", count: 64)],
            reason: SwarmRouter.ErrorPayload.Reason.invalidOwner
        )
    }

    func testReadSOCRejectsBadIdentifier() async {
        await expectInvalidParams(
            method: "swarm_readSingleOwnerChunk",
            params: [
                "owner": "0x1111111111111111111111111111111111111111",
                "identifier": "zzz",
            ],
            reason: SwarmRouter.ErrorPayload.Reason.invalidIdentifier
        )
    }

    func testReadSOCByAddressAndByPairRoundTrip() async throws {
        let privateKey = Data(repeating: 0xAB, count: 32)
        let identifier = Data(repeating: 0x42, count: 32)
        let payload = Data("soc payload".utf8)
        let cac = try SwarmSOC.makeCAC(payload: payload)
        let digest = SwarmSOC.signingMessage(
            identifier: identifier, cacAddress: cac.address
        ).web3.keccak256
        let sig = try FeedSigner.sign(digest: digest, privateKey: privateKey)
        let ownerBytes = try FeedSigner.ownerAddressBytes(privateKey: privateKey)
        let addressHex = SwarmSOC.socAddress(
            identifier: identifier, ownerAddress: ownerBytes
        ).web3.hexString.web3.noHexPrefix
        chunksByAddress[addressHex] = identifier + sig + SwarmSOC.socBody(cac: cac)

        // By address.
        let byAddress = try await makeRouter().handle(
            method: "swarm_readSingleOwnerChunk",
            params: ["address": addressHex],
            origin: connectedOrigin
        )
        let addressDict = try XCTUnwrap(byAddress as? [String: Any])
        XCTAssertEqual(
            Data(base64Encoded: addressDict["data"] as? String ?? ""), payload
        )
        XCTAssertEqual(addressDict["reference"] as? String, addressHex)
        XCTAssertEqual(
            addressDict["owner"] as? String,
            Hex.checksummed(ownerBytes.web3.hexString)
        )
        XCTAssertEqual(
            addressDict["identifier"] as? String,
            identifier.web3.hexString.web3.noHexPrefix
        )
        XCTAssertEqual((addressDict["signature"] as? String)?.count, 130)

        // By owner + identifier — provider derives the same address.
        let byPair = try await makeRouter().handle(
            method: "swarm_readSingleOwnerChunk",
            params: [
                "owner": Hex.checksummed(ownerBytes.web3.hexString),
                "identifier": identifier.web3.hexString.web3.noHexPrefix,
            ],
            origin: connectedOrigin
        )
        let pairDict = try XCTUnwrap(byPair as? [String: Any])
        XCTAssertEqual(pairDict["reference"] as? String, addressHex)
    }

    func testReadSOCRejectsCACAtAddress() async throws {
        // A CAC living at the requested address must be rejected —
        // the caller asked for a SOC (SWIP chunk-type contract).
        let payload = Data("plain cac".utf8)
        let cac = try SwarmSOC.makeCAC(payload: payload)
        let referenceHex = cac.address.web3.hexString.web3.noHexPrefix
        chunksByAddress[referenceHex] = SwarmSOC.socBody(cac: cac)
        await expectInvalidParams(
            method: "swarm_readSingleOwnerChunk",
            params: ["address": referenceHex],
            reason: SwarmRouter.ErrorPayload.Reason.chunkTypeMismatch
        )
    }

    // MARK: - read budget

    func testPermissionFreeReadsRateLimitAt120ForAnonymousOrigin() async throws {
        // listFeeds is the cheapest permission-free read — exhaust the
        // anonymous request budget, then expect rate_limited.
        let router = makeRouter()
        for _ in 0..<120 {
            _ = try await router.handle(
                method: "swarm_listFeeds", params: [:], origin: connectedOrigin
            )
        }
        do {
            _ = try await router.handle(
                method: "swarm_listFeeds", params: [:], origin: connectedOrigin
            )
            XCTFail("Expected rate_limited")
        } catch SwarmRouter.RouterError.invalidParams(let reason, _) {
            XCTAssertEqual(reason, SwarmRouter.ErrorPayload.Reason.rateLimited)
        }
    }

    // MARK: - errorPayload

    func testErrorPayloadMapsRouterErrors() async {
        let router = makeRouter()
        XCTAssertEqual(
            router.errorPayload(for: SwarmRouter.RouterError.unsupportedMethod(method: "foo")).code,
            4200
        )
        let invalidParams = router.errorPayload(for: SwarmRouter.RouterError.invalidParams(
            reason: "invalid_topic", message: "topic must be 64 hex chars"
        ))
        XCTAssertEqual(invalidParams.code, -32602)
        XCTAssertEqual(invalidParams.dataReason, "invalid_topic")

        let nodeUnavailable = router.errorPayload(for: SwarmRouter.RouterError.nodeUnavailable(
            reason: "node-stopped"
        ))
        XCTAssertEqual(nodeUnavailable.code, 4900)
        XCTAssertEqual(nodeUnavailable.dataReason, "node-stopped")
    }

    func testErrorPayloadMapsUnknownErrorTo32603() async {
        struct Unknown: Swift.Error {}
        let payload = makeRouter().errorPayload(for: Unknown())
        XCTAssertEqual(payload.code, -32603)
    }
}
