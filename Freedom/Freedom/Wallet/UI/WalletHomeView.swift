import BigInt
import SwiftData
import SwiftUI
import web3

@MainActor
struct WalletHomeView: View {
    @Environment(Vault.self) private var vault
    @Environment(ChainRegistry.self) private var chains
    @Environment(ChainStore.self) private var chainStore
    @Environment(PermissionStore.self) private var permissions
    @Environment(ENSResolver.self) private var ensResolver
    @Environment(TabStore.self) private var tabStore
    @Environment(OpenLVWalletSession.self) private var openlvSession
    @Environment(WalletTransactionHistoryStore.self) private var txHistory
    @Environment(WalletBalanceStore.self) private var balances

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

    @Environment(UserWalletStore.self) private var wallets
    @State private var address: String?
    @State private var primaryName: ENSReverseResolution = .none
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
        chainStore.chain(id: activeChainID) ?? Chain.defaultChain
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                walletRow
                if let address {
                    VStack(alignment: .leading, spacing: 4) {
                        ENSNameLabel(resolution: primaryName)
                        AddressPill(address: address)
                    }
                }
                chainPicker
                assetsCard
                sendReceiveButtons
                activityRow
                connectBrowserRow
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
        .task(id: "\(activeChainID)/\(wallets.activeIndex)") {
            await refreshAssets(force: false)
        }
        // Re-runs whenever the address changes (vault create / wipe / import) —
        // can't dedup by `primaryName != .none` because that's stale across rotations.
        .task(id: address) {
            guard let address else { return }
            primaryName = (try? await ensResolver.reverseResolve(
                address: EthereumAddress(address)
            )) ?? .none
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

    /// Desktop's payment history: every transaction this wallet
    /// broadcast, with its status.
    private var activityRow: some View {
        NavigationLink {
            WalletActivityView()
        } label: {
            HStack {
                Label("Activity", systemImage: "clock.arrow.circlepath")
                Spacer()
                if txHistory.pendingCount > 0 {
                    Text("\(txHistory.pendingCount) pending")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let latest = txHistory.entries.first {
                    Text(SwarmPublishHistoryFormatting.relativeTime(latest.createdAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Openlv remote signing: scan the desktop browser's QR and approve
    /// its requests here. Shows live status once a session is up.
    private var connectBrowserRow: some View {
        NavigationLink {
            ConnectBrowserView()
        } label: {
            HStack {
                Label("Scan from Freedom desktop", systemImage: "qrcode.viewfinder")
                Spacer()
                if openlvSession.isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// Which wallet the app acts as (desktop "multiple accounts"): the
    /// Send screen's asset-picker shape — a row that pushes the list.
    private var walletRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wallet").font(.caption).foregroundStyle(.secondary)
            NavigationLink {
                WalletsListView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: wallets.activeWallet.isMain ? "wallet.bifold.fill" : "wallet.bifold")
                        .font(.title3)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallets.activeWallet.name).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        Text(wallets.visibleWallets.count == 1 ? "Tap to add another wallet" : "\(wallets.visibleWallets.count) wallets")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wallet: \(wallets.activeWallet.name)")
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
            ForEach(chainStore.allChains()) { chain in
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
                    Task { await refreshAssets(force: true) }
                } label: {
                    if balances.isRefreshing(activeChain) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(balances.isRefreshing(activeChain))
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

    /// Cached balances show at once; the network refresh is silent
    /// unless nothing is cached yet. `force` skips the store's
    /// minimum-interval reuse (the refresh button).
    private func refreshAssets(force: Bool) async {
        let addressString: String
        do {
            addressString = try vault.signingKey(at: vault.activeWalletPath).ethereumAddress
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
        let tokens = TokenRegistry.tokens(for: chain)

        self.address = addressString
        if balances.holder == addressString, let cached = balances.balances(on: chain) {
            assetsState = .loaded(Self.entries(from: cached, tokens: tokens))
        } else {
            assetsState = .loading
        }
        let result = await balances.refresh(
            holder: addressString, chain: chain, tokens: tokens, minInterval: force ? 0 : WalletBalanceStore.defaultMinInterval
        )
        guard generation == balanceRefreshGeneration else { return }
        if let result {
            assetsState = .loaded(Self.entries(from: result, tokens: tokens))
        } else if case .loading = assetsState {
            assetsState = .failed
        }
    }

    /// Preserve the registry's declared order (native first); skip
    /// missing entries (call failed) and zero balances per the
    /// "empty wallet stays empty" UI rule.
    private static func entries(from result: [Token: BigUInt], tokens: [Token]) -> [AssetEntry] {
        tokens.compactMap { token in
            guard let balance = result[token], balance > 0 else { return nil }
            return AssetEntry(token: token, balance: balance)
        }
    }

}
