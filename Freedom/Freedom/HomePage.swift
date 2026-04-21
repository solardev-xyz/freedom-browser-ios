import SwiftData
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

    // fetchLimit keeps the Recent query bounded — we only need enough rows to
    // surface 5 distinct URLs. Without a limit, every HomePage body re-eval
    // materialises the full HistoryEntry table.
    @Query(Self.recentDescriptor) private var history: [HistoryEntry]
    @Query(Self.bookmarksDescriptor) private var bookmarks: [Bookmark]

    @State private var isShowingHistory = false
    @State private var isShowingBookmarks = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !bookmarks.isEmpty {
                    bookmarksSection
                }
                if !recentDistinct.isEmpty {
                    recentSection
                }
                exploreSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $isShowingHistory) {
            HistoryView(onSelect: onNavigate)
        }
        .sheet(isPresented: $isShowingBookmarks) {
            BookmarksView(onSelect: onNavigate)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Freedom").font(.largeTitle).bold()
            Text("Browse the decentralized web via Swarm")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bookmarks").font(.headline)
                Spacer()
                Button("See all") { isShowingBookmarks = true }
                    .font(.subheadline)
            }
            ForEach(bookmarks, id: \.id) { bookmark in
                LaunchCard(
                    title: bookmark.displayTitle,
                    subtitle: bookmark.url.absoluteString,
                    url: bookmark.url
                ) {
                    if let classified = BrowserURL.classify(bookmark.url) {
                        onNavigate(classified)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                Button("See all") { isShowingHistory = true }
                    .font(.subheadline)
            }
            ForEach(recentDistinct, id: \.id) { entry in
                LaunchCard(
                    title: entry.displayTitle,
                    subtitle: entry.url.absoluteString,
                    url: entry.url
                ) {
                    if let classified = BrowserURL.classify(entry.url) {
                        onNavigate(classified)
                    }
                }
            }
        }
    }

    private var exploreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Explore").font(.headline)
            ForEach(ExploreEntry.mainnetCurated, id: \.self) { entry in
                LaunchCard(title: entry.title, subtitle: entry.subtitle, url: entry.url.url) {
                    onNavigate(entry.url)
                }
            }
        }
    }

    /// Top 5 history entries deduped by URL (most recent visit wins).
    private var recentDistinct: [HistoryEntry] {
        var seen = Set<URL>()
        var out: [HistoryEntry] = []
        for entry in history {
            guard !seen.contains(entry.url) else { continue }
            seen.insert(entry.url)
            out.append(entry)
            if out.count == 5 { break }
        }
        return out
    }

    private static var recentDescriptor: FetchDescriptor<HistoryEntry> {
        var d = FetchDescriptor<HistoryEntry>(
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        d.fetchLimit = 50
        return d
    }

    private static var bookmarksDescriptor: FetchDescriptor<Bookmark> {
        var d = FetchDescriptor<Bookmark>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        d.fetchLimit = 5
        return d
    }
}

private struct LaunchCard: View {
    let title: String
    let subtitle: String?
    let url: URL
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                FaviconView(host: url.host, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
