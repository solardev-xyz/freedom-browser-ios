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
        case openrouter, anthropic, openai, xai, meta, venice
        case nearAI = "near-ai"
        case compatible

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openrouter: "OpenRouter"
            case .anthropic: "Anthropic"
            case .openai: "OpenAI"
            case .xai: "xAI (Grok)"
            case .meta: "Meta (Muse)"
            case .venice: "Venice"
            case .nearAI: "NEAR AI"
            case .compatible: "Custom (OpenAI-compatible)"
            }
        }

        /// Spoken to with the OpenAI chat-completions API at a base URL; the user names the model.
        var isOpenAICompatible: Bool { [.venice, .nearAI, .compatible].contains(self) }

        /// The fixed endpoint of a compatible provider (Custom has the user's).
        var presetBaseURL: String? {
            switch self {
            case .venice: "https://api.venice.ai/api/v1"
            case .nearAI: "https://cloud-api.near.ai/v1"
            default: nil
            }
        }

        var defaultModel: String {
            switch self {
            case .openrouter: "anthropic/claude-haiku-5.5"
            case .anthropic: "claude-haiku-5-5"
            case .openai: "gpt-5.4-mini"
            case .xai: "grok-4.3"
            case .meta: "muse-spark-1.3"
            // The user names the model of a compatible provider.
            case .venice, .nearAI, .compatible: ""
            }
        }

        /// Where the user gets a key (Custom: from whoever runs the server).
        var keyURL: URL? {
            switch self {
            case .venice: URL(string: "https://venice.ai/settings/api")!
            case .nearAI: URL(string: "https://cloud.near.ai")!
            case .compatible: nil
            case .openrouter: URL(string: "https://openrouter.ai/settings/keys")!
            case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
            case .openai: URL(string: "https://platform.openai.com/api-keys")!
            case .xai: URL(string: "https://console.x.ai")!
            case .meta: URL(string: "https://api.meta.ai/muse-code/key")!
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
    /// OpenRouter routes only to providers that keep no data (desktop's
    /// "Require zero data retention"); fewer models, on by default.
    var openrouterZeroRetention: Bool {
        didSet { defaults.set(openrouterZeroRetention, forKey: Keys.zeroRetention) }
    }
    /// The Custom provider's base URL (https).
    var compatibleBaseURL: String {
        didSet { defaults.set(compatibleBaseURL, forKey: Keys.compatibleBaseURL) }
    }
    /// Whether a compatible provider's chosen model accepts images, per provider.
    var acceptsImages: [String: Bool] {
        didSet { defaults.set(acceptsImages, forKey: Keys.acceptsImages) }
    }

    /// A compatible provider's endpoint, when it's a valid https URL.
    func baseURL(for provider: Provider) -> String? {
        let raw = provider.presetBaseURL ?? compatibleBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// The compatible providers set up enough to use, for the engine.
    var compatibleProviders: [[String: Any]] {
        Provider.allCases.filter(\.isOpenAICompatible).compactMap { provider in
            let model = (models[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, let baseURL = baseURL(for: provider) else { return nil }
            return ["id": provider.rawValue, "name": provider.displayName, "baseUrl": baseURL, "modelId": model, "vision": acceptsImages[provider.rawValue] ?? false]
        }
    }

    /// The chosen provider has a model (and a compatible one an endpoint).
    var hasModel: Bool {
        !model.isEmpty && (!provider.isOpenAICompatible || baseURL(for: provider) != nil)
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
        openrouterZeroRetention = defaults.object(forKey: Keys.zeroRetention) as? Bool ?? true
        compatibleBaseURL = defaults.string(forKey: Keys.compatibleBaseURL) ?? ""
        acceptsImages = defaults.dictionary(forKey: Keys.acceptsImages) as? [String: Bool] ?? [:]
    }

    private enum Keys {
        static let enabled = "agent.enabled"
        static let provider = "agent.provider"
        static let models = "agent.models"
        static let approvalMode = "agent.approvalMode"
        static let consented = "agent.consentedProviders"
        static let zeroRetention = "agent.openrouterZeroRetention"
        static let compatibleBaseURL = "agent.compatibleBaseURL"
        static let acceptsImages = "agent.acceptsImages"
    }
}
