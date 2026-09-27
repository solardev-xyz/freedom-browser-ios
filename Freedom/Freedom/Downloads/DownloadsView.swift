import QuickLook
import SwiftUI
import WebKit

/// The downloads page: every tracked download with progress, pause /
/// resume / cancel, open (Quick Look), share (incl. Save to Files) and
/// remove; Clear All.
struct DownloadsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TabStore.self) private var tabStore
    @State private var manager = DownloadManager.shared
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Files you download appear here."))
                } else {
                    List {
                        ForEach(manager.items) { item in
                            DownloadRow(item: item, manager: manager, fallbackWebView: tabStore.activeTab?.webView) {
                                previewURL = manager.fileURL(for: item)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { manager.remove(id: manager.items[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if !manager.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All", role: .destructive) { manager.clearAll() }
                    }
                }
            }
            .quickLookPreview($previewURL)
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let manager: DownloadManager
    let fallbackWebView: WKWebView?
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.filename.isEmpty ? "Preparing…" : item.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
            Text(item.sourceURL).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if item.isActive || item.canResume {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                } else if item.isActive {
                    ProgressView()
                }
            }
            HStack(spacing: 16) {
                switch item.state {
                case .inProgress:
                    Button("Pause") { manager.pause(id: item.id) }
                    Button("Cancel", role: .destructive) { manager.cancel(id: item.id) }
                case .paused:
                    Button("Resume") { manager.resume(id: item.id, fallback: fallbackWebView) }
                    Button("Remove", role: .destructive) { manager.remove(id: item.id) }
                case .completed:
                    Button("Open", action: open)
                    ShareLink(item: manager.fileURL(for: item)) { Text("Share") }
                    Button("Remove", role: .destructive) { manager.remove(id: item.id) }
                case .failed, .cancelled:
                    Button("Remove", role: .destructive) { manager.remove(id: item.id) }
                }
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        let received = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
        switch item.state {
        case .inProgress:
            if let total = item.totalBytes {
                return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
            }
            return received
        case .paused: return "Paused · \(received)"
        case .completed: return ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
        case .failed(let message): return "Failed · \(message)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Compact card above the bottom chrome while a download runs, and for
/// a few seconds after one completes (Open / Show all). Files are never
/// opened automatically.
struct DownloadShelf: View {
    @State private var manager = DownloadManager.shared
    let showAll: () -> Void
    @State private var previewURL: URL?

    private var current: DownloadItem? {
        if let active = manager.items.first(where: { $0.isActive }) { return active }
        if let id = manager.recentlyCompleted { return manager.item(id: id) }
        return nil
    }

    var body: some View {
        if let item = current {
            HStack(spacing: 10) {
                Image(systemName: item.isActive ? "arrow.down.circle" : "checkmark.circle.fill")
                    .foregroundStyle(item.isActive ? Color.accentColor : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename.isEmpty ? "Downloading…" : item.filename)
                        .font(.footnote.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if item.isActive, let fraction = item.fraction {
                        ProgressView(value: fraction).controlSize(.mini)
                    } else if item.isActive {
                        Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Downloaded").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if item.isActive {
                    Button("Cancel", role: .destructive) { manager.cancel(id: item.id) }
                } else {
                    Button("Open") { previewURL = manager.fileURL(for: item) }
                    Button { manager.dismissShelf() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss")
                }
                Button("All", action: showAll)
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .quickLookPreview($previewURL)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
