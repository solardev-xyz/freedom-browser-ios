import Foundation
import IPFSKit

/// Owns the in-flight IPFS identity swap — kicked off by vault create /
/// import / wipe and by the idempotent `checkAndHeal` self-heal hook
/// in `ContentView`. Decouples the wallet UX from kubo's restart
/// (~1–2s); the user sees the wallet succeed quickly and the swap
/// finishes in the background.
///
/// Direct mirror of `BeeIdentityCoordinator` for the IPFS half: same
/// `Status` enum shape, same retry semantics, same alert wiring.
/// One swap at a time. Re-entry cancels the prior task and starts a new
/// one. The coordinator remembers what to re-run for `retry()`.
@MainActor
@Observable
final class IpfsIdentityCoordinator {
    enum Status: Equatable {
        case idle
        case swapping
        case failed(message: String)
    }

    typealias InjectionWork = @MainActor (Vault, IPFSNode, SettingsStore) async throws -> Void
    typealias RevertWork = @MainActor (IPFSNode, SettingsStore) async throws -> Void

    private(set) var status: Status = .idle

    /// Bool accessor for the alert's `isPresented:` binding — keeps the
    /// `Status` enum's case shape inside this file so the view layer
    /// doesn't pattern-match coordinator internals.
    var isFailed: Bool { failedMessage != nil }

    /// Message accessor for the alert's `presenting:` slot. Returns nil
    /// for non-failed states.
    var failedMessage: String? {
        if case .failed(let m) = status { return m }
        return nil
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Captured at start so the modal's Retry button can re-run the last
    /// operation without the caller reconstructing the inputs.
    @ObservationIgnored private var retryAction: (() -> Void)?
    @ObservationIgnored private let injectFn: InjectionWork
    @ObservationIgnored private let revertFn: RevertWork
    @ObservationIgnored private let settings: SettingsStore

    init(
        settings: SettingsStore,
        inject: @escaping InjectionWork = {
            try await IpfsIdentityInjector.inject(vault: $0, ipfs: $1, settings: $2)
        },
        revert: @escaping RevertWork = {
            try await IpfsIdentityInjector.revertToAnonymous(ipfs: $0, settings: $1)
        }
    ) {
        self.settings = settings
        self.injectFn = inject
        self.revertFn = revert
    }

    func injectInBackground(vault: Vault, ipfs: IPFSNode) {
        retryAction = { [weak self] in
            self?.injectInBackground(vault: vault, ipfs: ipfs)
        }
        run { [injectFn, settings] in try await injectFn(vault, ipfs, settings) }
    }

    func revertInBackground(ipfs: IPFSNode) {
        retryAction = { [weak self] in
            self?.revertInBackground(ipfs: ipfs)
        }
        run { [revertFn, settings] in try await revertFn(ipfs, settings) }
    }

    /// No-op if there's no failure to recover from (e.g. user cancelled
    /// the alert first).
    func retry() {
        guard case .failed = status, let retryAction else { return }
        retryAction()
    }

    /// Drop a `.failed` state without retrying. Kubo is left in whatever
    /// state the failed swap put it in; the user can wipe + recreate or
    /// trigger another swap to recover.
    func dismissError() {
        guard case .failed = status else { return }
        status = .idle
        retryAction = nil
    }

    /// Idempotent self-heal: if the vault has been unlocked and the IPFS
    /// node is running, but the node's PeerID differs from what the
    /// vault would derive at the SLIP-0010 IPFS path, kicks off an
    /// inject. Catches the case where a previous swap was interrupted
    /// (app crashed mid-restart, force-quit, etc.).
    func checkAndHeal(vault: Vault, ipfs: IPFSNode) {
        guard case .idle = status else { return }
        guard vault.state == .unlocked, ipfs.status == .running else { return }
        guard let seed = try? vault.bip39Seed() else { return }
        guard let identity = try? IpfsIdentityKey.derive(fromSeed: seed) else { return }
        let derivedPeerID = IpfsIdentityFormat.peerID(publicKey: identity.publicKey)
        if IpfsIdentityInjector.peerIDsMatch(derivedPeerID, ipfs.peerID) { return }
        injectInBackground(vault: vault, ipfs: ipfs)
    }

    // MARK: - Private

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        status = .swapping
        task = Task { [weak self] in
            do {
                try await work()
                guard let self, !Task.isCancelled else { return }
                self.status = .idle
                self.retryAction = nil
            } catch is CancellationError {
                // Superseded by a newer swap — newer task already moved
                // status forward. Nothing to do.
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status = .failed(message: error.localizedDescription)
            }
        }
    }
}
