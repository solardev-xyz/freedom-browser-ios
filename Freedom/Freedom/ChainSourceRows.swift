import MyotisKit
import SwiftUI

/// Shared building blocks for the two "order" pages — Settings → ENS
/// (name resolution order) and Settings → Chains → chain (read and
/// broadcast order). Desktop parity: a reorderable row per source with
/// a status badge and an on/off switch, and the source's own settings
/// nested under it.
enum ChainSourceRows {
    /// The badge next to a source name (desktop `sourceStatus`).
    struct Badge: View {
        enum Kind { case ready, warning, neutral }
        let text: String
        let kind: Kind

        var body: some View {
            Text(text)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }

        private var color: Color {
            switch kind {
            case .ready: .green
            case .warning: .orange
            case .neutral: .secondary
            }
        }
    }

    /// Myotis readiness for a chain, worded like desktop's badge.
    @MainActor
    static func myotisBadge(chainID: Int, node: MyotisNode, enabled: Bool) -> Badge {
        guard ChainAccessPolicy.lightClientChainIDs.contains(chainID) else {
            return Badge(text: "Unsupported", kind: .neutral)
        }
        guard enabled else { return Badge(text: "Off", kind: .neutral) }
        let chainId = UInt64(chainID)
        if let recovery = node.recovery[chainId] {
            return Badge(text: recovery.label, kind: .warning)
        }
        guard let status = node.chainStatus[chainId] else {
            return Badge(text: "Status unknown", kind: .warning)
        }
        if !status.running { return Badge(text: "Off", kind: .neutral) }
        if status.paused { return Badge(text: "Paused", kind: .warning) }
        if status.isStaleAnchor { return Badge(text: "Checkpoint expired", kind: .warning) }
        if status.ready { return Badge(text: "Ready", kind: .ready) }
        if status.beaconState == "SYNCED" { return Badge(text: "Waiting for peers", kind: .warning) }
        return Badge(text: "Syncing", kind: .warning)
    }

    static func quorumBadge(m: Int, k: Int, available: Int) -> Badge {
        available >= AnchorCorroboration.minQuorumProviders && k >= 2 && m >= 1
            ? Badge(text: "\(m) of \(k)", kind: .ready)
            : Badge(text: "Needs \(AnchorCorroboration.minQuorumProviders) endpoints", kind: .warning)
    }

    /// One source row: name, help, badge, switch. `canDisable` is false
    /// for the last enabled source so a chain never ends up with no way
    /// to read.
    struct Row<Nested: View>: View {
        let title: String
        let help: String
        let badge: Badge
        @Binding var isOn: Bool
        var canDisable = true
        @ViewBuilder var nested: () -> Nested

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title).font(.body)
                            badge
                        }
                        Text(help).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $isOn)
                        .labelsHidden()
                        .disabled(isOn && !canDisable)
                }
                if isOn {
                    nested()
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Numeric text field with a unit suffix (timeouts).
    struct NumericField: View {
        @Binding var value: Int
        let suffix: String

        var body: some View {
            HStack(spacing: 2) {
                TextField("", value: $value, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 60)
                Text(suffix).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// M-of-K steppers plus the source timeout, editing a policy binding.
    struct QuorumFields: View {
        @Binding var policy: ChainAccessPolicy
        let available: Int

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Stepper("Require \(policy.quorumM) of \(policy.quorumK)", value: $policy.quorumM, in: 1...max(1, policy.quorumK))
                Stepper("Endpoints per wave: \(policy.quorumK)", value: $policy.quorumK, in: 2...9)
                    .onChange(of: policy.quorumK) { _, k in
                        if policy.quorumM > k { policy.quorumM = k }
                    }
                LabeledContent("Timeout") {
                    NumericField(value: $policy.quorumTimeoutMs, suffix: "ms")
                }
                Text("\(available) endpoint\(available == 1 ? "" : "s") currently available. Verified quorum needs at least \(AnchorCorroboration.minQuorumProviders).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    /// Prover URL and ZK toggle for the Colibri row.
    struct ColibriFields: View {
        @Binding var policy: ChainAccessPolicy
        let placeholder: String

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Prover") {
                    TextField(placeholder, text: Binding(
                        get: { policy.proverURL ?? "" },
                        set: { policy.proverURL = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.caption).monospaced()
                    .multilineTextAlignment(.trailing)
                }
                Toggle("ZK consensus proof", isOn: $policy.zkProof)
                Text("Leave the prover empty for the corpus.core default.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}
