import Foundation
import OSLog
import UIKit
import UniformTypeIdentifiers
import WebKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// One entry of a chat's transcript, as the agent sheet shows it.
struct AgentChatItem: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool }

    struct ToolCall: Equatable, Identifiable {
        let id: String
        let name: String
        let arguments: [String: String]
    }

    let id: String
    let role: Role
    let text: String
    /// Assistant: the tools it called in this turn.
    let toolCalls: [ToolCall]
    /// Tool result: which call it answers, and whether it failed.
    let toolCallID: String?
    let toolName: String?
    let isError: Bool
    /// Assistant: cut off (the app was killed, or the user stopped it).
    let interrupted: Bool
    let error: String?

    init?(_ raw: [String: Any]) {
        guard let role = (raw["role"] as? String).flatMap(Role.init) else { return nil }
        id = String(describing: raw["id"] ?? UUID().uuidString)
        self.role = role
        text = raw["text"] as? String ?? ""
        toolCalls = (raw["tools"] as? [[String: Any]] ?? []).map { call in
            ToolCall(
                id: call["id"] as? String ?? UUID().uuidString,
                name: call["name"] as? String ?? "?",
                arguments: (call["arguments"] as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
            )
        }
        toolCallID = raw["toolCallId"] as? String
        toolName = raw["name"] as? String
        isError = raw["isError"] as? Bool ?? false
        interrupted = raw["interrupted"] as? Bool ?? false
        error = raw["error"] as? String
    }
}

/// What the viewed chat is doing right now.
struct AgentLiveState: Equatable {
    var busy = false
    /// The answer streaming in.
    var partial = ""
    /// Tool calls of the current turn: name and status (pending, running, done, …).
    var tools: [(name: String, status: String)] = []
    var retryAt: Date?
    var retryError: String?
    var failure: String?

    static func == (a: AgentLiveState, b: AgentLiveState) -> Bool {
        a.busy == b.busy && a.partial == b.partial && a.tools.map(\.name) == b.tools.map(\.name)
            && a.tools.map(\.status) == b.tools.map(\.status) && a.retryAt == b.retryAt && a.failure == b.failure
    }
}

/// A website interaction waiting for the user.
struct AgentApproval: Identifiable, Equatable {
    let taskID: Int
    let chatID: Int
    let tool: String
    let label: String
    let effect: String?
    let navigationTarget: String?
    let intent: String?
    let summary: String?
    let uncertainties: [String]
    let url: String?
    let arguments: [String: String]

    var id: Int { taskID }

    init?(_ raw: [String: Any]) {
        guard let taskID = (raw["taskId"] as? NSNumber)?.intValue, let chatID = (raw["chatId"] as? NSNumber)?.intValue else { return nil }
        self.taskID = taskID
        self.chatID = chatID
        tool = raw["tool"] as? String ?? "?"
        label = raw["label"] as? String ?? ""
        effect = raw["effect"] as? String
        navigationTarget = raw["navigationTarget"] as? String
        intent = raw["intent"] as? String
        summary = raw["summary"] as? String
        uncertainties = raw["uncertainties"] as? [String] ?? []
        url = raw["url"] as? String
        arguments = (raw["arguments"] as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
    }
}

struct AgentChat: Identifiable, Equatable, Codable {
    let id: Int
    var title: String
    var updated: Date
}

/// Freedom Agent for the whole app: owns the engine (Pi in a hidden web
/// view), the chat list, the chat on screen and the approvals waiting for the
/// user. Started at launch when the agent is enabled, so a run the app was
/// killed during continues; independent of any sheet being open.
@MainActor
@Observable
final class AgentService {
    enum Phase: Equatable {
        case off
        case starting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .off
    private(set) var chats: [AgentChat] = []
    private(set) var currentChatID: Int?
    private(set) var items: [AgentChatItem] = []
    private(set) var hasEarlierItems = false
    private(set) var live = AgentLiveState()
    private(set) var approvals: [AgentApproval] = []
    /// The last error of a user action (sending, stopping), for the sheet.
    var lastError: String?
    /// The agent's sheet is on screen (from appearing until dismissed), so
    /// page prompts present over it instead of from the root (PagePrompts.swift).
    var isSheetOnScreen = false
    /// Chats whose runs were cut off when Freedom closed or was put away mid-run,
    /// waiting for the user to continue or stop them (`resumeInterrupted`).
    private(set) var interruptedChats: [Int] = []
    enum Interruption { case closed, background }
    private(set) var interruption: Interruption = .closed
    /// Whether opening the engine asks before continuing what its database left
    /// unfinished: at launch, after the engine was stopped in the background, and
    /// until the user answered. A restart after the engine crashed doesn't ask.
    private var askBeforeResuming = true

