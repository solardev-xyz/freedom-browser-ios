import Foundation

/// Bee-side feed operations. Closure-injected so unit tests stub the
/// bee call without `URLProtocol` mocking.
@MainActor
struct SwarmFeedService {
    /// `(owner, topic, batchID) → manifestReferenceHex`. Production
    /// wires through `BeeAPIClient.createFeedManifest`; tests stub
    /// directly. Throws `BeeAPIClient.Error.*` shapes the wrapper
    /// recognises and remaps to `FeedServiceError`.
    typealias CreateManifest = @MainActor (
        _ owner: String, _ topic: String, _ batchID: String
    ) async throws -> String

    let createFeedManifest: CreateManifest

    static func live(bee: BeeAPIClient) -> Self {
        Self(createFeedManifest: { owner, topic, batchID in
            try await bee.createFeedManifest(
                owner: owner, topic: topic, batchID: batchID
            )
        })
    }

    enum FeedServiceError: Swift.Error, Equatable {
        /// `BeeAPIClient.Error.notRunning` — bridge maps to 4900
        /// `node-stopped`.
        case unreachable
        /// 200 from bee but body wasn't `{"reference": "<hex>"}`.
        case malformedResponse
        /// Any other bee-side / transport failure. Bridge maps to -32603.
        case other(String)
    }

    struct CreateFeedResult: Equatable {
        let topic: String
        let ownerHex: String
        let manifestReference: String
        let bzzUrl: String
    }

    /// Creates the feed manifest at bee and returns the metadata.
    /// Idempotent at the bee layer — re-creating the same
    /// `(owner, topic)` returns the existing reference. Caller composes
    /// `ownerHex` from `FeedSigner.ownerAddressBytes` and `topicHex`
    /// from `FeedTopic.derive`, then persists the result via
    /// `SwarmFeedStore.upsert`.
    func createFeed(
        ownerHex: String, topicHex: String, batchID: String
    ) async throws -> CreateFeedResult {
        do {
            let reference = try await createFeedManifest(ownerHex, topicHex, batchID)
            return CreateFeedResult(
                topic: topicHex,
                ownerHex: ownerHex,
                manifestReference: reference,
                bzzUrl: "bzz://\(reference)"
            )
        } catch BeeAPIClient.Error.notRunning {
            throw FeedServiceError.unreachable
        } catch BeeAPIClient.Error.malformedResponse {
            throw FeedServiceError.malformedResponse
        } catch {
            throw FeedServiceError.other("\(error)")
        }
    }
}
