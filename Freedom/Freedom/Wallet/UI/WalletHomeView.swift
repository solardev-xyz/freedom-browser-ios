import BigInt
import SwiftData
import SwiftUI
import web3

@MainActor
struct WalletHomeView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(PermissionStore.self) private var permissions
    @Environment(ENSResolver.self) private var ensResolver
    @Environment(TabStore.self) private var tabStore

    @AppStorage(WalletDefaults.activeChainID) private var activeChainID: Int = Chain.defaultChain.id

    // SwiftData refreshes on `context.save()`, so the card auto-hides if
    // the dapp revokes from its own UI while the wallet sheet is open.
    @Query(sort: \DappPermission.lastUsedAt, order: .reverse)
    private var grants: [DappPermission]

    @Query private var autoApproveRules: [AutoApproveRule]

    /// O(rules) once per body eval beats O(rules) per visible site row.
    private var originsWithAutoApproveRules: Set<String> {
        Set(autoApproveRules.map(\.origin))
    }

    private var activeOrigin: OriginIdentity? {
        guard let url = tabStore.activeTab?.displayURL,
              let identity = OriginIdentity.from(displayURL: url),
              identity.isEligibleForWallet else { return nil }
        return identity
    }

    /// Filtering the in-memory `grants` array (bounded by a handful of
    /// dapps) instead of running a scoped fetch — `@Query` predicates can't
    /// reference runtime state, and this keeps SwiftData reactivity intact.
    private var activeTabGrant: DappPermission? {
        guard let key = activeOrigin?.key else { return nil }
        return grants.first { $0.origin == key }
    }

    @State private var address: String?
    @State private var primaryName: String?
    @State private var assetsState: AssetsState = .loading
    @State private var balanceRefreshGeneration: Int = 0

    private struct AssetEntry: Equatable {
        let token: Token
        let balance: BigUInt
    }

    private enum AssetsState: Equatable {
        case loading
        case loaded([AssetEntry])
        case failed
    }

    private var activeChain: Chain {
        Chain.find(id: activeChainID) ?? .defaultChain
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let address {
                    VStack(alignment: .leading, spacing: 4) {
                        if let primaryName {
                            Text(primaryName)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 4)
                        }
                        AddressPill(address: address)
                    }
                }
                chainPicker
                assetsCard
                sendReceiveButtons
                activeTabSiteCard
            }
            .padding(20)
        }
        // `.task(id:)` auto-cancels the previous run on chain change and on
        // view disappearance — no manual Task handle needed, no stale
        // `balance = .loaded(...)` clobbering after the user swipes away.
        // No `.refreshable` here: pull-to-refresh inside an iOS sheet has a
        // gesture-arbiter conflict with drag-to-dismiss that cancels the
        // refresh task. Refresh is button-driven instead (see balanceCard).
        .task(id: activeChainID) {
            await refreshAssets()
        }
        // Re-runs whenever the address changes (vault create / wipe / import) —
        // can't dedup by `primaryName != nil` because that's stale across rotations.
        .task(id: address) {
            guard let address else { return }
            primaryName = try? await ensResolver.reverseResolve(
                address: EthereumAddress(address)
            )
        }
    }

    private var sendReceiveButtons: some View {
        HStack(spacing: 12) {
            NavigationLink {
                SendFlowView(chain: activeChain)
            } label: {
                Label("Send", systemImage: "arrow.up.right")
            }
            .buttonStyle(PrimaryActionStyle())
            NavigationLink {
                ReceiveView()
            } label: {
                Label("Receive", systemImage: "arrow.down.left")
            }
            .buttonStyle(PrimaryActionStyle())
        }
    }

    private var chainPicker: some View {
        // Custom Binding routes the write through `WalletDefaults.setActiveChainID`
        // so the notification posts from one place — same code path as the
        // bridge's `wallet_switchEthereumChain` handler.
        let binding = Binding(
            get: { activeChainID },
            set: { WalletDefaults.setActiveChainID($0) }
        )
        return Picker("Chain", selection: binding) {
            ForEach(Chain.all) { chain in
                Text(chain.displayName).tag(chain.id)
            }
        }
        .pickerStyle(.segmented)
    }

    private var assetsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Assets").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refreshAssets() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(assetsState == .loading)
                .accessibilityLabel("Refresh balances")
            }
            assetsCardBody
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var assetsCardBody: some View {
        switch assetsState {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
        case .failed:
            Label("Couldn't load balances.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .loaded(let entries):
            if entries.isEmpty {
                Text("No assets on \(activeChain.displayName).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.token.id) { index, entry in
                        NavigationLink {
                            SendFlowView(chain: activeChain, asset: entry.token)
                        } label: {
                            AssetRow(token: entry.token, balance: entry.balance)
                        }
                        .buttonStyle(.plain)
                        if index < entries.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var activeTabSiteCard: some View {
        if let origin = activeOrigin, let grant = activeTabGrant {
            let host = tabStore.activeTab?.displayURL?.host
            VStack(alignment: .leading, spacing: 8) {
                Text("This site").font(.caption).foregroundStyle(.secondary)
                NavigationLink {
                    ConnectedSiteDetailView(origin: origin, host: host, grant: grant)
                } label: {
                    siteCardRow(origin: origin, host: host)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func siteCardRow(origin: OriginIdentity, host: String?) -> some View {
        HStack(spacing: 12) {
            FaviconView(host: host, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(origin.displayString)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Connected").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if originsWithAutoApproveRules.contains(origin.key) {
                Text("auto")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func refreshAssets() async {
        let addressString: String
        do {
            addressString = try vault.signingKey(at: .mainUser).ethereumAddress
        } catch {
            // Derivation only throws if the seed is gone (lock mid-view).
            assetsState = .failed
            return
        }
        // Snapshot chain so a mid-flight switch doesn't mis-format the
        // result against the new chain's tokens; generation token
        // discards stale terminal writes.
        balanceRefreshGeneration += 1
        let generation = balanceRefreshGeneration
        let chain = activeChain

        self.address = addressString
        assetsState = .loading
        let fetcher = TokenBalanceFetcher(walletRPC: chains.walletRPC)
        let tokens = TokenRegistry.tokens(for: chain)
        let result = await fetcher.fetch(
            holder: EthereumAddress(addressString),
            chain: chain,
            tokens: tokens
        )
        guard generation == balanceRefreshGeneration else { return }
        // Preserve the registry's declared order (native first); skip
        // missing entries (call failed) and zero balances per the
        // "empty wallet stays empty" UI rule.
        let entries: [AssetEntry] = tokens.compactMap { token in
            guard let balance = result[token], balance > 0 else { return nil }
            return AssetEntry(token: token, balance: balance)
        }
        assetsState = .loaded(entries)
    }

}
