import Foundation
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file the user attached to a chat (desktop's conversation attachments).
struct AgentAttachment: Codable, Identifiable, Equatable {
    /// `attachment_<20 hex>`, desktop's resource ID shape.
    let id: String
    let name: String
    let mimeType: String
    let bytes: Int

    enum Kind: String { case image, pdf, text, other }

    var kind: Kind {
        let type = UTType(mimeType: mimeType)
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .pdf) == true { return .pdf }
        if mimeType.hasPrefix("text/") || type?.conforms(to: .text) == true || type?.conforms(to: .json) == true
            || type?.conforms(to: .xml) == true || type?.conforms(to: .sourceCode) == true { return .text }
        return .other
    }

    var icon: String {
        switch kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .other: "doc"
        }
    }

    var info: [String: Any] {
        ["resourceId": id, "name": name, "mimeType": mimeType, "bytes": bytes, "kind": kind.rawValue]
    }
}

/// Chat attachments on disk (Application Support/Agent/attachments): files
/// staged in the composer, then moved under their chat when the message is
/// sent. The engine's `attachments` service reads them for the attachment
/// tools: bounded text, images (for models that accept them), PDF text and
/// PDF pages as images.
@MainActor
final class AgentAttachmentStore {
    enum StoreError: LocalizedError {
        case tooLarge, tooMany, unknown, unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "Attachments are limited to 20 MB each and 50 MB per message."
            case .tooMany: "Attach at most 10 files per message."
            case .unknown: "RESOURCE_NOT_FOUND: no attachment with that ID in this chat. Use attachment_list."
            case .unreadable(let reason): reason
            }
        }
    }

    static let maxFileBytes = 20 * 1024 * 1024
    static let maxMessageBytes = 50 * 1024 * 1024
    static let maxFiles = 10
    private static let maxTextBytes = 256 * 1024
    nonisolated private static let maxImageSide: CGFloat = 1568

    private let root = AgentDatabase.directory.appending(path: "attachments")
    private var staged: URL { root.appending(path: "staged") }

    private func chatDirectory(_ chatID: String) -> URL { root.appending(path: chatID) }
    private func indexURL(_ chatID: String) -> URL { chatDirectory(chatID).appending(path: "index.json") }

    // MARK: Composer

    func stage(data: Data, name: String, mimeType: String, alreadyStaged: [AgentAttachment]) throws -> AgentAttachment {
        guard alreadyStaged.count < Self.maxFiles else { throw StoreError.tooMany }
        guard data.count <= Self.maxFileBytes,
              alreadyStaged.reduce(0, { $0 + $1.bytes }) + data.count <= Self.maxMessageBytes else { throw StoreError.tooLarge }
        let id = "attachment_" + (0..<10).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try data.write(to: staged.appending(path: id), options: .completeFileProtection)
        return AgentAttachment(id: id, name: Self.cleanName(name), mimeType: mimeType, bytes: data.count)
    }

    func unstage(_ attachment: AgentAttachment) {
        try? FileManager.default.removeItem(at: staged.appending(path: attachment.id))
    }

    /// The message went out: its staged files belong to the chat now.
    func commit(_ attachments: [AgentAttachment], to chatID: Int) throws {
        guard !attachments.isEmpty else { return }
        let chat = String(chatID)
        try FileManager.default.createDirectory(at: chatDirectory(chat), withIntermediateDirectories: true)
        for attachment in attachments {
            try FileManager.default.moveItem(at: staged.appending(path: attachment.id), to: chatDirectory(chat).appending(path: attachment.id))
        }
        let index = list(chat) + attachments
        try JSONEncoder().encode(index).write(to: indexURL(chat))
    }

    func forget(chatID: Int) {
        try? FileManager.default.removeItem(at: chatDirectory(String(chatID)))
    }

    func forgetAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// An attachment of `chat` with its bytes (for publishing it).
    func file(chat: String, id: String) -> (attachment: AgentAttachment, data: Data)? {
        guard let attachment = list(chat).first(where: { $0.id == id }),
              let data = try? Data(contentsOf: chatDirectory(chat).appending(path: id)) else { return nil }
        return (attachment, data)
    }

    private func list(_ chat: String) -> [AgentAttachment] {
        (try? Data(contentsOf: indexURL(chat))).flatMap { try? JSONDecoder().decode([AgentAttachment].self, from: $0) } ?? []
    }

    private static func cleanName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").filter { !$0.isNewline }
        return String((cleaned.isEmpty ? "file" : cleaned).prefix(120))
    }

    /// A smaller JPEG of an image, at most `maxImageSide` on its long side.
    static func jpeg(_ data: Data, maxSide: CGFloat = maxImageSide) -> (data: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8).map { ($0, Int(size.width), Int(size.height)) }
    }

    /// Images of staged attachments for the message itself (vision models see them at once).
    func images(of attachments: [AgentAttachment]) -> [[String: Any]] {
        attachments.filter { $0.kind == .image }.prefix(4).compactMap { attachment in
            guard let data = try? Data(contentsOf: staged.appending(path: attachment.id)), let image = Self.jpeg(data) else { return nil }
            return ["resourceId": attachment.id, "mimeType": "image/jpeg", "base64": image.data.base64EncodedString()]
        }
    }

    // MARK: Engine service

    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        guard let chat = (params["chatId"] as? NSNumber)?.stringValue ?? params["chatId"] as? String else { throw StoreError.unknown }
        let attachments = list(chat)
        if method == "list" { return ["resources": attachments.map(\.info)] }
        guard let attachment = attachments.first(where: { $0.id == params["resourceId"] as? String }) else { throw StoreError.unknown }
        let file = chatDirectory(chat).appending(path: attachment.id)
        switch method {
        case "read": return try read(attachment, file: file, params)
        case "renderPage": return try renderPage(attachment, file: file, page: (params["page"] as? NSNumber)?.intValue ?? 1)
        default: throw AgentEngine.EngineError.tool("Unknown attachments method: \(method)")
        }
    }

    private func read(_ attachment: AgentAttachment, file: URL, _ params: [String: Any]) throws -> [String: Any] {
        let base = ["resourceId": attachment.id, "name": attachment.name] as [String: Any]
        switch attachment.kind {
        case .image:
            guard let data = try? Data(contentsOf: file), let image = Self.jpeg(data) else { throw StoreError.unreadable("The image couldn't be read.") }
            return base.merging(["kind": "image", "mimeType": "image/jpeg", "base64": image.data.base64EncodedString(), "width": image.width, "height": image.height]) { a, _ in a }
        case .pdf:
            guard let document = PDFDocument(url: file) else { throw StoreError.unreadable("The PDF couldn't be opened.") }
            let first = max(1, (params["page"] as? NSNumber)?.intValue ?? 1)
            let count = min(4, max(1, (params["pageCount"] as? NSNumber)?.intValue ?? 1))
            guard first <= document.pageCount else { throw StoreError.unreadable("The PDF has \(document.pageCount) pages.") }
            let pages = (first..<min(first + count, document.pageCount + 1)).map { number -> [String: Any] in
                let text = document.page(at: number - 1)?.string ?? ""
                return ["page": number, "text": String(text.prefix(40_000))]
            }
            var result = base.merging(["kind": "pdf", "pageCount": document.pageCount, "pages": pages]) { a, _ in a }
            if pages.allSatisfy({ ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                result["note"] = "No extractable text on these pages (a scan?). attachment_render_page shows a page as an image."
            }
            return result
        case .text, .other:
            guard let data = try? Data(contentsOf: file) else { throw StoreError.unreadable("The file couldn't be read.") }
            if attachment.kind == .other, String(data: data.prefix(4096), encoding: .utf8) == nil {
                throw StoreError.unreadable("UNSUPPORTED_ATTACHMENT: \(attachment.name) is a \(attachment.mimeType) file, which can't be read as text.")
            }
            let text = String(decoding: data, as: UTF8.self)
            let offset = max(0, (params["offset"] as? NSNumber)?.intValue ?? 0)
            let limit = min(Self.maxTextBytes, max(1, (params["limit"] as? NSNumber)?.intValue ?? 20_000))
            let characters = Array(text)
            let start = min(offset, characters.count)
            let end = min(characters.count, start + limit)
            var result = base.merging(["kind": "text", "text": String(characters[start..<end]), "offset": start, "totalChars": characters.count]) { a, _ in a }
            if end < characters.count { result["nextOffset"] = end }
            return result
        }
    }

    private func renderPage(_ attachment: AgentAttachment, file: URL, page: Int) throws -> [String: Any] {
        guard attachment.kind == .pdf, let document = PDFDocument(url: file) else { throw StoreError.unreadable("Only PDF attachments have pages.") }
        guard page >= 1, page <= document.pageCount, let pdfPage = document.page(at: page - 1) else {
            throw StoreError.unreadable("The PDF has \(document.pageCount) pages.")
        }
        let bounds = pdfPage.bounds(for: .mediaBox)
        let scale = Self.maxImageSide / max(bounds.width, bounds.height)
        let image = pdfPage.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { throw StoreError.unreadable("The page couldn't be rendered.") }
        return ["resourceId": attachment.id, "name": attachment.name, "page": page, "pageCount": document.pageCount, "mimeType": "image/jpeg", "base64": jpeg.base64EncodedString()]
    }
}

