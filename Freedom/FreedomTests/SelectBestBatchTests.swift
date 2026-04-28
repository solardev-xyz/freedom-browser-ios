import XCTest
@testable import Freedom

final class SelectBestBatchTests: XCTestCase {
    private func batch(
        id: String = UUID().uuidString,
        usable: Bool = true,
        usage: Double = 0,
        effectiveBytes: Int = 1_000_000,
        ttlSeconds: Int = 86_400
    ) -> PostageBatch {
        PostageBatch(
            batchID: id, usable: usable, usage: usage,
            effectiveBytes: effectiveBytes, ttlSeconds: ttlSeconds,
            isMutable: true, depth: 22, amount: "0", label: nil
        )
    }

    func testReturnsNilForEmptyStampList() {
        XCTAssertNil(StampService.selectBestBatch(forBytes: 1_000, in: []))
    }

    func testSkipsNonUsableBatches() {
        let only = [batch(usable: false, effectiveBytes: 10_000_000)]
        XCTAssertNil(StampService.selectBestBatch(forBytes: 1_000, in: only))
    }

    func testRequiresSizeSafetyMarginOfRoom() {
        // Exactly `bytes × StampService.sizeSafetyMargin` qualifies;
        // 1 byte less doesn't.
        let target = 1_000
        let exactRequired = Int(Double(target) * StampService.sizeSafetyMargin)
        let exact = batch(effectiveBytes: exactRequired)
        XCTAssertNotNil(StampService.selectBestBatch(forBytes: target, in: [exact]))

        let oneByteShort = batch(effectiveBytes: exactRequired - 1)
        XCTAssertNil(StampService.selectBestBatch(forBytes: target, in: [oneByteShort]))
    }

    func testUsageReducesRemainingCapacity() {
        // 2 MB batch, 80% used → 0.4 MB remaining, doesn't fit a 1 MB upload.
        let mostlyFull = batch(usage: 0.8, effectiveBytes: 2_000_000)
        XCTAssertNil(StampService.selectBestBatch(forBytes: 1_000_000, in: [mostlyFull]))
    }

    func testPicksLongestTTLAmongQualifiers() {
        let shortLived = batch(id: "short", effectiveBytes: 10_000_000, ttlSeconds: 3_600)
        let longLived = batch(id: "long", effectiveBytes: 10_000_000, ttlSeconds: 86_400)
        let mediumLived = batch(id: "medium", effectiveBytes: 10_000_000, ttlSeconds: 7_200)
        let picked = StampService.selectBestBatch(
            forBytes: 1_000, in: [shortLived, longLived, mediumLived]
        )
        XCTAssertEqual(picked?.batchID, "long")
    }

    func testIgnoresLongTTLIfBatchTooSmall() {
        // Long TTL but doesn't have capacity → the smaller-TTL but
        // larger-capacity batch wins.
        let bigButShort = batch(id: "big", effectiveBytes: 10_000_000, ttlSeconds: 60)
        let smallButLong = batch(id: "small", effectiveBytes: 1_000, ttlSeconds: 86_400)
        let picked = StampService.selectBestBatch(
            forBytes: 1_000_000, in: [bigButShort, smallButLong]
        )
        XCTAssertEqual(picked?.batchID, "big")
    }
}
