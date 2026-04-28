import XCTest
@testable import Freedom

final class TarBuilderTests: XCTestCase {
    /// Pinned mtime so tests are deterministic (mtime is the only
    /// per-build variable in the USTAR encoder).
    private let mtime = Date(timeIntervalSince1970: 0)

    // MARK: - Structural

    func testSingleFilePadsToHeaderPlusOneBlockPlusEndOfArchive() throws {
        let archive = try TarBuilder.build(
            entries: [.init(path: "hi.txt", bytes: Data("hi".utf8))],
            mtime: mtime
        )
        // 512 (header) + 512 (data block, "hi" padded to 512) + 1024
        // (two empty blocks marking end-of-archive).
        XCTAssertEqual(archive.count, 2048)
    }

    func testZeroByteFileStillRoundsToOneFullBlock() throws {
        let archive = try TarBuilder.build(
            entries: [.init(path: "empty", bytes: Data())],
            mtime: mtime
        )
        // Header (512) + zero data + zero pad (no padding when size
        // is already a multiple of 512) + 1024 end. = 1536
        XCTAssertEqual(archive.count, 1536)
    }

    func testTwoFilesEachPadIndependently() throws {
        let archive = try TarBuilder.build(
            entries: [
                .init(path: "a", bytes: Data(repeating: 0xAA, count: 600)),  // → 1024
                .init(path: "b", bytes: Data(repeating: 0xBB, count: 100)),  // → 512
            ],
            mtime: mtime
        )
        // (512 + 1024) + (512 + 512) + 1024 = 3584
        XCTAssertEqual(archive.count, 3584)
    }

    // MARK: - Header layout

    func testHeaderCarriesPathSizeMtimeAndUStarMagic() throws {
        let archive = try TarBuilder.build(
            entries: [.init(path: "hello.txt", bytes: Data("hi".utf8))],
            mtime: mtime
        )
        // Path lives at bytes 0..100, null-padded.
        let pathField = Array(archive[0..<100])
        XCTAssertEqual(Array(pathField.prefix(9)), Array("hello.txt".utf8))
        XCTAssertTrue(pathField.dropFirst(9).allSatisfy { $0 == 0 })

        // Size field (11 octal chars + null) at bytes 124..136.
        // "hi".count = 2 → "00000000002\0".
        let sizeField = Array(archive[124..<136])
        XCTAssertEqual(sizeField, Array("00000000002\0".utf8))

        // mtime is epoch 0 → all-zeros octal.
        let mtimeField = Array(archive[136..<148])
        XCTAssertEqual(mtimeField, Array("00000000000\0".utf8))

        // USTAR magic at 257..262 = "ustar".
        let magic = Array(archive[257..<262])
        XCTAssertEqual(magic, Array("ustar".utf8))

        // typeflag '0' (regular file) at byte 156.
        XCTAssertEqual(archive[156], 0x30)
    }

    func testHeaderChecksumReflectsAllOtherFields() throws {
        let archive = try TarBuilder.build(
            entries: [.init(path: "hi", bytes: Data())],
            mtime: mtime
        )
        // Recompute the checksum the way the spec dictates: sum every
        // byte of the header, treating the checksum field itself as 8
        // ASCII spaces.
        var headerCopy = Data(archive[0..<512])
        for i in 0..<8 { headerCopy[148 + i] = 0x20 }
        let expected = headerCopy.reduce(0) { $0 + Int($1) }

        // The encoder writes the checksum as 6 octal digits + null + space
        // at 148..156. Read those 6 digits back.
        let checksumField = Array(archive[148..<154])
        let checksumString = String(decoding: checksumField, as: UTF8.self)
        let read = Int(checksumString, radix: 8)
        XCTAssertEqual(read, expected)
        XCTAssertEqual(archive[154], 0)     // null terminator
        XCTAssertEqual(archive[155], 0x20)  // trailing space
    }

    func testEndOfArchiveIsTwoZeroBlocks() throws {
        let archive = try TarBuilder.build(
            entries: [.init(path: "a", bytes: Data("x".utf8))],
            mtime: mtime
        )
        // Last 1024 bytes are all zero.
        let tail = archive.suffix(1024)
        XCTAssertTrue(tail.allSatisfy { $0 == 0 })
    }

    // MARK: - Validation

    func testRejectsPathLongerThanUSTARLimit() {
        let longPath = String(repeating: "a", count: 101)
        XCTAssertThrowsError(try TarBuilder.build(
            entries: [.init(path: longPath, bytes: Data())],
            mtime: mtime
        )) { error in
            guard case TarBuilder.Error.pathTooLong = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAcceptsExactlyOneHundredCharPath() throws {
        let path = String(repeating: "a", count: 100)
        // Should not throw.
        _ = try TarBuilder.build(
            entries: [.init(path: path, bytes: Data())],
            mtime: mtime
        )
    }

    func testRejectsMultiByteUTF8PathExceedingByteLimit() {
        // 26 × U+1F600 (😀) = 26 chars but 4 bytes each = 104 bytes.
        // `String.count` (Characters) would mistakenly accept this; the
        // byte-count check rejects it before a silent truncation in the
        // header's 100-byte path field.
        let path = String(repeating: "\u{1F600}", count: 26)
        XCTAssertEqual(path.count, 26)
        XCTAssertEqual(path.utf8.count, 104)
        XCTAssertThrowsError(try TarBuilder.build(
            entries: [.init(path: path, bytes: Data())],
            mtime: mtime
        )) { error in
            guard case TarBuilder.Error.pathTooLong = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Determinism

    func testSameInputProducesByteIdenticalOutput() throws {
        let entries = [
            TarBuilder.Entry(path: "a.txt", bytes: Data("alpha".utf8)),
            TarBuilder.Entry(path: "b.css", bytes: Data("beta beta".utf8)),
        ]
        let first = try TarBuilder.build(entries: entries, mtime: mtime)
        let second = try TarBuilder.build(entries: entries, mtime: mtime)
        XCTAssertEqual(first, second)
    }
}
