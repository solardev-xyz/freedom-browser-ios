import SwiftUI
import UniformTypeIdentifiers

/// Closes whichever presentation hosts the node pages (the Nodes drawer
/// or the standalone Swarm node sheet) — a pushed page's own `dismiss`
/// would only pop it.
struct DismissNodesUIKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var dismissNodesUI: () -> Void {
        get { self[DismissNodesUIKey.self] }
        set { self[DismissNodesUIKey.self] = newValue }
    }
}

/// Publish on Swarm — desktop's `freedom://publish` page. A file, a
/// folder or typed text goes through the node under the
/// `freedom://publish` origin; the result offers the `bzz://` URL to
/// copy or open, and the recent publishes sit underneath.
@MainActor
struct SwarmPublishView: View {
    @Environment(SwarmUserPublisher.self) private var publisher
    @Environment(SwarmPublishHistoryStore.self) private var history
    @Environment(StampService.self) private var stampService
    @Environment(TabStore.self) private var tabStore
    @Environment(\.dismissNodesUI) private var dismissNodesUI

    @State private var pickingFile = false
    @State private var pickingFolder = false
    @State private var composingText = false
    @State private var text = ""
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !stampService.hasUsableStamps {
                    noStampsBanner
                }
                switch publisher.state {
                case .idle:
                    if composingText { textComposer } else { actions }
                case .uploading(let label, let progress):
                    progressCard(label: label, progress: progress)
                case .done(let result):
                    resultCard(result)
                case .failed(let message):
                    errorCard(message)
                }
                recentPublishes
            }
            .padding(20)
        }
        .navigationTitle("Publish on Swarm")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { start(.file(url)) }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { start(.folder(url)) }
        }
        .onDisappear { if case .done = publisher.state { publisher.reset() } }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upload content to the decentralized web.")
                .font(.callout)
                .foregroundStyle(.secondary)
            actionCard(icon: "doc", title: "Publish a file", subtitle: "Pick a file from this device") {
                pickingFile = true
            }
            actionCard(icon: "folder", title: "Publish a folder", subtitle: "A site or a set of files; index.html becomes the front page") {
                pickingFolder = true
            }
            actionCard(icon: "text.alignleft", title: "Publish text", subtitle: "Type or paste something to publish") {
                composingText = true
            }
        }
    }

    private func actionCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout).fontWeight(.semibold)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!stampService.hasUsableStamps)
    }

    private var textComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Enter text or paste data to publish…")
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
            PrimaryActionButton(title: "Publish", systemImage: "arrow.up.circle") {
                start(.text(text))
            }
            .disabled(text.isEmpty)
            Button("Cancel") { composingText = false; text = "" }
                .frame(maxWidth: .infinity)
        }
    }

    private var noStampsBanner: some View {
        NavigationLink {
            StampsView()
        } label: {
            Label("No usable postage stamp. Buy one to publish.", systemImage: "shippingbox")
                .font(.callout)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress / result / error

    private func progressCard(label: String, progress: Int?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProgressView()
                Text(progress.map { "\(label) \($0)%" } ?? label)
            }
            if let progress {
                ProgressView(value: Double(progress), total: 100)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func resultCard(_ result: SwarmUserPublisher.Result) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Published", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let name = result.name {
                Text(name).font(.callout).lineLimit(1).truncationMode(.middle)
            }
            Text(result.bzzURL.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(copied == "url" ? "Copied" : "Copy URL") { copy(result.bzzURL.absoluteString, tag: "url") }
                Button(copied == "ref" ? "Copied" : "Copy reference") { copy(result.reference, tag: "ref") }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            PrimaryActionButton(title: "Open", systemImage: "safari") {
                tabStore.open(result.bzzURL, inBackground: false, from: nil)
                dismissNodesUI()
            }
            Button("Publish another") { publisher.reset(); composingText = false; text = "" }
                .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Try again") { publisher.reset() }
                .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - History

    private var recentPublishes: some View {
        let entries = history.entries.prefix(3)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent publishes").font(.headline)
                Spacer()
                if !history.entries.isEmpty {
                    NavigationLink("See all") { SwarmPublishHistoryView() }
                        .font(.callout)
                }
            }
            if entries.isEmpty {
                Text("No publishes yet").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(entries)) { entry in
                NavigationLink {
                    SwarmPublishHistoryDetailView(entryId: entry.id)
                } label: {
                    SwarmPublishHistoryCard(entry: entry)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func start(_ source: SwarmUserPublisher.Source) {
        composingText = false
        copied = nil
        publisher.start(source)
    }

    private func copy(_ value: String, tag: String) {
        UIPasteboard.general.string = value
        copied = tag
    }
}
