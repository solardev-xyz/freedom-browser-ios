import SwiftUI
import SwarmKit

@main
struct FreedomApp: App {
    @State private var swarm = SwarmNode()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(swarm)
                .task { await startNodeIfNeeded() }
        }
    }

    private func startNodeIfNeeded() async {
        guard swarm.status == .idle else { return }
        // Try to pull fresh bootnode addresses via DoH; fall back to the
        // hardcoded list if it times out or fails.
        let fresh = await BootnodeResolver.resolveMainnet()
        let bootnodes = fresh.isEmpty ? SwarmConfig.defaultBootnodes : fresh
        swarm.start(.init(
            dataDir: SwarmNode.defaultDataDir(),
            password: "freedom-default",  // TODO: Keychain in M4
            bootnodes: bootnodes.joined(separator: "|")
        ))
    }
}
