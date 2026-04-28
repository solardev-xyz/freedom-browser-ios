import XCTest
@testable import Freedom

@MainActor
final class SwarmPublishServiceTests: XCTestCase {
    private struct CapturedRequest: Equatable {
        let path: String
        let body: Data
        let contentType: String
        let headers: [String: String]
        let query: [String: String]
    }

    private var lastRequest: CapturedRequest?
    /// What the stubbed upload returns on next call.
    private var nextResult: Result<(Data, [String: String]), Swift.Error> = .success((Data(), [:]))

    private func makeService() -> SwarmPublishService {
        SwarmPublishService(upload: { [self] path, body, contentType, headers, query in
            self.lastRequest = CapturedRequest(
                path: path, body: body, contentType: contentType,
                headers: headers, query: query
            )
            return try self.nextResult.get()
        })
    }

    private func successResponse(reference: String, tag: String? = nil) {
        let body = "{\"reference\": \"\(reference)\"}".data(using: .utf8)!
        var headers: [String: String] = [:]
        if let tag { headers["swarm-tag"] = tag }
        nextResult = .success((body, headers))
    }

    // MARK: - Request shape

    func testPublishDataPostsToBzzWithBatchHeader() async throws {
        successResponse(reference: "abc", tag: "42")
        let svc = makeService()
        let result = try await svc.publishData(
            Data("hello".utf8),
            contentType: "text/plain",
            name: nil,
            batchID: "batch1"
        )
        XCTAssertEqual(result.reference, "abc")
        XCTAssertEqual(result.tagUid, 42)
        XCTAssertEqual(lastRequest?.path, "/bzz")
        XCTAssertEqual(lastRequest?.contentType, "text/plain")
        XCTAssertEqual(lastRequest?.headers["Swarm-Postage-Batch-Id"], "batch1")
        XCTAssertEqual(lastRequest?.body, Data("hello".utf8))
    }

    func testPublishDataIncludesNameQueryWhenProvided() async throws {
        successResponse(reference: "x")
        _ = try await makeService().publishData(
            Data(), contentType: "text/plain", name: "greeting", batchID: "b"
        )
        XCTAssertEqual(lastRequest?.query["name"], "greeting")
    }

    func testPublishDataOmitsNameQueryWhenNil() async throws {
        successResponse(reference: "x")
        _ = try await makeService().publishData(
            Data(), contentType: "text/plain", name: nil, batchID: "b"
        )
        XCTAssertNil(lastRequest?.query["name"])
    }

    func testPublishDataOmitsNameQueryWhenEmpty() async throws {
        // Empty-string name behaves like missing name — no `?name=` in
        // the URL. Otherwise bee would surface an empty `name` field
        // on the manifest, which we'd have to specially clean up.
        successResponse(reference: "x")
        _ = try await makeService().publishData(
            Data(), contentType: "text/plain", name: "", batchID: "b"
        )
        XCTAssertNil(lastRequest?.query["name"])
    }

    // MARK: - Response parsing

    func testPublishDataReturnsNilTagWhenHeaderAbsent() async throws {
        successResponse(reference: "ref", tag: nil)
        let result = try await makeService().publishData(
            Data(), contentType: "text/plain", name: nil, batchID: "b"
        )
        XCTAssertNil(result.tagUid)
    }

    // MARK: - Error mapping

    func testPublishDataMapsBeeNotRunningToUnreachable() async {
        nextResult = .failure(BeeAPIClient.Error.notRunning)
        do {
            _ = try await makeService().publishData(
                Data(), contentType: "text/plain", name: nil, batchID: "b"
            )
            XCTFail("expected unreachable")
        } catch SwarmPublishService.PublishError.unreachable {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testPublishDataMapsBeeTransientToOther() async {
        // 5xx from bee — not "node down", so not nodeStopped. Surface as
        // -32603 internal so the dapp knows it's an unusual condition,
        // not a "retry the connect flow".
        nextResult = .failure(BeeAPIClient.Error.transient(503))
        do {
            _ = try await makeService().publishData(
                Data(), contentType: "text/plain", name: nil, batchID: "b"
            )
            XCTFail("expected other")
        } catch SwarmPublishService.PublishError.other {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testPublishDataRejectsResponseWithoutReference() async {
        nextResult = .success(("{}".data(using: .utf8)!, [:]))
        do {
            _ = try await makeService().publishData(
                Data(), contentType: "text/plain", name: nil, batchID: "b"
            )
            XCTFail("expected malformedResponse")
        } catch SwarmPublishService.PublishError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testPublishDataRejectsNonJSONResponse() async {
        nextResult = .success(("not json".data(using: .utf8)!, [:]))
        do {
            _ = try await makeService().publishData(
                Data(), contentType: "text/plain", name: nil, batchID: "b"
            )
            XCTFail("expected malformedResponse")
        } catch SwarmPublishService.PublishError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
