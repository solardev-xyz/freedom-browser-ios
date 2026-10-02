import Foundation
import Observation
import WebKit

/// Per-site web permissions (desktop "Site Permissions" parity, scoped to
/// what WKWebView lets the host decide: camera, microphone, and device
/// motion / orientation). Location, notifications, clipboard and MIDI
/// have no host hook on iOS — WebKit prompts for location itself, the
/// rest are unsupported in WKWebView.
enum SitePermissionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case camera, microphone, motion
    /// Opening links in other apps (mailto:, tel:, magnet:, app schemes).
    case externalApps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .motion: "Motion & orientation"
        case .externalApps: "Open other apps"
        }
    }

    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .motion: "gyroscope"
        case .externalApps: "arrow.up.forward.app"
        }
    }

    /// The kinds a WebKit media-capture request covers.
    static func kinds(for type: WKMediaCaptureType) -> [SitePermissionKind] {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera, .microphone]
        }
    }
}

enum SitePermissionDecision: String, Codable, Sendable {
    case allow, block
}

/// What applies to one site + permission right now: a remembered
/// decision, or this run's embargo after repeated dismissals.
enum SitePermissionState: Equatable, Sendable {
    case allowed, blocked, blockedThisSession

    var label: String {
        switch self {
        case .allowed: "Allowed"
        case .blocked: "Blocked"
        case .blockedThisSession: "Blocked this session"
        }
    }
}

struct SitePermissionEntry: Identifiable, Equatable {
    let kind: SitePermissionKind
    let state: SitePermissionState
    var id: String { kind.rawValue }
}

/// A request WebKit parked on the tab: the site, what it asked for, and
/// the one-shot answer. `remember` writes the decision to the store.
struct SitePermissionRequest: Identifiable {
    enum Answer { case allow, block, dismiss }
    let id = UUID()
    let origin: String
    let kinds: [SitePermissionKind]
    /// For `.externalApps`: the app the link would open ("Mail").
    var detail: String? = nil
    let respond: (Answer, _ remember: Bool) -> Void

    /// The prompt's sentence after the site name.
    var sentence: String {
        if kinds == [.externalApps] {
            return "wants to open \(detail ?? "another app")"
        }
        return "wants to use your " + kinds.map(\.label).joined(separator: " and ").lowercased()
    }
}

/// Remembered decisions (persisted, profile-wide) plus the per-run
/// state: dismissal counts and embargoes. Desktop `site-permissions`:
/// a dismissal denies once without recording; the third dismissal in a
/// row for the same site + permission blocks it for the rest of the run
/// (#364) so a page cannot re-raise the prompt indefinitely.
@MainActor
@Observable
final class SitePermissionStore {
    static let shared = SitePermissionStore()
    static let maxDismissals = 3
    private static let key = "sitePermissions.v1"

