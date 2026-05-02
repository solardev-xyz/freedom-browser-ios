import IPFSKit
import SwiftUI
import UIKit

/// Container view for the embedded IPFS (kubo) node — status, peer ID,
/// gateway, routing mode. Diagnostic logs hang off an unobtrusive footer
/// link, mirroring the Swarm `NodeHomeView` shape.
@MainActor
struct IpfsNodeHomeView: View {
    @Environment(IPFSNode.self) private var ipfs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard
                identityCard
                logsLink
            }
            .padding(20)
        }
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
                Text("\(ipfs.peerCount) peer\(ipfs.peerCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Identity").font(.caption).foregroundStyle(.secondary)
            // For now the kubo node uses the random RSA-2048 keypair it
            // generated on first repo init — recoverable across restarts
            // but distinct per device / install. Vault-derived Ed25519
            // identity is the next milestone (see project plan).
            row(
                label: "Peer ID",
                value: ipfs.peerID.isEmpty ? "—" : truncate(ipfs.peerID),
                copyable: ipfs.peerID.isEmpty ? nil : ipfs.peerID
            )
            row(label: "Source", value: "Random (anonymous)")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

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

    /// PeerIDs are 50+ chars; ellide the middle so both ends are visible.
    /// Same idiom the Swarm node sheet uses for long ENS names.
    private func truncate(_ s: String) -> String {
        guard s.count > 16 else { return s }
        return "\(s.prefix(8))…\(s.suffix(6))"
    }
}
