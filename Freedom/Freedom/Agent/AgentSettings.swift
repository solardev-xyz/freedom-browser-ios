import Foundation

/// The agent's switches and choices (UserDefaults). Keys live in the
/// Keychain (`AgentKeyStore`), conversations in the agent's database.
@MainActor
@Observable
final class AgentSettings {
    /// Whether this build offers the agent at all. Off in Release until it
    /// ships; DEBUG builds show it.
    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Model providers the agent can use with an API key.
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case openrouter, anthropic, openai

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openrouter: "OpenRouter"
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            }
        }

        var defaultModel: String {
            switch self {
            case .openrouter: "anthropic/claude-haiku-5.5"
            case .anthropic: "claude-haiku-5-5"
            case .openai: "gpt-5.4-mini"
            }
        }

        /// Where the user gets a key.
        var keyURL: URL {
            switch self {
            case .openrouter: URL(string: "https://openrouter.ai/settings/keys")!
            case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
            case .openai: URL(string: "https://platform.openai.com/api-keys")!
            }
        }
    }

    /// When the agent asks before acting on a website (desktop's approval
    /// modes). Wallet, signing, publishing, downloads and uploads always ask.
    enum ApprovalMode: String, CaseIterable, Identifiable, Sendable {
        /// Every click, keystroke and form change waits for the user.
        case everyInteraction = "every_interaction"
        /// Reading and moving around runs; anything that submits, buys,
        /// posts, deletes or changes settings waits for the user.
        case sensitiveActions = "sensitive_actions"
        /// Website interactions run without asking.
        case allowWebsiteInteractions = "allow_website_interactions"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyInteraction: "Ask for every interaction"
            case .sensitiveActions: "Ask for sensitive actions"
            case .allowWebsiteInteractions: "Allow website interactions"
            }
        }
    }

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    var provider: Provider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }
    /// Model id per provider, so switching providers keeps each choice.
    var models: [String: String] {
        didSet { defaults.set(models, forKey: Keys.models) }
    }
    var approvalMode: ApprovalMode {
        didSet { defaults.set(approvalMode.rawValue, forKey: Keys.approvalMode) }
    }
    /// The providers the user agreed to send page content and messages to
    /// (App Store guideline 5.1.2(i): ask before sharing personal data with
    /// a third-party AI). Asked again for a provider not in here.
    var consentedProviders: Set<String> {
        didSet { defaults.set(Array(consentedProviders).sorted(), forKey: Keys.consented) }
    }

    var model: String {
        get { models[provider.rawValue] ?? provider.defaultModel }
        set { models[provider.rawValue] = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var hasConsented: Bool { consentedProviders.contains(provider.rawValue) }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        provider = defaults.string(forKey: Keys.provider).flatMap(Provider.init) ?? .openrouter
        models = defaults.dictionary(forKey: Keys.models) as? [String: String] ?? [:]
        approvalMode = defaults.string(forKey: Keys.approvalMode).flatMap(ApprovalMode.init) ?? .sensitiveActions
        consentedProviders = Set(defaults.stringArray(forKey: Keys.consented) ?? [])
    }

    private enum Keys {
        static let enabled = "agent.enabled"
        static let provider = "agent.provider"
        static let models = "agent.models"
        static let approvalMode = "agent.approvalMode"
        static let consented = "agent.consentedProviders"
    }
}
