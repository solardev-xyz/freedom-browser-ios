import SwiftUI

/// `permissionStore.revoke(origin:)` cascades `accountsChanged: []` +
/// `disconnect` to the live tab via `.walletPermissionRevoked`, so the
/// dapp learns it lost access without the user re-navigating.
@MainActor
struct ConnectedSiteDetailView: View {
    @Environment(PermissionStore.self) private var permissions
    @Environment(\.dismiss) private var dismiss

    let origin: OriginIdentity
    let host: String?
    let grant: DappPermission

    @State private var isShowingRevokeConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                originHeader
                connectionCard
                Button("Revoke connection", role: .destructive) {
                    isShowingRevokeConfirm = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
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

    private var originHeader: some View {
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
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected account").font(.caption).foregroundStyle(.secondary)
                Text(grant.account)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ApprovalLabeledRow(
                label: "Granted",
                value: Self.formatter.localizedString(for: grant.grantedAt, relativeTo: .now)
            )
            ApprovalLabeledRow(
                label: "Last used",
                value: Self.formatter.localizedString(for: grant.lastUsedAt, relativeTo: .now)
            )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
