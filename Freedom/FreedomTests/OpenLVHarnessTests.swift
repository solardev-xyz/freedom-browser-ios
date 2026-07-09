import SwiftData
import web3
import WebKit
import XCTest
@testable import Freedom

/// Full-protocol test against the real desktop host: the vendored
/// openlv SDK in the hidden WKWebView ↔ local MQTT signaling ↔ WebRTC
/// ↔ a Chromium page running the same SDK in the host role (Node has
/// no WebRTC).
///
/// Needs the harness from the freedom-browser repo running on the Mac —
/// run via `scripts/openlv-e2e.sh`, which boots it and passes
/// `OPENLV_HARNESS_URL` through to this process. Skips otherwise, so
/// the normal suite stays offline.
///
/// The host sends the exact sequence a desktop signing job produces:
/// eth_requestAccounts → wallet_switchEthereumChain pre-flight →
/// personal_sign. The test answers with canned values (approval-sheet
/// routing is WP-R4b) and asserts the host recorded them verbatim —
/// proving envelopes, encryption, signaling, and transport end to end.
@MainActor
final class OpenLVHarnessTests: XCTestCase {
    private static let account = "0x1111111111111111111111111111111111111111"
    private static let signature = "0x" + String(repeating: "ab", count: 65)

    func testDesktopHostSessionEndToEnd() async throws {
        guard let base = ProcessInfo.processInfo.environment["OPENLV_HARNESS_URL"] else {
            throw XCTSkip("OPENLV_HARNESS_URL not set — run scripts/openlv-e2e.sh")
        }

        let uri = try await fetchURI(base: base)
        XCTAssertTrue(uri.hasPrefix("openlv://"), "harness returned a non-openlv URI: \(uri)")

        let engine = WebViewOpenLVEngine()
        defer {
            engine.webView.removeFromSuperview()
            engine.stop()
        }
        attachToKeyWindow(engine.webView)

        var statuses: [OpenLVEngineStatus] = []
        engine.statusHandler = { statuses.append($0) }
        engine.requestHandler = { method, _ in
            switch method {
            case "eth_requestAccounts":
                return .result([Self.account])
            case "wallet_switchEthereumChain":
                return .result(NSNull())
            case "personal_sign":
                return .result(Self.signature)
            default:
                return .error(code: 4200, message: "Method not supported: \(method)")
            }
        }

        try await engine.start(uri: uri)

        let state = try await pollUntilDone(base: base, timeout: 90)
        XCTAssertNil(state["error"] as? String)
        XCTAssertTrue(statuses.contains(.connected), "engine never reported connected; saw \(statuses)")

        let exchanges = state["exchanges"] as? [[String: Any]] ?? []
        XCTAssertEqual(exchanges.map { $0["method"] as? String },
                       ["eth_requestAccounts", "wallet_switchEthereumChain", "personal_sign"])

        func response(_ index: Int) -> [String: Any]? {
            exchanges.indices.contains(index) ? exchanges[index]["response"] as? [String: Any] : nil
        }
        XCTAssertEqual(response(0)?["result"] as? [String], [Self.account])
        XCTAssertTrue(response(1)?.keys.contains("result") ?? false,
                      "chain switch should resolve with a (null) result, got \(String(describing: response(1)))")
        XCTAssertEqual(response(2)?["result"] as? String, Self.signature)
    }

