import Foundation

/// Bundle of swarm collaborators threaded `FreedomApp → TabStore →
/// BrowserTab → SwarmBridge`. Mirrors `WalletServices`'s shape — adding
/// a new swarm dependency at WP5/WP6 (`SwarmPublishService`,
/// `SwarmFeedService`) becomes a one-field addition here instead of an
/// N-place plumbing change.
@MainActor
struct SwarmServices {
    let permissionStore: SwarmPermissionStore
    let feedStore: SwarmFeedStore
    let bee: BeeAPIClient
    let publishService: SwarmPublishService
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
}
