import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm

    @State private var hashInput: String = "bzz://c0b683a3be2593bc7e22d252a371bac921bf47d11c3f3c1680ee60e6b8ccfcc8"
    @State private var currentURL: URL? = nil
    @State private var inputError: String? = nil
    @FocusState private var hashFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            urlBar
            Divider()
            contentArea
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().frame(width: 8, height: 8).foregroundStyle(statusColor)
            Text(swarm.status.rawValue).font(.caption).monospaced()
            Spacer()
            Text("\(swarm.peerCount) peers")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            TextField("bzz://<hash>[/path]", text: $hashInput)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($hashFieldFocused)
                .onSubmit(load)
            Button("Go", action: load)
                .buttonStyle(.borderedProminent)
                .disabled(!canLoad)
        }
        .padding(12)
    }

    @ViewBuilder private var contentArea: some View {
        if let err = inputError {
            ContentUnavailableView {
                Label("invalid URL", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err).font(.caption)
            }
        } else if let url = currentURL {
            BrowserWebView(url: url)
        } else {
            ContentUnavailableView {
                Label("paste a swarm URL", systemImage: "network")
            } description: {
                Text("Freedom routes bzz:// requests through the embedded bee node.\nAssets within a manifest resolve by path.")
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var canLoad: Bool {
        !hashInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && swarm.status == .running
    }

    private var statusColor: Color {
        switch swarm.status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle, .stopped: .gray
        }
    }

    private func load() {
        let trimmed = hashInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let urlString = trimmed.hasPrefix("bzz://") ? trimmed : "bzz://\(trimmed)"
        guard let url = URL(string: urlString), url.scheme == "bzz", url.host != nil else {
            inputError = "expected bzz://<hash>[/path] or a bare hash"
            currentURL = nil
            return
        }
        inputError = nil
        currentURL = url
        hashFieldFocused = false
    }
}

#Preview {
    ContentView()
        .environment(SwarmNode())
}
