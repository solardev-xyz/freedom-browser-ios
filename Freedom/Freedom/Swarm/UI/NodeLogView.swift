import SwarmKit
import SwiftUI

/// Full bee log surface — diagnostic-only, for users who hit a snag and
/// need to share what bee was doing. Hidden behind an unobtrusive link
/// in `NodeHomeView` so the 99% of users who don't care never see it.
@MainActor
struct NodeLogView: View {
    @Environment(SwarmNode.self) private var swarm

    var body: some View {
        ScrollView {
            // Lazy — `swarm.log` is capped at 500 lines (SwarmKit), and
            // an eager VStack would inflate every row up-front on each
            // push.
            LazyVStack(alignment: .leading, spacing: 4) {
                if swarm.log.isEmpty {
                    Text("No log entries yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(swarm.log.enumerated()), id: \.offset) { _, line in
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
