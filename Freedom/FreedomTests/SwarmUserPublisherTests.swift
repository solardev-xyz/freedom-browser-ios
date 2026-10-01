import SwiftData
import XCTest
@testable import Freedom

/// User-initiated publishing (desktop `freedom://publish`): payload
/// preparation from files / folders / text, the history row under the
/// `freedom://publish` origin, and tag-driven progress.
@MainActor
final class SwarmUserPublisherTests: XCTestCase {
    private var container: ModelContainer!
    private var history: SwarmPublishHistoryStore!
    private var uploads: [(path: String, contentType: String, headers: [String: String], query: [String: String], bytes: Int)] = []
    private var uploadError: Swift.Error?
    private var stamps: [PostageBatch] = []
    private var tags: [BeeAPIClient.TagResponse] = []
    private var keep: [AnyObject] = []
    private var tempDir: URL!

    override func setUp() async throws {
        container = try inMemoryContainer(for: SwarmPublishHistoryRecord.self)
        history = SwarmPublishHistoryStore(context: container.mainContext)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makePublisher() -> SwarmUserPublisher {
        let publisher = SwarmUserPublisher(
            publishService: SwarmPublishService(upload: { [unowned self] path, body, ct, headers, query in
                uploads.append((path, ct, headers, query, body.count))
                if let uploadError { throw uploadError }
                let json = try JSONSerialization.data(withJSONObject: ["reference": String(repeating: "ab", count: 32)])
                return (json, ["swarm-tag": "7"])
            }),
            history: history,
            currentStamps: { [unowned self] in stamps },
            getTag: { [unowned self] _ in
                guard !tags.isEmpty else { throw BeeAPIClient.Error.notRunning }
                return tags.removeFirst()
            }
        )
        keep.append(publisher)
        return publisher
    }

    private func armStamp() {
        stamps = [PostageBatch(
            batchID: String(repeating: "ee", count: 32), usable: true, usage: 0.1,
            effectiveBytes: 10_000_000, ttlSeconds: 86_400 * 30,
            isMutable: true, depth: 22, amount: "1000", label: nil
        )]
    }

    private func write(_ relative: String, _ content: String) throws {
        let url = tempDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func tag(sent: Int, split: Int) -> BeeAPIClient.TagResponse {
        .init(uid: 7, split: split, seen: split, stored: split, sent: sent, synced: 0)
    }

    // MARK: - Preparation

    func testTextBecomesASingleNamedUpload() throws {
        let payload = try SwarmUserPublisher.prepare(.text("hello"))
        XCTAssertEqual(payload.kind, .data)
        XCTAssertEqual(payload.name, "text.txt")
        XCTAssertEqual(payload.bytes, 5)
        guard case .single(_, let contentType, _) = payload.body else { return XCTFail() }
        XCTAssertTrue(contentType.hasPrefix("text/plain"))
    }

    func testFileKeepsItsNameAndMimeType() throws {
        try write("photo.png", "png-bytes")
        let payload = try SwarmUserPublisher.prepare(.file(tempDir.appendingPathComponent("photo.png")))
        guard case .single(let data, let contentType, let name) = payload.body else { return XCTFail() }
        XCTAssertEqual(name, "photo.png")
        XCTAssertEqual(contentType, "image/png")
        XCTAssertEqual(data, Data("png-bytes".utf8))
        XCTAssertEqual(SwarmUserPublisher.mimeType(for: URL(fileURLWithPath: "/x/blob.unknownext")), "application/octet-stream")
    }

    func testFolderBecomesASortedCollectionWithIndexDocument() throws {
        try write("index.html", "<h1>hi</h1>")
        try write("assets/app.js", "console.log(1)")
        try write(".DS_Store", "junk")
        let (entries, bytes) = try SwarmUserPublisher.collect(folder: tempDir)
        XCTAssertEqual(entries.map(\.path), ["assets/app.js", "index.html"])
        XCTAssertEqual(bytes, 14 + 11)

        let payload = try SwarmUserPublisher.prepare(.folder(tempDir))
        XCTAssertEqual(payload.kind, .files)
        XCTAssertEqual(payload.name, tempDir.lastPathComponent)
        guard case .collection(let tar, let index, _) = payload.body else { return XCTFail() }
        XCTAssertEqual(index, "index.html")
        XCTAssertEqual(tar.count % 512, 0)
    }

    func testFolderWithoutIndexHasNoIndexDocument() throws {
        try write("readme.txt", "x")
        let payload = try SwarmUserPublisher.prepare(.folder(tempDir))
        guard case .collection(_, let index, _) = payload.body else { return XCTFail() }
        XCTAssertNil(index)
    }

    func testEmptyFolderAndLongPathsAreRejected() throws {
        XCTAssertThrowsError(try SwarmUserPublisher.prepare(.folder(tempDir))) { error in
            XCTAssertEqual(error as? SwarmUserPublisher.Error, .emptyFolder)
        }
        let long = String(repeating: "d", count: 101) + ".txt"
        try write(long, "x")
        XCTAssertThrowsError(try SwarmUserPublisher.prepare(.folder(tempDir))) { error in
            XCTAssertEqual(error as? SwarmUserPublisher.Error, .pathTooLong(long))
        }
    }

    // MARK: - Publishing

    func testPublishTextRecordsHistoryUnderTheUserOriginAndFollowsTheTag() async throws {
        armStamp()
        tags = [tag(sent: 1, split: 4), tag(sent: 4, split: 4)]
        let publisher = makePublisher()
        await publisher.publish(.text("hello"))

        guard case .done(let result) = publisher.state else { return XCTFail("state \(publisher.state)") }
        XCTAssertEqual(result.reference, String(repeating: "ab", count: 32))
        XCTAssertEqual(result.bzzURL.absoluteString, "bzz://\(String(repeating: "ab", count: 32))/")
        XCTAssertEqual(uploads.count, 1)
        XCTAssertEqual(uploads[0].path, "/bzz")
        XCTAssertEqual(uploads[0].query["name"], "text.txt")
        XCTAssertEqual(uploads[0].headers["Swarm-Postage-Batch-Id"], stamps[0].batchID)
        XCTAssertTrue(tags.isEmpty, "polled until every chunk was sent")

        let row = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(row.origin, SwarmUserPublisher.userOrigin)
        XCTAssertEqual(row.kind, .data)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.tagUid, 7)
        XCTAssertEqual(row.bytesSize, 5)
    }

    func testPublishFolderSendsATarCollection() async throws {
        armStamp()
        try write("index.html", "<h1>hi</h1>")
        let publisher = makePublisher()
        await publisher.publish(.folder(tempDir))
        guard case .done = publisher.state else { return XCTFail("state \(publisher.state)") }
        XCTAssertEqual(uploads[0].contentType, "application/x-tar")
        XCTAssertEqual(uploads[0].headers["Swarm-Collection"], "true")
        XCTAssertEqual(uploads[0].headers["Swarm-Index-Document"], "index.html")
        XCTAssertEqual(history.entries.first?.kind, .files)
    }

    func testNoUsableStampFailsBeforeUploadingOrRecording() async {
        let publisher = makePublisher()
        await publisher.publish(.text("hello"))
        guard case .failed(let message) = publisher.state else { return XCTFail("state \(publisher.state)") }
        XCTAssertTrue(message.contains("stamp"))
        XCTAssertTrue(uploads.isEmpty)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testUploadFailureIsRecordedAsFailed() async {
        armStamp()
        uploadError = BeeAPIClient.Error.notRunning
        let publisher = makePublisher()
        await publisher.publish(.text("hello"))
        guard case .failed(let message) = publisher.state else { return XCTFail("state \(publisher.state)") }
        XCTAssertEqual(message, "The Swarm node isn't reachable.")
        XCTAssertEqual(history.entries.first?.status, .failed)
        publisher.reset()
        XCTAssertEqual(publisher.state, .idle)
    }

    func testAForgottenTagStillEndsDone() async {
        armStamp()
        tags = []
        let publisher = makePublisher()
        await publisher.publish(.text("hello"))
        guard case .done = publisher.state else { return XCTFail("state \(publisher.state)") }
    }
}
