import SwiftUI

/// Leading address-bar icon on web pages: opens the "This Site" sheet
/// (ad blocking on/off for the site, its permissions). Orange while ad
/// blocking is off for the site; the private-tab glyph in private tabs.
struct SiteSettingsButton: View {
    let host: String
    var permissions: SitePermissionContext? = nil
    var isPrivate: Bool = false
    /// Reload the page after the site's blocking changed.
    let onReload: () -> Void

    @Environment(AdblockService.self) private var adblock
    @State private var showingSheet = false

    var body: some View {
        let blockingOff = adblock.isAllowlisted(host: host)
        Button { showingSheet = true } label: {
            Image(systemName: isPrivate ? "eye.slash.fill" : "gearshape")
                .font(.system(size: 16))
                .foregroundStyle(blockingOff ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPrivate ? "Private tab, settings for this site" : "Settings for this site")
        .sheet(isPresented: $showingSheet) {
            SiteSettingsSheet(host: host, permissions: permissions, onReload: onReload)
        }
        #if DEBUG
        // FREEDOM_DEBUG_SHOW=site opens the sheet for screenshots.
        .task {
            if ProcessInfo.processInfo.environment["FREEDOM_DEBUG_SHOW"] == "site" {
                try? await Task.sleep(for: .seconds(2))
                showingSheet = true
            }
        }
        #endif
    }
}

/// Per-site controls, Safari's "Website Settings": ad blocking for this
/// site and the permissions it holds.
struct SiteSettingsSheet: View {
    let host: String
    var permissions: SitePermissionContext? = nil
    let onReload: () -> Void

    @Environment(AdblockService.self) private var adblock
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: blockingBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ad blocking")
                            Text("Ads, trackers and scriptlets on this site")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!adblock.isAnyCategoryEnabled)
                } footer: {
                    Text(blockingFooter)
                }

                if let permissions {
                    Section {
                        if permissions.entries.isEmpty {
                            Text("This site hasn't asked for anything yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            SitePermissionRows(origin: permissions.origin, store: permissions.store)
                            Button("Remove all for this site", role: .destructive) {
                                permissions.store.revokeAll(origin: permissions.origin)
                            }
                        }
                    } header: {
                        Text("Permissions")
                    } footer: {
                        if !permissions.entries.isEmpty {
                            Text("Removing a decision lets the site ask again.")
                        }
                    }
                }
            }
            .navigationTitle(host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// On = the site isn't allowlisted. Either way the page reloads, so
    /// the rules and scriptlets apply (or stop) right away.
    private var blockingBinding: Binding<Bool> {
        Binding(
            get: { !adblock.isAllowlisted(host: host) },
            set: { on in
                if on {
                    adblock.removeAllowlist(covering: host)
                } else {
                    adblock.addAllowlist(domain: host)
                }
                onReload()
            }
        )
    }

    private var blockingFooter: String {
        if !adblock.isAnyCategoryEnabled {
            return "Every filter list is off in Settings → Ad Blocking."
        }
        if let entry = adblock.allowlistEntry(covering: host), entry != adblock.normalizedHost(host) {
            return "Off for all of \(entry). Turning it on here turns it back on there too."
        }
        return "Turning it off allows ads, trackers and scriptlets on \(adblock.normalizedHost(host) ?? host) and reloads the page. All exceptions are listed in Settings → Ad Blocking."
    }
}
