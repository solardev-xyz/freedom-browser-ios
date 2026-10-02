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
                        SitePermissionRows(origin: origin, store: store)
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

}

/// One site's rows: permission, state, swipe to Remove (which lets the
/// site ask again). Shared by Settings → Site Permissions, the
/// address-bar indicator's sheet and the trust sheet.
struct SitePermissionRows: View {
    let origin: String
    let store: SitePermissionStore

    var body: some View {
        ForEach(store.entries(origin: origin)) { entry in
            HStack {
                Label(entry.kind.label, systemImage: entry.kind.symbol)
                Spacer()
                Text(entry.state.label).foregroundStyle(.secondary)
            }
            .swipeActions {
                Button(role: .destructive) { store.revoke(origin: origin, kind: entry.kind) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

/// The site the address bar is showing and the store its decisions
/// live in — a private tab's own ephemeral store, else the shared one
/// (desktop: the indicator lists, and its Remove lifts, what applies in
/// the window you are looking at).
struct SitePermissionContext {
    let origin: String
    let store: SitePermissionStore

    @MainActor var entries: [SitePermissionEntry] { store.entries(origin: origin) }
}

/// Address-bar indicator for a site with remembered or embargoed
/// permissions; opens the per-site sheet.
struct SitePermissionIndicator: View {
    let context: SitePermissionContext
    @State private var showingSheet = false

    var body: some View {
        Button { showingSheet = true } label: {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Site permissions")
        .sheet(isPresented: $showingSheet) {
            SitePermissionsSheet(context: context)
        }
    }
}

/// "Permissions for this site" from the page, with Remove per row and
/// for the whole site.
struct SitePermissionsSheet: View {
    let context: SitePermissionContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SitePermissionRows(origin: context.origin, store: context.store)
                } header: {
                    Text(context.origin)
                } footer: {
                    Text("Removing a decision lets the site ask again. Decisions blocked after repeated dismissals last only for this session.")
                }
                if !context.entries.isEmpty {
                    Section {
                        Button("Remove all for this site", role: .destructive) {
                            context.store.revokeAll(origin: context.origin)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Site Permissions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
