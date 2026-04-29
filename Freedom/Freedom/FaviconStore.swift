import Foundation
import Observation
import OSLog
import SwiftData
import UIKit
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "FaviconStore")

@MainActor
@Observable
final class FaviconStore {
    /// In-memory cache of decoded UIImages keyed by URL host. Decoded once
    /// at store-time so FaviconView can render without re-parsing bytes on
    /// every body eval. @Observable tracks reads of this dict so any view
    /// that looked up an entry re-renders when any host's icon is written;
    /// with pre-decoded UIImages that's effectively free (SwiftUI diffs by
    /// UIImage identity).
    private(set) var images: [String: UIImage] = [:]

    @ObservationIgnored private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        loadAll()
    }

    func image(for host: String?) -> UIImage? {
        guard let host else { return nil }
        return images[host]
    }

    /// Extract a favicon URL from the loaded page, download it, and cache.
    /// Idempotent: no-op if a favicon is already cached for the host.
    func fetchIfNeeded(for pageURL: URL, webView: WKWebView) {
        guard let host = pageURL.host, images[host] == nil else { return }

        Task { [weak self] in
            guard let self else { return }
            let iconURL = await self.resolveIconURL(from: webView, pageURL: pageURL)
            guard let iconURL, let data = await self.download(iconURL) else { return }
            self.store(data: data, host: host)
        }
    }

    private func resolveIconURL(from webView: WKWebView, pageURL: URL) async -> URL? {
        // Ask the page for any declared icon first — prefers apple-touch-icon
        // (retina-quality) when present, then regular <link rel="icon">.
        let script = """
        (function() {
            const links = Array.from(document.querySelectorAll('link[rel]'))
                .filter(l => /(^|\\s)(apple-touch-icon|icon|shortcut icon)(\\s|$)/.test(l.rel));
            if (links.length === 0) return null;
            const apple = links.find(l => l.rel.includes('apple-touch-icon'));
            return (apple || links[0]).href;
        })();
        """
        if let result = try? await webView.evaluateJavaScript(script),
           let urlString = result as? String,
           let url = URL(string: urlString) {
            return url
        }
        // Fallback: /favicon.ico at the page origin.
        var components = URLComponents()
        components.scheme = pageURL.scheme
        components.host = pageURL.host
        components.path = "/favicon.ico"
        return components.url
    }

    private func download(_ url: URL) async -> Data? {
        // For bzz:// URLs, reach into the Bee HTTP gateway directly.
        // URLSession doesn't route through our WKURLSchemeHandler, so we
        // translate the URL to localhost:1633 ourselves.
        let fetchURL: URL
        if url.scheme == "bzz" {
            guard let translated = BzzSchemeHandler.localHTTPURL(for: url) else { return nil }
            fetchURL = translated
        } else if url.scheme == "https" {
            fetchURL = url
        } else {
            // http:// falls afoul of ATS; skip rather than adding exceptions.
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: fetchURL)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                return nil
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func store(data: Data, host: String) {
        // Reject garbage payloads (HTML error pages served as /favicon.ico, etc.).
        guard let image = UIImage(data: data) else { return }
        if let existing = fetchOne(host: host) {
            existing.imageData = data
            existing.fetchedAt = Date()
        } else {
            context.insert(Favicon(host: host, imageData: data))
        }
        save()
        images[host] = image
    }

    private func fetchOne(host: String) -> Favicon? {
        var d = FetchDescriptor<Favicon>(predicate: #Predicate { $0.host == host })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func loadAll() {
        let all = (try? context.fetch(FetchDescriptor<Favicon>())) ?? []
        for f in all {
            if let image = UIImage(data: f.imageData) {
                images[f.host] = image
            }
        }
    }

    private func save() { context.saveLogging("Favicon", to: log) }
}
