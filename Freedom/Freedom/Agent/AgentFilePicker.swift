import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A file the user chose for the agent to put into a page's file field.
struct AgentPickedFile {
    let data: Data
    let name: String
    let mimeType: String
}

/// browser_upload: the agent asked to attach a file; the user chooses one
/// (photo library or Files) or cancels. Choosing is the consent: only that
/// file goes to the page.
@MainActor
@Observable
final class AgentFilePrompt: Identifiable {
    let id = UUID()
    let site: String
    let field: String
    @ObservationIgnored private var continuation: CheckedContinuation<AgentPickedFile?, Never>?

    init(site: String, field: String) {
        self.site = site
        self.field = field
    }

    fileprivate func wait() async -> AgentPickedFile? {
        await withCheckedContinuation { continuation = $0 }
    }

    func choose(_ file: AgentPickedFile) { finish(file) }
    func cancel() { finish(nil) }

    private func finish(_ file: AgentPickedFile?) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: file)
    }

    /// Shows `prompt` through `present` and waits for the choice.
    static func ask(_ prompt: AgentFilePrompt, present: (AgentFilePrompt?) -> Void) async -> AgentPickedFile? {
        present(prompt)
        let file = await prompt.wait()
        present(nil)
        return file
    }
}

/// The picker over the agent's sheet.
struct AgentFileSheet: View {
    let prompt: AgentFilePrompt
    @State private var photo: PhotosPickerItem?
    @State private var showingFiles = false
    @State private var loading = false
    @State private var error: String?

    /// Desktop's per-file limit for attachments.
    static let maxBytes = 20 * 1024 * 1024

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("The agent wants to attach a file to \(prompt.field.isEmpty ? "a file field" : "“\(prompt.field)”") on \(prompt.site).")
                    .font(.headline)
                PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos])) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                Button {
                    showingFiles = true
                } label: {
                    Label("Files", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                if loading { ProgressView() }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Only the file you choose goes to this website.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .navigationTitle("Choose a file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { prompt.cancel() }
                }
            }
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    error = "That file couldn't be read."
                    return
                }
                let type = UTType(filenameExtension: url.pathExtension)
                deliver(AgentPickedFile(data: data, name: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream"))
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
        .presentationDetents([.medium])
    }

    private func load(_ item: PhotosPickerItem) async {
        loading = true
        defer { loading = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            error = "That item couldn't be loaded."
            return
        }
        let type = item.supportedContentTypes.first
        // Websites rarely take HEIC: images other than JPEG and PNG go as JPEG.
        if let type, type.conforms(to: .image), !type.conforms(to: .jpeg), !type.conforms(to: .png),
           let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
            deliver(AgentPickedFile(data: jpeg, name: "photo.jpg", mimeType: "image/jpeg"))
            return
        }
        let ext = type?.preferredFilenameExtension ?? "bin"
        deliver(AgentPickedFile(data: data, name: "\(type?.conforms(to: .movie) == true ? "video" : "photo").\(ext)", mimeType: type?.preferredMIMEType ?? "application/octet-stream"))
    }

    private func deliver(_ file: AgentPickedFile) {
        guard file.data.count <= Self.maxBytes else {
            error = "That file is larger than 20 MB."
            return
        }
        prompt.choose(file)
    }
}
