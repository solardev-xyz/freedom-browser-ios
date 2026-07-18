import Foundation
import web3

/// Node-facing operations for the SWIP messaging extension. Same
/// closure-injection shape as `SwarmChunkService` so bridge unit tests
/// and the e2e harness stub the gateway without `URLProtocol` mocking.
///
/// - `sendPss` → `POST /pss/send/{topicHex}/{targets}?recipient=` —
///   trojan wrap/mine/encrypt happens on the node.
/// - `sendGsoc` → GSOC derivation + mining happen HERE (Freedom
///   profile v1, `SwarmGsoc`), then the chunk is signed with the mined
///   owner key and uploaded through the standard SOC path — byte-
///   compatible with desktop's bee-js `gsocSend`.
/// - `getMessagingIdentity` → `GET /addresses`.
@MainActor
final class SwarmMessagingService {
    typealias SendPss = @MainActor (
        _ topicHex: String, _ targets: String, _ recipient: String,
        _ body: Data, _ batchID: String
    ) async throws -> Void
    typealias GetAddresses = @MainActor () async throws
        -> (pssPublicKey: String, overlay: String)

    enum MessagingError: Swift.Error, Equatable {
        case unreachable
        case other(String)
    }

    private let sendPssRaw: SendPss
    private let getAddresses: GetAddresses
    private let chunkService: SwarmChunkService
    /// Mined derivations are pure functions of the topic — cache them
    /// (desktop keeps 128; mining costs ~4k hash+derive rounds).
    private var gsocCache: [String: SwarmGsoc.Derivation] = [:]
    private var gsocCacheOrder: [String] = []
    private static let gsocCacheMax = 128

    init(
        sendPss: @escaping SendPss,
        getAddresses: @escaping GetAddresses,
        chunkService: SwarmChunkService
    ) {
        self.sendPssRaw = sendPss
        self.getAddresses = getAddresses
        self.chunkService = chunkService
    }

    static func live(bee: BeeAPIClient, chunkService: SwarmChunkService) -> SwarmMessagingService {
        SwarmMessagingService(
            sendPss: { topicHex, targets, recipient, body, batchID in
                try await bee.postPss(
                    topicHex: topicHex, targets: targets,
                    recipient: recipient, body: body, batchID: batchID
                )
            },
            getAddresses: { try await bee.getAddresses() },
            chunkService: chunkService
        )
    }

    /// bee-js `Topic.fromString` — `keccak256(utf8(topic))`, the hashed
    /// form used on the wire for both `/pss/send` and `/pss/subscribe`.
    static func pssTopicHex(_ topic: String) -> String {
        Data(topic.utf8).web3.keccak256.web3.hexString.web3.noHexPrefix
    }

    /// Cached Freedom-profile GSOC derivation. Mining runs off-main —
    /// it's pure CPU and would jank the main actor.
    func gsocDerivation(topic: String) async throws -> SwarmGsoc.Derivation {
        if let cached = gsocCache[topic] { return cached }
        let derivation = try await Task.detached(priority: .userInitiated) {
            try SwarmGsoc.derive(topic: topic)
        }.value
        gsocCache[topic] = derivation
        gsocCacheOrder.append(topic)
        if gsocCacheOrder.count > Self.gsocCacheMax {
            gsocCache.removeValue(forKey: gsocCacheOrder.removeFirst())
        }
        return derivation
    }

    func sendPss(
        topic: String, targets: String, recipient: String,
        payload: Data, batchID: String
    ) async throws {
        do {
            try await sendPssRaw(
                Self.pssTopicHex(topic), targets.lowercased(),
                recipient.lowercased(), payload, batchID
            )
        } catch BeeAPIClient.Error.notRunning {
            throw MessagingError.unreachable
        } catch {
            throw MessagingError.other("pss send: \(error)")
        }
    }

    /// Returns the 64-hex GSOC address written to (== the subscribe key
    /// for the same topic).
    func sendGsoc(
        topic: String, payload: Data, batchID: String
    ) async throws -> String {
        let derivation = try await gsocDerivation(topic: topic)
        do {
            _ = try await chunkService.writeSingleOwnerChunk(
                identifier: derivation.identifier,
                payload: payload,
                span: nil,
                privateKey: derivation.privateKey,
                batchID: batchID
            )
        } catch SwarmChunkService.ChunkServiceError.unreachable {
            throw MessagingError.unreachable
        } catch {
            throw MessagingError.other("gsoc send: \(error)")
        }
        return derivation.addressHex
    }

    struct MessagingIdentity: Equatable {
        /// 66-hex compressed secp256k1 — node-global (the lurker
        /// decrypts with the node key), hence `bee-wallet` mode.
        let pssPublicKey: String
        /// Truncated overlay prefix, `maxTargetDepth` bytes. The full
        /// overlay MUST NOT reach a page (cross-origin correlation
        /// handle + discloses exact network position).
        let pssTarget: String
        let identityMode: String
    }

    func messagingIdentity() async throws -> MessagingIdentity {
        let addresses: (pssPublicKey: String, overlay: String)
        do {
            addresses = try await getAddresses()
        } catch BeeAPIClient.Error.notRunning {
            throw MessagingError.unreachable
        } catch {
            throw MessagingError.other("addresses: \(error)")
        }
        let depth = SwarmCapabilities.Limits.defaults.maxTargetDepth
        let key = addresses.pssPublicKey.lowercased()
            .replacingOccurrences(of: "0x", with: "")
        let overlay = addresses.overlay.lowercased()
            .replacingOccurrences(of: "0x", with: "")
        return MessagingIdentity(
            pssPublicKey: key,
            pssTarget: String(overlay.prefix(depth * 2)),
            identityMode: "bee-wallet"
        )
    }
}
