import SwiftUI

/// Freedom Agent's sheet: a chat about the page the user has open. Shown at
/// half height over the page so the user can watch the agent work in it
/// (desktop's narrow-window layout); approvals appear in the chat.
struct AgentSheet: View {
    @Environment(AgentService.self) private var agent
    @Environment(TabStore.self) private var tabStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var isShowingSettings = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if agent.isConfigured {
                    chat
                } else {
                    AgentSetupView()
                }
            }
            .navigationTitle(agent.currentChat?.title ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { chatsMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if agent.isConfigured {
                        Button("New chat", systemImage: "square.and.pencil") { agent.newChat() }
                            .disabled(agent.currentChatID == nil)
                    }
                    Button("Agent settings", systemImage: "gearshape") { isShowingSettings = true }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    AgentSettingsView()
                        .toolbar { Button("Done") { isShowingSettings = false } }
                }
            }
        }
        .task { await agent.start() }
    }

    // MARK: - Chat

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let waiting = agent.approvals.first(where: { $0.chatID != agent.currentChatID }) {
                        Button {
                            Task { await agent.select(waiting.chatID) }
                        } label: {
                            Label("Another chat is waiting for your approval", systemImage: "hand.raised.fill")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }
                    if agent.items.isEmpty && !agent.live.busy {
                        emptyState
                    }
                    if agent.hasEarlierItems {
                        Text("Earlier messages aren't shown.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(agent.items) { item in
                        AgentItemRow(item: item)
                    }
                    liveRows
                    ForEach(agent.pendingApprovalsForCurrentChat) { approval in
                        AgentApprovalCard(approval: approval)
                    }
                    if let error = agent.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: agent.items.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: agent.live.partial) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: agent.approvals.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom) { composer }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about the page you have open, or give the agent a task on it.")
                .font(.subheadline).foregroundStyle(.secondary)
            if tabStore.activeTab?.isPrivate == true {
                Label("The agent doesn't work in private tabs.", systemImage: "eye.slash")
                    .font(.footnote).foregroundStyle(.orange)
            }
            ForEach(["Summarize this page", "What can I do on this site?"], id: \.self) { suggestion in
                Button(suggestion) { Task { await agent.send(suggestion) } }
                    .buttonStyle(.bordered)
                    .font(.footnote)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var liveRows: some View {
        let live = agent.live
        if live.busy {
            ForEach(Array(live.tools.enumerated()), id: \.offset) { _, tool in
                Label(AgentToolLabel.running(tool.name), systemImage: "circle.dotted")
                    .font(.footnote).foregroundStyle(.secondary)
                    .symbolEffect(.pulse)
            }
            if !live.partial.isEmpty {
                Text(markdown(live.partial)).textSelection(.enabled)
            } else if live.tools.isEmpty {
                ProgressView().controlSize(.small)
            }
            if let retryAt = live.retryAt, retryAt > Date() {
                Label("Retrying \(retryAt, style: .relative)\(live.retryError.map { ": \($0)" } ?? "")", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if !live.busy, let failure = live.failure {
            Label("The run stopped: \(failure)", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the agent", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .submitLabel(.send)
                .onSubmit(send)
            if agent.live.busy {
                Button("Stop", systemImage: "stop.circle.fill") { Task { await agent.stopRun() } }
                    .labelStyle(.iconOnly).font(.title)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly).font(.title)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || agent.phase != .ready)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await agent.send(text) }
    }

    // MARK: - Chats menu

    private var chatsMenu: some View {
        Menu {
            if agent.chats.isEmpty {
                Text("No chats yet")
            }
            ForEach(agent.chats) { chat in
                Button {
                    Task { await agent.select(chat.id) }
                } label: {
                    if chat.id == agent.currentChatID {
                        Label(chat.title, systemImage: "checkmark")
                    } else {
                        Text(chat.title)
                    }
                }
            }
            if let current = agent.currentChatID {
                Divider()
                Button("Remove this chat from the list", systemImage: "trash", role: .destructive) { agent.forget(current) }
            }
        } label: {
            Label("Chats", systemImage: "list.bullet")
        }
    }
}

extension View {
    /// Freedom Agent's sheet: half height over the page, which stays usable so the
    /// user can watch the agent work in it; it comes up by itself when the agent
    /// asks for an approval.
    func agentSheet(isPresented: Binding<Bool>) -> some View {
        modifier(AgentSheetPresenter(isPresented: isPresented))
    }
}

private struct AgentSheetPresenter: ViewModifier {
    @Environment(AgentService.self) private var agent
    @Environment(TabStore.self) private var tabStore
    @Binding var isPresented: Bool

    /// Dismissing the transfer sheet cancels the transfer.
    private var walletPromptBinding: Binding<AgentTransferPrompt?> {
        Binding(get: { agent.walletPrompt }, set: { if $0 == nil { agent.walletPrompt?.cancel() } })
    }

    /// A page prompt showing from the root: the agent's sheet waits for it.
    private var pagePromptPending: Bool { tabStore.activeTab?.hasPendingPrompt == true }

    func body(content: Content) -> some View {
        content
            .onChange(of: agent.approvals.count) { old, new in
                if new > old, !isPresented, !pagePromptPending { isPresented = true }
            }
            .onChange(of: pagePromptPending) { _, pending in
                if !pending, !agent.approvals.isEmpty || agent.walletPrompt != nil, !isPresented { isPresented = true }
            }
            .onChange(of: agent.walletPrompt?.id) { _, id in
                if id != nil, !isPresented, !pagePromptPending { isPresented = true }
            }
            .sheet(isPresented: $isPresented, onDismiss: { agent.isSheetOnScreen = false }) {
                AgentSheet()
                    .onAppear { agent.isSheetOnScreen = true }
                    // A page the agent operates may ask for the wallet, a permission, Swarm or Radicle.
                    .pagePromptSheets(inAgentSheet: true)
                    // The agent's own transfer (wallet_transfer).
                    .sheet(item: walletPromptBinding) { prompt in
                        AgentTransferSheet(prompt: prompt)
                    }
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
    }
}

// MARK: - Rows

private struct AgentItemRow: View {
    let item: AgentChatItem

    var body: some View {
        switch item.role {
        case .user:
            Text(item.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(item.toolCalls) { call in
                    Label(AgentToolLabel.done(call.name, call.arguments), systemImage: AgentToolLabel.icon(call.name))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !item.text.isEmpty {
                    Text(markdown(item.text)).textSelection(.enabled)
                }
                if item.interrupted {
                    Label("Interrupted", systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
                }
                if let error = item.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
        case .tool:
            if item.isError {
                Label(item.text.isEmpty ? "\(AgentToolLabel.running(item.toolName ?? "")) failed" : item.text, systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }
}

private struct AgentApprovalCard: View {
    @Environment(AgentService.self) private var agent
    let approval: AgentApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Allow this?", systemImage: "hand.raised.fill")
                .font(.headline)
            Text(AgentToolLabel.request(approval))
                .font(.body)
            if let host = approval.url.flatMap(URL.init(string:))?.host() {
                Text("On \(host)").font(.footnote).foregroundStyle(.secondary)
            }
            if let target = approval.navigationTarget, let host = URL(string: target)?.host() {
                Text("Opens \(host)").font(.footnote).foregroundStyle(.secondary)
            }
            if let summary = approval.summary ?? approval.intent {
                Text(summary).font(.footnote)
            }
            ForEach(approval.uncertainties, id: \.self) { uncertainty in
                Label(uncertainty, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Allow") { Task { await agent.answer(approval, approved: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Don't allow", role: .cancel) { Task { await agent.answer(approval, approved: false) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.4)))
    }
}

/// How the sheet describes the browser tools.
enum AgentToolLabel {
    static func icon(_ name: String) -> String {
        switch name {
        case "browser_snapshot", "browser_get_tab": "doc.text.magnifyingglass"
        case "browser_list_tabs", "browser_focus_tab": "square.on.square"
        case "browser_create_tab": "plus.square.on.square"
        case "browser_close_tab": "xmark.square"
        case "browser_screenshot": "camera.viewfinder"
        case "browser_target_point": "scope"
        case "browser_stop_loading": "stop.circle"
        case "browser_get_dialog", "browser_handle_dialog": "exclamationmark.bubble"
        case "browser_list_frames", "browser_read_frame": "rectangle.inset.filled"
        case "wallet_transfer": "arrow.up.right.circle"
        case "browser_navigate": "arrow.up.right.square"
        case "browser_click": "hand.tap"
        case "browser_type": "keyboard"
        case "browser_select": "filemenu.and.selection"
        case "browser_scroll": "arrow.up.and.down"
        case "browser_press": "return"
        case "browser_wait": "hourglass"
        default: "wrench.and.screwdriver"
        }
    }

    static func running(_ name: String) -> String {
        switch name {
        case "browser_snapshot": "Reading the page…"
        case "browser_get_tab": "Checking the tab…"
        case "browser_navigate": "Opening a page…"
        case "browser_click": "Clicking…"
        case "browser_type": "Typing…"
        case "browser_select": "Choosing an option…"
        case "browser_scroll": "Scrolling…"
        case "browser_press": "Pressing a key…"
        case "browser_wait": "Waiting for the page…"
        case "browser_list_tabs": "Checking the tabs…"
        case "browser_create_tab": "Opening a tab…"
        case "browser_focus_tab": "Switching tabs…"
        case "browser_close_tab": "Closing a tab…"
        case "browser_screenshot": "Looking at the page…"
        case "browser_target_point": "Finding the spot…"
        case "browser_stop_loading": "Stopping…"
        case "browser_get_dialog": "Reading the dialog…"
        case "browser_handle_dialog": "Answering the dialog…"
        case "browser_list_frames": "Finding embedded frames…"
        case "browser_read_frame": "Reading an embedded frame…"
        case "wallet_transfer": "Waiting for you to approve the transfer…"
        default: "Working…"
        }
    }

    static func done(_ name: String, _ arguments: [String: String]) -> String {
        let intent = arguments["intent"].map { ": \($0)" } ?? ""
        switch name {
        case "browser_snapshot": return "Read the page"
        case "browser_get_tab": return "Checked the tab"
        case "browser_navigate": return "Opened \(arguments["url"] ?? "a page")"
        case "browser_click": return "Click\(intent)"
        case "browser_type": return "Type “\(arguments["text"].map { String($0.prefix(60)) } ?? "")”"
        case "browser_select": return "Choose “\(arguments["value"] ?? arguments["values"] ?? "")”"
        case "browser_scroll": return "Scroll \(arguments["direction"] ?? "")"
        case "browser_press": return "Press \(arguments["key"] ?? "a key")\(intent)"
        case "browser_wait": return "Wait for \(arguments["condition"] ?? "the page")"
        case "browser_list_tabs": return "Checked the tabs"
        case "browser_create_tab": return "Opened \(arguments["url"] ?? "a page") in a new tab"
        case "browser_focus_tab": return "Switched tabs"
        case "browser_close_tab": return "Closed a tab"
        case "browser_screenshot": return "Looked at the page"
        case "browser_target_point": return "Found a spot on the page"
        case "browser_stop_loading": return "Stopped loading"
        case "browser_get_dialog": return "Read the dialog"
        case "browser_list_frames": return "Found embedded frames"
        case "browser_read_frame": return "Read an embedded frame"
        case "wallet_transfer": return "Send \(arguments["amount"] ?? "") \(arguments["asset"] ?? "") to \(arguments["recipient"] ?? "")"
        case "browser_handle_dialog": return arguments["accept"] == "1" ? "Answered OK to the dialog" : "Answered Cancel to the dialog"
        default: return name
        }
    }

    /// The approval's one-line request: what exactly would happen.
    static func request(_ approval: AgentApproval) -> String {
        let target = approval.label.isEmpty ? "an element" : "“\(approval.label)”"
        switch approval.tool {
        case "browser_click":
            return approval.effect == "form_submission" ? "Submit the form with \(target)" : "Click \(target)"
        case "browser_type":
            let text = approval.arguments["text"] ?? ""
            return "Type “\(text.prefix(80))” into \(target)"
        case "browser_select":
            return "Choose “\(approval.arguments["value"] ?? approval.arguments["values"] ?? "")” in \(target)"
        case "browser_press":
            return "Press \(approval.arguments["key"] ?? "a key") on \(target)"
        case "browser_scroll":
            return "Scroll \(approval.arguments["direction"] ?? "") in \(target)"
        case "browser_handle_dialog":
            if let text = approval.arguments["promptText"] { return "Answer “\(text.prefix(80))” to the page's question \(target)" }
            return approval.effect == "dialog_accept" ? "Answer OK to \(target)" : "Answer Cancel to \(target)"
        default:
            return approval.tool
        }
    }
}

/// Model answers are Markdown; fall back to plain text when they don't parse.
private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}
