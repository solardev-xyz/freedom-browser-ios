import Foundation

/// Stale-anchor recovery, part 3: persisted sync-state *generations*.
/// Port of desktop `checkpoint-store.js` minus the multi-process
/// ownership receipts (iOS is single-process: the engine handle is the
/// owner, and `myotis_stop` is synchronous).
///
/// Layout, per chain, under `<dataDir>/<network>/`:
///
///     verified-sync.json                 pointer {schemaVersion, chainId, generation}
///     verified-sync-backup-<uuid>.json   byte-for-byte old pointer (repair only)
///     verified-sync/<uuid>/anchor.json   immutable {origin: bundled|verified, checkpoint?}
///     verified-sync/<uuid>/…             the engine's own files (snapshot, peer
///                                        caches, sync-anchor[-gnosis].json marker)
///
/// Invariants (desktop parity): generations are append-only — a new
/// one is minted for every bundled bootstrap, checkpoint replacement
/// or repair; old directories are retained, never edited, copied or
/// deleted; "retirement" is only losing the pointer. The host never
/// writes the engine's native marker — it only checks that an existing
/// marker agrees with the generation's authenticated record. Legacy
/// pre-generation engine files directly in `<network>/` (myotis v0.1.7
/// era) are left in place as a retired bundled generation.
public struct MyotisGeneration: Sendable, Equatable {
    public enum Origin: String, Codable, Sendable {
        /// Bootstrapped from the engine's embedded checkpoint (`myotis_create`).
        case bundled
        /// Bootstrapped from a quorum-and-proof-verified checkpoint
        /// (`myotis_create_with_checkpoint`).
        case verified
    }

    public var id: String
    public var chainId: UInt64
    public var directory: URL
    public var origin: Origin
    public var checkpoint: MyotisCheckpointRecord?
}

public struct MyotisGenerationStore: Sendable {
    public static let schemaVersion = 1
    /// The engine ABI that introduced the native anchor-marker contract
    /// generations are stamped with. A constant, like desktop's — NOT the
    /// current engine ABI (`MyotisNode.expectedABI`), bumping it would
    /// orphan every verified generation on disk.
    public static let nativeCheckpointApi = 26
    /// Cap on any JSON the store reads (pointer, anchor, native marker).
    public static let maxRecordBytes = 16 * 1024

    public let baseDir: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    // MARK: - Records

    struct Pointer: Codable, Equatable {
        var schemaVersion: Int
        var chainId: UInt64
        var generation: String
    }

    struct Anchor: Codable, Equatable {
        var schemaVersion: Int
        var chainId: UInt64
        var generation: String
        var nativeCheckpointApi: Int
        var origin: MyotisGeneration.Origin
        var checkpoint: MyotisCheckpointRecord?
    }

    struct NativeMarker: Codable {
        var checkpointRoot: String
        var checkpointSlot: UInt64
    }

    // MARK: - Paths

    public func chainDirectory(_ network: MyotisNetwork) -> URL {
        baseDir.appendingPathComponent(network.rawValue, isDirectory: true)
    }

    func pointerURL(_ network: MyotisNetwork) -> URL {
        chainDirectory(network).appendingPathComponent("verified-sync.json")
    }

    func generationsDirectory(_ network: MyotisNetwork) -> URL {
        chainDirectory(network).appendingPathComponent("verified-sync", isDirectory: true)
    }

    func generationDirectory(_ network: MyotisNetwork, id: String) -> URL {
        generationsDirectory(network).appendingPathComponent(id, isDirectory: true)
    }

    /// The engine's own marker for a caller-supplied anchor:
    /// `sync-anchor.json` on mainnet, `sync-anchor-gnosis.json` on Gnosis
    /// (engine `persistence_suffix`).
    public static func nativeMarkerName(_ network: MyotisNetwork) -> String {
        network == .mainnet ? "sync-anchor.json" : "sync-anchor-\(network.rawValue).json"
    }

    // MARK: - Public API

