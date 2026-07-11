import SwiftUI

/// Feed-write approval sheet. First-grant flow shows the
/// identity-mode picker; the choice persists immutably on
/// `SwarmFeedIdentity` because flipping it later would orphan
/// existing feeds (different signing key → different SOC ownership).
/// Subsequent grants for the same origin skip the picker entirely.
@MainActor
struct SwarmFeedAccessSheet: View {
    @Environment(Vault.self) private var vault
    @Environment(SwarmFeedStore.self) private var feedStore
    @Environment(SwarmPermissionStore.self) private var permissionStore
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let details: SwarmFeedAccessDetails

    @State private var pickedMode: SwarmFeedIdentityMode = .appScoped
    @State private var grantAutoApprove: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(
                        origin: approval.origin,
                        caption: captionText
                    )
                    switch vault.state {
                    case .empty:
                        Label("Set up a wallet first, then try again.",
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    case .locked:
                        ApprovalUnlockStrip()
                    case .unlocked:
                        unlockedBody
                    }
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
            // Sheet was opened only because the vault was locked at
            // request time (the bridge's auto-approve path requires an
            // unlocked vault; see `feedAutoApproveActive`). Once the
            // user unlocks, honor the existing auto-approve grant and
            // skip the sheet body — re-asking would defeat the whole
            // "auto" part. First-grant must always show the picker.
            .task(id: vault.state) {
                guard !details.isFirstGrant,
                      vault.state == .unlocked,
                      permissionStore.isAutoApproveFeeds(origin: approval.origin.key)
                else { return }
                approval.decide(.approved)
                dismiss()
            }
        }
    }

    /// Feed and signing requests share one grant tier but deserve
    /// distinct copy — a raw SOC write / identity disclosure isn't
    /// "creating a feed", and the user should understand it reveals
    /// this site's publisher address (desktop's "Publisher Signing"
    /// prompt makes the same distinction).
    private var captionText: String {
        switch details.scope {
        case .feed(let name):
            return "This site wants to create feed “\(name)”"
        case .signing:
            return "This site wants to sign Swarm chunks with its "
                + "publisher key, which reveals its publisher address"
        }
    }

    private var navigationTitleText: String {
        switch details.scope {
        case .feed: return "Allow feed access"
        case .signing: return "Allow publisher signing"
        }
    }

    @ViewBuilder private var unlockedBody: some View {
        if details.isFirstGrant {
            identityModeCard
        }
        autoApproveToggle
        PrimaryActionButton(
            title: "Allow",
            systemImage: "checkmark",
            action: approve
        )
    }

    private var identityModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Signing key", selection: $pickedMode) {
                Text("App-scoped").tag(SwarmFeedIdentityMode.appScoped)
                Text("Bee wallet").tag(SwarmFeedIdentityMode.beeWallet)
            }
            .pickerStyle(.segmented)
            Text(modeExplainer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var modeExplainer: String {
        switch pickedMode {
        case .appScoped:
            return "A dedicated key for this site. Cryptographically isolated from your wallet."
        case .beeWallet:
            return "Sign with your Bee node’s main key. Useful when a site needs a known funded identity."
        }
    }

    private var autoApproveToggle: some View {
        ApprovalAutoApproveCard(
            label: "Skip approval for future feed writes from this site",
            caption: "You can revoke this from the connected-sites list later.",
            isOn: $grantAutoApprove
        )
    }

    private func approve() {
        if details.isFirstGrant {
            // For appScoped, publisher index is allocated inside
            // setFeedIdentity at insert time — keeps two concurrent
            // approval flows from different origins from racing to
            // the same index.
            feedStore.setFeedIdentity(
                origin: approval.origin.key,
                identityMode: pickedMode
            )
        }
        if grantAutoApprove {
            permissionStore.setAutoApproveFeeds(
                origin: approval.origin.key, enabled: true
            )
        }
        approval.decide(.approved)
        dismiss()
    }
}
