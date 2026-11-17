import Foundation
import OSLog
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// Reads and operates the page in the user's tab for the agent's browser
/// tools. The page side (agent-page.js, built from AgentEngine/page/) runs in
/// the tab's own content world, injected on first use per document, so the
/// page's scripts can't see or call it.
@MainActor
final class AgentPageDriver {
    enum DriverError: LocalizedError {
        case noTab
        case privateTab
        case scriptMissing
        case badURL(String)

        var errorDescription: String? {
            switch self {
            case .noTab: "No tab is open."
            case .privateTab: "The agent doesn't work in private tabs."
            case .scriptMissing: "The agent's page script is missing from the app."
            case .badURL(let reason): reason
            }
        }
    }

    static let world = WKContentWorld.world(name: "FreedomAgent")

    private static let pageScript: String? = Bundle.main.url(forResource: "agent-page", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The tab the agent works in (the active one).
    private let currentTab: () -> BrowserTab?
    /// Opens a tab when there is none (the start page) and the agent navigates.
    private let openTab: () -> BrowserTab?
    /// Navigation counters per web view: bumped whenever its URL changes,
    /// including in-page navigations, so waits and results can tell.
    private var navigations: [ObjectIdentifier: (count: Int, observation: NSKeyValueObservation)] = [:]

    init(currentTab: @escaping () -> BrowserTab?, openTab: @escaping () -> BrowserTab?) {
        self.currentTab = currentTab
        self.openTab = openTab
    }

    /// One call from the engine's `page` service.
    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        let tab = try usableTab(opening: method == "navigate")
        switch method {
        case "tab":
            return state(of: tab)
        case "navigate":
            return try await navigate(tab, to: params["url"] as? String ?? "")
        case "snapshot", "describe", "matches", "containsText":
            return try await callPage(tab, method, params)
        case "click", "type", "select", "press", "scroll":
            let before = navigationCount(tab.webView)
            var result = try await callPage(tab, method, params) as? [String: Any] ?? [:]
            // Let the page react (a link starting to load, a form submitting) before reporting.
            try? await Task.sleep(for: .milliseconds(120))
            if result["ok"] as? Bool != false {
                let now = state(of: tab)
                result["tab"] = now
                result["navigated"] = navigationCount(tab.webView) != before || tab.isLoading
            }
            return result
        default:
            throw AgentEngine.EngineError.tool("Unknown page method: \(method)")
        }
    }

    private func usableTab(opening: Bool = false) throws -> BrowserTab {
        guard let tab = currentTab() ?? (opening ? openTab() : nil) else { throw DriverError.noTab }
        guard !tab.isPrivate else { throw DriverError.privateTab }
        observeNavigations(tab.webView)
        return tab
    }

    func state(of tab: BrowserTab) -> [String: Any] {
        [
            "url": tab.displayURL?.absoluteString ?? tab.webView.url?.absoluteString ?? "",
            "title": tab.title,
            "loading": tab.isLoading,
            "webLoading": tab.webView.isLoading,
            "progress": (tab.webView.estimatedProgress * 100).rounded() / 100,
            "navigationId": navigationCount(tab.webView),
        ]
    }

    // MARK: - Navigation

    private static let allowedSchemes: Set<String> = ["http", "https", "bzz", "ipfs", "ipns", "ens"]

    private func navigate(_ tab: BrowserTab, to input: String) async throws -> [String: Any] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), Self.allowedSchemes.contains(scheme) else {
            throw DriverError.badURL("Use an absolute http, https, bzz, ipfs, ipns or ens URL.")
        }
        guard url.user == nil, url.password == nil else { throw DriverError.badURL("URLs with embedded credentials aren't allowed.") }
        guard let target = BrowserURL.parse(trimmed) else { throw DriverError.badURL("That isn't a URL Freedom can open.") }
        let before = navigationCount(tab.webView)
        tab.navigate(to: target)
        // Report once loading has started (or the name is resolving), not when it ends: browser_wait does that.
        for _ in 0..<20 where navigationCount(tab.webView) == before && !tab.isLoading {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ["navigating": true, "tab": state(of: tab)]
    }

    private func observeNavigations(_ webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        guard navigations[id] == nil else { return }
        let observation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.navigations[id]?.count += 1 }
        }
        navigations[id] = (0, observation)
    }

    private func navigationCount(_ webView: WKWebView) -> Int { navigations[ObjectIdentifier(webView)]?.count ?? 0 }

    // MARK: - Page script

    private static let installSentinel = "__freedom_agent_needs_page_script"

    private func callPage(_ tab: BrowserTab, _ method: String, _ params: [String: Any]) async throws -> Any? {
        let webView = tab.webView
        let body = """
        const page = globalThis.__freedomAgentPage;
        if (!page) return "\(Self.installSentinel)";
        return await page.call(method, args);
        """
        let arguments: [String: Any] = ["method": method, "args": params]
        var result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.world)
        if result as? String == Self.installSentinel {
            guard let script = Self.pageScript else { throw DriverError.scriptMissing }
            _ = try await webView.callAsyncJavaScript(script + "\nreturn true;", arguments: [:], in: nil, contentWorld: Self.world)
            log.notice("[page] installed the page script on \(webView.url?.host() ?? "?", privacy: .public)")
            result = try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.world)
        }
        guard let json = result as? String, let data = json.data(using: .utf8) else { return result }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
