import Foundation
import FreedomIpfs

public enum FreedomIpfsReaderError: Error, Equatable {
    case createNodeFailed
    case invalidNode
    case startGatewayFailed
    case importCarFailed
    case exportCarFailed
}

public enum FreedomIpfsRoutingMode: UInt32, Sendable {
    case auto = 0
    case delegated = 1
    case lightDht = 2
    case offline = 3
}

public struct FreedomIpfsStats: Equatable, Sendable {
    public let blockCount: UInt64
    public let totalBytes: UInt64
}

public struct FreedomIpfsRetrievalCounters: Equatable, Sendable {
    public let cacheHits: UInt64
    public let httpProviderBlocks: UInt64
    public let bitswapBlocks: UInt64
}

public struct FreedomIpfsRoutingCounters: Equatable, Sendable {
    public let delegatedProviderLookups: UInt64
    public let delegatedProviderResults: UInt64
    public let delegatedProviderErrors: UInt64
    public let dhtProviderLookups: UInt64
    public let dhtProviderResults: UInt64
    public let dhtProviderErrors: UInt64
}

public struct FreedomIpfsDiagnostics: Equatable, Sendable {
    public let stats: FreedomIpfsStats
    public let retrievalStats: FreedomIpfsRetrievalCounters
    public let routingStats: FreedomIpfsRoutingCounters
    public let activePreloadCount: UInt64
    public let isGatewayRunning: Bool
    public let isBackgrounded: Bool
}

public final class FreedomIpfsReader {
    private var handle: OpaquePointer?

    public init() throws {
        guard let handle = freedom_ipfs_node_new_in_memory() else {
            throw FreedomIpfsReaderError.createNodeFailed
        }
        self.handle = handle
    }

    public init(dataDirectory: URL, maxCacheBytes: UInt64 = 0) throws {
        let handle = dataDirectory.path.withCString { path in
            freedom_ipfs_node_new_with_data_dir(path, maxCacheBytes)
        }
        guard let handle else {
            throw FreedomIpfsReaderError.createNodeFailed
        }
        self.handle = handle
    }

    deinit {
        if let handle {
            freedom_ipfs_node_free(handle)
        }
    }

    public static var version: String {
        guard let ptr = freedom_ipfs_version() else {
            return ""
        }
        defer { freedom_ipfs_string_free(ptr) }
        return String(cString: ptr)
    }

    public func startGateway(address: String = "127.0.0.1:0") throws {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let ok = address.withCString { addressPtr in
            freedom_ipfs_node_start_gateway(handle, addressPtr)
        }
        guard ok else {
            throw FreedomIpfsReaderError.startGatewayFailed
        }
    }

    public func startOnlineGateway(
        address: String = "127.0.0.1:0",
        delegatedRouter: String? = nil,
        routingMode: FreedomIpfsRoutingMode = .auto,
        maxConcurrentRequests: Int = 0,
        dhtQueryTimeoutSeconds: UInt64 = 0,
        dhtMaxProviders: Int = 0
    ) throws {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let ok = address.withCString { addressPtr in
            if let delegatedRouter {
                return delegatedRouter.withCString { routerPtr in
                    freedom_ipfs_node_start_gateway_online_with_config_v2(
                        handle,
                        addressPtr,
                        routerPtr,
                        routingMode.rawValue,
                        maxConcurrentRequests,
                        dhtQueryTimeoutSeconds,
                        dhtMaxProviders
                    )
                }
            }
            return freedom_ipfs_node_start_gateway_online_with_config_v2(
                handle,
                addressPtr,
                nil,
                routingMode.rawValue,
                maxConcurrentRequests,
                dhtQueryTimeoutSeconds,
                dhtMaxProviders
            )
        }
        guard ok else {
            throw FreedomIpfsReaderError.startGatewayFailed
        }
    }

    public func startOnlineGateway(
        address: String = "127.0.0.1:0",
        delegatedRouters: [String],
        routingMode: FreedomIpfsRoutingMode = .auto,
        maxConcurrentRequests: Int = 0,
        dhtQueryTimeoutSeconds: UInt64 = 0,
        dhtMaxProviders: Int = 0
    ) throws {
        let routerList = delegatedRouters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        try startOnlineGateway(
            address: address,
            delegatedRouter: routerList.isEmpty ? nil : routerList,
            routingMode: routingMode,
            maxConcurrentRequests: maxConcurrentRequests,
            dhtQueryTimeoutSeconds: dhtQueryTimeoutSeconds,
            dhtMaxProviders: dhtMaxProviders
        )
    }

