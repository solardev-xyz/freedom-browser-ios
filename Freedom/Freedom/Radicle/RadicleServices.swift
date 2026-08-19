import Foundation
import RadicleKit

/// Bundle of Radicle collaborators threaded `FreedomApp → TabStore →
/// BrowserTab → RadicleBridge`. Mirrors `SwarmServices`'s shape.
@MainActor
struct RadicleServices {
    let node: RadicleNode
    let permissionStore: RadiclePermissionStore
    /// One per app session, shared across tabs, so `seedStatus` events
    /// and snapshots survive page reloads and multi-tab same-origin use.
    let seedTracker: RadicleSeedTracker
    /// `nil` when provider methods may run, or a
    /// `RadicleBridge.ErrorPayload.Reason` string otherwise. Composed in
    /// `FreedomApp.init` from the live observables (settings toggle +
    /// node status).
    let nodeFailureReason: @MainActor () -> String?
}
