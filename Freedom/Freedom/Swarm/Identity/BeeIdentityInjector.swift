import Foundation
import SwarmKit

/// Orchestrates Swarm node identity changes — vault create / import (swap
/// to derived identity) and vault wipe (revert to anonymous).
///
/// The Swarm node is now Rust Ant (`ant-ffi`), which reads its identity
/// from `<dataDir>/identity.json` at `ant_init` (NOT desktop's
/// `keys/swarm.key` keystore — that's the `antd` daemon's format, which
/// the in-process FFI doesn't read). So injection here is:
///
///   1. derive the Swarm wallet from `m/44'/60'/0'/0/1`
///   2. short-circuit if the derived address matches what the running node
///      already reports (same-mnemonic re-import path)
///   3. stop the node, wait for `.stopped`
///   4. wipe identity-tied auxiliary state
///   5. seed `identity.json` with the derived signing key + a zero overlay
///      nonce (`SwarmNode.writeInjectedIdentity`) — this makes the overlay
///      byte-identical to desktop's injected node for the same wallet
///   6. start the node, wait for `.running`
///
/// `revertToAnonymous` is the wipe counterpart: full data-dir wipe so Ant
/// regenerates a fresh random `identity.json` on next start.
///
/// Failures between steps 4 and 8 leave the user in a partial state.
/// Recovery is "wipe wallet → recreate", a tested UX path.
@MainActor
enum BeeIdentityInjector {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case waitTimeout(target: SwarmStatus)
        case keystoreWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .waitTimeout(let target):
                "Timed out waiting for the Swarm node to reach \(target.rawValue)."
            case .keystoreWriteFailed(let detail):
                "Couldn't write the Swarm node keystore: \(detail)"
            }
        }
    }

    /// Polling cadence for status transitions. Fast enough that the user
    /// doesn't notice the wait, slow enough that we don't burn the main
    /// actor on tight loops.
    private static let pollIntervalNanos: UInt64 = 100_000_000  // 0.1s

    /// Shut-down typically completes in <1s; budget for slow simulators
    /// and the rare case where bee-lite is mid-network-IO when SIGTERM lands.
    static let stopTimeoutSeconds: TimeInterval = 10

    /// First-boot setup (chequebook check, libp2p key generation, initial
    /// bootnode handshake) typically takes 2-4s on light mode, sub-second
    /// on ultralight. Generous for first-time state init on a fresh device.
    static let startTimeoutSeconds: TimeInterval = 30

    /// Which paths inside the data dir the restart should erase.
    private enum WipeMode {
        case auxiliaryOnly  // identity swap — keep `keys/swarm.key` for overwrite
        case all            // revert to anonymous — let Bee regenerate everything
    }

    /// Swap the Bee node's identity to one derived from the user's vault.
    /// Idempotent for same-mnemonic re-imports — compares the derived
    /// address to what the running node already reports and returns early
    /// when they match.
    static func inject(vault: Vault, swarm: SwarmNode, mode: BeeNodeMode) async throws {
        let hdKey = try vault.signingKey(at: .beeWallet)
        let derivedAddress = try hdKey.ethereumAddress

        if Self.addressesMatch(derivedAddress, swarm.walletAddress),
           swarm.status == .running {
            return
        }

        // The SwarmConfig password is vestigial under Ant (Ant owns its
        // identity via identity.json), but BeeBootConfig still threads it
        // — keep loading it so the config shape is unchanged.
        let password = try BeePassword.loadOrCreate()
        let config = await BeeBootConfig.build(password: password, mode: mode)

        try await restart(
            swarm: swarm,
            wipe: .auxiliaryOnly,
            signingKey: hdKey.privateKey,
            config: config
        )
    }

    /// Drop the user-derived identity and let Bee regenerate a fresh
    /// internal random key. Called on vault wipe so the node doesn't
    /// keep signing as a seed the user just chose to forget. Always
    /// restarts in ultralight — caller is responsible for resetting
    /// `settings.beeNodeMode` to `.ultraLight` so the next launch agrees.
    static func revertToAnonymous(swarm: SwarmNode) async throws {
        let password = try BeePassword.loadOrCreate()
        async let config = BeeBootConfig.build(password: password, mode: .ultraLight)
        try await restart(
            swarm: swarm,
            wipe: .all,
            signingKey: nil,
            config: await config
        )
    }

    /// Restart bee-lite with a different `BeeNodeMode` while keeping the
    /// existing identity. Used by the ultralight→light upgrade after the
    /// funder tx confirms; bee re-boots into light mode and starts the
    /// chequebook deploy + postage sync.
    ///
    /// Deliberately does NOT wait for `.running`: bee's first boot in
    /// light mode includes a chequebook deploy + batch snapshot load +
    /// postage sync prep + warmup, totalling ~5 minutes on a fresh
    /// install. The wallet's status bar + publish-setup checklist drive
    /// progress UI from `BeeReadiness`; a synchronous "wait for running"
    /// gate here only produces fake errors when the wait expires before
    /// bee finishes — bee continues starting regardless.
    static func restartForMode(swarm: SwarmNode, mode: BeeNodeMode) async throws {
        let password = try BeePassword.loadOrCreate()
        async let config = BeeBootConfig.build(password: password, mode: mode)
        try await ensureStopped(swarm)
        swarm.start(await config)
    }

    /// Lowercase byte-equality on hex addresses. Both inputs may carry an
    /// optional `0x` prefix and arbitrary case (callers include EIP-55
    /// checksummed sources). Empty strings — e.g. a freshly-constructed
    /// `SwarmNode` before its first `start` — never match anything,
    /// otherwise initial vault create would silently skip the keystore
    /// write.
    static func addressesMatch(_ a: String, _ b: String) -> Bool {
        let na = Hex.stripped(a.lowercased())
        let nb = Hex.stripped(b.lowercased())
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb
    }

    // MARK: - Private

    /// Shared restart sequence for both inject and revert. `signingKey` is
    /// non-nil for inject (seed `identity.json` after wiping auxiliary
    /// state) and nil for revert (let Ant regenerate a fresh random
    /// identity).
    private static func restart(
        swarm: SwarmNode,
        wipe: WipeMode,
        signingKey: Data?,
        config: SwarmConfig
    ) async throws {
        try await ensureStopped(swarm)
        let dataDir = SwarmNode.defaultDataDir()
        switch wipe {
        case .auxiliaryOnly: try BeeStateDirs.wipeAuxiliaryState(at: dataDir)
        case .all:           try BeeStateDirs.wipeAll(at: dataDir)
        }
        if let signingKey {
            try SwarmNode.writeInjectedIdentity(signingKey: signingKey, dataDir: dataDir)
        }
        swarm.start(config)
        try await waitForStatus(swarm, target: .running, timeout: startTimeoutSeconds)
    }

    /// Bounded so a stuck `.starting` / `.stopping` transition doesn't hang.
    private static func ensureStopped(_ swarm: SwarmNode) async throws {
        let deadline = Date().addingTimeInterval(stopTimeoutSeconds)
        while Date() < deadline,
              swarm.status == .starting || swarm.status == .stopping {
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        if swarm.status == .running {
            swarm.stop()
            try await waitForStatus(swarm, target: .stopped, timeout: stopTimeoutSeconds)
        }
    }

    private static func waitForStatus(
        _ swarm: SwarmNode,
        target: SwarmStatus,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if swarm.status == target { return }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        if swarm.status == target { return }
        throw Error.waitTimeout(target: target)
    }
}
