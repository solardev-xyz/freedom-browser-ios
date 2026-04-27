import Foundation
import SwarmKit

/// Orchestrates Bee node identity changes — vault create / import (swap to
/// derived identity) and vault wipe (revert to anonymous). Sequence for
/// `inject` matches desktop `identity-manager.js:399-445`:
///
///   1. derive bee wallet from `m/44'/60'/0'/0/1`
///   2. short-circuit if the derived address matches what the running node
///      already reports (same-mnemonic re-import path)
///   3. encrypt the private key into a V3 keystore
///   4. stop the node, wait for `.stopped`
///   5. wipe identity-tied auxiliary state
///   6. overwrite `keys/swarm.key`
///   7. start the node with a fresh config built around the same password
///   8. wait for `.running`
///
/// `revertToAnonymous` is the wipe counterpart: full data-dir wipe so Bee
/// regenerates a fresh internal random key under the existing Keychain
/// password.
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

        let password = try BeePassword.loadOrCreate()
        // Resolve bootnodes in parallel with scrypt + stop + wipe + write —
        // the network call is independent of every other step and finishes
        // in time to be ready when we hand the config to swarm.start.
        async let config = BeeBootConfig.build(password: password, mode: mode)

        // scrypt N=32768 is intentionally 3-5s of CPU; running it on the
        // main actor would freeze gesture / scroll responsiveness for the
        // duration. Detach so the actor stays free. Priority matches the
        // vault's other crypto offloads (`Vault.swift:47, 58, 92, 98`).
        let privateKey = hdKey.privateKey
        let strippedAddress = Hex.stripped(derivedAddress)
        let keystoreJSON = try await Task.detached(priority: .userInitiated) {
            try BeeKeystore.encrypt(
                privateKey: privateKey,
                password: password,
                address: strippedAddress
            )
        }.value

        try await restart(
            swarm: swarm,
            wipe: .auxiliaryOnly,
            keystoreJSON: keystoreJSON,
            config: await config
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
            keystoreJSON: nil,
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
        let config = await BeeBootConfig.build(password: password, mode: mode)
        try await ensureStopped(swarm)
        // bee-lite's `shutdown()` returns synchronously, but the
        // gomobile-bound bee object isn't released by Go's GC until
        // later — non-deterministic timing. Until that happens the
        // prior bee's leveldb LOCK fcntl is still held, and starting
        // a new bee on the same data dir fails fast with
        // `init state store: resource temporarily unavailable`. Inject
        // paths sidestep this by wiping the dir; mode-change keeps it,
        // so we retry until GC catches up (typically <5s).
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            swarm.start(config)
            // bee fails fast on LOCK contention (~100ms); 1.5s is
            // plenty to distinguish lock race from a healthy startup
            // that's transitioning into `.starting`.
            try await Task.sleep(nanoseconds: 1_500_000_000)
            if swarm.status != .failed { return }
        }
        throw Error.waitTimeout(target: .running)
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

    /// Shared restart sequence for both inject and revert. The `keystoreJSON`
    /// param is non-nil for inject (overwrite `keys/swarm.key` after wiping
    /// auxiliary state) and nil for revert (let Bee regenerate fresh).
    private static func restart(
        swarm: SwarmNode,
        wipe: WipeMode,
        keystoreJSON: Data?,
        config: SwarmConfig
    ) async throws {
        try await ensureStopped(swarm)
        let dataDir = SwarmNode.defaultDataDir()
        switch wipe {
        case .auxiliaryOnly: try BeeStateDirs.wipeAuxiliaryState(at: dataDir)
        case .all:           try BeeStateDirs.wipeAll(at: dataDir)
        }
        if let keystoreJSON {
            try writeKeystore(keystoreJSON, at: dataDir)
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

    private static func writeKeystore(_ json: Data, at dataDir: URL) throws {
        let keysDir = dataDir.appendingPathComponent("keys")
        try FileManager.default.createDirectory(
            at: keysDir, withIntermediateDirectories: true
        )
        do {
            try json.write(to: keysDir.appendingPathComponent("swarm.key"))
        } catch {
            throw Error.keystoreWriteFailed(error.localizedDescription)
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
