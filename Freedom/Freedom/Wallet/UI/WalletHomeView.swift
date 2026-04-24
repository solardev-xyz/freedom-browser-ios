import SwiftData
import SwiftUI

@MainActor
struct WalletHomeView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(PermissionStore.self) private var permissions

    @AppStorage(WalletDefaults.activeChainID) private var activeChainID: Int = Chain.defaultChain.id

    // Live dapp grants — SwiftData refreshes on every `context.save()` that
    // grant/revoke perform, so the row list stays in sync without manual
    // invalidation.
    @Query(sort: \DappPermission.lastUsedAt, order: .reverse)
    private var grants: [DappPermission]

    @State private var address: String?
    @State private var balance: BalanceState = .loading
    @State private var revealedPhrase: [String]?
    @State private var revealError: String?

    private enum BalanceState: Equatable {
        case loading
        case loaded(String)
        case failed
    }

    private var activeChain: Chain {
        Chain.find(id: activeChainID) ?? .defaultChain
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let level = vault.securityLevel {
                    SecurityLevelBadge(level: level)
                }
                if let address {
                    AddressPill(address: address)
                }
                chainPicker
                balanceCard
                NavigationLink {
                    SendFlowView()
                } label: {
                    Label("Send", systemImage: "arrow.up.right")
                }
                .buttonStyle(PrimaryActionStyle())
                Button("Lock wallet") { vault.lock() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                connectedSitesSection
                advancedSection
            }
            .padding(20)
        }
        .refreshable { await refreshBalance() }
        // `.task(id:)` auto-cancels the previous run on chain change and on
        // view disappearance — no manual Task handle needed, no stale
        // `balance = .loaded(...)` clobbering after the user swipes away.
        .task(id: activeChainID) {
            await refreshBalance()
        }
        .navigationDestination(item: $revealedPhrase) { words in
            RecoveryPhraseView(words: words)
        }
    }

    private var chainPicker: some View {
        Picker("Chain", selection: $activeChainID) {
            ForEach(Chain.all) { chain in
                Text(chain.displayName).tag(chain.id)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: activeChainID) { _, new in
            NotificationCenter.default.post(
                name: .walletActiveChainChanged,
                object: nil,
                userInfo: ["chainID": new]
            )
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Balance").font(.caption).foregroundStyle(.secondary)
            switch balance {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            case .loaded(let display):
                Text(display)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
            case .failed:
                Label("Couldn't load balance. Pull to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var connectedSitesSection: some View {
        if !grants.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connected sites").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(grants.enumerated()), id: \.element.id) { index, grant in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.origin)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(grant.account)
                                    .font(.caption2)
                                    .monospaced()
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                permissions.revoke(origin: grant.origin)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        if index < grants.count - 1 {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var advancedSection: some View {
        WalletAdvancedSection {
            Button {
                Task { await revealPhrase() }
            } label: {
                Label("Show recovery phrase", systemImage: "key.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            if let revealError {
                Text(revealError).font(.caption).foregroundStyle(.red)
            }
            WipeWalletButton()
        }
    }

    private func refreshBalance() async {
        let address: String
        do {
            address = try vault.signingKey(at: .mainUser).ethereumAddress
        } catch {
            // Derivation only throws if the seed is gone (lock mid-view).
            balance = .failed
            return
        }
        self.address = address
        balance = .loading
        do {
            let hex = try await chains.walletRPC.balance(of: address, on: activeChain)
            if Task.isCancelled { return }
            balance = .loaded(BalanceFormatter.format(weiHex: hex, on: activeChain))
        } catch {
            if Task.isCancelled { return }
            balance = .failed
        }
    }

    private func revealPhrase() async {
        revealError = nil
        do {
            let mnemonic = try await vault.revealMnemonic()
            revealedPhrase = mnemonic.words
        } catch {
            revealError = error.localizedDescription
        }
    }
}
