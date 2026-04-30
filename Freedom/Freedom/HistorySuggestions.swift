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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < matches.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
    }
}
