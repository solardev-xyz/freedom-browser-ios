import IPFSKit
import SwiftUI
import UIKit

/// Container view for the embedded IPFS reader (Rust `freedom-ipfs`):
/// status, gateway URL, cache health, retrieval/routing counters, and
/// active preloads. The reader is a read-only browser path — there is
/// no PeerID and no libp2p peer set, so the previous identity card
/// has been replaced with diagnostics-derived health rows.
@MainActor
struct IpfsNodeHomeView: View {
    @Environment(IPFSNode.self) private var ipfs
    @Environment(SettingsStore.self) private var settings

    @State private var isShowingClearCacheConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                enableCard
                if settings.ipfsNodeEnabled {
                    statusCard
                    cacheCard
                    retrievalCard
                    routingCard
                    debugCard
                    logsLink
                }
            }
            .padding(20)
        }
    }

    /// Top-level enable/disable. Toggle ON kicks off a runtime boot of
    /// the Rust gateway with the current settings; toggle OFF stops
    /// the gateway and clears the in-memory diagnostics.
    private var enableCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable")
                    .font(.headline)
                Text("Run the embedded IPFS reader")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enable", isOn: enableBinding)
                .labelsHidden()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { settings.ipfsNodeEnabled },
            set: { newValue in
                settings.ipfsNodeEnabled = newValue
                if newValue {
                    let config = settings.ipfsConfig(dataDir: IPFSNode.defaultDataDir())
                    ipfs.start(config)
                } else {
                    ipfs.stop()
                }
            }
        )
    }

    // MARK: - Cards

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Circle()
                    .frame(width: 10, height: 10)
                    .foregroundStyle(ipfs.status.color)
                Text(ipfs.status.rawValue)
                    .font(.headline)
                    .monospaced()
                Spacer()
            }
            Divider().opacity(0.3)
            row(label: "Routing", value: ipfs.activeRoutingMode.rawValue)
            row(label: "Power", value: ipfs.activeLowPower ? "low" : "default")
            if let url = ipfs.gatewayURL {
                Divider().opacity(0.3)
                row(label: "Gateway", value: url.absoluteString, copyable: url.absoluteString)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var cacheCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cache").font(.caption).foregroundStyle(.secondary)
            row(label: "Blocks", value: "\(diagnostics?.stats.blockCount ?? 0)")
            row(
                label: "Size",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(diagnostics?.stats.totalBytes ?? 0),
                    countStyle: .file
                )
            )
            row(label: "Active preloads", value: "\(diagnostics?.activePreloadCount ?? 0)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var retrievalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retrieval").font(.caption).foregroundStyle(.secondary)
            row(label: "Cache hits", value: "\(diagnostics?.retrievalStats.cacheHits ?? 0)")
            row(label: "HTTP provider blocks", value: "\(diagnostics?.retrievalStats.httpProviderBlocks ?? 0)")
            row(label: "Bitswap blocks", value: "\(diagnostics?.retrievalStats.bitswapBlocks ?? 0)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Routing").font(.caption).foregroundStyle(.secondary)
            row(label: "Delegated lookups", value: "\(diagnostics?.routingStats.delegatedProviderLookups ?? 0)")
            row(label: "Delegated results", value: "\(diagnostics?.routingStats.delegatedProviderResults ?? 0)")
            row(label: "Delegated errors", value: "\(diagnostics?.routingStats.delegatedProviderErrors ?? 0)")
            Divider().opacity(0.3)
            row(label: "DHT lookups", value: "\(diagnostics?.routingStats.dhtProviderLookups ?? 0)")
            row(label: "DHT results", value: "\(diagnostics?.routingStats.dhtProviderResults ?? 0)")
            row(label: "DHT errors", value: "\(diagnostics?.routingStats.dhtProviderErrors ?? 0)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Advanced/debug actions for physical-device triage. Disabled
    /// when the gateway isn't running because the underlying calls
    /// are no-ops in that state.
    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug").font(.caption).foregroundStyle(.secondary)
            Button {
                ipfs.resetRoutingState()
            } label: {
                Label("Reset routing state", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(ipfs.status != .running)

            Button(role: .destructive) {
                isShowingClearCacheConfirm = true
            } label: {
                Label("Clear cache", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(ipfs.status != .running)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .confirmationDialog(
            "Clear IPFS cache?",
            isPresented: $isShowingClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear cache", role: .destructive) {
                _ = ipfs.clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes cached IPFS blocks. Future loads will start from a cold cache.")
        }
    }

    private var diagnostics: FreedomIpfsDiagnostics? { ipfs.diagnostics }

    private var logsLink: some View {
        NavigationLink {
            IpfsNodeLogView()
        } label: {
            HStack {
                Text("Diagnostic logs")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Row helpers

    private func row(label: String, value: String, copyable: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .monospaced()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let copyable {
                Button {
                    UIPasteboard.general.string = copyable
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }
}
