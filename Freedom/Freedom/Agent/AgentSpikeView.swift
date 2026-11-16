#if DEBUG
import OSLog
import SwiftUI
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// DEBUG-only test bench for the agent engine spike: boots Pi in its hidden
/// web view, runs one prompt with the `read_page` tool against the active
/// tab, and shows the transcript and timings.
///
/// `FREEDOM_DEBUG_SHOW=agent` opens it at launch. `FREEDOM_DEBUG_AGENT=<provider>:<model>`
/// (e.g. `faux:`, `ollama:qwen3:8b`) runs `FREEDOM_DEBUG_AGENT_PROMPT` right
/// away, with `FREEDOM_DEBUG_AGENT_KEY` as the API key.
///
/// The durable agent (Pi's durable runtime on the app's SQLite) uses the
/// provider and model above (faux: the scripted model; Ollama isn't wired up
/// there). `FREEDOM_DEBUG_AGENT_DURABLE=open` opens it at launch and continues
/// what the last launch left, `=fresh` wipes it first;
/// `FREEDOM_DEBUG_AGENT_DURABLE_PROMPT` then submits a prompt (once: a
/// relaunch with the same prompt finds the same submission),
/// `FREEDOM_DEBUG_AGENT_PACE` sets the scripted model's tokens per second, and
/// `FREEDOM_DEBUG_AGENT_APPROVE=yes|no` answers approvals after a second;
/// `FREEDOM_DEBUG_AGENT` and `_KEY` choose its model as for the bare loop.
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
    @State private var status = "Starting…"
    @State private var provider: Provider = .faux
    @State private var model = Provider.faux.defaultModel
    @State private var baseURL = "http://127.0.0.1:11434/v1"
    @State private var apiKey = ""
    @State private var prompt = "What is the page I have open about?"
    @State private var transcript: [String] = []
    @State private var answer = ""
    @State private var isRunning = false

    @State private var durableStatus = "Closed"
    @State private var durableLive = ""
    @State private var durableAnswer = ""
    @State private var durableTranscript: [String] = []
    @State private var pendingApproval: (taskId: Int, summary: String)?
    @State private var slowPace = true
    @State private var autoApprove: Bool?

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
                durableSection
            }
            .navigationTitle("Agent (spike)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .task { await boot() }
        .onDisappear { engine.stop() }
    }

    /// Pi's durable runtime on the app's SQLite, with the scripted model: run,
    /// kill the app, reopen, and the run continues.
    @ViewBuilder private var durableSection: some View {
        Section {
            Text(durableStatus).font(.footnote.monospaced())
            if !durableLive.isEmpty { Text(durableLive).font(.caption.monospaced()) }
            Toggle("Slow model (10 tokens/s)", isOn: $slowPace)
            Button("Open (continue last run)") { Task { await openDurable(wipe: false) } }
            Button("Wipe and open", role: .destructive) { Task { await openDurable(wipe: true) } }
            Button("Submit prompt") { Task { await submitDurable(prompt, requestId: UUID().uuidString) } }
            Button("Submit \"send a tip\" (needs approval)") {
                Task { await submitDurable("Please send a tip to the author", requestId: UUID().uuidString) }
            }
            if let pendingApproval {
                VStack(alignment: .leading) {
                    Text("Approve \(pendingApproval.summary)?").font(.footnote)
                    HStack {
                        Button("Approve") { Task { await answerApproval(true) } }.buttonStyle(.borderedProminent)
                        Button("Decline") { Task { await answerApproval(false) } }.buttonStyle(.bordered)
                    }
                }
            }
            if !durableAnswer.isEmpty { Text(durableAnswer) }
            Button("Show transcript") { Task { await loadDurableTranscript() } }
            ForEach(Array(durableTranscript.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
        } header: {
            Text("Durable agent")
        } footer: {
            Text("Uses the provider, model and key above; faux is the scripted model, and the slow switch only slows that one.")
        }
    }

    private func boot() async {
        engine.readPage = { [tabStore] in try await Self.readActivePage(tabStore) }
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
        if let mode = env["FREEDOM_DEBUG_AGENT_DURABLE"], ["open", "fresh"].contains(mode) {
            if let pace = env["FREEDOM_DEBUG_AGENT_PACE"].flatMap(Int.init) { slowPace = pace <= 10 }
            autoApprove = env["FREEDOM_DEBUG_AGENT_APPROVE"].map { $0 == "yes" }
            await openDurable(wipe: mode == "fresh", pace: env["FREEDOM_DEBUG_AGENT_PACE"].flatMap(Int.init))
            if let delay = env["FREEDOM_DEBUG_AGENT_DELAY"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
            if let text = env["FREEDOM_DEBUG_AGENT_DURABLE_PROMPT"], !text.isEmpty {
                await submitDurable(text, requestId: "env:\(text)")
            }
            return
        }
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

    private func openDurable(wipe: Bool, pace: Int? = nil) async {
        durableAnswer = ""
        durableTranscript = []
        pendingApproval = nil
        do {
            // A run continued from the last launch may need the key right away.
            let r = try await engine.command("durableOpen", ["wipe": wipe, "pace": pace ?? (slowPace ? 10 : 200), "apiKeys": durableKeys]) as? [String: Any] ?? [:]
            let resumed = r["resumed"] as? [String: Any] ?? [:]
            durableStatus = "Opened in \(r["openMs"] ?? "?") ms\(wipe ? " (wiped)" : "") · found \(resumed["entries"] ?? 0) entries, \(resumed["busy"] as? Bool == true ? "a run in progress" : "idle")"
            let partial = (resumed["partial"] as? String)?.count ?? 0
            log.notice("[durable] \(durableStatus, privacy: .public) partial=\(partial) lastEntry=\(resumed["lastEntry"] as? String ?? "-", privacy: .public) tools=\(String(describing: resumed["tools"] ?? []), privacy: .public)")
        } catch {
            durableStatus = "Open failed: \(error.localizedDescription)"
            log.error("[durable] open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keys for the durable agent: kept in memory (here and in the engine), never in its database.
    private var durableKeys: [String: String] {
        provider.needsKey && !apiKey.isEmpty ? [provider.rawValue: apiKey] : [:]
    }

    private func submitDurable(_ text: String, requestId: String) async {
        durableAnswer = ""
        guard provider != .ollama else {
            durableStatus = "The durable agent doesn't have Ollama yet; pick another provider."
            return
        }
        let modelRef: [String: String] = provider == .faux
            ? ["provider": "faux", "modelId": "scripted"]
            : ["provider": provider.rawValue, "modelId": model]
        do {
            if provider.needsKey { _ = try await engine.command("durableSetKey", ["provider": provider.rawValue, "key": apiKey]) }
            let r = try await engine.command("durableSubmit", ["prompt": text, "requestId": requestId, "model": modelRef]) as? [String: Any] ?? [:]
            log.notice("[durable] submitted \(String(describing: r["submissionId"] ?? "?"), privacy: .public) to \(modelRef["provider"] ?? "?", privacy: .public):\(modelRef["modelId"] ?? "?", privacy: .public): \(text, privacy: .public)")
        } catch {
            durableStatus = "Submit failed: \(error.localizedDescription)"
            log.error("[durable] submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func answerApproval(_ approved: Bool) async {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        let ok = (try? await engine.command("durableApprove", ["taskId": pending.taskId, "approved": approved])) as? Bool ?? false
        log.notice("[durable] \(approved ? "approved" : "declined", privacy: .public) task \(pending.taskId) delivered=\(ok)")
    }

    private func loadDurableTranscript() async {
        let entries = (try? await engine.command("durableTranscript")) as? [[String: Any]] ?? []
        durableTranscript = entries.map { entry in
            var line = "\(entry["kind"] as? String ?? "?"): \(entry["text"] as? String ?? "")"
            if let cost = entry["cost"] as? Double { line += String(format: "  (%@ tok, $%.6f)", String(describing: entry["tokens"] ?? "?"), cost) }
            return line
        }
        for line in durableTranscript { log.notice("[durable] transcript \(line, privacy: .public)") }
    }

    private func handleDurable(_ event: [String: Any], type: String) {
        switch type {
        case "state":
            let partial = (event["partial"] as? String)?.count ?? 0
            let tools = (event["tools"] as? [[String: Any]] ?? []).map { "\($0["name"] ?? "?"):\($0["status"] ?? "?")" }.joined(separator: ",")
            var retry = "-"
            if let at = event["retryAt"] as? Double { retry = "\(Int(at - Date().timeIntervalSince1970 * 1000)) ms" }
            durableLive = "busy=\(event["busy"] as? Bool == true) entries=\(event["entries"] ?? 0) attempt=\(event["attempt"] ?? "-") partial=\(partial) retry=\(retry) tools=[\(tools)] failure=\(event["failure"] ?? "-")"
            if partial > 0 { durableAnswer = event["partial"] as? String ?? "" }
            log.notice("[durable] state \(durableLive, privacy: .public)")
        case "approval":
            let taskId = (event["taskId"] as? NSNumber)?.intValue ?? 0
            let args = (event["arguments"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            pendingApproval = (taskId, "\(event["tool"] ?? "?") \(args)")
            log.notice("[durable] approval needed: task \(taskId) \(event["tool"] as? String ?? "?", privacy: .public) \(args, privacy: .public)")
            if let autoApprove {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await answerApproval(autoApprove)
                }
            }
        case "approval_gone":
            pendingApproval = nil
        case "run_end":
            durableAnswer = event["answer"] as? String ?? durableAnswer
            log.notice("[durable] run ended failure=\(event["failure"] as? String ?? "-", privacy: .public) answer=\(durableAnswer, privacy: .public)")
            Task { await loadDurableTranscript() }
        default:
            break
        }
    }

    private func handle(_ event: [String: Any]) {
        if let type = event["type"] as? String, ["state", "approval", "approval_gone", "run_end"].contains(type) {
            handleDurable(event, type: type)
            return
        }
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
