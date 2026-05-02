import IPFSKit
import SwiftUI

/// Full kubo log surface — diagnostic-only. Same shape as the Swarm
/// `NodeLogView`; hidden behind an unobtrusive footer link in
/// `IpfsNodeHomeView`.
@MainActor
struct IpfsNodeLogView: View {
    @Environment(IPFSNode.self) private var ipfs

    var body: some View {
        ScrollView {
            // Lazy — `ipfs.log` is capped at 500 lines (IPFSKit), and an
            // eager VStack would inflate every row up-front on push.
            LazyVStack(alignment: .leading, spacing: 4) {
                if ipfs.log.isEmpty {
                    Text("No log entries yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(ipfs.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
    }
}