    /// Same wire, full native pipeline: `OpenLVWalletSession` +
    /// `WebViewOpenLVEngine` + a real vault, with the approval parking
    /// resolved programmatically (standing in for the sheets). The
    /// signature the host records must recover to the vault account —
    /// exactly the verification desktop's remote signer performs.
    func testWalletSessionEndToEnd() async throws {
        guard let base = ProcessInfo.processInfo.environment["OPENLV_HARNESS_URL"] else {
            throw XCTSkip("OPENLV_HARNESS_URL not set — run scripts/openlv-e2e.sh")
        }

        let savedChainID = UserDefaults.standard.integer(forKey: WalletDefaults.activeChainID)
        let vaultService = "com.freedom.wallet.test.\(UUID().uuidString)"
        let vault = Vault(crypto: VaultCrypto(service: vaultService, preferred: .deviceBound))
        try await vault.create(mnemonic: Mnemonic(phrase: hardhatMnemonic))

        let bundle = try ChainStackBundle()
        let (services, containers) = try makeWalletServices(vault: vault, bundle: bundle)
        _ = containers // kept alive for the duration of the test
        let chainStore = bundle.chainStore
        let session = OpenLVWalletSession(
            services: services,
            activeChain: { chainStore.chain(id: Chain.defaultChain.id) ?? Chain.defaultChain }
        )
        defer {
            session.stop()
            UserDefaults.standard.set(savedChainID, forKey: WalletDefaults.activeChainID)
            try? VaultCrypto(service: vaultService).wipe()
        }

        // Stand-in for the approval sheets: approve whatever parks.
        let approver = Task { @MainActor in
            while !Task.isCancelled {
                if session.pendingApproval != nil {
                    session.resolvePendingApproval(.approved)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { approver.cancel() }

        let uri = try await fetchURI(base: base)
        try await session.start(uri: uri)

        let state = try await pollUntilDone(base: base, timeout: 90)
        XCTAssertNil(state["error"] as? String)

        let exchanges = state["exchanges"] as? [[String: Any]] ?? []
        XCTAssertEqual(exchanges.map { $0["method"] as? String },
                       ["eth_requestAccounts", "wallet_switchEthereumChain", "personal_sign"])

        let accounts = (exchanges.first?["response"] as? [String: Any])?["result"] as? [String]
        XCTAssertEqual(accounts?.first?.lowercased(), hardhatAccount0)

        // Recover the recorded signature — must be the vault account.
        let signPayload = exchanges.last?["response"] as? [String: Any]
        let signatureHex = try XCTUnwrap(signPayload?["result"] as? String)
        let sigBytes = try XCTUnwrap(signatureHex.web3.hexData)
        let message = Data("freedom openlv ios harness".utf8)
        var prefixed = Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8)
        prefixed.append(message)
        let recovered = try KeyUtil.recoverPublicKey(message: prefixed.web3.keccak256, signature: sigBytes)
        XCTAssertEqual(recovered.lowercased(), hardhatAccount0)
    }

    /// The wallet endpoint builds the ENTIRE transaction itself — nonce
    /// from its tracker, gas from its oracle, legacy EIP-155 signature,
    /// broadcast through its own RPC pool. This runs that path against a
    /// local anvil (chain-id 100, prefunded hardhat accounts) and
    /// asserts the transaction actually MINES — separating "signed and
    /// broadcast without error" from "constructed something the chain
    /// accepts". Needs anvil; scripts/openlv-e2e.sh starts it.
    func testTransactionBroadcastMinesOnLocalChain() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["OPENLV_HARNESS_URL"] else {
            throw XCTSkip("OPENLV_HARNESS_URL not set — run scripts/openlv-e2e.sh")
        }
        guard let anvil = env["OPENLV_ANVIL_URL"], !anvil.isEmpty else {
            throw XCTSkip("OPENLV_ANVIL_URL not set — anvil unavailable")
        }

        let savedChainID = UserDefaults.standard.integer(forKey: WalletDefaults.activeChainID)
        let vaultService = "com.freedom.wallet.test.\(UUID().uuidString)"
        let vault = Vault(crypto: VaultCrypto(service: vaultService, preferred: .deviceBound))
        try await vault.create(mnemonic: Mnemonic(phrase: hardhatMnemonic))

        let bundle = try ChainStackBundle()
        // Point the wallet's Gnosis RPCs at anvil — nonce fetch, gas
        // price, estimation, and the broadcast all go through this pool.
        bundle.chainStore.updateRPCURLs(forChainID: Chain.defaultChain.id, [anvil])

        let (services, containers) = try makeWalletServices(vault: vault, bundle: bundle)
        _ = containers
        let chainStore = bundle.chainStore
        let session = OpenLVWalletSession(
            services: services,
            activeChain: { chainStore.chain(id: Chain.defaultChain.id) ?? Chain.defaultChain }
        )
        defer {
            session.stop()
            UserDefaults.standard.set(savedChainID, forKey: WalletDefaults.activeChainID)
            try? VaultCrypto(service: vaultService).wipe()
        }

        let approver = Task { @MainActor in
            while !Task.isCancelled {
                if session.pendingApproval != nil {
                    session.resolvePendingApproval(.approved)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { approver.cancel() }

        let uri = try await fetchURI(base: base, mode: "tx")
        try await session.start(uri: uri)

        let state = try await pollUntilDone(base: base, timeout: 90)
        XCTAssertNil(state["error"] as? String)

        let exchanges = state["exchanges"] as? [[String: Any]] ?? []
        XCTAssertEqual(exchanges.map { $0["method"] as? String },
                       ["eth_requestAccounts", "wallet_switchEthereumChain", "eth_sendTransaction"])

        let txPayload = exchanges.last?["response"] as? [String: Any]
        let hash = try XCTUnwrap(txPayload?["result"] as? String,
                                 "no tx hash — response was \(String(describing: txPayload))")
        XCTAssertEqual(hash.count, 66)

        // The decisive part: the receipt must exist and be successful.
        let receipt = try await pollReceipt(anvil: anvil, hash: hash, timeout: 30)
        XCTAssertEqual(receipt["status"] as? String, "0x1", "tx mined but reverted")
        XCTAssertNotNil(receipt["blockNumber"])
    }

    private func pollReceipt(
        anvil: String, hash: String, timeout: TimeInterval
    ) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: anvil))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1,
                "method": "eth_getTransactionReceipt", "params": [hash],
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let receipt = envelope?["result"] as? [String: Any] {
                return receipt
            }
            if Date() > deadline {
                XCTFail("tx \(hash) never got a receipt — not mined")
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Harness control surface

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Each test consumes one host session; `/reset` reloads the host
    /// page, and the fresh session's URI appears shortly after. `mode`
    /// picks the request sequence the host sends (nil: personal_sign;
    /// "tx": eth_sendTransaction).
    private func fetchURI(base: String, mode: String? = nil) async throws -> String {
        let reset = mode.map { "\(base)/reset?mode=\($0)" } ?? "\(base)/reset"
        _ = try? await fetchJSON(XCTUnwrap(URL(string: reset)))
        let url = try XCTUnwrap(URL(string: "\(base)/uri"))
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let uri = (try? await fetchJSON(url))?["uri"] as? String { return uri }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        // The harness is up (env var set) but broken — that's a failure,
        // not a skip.
        XCTFail("harness never produced a session URI after reset")
        throw CancellationError()
    }

    private func pollUntilDone(base: String, timeout: TimeInterval) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: "\(base)/state"))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let state = try await fetchJSON(url)
            let phase = state["phase"] as? String
            if phase == "done" || phase == "error" { return state }
            if Date() > deadline {
                XCTFail("harness never reached done; last state: \(state)")
                return state
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
