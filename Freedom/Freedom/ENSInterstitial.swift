import SwiftUI

/// Full-webArea takeover shown in place of the webview when a navigation
/// is gated. Three shapes:
///  - unverified: single-source resolution with blockUnverifiedEns on →
///    "Continue once" + "Go back". One-shot opt-in, not remembered.
///  - conflict: providers disagreed on the contenthash → "Go back" only.
///  - anchorDisagreement: providers disagreed on the block hash → "Go back" only.
struct ENSInterstitial: View {
    let gate: BrowserTab.Gate
    let tab: BrowserTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                explanation
                details
                actions
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 44))
                .foregroundStyle(headerColor)
            Text(headerTitle).font(.title2).bold()
        }
    }

    private var explanation: some View {
        Text(explanationText)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var details: some View {
        switch gate {
        case .unverifiedUntrusted(_, let trust):
            TrustSummary(trust: trust)
        case .conflict(let groups, let trust):
            ConflictGroups(groups: groups, trust: trust)
        case .anchorDisagreement(let largest, let total, let threshold):
            AnchorDetails(largest: largest, total: total, threshold: threshold)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if case .unverifiedUntrusted = gate {
                Button { tab.continuePastGate() } label: {
                    Label("Continue once", systemImage: "arrow.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            Button { tab.dismissGate() } label: {
                Text("Go back").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Copy

    private var headerSymbol: String {
        switch gate {
        case .unverifiedUntrusted: "exclamationmark.shield.fill"
        case .conflict, .anchorDisagreement: "xmark.shield.fill"
        }
    }

    private var headerColor: Color {
        switch gate {
        case .unverifiedUntrusted: .orange
        case .conflict, .anchorDisagreement: .red
        }
    }

    private var headerTitle: String {
        switch gate {
        case .unverifiedUntrusted: "Unverified resolution"
        case .conflict: "Providers disagreed"
        case .anchorDisagreement: "Block-hash disagreement"
        }
    }

    private var explanationText: String {
        switch gate {
        case .unverifiedUntrusted:
            "Only one Ethereum provider answered. The contenthash couldn't be cross-checked against other providers, so a misbehaving RPC could steer you to content of its choosing."
        case .conflict:
            "Providers returned different contenthashes for this name. One or more of them is lying — or an honest chain fork is in progress. Do not continue."
        case .anchorDisagreement:
            "Providers returned different block hashes at the corroboration anchor. A provider is serving a stale or forged chain state. Do not continue."
        }
    }
}

private struct TrustSummary: View {
    let trust: ENSTrust

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailsHeader
            LabeledContent("Responded", value: trust.agreed.first ?? "—")
                .font(.caption)
            LabeledContent("Block", value: String(trust.block.number))
                .font(.caption)
        }
    }
}

private struct ConflictGroups: View {
    let groups: [ENSConflictGroup]
    let trust: ENSTrust

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            groupsHeader
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(labelFor(group))
                        .font(.caption).bold()
                        .foregroundStyle(group.resolvedData == nil ? .secondary : .primary)
                    ForEach(group.hosts, id: \.self) { host in
                        Text(host).font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            LabeledContent("Block", value: String(trust.block.number))
                .font(.caption)
        }
    }

    private func labelFor(_ group: ENSConflictGroup) -> String {
        if let reason = group.reason {
            switch reason {
            case .noResolver: return "No resolver registered"
            case .noContenthash: return "Resolver failed (e.g. CCIP gateway)"
            case .emptyContenthash: return "Contenthash empty"
            case .ccipDisabled: return "Needs CCIP-Read (disabled)"
            case .emptyAddress: return "No address record"
            }
        }
        guard let bytes = group.resolvedData else { return "Unknown response" }
        let preview = bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "Contenthash 0x\(preview)…"
    }
}

private struct AnchorDetails: View {
    let largest: Int
    let total: Int
    let threshold: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailsHeader
            LabeledContent("Largest agreeing bucket", value: "\(largest) / \(total)")
                .font(.caption)
            LabeledContent("Threshold required", value: "\(threshold)")
                .font(.caption)
        }
    }
}

private var detailsHeader: some View {
    Text("Details")
        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
}

private var groupsHeader: some View {
    Text("What each provider said")
        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
}
