import BigInt
import SwiftData
import web3
import XCTest
@testable import Freedom

/// The openlv wallet-endpoint coordinator, driven without an engine:
/// requests go straight into `handleRequest`, approvals are resolved
/// programmatically (standing in for the sheets), and signatures are
/// verified by recovery — the same check the desktop's remote signer
/// runs on its side of the wire.
@MainActor
final class OpenLVWalletSessionTests: XCTestCase {
    private let account0 = hardhatAccount0
    private let stranger = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

    private var bundle: ChainStackBundle!
    private var containers: [ModelContainer] = []
    private var vaultService = ""
    private var vault: Vault!
    private var session: OpenLVWalletSession!
    private var savedChainID: Int = 0

    @MainActor
    private final class FakeEngine: OpenLVSessionEngine {
        var requestHandler: ((String, [Any]) async -> OpenLVResponse)?
        var statusHandler: ((OpenLVEngineStatus) -> Void)?
        private(set) var startedURIs: [String] = []
        private(set) var stopCount = 0
        func start(uri: String) async throws { startedURIs.append(uri) }
        func stop() { stopCount += 1 }
    }

    private var engine: FakeEngine!

    override func setUp() async throws {
        bundle = try ChainStackBundle()
        savedChainID = UserDefaults.standard.integer(forKey: WalletDefaults.activeChainID)

        vaultService = "com.freedom.wallet.test.\(UUID().uuidString)"
        vault = Vault(crypto: VaultCrypto(service: vaultService, preferred: .deviceBound))
        try await vault.create(mnemonic: Mnemonic(phrase: hardhatMnemonic))

        let (services, serviceContainers) = try makeWalletServices(vault: vault, bundle: bundle)
        containers = serviceContainers
        engine = FakeEngine()
        let chainStore = bundle.chainStore
        session = OpenLVWalletSession(
            services: services,
            activeChain: { WalletDefaults.activeChain(in: chainStore) },
            engineFactory: { [unowned self] in self.engine }
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedChainID, forKey: WalletDefaults.activeChainID)
        try VaultCrypto(service: vaultService).wipe()
        session = nil
        containers = []
        bundle = nil
    }

    // MARK: - Envelope helpers

    private func result(of response: OpenLVResponse) -> Any? {
        if case .result(let value) = response { return value }
        return nil
    }

    private func errorCode(of response: OpenLVResponse) -> Int? {
        if case .error(let code, _) = response { return code }
        return nil
    }

    /// Fires the request, waits for the approval to park, resolves it,
    /// and returns the response. Optionally inspects the parked kind.
    private func request(
        _ method: String,
        _ params: [Any],
        deciding decision: ApprovalRequest.Decision,
        inspect: ((ApprovalRequest.Kind) -> Void)? = nil
    ) async -> OpenLVResponse {
        async let responseTask = session.handleRequest(method: method, params: params)
        let deadline = Date().addingTimeInterval(5)
        while session.pendingApproval == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let pending = session.pendingApproval else {
            XCTFail("request \(method) never parked an approval")
            return await responseTask
        }
        XCTAssertEqual(pending.origin.scheme, .openlv)
        inspect?(pending.kind)
        session.resolvePendingApproval(decision)
        return await responseTask
    }

    // MARK: - Ungated reads

    func testChainIdAnswersWithoutApproval() async {
        let response = await session.handleRequest(method: "eth_chainId", params: [])
        XCTAssertEqual(result(of: response) as? String, Chain.defaultChain.hexChainID)
        XCTAssertNil(session.pendingApproval)
    }

    func testAccountsAreEmptyBeforeConnect() async {
        let response = await session.handleRequest(method: "eth_accounts", params: [])
        XCTAssertEqual(result(of: response) as? [String], [])
    }

    func testUnknownMethodIsRefused() async {
        let response = await session.handleRequest(method: "eth_getBalance", params: [])
        XCTAssertEqual(errorCode(of: response), 4200)
    }

    func testAddEthereumChainIsRefused() async {
        let response = await session.handleRequest(method: "wallet_addEthereumChain", params: [])
        XCTAssertEqual(errorCode(of: response), 4200)
    }

    // MARK: - Connect

    func testRequestAccountsApprovedReturnsVaultAccount() async {
        var kind: ApprovalRequest.Kind?
        let response = await request("eth_requestAccounts", [], deciding: .approved) { kind = $0 }
        guard case .connect = kind else { return XCTFail("expected .connect sheet") }

        let accounts = result(of: response) as? [String]
        XCTAssertEqual(accounts?.first?.lowercased(), account0)

        // The grant answers eth_accounts (and repeat connects) for the
        // rest of the session without another sheet.
        let again = await session.handleRequest(method: "eth_accounts", params: [])
        XCTAssertEqual((result(of: again) as? [String])?.first?.lowercased(), account0)
        let repeatConnect = await session.handleRequest(method: "eth_requestAccounts", params: [])
        XCTAssertNotNil(result(of: repeatConnect))
        XCTAssertNil(session.pendingApproval)
    }

