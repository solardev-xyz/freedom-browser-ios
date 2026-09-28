import SwiftUI

/// The prompt for a parked site permission request: what the site asked
/// for, Allow / Block, and "Remember for this site". Swiping it away is
/// a dismissal (denied once, nothing recorded).
struct SitePermissionPrompt: View {
    let request: SitePermissionRequest
    @State private var remember = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ForEach(request.kinds) { kind in
                        Image(systemName: kind.symbol)
                            .font(.title2)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.origin)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(request.sentence)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Remember for this site", isOn: $remember)
                Text(remember
                    ? "The answer is kept for this site until you remove it under Settings → Site Permissions."
                    : "The answer applies to this request only. The site can ask again; after three dismissals in a row it is blocked for this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button(role: .destructive) { request.respond(.block, remember) } label: {
                        Text("Block").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { request.respond(.allow, remember) } label: {
                        Text("Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Site permission")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(300)])
    }
}

/// Settings → Site Permissions: remembered decisions and run-scoped
/// embargoes, per site and per permission, with removal.
struct SitePermissionsSettingsView: View {
    @State private var store = SitePermissionStore.shared

    var body: some View {
        List {
            if store.origins.isEmpty {
                ContentUnavailableView(
                    "No site permissions",
                    systemImage: "hand.raised",
                    description: Text("Sites that asked for the camera, microphone or motion sensors and were remembered appear here.")
                )
            } else {
                ForEach(store.origins, id: \.self) { origin in
                    Section {
                        ForEach(SitePermissionKind.allCases) { kind in
                            if let row = rowText(origin: origin, kind: kind) {
                                HStack {
                                    Label(kind.label, systemImage: kind.symbol)
                                    Spacer()
                                    Text(row).foregroundStyle(.secondary)
                                }
                                .swipeActions {
                                    Button(role: .destructive) { store.revoke(origin: origin, kind: kind) } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(origin)
                    }
                }
                Section {
                    Button("Remove all", role: .destructive) { store.removeAll() }
                } footer: {
                    Text("Removing a decision lets the site ask again. Decisions blocked after repeated dismissals last only for this session.")
                }
            }
        }
        .navigationTitle("Site Permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rowText(origin: String, kind: SitePermissionKind) -> String? {
        if store.isSessionBlocked(origin: origin, kind: kind) { return "Blocked this session" }
        switch store.decision(origin: origin, kind: kind) {
        case .allow?: return "Allowed"
        case .block?: return "Blocked"
        case nil: return nil
        }
    }
}
