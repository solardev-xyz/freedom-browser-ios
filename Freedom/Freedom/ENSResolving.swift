import Foundation

/// One-method protocol over `ENSResolver.resolveContent`. Exists so the
/// scheme handlers can be unit-tested with a fake resolver — wiring up
/// the real `ENSResolver` requires the full RPC pool + anchor cache +
/// settings store, which makes per-handler-branch testing painful.
@MainActor
protocol ENSResolving: AnyObject {
    func resolveContent(_ name: String) async throws -> ENSResolvedContent
}

extension ENSResolver: ENSResolving {}

/// Per-scheme-task cancellation marker for scheme handlers that
/// await ENS resolution before issuing the upstream fetch. The
/// existing `active` dict in each handler is keyed by
/// `dataTask.taskIdentifier`, which doesn't exist yet pre-resolve —
/// so `stop(_:)` flips this flag to signal the post-await branch
/// that it should bail out before opening a URLSession data task.
@MainActor
final class PendingResolution {
    var cancelled = false
}
