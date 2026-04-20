import SwiftUI
import SwarmKit

@main
struct FreedomApp: App {
    @State private var swarm = SwarmNode()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(swarm)
                .task { startNodeIfNeeded() }
        }
    }

    private func startNodeIfNeeded() {
        guard swarm.status == .idle else { return }
        swarm.start(.init(
            dataDir: SwarmNode.defaultDataDir(),
            password: "freedom-default"  // TODO: Keychain in M4
        ))
    }
}
