import SwiftUI

/// Consent sheet for a bzz-hosted app's permission manifest — desktop's
/// "App permissions" sub-screen. Lists what the app declares (browser
/// label + the app's own reason), what it stopped declaring, and offers
/// the three answers: allow all, connect but keep the per-action
/// prompts, or don't allow. The decision is settled on
/// `SwarmManifestStore` here; the bridge only learns approved / denied.
@MainActor
struct SwarmManifestSheet: View {
    @Environment(SwarmManifestStore.self) private var manifestStore
    @Environment(\.dismiss) private var dismiss

    let approval: ApprovalRequest
    let details: SwarmManifestConsentDetails

    private var model: SwarmManifestConsentModel { details.model }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ApprovalOriginStrip(origin: approval.origin, caption: caption)
                    appCard
                    rows
                    if model.createsIdentity || model.preservedIdentity {
                        identityNote
                    }
                    Text("Allow all applies these permissions now. Asking each time keeps the normal per-action prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PrimaryActionButton(title: "Allow all", systemImage: "checkmark") {
                        settle(.allow)
                    }
                    Button("Connect, but ask each time") { settle(.individual) }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .padding(20)
            }
            .navigationTitle(model.isUpdate ? "Updated app permissions" : "App permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Don’t allow") { settle(.deny) }
                }
            }
        }
    }

    private var caption: String {
        model.isUpdate
            ? "This app changed the permissions it declares"
            : "This app declares the permissions it needs up front"
    }

    private var appCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.name).font(.headline)
            if !model.description.isEmpty {
                Text(model.description).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.removed, id: \.self) { capability in
                row(title: "\(capability.label) removed",
                    detail: "The app no longer requests this capability. Manifest-managed access has been removed.",
                    systemImage: "minus.circle")
            }
            ForEach(model.changed, id: \.capability) { change in
                row(title: change.capability.label, detail: change.why, systemImage: icon(for: change.capability))
            }
        }
    }

    private func row(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func icon(for capability: SwarmManifestCapability) -> String {
        switch capability {
        case .publish: "square.and.arrow.up"
        case .feeds: "dot.radiowaves.up.forward"
        case .signing: "signature"
        case .messaging: "envelope"
        }
    }

    private var identityNote: some View {
        Label(
            model.createsIdentity
                ? "A new app-scoped signing identity will be created. Your vault still unlocks at signing time."
                : "Your existing publisher identity will be kept.",
            systemImage: "key"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Settles the token on the store, then resolves the continuation
    /// with what the store says. A token that expired or went stale
    /// under the sheet counts as a denial — the page can ask again.
    private func settle(_ outcome: SwarmManifestOutcome) {
        let allowed = (try? manifestStore.decide(token: details.token, outcome: outcome))?.allowed ?? false
        approval.decide(allowed ? .approved : .denied)
        dismiss()
    }
}
