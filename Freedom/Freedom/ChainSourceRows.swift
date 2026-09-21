import MyotisKit
import SwiftUI

/// Shared building blocks for the two "order" pages — Settings → Name
/// Resolution and Settings → Chains → chain — and their per-source
/// option pages. Desktop parity: a reorderable row per source with a
/// status badge and an on/off switch; the source's own settings live
/// one level down.
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

    /// One row of an order list: name, badge, switch, chevron. The list
    /// lives in permanent edit mode so the reorder handle is always
    /// shown; a `NavigationLink` would be inert there, so the row is a
    /// button that pushes the source's option page itself.
    struct Row: View {
        let title: String
        let badge: Badge
        @Binding var isOn: Bool
        /// False for the last enabled source: a chain must keep a way to read.
        var canDisable = true
        let open: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        Text(title).foregroundStyle(.primary)
                        badge
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .disabled(isOn && !canDisable)
                Button(action: open) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// An endpoint row with its own remove button — the endpoint lists
    /// sit in the same permanently-editing form as the order lists, so
    /// swipe-to-delete is not available to them.
    struct EndpointRow: View {
        let url: String
        var badge: Badge? = nil
        var canRemove = true
        let remove: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Text(url).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
                if let badge { badge }
                Spacer(minLength: 4)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(canRemove ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canRemove)
            }
        }
    }

    /// Numeric text field with a unit suffix (timeouts).
    struct NumericField: View {
        @Binding var value: Int
        let suffix: String

        var body: some View {
            HStack(spacing: 2) {
                TextField("", value: $value, format: .number.grouping(.never))
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
            Stepper("Require \(policy.quorumM) of \(policy.quorumK)", value: $policy.quorumM, in: 1...max(1, policy.quorumK))
            Stepper("Endpoints per wave: \(policy.quorumK)", value: $policy.quorumK, in: 2...9)
                .onChange(of: policy.quorumK) { _, k in
                    if policy.quorumM > k { policy.quorumM = k }
                }
            LabeledContent("Timeout") {
                NumericField(value: $policy.quorumTimeoutMs, suffix: "ms")
            }
        }
    }

    /// Prover URL and ZK toggle for the Colibri row.
    struct ColibriFields: View {
        @Binding var policy: ChainAccessPolicy
        let placeholder: String

        var body: some View {
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
        }
    }

    // MARK: - Copy

    static func readTitle(_ source: ChainSource) -> String {
        switch source {
        case .myotis: "Myotis P2P light client"
        case .colibri: "Colibri verification"
        case .quorum: "RPC quorum"
        case .direct: "Direct RPC"
        }
    }

    static func readHelp(_ source: ChainSource) -> String {
        switch source {
        case .myotis: "Verified locally against the chain by the embedded light client; no RPC endpoint involved."
        case .colibri: "A remote prover produces the witness; Freedom verifies the cryptographic proof locally against the chain consensus."
        case .quorum: "Several independently configured RPC endpoints must return byte-identical answers."
        case .direct: "Compatibility fallback using the first working configured endpoint. Not cryptographic verification."
        }
    }
}
