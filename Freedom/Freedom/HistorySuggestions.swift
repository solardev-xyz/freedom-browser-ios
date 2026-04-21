import SwiftUI

struct HistorySuggestion: Identifiable {
    var id: URL { url }
    let url: URL
    let title: String
    let timestamp: Date
    let isBookmark: Bool
}

struct HistorySuggestions: View {
    let matches: [HistorySuggestion]
    let onSelect: (HistorySuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                Button { onSelect(match) } label: {
                    HStack(spacing: 10) {
                        FaviconView(host: match.url.host)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(match.url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if match.isBookmark {
                            Image(systemName: "star.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < matches.count - 1 {
                    Divider()
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}
