import SwarmKit
import SwiftUI

/// Desktop's wallet-scan copy (freedom-browser #534), shown only while no
/// usable storage exists yet: what the node is still looking for is
/// registered only when the scan ends, so offering a plan before then
/// could sell storage the wallet already owns.
enum WalletScanCopy {
    /// The scan to tell the user about, if any: the node is still looking
    /// and the user has no usable storage yet.
    static func looking(_ scan: WalletScan?, hasUsableStorage: Bool) -> WalletScan? {
        guard let scan, scan.isLooking, !hasUsableStorage else { return nil }
        return scan
    }

    /// Floor of the progress, capped at 99 until the scan is done.
    static func percent(_ scan: WalletScan) -> Int? {
        scan.progress.map { min(99, Int(($0 * 100).rounded(.down))) }
    }

    /// Replaces the storage-plan offer and the empty-storage message.
    static func message(_ scan: WalletScan) -> String {
        if scan.isRetrying {
            return "The Swarm node couldn't finish looking for your existing storage and is trying again. Wait for it before you buy more."
        }
        if let percent = percent(scan) { return "Looking for your existing storage… \(percent)%" }
        return "Looking for your existing storage…"
    }

    /// The node card's subtitle under "Setup Swarm publishing".
    static func hint(_ scan: WalletScan) -> String {
        scan.isRetrying ? "Retrying the search for your existing storage" : "Looking for your existing storage…"
    }

    /// Above the stamps list while ant re-confirms an unverified scan.
    static let confirming = "Still confirming your storage history in the background."
}

/// `WalletScanCopy.message` as a card, with a spinner while it looks.
@MainActor
struct WalletScanNotice: View {
    let scan: WalletScan

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !scan.isRetrying {
                ProgressView()
            }
            Text(WalletScanCopy.message(scan))
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
