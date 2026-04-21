import SwiftUI
import SwarmKit

struct ContentView: View {
    @Environment(SwarmNode.self) private var swarm
    @Environment(TabStore.self) private var tabStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var addressText: String = ""
    @State private var inputError: String? = nil
    @State private var isShowingTabSwitcher = false
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
        .sheet(isPresented: $isShowingTabSwitcher) {
            TabSwitcher(isPresented: $isShowingTabSwitcher)
        }
        .onChange(of: tabStore.activeTab?.url) { _, new in
            guard !addressFocused else { return }
            addressText = new?.absoluteString ?? ""
        }
        .onChange(of: tabStore.activeRecordID) { _, _ in
            addressFocused = false
            addressText = tabStore.activeTab?.url?.absoluteString ?? ""
        }
        .onChange(of: scenePhase) { _, new in
            if new == .background {
                Task { await tabStore.captureActive() }
            }
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
            } else if let active = tabStore.activeTab, active.isLoading {
                Button { active.stop() } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button { tabStore.activeTab?.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(tabStore.activeTab?.url == nil)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder private var progressBar: some View {
        if let active = tabStore.activeTab, active.isLoading, active.progress > 0, active.progress < 1 {
            ProgressView(value: active.progress)
                .tint(.accentColor)
                .scaleEffect(y: 0.5)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    @ViewBuilder private var webArea: some View {
        if let active = tabStore.activeTab, active.hasNavigated {
            // .id forces SwiftUI to recreate the representable when the
            // active tab changes — otherwise it reuses the prior UIView
            // (which is the *previous* tab's WKWebView) and we show the
            // wrong page.
            BrowserWebView(tab: active).id(active.recordID)
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
            toolbarButton("chevron.backward", enabled: tabStore.activeTab?.canGoBack == true) {
                tabStore.activeTab?.goBack()
            }
            toolbarButton("chevron.forward", enabled: tabStore.activeTab?.canGoForward == true) {
                tabStore.activeTab?.goForward()
            }
            Spacer(minLength: 0)
            if let url = tabStore.activeTab?.url {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 20))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                toolbarButton("square.and.arrow.up", enabled: false) {}
            }
            Button { isShowingTabSwitcher = true } label: {
                tabsButtonLabel
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, 4)
        .background(Color(.secondarySystemBackground))
    }

    private var tabsButtonLabel: some View {
        ZStack {
            Image(systemName: "square.on.square").font(.system(size: 20))
            if !tabStore.records.isEmpty {
                Text("\(tabStore.records.count)")
                    .font(.caption2).bold()
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 14, y: -10)
            }
        }
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
        tabStore.navigateActive(to: browserURL)
    }
}
