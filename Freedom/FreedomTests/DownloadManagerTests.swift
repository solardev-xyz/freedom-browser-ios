import XCTest
@testable import Freedom

/// Download bookkeeping: policy decision, filename collisions, state
/// transitions and the persisted index.
@MainActor
final class DownloadManagerTests: XCTestCase {
    private var keep: [DownloadManager] = []

    private func manager() -> DownloadManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
        let m = DownloadManager(directory: dir)
        keep.append(m)
        return m
    }

    func testResponsePolicyDownloadsUndisplayableOrAttachment() {
        XCTAssertTrue(BrowserTab.shouldDownload(canShowMIMEType: false, contentDisposition: nil))
        XCTAssertTrue(BrowserTab.shouldDownload(canShowMIMEType: true, contentDisposition: "attachment; filename=\"a.pdf\""))
        XCTAssertTrue(BrowserTab.shouldDownload(canShowMIMEType: true, contentDisposition: "Attachment"))
        XCTAssertFalse(BrowserTab.shouldDownload(canShowMIMEType: true, contentDisposition: "inline"))
        XCTAssertFalse(BrowserTab.shouldDownload(canShowMIMEType: true, contentDisposition: nil))
    }

    func testUniqueFilenames() {
        var taken: Set<String> = ["report.pdf", "report (2).pdf", "notes"]
        let exists: (String) -> Bool = { taken.contains($0) }
        XCTAssertEqual(DownloadManager.uniqueFilename("report.pdf", existing: exists), "report (3).pdf")
        XCTAssertEqual(DownloadManager.uniqueFilename("notes", existing: exists), "notes (2)")
        XCTAssertEqual(DownloadManager.uniqueFilename("fresh.zip", existing: exists), "fresh.zip")
        XCTAssertEqual(DownloadManager.uniqueFilename("../evil/../x.txt", existing: exists), "_.._evil_.._x.txt", "separators neutralised, no leading dot")
        XCTAssertEqual(DownloadManager.uniqueFilename(".hidden", existing: exists), "_.hidden")
        XCTAssertEqual(DownloadManager.uniqueFilename("   ", existing: exists), "download")
        taken.insert("download")
        XCTAssertEqual(DownloadManager.uniqueFilename("", existing: exists), "download (2)")
    }

    func testProgressCompletionAndFailureTransitions() throws {
        let m = manager()
        let id = UUID()
        // Seed an in-progress item the way adopt() does, without WebKit.
        let item = DownloadItem(id: id, sourceURL: "https://x.example/a.bin", filename: "a.bin", mimeType: nil,
                                bytesReceived: 0, totalBytes: nil, state: .inProgress, startedAt: Date(), finishedAt: nil)
        m.seedForTesting(item)
        m.applyProgress(id: id, received: 40, total: 100)
        XCTAssertEqual(m.item(id: id)?.fraction, 0.4)
        XCTAssertTrue(m.hasActive)
        m.markFailed(id: id, message: "lost connection", resumeData: Data([1]))
        XCTAssertEqual(m.item(id: id)?.state, .paused, "a failure with resume data is a pause")
        XCTAssertTrue(m.item(id: id)!.canResume)
        m.markFailed(id: id, message: "gone", resumeData: nil)
        XCTAssertEqual(m.item(id: id)?.state, .failed("gone"))
        let other = UUID()
        m.seedForTesting(DownloadItem(id: other, sourceURL: "https://x.example/b.bin", filename: "b.bin", mimeType: nil,
                                      bytesReceived: 10, totalBytes: 10, state: .inProgress, startedAt: Date(), finishedAt: nil))
        m.markCompleted(id: other)
        XCTAssertEqual(m.item(id: other)?.state, .completed)
        XCTAssertEqual(m.recentlyCompleted, other, "the shelf shows the completed item")
        XCTAssertFalse(m.hasActive)
    }

    func testIndexPersistsAndInterruptedDownloadsBecomeFailures() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadManagerTests-persist-\(UUID().uuidString)")
        let first = DownloadManager(directory: dir); keep.append(first)
        let done = UUID(), running = UUID()
        first.seedForTesting(DownloadItem(id: done, sourceURL: "https://x.example/a", filename: "a", mimeType: "text/plain",
                                          bytesReceived: 5, totalBytes: 5, state: .completed, startedAt: Date(), finishedAt: Date()))
        first.seedForTesting(DownloadItem(id: running, sourceURL: "https://x.example/b", filename: "b", mimeType: nil,
                                          bytesReceived: 1, totalBytes: 9, state: .inProgress, startedAt: Date(), finishedAt: nil))
        try? Data("hello".utf8).write(to: first.fileURL(for: first.item(id: done)!))
        let second = DownloadManager(directory: dir); keep.append(second)
        XCTAssertEqual(second.item(id: done)?.state, .completed)
        XCTAssertEqual(second.item(id: running)?.state, .failed("Interrupted"))
        second.remove(id: done)
        XCTAssertNil(second.item(id: done))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a").path), "remove deletes the file")
        second.clearAll()
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertTrue(DownloadManager(directory: dir).items.isEmpty)
    }
}
