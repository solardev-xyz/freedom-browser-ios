import Foundation

/// Host seed pins for the execution-layer peer pool (engine ABI 31+,
/// `myotis_set_boot_enodes`, myotis #465): known-good snap-serving nodes
/// the engine dials first, so a fresh install or a cold peer cache has a
/// serving peer within seconds instead of waiting for discovery to find
/// one. A floor for cold starts, not the pool — discovery keeps running
/// and the pins are only re-dialed while nobody serves.
///
/// The app bundles one list per network (`Resources/myotis/seeds-<net>.json`, flattened into the bundle root,
/// regenerated at release time by `scripts/myotis-seeds.py` from a warm
/// profile's `peers.cache`). Each start pushes a random subset of at most
/// `limit` entries, so no single operator is dialed first by every install
/// every time and the network sees a different subset per client.
public enum MyotisSeedPins {
    /// Entries pushed per start. The engine caps a list at 64; 20 keeps a
    /// cold start covered several times over while spreading the load.
    public static let limit = 20
    /// The engine's hard cap on a host list.
    public static let engineCap = 64

    /// `enode://<128 hex secp256k1 pubkey>@<IPv4>:<port>` — numeric hosts
    /// only (the engine has no resolver and refuses DNS names).
    private static let entry = try! NSRegularExpression(
        pattern: #"^enode://[0-9a-f]{128}@(\d{1,3}\.){3}\d{1,3}:\d{1,5}$"#
    )

    /// Parse a JSON array of enode strings. Malformed entries and repeated
    /// addresses are dropped rather than refusing the list: the engine
    /// applies or refuses a push AS A WHOLE, so one bad line must not
    /// cost the cold start every pin. Capped at the engine limit.
    public static func parse(_ data: Data) -> [String] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for e in raw {
            let range = NSRange(e.startIndex..., in: e)
            guard entry.firstMatch(in: e, range: range) != nil,
                  let at = e.firstIndex(of: "@")
            else { continue }
            let address = String(e[e.index(after: at)...])
            guard seen.insert(address).inserted else { continue }
            out.append(e)
            if out.count == engineCap { break }
        }
        return out
    }

    /// Load a bundled list; a missing or unreadable resource is an empty
    /// list (cold start as before), never an error.
    public static func load(_ url: URL?) -> [String] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return parse(data)
    }

    /// The subset one start pushes: shuffled, at most `limit` entries.
    public static func select<G: RandomNumberGenerator>(
        _ all: [String], limit: Int = MyotisSeedPins.limit, using rng: inout G
    ) -> [String] {
        Array(all.shuffled(using: &rng).prefix(max(0, limit)))
    }

    public static func select(_ all: [String], limit: Int = MyotisSeedPins.limit) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return select(all, limit: limit, using: &rng)
    }

    /// The JSON the engine takes.
    public static func json(_ enodes: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: enodes),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}
