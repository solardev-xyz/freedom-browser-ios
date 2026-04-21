import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm

    @State private var tab = BrowserTab()
    @State private var addressText: String = ""
    @State private var inputError: String? = nil
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            nodeStatusBar
            addressBar
            if let err = inputError {
                inputErrorRow(err)
            }
            progressBar
            webArea
            toolbar
        }
        .onChange(of: tab.url) { _, new in
            guard !addressFocused, let new else { return }
            addressText = new.absoluteString
        }
    }

    private var nodeStatusBar: some View {
        HStack(spacing: 8) {
            Circle().frame(width: 8, height: 8).foregroundStyle(nodeStatusColor)
            Text(swarm.status.rawValue).font(.caption).monospaced()
            Spacer()
            Text("\(swarm.peerCount) peers")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            TextField("bzz://<hash> or https://…", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit(navigate)
            if addressFocused {
                Button("Go", action: navigate)
                    .buttonStyle(.borderedProminent)
            } else if tab.isLoading {
                Button { tab.stop() } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button { tab.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(tab.url == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var progressBar: some View {
        if tab.isLoading && tab.progress > 0 && tab.progress < 1 {
            ProgressView(value: tab.progress)
                .tint(.accentColor)
                .scaleEffect(y: 0.5)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    @ViewBuilder private var webArea: some View {
        if tab.hasNavigated {
            BrowserWebView(tab: tab)
        } else {
            HomePage(onNavigate: navigate(to:))
        }
    }

    private func inputErrorRow(_ err: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(err).font(.caption)
            Spacer()
            Button { inputError = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(Color.red)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            toolbarButton("chevron.backward", enabled: tab.canGoBack) { tab.goBack() }
            toolbarButton("chevron.forward", enabled: tab.canGoForward) { tab.goForward() }
            Spacer(minLength: 0)
            if let url = tab.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                toolbarButton("square.and.arrow.up", enabled: false) {}
            }
            toolbarButton("square.on.square", enabled: false) {}  // tabs — M3.2
        }
        .padding(.horizontal, 4)
        .background(Color(.secondarySystemBackground))
    }

    private func toolbarButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!enabled)
    }

    private var nodeStatusColor: Color {
        switch swarm.status {
        case .running: .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .idle, .stopped: .gray
        }
    }

    private func navigate() {
        guard let parsed = BrowserURL.parse(addressText) else {
            inputError = "Expected bzz://<hash>[/path], https://…, or a bare 64-hex Swarm reference."
            return
        }
        navigate(to: parsed)
    }

    private func navigate(to browserURL: BrowserURL) {
        inputError = nil
        addressFocused = false
        addressText = browserURL.url.absoluteString
        tab.navigate(to: browserURL)
    }
}

#Preview {
    ContentView()
        .environment(SwarmNode())
}
