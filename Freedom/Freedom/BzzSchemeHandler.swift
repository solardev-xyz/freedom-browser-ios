import Foundation
import WebKit

final class BzzSchemeHandler: NSObject, WKURLSchemeHandler {
    private let beeAPIPort: Int = 1633
    private let session = URLSession.shared
    private var active: [ObjectIdentifier: URLSessionDataTask] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let httpURL = translate(url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        let key = ObjectIdentifier(task)
        let dataTask = session.dataTask(with: httpURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.active.removeValue(forKey: key) != nil else { return }
                if let error {
                    task.didFailWithError(error)
                    return
                }
                guard let response, let data else {
                    task.didFailWithError(URLError(.badServerResponse))
                    return
                }
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
        active[key] = dataTask
        dataTask.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    private func translate(_ url: URL) -> URL? {
        guard url.scheme == "bzz", let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = beeAPIPort
        let path = url.path.isEmpty ? "/" : url.path
        components.path = "/bzz/\(host)\(path)"
        components.query = url.query
        return components.url
    }
}
