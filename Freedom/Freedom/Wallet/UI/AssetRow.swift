import BigInt
import SwiftUI

/// One row in the wallet's asset list. Logo + symbol/name on the leading
/// side, formatted balance trailing. Tap target is wired by the parent
/// (NavigationLink in `WalletHomeView`); this view itself is just the
/// label.
@MainActor
struct AssetRow: View {
    let token: Token
    let balance: BigUInt

    var body: some View {
        // Subtitle slot intentionally empty — symbol is the bold leading
        // label, amount on the trailing side already implies the asset.
        // Reserved for an "All chains" rollup view where the chain name
        // would belong here.
        HStack(spacing: 12) {
            logo
            Text(token.symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            Text(BalanceFormatter.formatAmount(wei: balance, decimals: token.decimals))
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var logo: some View {
        if let image = bundledLogo {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(Circle())
        } else {
            // Fallback for tokens without a bundled logo (custom tokens,
            // future): tinted circle with the symbol's first letter.
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 28, height: 28)
                .overlay {
                    Text(String(token.symbol.prefix(1)))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }

    private var bundledLogo: UIImage? {
        guard let asset = token.logoAsset else { return nil }
        return UIImage(named: asset)
    }
}
