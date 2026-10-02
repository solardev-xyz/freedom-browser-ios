import Foundation

/// One thing the settings search can find: a control or a page, the
/// helper line beside it, the section it lives in, and where to go.
/// Desktop "Search settings": case-insensitive substring over label,
/// description and helper line, no fuzzy matching, each match listed
/// with its section.
struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    let section: String
    let path: [SettingsPath]
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return ([title, section] + [detail ?? ""] + keywords).contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// The index: curated per page (SwiftUI views can't be introspected),
/// plus the chains and resolution methods that exist at search time.
enum SettingsSearchIndex {
    static func entries(chains: [Chain]) -> [SettingsSearchEntry] {
        fixed + chains.map { chain in
            SettingsSearchEntry(
                id: "chain:\(chain.id)", title: chain.displayName,
                detail: "Chain \(chain.id) · RPC endpoints, read and verification order, \(chain.nativeSymbol).",
                section: "Chains", path: [.rpc, .chainEditor(chain.id)],
                keywords: [chain.nativeSymbol, chain.nativeName, "rpc", "endpoint", "provider"]
            )
        }
    }

    static func matches(_ query: String, in entries: [SettingsSearchEntry]) -> [SettingsSearchEntry] {
        entries.filter { $0.matches(query) }
    }

    /// Matches grouped by section, sections in index order.
    static func grouped(_ query: String, in entries: [SettingsSearchEntry]) -> [(section: String, entries: [SettingsSearchEntry])] {
        var order: [String] = []
        var bySection: [String: [SettingsSearchEntry]] = [:]
        for entry in matches(query, in: entries) {
            if bySection[entry.section] == nil { order.append(entry.section) }
            bySection[entry.section, default: []].append(entry)
        }
        return order.map { (section: $0, entries: bySection[$0]!) }
    }

