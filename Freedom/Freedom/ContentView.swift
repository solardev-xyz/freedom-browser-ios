import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm

    @State private var hashInput: String = "bzz://f0df8b5fbe7d8cb04430ba8913e8aa6a0ad4976f3a48b7aacf5aa14635739813"
    @State private var currentHtml: String? = nil
    @State private var loadedFilename: String? = nil
    @State private var fetchError: String? = nil
    @State private var isLoading: Bool = false
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
            TextField("swarm hash…", text: $hashInput)
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
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("fetching…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = fetchError {
            ContentUnavailableView {
                Label("load failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(err).font(.caption).multilineTextAlignment(.center)
            }
        } else if let html = currentHtml {
            VStack(spacing: 0) {
                if let name = loadedFilename {
                    Text(name)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground))
                }
                BrowserWebView(html: html)
            }
        } else {
            ContentUnavailableView {
                Label("paste a swarm hash", systemImage: "network")
            } description: {
                Text("Freedom fetches content over the Swarm network via the embedded bee node.")
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var canLoad: Bool {
        !hashInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && swarm.status == .running
        && !isLoading
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
        let hash = trimmed.hasPrefix("bzz://") ? String(trimmed.dropFirst("bzz://".count)) : trimmed
        hashFieldFocused = false
        isLoading = true
        currentHtml = nil
        loadedFilename = nil
        fetchError = nil
        Task {
            do {
                let file = try await swarm.download(hash: hash)
                if let text = String(data: file.data, encoding: .utf8) {
                    currentHtml = text
                    loadedFilename = file.name
                } else {
                    fetchError = "content is binary (\(file.data.count) bytes). M1 only renders UTF-8 text/HTML — M2 will add full asset resolution via WKURLSchemeHandler."
                }
            } catch {
                fetchError = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    ContentView()
        .environment(SwarmNode())
}