    func testRequestAccountsDeniedReturns4001() async {
        let response = await request("eth_requestAccounts", [], deciding: .denied)
        XCTAssertEqual(errorCode(of: response), 4001)
        let accounts = await session.handleRequest(method: "eth_accounts", params: [])
        XCTAssertEqual(result(of: accounts) as? [String], [])
    }

    // MARK: - personal_sign

    private var messageHex: String {
        "0x" + Data("freedom openlv session test".utf8).hexString
    }

    func testPersonalSignApprovedRecoversToVaultAccount() async throws {
        let response = await request("personal_sign", [messageHex, account0], deciding: .approved) { kind in
            guard case .personalSign = kind else { return XCTFail("expected .personalSign sheet") }
        }

        let signatureHex = try XCTUnwrap(result(of: response) as? String)
        let sigBytes = try XCTUnwrap(signatureHex.web3.hexData)
        XCTAssertEqual(sigBytes.count, 65)

        let message = Data("freedom openlv session test".utf8)
        let prefix = "\u{19}Ethereum Signed Message:\n\(message.count)"
        var prefixed = Data(prefix.utf8)
        prefixed.append(message)
        let recovered = try KeyUtil.recoverPublicKey(message: prefixed.web3.keccak256, signature: sigBytes)
        XCTAssertEqual(recovered.lowercased(), account0)
    }

    func testPersonalSignForForeignAccountFailsAfterApproval() async {
        let response = await request("personal_sign", [messageHex, stranger], deciding: .approved)
        XCTAssertEqual(errorCode(of: response), -32602)
    }

    func testPersonalSignDeniedReturns4001() async {
        let response = await request("personal_sign", [messageHex, account0], deciding: .denied)
        XCTAssertEqual(errorCode(of: response), 4001)
    }

    func testPersonalSignWithGarbageParamsFailsWithoutSheet() async {
        let response = await session.handleRequest(method: "personal_sign", params: [42])
        XCTAssertEqual(errorCode(of: response), -32602)
        XCTAssertNil(session.pendingApproval)
    }

    // MARK: - eth_signTypedData_v4

    private var typedDataJSON: String {
        """
        {"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"chainId","type":"uint256"}],
        "Payment":[{"name":"to","type":"address"},{"name":"amount","type":"uint256"}]},
        "primaryType":"Payment",
        "domain":{"name":"Freedom Test","chainId":100},
        "message":{"to":"\(stranger)","amount":"1000"}}
        """
    }

    func testTypedDataApprovedReturnsSignature() async throws {
        let response = await request("eth_signTypedData_v4", [account0, typedDataJSON], deciding: .approved) { kind in
            guard case .typedData = kind else { return XCTFail("expected .typedData sheet") }
        }
        let signatureHex = try XCTUnwrap(result(of: response) as? String)
        XCTAssertEqual(signatureHex.web3.hexData?.count, 65)
    }

    func testTypedDataForForeignAccountFailsAfterApproval() async {
        let response = await request("eth_signTypedData_v4", [stranger, typedDataJSON], deciding: .approved)
        XCTAssertEqual(errorCode(of: response), -32602)
    }

    func testTypedDataWithInvalidPayloadFailsWithoutSheet() async {
        let response = await session.handleRequest(
            method: "eth_signTypedData_v4", params: [account0, "not json"]
        )
        XCTAssertEqual(errorCode(of: response), -32602)
        XCTAssertNil(session.pendingApproval)
    }

    // MARK: - wallet_switchEthereumChain

    func testSwitchToCurrentChainIsSilentNull() async {
        let response = await session.handleRequest(
            method: "wallet_switchEthereumChain",
            params: [["chainId": Chain.defaultChain.hexChainID]]
        )
        XCTAssertTrue(result(of: response) is NSNull)
        XCTAssertNil(session.pendingApproval)
    }

    func testSwitchToUnknownChainReturns4902WithoutSheet() async {
        let response = await session.handleRequest(
            method: "wallet_switchEthereumChain",
            params: [["chainId": "0x539"]]
        )
        XCTAssertEqual(errorCode(of: response), 4902)
        XCTAssertNil(session.pendingApproval)
    }

