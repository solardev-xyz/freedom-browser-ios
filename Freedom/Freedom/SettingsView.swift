import SwiftUI

/// Top-level settings hub. iOS Settings-style: tap a row to drill into
/// a per-section page. Done invalidates the resolver cache + pool
/// quarantine so any setting changes (RPC URLs, quorum config, CCIP
/// toggle) take effect on the next navigation.
struct SettingsView: View {
    @Environment(ENSResolver.self) private var resolver
    @Environment(ChainRegistry.self) private var chainRegistry
    @Environment(ChainStore.self) private var chainStore
    @Environment(\.dismiss) private var dismiss

    /// Single typed path that backs every settings sub-page push.
    /// Going entirely value-based avoids the SwiftUI mixed-model
    /// bounce where a value-push from inside a destination-pushed
    /// view forces the visible stack to re-sync.
    @State private var path: [SettingsPath] = []
    /// Desktop "Search settings": a non-empty query replaces the hub
    /// with every matching control, grouped by section; tapping a
    /// result opens its page. The query stays, so Back returns here.
    @State private var query = ""
    /// Applied one tick after the stack appears: a multi-level path set
    /// before the destinations are registered is dropped by SwiftUI.
    private let initialPath: [SettingsPath]
    /// A query to start with (the `FREEDOM_DEBUG_SETTINGS=find:<q>` hook).
    private let initialQuery: String

    init(initialPath: [SettingsPath] = [], initialQuery: String = "") {
        self.initialPath = initialPath
        self.initialQuery = initialQuery
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if isSearching {
                    searchResults
                } else {
                NavigationLink(value: SettingsPath.wallet) {
                    Label("Wallet", systemImage: "wallet.bifold.fill")
                }
                NavigationLink(value: SettingsPath.ens) {
                    Label("Name Resolution", systemImage: "globe")
                }
                NavigationLink(value: SettingsPath.swarm) {
                    Label("Swarm", systemImage: "circle.hexagongrid.fill")
                }
                NavigationLink(value: SettingsPath.ipfs) {
                    Label("IPFS", systemImage: "globe.asia.australia")
                }
                NavigationLink(value: SettingsPath.myotis) {
                    Label("Light Client", systemImage: "bolt.shield.fill")
                }
                NavigationLink(value: SettingsPath.rpc) {
                    Label("Chains", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink(value: SettingsPath.adblock) {
                    Label("Ad Blocking", systemImage: "shield.lefthalf.filled")
                }
                NavigationLink(value: SettingsPath.search) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                NavigationLink(value: SettingsPath.sitePermissions) {
                    Label("Site Permissions", systemImage: "hand.raised.fill")
                }
                Section {
                    NavigationLink(value: SettingsPath.about) {
                        Label("About", systemImage: "info.circle")
                    }
                }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search settings")
            .overlay {
                if isSearching, searchGroups.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { finish() }
                }
            }
            .navigationDestination(for: SettingsPath.self) { route in
                destination(for: route)
            }
        }
        .environment(\.settingsPath, $path)
        .task {
            if !initialQuery.isEmpty, query.isEmpty { query = initialQuery }
            guard !initialPath.isEmpty, path.isEmpty else { return }
            await Task.yield()
            path = initialPath
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var searchGroups: [(section: String, entries: [SettingsSearchEntry])] {
        SettingsSearchIndex.grouped(query, in: SettingsSearchIndex.entries(chains: chainStore.allChains()))
    }

    @ViewBuilder
    private var searchResults: some View {
        ForEach(searchGroups, id: \.section) { group in
            Section(group.section) {
                ForEach(group.entries) { entry in
                    Button {
                        path = entry.path
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                if let detail = entry.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for route: SettingsPath) -> some View {
        switch route {
        case .wallet:
            WalletSettingsView()
        case .ens:
            ENSSettingsView()
        case .swarm:
            SwarmSettingsView()
        case .ipfs:
            IPFSSettingsView()
        case .myotis:
            MyotisSettingsView()
        case .rpc:
            RPCSettingsView()
        case .adblock:
            AdblockSettingsView()
        case .search:
            SearchSettingsView()
        case .sitePermissions:
            SitePermissionsSettingsView()
        case .about:
            AboutView()
        case .licenses:
            LicensesView()
        case .license(let id):
            LicenseDetailView(id: id)
        case .chainEditor(let id):
            if let chain = chainStore.chain(id: id) {
                ChainDetailView(chain: chain, chainStore: chainStore)
            }
        case .chainSource(let id, let source):
            if let chain = chainStore.chain(id: id) {
                ChainSourceDetailView(chain: chain, source: source)
            }
        case .ensMethod(let method):
            ENSMethodDetailView(method: method)
        case .chainlistSearch:
            ChainlistSearchView()
        case .addChainForm(let prefill):
            AddChainForm(prefill: prefill)
        }
    }

    private func finish() {
        resolver.invalidate()
        // Drop quarantine + shuffle on every per-chain pool so a URL the
        // user just edited / re-added is reconsidered on the next request.
        chainRegistry.invalidateAllPools()
        dismiss()
    }
}