    /// The generation the engine should run: the pointed-at one when its
    /// record is intact, otherwise a fresh bundled generation (first run,
    /// legacy layout, or an unreadable pointer — never a guess at an old
    /// directory).
    public func loadOrCreate(_ network: MyotisNetwork, nowMs: Int64) throws -> MyotisGeneration {
        if let current = try loadCurrent(network, nowMs: nowMs) { return current }
        return try create(network, origin: .bundled, checkpoint: nil)
    }

    /// Mint a new verified generation for `checkpoint` and move the
    /// pointer to it. The previous generation is retained untouched.
    public func replace(
        _ network: MyotisNetwork, checkpoint: MyotisCheckpointRecord, nowMs: Int64
    ) throws -> MyotisGeneration {
        let validated = try checkpoint.validated(chainId: network.chainId, nowMs: nowMs, fresh: true)
        return try create(network, origin: .verified, checkpoint: validated)
    }

    /// "Repair sync data": back up the pointer byte-for-byte, then start
    /// a fresh bundled generation. Nothing old is modified; if the
    /// bundled anchor is itself stale the ordinary recovery runs next.
    public func repair(_ network: MyotisNetwork) throws -> MyotisGeneration {
        let pointer = pointerURL(network)
        if FileManager.default.fileExists(atPath: pointer.path) {
            let backup = chainDirectory(network)
                .appendingPathComponent("verified-sync-backup-\(UUID().uuidString.lowercased()).json")
            do { try FileManager.default.copyItem(at: pointer, to: backup) } catch { throw Self.map(error) }
        }
        return try create(network, origin: .bundled, checkpoint: nil)
    }

    /// Before handing a generation to the engine: an existing native
    /// marker must agree with the authenticated record. Absent is legal
    /// (the engine writes it on the first checkpoint create); present on
    /// a bundled generation, unreadable, or disagreeing is `.storage`.
    /// The host never manufactures or rewrites a marker.
    public func checkNativeMarker(_ generation: MyotisGeneration, network: MyotisNetwork) throws {
        let url = generation.directory.appendingPathComponent(Self.nativeMarkerName(network))
        var isDirectory: ObjCBool = false
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !exists && attributes == nil { return }
        guard let attributes, !isDirectory.boolValue,
              (attributes[.type] as? FileAttributeType) == .typeRegular
        else { throw MyotisCheckpointError.storage }
        guard generation.origin == .verified, let record = generation.checkpoint,
              let marker: NativeMarker = try? Self.readJSON(url),
              MyotisHex.root(marker.checkpointRoot) == record.root,
              marker.checkpointSlot == record.slot
        else { throw MyotisCheckpointError.storage }
    }

    // MARK: - Internals

    func loadCurrent(_ network: MyotisNetwork, nowMs: Int64) throws -> MyotisGeneration? {
        let pointerURL = pointerURL(network)
        guard FileManager.default.fileExists(atPath: pointerURL.path) else { return nil }
        let pointer: Pointer
        do { pointer = try Self.readJSON(pointerURL) } catch { throw MyotisCheckpointError.storage }
        guard pointer.schemaVersion == Self.schemaVersion, pointer.chainId == network.chainId,
              Self.isGenerationId(pointer.generation)
        else { throw MyotisCheckpointError.storage }
        let directory = generationDirectory(network, id: pointer.generation)
        let anchor: Anchor
        do { anchor = try Self.readJSON(directory.appendingPathComponent("anchor.json")) } catch {
            throw MyotisCheckpointError.storage
        }
        guard anchor.schemaVersion == Self.schemaVersion, anchor.chainId == network.chainId,
              anchor.generation == pointer.generation,
              anchor.nativeCheckpointApi == Self.nativeCheckpointApi
        else { throw MyotisCheckpointError.storage }
        var checkpoint: MyotisCheckpointRecord?
        switch anchor.origin {
        case .bundled:
            guard anchor.checkpoint == nil else { throw MyotisCheckpointError.storage }
        case .verified:
            guard let record = anchor.checkpoint else { throw MyotisCheckpointError.storage }
            do {
                checkpoint = try record.validated(chainId: network.chainId, nowMs: nowMs, fresh: false)
            } catch { throw MyotisCheckpointError.storage }
        }
        return MyotisGeneration(
            id: pointer.generation, chainId: network.chainId, directory: directory,
            origin: anchor.origin, checkpoint: checkpoint
        )
    }

