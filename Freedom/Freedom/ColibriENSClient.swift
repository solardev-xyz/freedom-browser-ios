import Foundation
import Colibri
import OSLog
import web3

private let log = Logger(subsystem: "com.browser.Freedom", category: "ColibriENS")

/// Cryptographically-verified ENS resolution via the corpus-core Colibri
/// stateless client. Drives a single `eth_call` against the ENS Universal
/// Resolver through a remote prover (`mainnet1.colibri-proof.tech` by
/// default). The verifier runs the EVM locally against proven storage and
/// validates against the Ethereum sync committee — so a successful return
/// has the same trust footing as a sync-committee-attested block, not the
/// looser M-of-K public-RPC agreement the quorum path uses.
///
/// Singleton per `(proverURL, zkProof)` tuple. Settings-driven invalidation
/// rebuilds the underlying `Colibri()` instance.
@MainActor
final class ColibriENSClient {
    static let defaultProverURL = "https://mainnet1.colibri-proof.tech"

    private let settings: SettingsStore
    private var cached: Colibri?
    private var cachedKey: String?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Drop the cached `Colibri()` so the next call rebuilds against the
    /// latest settings. Called from `ENSResolver.invalidate()`.
    func invalidate() {
        cached = nil
        cachedKey = nil
    }

    /// Universal Resolver `resolve(bytes name, bytes data)` via Colibri.
    /// Returns the raw ABI-encoded inner result + the resolver address
    /// chosen by the UR. Mirrors `QuorumLeg`'s decode shape so downstream
    /// contenthash / addr decoding is shared.
    func universalResolverCall(
        dnsEncodedName: Data,
        callData: Data
    ) async throws -> (resolvedData: Data, resolverAddress: EthereumAddress) {
        let encoded = try UniversalResolverABI.encodeResolve(name: dnsEncodedName, callData: callData)
        let paramsJSON = try JSONSerialization.data(withJSONObject: [
            ["to": UniversalResolverABI.address.asString(), "data": encoded.web3.hexString],
            "latest",
        ])
        let params = String(data: paramsJSON, encoding: .utf8) ?? "[]"
        let client = currentClient()
        let rawResult: Any
        do {
            rawResult = try await client.rpc(method: "eth_call", params: params)
        } catch {
            throw mapColibriError(error)
        }
        guard let hex = rawResult as? String else {
            throw ColibriENSError.unexpectedResponse(String(describing: rawResult))
        }
        return try UniversalResolverABI.decodeResolveResponse(hex)
    }

    /// Host of the currently-active prover, for logging and the trust
    /// popover. Reads live settings so a settings flip is reflected
    /// without rebuilding the client.
    var activeProverHost: String {
        URL(string: resolvedProverURL)?.host ?? resolvedProverURL
    }

    // MARK: - Client lifecycle

    private var resolvedProverURL: String {
        let raw = settings.ensColibriProverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? Self.defaultProverURL : raw
    }

    private var key: String { "\(resolvedProverURL)|\(settings.ensColibriZkProof)" }

    private func currentClient() -> Colibri {
        if let cached, cachedKey == key { return cached }
        let client = Colibri()
        client.chainId = 1
        client.provers = [resolvedProverURL]
        client.zkProof = settings.ensColibriZkProof
        client.privacyMode = .basic
        // Intentionally no `eth_rpcs` — Colibri's trust model is "the
        // prover is the only external party beyond Ethereum consensus."
        // Sub-requests that fall through to `eth_rpcs` indicate a
        // binding-version gap to diagnose, not paper over.
        cached = client
        cachedKey = key
        log.info("[colibri] client ready prover=\(self.activeProverHost, privacy: .public) zk=\(self.settings.ensColibriZkProof, privacy: .public)")
        return client
    }
}

/// Typed errors out of `ColibriENSClient`. The resolver consumes these to
/// decide between a verified-negative outcome (legitimate `.noContenthash`
/// / `.noResolver`) and a transient failure (network / proof) that should
/// trigger the quorum fallback.
enum ColibriENSError: Error {
    /// EVM-level revert during proof replay. Either the underlying resolver
    /// has no contenthash for this name (verified-negative) or it reverted
    /// for another reason. The v1.1.24 binding doesn't expose the revert
    /// selector so we can't distinguish `ResolverNotFound` from
    /// `NoContenthash` here — both surface as `.contractRevert`. Refine
    /// once the binding exposes revert data.
    case contractRevert(message: String)
    /// Proof generation / verification failed (prover outage, sync
    /// committee mismatch, transient binding error). Treated as transient
    /// — caller falls back to quorum when `ensFallbackToQuorum` is on.
    case proofFailed(message: String)
    case network(underlying: Error)
    /// Decode of the proven response failed — indicates a binding/ABI
    /// mismatch if seen.
    case unexpectedResponse(String)
}

private func mapColibriError(_ error: Error) -> ColibriENSError {
    let description = String(describing: error)
    // v1.1.24 wraps revert outcomes as
    // `proofError("RPC error for method eth_call: Revert")`. Match the
    // ending token rather than the full string so a future binding with
    // richer messages still classifies correctly.
    if description.contains("Revert") {
        return .contractRevert(message: description)
    }
    if let urlErr = error as? URLError {
        return .network(underlying: urlErr)
    }
    return .proofFailed(message: description)
}

// MARK: - Disk storage adapter

/// File-backed `ColibriStorage` rooted at the app's application-support
/// directory. Registered once at app startup so the Colibri verifier's
/// sync-committee state survives across launches.
@MainActor
enum ColibriDiskStorage {
    /// Default storage location: `<app>/Library/Application Support/colibri`.
    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("colibri", isDirectory: true)
    }

    /// One-shot registration. Safe to call multiple times; the underlying
    /// `StorageBridge` is a process global and the last call wins. Tests
    /// register their own adapter and rely on registration order.
    static func register(directory: URL = defaultDirectory()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StorageBridge.registerStorage(DiskBacked(root: directory))
        log.info("[colibri] disk storage at \(directory.path, privacy: .public)")
    }

    private final class DiskBacked: ColibriStorage {
        let root: URL
        init(root: URL) { self.root = root }

        func get(key: String) -> Data? {
            try? Data(contentsOf: root.appendingPathComponent(key))
        }
        func set(key: String, value: Data) {
            try? value.write(to: root.appendingPathComponent(key))
        }
        func delete(key: String) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(key))
        }
    }
}
