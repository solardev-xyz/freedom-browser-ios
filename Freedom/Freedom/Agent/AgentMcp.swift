import AuthenticationServices
import Foundation
import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "com.browser.Freedom", category: "AgentEngine")

/// A connected service: a remote MCP server the user added (desktop's
/// "Connected services"). Its OAuth state, if it has one, is in the Keychain.
struct AgentMcpServer: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var url: String

    var engineValue: [String: Any] { ["id": id, "name": name, "url": url] }

    static let maxServers = 32

    /// Desktop's rules: https, or http on this device only; no credentials, query or fragment.
    static func validatedURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host() else {
            throw AgentMcpError("Enter a complete MCP server URL.")
        }
        let loopback = ["127.0.0.1", "::1", "localhost"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && loopback), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, trimmed.count <= 2048 else {
            throw AgentMcpError("Use an HTTPS MCP URL (HTTP is allowed on localhost), without credentials, query parameters or a fragment.")
        }
        return trimmed
    }
}

struct AgentMcpError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A connected service as the engine last reported it.
struct AgentMcpStatus: Equatable {
    struct Tool: Equatable, Hashable {
        let name: String
        let description: String
    }

    /// connected, needs-auth, failed, disconnected, connecting, signing-in.
    let state: String
    let message: String
    let tools: [Tool]

    init?(_ raw: [String: Any]) {
        guard let state = raw["state"] as? String else { return nil }
        self.state = state
        message = raw["message"] as? String ?? ""
        tools = (raw["tools"] as? [[String: Any]] ?? []).compactMap { tool in
            (tool["name"] as? String).map { Tool(name: $0, description: tool["description"] as? String ?? "") }
        }
    }

    var badge: String {
        switch state {
        case "connected": "Connected"
        case "needs-auth": "Sign-in needed"
        case "failed": "Unavailable"
        case "connecting": "Connecting…"
        case "signing-in": "Signing in…"
        default: "Disconnected"
        }
    }
}

/// The services the user added, in UserDefaults (no secrets).
@MainActor
@Observable
final class AgentMcpStore {
    private static let key = "agent.mcpServers"
    private let defaults: UserDefaults
    private(set) var servers: [AgentMcpServer]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        servers = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([AgentMcpServer].self, from: $0) } ?? []
    }

    func add(name: String, url raw: String) throws -> AgentMcpServer {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count) else { throw AgentMcpError("Enter a connection name (up to 80 characters).") }
        let url = try AgentMcpServer.validatedURL(raw)
        guard servers.count < AgentMcpServer.maxServers else { throw AgentMcpError("Remove a connection before adding another (32 maximum).") }
        guard !servers.contains(where: { $0.url == url }) else { throw AgentMcpError("This server is already connected. Use its Reconnect button.") }
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let server = AgentMcpServer(id: bytes.map { String(format: "%02x", $0) }.joined(), name: name, url: url)
        servers.append(server)
        save()
        return server
    }

    func remove(_ id: String) {
        servers.removeAll { $0.id == id }
        save()
        AgentMcpDriver.forgetAuth(id: id)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Self.key) }
    }
}

/// The engine's `mcp` service: OAuth state per service in the Keychain (this
/// device only), and the sign-in page in the system's web authentication sheet,
/// which returns the redirect to the engine (pi-mcp completes the sign-in).
@MainActor
final class AgentMcpDriver: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let keychainService = "com.browser.Freedom.agent.mcp-auth"
    private var session: ASWebAuthenticationSession?

    func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        let id = params["id"] as? String ?? ""
        guard !id.isEmpty else { throw AgentMcpError("No connection ID.") }
        switch method {
        case "loadAuth":
            guard let data = try KeychainItem(account: id, service: Self.keychainService).read(),
                  let state = try? JSONSerialization.jsonObject(with: data) else { return ["state": NSNull()] }
            return ["state": state]
        case "saveAuth":
            let state = params["state"] ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: state, options: [.fragmentsAllowed])
            try KeychainItem(account: id, service: Self.keychainService).write(data, protection: .deviceOnly)
            return true
        case "authorize":
            guard let raw = params["url"] as? String, let url = URL(string: raw), url.scheme == "https",
                  let scheme = params["callbackScheme"] as? String, !scheme.isEmpty else {
                throw AgentMcpError("The service's sign-in address isn't usable.")
            }
            guard let callback = await authorize(url, scheme: scheme) else { return [String: Any]() }
            return ["url": callback.absoluteString]
        default:
            throw AgentEngine.EngineError.tool("Unknown mcp method: \(method)")
        }
    }

    static func forgetAuth(id: String) {
        try? KeychainItem(account: id, service: keychainService).delete()
    }

    private func authorize(_ url: URL, scheme: String) async -> URL? {
        session?.cancel()
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    log.error("[mcp] sign-in sheet failed: \(error.localizedDescription, privacy: .public)")
                }
                if once.claim() { continuation.resume(returning: callback) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start(), once.claim() { continuation.resume(returning: nil) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Settings

/// Agent settings → Connected services (desktop's panel of the same name).
struct AgentConnectionsView: View {
    @Environment(AgentService.self) private var agent
    @State private var name = ""
    @State private var url = ""
    @State private var error: String?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                if agent.mcp.servers.isEmpty {
                    Text("Connect a service to let Freedom Agent use its tools.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agent.mcp.servers) { server in
                    row(server)
                }
            } footer: {
                Text("Services available to Freedom Agent across your chats.")
            }

            Section {
                TextField("My service", text: $name)
                TextField("https://example.com/mcp", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button(isAdding ? "Connecting…" : "Connect service") {
                    Task { await add() }
                }
                .disabled(isAdding || name.isEmpty || url.isEmpty)
            } header: {
                Text("Add a service")
            } footer: {
                Text("Connections go directly to the service. You’ll approve each tool or resource request before it runs. Services that need an account offer sign-in. Only remote MCP servers work on iPhone.")
            }
        }
        .navigationTitle("Connected services")
        .task { await agent.connectMcpServers() }
    }

    @ViewBuilder private func row(_ server: AgentMcpServer) -> some View {
        let status = agent.mcpStatuses[server.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(server.name).font(.headline)
                Spacer()
                Text(status?.badge ?? "Disconnected")
                    .font(.caption)
                    .foregroundStyle(status?.state == "connected" ? .green : status?.state == "needs-auth" ? .orange : .secondary)
            }
            Text(server.url).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            if let message = status?.message, !message.isEmpty {
                Text(message).font(.footnote)
            }
            if let tools = status?.tools, !tools.isEmpty {
                DisclosureGroup("\(tools.count) available tool\(tools.count == 1 ? "" : "s")") {
                    ForEach(tools, id: \.self) { tool in
                        VStack(alignment: .leading) {
                            Text(tool.name).font(.footnote.monospaced())
                            if !tool.description.isEmpty {
                                Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
                .font(.footnote)
            }
            HStack {
                if status?.state == "needs-auth" {
                    Button("Sign in") { Task { await agent.signInMcp(server.id) } }
                        .buttonStyle(.borderedProminent)
                }
                Button("Reconnect") { Task { await agent.reconnectMcp(server.id) } }
                    .buttonStyle(.bordered)
                Button("Disconnect", role: .destructive) { Task { await agent.removeMcp(server.id) } }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
            .disabled(status?.state == "connecting" || status?.state == "signing-in")
        }
        .padding(.vertical, 4)
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        do {
            try await agent.addMcp(name: name, url: url)
            name = ""
            url = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
