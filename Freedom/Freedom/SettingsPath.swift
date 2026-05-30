import SwiftUI

/// Single typed-path enum that backs the settings root's
/// `NavigationStack(path: $path)`. Mixing value-based and
/// destination-based `NavigationLink` inside the same stack breaks
/// `NavigationStack`'s sync — when a value-push happens from inside
/// a destination-pushed view, SwiftUI bounces the visible stack to
/// match the path (which doesn't track the destination-pushed
/// ancestor) and the user ends up jumped back to the wrong level.
///
/// Going entirely value-based keeps the path authoritative and lets
/// the Add Chain flow pop multiple levels in one animation by
/// trimming the `.chainlistSearch` / `.addChainForm` suffix.
enum SettingsPath: Hashable {
    case wallet
    case ens
    case swarm
    case ipfs
    case rpc
    case adblock

    case chainEditor(Int) // chain ID — resolved against ChainStore at destination time

    case chainlistSearch
    case addChainForm(AddChainForm.Prefill?)

    /// True for the per-step views the user pushes during the
    /// "Add Chain" sub-flow. Used by `AddChainForm.submit` to know
    /// which suffix of the path to drop so a successful add lands
    /// the user back on the chain list — not stranded mid-flow.
    var isAddChainStep: Bool {
        switch self {
        case .chainlistSearch, .addChainForm: return true
        case .wallet, .ens, .swarm, .ipfs, .rpc, .adblock, .chainEditor: return false
        }
    }
}

private struct SettingsPathKey: EnvironmentKey {
    static let defaultValue: Binding<[SettingsPath]> = .constant([])
}

extension EnvironmentValues {
    /// Shared binding into the settings root's `NavigationStack` path.
    /// `AddChainForm` reads this to trim the Add Chain suffix on
    /// successful submission — popping every step the user pushed
    /// during the flow in one animation.
    var settingsPath: Binding<[SettingsPath]> {
        get { self[SettingsPathKey.self] }
        set { self[SettingsPathKey.self] = newValue }
    }
}
