import Foundation
import IPFSKit

/// Orchestrates kubo node identity changes — vault create / import (swap
/// to vault-derived identity) and vault wipe (revert to a fresh random
/// identity). Mirrors `BeeIdentityInjector` for the IPFS side; the
/// shape parallels desktop Freedom's `identity-manager.js` flow.
///
/// `inject` sequence:
///   1. derive Ed25519 keypair from `vault.bip39Seed()` at the IPFS
///      SLIP-0010 path
///   2. compute libp2p PrivKey base64 + PeerID
///   3. short-circuit if the running config already has the same PeerID
///      (same-mnemonic re-import path)
///   4. stop the kubo node, wait for `.stopped`
///   5. write `Identity.PeerID` + `Identity.PrivKey` into kubo's
///      `<dataDir>/config`, preserving every other field
///   6. start the node with the same config
///   7. wait for `.running`
///
/// `revertToAnonymous` is the wipe counterpart — full data-dir wipe so
/// kubo regenerates a fresh random keypair on the next `fsrepo.Init`.
///
/// Failures between stop and start leave the user in a partial state.
/// Recovery is "wipe wallet → recreate", same as bee.
@MainActor
enum IpfsIdentityInjector {
    enum Error: Swift.Error, LocalizedError {
        case waitTimeout(target: IPFSStatus)
        case configWriteFailed(String)
        case dataDirWipeFailed(String)

        var errorDescription: String? {
            switch self {
            case .waitTimeout(let target):
                "Timed out waiting for the IPFS node to reach \(target.rawValue)."
            case .configWriteFailed(let detail):
                "Couldn't write the IPFS node config: \(detail)"
            case .dataDirWipeFailed(let detail):
                "Couldn't wipe the IPFS data directory: \(detail)"
            }
        }
    }

    /// Polling cadence for status transitions. Matches bee's injector
    /// (Freedom/Swarm/Identity/BeeIdentityInjector.swift).
    private static let pollIntervalNanos: UInt64 = 100_000_000  // 0.1s

    /// Kubo's shutdown is fast (~15ms in coprobe). 5s is generous for
    /// simulator overhead.
    static let stopTimeoutSeconds: TimeInterval = 5

    /// Kubo's first online start is ~1.1s in coprobe; 30s is generous
    /// for cold-cache plugin init / repo init / DHT bring-up paths.
    static let startTimeoutSeconds: TimeInterval = 30

    /// Swap the kubo node's identity to one derived from the user's
    /// vault. Idempotent: if the config's current PeerID already
    /// matches the derived PeerID and the node is running, returns
    /// without doing any work.
    static func inject(vault: Vault, ipfs: IPFSNode, settings: SettingsStore) async throws {
        let seed = try vault.bip39Seed()
        let identity = try IpfsIdentityKey.derive(fromSeed: seed)
        let derivedPeerID = IpfsIdentityFormat.peerID(publicKey: identity.publicKey)
        let derivedPrivKey = IpfsIdentityFormat.libp2pPrivKeyBase64(
            privateKey: identity.privateKey,
            publicKey: identity.publicKey
        )

        let dataDir = IPFSNode.defaultDataDir()
        if let current = try? IpfsKuboConfig.currentPeerID(at: dataDir),
           Self.peerIDsMatch(current, derivedPeerID),
           ipfs.status == .running {
            return
        }

        let config = settings.ipfsConfig(dataDir: dataDir)
        try await ensureStopped(ipfs)
        try writeIdentity(at: dataDir, peerID: derivedPeerID, privKeyBase64: derivedPrivKey)
        ipfs.start(config)
        try await waitForStatus(ipfs, target: .running, timeout: startTimeoutSeconds)
    }

    /// Drop the user-derived identity and let kubo regenerate fresh.
    /// Wipes the entire data dir so `fsrepo.Init` runs from scratch on
    /// the next start (mirrors bee's `revertToAnonymous` `.all` wipe).
    static func revertToAnonymous(ipfs: IPFSNode, settings: SettingsStore) async throws {
        let dataDir = IPFSNode.defaultDataDir()
        let config = settings.ipfsConfig(dataDir: dataDir)
        try await ensureStopped(ipfs)
        do {
            if FileManager.default.fileExists(atPath: dataDir.path) {
                try FileManager.default.removeItem(at: dataDir)
            }
        } catch {
            throw Error.dataDirWipeFailed(error.localizedDescription)
        }
        ipfs.start(config)
        try await waitForStatus(ipfs, target: .running, timeout: startTimeoutSeconds)
    }

    /// Case-sensitive equality on Base58 PeerIDs. Empty strings — e.g.
    /// a freshly-constructed `IPFSNode` before its first `start` —
    /// never match anything, otherwise initial vault create would
    /// silently skip the config write.
    static func peerIDsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }

    // MARK: - Private

    private static func writeIdentity(at dataDir: URL, peerID: String, privKeyBase64: String) throws {
        do {
            try IpfsKuboConfig.injectIdentity(
                at: dataDir,
                peerID: peerID,
                privKeyBase64: privKeyBase64
            )
        } catch {
            throw Error.configWriteFailed(error.localizedDescription)
        }
    }

    /// Bounded so a stuck `.starting` / `.stopping` transition doesn't hang.
    private static func ensureStopped(_ ipfs: IPFSNode) async throws {
        let deadline = Date().addingTimeInterval(stopTimeoutSeconds)
        while Date() < deadline,
              ipfs.status == .starting || ipfs.status == .stopping {
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        if ipfs.status == .running {
            ipfs.stop()
            try await waitForStatus(ipfs, target: .stopped, timeout: stopTimeoutSeconds)
        }
    }

    private static func waitForStatus(
        _ ipfs: IPFSNode,
        target: IPFSStatus,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ipfs.status == target { return }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        if ipfs.status == target { return }
        throw Error.waitTimeout(target: target)
    }
}
