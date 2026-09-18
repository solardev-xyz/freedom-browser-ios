import XCTest
import WebKit
@testable import Freedom

/// The `web3:` handler serves only what the tab staged, only to a
/// top-level document load, with the isolating response policy.
@MainActor
final class Web3SchemeHandlerTests: XCTestCase {
    private let app = OnchainAppRef(address: "0x00000095643CFfA7D9fae407a84dfCB6406456c6", chainID: 1)!
    private lazy var document = OnchainAppDocument(
        html: "<!doctype html><title>zSwap</title>",
        provenance: OnchainAppProvenance(
            app: app, networkName: "Ethereum",
            htmlHash: OnchainAppRef.htmlHash("<!doctype html><title>zSwap</title>"),
            trust: OnchainAppLoader.verifiedTrust(source: "myotis")
        )
    )

    private func task(_ urlString: String, method: String = "GET", topLevel: Bool = true, mainDocument: String? = nil) -> FakeSchemeTask {
        let url = URL(string: urlString)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let mainDocument {
            request.mainDocumentURL = URL(string: mainDocument)
        } else if topLevel {
            request.mainDocumentURL = url
        }
        return FakeSchemeTask(request: request)
    }

    private func serve(_ handler: Web3SchemeHandler, _ task: FakeSchemeTask) -> (status: Int, headers: [String: String], body: String) {
        handler.webView(WKWebView(frame: .zero), start: task)
        let response = task.responses.first as! HTTPURLResponse
        let headers = Dictionary(uniqueKeysWithValues: response.allHeaderFields.map { ("\($0.key)", "\($0.value)") })
        return (response.statusCode, headers, String(decoding: task.body, as: UTF8.self))
    }

    func testStagedDocumentIsServedWithIsolationPolicy() {
        let handler = Web3SchemeHandler()
        handler.stage(document)
        let result = serve(handler, task(app.canonicalURL(tail: "/swap?x=1").absoluteString))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, document.html)
        XCTAssertEqual(result.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(result.headers["Content-Security-Policy"], Web3SchemeHandler.contentSecurityPolicy)
        XCTAssertTrue(Web3SchemeHandler.contentSecurityPolicy.contains("connect-src 'none'"))
        XCTAssertTrue(Web3SchemeHandler.contentSecurityPolicy.contains("frame-src 'none'"))
        XCTAssertTrue(Web3SchemeHandler.contentSecurityPolicy.contains("sandbox allow-scripts allow-same-origin"))
        XCTAssertEqual(result.headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(result.headers["X-Frame-Options"], "DENY")
        XCTAssertEqual(result.headers["Referrer-Policy"], "no-referrer")
        XCTAssertEqual(result.headers["X-Freedom-Onchain-App-Verified"], "true")
        XCTAssertEqual(result.headers["X-Freedom-Onchain-App-Hash"], document.provenance.htmlHash)
        XCTAssertNil(result.headers["Access-Control-Allow-Origin"], "no cross-origin reads of app bytes")
    }

    func testHeadServesHeadersWithoutBody() {
        let handler = Web3SchemeHandler()
        handler.stage(document)
        let result = serve(handler, task(app.canonicalURL().absoluteString, method: "HEAD"))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, "")
    }

    func testUnstagedAppGetsReloadPageNotBytes() {
        let handler = Web3SchemeHandler()
        let result = serve(handler, task(app.canonicalURL().absoluteString))
        XCTAssertEqual(result.status, 404)
        XCTAssertTrue(result.body.contains(app.displayURL().absoluteString))
    }

    func testSubresourceAndFrameRequestsAreRefused() {
        let handler = Web3SchemeHandler()
        handler.stage(document)
        // A hostile https page fetching / framing the app.
        let fromWeb = serve(handler, task(app.canonicalURL().absoluteString, mainDocument: "https://evil.example/"))
        XCTAssertEqual(fromWeb.status, 403)
        XCTAssertFalse(fromWeb.body.contains("zSwap"))
        // No main document at all fails closed.
        let noMain = serve(handler, task(app.canonicalURL().absoluteString, topLevel: false))
        XCTAssertEqual(noMain.status, 403)
    }

    func testOnlyCanonicalFormAndGetHead() {
        let handler = Web3SchemeHandler()
        handler.stage(document)
        XCTAssertEqual(serve(handler, task(app.displayURL().absoluteString)).status, 400, "friendly form never reaches WebKit")
        XCTAssertEqual(serve(handler, task(app.canonicalURL().absoluteString, method: "POST")).status, 405)
        XCTAssertEqual(serve(handler, task("web3://nope.eip155-1/")).status, 400)
    }

    func testStagingIsBoundedAndKeyedByApp() {
        let handler = Web3SchemeHandler()
        handler.stage(document)
        XCTAssertTrue(handler.hasStagedDocument(for: app.canonicalURL(tail: "/deep/link")))
        XCTAssertTrue(handler.hasStagedDocument(for: app.displayURL()))
        XCTAssertFalse(handler.hasStagedDocument(for: OnchainAppRef(address: app.address, chainID: 100)!.canonicalURL()))
        for i in 0..<Web3SchemeHandler.capacity {
            let other = OnchainAppRef(address: String(format: "0x%040x", i + 1), chainID: 1)!
            handler.stage(OnchainAppDocument(html: "", provenance: OnchainAppProvenance(app: other, networkName: "", htmlHash: "0x", trust: document.provenance.trust)))
        }
        XCTAssertNil(handler.stagedDocument(for: app), "oldest app evicted")
    }
}

@MainActor
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var responses: [URLResponse] = []
    var body = Data()
    var finished = 0
    var errors: [Error] = []
    init(request: URLRequest) { self.request = request }
    func didReceive(_ response: URLResponse) { responses.append(response) }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { finished += 1 }
    func didFailWithError(_ error: any Error) { errors.append(error) }
}
