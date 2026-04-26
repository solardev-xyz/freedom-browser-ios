import SwiftUI
import UIKit

/// Bundled-PNG logo with a tinted symbol-initial fallback. Used by
/// `AssetRow`, `SendFlowView`'s From row, and `AssetPickerView`.
@MainActor
struct TokenLogo: View {
    let token: Token
    var size: CGFloat = 28

    var body: some View {
        if let asset = token.logoAsset, let image = UIImage(named: asset) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: size, height: size)
                .overlay {
                    Text(String(token.symbol.prefix(1)))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
        }
    }
}
