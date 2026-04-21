import SwiftUI
import SwiftData
import SwarmKit

@main
struct FreedomApp: App {
    @State private var swarm = SwarmNode()
    @State private var tabStore: TabStore
    private let modelContainer: ModelContainer

    init() {
        do {
            let container = try ModelContainer(for: TabRecord.self)
            self.modelContainer = container
            self._tabStore = State(wrappedValue: TabStore(context: container.mainContext))
        } catch {
            fatalError("Failed to create SwiftData ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(swarm)
                .environment(tabStore)
                .modelContainer(modelContainer)
                .task { await startNodeIfNeeded() }
        }
    }

    private func startNodeIfNeeded() async {
        guard swarm.status == .idle else { return }
        let fresh = await BootnodeResolver.resolveMainnet()
        let bootnodes = fresh.isEmpty ? SwarmConfig.defaultBootnodes : fresh
        swarm.start(.init(
            dataDir: SwarmNode.defaultDataDir(),
            password: "freedom-default",  // TODO: Keychain in M4
            bootnodes: bootnodes.joined(separator: "|")
        ))
    }
}
