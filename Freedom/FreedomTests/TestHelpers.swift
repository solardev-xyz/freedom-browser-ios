import Foundation
import SwiftData
import UIKit
import web3
import WebKit
@testable import Freedom

/// Builds a `ModelContainer` backed by an ephemeral in-memory store for
/// per-test isolation. Replaces the `ModelConfiguration(isStoredInMemoryOnly:
/// true)` + `ModelContainer(for:configurations:)` boilerplate spread across
/// the SwiftData-backed store tests.
func inMemoryContainer(for models: any PersistentModel.Type...) throws -> ModelContainer {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: Schema(models), configurations: config)
}

/// Builds a mainnet `EthereumRPCPool` whose URL source reads from
/// `settings.ensPublicRpcProviders` — the pre-WP3 test convenience,
/// preserved for tests that don't need a full `ChainStore` and just
/// want a settings-driven mainnet pool.
@MainActor
func mainnetPool(
    settings: SettingsStore,
    clock: @escaping () -> Date = Date.init
) -> EthereumRPCPool {
    EthereumRPCPool(
        chainID: Chain.mainnetID,
        urlSource: { settings.ensPublicRpcProviders },
        clock: clock
    )
}

/// One-stop bundle that mirrors prod's chain stack — in-memory
/// `ChainStore` seeded with mainnet + Gnosis, mainnet pool sourcing
/// URLs from the store, and a registry holding both. Hold a single
/// reference on the test class so the `ModelContainer` outlives every
/// fetch the test triggers.
@MainActor
final class ChainStackBundle {
    let container: ModelContainer
    let settings: SettingsStore
    let chainStore: ChainStore
    let mainnetPool: EthereumRPCPool
    let registry: ChainRegistry

    init(
        settings: SettingsStore? = nil,
        clock: @escaping () -> Date = Date.init,
        orderer: @escaping ([URL]) -> [URL] = { $0.shuffled() }
    ) throws {
        // Per-bundle UserDefaults suite by default — keeps the chain
        // store's migration markers and provider lists isolated from
        // `UserDefaults.standard`, which is shared across the test process.
        let s = settings ?? SettingsStore(
            defaults: UserDefaults(suiteName: "ChainStack-\(UUID().uuidString)")!
        )
        self.settings = s
        container = try inMemoryContainer(for: ChainRecord.self)
        chainStore = ChainStore(context: container.mainContext, settings: s)
        let store = chainStore
        mainnetPool = EthereumRPCPool(
            chainID: Chain.mainnetID,
            urlSource: { store.rpcURLs(forChainID: Chain.mainnetID) },
            clock: clock,
            orderer: orderer
        )
        registry = ChainRegistry(chainStore: store, mainnetPool: mainnetPool, poolOrderer: orderer)
    }
}

/// Standard hardhat / anvil test mnemonic. Account 0 derives to
/// `0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266`. Used across the wallet
/// + bridge test suite; centralized so vector lookups against external
/// docs match a single source.
let hardhatMnemonic = "test test test test test test test test test test test junk"

/// Address `hardhatMnemonic` derives at m/44'/60'/0'/0/0 — lowercase, as
/// `KeyUtil.recoverPublicKey` returns it.
let hardhatAccount0 = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

/// One-stop `WalletServices` over a `ChainStackBundle` for wallet-endpoint
/// tests: in-memory permission + auto-approve stores. The containers are
/// returned so callers can keep them alive for the test's duration.
@MainActor
func makeWalletServices(
    vault: Vault,
    bundle: ChainStackBundle
) throws -> (services: WalletServices, containers: [ModelContainer]) {
    let permissionContainer = try inMemoryContainer(for: DappPermission.self)
    let autoApproveContainer = try inMemoryContainer(for: AutoApproveRule.self)
    let services = WalletServices(
        vault: vault,
        chainRegistry: bundle.registry,
        chainStore: bundle.chainStore,
        permissionStore: PermissionStore(context: permissionContainer.mainContext),
        autoApproveStore: AutoApproveStore(context: autoApproveContainer.mainContext),
        transactionService: TransactionService(vault: vault, registry: bundle.registry),
        ensResolver: ENSResolver(pool: bundle.mainnetPool, settings: bundle.settings)
    )
    return (services, [permissionContainer, autoApproveContainer])
}

