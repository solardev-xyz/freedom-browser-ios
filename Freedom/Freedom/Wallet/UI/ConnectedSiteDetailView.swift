import SwiftData
import SwiftUI

/// `permissionStore.revoke(origin:)` cascades `accountsChanged: []` +
/// `disconnect` to the live tab via `.walletPermissionRevoked`, so the
/// dapp learns it lost access without the user re-navigating.
@MainActor
struct ConnectedSiteDetailView: View {
    @Environment(PermissionStore.self) private var permissions
    @Environment(AutoApproveStore.self) private var autoApproveStore
    @Environment(\.dismiss) private var dismiss

    let origin: OriginIdentity
    let host: String?
    let grant: DappPermission

    /// Predicate can't capture `origin.key` (runtime), so fetch all and
    /// filter in body. Sort moves to SwiftData via `@Query(sort:)`.
    @Query(sort: \AutoApproveRule.grantedAt, order: .reverse)
    private var allRules: [AutoApproveRule]

    private var rules: [AutoApproveRule] {
        allRules.filter { $0.origin == origin.key }
    }

    @State private var isShowingRevokeConfirm = false

    var body: some View {
        List {
            Section {
                originRow
            }
            Section("Connection") {
                accountRow
                ApprovalLabeledRow(
                    label: "Granted",
                    value: Self.formatter.localizedString(for: grant.grantedAt, relativeTo: .now)
                )
                ApprovalLabeledRow(
                    label: "Last used",
                    value: Self.formatter.localizedString(for: grant.lastUsedAt, relativeTo: .now)
                )
            }
            if !rules.isEmpty {
                Section {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                    }
                    .onDelete { offsets in
                        offsets.forEach { autoApproveStore.revoke(rules[$0]) }
                    }
                } header: {
                    Text("Auto-approve rules")
                } footer: {
                    Text("Swipe a rule to remove it.")
                }
            }
            Section {
                Button("Revoke connection", role: .destructive) {
                    isShowingRevokeConfirm = true
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Connected site")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Disconnect from \(origin.displayString)?",
            isPresented: $isShowingRevokeConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                permissions.revoke(origin: origin.key)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The site loses wallet access immediately. It can request a new connection any time.")
        }
    }

    private var originRow: some View {
        HStack(spacing: 12) {
            FaviconView(host: host, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(origin.displayString)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(origin.schemeDisplayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connected account").font(.caption).foregroundStyle(.secondary)
            Text(grant.account)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func ruleRow(_ rule: AutoApproveRule) -> some View {
        let label = ERC20Selectors.label(for: rule.selector).map { $0.capitalized }
            ?? "Custom call"
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout)
            Text("\(rule.contract.shortenedHex()) · \(rule.selector)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
