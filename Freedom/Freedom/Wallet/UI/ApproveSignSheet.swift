import SwiftUI
import web3

/// Narrowed input for the sign sheet — exhaustivity makes routing bugs
/// a compile error rather than a runtime assert.
enum SignKind {
    case personalSign(PersonalSignCoder.Preview)
    case typedData(TypedData)
}

/// `personal_sign` + `eth_signTypedData_v4` approval. Actual signing
/// happens in the bridge after `.approved` fires — the sheet only shows
/// intent. Connect flow is `ApproveConnectSheet`; ContentView routes.
@MainActor
struct ApproveSignSheet: View {
    @Environment(Vault.self) private var vault
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let kind: SignKind

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(origin: approval.origin, caption: caption)
                    switch vault.state {
                    case .empty:
                        Label("Set up a wallet first, then try again.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    case .locked:
                        ApprovalUnlockStrip()
                    case .unlocked:
                        unlockedBody
                    }
                }
                .padding(20)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        approval.decide(.denied)
                        dismiss()
                    }
                }
            }
        }
    }

    private var caption: String {
        switch kind {
        case .personalSign: return "This site wants you to sign a message"
        case .typedData: return "This site wants you to sign typed data"
        }
    }

    private var navTitle: String {
        switch kind {
        case .personalSign: return "Sign message"
        case .typedData: return "Sign data"
        }
    }

    @ViewBuilder private var unlockedBody: some View {
        switch kind {
        case .personalSign(let preview):
            PersonalSignBody(preview: preview, approve: approve)
        case .typedData(let typed):
            TypedDataBody(typed: typed, approve: approve)
        }
    }

    private func approve() {
        approval.decide(.approved)
        dismiss()
    }
}

@MainActor
private struct PersonalSignBody: View {
    let preview: PersonalSignCoder.Preview
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Message").font(.caption).foregroundStyle(.secondary)
            messageBlock
            Text("Signatures can authorize actions off-chain. Only sign if you recognise the site.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrimaryActionButton(title: "Sign", systemImage: "signature", action: approve)
        }
    }

    @ViewBuilder private var messageBlock: some View {
        Group {
            switch preview {
            case .utf8(let text):
                Text(text).textSelection(.enabled)
            case .hex(let hex):
                Text(hex)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
private struct TypedDataBody: View {
    let typed: TypedData
    let approve: () -> Void

    /// Computed once on first appear: pretty-printed message JSON +
    /// domain summary. SwiftUI re-evaluates body on every state change,
    /// and a 5KB OpenSea order is non-trivial to format.
    @State private var messageJSON: String = ""
    @State private var domainSummary: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ApprovalLabeledRow(label: "Domain", value: domainSummary)
                ApprovalLabeledRow(label: "Type", value: typed.primaryType)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("Message").font(.caption).foregroundStyle(.secondary)
            // Capped height so a long payload can't push Sign below the fold;
            // user can still scroll the message inside this card.
            ScrollView {
                Text(messageJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text("Signatures can authorize actions off-chain. Only sign if you recognise the site.")
                .font(.caption)
                .foregroundStyle(.secondary)
            PrimaryActionButton(title: "Sign", systemImage: "signature", action: approve)
        }
        .task {
            messageJSON = typed.description
            domainSummary = formatDomain()
        }
    }

    /// `typed.domain` is `GenericJSON.JSON`, not directly subscriptable
    /// without importing that module. Round-trip through `JSONSerialization`
    /// to read `name` / `verifyingContract` / `chainId`. Runs once on
    /// `.task`, so the cost is paid once per sheet appearance.
    private func formatDomain() -> String {
        guard let data = try? JSONEncoder().encode(typed.domain),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "(unknown)"
        }
        if let name = dict["name"] as? String { return name }
        if let contract = dict["verifyingContract"] as? String { return contract }
        if let chainID = dict["chainId"] { return "chain \(chainID)" }
        return "(unknown)"
    }
}