    let settings: AgentSettings
    private let tabStore: TabStore
    private var engine: AgentEngine?
    private var pageDriver: AgentPageDriver?
    private var walletDriver: AgentWalletDriver?
    /// A transfer the agent asked for, waiting for the user on the agent's sheet.
    private(set) var walletPrompt: AgentTransferPrompt?
    /// A file the agent asked to upload (browser_upload), waiting for the user's choice.
    private(set) var filePrompt: AgentFilePrompt?
    /// Files the user attached to the next message.
    private(set) var stagedAttachments: [AgentAttachment] = []
    let attachments = AgentAttachmentStore()
    private let wallet: WalletServices
    private let balances: WalletBalanceStore
    private let userWallets: UserWalletStore
    private let nodes: AgentNodes
    private var nodeDriver: AgentNodeDriver?
    private let defaults: UserDefaults

    init(
        settings: AgentSettings,
        tabStore: TabStore,
        wallet: WalletServices,
        balances: WalletBalanceStore,
        userWallets: UserWalletStore,
        nodes: AgentNodes,
        defaults: UserDefaults = .standard
    ) {
        self.nodes = nodes
        self.settings = settings
        self.tabStore = tabStore
        self.wallet = wallet
        self.balances = balances
        self.userWallets = userWallets
        self.defaults = defaults
        chats = (defaults.data(forKey: Self.chatsKey)).flatMap { try? JSONDecoder().decode([AgentChat].self, from: $0) } ?? []
        keyedProviders = Set(AgentKeyStore.allKeys(AgentSettings.Provider.allCases.map(\.rawValue)).keys)
        observeAppLifecycle()
    }

    private static let chatsKey = "agent.chats"

    var currentChat: AgentChat? { chats.first { $0.id == currentChatID } }
    var pendingApprovalsForCurrentChat: [AgentApproval] { approvals.filter { $0.chatID == currentChatID } }
    /// Providers with a key in the Keychain, read once: the sheet asks on every redraw.
    private var keyedProviders: Set<String>
    var hasKey: Bool { keyedProviders.contains(settings.provider.rawValue) }
    /// Ready to chat: enabled, consented for the provider, with a key.
    var isConfigured: Bool { settings.isEnabled && settings.hasConsented && hasKey && settings.hasModel }

    // MARK: - Lifecycle