    public func restartOnlineGateway(
        address: String = "127.0.0.1:0",
        delegatedRouter: String? = nil,
        routingMode: FreedomIpfsRoutingMode = .auto,
        maxConcurrentRequests: Int = 0,
        dhtQueryTimeoutSeconds: UInt64 = 0,
        dhtMaxProviders: Int = 0
    ) throws {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let ok = address.withCString { addressPtr in
            if let delegatedRouter {
                return delegatedRouter.withCString { routerPtr in
                    freedom_ipfs_node_restart_gateway_online_with_config_v2(
                        handle,
                        addressPtr,
                        routerPtr,
                        routingMode.rawValue,
                        maxConcurrentRequests,
                        dhtQueryTimeoutSeconds,
                        dhtMaxProviders
                    )
                }
            }
            return freedom_ipfs_node_restart_gateway_online_with_config_v2(
                handle,
                addressPtr,
                nil,
                routingMode.rawValue,
                maxConcurrentRequests,
                dhtQueryTimeoutSeconds,
                dhtMaxProviders
            )
        }
        guard ok else {
            throw FreedomIpfsReaderError.startGatewayFailed
        }
    }

    public func restartOnlineGateway(
        address: String = "127.0.0.1:0",
        delegatedRouters: [String],
        routingMode: FreedomIpfsRoutingMode = .auto,
        maxConcurrentRequests: Int = 0,
        dhtQueryTimeoutSeconds: UInt64 = 0,
        dhtMaxProviders: Int = 0
    ) throws {
        let routerList = delegatedRouters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        try restartOnlineGateway(
            address: address,
            delegatedRouter: routerList.isEmpty ? nil : routerList,
            routingMode: routingMode,
            maxConcurrentRequests: maxConcurrentRequests,
            dhtQueryTimeoutSeconds: dhtQueryTimeoutSeconds,
            dhtMaxProviders: dhtMaxProviders
        )
    }

    public func setRoutingMode(
        _ routingMode: FreedomIpfsRoutingMode,
        delegatedRouters: [String] = [],
        maxConcurrentRequests: Int = 0,
        dhtQueryTimeoutSeconds: UInt64 = 0,
        dhtMaxProviders: Int = 0
    ) throws {
        try restartOnlineGateway(
            delegatedRouters: delegatedRouters,
            routingMode: routingMode,
            maxConcurrentRequests: maxConcurrentRequests,
            dhtQueryTimeoutSeconds: dhtQueryTimeoutSeconds,
            dhtMaxProviders: dhtMaxProviders
        )
    }

    public var gatewayURL: URL? {
        guard let handle, let ptr = freedom_ipfs_node_gateway_url(handle) else {
            return nil
        }
        defer { freedom_ipfs_string_free(ptr) }
        return URL(string: String(cString: ptr))
    }

    public func localGatewayURL(for address: String) -> URL? {
        guard
            let gatewayURL,
            let path = Self.gatewayPathParts(for: address),
            var components = URLComponents(url: gatewayURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.percentEncodedPath = path.percentEncodedPath
        components.percentEncodedQuery = path.percentEncodedQuery
        components.percentEncodedFragment = path.percentEncodedFragment
        return components.url
    }

    public static func gatewayPath(for address: String) -> String? {
        gatewayPathParts(for: address)?.rendered
    }

    private static func gatewayPathParts(for address: String) -> GatewayPath? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let direct = GatewayPath(gatewayStyleAddress: trimmed) {
            return direct
        }

        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "ipfs" || scheme == "ipns"
        else {
            return nil
        }

        let authority = components.host ?? ""
        guard !authority.isEmpty else {
            return nil
        }

        let prefix = scheme == "ipfs" ? "/ipfs/" : "/ipns/"
        let path = prefix + authority + components.percentEncodedPath
        return GatewayPath(
            percentEncodedPath: path,
            percentEncodedQuery: components.percentEncodedQuery,
            percentEncodedFragment: components.percentEncodedFragment
        )
    }

    public func preload(path: String) -> UInt64 {
        guard let handle else {
            return 0
        }
        return path.withCString { pathPtr in
            freedom_ipfs_node_preload_path(handle, pathPtr)
        }
    }

