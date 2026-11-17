#if DEBUG
import OSLog
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// DEBUG-only test bench for the agent engine: boots Pi in its own hidden
/// web view; runs one prompt on Pi's bare loop (pi-agent-core) with a
/// `read_page` tool against the active tab; and runs the scripted browser-tool
/// checks on real sites. Freedom Agent itself is `AgentService`/`AgentSheet`.
///
/// `FREEDOM_DEBUG_SHOW=agent-bench` opens it at launch.
/// `FREEDOM_DEBUG_AGENT=<provider>:<model>` (e.g. `faux:`, `ollama:qwen3:8b`)
/// runs `FREEDOM_DEBUG_AGENT_PROMPT` right away, with `FREEDOM_DEBUG_AGENT_KEY`
/// as the API key. `FREEDOM_DEBUG_AGENT_PAGECHECK=all|<case,…>` runs the page
/// checks (AgentEngine/src/page-check.js); `FREEDOM_DEBUG_AGENT_TIMERCHECK=1`
/// measures timer throttling.
struct AgentSpikeView: View {
    enum Provider: String, CaseIterable, Identifiable {
        case faux, ollama, openrouter, anthropic, openai
        var id: String { rawValue }

        var defaultModel: String {
            switch self {
            case .faux: "faux"
            case .ollama: "qwen3:8b"
            case .openrouter: "anthropic/claude-haiku-5.5"
            case .anthropic: "claude-haiku-5-5"
            case .openai: "gpt-5.4-mini"
            }
        }

        var needsKey: Bool { ![.faux, .ollama].contains(self) }
    }

    @Environment(TabStore.self) private var tabStore
    @Environment(\.dismiss) private var dismiss

