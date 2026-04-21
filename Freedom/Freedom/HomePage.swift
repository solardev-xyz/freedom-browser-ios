import SwiftUI

struct ExploreEntry: Hashable {
    let title: String
    let subtitle: String?
    let url: BrowserURL

    static let mainnetCurated: [ExploreEntry] = [
        ExploreEntry(
            title: "Swarmit",
            subtitle: "Decentralized social feed on Swarm",
            url: .bzz(URL(string: "bzz://c0b683a3be2593bc7e22d252a371bac921bf47d11c3f3c1680ee60e6b8ccfcc8")!)
        ),
    ]
}

struct HomePage: View {
    let onNavigate: (BrowserURL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                exploreSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Freedom").font(.largeTitle).bold()
            Text("Browse the decentralized web via Swarm")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Explore").font(.headline)
            ForEach(ExploreEntry.mainnetCurated, id: \.self) { entry in
                Button { onNavigate(entry.url) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).foregroundStyle(.primary)
                            if let sub = entry.subtitle {
                                Text(sub).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    HomePage { _ in }
}
