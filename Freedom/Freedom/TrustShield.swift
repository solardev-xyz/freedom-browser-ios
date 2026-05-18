import SwiftUI

struct TrustShield: View {
    let trust: ENSTrust
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails = true } label: {
            Image(systemName: trust.shieldSymbol)
                .font(.system(size: 18))
                .foregroundStyle(trust.shieldColor)
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

                if isColibri {
                    Section("Prover") {
                        ForEach(trust.queried, id: \.self) { hostRow($0) }
                    }
                } else {
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

    private var isColibri: Bool { trust.method == .colibri }

    private var levelHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: trust.shieldSymbol)
                .font(.largeTitle)
                .foregroundStyle(trust.shieldColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func hostRow(_ host: String) -> some View {
        Text(host).font(.caption).monospaced().textSelection(.enabled)
    }

    private var title: String {
        if isColibri, trust.level == .verified { return "Cryptographically verified" }
        return trust.level.displayName
    }

    private var summary: String {
        if isColibri {
            switch trust.level {
            case .verified:
                return "Proven against the Ethereum sync committee — the answer is checked against consensus itself, not just cross-checked between RPCs."
            default:
                // Colibri only ever mints `.verified`; a non-verified level
                // here means the quorum fallback produced the result.
                break
            }
        }
        switch trust.level {
        case .verified:
            return "\(trust.agreed.count) of \(trust.queried.count) providers returned identical bytes at a corroborated block."
        case .userConfigured:
            return "Resolved via your configured RPC endpoint — single-source trust."
        case .unverified:
            return "Only one provider responded. The answer is not cross-checked against others."
        case .conflict:
            return "Providers disagreed on the contenthash. Do not trust this answer."
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

private extension ENSTrust {
    /// Colibri verification gets a distinct `seal` glyph — a proof-backed
    /// guarantee, visually separate from the `shield` of M-of-K quorum
    /// agreement.
    var shieldSymbol: String {
        if method == .colibri, level == .verified { return "checkmark.seal.fill" }
        switch level {
        case .verified: return "checkmark.shield.fill"
        case .userConfigured: return "shield.fill"
        case .unverified: return "exclamationmark.shield.fill"
        case .conflict: return "xmark.shield.fill"
        }
    }

    var shieldColor: Color {
        switch level {
        case .verified: return .green
        case .userConfigured: return .blue
        case .unverified: return .orange
        case .conflict: return .red
        }
    }
}
