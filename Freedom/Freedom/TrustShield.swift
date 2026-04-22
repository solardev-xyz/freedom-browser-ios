import SwiftUI

struct TrustShield: View {
    let trust: ENSTrust
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails = true } label: {
            Image(systemName: trust.level.shieldSymbol)
                .font(.system(size: 18))
                .foregroundStyle(trust.level.shieldColor)
                .frame(width: 28, height: 28)
        }
        .sheet(isPresented: $showingDetails) {
            TrustDetailsSheet(trust: trust)
        }
    }
}

private struct TrustDetailsSheet: View {
    let trust: ENSTrust
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { levelHeader }

                Section("Pinned Block") {
                    HStack {
                        Text("Number")
                        Spacer()
                        Text("\(trust.block.number)").monospacedDigit()
                    }
                    HStack {
                        Text("Hash")
                        Spacer()
                        Text(truncatedHash)
                            .font(.caption).monospaced()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Quorum") {
                    LabeledContent("Providers queried", value: "\(trust.k)")
                    LabeledContent("Required agreement", value: "\(trust.m)")
                }

                if !trust.agreed.isEmpty {
                    Section("Agreed (\(trust.agreed.count))") {
                        ForEach(trust.agreed, id: \.self) { hostRow($0) }
                    }
                }
                if !trust.dissented.isEmpty {
                    Section("Dissented (\(trust.dissented.count))") {
                        ForEach(trust.dissented, id: \.self) { hostRow($0) }
                    }
                }
                if let silent = silentProviders, !silent.isEmpty {
                    Section("No response (\(silent.count))") {
                        ForEach(silent, id: \.self) { hostRow($0) }
                    }
                }
            }
            .navigationTitle("Trust")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var levelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: trust.level.shieldSymbol)
                .font(.largeTitle)
                .foregroundStyle(trust.level.shieldColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(trust.level.displayName).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func hostRow(_ host: String) -> some View {
        Text(host).font(.caption).monospaced().textSelection(.enabled)
    }

    private var summary: String {
        switch trust.level {
        case .verified:
            "\(trust.agreed.count) of \(trust.queried.count) providers returned identical bytes at a corroborated block."
        case .userConfigured:
            "Resolved via your configured RPC endpoint — single-source trust."
        case .unverified:
            "Only one provider responded. The answer is not cross-checked against others."
        case .conflict:
            "Providers disagreed on the contenthash. Do not trust this answer."
        }
    }

    private var truncatedHash: String {
        // Keep enough prefix to eyeball-distinguish, suffix for checksum sanity.
        let hash = trust.block.hash
        guard hash.count > 20 else { return hash }
        return String(hash.prefix(10)) + "…" + String(hash.suffix(6))
    }

    /// Providers queried but not listed as agreed or dissented — either
    /// timed out or errored mid-wave. Shown so the user can see which
    /// provider was silent rather than which actively disagreed.
    private var silentProviders: [String]? {
        let accounted = Set(trust.agreed).union(trust.dissented)
        let silent = trust.queried.filter { !accounted.contains($0) }
        return silent.isEmpty ? nil : silent
    }
}

private extension ENSTrustLevel {
    var shieldSymbol: String {
        switch self {
        case .verified: "checkmark.shield.fill"
        case .userConfigured: "shield.fill"
        case .unverified: "exclamationmark.shield.fill"
        case .conflict: "xmark.shield.fill"
        }
    }

    var shieldColor: Color {
        switch self {
        case .verified: .green
        case .userConfigured: .blue
        case .unverified: .orange
        case .conflict: .red
        }
    }
}