final class MutableClock {
    var now: Date
    init(now: Date) { self.now = now }
    func advance(by interval: TimeInterval) { now.addTimeInterval(interval) }
}

actor ActorCallTracker {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

/// A deterministic `LegRunner` driven by a per-URL outcome map. Any URL
/// not in the map returns a generic network error so missing entries are
/// obvious in test failures.
func makeLegRunner(_ kinds: [URL: QuorumLeg.Outcome.Kind]) -> QuorumWave.LegRunner {
    { url, _, _, _, _, _, _ in
        QuorumLeg.Outcome(url: url, kind: kinds[url] ?? .error(URLError(.badServerResponse)))
    }
}

/// Wrap raw bytes as an ABI-encoded `bytes` payload — matches the shape
/// the UR returns after one layer of unwrapping. Force-tries so encoding
/// failures fail the test loudly rather than silently corrupting assertions.
func abiEncodeBytes(_ payload: Data) -> Data {
    let encoder = ABIFunctionEncoder("_")
    try! encoder.encode(payload)
    let full = try! encoder.encoded()
    return Data(full.dropFirst(4))  // strip 4-byte method id
}

/// Encode an `OffchainLookup` revert payload (selector + ABI-encoded args)
/// the way an RPC `error.data` field carries it. Used by both the forward
/// CCIP tests and the reverse CCIP tests.
func encodeOffchainLookupRevert(
    address: EthereumAddress,
    urls: [String],
    callData: Data = Data([0xaa, 0xbb, 0xcc, 0xdd]),
    callbackFunction: Data = Data([0xde, 0xad, 0xbe, 0xef]),
    extraData: Data = Data()
) -> Data {
    let lookup = OffchainLookup(
        address: address,
        urls: urls,
        callData: callData,
        callbackFunction: callbackFunction,
        extraData: extraData
    )
    let encoder = ABIFunctionEncoder(OffchainLookup.name)
    try! lookup.encode(to: encoder)
    return try! encoder.encoded()
}

/// JSON-RPC `result` envelope wrapper used across the wallet/router/tx
/// test suites. Force-tries — encoding failures should fail the test, not
/// be silently swallowed.
func rpcResult(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": value])
}

/// JSON-RPC `error` envelope wrapper. `dataHex` non-nil → EIP-474
/// execution-revert shape (the `error.data` field is what the wallet
/// uses to discriminate deterministic protocol answers from provider
/// quirks).
func rpcError(code: Int, message: String, dataHex: String? = nil) throws -> Data {
    var error: [String: Any] = ["code": code, "message": message]
    if let dataHex { error["data"] = dataHex }
    return try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "error": error,
    ])
}

/// Stubs for `VaultCrypto`'s biometric gate. Real `LAContext` would hang
/// waiting for simulator-user interaction; these drive deterministic
/// success / "can't gate" paths.
struct AlwaysAllowPrompter: BiometricPrompter {
    func canPrompt() -> Bool { true }
    func prompt(reason: String) async throws {}
}

struct NeverPrompter: BiometricPrompter {
    func canPrompt() -> Bool { false }
    func prompt(reason: String) async throws {
        throw CancellationError()
    }
}

extension Data {
    /// Lowercase hex, no `0x` prefix. Test vectors in the BIP-39/BIP-32/
    /// Ethereum specs are presented without the prefix, so comparing against
    /// `.web3.hexString` (which prepends `0x`) would force a drop at every
    /// assertion site — this avoids that noise.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Attaches a hidden WKWebView to the test host's key window — detached
/// WKWebViews get their timers and network throttled, which stalls
/// anything driven from inside the page (used by the OpenLV engine tests).
@MainActor
func attachToKeyWindow(_ webView: WKWebView) {
    UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
        .first?
        .addSubview(webView)
}