    func testSwitchToKnownChainApprovedUpdatesActiveChain() async {
        let response = await request(
            "wallet_switchEthereumChain",
            [["chainId": "0x1"]],
            deciding: .approved
        ) { kind in
            guard case .switchChain(let details) = kind else { return XCTFail("expected .switchChain sheet") }
            XCTAssertEqual(details.to.id, 1)
        }
        XCTAssertTrue(result(of: response) is NSNull)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: WalletDefaults.activeChainID), 1)

        let chainId = await session.handleRequest(method: "eth_chainId", params: [])
        XCTAssertEqual(result(of: chainId) as? String, "0x1")
    }

    // MARK: - eth_sendTransaction (offline paths — broadcast is E2E territory)

    private var fullyQuotedTx: [String: Any] {
        [
            "from": account0,
            "to": stranger,
            "value": "0x38d7ea4c68000",
            "chainId": Chain.defaultChain.hexChainID,
            "nonce": "0x0",
            "gasPrice": "0x3b9aca00",
            "gas": "0x5208",
        ]
    }

    func testSendTransactionDeniedReturns4001() async {
        let response = await request("eth_sendTransaction", [fullyQuotedTx], deciding: .denied) { kind in
            guard case .sendTransaction(let details) = kind else { return XCTFail("expected .sendTransaction sheet") }
            XCTAssertEqual(details.valueWei, BigUInt(1_000_000_000_000_000))
        }
        XCTAssertEqual(errorCode(of: response), 4001)
    }

    func testSendTransactionForForeignAccountFailsAfterApproval() async {
        var tx = fullyQuotedTx
        tx["from"] = stranger
        let response = await request("eth_sendTransaction", [tx], deciding: .approved)
        XCTAssertEqual(errorCode(of: response), -32602)
    }

    func testSendTransactionOnWrongChainFailsWithoutSheet() async {
        var tx = fullyQuotedTx
        tx["chainId"] = "0x1"
        let response = await session.handleRequest(method: "eth_sendTransaction", params: [tx])
        XCTAssertEqual(errorCode(of: response), -32602)
        XCTAssertNil(session.pendingApproval)
    }

    // MARK: - Approval serialization + lifecycle

    func testSecondRequestWhileApprovalPendingIsUnavailable() async {
        async let first = session.handleRequest(method: "eth_requestAccounts", params: [])
        let deadline = Date().addingTimeInterval(5)
        while session.pendingApproval == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let second = await session.handleRequest(method: "personal_sign", params: [messageHex, account0])
        XCTAssertEqual(errorCode(of: second), -32002)

        session.resolvePendingApproval(.denied)
        _ = await first
    }

    func testStopDeniesParkedApproval() async throws {
        try await session.start(uri: "openlv://fake@1?h=00&k=00&p=mqtt&s=x")
        async let response = session.handleRequest(method: "eth_requestAccounts", params: [])
        let deadline = Date().addingTimeInterval(5)
        while session.pendingApproval == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        session.stop()
        let resolved = await response
        XCTAssertEqual(errorCode(of: resolved), 4001)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(session.status, .idle)
    }

    func testStartWiresEngineAndTracksStatus() async throws {
        try await session.start(uri: "openlv://fake@1?h=00&k=00&p=mqtt&s=x")
        XCTAssertEqual(engine.startedURIs.count, 1)
        XCTAssertEqual(session.status, .connecting)

        engine.statusHandler?(.connected)
        XCTAssertEqual(session.status, .connected)
        XCTAssertTrue(session.isActive)

        engine.statusHandler?(.disconnected)
        XCTAssertEqual(session.status, .disconnected)
        XCTAssertFalse(session.isActive)

        // Requests flow through the wired handler.
        let response = await engine.requestHandler?("eth_chainId", [])
        XCTAssertNotNil(response)
    }

    // MARK: - URI extraction

    func testExtractsRawAndBridgeURIs() {
        XCTAssertEqual(
            OpenLVWalletSession.extractOpenLVURI(from: " openlv://abc@1?p=mqtt "),
            "openlv://abc@1?p=mqtt"
        )
        XCTAssertEqual(
            OpenLVWalletSession.extractOpenLVURI(
                from: "https://freedom.florianglatz.eth.limo/#openlv://abc@1?h=x&s=wss%3A%2F%2Fbroker%2Fmqtt"
            ),
            "openlv://abc@1?h=x&s=wss://broker/mqtt"
        )
        XCTAssertNil(OpenLVWalletSession.extractOpenLVURI(from: "https://example.com/#not-a-session"))
        XCTAssertNil(OpenLVWalletSession.extractOpenLVURI(from: "hello"))
    }
}
