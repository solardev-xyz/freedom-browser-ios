import SwiftUI

/// Modal sheet for the embedded Swarm node — the dual to `WalletSheet`.
@MainActor
struct NodeSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            NodeHomeView()
                .navigationTitle("Swarm node")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isPresented = false }
                    }
                }
        }
    }
}