    func create(
        _ network: MyotisNetwork, origin: MyotisGeneration.Origin, checkpoint: MyotisCheckpointRecord?
    ) throws -> MyotisGeneration {
        let id = UUID().uuidString.lowercased()
        let directory = generationDirectory(network, id: id)
        let anchor = Anchor(
            schemaVersion: Self.schemaVersion, chainId: network.chainId, generation: id,
            nativeCheckpointApi: Self.nativeCheckpointApi, origin: origin, checkpoint: checkpoint
        )
        let pointer = Pointer(schemaVersion: Self.schemaVersion, chainId: network.chainId, generation: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            inheritPeerCaches(network, into: directory)
            try Self.writeJSON(anchor, to: directory.appendingPathComponent("anchor.json"))
            try Self.writeJSON(pointer, to: pointerURL(network))
        } catch {
            throw Self.map(error)
        }
        return MyotisGeneration(
            id: id, chainId: network.chainId, directory: directory, origin: origin, checkpoint: checkpoint
        )
    }

    /// The engine's learned peer lists — `peers[-net].cache` (execution
    /// layer, with the served / failed verdicts that order the dials on
    /// the next start) and `cl-peers[-net].cache` (beacon side). They are
    /// addresses, not sync state, so a new generation may start from the
    /// previous one's instead of an empty pool: a cold pool is what makes
    /// the first minutes after "ready" fail every read (myotis #465).
    /// Anchor and sync-state files stay per generation.
    public static func peerCacheNames(_ network: MyotisNetwork) -> [String] {
        let suffix = network == .mainnet ? "" : "-\(network.rawValue)"
        return ["peers\(suffix).cache", "cl-peers\(suffix).cache"]
    }

    /// Best-effort copy of the peer caches from the generation the
    /// pointer names (or the legacy layout's chain directory) into a
    /// freshly created generation directory. Never fails the creation:
    /// an unreadable pointer or a missing cache simply means a cold pool,
    /// as before.
    private func inheritPeerCaches(_ network: MyotisNetwork, into directory: URL) {
        let fm = FileManager.default
        var sources: [URL] = []
        if let pointer: Pointer = try? Self.readJSON(pointerURL(network)),
           pointer.chainId == network.chainId, Self.isGenerationId(pointer.generation) {
            sources.append(generationDirectory(network, id: pointer.generation))
        }
        sources.append(chainDirectory(network))
        for name in Self.peerCacheNames(network) {
            let destination = directory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            for source in sources {
                let candidate = source.appendingPathComponent(name)
                guard candidate != destination, fm.fileExists(atPath: candidate.path) else { continue }
                if (try? fm.copyItem(at: candidate, to: destination)) != nil { break }
            }
        }
    }

    static func isGenerationId(_ id: String) -> Bool {
        guard id.count == 36, UUID(uuidString: id) != nil else { return false }
        return id == id.lowercased()
    }

    static func readJSON<T: Decodable>(_ url: URL) throws -> T {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maxRecordBytes
        else { throw MyotisCheckpointError.storage }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    /// Filesystem refusals (full, read-only, permissions) are
    /// `.storageIO`; everything else that is not already a checkpoint
    /// error is `.storage`.
    static func map(_ error: Error) -> MyotisCheckpointError {
        if let known = error as? MyotisCheckpointError { return known }
        let ns = error as NSError
        let posix: Int32? = {
            if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain { return Int32(underlying.code) }
            return nil
        }()
        if let posix, [ENOSPC, EDQUOT, EACCES, EPERM, EROFS, EIO, EMFILE, ENFILE].contains(posix) {
            return .storageIO
        }
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteOutOfSpaceError, NSFileWriteVolumeReadOnlyError, NSFileWriteNoPermissionError]
            .contains(ns.code)
        {
            return .storageIO
        }
        return .storage
    }
}
