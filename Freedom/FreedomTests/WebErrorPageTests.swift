import XCTest
@testable import Freedom

/// What a failed web load shows: the cause named, the failed URL kept,
/// WebKit's cancels ignored.
final class WebErrorPageTests: XCTestCase {
    private func urlError(_ code: URLError.Code, url: String = "https://a.example/x") -> Error {
        NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: url)!,
            NSURLErrorFailingURLStringErrorKey: url,
            NSLocalizedDescriptionKey: "desc",
        ])
    }

    func testClassifiesTheCommonFailures() {
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.cannotFindHost)), .hostNotFound)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.dnsLookupFailed)), .hostNotFound)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.cannotConnectToHost)), .cannotConnect)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.timedOut)), .timedOut)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.serverCertificateHasBadDate)), .certificate(reason: "the certificate has expired"))
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.serverCertificateUntrusted)), .certificate(reason: "the certificate isn't trusted"))
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.clientCertificateRequired)), .clientCertificate)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.appTransportSecurityRequiresSecureConnection)), .insecureBlocked)
        XCTAssertEqual(WebErrorPage.kind(for: urlError(.badServerResponse)), .generic(message: "desc"))
    }

    func testCancelsAndHandoffsShowNothing() {
        XCTAssertNil(WebErrorPage.kind(for: urlError(.cancelled)))
        XCTAssertNil(WebErrorPage.kind(for: NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertNil(WebErrorPage.kind(for: NSError(domain: "WebKitErrorDomain", code: 204)))
        XCTAssertEqual(WebErrorPage.kind(for: NSError(domain: "WebKitErrorDomain", code: 101, userInfo: [NSLocalizedDescriptionKey: "bad url"])), .generic(message: "bad url"))
    }

    func testFailedURLComesFromTheError() {
        XCTAssertEqual(WebErrorPage.failedURL(urlError(.timedOut, url: "https://b.example/p?q=1"))?.absoluteString, "https://b.example/p?q=1")
        XCTAssertNil(WebErrorPage.failedURL(NSError(domain: NSURLErrorDomain, code: -1001)))
    }

    func testRenderedPageNamesTheHostAndRetriesTheURL() {
        let html = WebErrorPage.render(.certificate(reason: "the certificate has expired"), url: URL(string: "https://expired.badssl.com/?a=1&b=<2>")!)
        XCTAssertTrue(html.contains("<title>This connection isn&#39;t private</title>"))
        XCTAssertTrue(html.contains("couldn&#39;t verify expired.badssl.com: the certificate has expired"))
        XCTAssertTrue(html.contains("never bypasses certificate errors"))
        // Attribute and text escaping: `&` and the percent-encoded brackets survive, raw `&` does not.
        XCTAssertTrue(html.contains("<a href=\"https://expired.badssl.com/?a=1&amp;b=%3C2%3E\">Try again</a>"))
        XCTAssertFalse(html.contains("?a=1&b="))
        let offline = WebErrorPage.render(.offline, url: URL(string: "https://a.example")!)
        XCTAssertTrue(offline.contains("<h1>You&#39;re offline</h1>"))
    }
}
