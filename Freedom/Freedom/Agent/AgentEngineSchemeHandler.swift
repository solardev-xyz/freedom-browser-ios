import Foundation
import OSLog
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// `freedom-agent://engine/…` for the agent engine's hidden web view:
/// serves the bundled engine (`agent-engine.html`, `agent-engine.js`) and
/// proxies the engine's network requests (`/net`) through URLSession, so
/// model providers that don't allow browser origins still answer, and
/// their server-sent events stream back as they arrive.
final class AgentEngineSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "freedom-agent"
    static let engineURL = URL(string: "\(scheme)://engine/agent-engine.html")!

    private let proxy = AgentNetProxy()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "engine" else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        if url.path == "/net" {
            proxy.start(task)
        } else {
            Self.serveBundled(name: url.lastPathComponent, url: url, task: task)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        proxy.stop(task)
    }

    private static let bundledFiles: [String: String] = [
        "agent-engine.html": "text/html; charset=utf-8",
        "agent-engine.js": "text/javascript; charset=utf-8",
    ]

    private static func serveBundled(name: String, url: URL, task: WKURLSchemeTask) {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let mime = bundledFiles[name],
              let file = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "agent-engine")
                ?? Bundle.main.url(forResource: stem, withExtension: ext),
              let data = try? Data(contentsOf: file) else {
            log.error("[engine] missing bundled \(name, privacy: .public): run `npm run build` in AgentEngine/")
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": "no-store"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

/// Replays the engine's fetches with URLSession and streams each response
/// back through its scheme task. Everything runs on the main queue, so a
/// task WebKit stopped is never messaged again (WebKit traps on that).
private final class AgentNetProxy: NSObject, URLSessionDataDelegate {
    private final class Entry {
        let schemeTask: WKURLSchemeTask
        var stopped = false
        var bytes = 0
        init(_ schemeTask: WKURLSchemeTask) { self.schemeTask = schemeTask }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var entries: [Int: Entry] = [:]
    private var taskIDs: [ObjectIdentifier: Int] = [:]

    func start(_ schemeTask: WKURLSchemeTask) {
        let incoming = schemeTask.request
        guard let target = incoming.value(forHTTPHeaderField: "x-freedom-target").flatMap(URL.init(string:)),
              ["http", "https"].contains(target.scheme?.lowercased() ?? "") else {
            schemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var request = URLRequest(url: target)
        request.httpMethod = incoming.httpMethod ?? "GET"
        for (name, value) in Self.decodeHeaders(incoming.value(forHTTPHeaderField: "x-freedom-headers")) {
            // URLSession computes these itself.
            if ["host", "content-length", "connection"].contains(name.lowercased()) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = incoming.httpBody ?? incoming.httpBodyStream.map(Self.readAll)

        let dataTask = session.dataTask(with: request)
        log.notice("[net] \(target.host() ?? "?", privacy: .public) \(request.httpMethod ?? "?", privacy: .public) start, \(request.httpBody?.count ?? 0) bytes")
        entries[dataTask.taskIdentifier] = Entry(schemeTask)
        taskIDs[ObjectIdentifier(schemeTask)] = dataTask.taskIdentifier
        dataTask.resume()
    }

    func stop(_ schemeTask: WKURLSchemeTask) {
        guard let id = taskIDs.removeValue(forKey: ObjectIdentifier(schemeTask)),
              let entry = entries.removeValue(forKey: id) else { return }
        entry.stopped = true
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == id }?.cancel() }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let entry = entries[dataTask.taskIdentifier], !entry.stopped,
              let http = response as? HTTPURLResponse, let url = entry.schemeTask.request.url else {
            completionHandler(.cancel)
            return
        }
        var headers = http.allHeaderFields as? [String: String] ?? [:]
        // URLSession already undid the transfer framing and content encoding,
        // so those headers, and the length, no longer describe the body.
        for name in headers.keys where Self.droppedResponseHeaders.contains(name.lowercased()) {
            headers.removeValue(forKey: name)
        }
        log.notice("[net] \(dataTask.originalRequest?.url?.host ?? "?", privacy: .public) HTTP \(http.statusCode)")
        let rewritten = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        entry.schemeTask.didReceive(rewritten)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = entries[dataTask.taskIdentifier], !entry.stopped else { return }
        entry.bytes += data.count
        entry.schemeTask.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = entries.removeValue(forKey: task.taskIdentifier) else { return }
        taskIDs.removeValue(forKey: ObjectIdentifier(entry.schemeTask))
        guard !entry.stopped else { return }
        if let error {
            log.notice("[net] \(task.originalRequest?.url?.host ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            entry.schemeTask.didFailWithError(error)
        } else {
            log.notice("[net] \(task.originalRequest?.url?.host ?? "?", privacy: .public) finished, \(entry.bytes) bytes")
            entry.schemeTask.didFinish()
        }
    }

    private static let droppedResponseHeaders: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive",
    ]

    private static func decodeHeaders(_ encoded: String?) -> [(String, String)] {
        guard let encoded, let data = Data(base64Encoded: encoded),
              let pairs = try? JSONSerialization.jsonObject(with: data) as? [[String]] else { return [] }
        return pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
