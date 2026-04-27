import Foundation

/// How bee-lite is configured to participate in the Swarm network. The
/// only mode that can publish (i.e. pay other nodes for chunks via the
/// chequebook + xBZZ) is `.light`; `.ultraLight` browses without an
/// on-chain identity, and is the default until the user funds the node
/// (see `PublishSetupView`).
///
/// Maps directly to `SwarmConfig.rpcEndpoint`:
///   - `.ultraLight` → `nil` → bee-lite skips the chain entirely
///   - `.light` → pinned Gnosis RPC → bee-lite enables swap + chequebook
///
/// Stored as a raw string in `UserDefaults` so the on-disk format stays
/// independent of Swift case names.
enum BeeNodeMode: String, CaseIterable, Hashable, Sendable {
    case ultraLight = "ultra-light"
    case light
}