    @State private var engine = AgentEngine()
    @State private var pageDriver: AgentPageDriver?
    @State private var status = "Starting…"
    @State private var provider: Provider = .faux
    @State private var model = Provider.faux.defaultModel
    @State private var baseURL = "http://127.0.0.1:11434/v1"
    @State private var apiKey = ""
    @State private var prompt = "What is the page I have open about?"
    @State private var transcript: [String] = []
    @State private var answer = ""
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Text(status).font(.footnote.monospaced())
                    Button("Network check (openrouter.ai/models)") { Task { await netCheck() } }
                }
                Section("Model") {
                    Picker("Provider", selection: $provider) {
                        ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: provider) { _, new in model = new.defaultModel }
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider == .ollama {
                        TextField("Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if provider.needsKey {
                        SecureField("API key (kept in memory only)", text: $apiKey)
                    }
                }
                Section("Prompt") {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                    Button(isRunning ? "Stop" : "Run") {
                        if isRunning { Task { _ = try? await engine.command("abort") } } else { Task { await run() } }
                    }
                }
                if !answer.isEmpty {
                    Section("Answer") { Text(answer) }
                }
                if !transcript.isEmpty {
                    Section("Events") {
                        ForEach(Array(transcript.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Agent test bench")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .task { await boot() }
        .onDisappear { engine.stop() }
    }

    private func boot() async {
        engine.readPage = { [tabStore] in try await Self.readActivePage(tabStore) }
        let driver = AgentPageDriver(tabs: tabStore)
        pageDriver = driver
        engine.pageDriver = driver
        engine.onEvent = { event in handle(event) }
        do {
            let bootMs = try await engine.start()
            let info = try await engine.command("info") as? [String: Any]
            status = "Ready in \(bootMs) ms · pi-ai \(info?["piAi"] as? String ?? "?")"
            log.notice("[spike] \(status, privacy: .public)")
        } catch {
            status = "Failed: \(error.localizedDescription)"
            log.error("[spike] boot failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        await autorunIfRequested()
    }

    private func autorunIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        // FREEDOM_DEBUG_AGENT_PAGECHECK=all|<case,…>: the browser tools on real sites, no model (src/page-check.js).
        if let names = env["FREEDOM_DEBUG_AGENT_PAGECHECK"], !names.isEmpty {
            // Lets a FREEDOM_DEBUG_OPEN_URL tab exist first: opening one from here would bring the
            // page to the front and dismiss this sheet, and the engine with it.
            if let delay = env["FREEDOM_DEBUG_AGENT_DELAY"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
            log.notice("[spike] page check \(names, privacy: .public) starting")
            do {
                let loadOnly = env["FREEDOM_DEBUG_AGENT_PAGECHECK_LOADONLY"] == "1"
                let results = try await engine.command("pageCheck", ["names": names, "loadOnly": loadOnly]) as? [[String: Any]] ?? []
                let passed = results.filter { $0["ok"] as? Bool == true }.count
                status = "Page check: \(passed)/\(results.count) passed"
                log.notice("[spike] page check done: \(passed)/\(results.count)")
            } catch {
                log.error("[spike] page check failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        if env["FREEDOM_DEBUG_AGENT_TIMERCHECK"] == "1" {
            for round in 1...3 {
                let r = (try? await engine.command("timerCheck", ["count": 40])) as? [String: Any] ?? [:]
                log.notice("[spike] timers round \(round): 40×50 ms took \(String(describing: r["totalMs"] ?? "?"), privacy: .public) ms (expected 2000), worst late \(String(describing: r["worstLateMs"] ?? "?"), privacy: .public) ms, visibility \(r["visibility"] as? String ?? "?", privacy: .public)")
            }
        }
        if let spec = env["FREEDOM_DEBUG_AGENT"], !spec.isEmpty {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if let chosen = Provider(rawValue: parts[0]) {
                provider = chosen
                model = parts.count > 1 && !parts[1].isEmpty ? parts[1] : chosen.defaultModel
            }
        }
        if let key = env["FREEDOM_DEBUG_AGENT_KEY"] { apiKey = key }
        guard let spec = env["FREEDOM_DEBUG_AGENT"], !spec.isEmpty, Provider(rawValue: String(spec.prefix { $0 != ":" })) != nil else { return }
        if let text = env["FREEDOM_DEBUG_AGENT_PROMPT"] { prompt = text }
        if env["FREEDOM_DEBUG_AGENT_NETCHECK"] == "1" { await netCheck() }
        // Lets a FREEDOM_DEBUG_OPEN_URL page finish loading before read_page.
        if let delay = env["FREEDOM_DEBUG_AGENT_DELAY"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
        await run()
    }

    private func run() async {
        isRunning = true
        answer = ""
        transcript = []
        defer { isRunning = false }
        var params: [String: Any] = ["provider": provider.rawValue, "model": model, "prompt": prompt]
        if provider == .ollama { params["baseUrl"] = baseURL }
        if provider.needsKey { params["apiKey"] = apiKey }
        log.notice("[spike] run \(provider.rawValue, privacy: .public):\(model, privacy: .public)")
        do {
            let result = try await engine.command("run", params) as? [String: Any] ?? [:]
            let summary = "stop=\(result["stopReason"] ?? "?") firstToken=\(result["firstTokenMs"] ?? "-")ms total=\(result["totalMs"] ?? "?")ms tools=\((result["tools"] as? [Any])?.count ?? 0)"
            transcript.append(summary)
            if let error = result["error"] as? String { transcript.append("error: \(error)") }
            log.notice("[spike] done \(summary, privacy: .public) error=\(result["error"] as? String ?? "-", privacy: .public) answer=\(answer, privacy: .public)")
        } catch {
            transcript.append("failed: \(error.localizedDescription)")
            log.error("[spike] run failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func netCheck() async {
        do {
            let r = try await engine.command("netCheck", ["url": "https://openrouter.ai/api/v1/models"]) as? [String: Any] ?? [:]
            let line = "net: HTTP \(r["status"] ?? "?") \(r["bytes"] ?? "?") bytes, first chunk \(r["firstChunkMs"] ?? "?") ms, total \(r["totalMs"] ?? "?") ms"
            transcript.append(line)
            log.notice("[spike] \(line, privacy: .public)")
        } catch {
            transcript.append("net failed: \(error.localizedDescription)")
            log.error("[spike] net failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "text":
            answer += event["delta"] as? String ?? ""
        case "tool_start":
            transcript.append("→ \(event["name"] ?? "?") at \(event["atMs"] ?? "?") ms")
        case "tool_end":
            transcript.append("← \(event["name"] ?? "?")\(event["isError"] as? Bool == true ? " (error)" : "") at \(event["atMs"] ?? "?") ms")
        default:
            break
        }
    }

    /// The `read_page` tool: the active tab's address, title and visible text,
    /// read in an isolated content world so page scripts can't see or alter the call.
    private static func readActivePage(_ tabStore: TabStore) async throws -> [String: Any] {
        guard let tab = tabStore.activeTab else { throw AgentEngine.EngineError.tool("No tab is open.") }
        let value = try await tab.webView.callAsyncJavaScript(
            "return { url: location.href, title: document.title, text: (document.body ? document.body.innerText : '').slice(0, 6000) };",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let page = value as? [String: Any] else { throw AgentEngine.EngineError.tool("The page returned nothing.") }
        log.notice("[spike] read_page \(page["url"] as? String ?? "?", privacy: .public)")
        return page
    }
}
#endif