    /// Starts the engine and opens the agent's database (continuing interrupted runs).
    func start() async {
        #if DEBUG
        applyDebugSetup()
        #endif
        guard AgentSettings.isAvailable, settings.isEnabled, phase == .off || phase.isFailed else { return }
        phase = .starting
        let engine = AgentEngine()
        let driver = AgentPageDriver(tabs: tabStore, defaults: defaults)
        driver.chooseFile = { [weak self] site, field in
            guard let self else { return nil }
            return await AgentFilePrompt.ask(AgentFilePrompt(site: site, field: field)) { self.filePrompt = $0 }
        }
        engine.pageDriver = driver
        engine.attachmentStore = attachments
        let nodeDriver = AgentNodeDriver(nodes: nodes, attachments: attachments, defaults: defaults)
        engine.nodeDriver = nodeDriver
        self.nodeDriver = nodeDriver
        let walletDriver = AgentWalletDriver(services: wallet, balances: balances, userWallets: userWallets) { [weak self] prompt in
            self?.walletPrompt = prompt
        }
        engine.walletDriver = walletDriver
        self.walletDriver = walletDriver
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engine.onTerminated = { [weak self] in self?.engineDied() }
        self.engine = engine
        pageDriver = driver
        do {
            _ = try await engine.start()
            let keys = AgentKeyStore.allKeys(AgentSettings.Provider.allCases.map(\.rawValue))
            var wipe = false
            #if DEBUG
            // FREEDOM_DEBUG_AGENT_WIPE=1: start from no chats (simulator runs); once, not on a restart.
            if ProcessInfo.processInfo.environment["FREEDOM_DEBUG_AGENT_WIPE"] == "1", !debugLaunchHandled {
                wipe = true
                chats = []
                currentChatID = nil
                saveChats()
                driver.forgetAll()
                attachments.forgetAll()
                nodeDriver.forgetAll()
            }
            #endif
            let result = try await engine.command("agentOpen", [
                "apiKeys": keys,
                "compatible": settings.compatibleProviders,
                "approvalMode": settings.approvalMode.rawValue,
                "openrouterZeroRetention": settings.openrouterZeroRetention,
                "wipe": wipe,
                "askBeforeResuming": askBeforeResuming,
            ]) as? [String: Any] ?? [:]
            for raw in result["approvals"] as? [[String: Any]] ?? [] {
                if let approval = AgentApproval(raw) { approvals.append(approval) }
            }
            interruptedChats = (result["interrupted"] as? [NSNumber] ?? []).map(\.intValue)
            if interruptedChats.isEmpty {
                askBeforeResuming = false
            } else {
                log.notice("[agent] interrupted runs in chats \(self.interruptedChats, privacy: .public); asking before continuing")
                if !interruptedChats.contains(where: { $0 == currentChatID }) { currentChatID = interruptedChats.first }
                #if DEBUG
                // FREEDOM_DEBUG_AGENT_RESUME=continue|stop answers the question after 2 s (simulator runs).
                if let answer = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_AGENT_RESUME"], !answer.isEmpty {
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        await self.resumeInterrupted(answer == "continue")
                    }
                }
                #endif
            }
            phase = .ready
            log.notice("[agent] open in \(String(describing: result["openMs"] ?? "?"), privacy: .public) ms, \(self.chats.count) chats")
            #if DEBUG
            // Whether the engine's page counts as visible, so its timers run on time.
            let timers = (try? await engine.command("timerCheck", ["count": 4])) as? [String: Any] ?? [:]
            log.notice("[agent] engine timers: 4×50 ms took \(String(describing: timers["totalMs"] ?? "?"), privacy: .public) ms, visibility \(timers["visibility"] as? String ?? "?", privacy: .public)")
            _ = try? await engine.command("heartbeat", ["seconds": 5])
            #endif
            if let current = currentChatID ?? chats.first?.id { await select(current) }
            #if DEBUG
            if !debugLaunchHandled {
                debugLaunchHandled = true
                await runDebugPrompt()
            }
            #endif
        } catch {
            phase = .failed(error.localizedDescription)
            log.error("[agent] start failed: \(error.localizedDescription, privacy: .public)")
            engine.stop()
            self.engine = nil
        }
    }

    /// When the engine's process died: a new engine, and the durable agent picks up
    /// the interrupted run where its database left it. At most three restarts a minute.
    private var restarts: [Date] = []

    private func engineDied() {
        restarts = restarts.filter { $0.timeIntervalSinceNow > -60 } + [Date()]
        let chat = currentChatID
        stop()
        guard restarts.count <= 3 else {
            phase = .failed("The agent's engine keeps stopping. Close and reopen the agent to try again.")
            log.error("[agent] engine died \(self.restarts.count) times within a minute; not restarting")
            return
        }
        log.notice("[agent] engine died; restarting it to continue")
        currentChatID = chat
        Task { await start() }
    }

