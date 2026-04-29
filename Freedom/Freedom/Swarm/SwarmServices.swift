import Foundation

/// Bundle of swarm collaborators threaded `FreedomApp → TabStore →
/// BrowserTab → SwarmBridge`. Mirrors `WalletServices`'s shape —
/// adding a new collaborator is a one-field addition here instead of
/// an N-place plumbing change.
@MainActor
struct SwarmServices {
    let permissionStore: SwarmPermissionStore
    let feedStore: SwarmFeedStore
    /// Append-only log of every `window.swarm` publish/feed-write so the
    /// user can later browse what they uploaded and copy references back
    /// out. Bridge handlers do a two-step write (record on entry,
    /// complete/fail on bee response) — see `SwarmPublishHistoryStore`.
    let publishHistoryStore: SwarmPublishHistoryStore
    let bee: BeeAPIClient
    let publishService: SwarmPublishService
    let feedService: SwarmFeedService
    /// Needed for HD-key derivation on feed-write paths — bridge
    /// resolves the publisher key via `SwarmFeedIdentity.signingKey(via:)`.
    let vault: Vault
    /// Tag ownership map for `swarm_getUploadStatus`'s cross-origin
    /// defense — bridge records the `(tagUid, origin)` after every
    /// successful publish, looks it up before forwarding the status
    /// query to bee. One instance per app session; shared across all
    /// `BrowserTab`s so cross-tab same-origin reads work.
    let tagOwnership: TagOwnership
    /// Shared across tabs so two-tab same-dapp updates serialize.
    let feedWriteLock: SwarmFeedWriteLock
    /// Returns `nil` when bee is fully ready, or one of
    /// `SwarmRouter.ErrorPayload.Reason`'s node-side strings otherwise.
    /// Composed once in `FreedomApp.init` from the four observable
    /// services (`SwarmNode`, `SettingsStore`, `BeeReadiness`,
    /// `StampService`); the closure reads them live, no caching, so a
    /// mode flip / sync-progress tick is reflected on the next
    /// `swarm_getCapabilities`.
    let nodeFailureReason: @MainActor () -> String?
    /// Live `[PostageBatch]` snapshot for `swarm_publishData` /
    /// `swarm_publishFiles` batch selection. Closure (rather than a
    /// `StampService` reference) keeps the bridge's surface narrow —
    /// it only needs to read stamps, not poll or buy them.
    let currentStamps: @MainActor () -> [PostageBatch]
    /// Tag-status fetch for `swarm_getUploadStatus`. Closure-extracted
    /// so unit tests can stub without `URLSession`/`URLProtocol`
    /// mocking — same pattern as `currentStamps` / `nodeFailureReason`.
    let getTag: @MainActor (Int) async throws -> BeeAPIClient.TagResponse
}
