import SwiftUI

struct FaviconView: View {
    let host: String?
    var size: CGFloat = 16

    @Environment(FaviconStore.self) private var faviconStore

    var body: some View {
        Group {
            if let image = faviconStore.image(for: host) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