    /// origin → kind → decision
    private(set) var decisions: [String: [String: SitePermissionDecision]]
    /// origin|kind embargoed for this run after repeated dismissals.
    private(set) var sessionBlocks: Set<String> = []
    private var dismissals: [String: Int] = [:]
    /// nil: in-memory only (a private tab's store).
    private let defaults: UserDefaults?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: [String: SitePermissionDecision]].self, from: data)
        {
            decisions = stored
        } else {
            decisions = [:]
        }
    }

    /// A store that never touches disk: decisions live as long as it does.
    init(ephemeral: Bool) {
        precondition(ephemeral)
        defaults = nil
        decisions = [:]
    }

    var isEphemeral: Bool { defaults == nil }

    /// `scheme://host[:port]` — the origin a permission belongs to. ENS
    /// hosts keep the name (`bzz://vitalik.eth`), so a rotated content
    /// hash keeps its decisions and a different name never inherits them.
    static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func origin(for securityOrigin: WKSecurityOrigin) -> String? {
        let scheme = securityOrigin.protocol.lowercased()
        let host = securityOrigin.host.lowercased()
        guard !scheme.isEmpty, !host.isEmpty else { return nil }
        let port = securityOrigin.port == 0 ? "" : ":\(securityOrigin.port)"
        return "\(scheme)://\(host)\(port)"
    }

    private static func sessionKey(_ origin: String, _ kind: SitePermissionKind) -> String { "\(origin)|\(kind.rawValue)" }

    func decision(origin: String, kind: SitePermissionKind) -> SitePermissionDecision? {
        decisions[origin]?[kind.rawValue]
    }

    func isSessionBlocked(origin: String, kind: SitePermissionKind) -> Bool {
        sessionBlocks.contains(Self.sessionKey(origin, kind))
    }

    func state(origin: String, kind: SitePermissionKind) -> SitePermissionState? {
        if isSessionBlocked(origin: origin, kind: kind) { return .blockedThisSession }
        switch decision(origin: origin, kind: kind) {
        case .allow?: return .allowed
        case .block?: return .blocked
        case nil: return nil
        }
    }

    /// Everything that applies to a site, in `SitePermissionKind` order —
    /// what the address-bar indicator lists and its Remove lifts.
    func entries(origin: String) -> [SitePermissionEntry] {
        SitePermissionKind.allCases.compactMap { kind in
            state(origin: origin, kind: kind).map { SitePermissionEntry(kind: kind, state: $0) }
        }
    }

    /// What to do with a request before asking: `.allow` when every kind
    /// is remembered as allowed, `.block` when any kind is remembered as
    /// blocked or embargoed, nil when the user must be asked.
    func settled(origin: String, kinds: [SitePermissionKind]) -> SitePermissionDecision? {
        if kinds.contains(where: { isSessionBlocked(origin: origin, kind: $0) }) { return .block }
        let remembered = kinds.map { decision(origin: origin, kind: $0) }
        if remembered.contains(.block) { return .block }
        if remembered.allSatisfy({ $0 == .allow }) { return .allow }
        return nil
    }

    func remember(origin: String, kinds: [SitePermissionKind], decision: SitePermissionDecision) {
        var forOrigin = decisions[origin] ?? [:]
        for kind in kinds { forOrigin[kind.rawValue] = decision }
        decisions[origin] = forOrigin
        for kind in kinds { dismissals[Self.sessionKey(origin, kind)] = nil }
        persist()
    }

    /// A dismissed prompt: denied once, nothing recorded — until the
    /// third in a row, which embargoes the site + permission for this run.
    /// Returns true when the embargo was just imposed.
    @discardableResult
    func noteDismissal(origin: String, kinds: [SitePermissionKind]) -> Bool {
        var embargoed = false
        for kind in kinds {
            let key = Self.sessionKey(origin, kind)
            let count = (dismissals[key] ?? 0) + 1
            dismissals[key] = count
            if count >= Self.maxDismissals {
                sessionBlocks.insert(key)
                embargoed = true
            }
        }
        return embargoed
    }

    /// An answered prompt resets the dismissal streak.
    func noteAnswered(origin: String, kinds: [SitePermissionKind]) {
        for kind in kinds { dismissals[Self.sessionKey(origin, kind)] = nil }
    }

    func revoke(origin: String, kind: SitePermissionKind) {
        decisions[origin]?[kind.rawValue] = nil
        if decisions[origin]?.isEmpty == true { decisions[origin] = nil }
        sessionBlocks.remove(Self.sessionKey(origin, kind))
        dismissals[Self.sessionKey(origin, kind)] = nil
        persist()
    }

    func revokeAll(origin: String) {
        for kind in SitePermissionKind.allCases { revoke(origin: origin, kind: kind) }
    }

    func removeAll() {
        decisions = [:]
        sessionBlocks = []
        dismissals = [:]
        persist()
    }

    /// Origins with any remembered decision or a run-scoped embargo.
    var origins: [String] {
        let embargoed = sessionBlocks.map { String($0.split(separator: "|", maxSplits: 1)[0]) }
        return Array(Set(decisions.keys).union(embargoed)).sorted()
    }

    private func persist() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(decisions) { defaults.set(data, forKey: Self.key) }
    }
}
