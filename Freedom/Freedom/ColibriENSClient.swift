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
    private let chainStore: ChainStore
    private var cached: Colibri?
    private var cachedKey: String?

    init(settings: SettingsStore, chainStore: ChainStore) {
        self.settings = settings
        self.chainStore = chainStore
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
        let hex = try await provenEthCall(to: UniversalResolverABI.address, callData: encoded)
        return try UniversalResolverABI.decodeResolveResponse(hex)
    }

    /// One proven eth_call straight to a NameNFT registry (WNS/GNS) with
    /// the inner resolver calldata — no `resolve()` envelope. The raw
    /// return already matches the UR's inner `resolvedData` shape (ABI
    /// `bytes` for contenthash, padded address for addr), so downstream
    /// decoding is shared with the UR path.
    func nameNftCall(
        contract: EthereumAddress,
        callData: Data
    ) async throws -> (resolvedData: Data, resolverAddress: EthereumAddress) {
        let hex = try await provenEthCall(to: contract, callData: callData)
        guard let bytes = hex.web3.hexData, !bytes.isEmpty else {
            throw ColibriENSError.unexpectedResponse(hex)
        }
        return (bytes, contract)
    }

    /// Universal Resolver `reverse(bytes,uint256)` via Colibri. The UR
    /// internally checks forward-resolution and reverts with
    /// `ReverseAddressMismatch(string,bytes)` on spoofed records — that
    /// revert surfaces as `ColibriENSError.revert(data:)`, which
    /// `ENSResolver.colibriReverse` decodes into `.unverified`.
    func universalResolverReverse(
        address: EthereumAddress
    ) async throws -> String {
        let encoded = try UniversalResolverABI.encodeReverse(address: address)
        let hex = try await provenEthCall(to: UniversalResolverABI.address, callData: encoded)
        return UniversalResolverABI.decodeReverseResponse(hex) ?? ""
    }

    /// One eth_call through the Colibri verifier, returning the proven
    /// return data as hex. Errors come back as typed `ColibriENSError`.
    private func provenEthCall(to: EthereumAddress, callData: Data) async throws -> String {
        let paramsJSON = try JSONSerialization.data(withJSONObject: [
            ["to": to.asString(), "data": callData.web3.hexString],
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
        return hex
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
        // Explicit freshness window for "latest"-tag proofs (desktop parity,
        // freedom-browser #116). The 1.1.30 verifier rejects proofs whose
        // block timestamp is older than this, closing the stale-proof gap —
        // set explicitly rather than relying on the binding's default so a
        // future default change upstream can't silently widen our window.
        client.maxLatestAgeSeconds = 60
        // `checkpointz` is left empty on purpose: since 1.1.30 the binding
        // falls back to its per-chain public checkpointz defaults at
        // runtime (plus witness verification across the Weak Subjectivity
        // Period in zk mode), which is exactly the hardened behavior we
        // asked corpus-core for.
        // `.basic` (PAP) mode does optimistic `eth_call` execution against
        // execution-layer data (`eth_getProof`, `eth_getCode`) fetched from
        // these RPCs and verified locally against the prover-attested state
        // root — a lying RPC can't forge a Merkle proof, so this is an
        // untrusted data source, not a trusted one. Sourced from the
        // mainnet `ChainRecord` so it tracks the same list `ENSResolver`
        // and `WalletRPC` use.
        client.eth_rpcs = chainStore.rpcURLs(forChainID: Chain.mainnetID)
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
    /// The `eth_call` ran to completion but the EVM reverted — a fully
    /// verified outcome, not a proof/transport failure. `data` is the
    /// raw revert return-data (`0x`-prefixed hex). Callers ABI-decode it
    /// to tell `OffchainLookup` / `ReverseAddressMismatch` / a bare
    /// "no contenthash" revert apart.
    case revert(data: String)
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
    if case let ColibriError.revert(data) = error {
        return .revert(data: data)
    }
    if let urlErr = error as? URLError {
        return .network(underlying: urlErr)
    }
    return .proofFailed(message: String(describing: error))
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