    /// The user's answer for the interrupted runs: continue them, or end them as stopped.
    func resumeInterrupted(_ proceed: Bool) async {
        guard let engine, !interruptedChats.isEmpty else { return }
        if proceed {
            let shown = interruptedChats.first { $0 == currentChatID } ?? interruptedChats[0]
            pageDriver?.showWorkingTab(chatID: shown)
        }
        interruptedChats = []
        askBeforeResuming = false
        do {
            _ = try await engine.command("agentResumeInterrupted", ["proceed": proceed])
            log.notice("[agent] interrupted runs \(proceed ? "continued" : "stopped", privacy: .public)")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Sending or stopping ends interrupted runs the user didn't continue (the engine does it first).
    private func dropInterrupted() {
        guard !interruptedChats.isEmpty else { return }
        interruptedChats = []
        askBeforeResuming = false
        log.notice("[agent] interrupted runs stopped by a new message or Stop")
    }

    func stop() {
        engine?.onTerminated = nil
        engine?.stop()
        engine = nil
        pageDriver = nil
        walletDriver?.cancelPending()
        walletDriver = nil
        filePrompt?.cancel()
        phase = .off
        approvals = []
        live = AgentLiveState()
    }

    // MARK: - Chats

    func newChat() {
        currentChatID = nil
        items = []
        hasEarlierItems = false
        live = AgentLiveState()
        Task { _ = try? await engine?.command("agentView", ["chatId": NSNull()]) }
    }

    func select(_ chatID: Int) async {
        guard let engine else { return }
        currentChatID = chatID
        items = []
        live = AgentLiveState()
        do {
            let found = try await engine.command("agentView", ["chatId": chatID]) as? Bool ?? false
            if !found {
                chats.removeAll { $0.id == chatID }
                saveChats()
                if currentChatID == chatID { currentChatID = nil }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Removes the chat from the list (its history stays in the database for now).
    func forget(_ chatID: Int) {
        chats.removeAll { $0.id == chatID }
        saveChats()
        pageDriver?.forget(chatID: chatID)
        attachments.forget(chatID: chatID)
        nodeDriver?.forget(chatID: chatID)
        if currentChatID == chatID { newChat() }
    }

    /// Sends `text` to the current chat, creating one first if needed.
    // MARK: - Attachments

    func stageAttachment(data: Data, name: String, mimeType: String) {
        do {
            stagedAttachments.append(try attachments.stage(data: data, name: name, mimeType: mimeType, alreadyStaged: stagedAttachments))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unstageAttachment(_ attachment: AgentAttachment) {
        stagedAttachments.removeAll { $0.id == attachment.id }
        attachments.unstage(attachment)
    }

    var canSendAttachmentsOnly: Bool { !stagedAttachments.isEmpty }

    func send(_ text: String) async {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = typed.isEmpty && !stagedAttachments.isEmpty ? "See the attached files." : typed
        guard !prompt.isEmpty, let engine, phase == .ready else { return }
        lastError = nil
        dropInterrupted()
        let model: [String: String] = ["provider": settings.provider.rawValue, "modelId": settings.model]
        do {
            var chatID = currentChatID
            if chatID == nil {
                let created = try await engine.command("agentCreateChat", ["model": model])
                guard let id = (created as? NSNumber)?.intValue else { throw AgentEngine.EngineError.tool("The chat couldn't be created.") }
                chats.insert(AgentChat(id: id, title: String(prompt.prefix(80)), updated: Date()), at: 0)
                saveChats()
                // IDs start over when the chat database is deleted: a new chat starts with no tabs or files.
                pageDriver?.forget(chatID: id)
                attachments.forget(chatID: id)
                nodeDriver?.forget(chatID: id)
                chatID = id
                await select(id)
            }
            guard let chatID else { return }
            // The tab the user is looking at is the one this message is about.
            pageDriver?.beginTurn(chatID: chatID)
            // A compatible provider's settings as they are now (the model ID may have just changed).
            if settings.provider.isOpenAICompatible {
                _ = try await engine.command("agentSetCompatible", ["providers": settings.compatibleProviders])
            }
            // Attached files: images go into the message for models that see them, every file to the chat's store.
            let sending = stagedAttachments
            let images = attachments.images(of: sending)
            try attachments.commit(sending, to: chatID)
            stagedAttachments = []
            _ = try await engine.command("agentSubmit", [
                "chatId": chatID, "prompt": prompt, "requestId": UUID().uuidString, "model": model,
                "attachments": sending.map(\.info), "images": images,
            ])
            touch(chatID)
        } catch {
            lastError = error.localizedDescription
            log.error("[agent] send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopRun() async {
        // Stopping the agent withdraws a transfer or file choice it was asking for.
        walletDriver?.cancelPending()
        filePrompt?.cancel()
        guard let engine, let chatID = currentChatID else { return }
        dropInterrupted()
        _ = try? await engine.command("agentAbort", ["chatId": chatID])
    }

    // MARK: - Background

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// The last check in the background found a run working (not waiting for the user).
    private var workingInBackground = false
    /// The engine was stopped in the background mid-run: start it again when Freedom is back.
    private var stoppedInBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterForeground() }
            },
        ]
    }

    /// A working run gets the time iOS allows in the background (about 30 s) to
    /// finish. If it's still working when that ends, the engine stops as if the
    /// app had been killed, and coming back asks whether to continue. A run
    /// waiting for the user (an approval, a transfer, a file) just waits.
    private func didEnterBackground() {
        guard phase == .ready, let engine, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Freedom Agent") { [weak self] in
            MainActor.assumeIsolated { self?.backgroundTimeEnded() }
        }
        workingInBackground = true
        #if DEBUG
        // FREEDOM_DEBUG_AGENT_BACKGROUND_SECONDS=<n>: the background time ends after n seconds (simulator runs).
        if let seconds = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_AGENT_BACKGROUND_SECONDS"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                self.backgroundTimeEnded()
            }
        }
        #endif
        Task {
            while backgroundTask != .invalid {
                let activity = (try? await engine.command("agentActivity", [:])) as? [String: Any] ?? [:]
                let waitingForUser = (activity["approvals"] as? Int ?? 0) > 0 || (activity["interrupted"] as? Int ?? 0) > 0
                    || walletPrompt != nil || filePrompt != nil
                workingInBackground = activity["busy"] as? Bool == true && !waitingForUser
                if !workingInBackground {
                    endBackgroundTask()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func backgroundTimeEnded() {
        guard backgroundTask != .invalid else { return }
        if workingInBackground {
            log.notice("[agent] background time ended mid-run; the engine stops until Freedom is back")
            let chat = currentChatID
            stop()
            currentChatID = chat
            askBeforeResuming = true
            interruption = .background
            stoppedInBackground = true
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func willEnterForeground() {
        endBackgroundTask()
        guard stoppedInBackground else { return }
        stoppedInBackground = false
        Task { await start() }
    }

    func answer(_ approval: AgentApproval, approved: Bool) async {
        approvals.removeAll { $0.taskID == approval.taskID }
        _ = try? await engine?.command("agentApprove", ["taskId": approval.taskID, "approved": approved])
        log.notice("[agent] \(approved ? "approved" : "declined", privacy: .public) task \(approval.taskID) \(approval.tool, privacy: .public)")
    }

    // MARK: - Settings changes

    /// Saves (or with an empty string removes) the key for `provider` and hands it to the engine.
    func setKey(_ key: String, for provider: AgentSettings.Provider) throws {
        try AgentKeyStore.setKey(key, for: provider.rawValue)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { keyedProviders.remove(provider.rawValue) } else { keyedProviders.insert(provider.rawValue) }
        Task { _ = try? await engine?.command("agentSetKey", ["provider": provider.rawValue, "key": trimmed]) }
    }

    func approvalModeChanged() {
        Task { _ = try? await engine?.command("agentSetApprovalMode", ["mode": settings.approvalMode.rawValue]) }
    }

    func zeroRetentionChanged() {
        Task { _ = try? await engine?.command("agentSetZeroRetention", ["on": settings.openrouterZeroRetention]) }
    }

    /// Deletes every chat (the database file) and the chat list; keys and settings stay.
    func deleteAllChats() async {
        let wasRunning = engine != nil
        stop()
        chats = []
        currentChatID = nil
        items = []
        saveChats()
        AgentPageDriver(tabs: tabStore, defaults: defaults).forgetAll()
        AgentNodeDriver(nodes: nodes, attachments: attachments, defaults: defaults).forgetAll()
        attachments.forgetAll()
        stagedAttachments = []
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: AgentDatabase.directory.appending(path: "agent.sqlite\(suffix)"))
        }
        log.notice("[agent] deleted all chats")
        if wasRunning { await start() }
    }

    func enabledChanged() async {
        if settings.isEnabled { await start() } else { stop() }
    }

    // MARK: - Engine events

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "chat_items":
            guard (event["chatId"] as? NSNumber)?.intValue == currentChatID else { return }
            items = (event["items"] as? [[String: Any]] ?? []).compactMap(AgentChatItem.init)
            if let last = items.last {
                let tools = last.toolCalls.map { "\($0.name)(\($0.arguments.map { "\($0.key)=\($0.value.prefix(60))" }.sorted().joined(separator: ", ")))" }.joined(separator: " ")
                log.notice("[agent] item \(last.role.rawValue, privacy: .public)\(last.isError ? " error" : "", privacy: .public): \(last.text.prefix(300), privacy: .public) \(tools, privacy: .public)")
            }
            hasEarlierItems = event["hasEarlier"] as? Bool ?? false
        case "chat_live":
            guard let chatID = (event["chatId"] as? NSNumber)?.intValue, chatID == currentChatID else { return }
            var next = AgentLiveState()
            next.busy = event["busy"] as? Bool ?? false
            next.partial = event["partial"] as? String ?? ""
            next.tools = (event["tools"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "?", $0["status"] as? String ?? "") }
            next.retryAt = (event["retryAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            next.retryError = event["retryError"] as? String
            next.failure = event["failure"] as? String
            if live.busy && !next.busy {
                touch(chatID)
                log.notice("[agent] run ended in chat \(chatID)\(next.failure.map { ": \($0)" } ?? "", privacy: .public)")
            }
            live = next
        case "approval":
            guard let approval = AgentApproval(event), !approvals.contains(where: { $0.taskID == approval.taskID }) else { return }
            approvals.append(approval)
            log.notice("[agent] approval needed: task \(approval.taskID) \(approval.tool, privacy: .public) “\(approval.label, privacy: .public)” \(approval.summary ?? "", privacy: .public)")
            #if DEBUG
            if let answer = ProcessInfo.processInfo.environment["FREEDOM_DEBUG_AGENT_APPROVE"] {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await self.answer(approval, approved: answer == "yes")
                }
            }
            #endif
        case "approval_gone":
            let taskID = (event["taskId"] as? NSNumber)?.intValue
            approvals.removeAll { $0.taskID == taskID }
        default:
            break
        }
    }

    #if DEBUG
    /// The launch switches below apply to the first start only, not to a restart after the engine died.
    private var debugLaunchHandled = false

    /// FREEDOM_DEBUG_AGENT_SETUP=<provider>[:<model>] with FREEDOM_DEBUG_AGENT_KEY: turns the
    /// agent on with that key and consent, as the setup screen would (simulator runs).
    private func applyDebugSetup() {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["FREEDOM_DEBUG_AGENT_SETUP"], !spec.isEmpty else { return }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard let provider = AgentSettings.Provider(rawValue: parts[0]) else { return }
        settings.provider = provider
        if parts.count > 1, !parts[1].isEmpty { settings.model = parts[1] }
        if let baseURL = env["FREEDOM_DEBUG_AGENT_BASE_URL"], !baseURL.isEmpty { settings.compatibleBaseURL = baseURL }
        if let key = env["FREEDOM_DEBUG_AGENT_KEY"], !key.isEmpty { try? setKey(key, for: provider) }
        if let mode = env["FREEDOM_DEBUG_AGENT_MODE"].flatMap(AgentSettings.ApprovalMode.init) { settings.approvalMode = mode }
        settings.consentedProviders.insert(provider.rawValue)
        settings.isEnabled = true
    }

    /// FREEDOM_DEBUG_AGENT_ASK=<prompt>: asks it in a new chat once the agent is open,
    /// after FREEDOM_DEBUG_AGENT_DELAY seconds (a FREEDOM_DEBUG_OPEN_URL page loading).
    private func runDebugPrompt() async {
        let env = ProcessInfo.processInfo.environment
        guard let prompt = env["FREEDOM_DEBUG_AGENT_ASK"], !prompt.isEmpty else { return }
        if let delay = env["FREEDOM_DEBUG_AGENT_DELAY"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
        // FREEDOM_DEBUG_AGENT_ATTACH: files in the app's tmp directory, comma-separated, attached to the prompt.
        for name in (env["FREEDOM_DEBUG_AGENT_ATTACH"] ?? "").split(separator: ",").map(String.init) {
            let url = FileManager.default.temporaryDirectory.appending(path: name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)
            stageAttachment(data: data, name: name, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
        }
        // FREEDOM_DEBUG_AGENT_HTML_B64: a test page of the run's own in the active tab (base64 HTML).
        if let encoded = env["FREEDOM_DEBUG_AGENT_HTML_B64"], let data = Data(base64Encoded: encoded),
           let html = String(data: data, encoding: .utf8), let tab = tabStore.activeTab {
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://agent-check.invalid/"))
            try? await Task.sleep(for: .seconds(2))
        }
        newChat()
        log.notice("[agent] debug prompt: \(prompt, privacy: .public)")
        await send(prompt)
    }
    #endif

    private func touch(_ chatID: Int) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        var chat = chats.remove(at: index)
        chat.updated = Date()
        chats.insert(chat, at: 0)
        saveChats()
    }

    private func saveChats() {
        if let data = try? JSONEncoder().encode(chats) { defaults.set(data, forKey: Self.chatsKey) }
    }
}

extension AgentService.Phase {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
