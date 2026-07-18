import SwiftUI

/// Messaging-tier approval sheet (SWIP messaging extension). First
/// grant explains what the tier discloses (a stable per-site messaging
/// identity) and consumes (bandwidth while subscribed, stamps on
/// send); per-send prompts show the topic + size and offer the
/// auto-approve toggle — mirrors desktop's `showSwarmMessagingApproval`
/// grant/send modes.
@MainActor
struct SwarmMessagingSheet: View {
    @Environment(SwarmPermissionStore.self) private var permissionStore
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let details: SwarmMessagingDetails

    @State private var sendAutoApprove: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: captionText
                    )
                    if details.isFirstGrant {
                        grantExplainer
                    }
                    if case .send = details.operation {
                        autoApproveToggle
                    }
                    PrimaryActionButton(
                        title: "Allow",
                        systemImage: "checkmark",
                        action: approve
                    )
                }
                .padding(20)
            }
            .navigationTitle(navigationTitleText)
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

    private var navigationTitleText: String {
        if details.isFirstGrant { return "Allow messaging" }
        switch details.operation {
        case .identity: return "Allow messaging"
        case .subscribe: return "Allow subscription"
        case .send: return "Send message"
        }
    }

    private var captionText: String {
        switch details.operation {
        case .identity:
            return "This site wants to see your messaging identity"
        case .subscribe(let topic):
            return "This site wants to receive messages on “\(topic)”"
        case .send(let kind, let topic, let sizeBytes):
            let how = kind == .pss ? "an encrypted message" : "a broadcast"
            return "This site wants to send \(how) on “\(topic)” "
                + "(\(sizeBytes) bytes)"
        }
    }

    private var grantExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Reveals a stable messaging key other sites can't see but this site can rely on.",
                systemImage: "key"
            )
            Label(
                "Subscriptions use bandwidth while the page is open; sends use your stamps.",
                systemImage: "antenna.radiowaves.left.and.right"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var autoApproveToggle: some View {
        ApprovalAutoApproveCard(
            label: "Skip approval for future messages from this site",
            caption: "You can revoke this from the connected-sites list later.",
            isOn: $sendAutoApprove
        )
    }

    private func approve() {
        if details.isFirstGrant {
            permissionStore.grantMessaging(origin: approval.origin.key)
        }
        if sendAutoApprove {
            permissionStore.setAutoApproveMessaging(
                origin: approval.origin.key, enabled: true
            )
        }
        approval.decide(.approved)
        dismiss()
    }
}
