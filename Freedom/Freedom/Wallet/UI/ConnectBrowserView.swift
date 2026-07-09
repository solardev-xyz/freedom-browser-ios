import SwiftUI

/// Entry point for openlv remote signing: scan the QR freedom desktop
/// shows (or paste its link) to let that browser send signing requests
/// to this wallet. Every request still gets its own approval sheet —
/// this screen only establishes the encrypted session.
@MainActor
struct ConnectBrowserView: View {
    @Environment(OpenLVWalletSession.self) private var session
    @Environment(\.closeWalletSheet) private var closeWalletSheet

    @State private var pastedLink = ""
    @State private var inputError: String?
    @State private var isStarting = false

    var body: some View {
        List {
            statusSection
            if !session.isActive {
                scanSection
                pasteSection
            }
        }
        .navigationTitle("Connect Browser")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusSection: some View {
        Section {
            switch session.status {
            case .idle:
                Text("Scan the QR code shown in Freedom on your computer to approve its signing requests on this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to your browser…")
                }
            case .connected:
                Label("Connected — approve requests as they appear.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .disconnected:
                Text("Disconnected. Scan a new QR code in your browser to reconnect.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if session.isActive {
                Button("Disconnect", role: .destructive) {
                    session.stop()
                }
            }
        }
    }

    private var scanSection: some View {
        Section("Scan") {
            QRScannerView { code in
                connect(raw: code)
            }
            .frame(height: 240)
            .listRowInsets(EdgeInsets())
        }
    }

    private var pasteSection: some View {
        Section("Or paste the link") {
            TextField("https://… or openlv://…", text: $pastedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
            Button {
                connect(raw: pastedLink)
            } label: {
                if isStarting {
                    ProgressView()
                } else {
                    Text("Connect")
                }
            }
            .disabled(pastedLink.isEmpty || isStarting)
            if let inputError {
                Text(inputError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func connect(raw: String) {
        guard !isStarting else { return }
        guard let uri = OpenLVWalletSession.extractOpenLVURI(from: raw) else {
            inputError = "That doesn't look like a Freedom connection link."
            return
        }
        inputError = nil
        isStarting = true
        Task {
            do {
                try await session.start(uri: uri)
                // Approval sheets present from ContentView; the wallet
                // sheet would sit on top of them, so get out of the way.
                closeWalletSheet()
            } catch {
                inputError = "Couldn't start the session: \(error.localizedDescription)"
            }
            isStarting = false
        }
    }
}
