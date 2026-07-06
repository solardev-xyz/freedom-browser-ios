import Foundation
import web3

/// Verification of the Swarm-feed filter-list manifest. Pure — no I/O.
///
/// Mirrors `update-manifest.js` in the desktop browser and `manifest.ts` in
/// freedom-adblock-service. The wire format is one JSON document with
/// per-platform sections; iOS consumes `platforms.ios.lists[]` (pre-compiled
/// WebKit content-blocker JSON shards) and joins `platforms.desktop.lists[]`
/// by `list_id` for display metadata (title, source URL).
///
/// Verification gates, in order:
///  1. well-formed JSON object with `sig`
///  2. schema == `AdblockUpdateFeed.manifestSchema`
///  3. structural sanity (non-empty iOS lists, hex refs/hashes)
///  4. monotonic version — reject anything <= the already-applied version
///  5. EIP-191 signature over the canonical manifest bytes recovers to the
///     pinned signer address
enum AdblockManifestError: Error, Equatable {
    case malformed(String)
    case badSchema(Int)
    case notNewer(version: Int, applied: Int)
    case badSignature(String)
    case signerMismatch(recovered: String, expected: String)
}

/// Typed view of the manifest (snake_case on the wire).
struct AdblockFeedManifest: Codable, Equatable {
    let schema: Int
    let version: Int
    let generatedAt: String
    let engines: [String: String]
    let platforms: Platforms
    let sig: String?

    struct Platforms: Codable, Equatable {
        let desktop: DesktopSection
        let ios: IosSection
    }

    struct DesktopSection: Codable, Equatable {
        let lists: [DesktopList]
    }

    struct DesktopList: Codable, Equatable {
        let category: String
        let listId: String
        let title: String?
        let sourceUrl: String
        let license: String
        let ref: String
        let sha256: String
        let bytes: Int
        let ruleCount: Int
    }

    struct IosSection: Codable, Equatable {
        let lists: [IosList]
    }

    struct IosList: Codable, Equatable {
        let listId: String
        let shards: [IosShard]
    }

    struct IosShard: Codable, Equatable {
        let filename: String
        let ref: String
        let sha256: String
        let bytes: Int
        let ruleCount: Int
    }

    func desktopList(id: String) -> DesktopList? {
        platforms.desktop.lists.first { $0.listId == id }
    }
}

enum AdblockUpdateManifest {
    /// The exact bytes `sig` is computed and verified over: the manifest
    /// without its `sig` field, keys recursively sorted, compact JSON.
    /// Must be byte-identical to the publisher's
    /// `canonicalManifestForSigning` (JS `JSON.stringify` over deep-sorted
    /// keys) — `.sortedKeys` gives the recursive sort, and
    /// `.withoutEscapingSlashes` is load-bearing: `JSONSerialization`
    /// escapes `/` as `\/` by default where `JSON.stringify` does not, and
    /// the manifest is full of URLs. Proven byte-identical by golden
    /// vectors generated with the publisher's own code
    /// (`AdblockUpdateManifestTests`).
    static func canonicalBytes(payload: Data) throws -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw AdblockManifestError.malformed("payload is not a JSON object")
        }
        object.removeValue(forKey: "sig")
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// EIP-191 personal-sign recovery over the canonical bytes: keccak256 of
    /// `"\x19Ethereum Signed Message:\n<len>" + canonical`, then secp256k1
    /// ecrecover. Returns the lowercase `0x…` signer address.
    static func recoverSigner(canonical: Data, sig: String) throws -> String {
        guard let sigData = sig.web3.hexData, sigData.count == 65 else {
            throw AdblockManifestError.badSignature(sig)
        }
        let prefix = "\u{19}Ethereum Signed Message:\n\(canonical.count)"
        let digest = (Data(prefix.utf8) + canonical).web3.keccak256
        guard let address = try? KeyUtil.recoverPublicKey(message: digest, signature: sigData) else {
            throw AdblockManifestError.badSignature(sig)
        }
        return address.lowercased()
    }

    /// Full verification pipeline. `appliedVersion` is the feed version the
    /// app last applied (nil when still on bundled lists).
    static func verify(
        payload: Data,
        sigAddress: String,
        appliedVersion: Int?
    ) throws -> AdblockFeedManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let manifest = try? decoder.decode(AdblockFeedManifest.self, from: payload) else {
            throw AdblockManifestError.malformed("manifest does not decode")
        }
        guard let sig = manifest.sig, !sig.isEmpty else {
            throw AdblockManifestError.malformed("manifest has no sig")
        }
        guard manifest.schema == AdblockUpdateFeed.manifestSchema else {
            throw AdblockManifestError.badSchema(manifest.schema)
        }
        try assertStructure(manifest)
        if let applied = appliedVersion, manifest.version <= applied {
            throw AdblockManifestError.notNewer(version: manifest.version, applied: applied)
        }

        let canonical = try canonicalBytes(payload: payload)
        let recovered = try recoverSigner(canonical: canonical, sig: sig)
        guard recovered == sigAddress.lowercased() else {
            throw AdblockManifestError.signerMismatch(recovered: recovered, expected: sigAddress.lowercased())
        }
        return manifest
    }

    private static func assertStructure(_ manifest: AdblockFeedManifest) throws {
        guard manifest.version > 0 else {
            throw AdblockManifestError.malformed("non-positive version")
        }
        guard !manifest.platforms.ios.lists.isEmpty else {
            throw AdblockManifestError.malformed("empty ios list section")
        }
        for list in manifest.platforms.ios.lists {
            guard !list.shards.isEmpty else {
                throw AdblockManifestError.malformed("list \(list.listId) has no shards")
            }
            for shard in list.shards {
                guard SwarmRef.isHex(shard.ref, length: 64), SwarmRef.isHex(shard.sha256, length: 64) else {
                    throw AdblockManifestError.malformed("bad ref/sha256 on \(shard.filename)")
                }
                guard shard.bytes > 0 else {
                    throw AdblockManifestError.malformed("empty shard \(shard.filename)")
                }
            }
        }
    }
}