// MARK: - Composer

/// The composer's paperclip: photos or files to send with the next message.
struct AgentAttachButton: View {
    @Environment(AgentService.self) private var agent
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var photos: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showingPhotos = true }
            Button("Files", systemImage: "folder") { showingFiles = true }
        } label: {
            Image(systemName: "paperclip").font(.title3)
        }
        .disabled(agent.phase != .ready)
        .photosPicker(isPresented: $showingPhotos, selection: $photos, maxSelectionCount: AgentAttachmentStore.maxFiles, matching: .images)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let type = UTType(filenameExtension: url.pathExtension)
                agent.stageAttachment(data: data, name: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
            }
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                for (index, item) in items.enumerated() {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    // Photos go as JPEG (HEIC is rarely understood).
                    let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) ?? data
                    agent.stageAttachment(data: jpeg, name: items.count == 1 ? "photo.jpg" : "photo-\(index + 1).jpg", mimeType: "image/jpeg")
                }
            }
        }
    }
}

/// The attachments waiting to go with the next message.
struct AgentStagedAttachments: View {
    @Environment(AgentService.self) private var agent

    var body: some View {
        if !agent.stagedAttachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(agent.stagedAttachments) { attachment in
                        HStack(spacing: 4) {
                            Image(systemName: attachment.icon)
                            Text(attachment.name).lineLimit(1)
                            Button("Remove", systemImage: "xmark.circle.fill") { agent.unstageAttachment(attachment) }
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                    }
                }
            }
        }
    }
}

/// A sent message's attachments, from the note the engine adds to its text.
enum AgentAttachmentNote {
    static let marker = "\n\nAttached files"

    /// The message text without the note, and the attached files' names.
    static func split(_ text: String) -> (text: String, names: [String]) {
        guard let range = text.range(of: marker) else { return (text, []) }
        let note = String(text[range.upperBound...])
        let names = note.matches(of: /([^;:]+?) \(attachment_[0-9a-f]{20}/).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
        return (String(text[..<range.lowerBound]), names)
    }
}
