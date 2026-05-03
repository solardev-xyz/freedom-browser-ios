import SwiftUI

/// Modal sheet for the embedded IPFS reader — sibling of `NodeSheet`
/// which covers Swarm. The two are intentionally separate so each
/// node's status / cache / routing state has its own surface area.
@MainActor
struct IpfsNodeSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            IpfsNodeHomeView()
                .navigationTitle("IPFS node")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isPresented = false }
                    }
                }
        }
    }
}