    private static func e(_ id: String, _ title: String, _ detail: String?, _ section: String, _ path: [SettingsPath], _ keywords: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, title: title, detail: detail, section: section, path: path, keywords: keywords)
    }

    static let fixed: [SettingsSearchEntry] = [
        // Wallet
        e("wallet", "Wallet", "Security level, recovery phrase, private key, wipe.", "Wallet", [.wallet], ["vault", "seed", "mnemonic", "face id", "biometric"]),
        e("wallet.phrase", "Show recovery phrase", "Re-prompts for biometrics. The 24 words control every account and identity.", "Wallet", [.wallet], ["seed", "mnemonic", "backup", "export"]),
        e("wallet.key", "Show private key", "Re-prompts for biometrics. Controls this one account; what other wallets' \"import private key\" fields take.", "Wallet", [.wallet], ["export", "account"]),
        e("wallet.wipe", "Wipe wallet", "Deletes the vault from this device. Only the recovery phrase brings it back.", "Wallet", [.wallet], ["delete", "reset", "remove"]),
        // Name resolution
        e("ens", "Name Resolution", "How .eth, .wei, .gwei and .tez names are resolved and verified.", "Name Resolution", [.ens], ["ens", "wns", "gns", "tezos", "domains"]),
        e("ens.order", "Resolution order", "Freedom tries enabled methods from top to bottom. Drag the handles to reorder; tap a method for its options.", "Name Resolution", [.ens], ["method", "myotis", "colibri", "quorum", "direct"]),
        e("ens.preferVerified", "Prefer verified answers", "Keep an unverified Direct RPC answer as a fallback while later enabled methods try to produce a verified one.", "Name Resolution", [.ens]),
        e("ens.block", "Block unverified resolutions", "A resolution that came from only one endpoint shows an interstitial and requires tapping Continue once.", "Name Resolution", [.ens], ["interstitial", "unverified"]),
        e("ens.ccip", "Follow CCIP-Read (EIP-3668)", "Some ENS names (.box via 3DNS, primary names via Namestone) resolve via an offchain gateway.", "Name Resolution", [.ens], ["offchain", "gateway", "box", "namestone"]),
        e("ens.myotis", "P2P Light Client", "Names resolve locally once the light client is synced with a snap peer.", "Name Resolution", [.ens, .ensMethod(.myotis)], ["myotis", "light client"]),
        e("ens.colibri", "Colibri", "Prover endpoint and ZK consensus proof: answers checked against the sync committee.", "Name Resolution", [.ens, .ensMethod(.colibri)], ["prover", "zk", "proof", "sync committee"]),
        e("ens.quorum", "Quorum", "Byte-identical answers from M of K endpoints at one corroborated block. Endpoints per wave, required agreement, timeout, anchor TTL, block anchor.", "Name Resolution", [.ens, .ensMethod(.quorum)], ["m of k", "endpoints per wave", "timeout", "anchor"]),
        e("ens.direct", "Direct RPC", "The first endpoint that answers is used; your own endpoints first and labelled user-configured.", "Name Resolution", [.ens, .ensMethod(.direct)], ["rpc", "endpoint", "unverified"]),
        e("ens.universalResolver", "Universal Resolver", "The ENS Universal Resolver contract used for lookups.", "Name Resolution", [.ens, .ensMethod(.quorum)], ["contract", "address"]),
        // Nodes
        e("swarm", "Swarm", "Run the embedded Swarm node on app launch and right now. bzz:// page loads need it.", "Swarm", [.swarm], ["bee", "ant", "node", "bzz", "peers", "enable"]),
        e("swarm.manifests", "App permissions", "Swarm apps that declare their permissions up front, and whether you let the declaration apply or kept asking each time.", "Swarm", [.swarm], ["manifest", "declare", "disconnect"]),
        e("ipfs", "IPFS", "Run the embedded IPFS reader on app launch and right now. ipfs:// page loads need it.", "IPFS", [.ipfs], ["node", "reader", "gateway", "enable", "peers"]),
        e("ipfs.routing", "Routing", "How content is found: DHT, delegated routing, providers. Applies on the next gateway restart.", "IPFS", [.ipfs], ["dht", "delegated", "providers", "transport"]),
        e("ipfs.lowResource", "Low resource", "Fewer connections and less background work; slower first loads.", "IPFS", [.ipfs], ["battery", "memory", "connections"]),
        e("myotis", "Light Client", "Verify Ethereum and Gnosis data peer-to-peer on this device — no RPC provider or prover in the loop.", "Light Client", [.myotis], ["myotis", "ethereum", "gnosis", "p2p", "enable", "sync"]),
        e("myotis.networks", "Ethereum and Gnosis switches", "Each network runs its own light client; switch one off to save data and battery.", "Light Client", [.myotis], ["mainnet", "xdai", "per chain", "network"]),
        // Chains
        e("chains", "Chains", "The chains Freedom resolves names and balances on; add a chain from Chainlist or by hand.", "Chains", [.rpc], ["rpc", "network", "add chain", "chainlist", "custom", "endpoint", "provider"]),
        e("chains.add", "Add Chain", "Search Chainlist or enter a chain id, RPC URL and native symbol by hand.", "Chains", [.rpc, .chainlistSearch], ["chainlist", "custom", "network"]),
        // Ad blocking
        e("adblock", "Ad Blocking", "Categories (ads, privacy, cookie notices, annoyances), per-site allowlist, list updates.", "Ad Blocking", [.adblock], ["ads", "tracker", "easylist", "easyprivacy", "cookie", "annoyance", "filter", "block"]),
        e("adblock.updates", "Keep lists up to date", "Filter lists refresh from a signed Swarm feed.", "Ad Blocking", [.adblock], ["update", "feed", "signed"]),
        e("adblock.allowlist", "Allowlist", "Sites you add here have all adblock categories bypassed. Useful when blocking breaks a page you trust.", "Ad Blocking", [.adblock], ["allow", "bypass", "exception", "whitelist", "add site"]),
        // Search
        e("search", "Search", "Anything typed into the address bar that is not a URL, a hash or a name is searched with this engine.", "Search", [.search], ["engine", "duckduckgo", "google", "brave", "custom", "template", "searchTerms"]),
        e("search.custom", "Custom search engine", "An HTTPS URL with exactly one {searchTerms} (or %s) placeholder and a name.", "Search", [.search], ["template", "url", "placeholder"]),
        // Site permissions
        e("sitePermissions", "Site Permissions", "Remembered camera, microphone, motion and open-other-apps decisions per site, with removal.", "Site Permissions", [.sitePermissions], ["camera", "microphone", "motion", "orientation", "external apps", "mailto", "revoke", "remove", "blocked"]),
        // About
        e("about", "About", "Version, source code, what the app is built with.", "About", [.about], ["version", "build", "source"]),
        e("about.licenses", "Open-source licences", "Every bundled component: native components, filter lists, Swift packages, Rust crates — with licence texts.", "About", [.about, .licenses], ["license", "notice", "acknowledgements", "credits", "third party", "open source"]),
    ]
}
