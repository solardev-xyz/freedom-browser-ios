import SwiftUI

/// Renders an ENS primary name with a trust indicator. The amber-warning
/// `.unverified` arm is the load-bearing one: it surfaces UR's
/// `ReverseAddressMismatch` revert (on-chain reverse record points at a
/// name that does NOT forward-resolve to the address — a spoofed claim).
struct ENSNameLabel: View {
    let resolution: ENSReverseResolution

    var body: some View {
        switch resolution {
        case .none:
            EmptyView()
        case .verified(let name):
            HStack(spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 4)
            .accessibilityLabel(Text("\(name), verified primary name"))
        case .unverified(let claimedName):
            HStack(spacing: 4) {
                Text(claimedName ?? "unverified primary name")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(.horizontal, 4)
            .accessibilityLabel(Text("Unverified primary name claim: \(claimedName ?? "unknown")"))
        }
    }
}