    public func cancelPreload(taskID: UInt64) -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_cancel_preload(handle, taskID)
    }

    @discardableResult
    public func stopGateway() -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_stop_gateway(handle)
    }

    public var stats: FreedomIpfsStats {
        guard let handle else {
            return FreedomIpfsStats(blockCount: 0, totalBytes: 0)
        }
        return FreedomIpfsStats(
            blockCount: freedom_ipfs_node_block_count(handle),
            totalBytes: freedom_ipfs_node_total_bytes(handle)
        )
    }

    public var retrievalStats: FreedomIpfsRetrievalCounters {
        guard let handle else {
            return FreedomIpfsRetrievalCounters(
                cacheHits: 0,
                httpProviderBlocks: 0,
                bitswapBlocks: 0
            )
        }
        let stats = freedom_ipfs_node_retrieval_stats(handle)
        return FreedomIpfsRetrievalCounters(
            cacheHits: stats.cache_hits,
            httpProviderBlocks: stats.http_provider_blocks,
            bitswapBlocks: stats.bitswap_blocks
        )
    }

    public var routingStats: FreedomIpfsRoutingCounters {
        guard let handle else {
            return FreedomIpfsRoutingCounters(
                delegatedProviderLookups: 0,
                delegatedProviderResults: 0,
                delegatedProviderErrors: 0,
                dhtProviderLookups: 0,
                dhtProviderResults: 0,
                dhtProviderErrors: 0
            )
        }
        let stats = freedom_ipfs_node_routing_stats(handle)
        return FreedomIpfsRoutingCounters(
            delegatedProviderLookups: stats.delegated_provider_lookups,
            delegatedProviderResults: stats.delegated_provider_results,
            delegatedProviderErrors: stats.delegated_provider_errors,
            dhtProviderLookups: stats.dht_provider_lookups,
            dhtProviderResults: stats.dht_provider_results,
            dhtProviderErrors: stats.dht_provider_errors
        )
    }

    public var activePreloadCount: UInt64 {
        guard let handle else {
            return 0
        }
        return freedom_ipfs_node_active_preload_count(handle)
    }

    public var diagnostics: FreedomIpfsDiagnostics {
        guard let handle else {
            return FreedomIpfsDiagnostics(
                stats: FreedomIpfsStats(blockCount: 0, totalBytes: 0),
                retrievalStats: FreedomIpfsRetrievalCounters(
                    cacheHits: 0,
                    httpProviderBlocks: 0,
                    bitswapBlocks: 0
                ),
                routingStats: FreedomIpfsRoutingCounters(
                    delegatedProviderLookups: 0,
                    delegatedProviderResults: 0,
                    delegatedProviderErrors: 0,
                    dhtProviderLookups: 0,
                    dhtProviderResults: 0,
                    dhtProviderErrors: 0
                ),
                activePreloadCount: 0,
                isGatewayRunning: false,
                isBackgrounded: false
            )
        }
        let snapshot = freedom_ipfs_node_diagnostics(handle)
        return FreedomIpfsDiagnostics(
            stats: FreedomIpfsStats(
                blockCount: snapshot.block_count,
                totalBytes: snapshot.total_bytes
            ),
            retrievalStats: FreedomIpfsRetrievalCounters(
                cacheHits: snapshot.cache_hits,
                httpProviderBlocks: snapshot.http_provider_blocks,
                bitswapBlocks: snapshot.bitswap_blocks
            ),
            routingStats: FreedomIpfsRoutingCounters(
                delegatedProviderLookups: snapshot.delegated_provider_lookups,
                delegatedProviderResults: snapshot.delegated_provider_results,
                delegatedProviderErrors: snapshot.delegated_provider_errors,
                dhtProviderLookups: snapshot.dht_provider_lookups,
                dhtProviderResults: snapshot.dht_provider_results,
                dhtProviderErrors: snapshot.dht_provider_errors
            ),
            activePreloadCount: snapshot.active_preload_count,
            isGatewayRunning: snapshot.gateway_running != 0,
            isBackgrounded: snapshot.lifecycle_background != 0
        )
    }

    public func clearCache() -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_clear_cache(handle)
    }

    public func trimCache(maxBytes: UInt64) -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_trim_cache(handle, maxBytes)
    }

    public func enterBackground() -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_enter_background(handle)
    }

    public func enterForeground() -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_enter_foreground(handle)
    }

    public func handleLowMemory(maxCacheBytes: UInt64 = 0) -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_handle_low_memory(handle, maxCacheBytes)
    }

    public func handleNetworkChange() -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_handle_network_change(handle)
    }

    public func importCar(_ data: Data) throws {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let ok = data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return freedom_ipfs_node_import_car(handle, base, bytes.count)
        }
        guard ok else {
            throw FreedomIpfsReaderError.importCarFailed
        }
    }

    public func exportCar() throws -> Data {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let buffer = freedom_ipfs_node_export_car(handle)
        defer { freedom_ipfs_buffer_free(buffer) }
        guard let data = buffer.data else {
            return Data()
        }
        guard buffer.len > 0 else {
            return Data()
        }
        return Data(bytes: data, count: buffer.len)
    }
}

private struct GatewayPath {
    let percentEncodedPath: String
    let percentEncodedQuery: String?
    let percentEncodedFragment: String?

    init(percentEncodedPath: String, percentEncodedQuery: String?, percentEncodedFragment: String?) {
        self.percentEncodedPath = percentEncodedPath
        self.percentEncodedQuery = percentEncodedQuery
        self.percentEncodedFragment = percentEncodedFragment
    }

    init?(gatewayStyleAddress: String) {
        guard
            let components = URLComponents(string: gatewayStyleAddress),
            components.scheme == nil,
            components.host == nil,
            components.percentEncodedPath.hasPrefix("/ipfs/")
                || components.percentEncodedPath.hasPrefix("/ipns/")
        else {
            return nil
        }
        self.init(
            percentEncodedPath: components.percentEncodedPath,
            percentEncodedQuery: components.percentEncodedQuery,
            percentEncodedFragment: components.percentEncodedFragment
        )
    }

    var rendered: String {
        var output = percentEncodedPath
        if let percentEncodedQuery {
            output += "?\(percentEncodedQuery)"
        }
        if let percentEncodedFragment {
            output += "#\(percentEncodedFragment)"
        }
        return output
    }
}
