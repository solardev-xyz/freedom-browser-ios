import Foundation
import FreedomIpfs

public enum FreedomIpfsReaderError: Error, Equatable {
    case createNodeFailed
    case invalidNode
    case startGatewayFailed
    case importCarFailed
    case exportCarFailed
    case nativeGatewayRequestFailed
    case invalidNativeGatewayRequest
}

public enum FreedomIpfsRoutingMode: UInt32, Sendable {
    case auto = 0
    case delegated = 1
    case lightDht = 2
    case offline = 3
}

public enum FreedomIpfsNativeGatewayReadStatus: UInt32, Sendable {
    case pending = 0
    case bytes = 1
    case end = 2
    case cancelled = 3
    case failed = 4
    case invalidHandle = 5
}

public struct FreedomIpfsNativeGatewayReadResult: Equatable, Sendable {
    public let status: FreedomIpfsNativeGatewayReadStatus
    public let bytesRead: Int
}

public enum FreedomIpfsNativeGatewayEventStatus: UInt32, Sendable {
    case ok = 0
    case timeout = 1
    case invalidNode = 2
    case gatewayStopped = 3
}

public struct FreedomIpfsNativeGatewayEventFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let responseReady = FreedomIpfsNativeGatewayEventFlags(rawValue: 1 << 0)
    public static let bodyReady = FreedomIpfsNativeGatewayEventFlags(rawValue: 1 << 1)
    public static let end = FreedomIpfsNativeGatewayEventFlags(rawValue: 1 << 2)
    public static let failed = FreedomIpfsNativeGatewayEventFlags(rawValue: 1 << 3)
    public static let cancelled = FreedomIpfsNativeGatewayEventFlags(rawValue: 1 << 4)
    public static let handleFreed = FreedomIpfsNativeGatewayEventFlags(rawValue: 1 << 5)
}

public struct FreedomIpfsNativeGatewayEvent: Equatable, Sendable {
    public let status: FreedomIpfsNativeGatewayEventStatus
    public let events: FreedomIpfsNativeGatewayEventFlags
    public let requestHandle: UInt64
}

public struct FreedomIpfsStats: Equatable, Sendable {
    public let blockCount: UInt64
    public let totalBytes: UInt64
}

public struct FreedomIpfsRetrievalCounters: Equatable, Sendable {
    public let cacheHits: UInt64
    public let httpProviderBlocks: UInt64
    public let bitswapBlocks: UInt64

    public func delta(since previous: FreedomIpfsRetrievalCounters) -> FreedomIpfsRetrievalCounters {
        FreedomIpfsRetrievalCounters(
            cacheHits: Self.saturatingSubtract(cacheHits, previous.cacheHits),
            httpProviderBlocks: Self.saturatingSubtract(httpProviderBlocks, previous.httpProviderBlocks),
            bitswapBlocks: Self.saturatingSubtract(bitswapBlocks, previous.bitswapBlocks)
        )
    }

    private static func saturatingSubtract(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

public struct FreedomIpfsRoutingCounters: Equatable, Sendable {
    public let delegatedProviderLookups: UInt64
    public let delegatedProviderResults: UInt64
    public let delegatedProviderErrors: UInt64
    public let dhtProviderLookups: UInt64
    public let dhtProviderResults: UInt64
    public let dhtProviderErrors: UInt64

    public func delta(since previous: FreedomIpfsRoutingCounters) -> FreedomIpfsRoutingCounters {
        FreedomIpfsRoutingCounters(
            delegatedProviderLookups: Self.saturatingSubtract(
                delegatedProviderLookups,
                previous.delegatedProviderLookups
            ),
            delegatedProviderResults: Self.saturatingSubtract(
                delegatedProviderResults,
                previous.delegatedProviderResults
            ),
            delegatedProviderErrors: Self.saturatingSubtract(
                delegatedProviderErrors,
                previous.delegatedProviderErrors
            ),
            dhtProviderLookups: Self.saturatingSubtract(dhtProviderLookups, previous.dhtProviderLookups),
            dhtProviderResults: Self.saturatingSubtract(dhtProviderResults, previous.dhtProviderResults),
            dhtProviderErrors: Self.saturatingSubtract(dhtProviderErrors, previous.dhtProviderErrors)
        )
    }

    private static func saturatingSubtract(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}

public struct FreedomIpfsDiagnostics: Equatable, Sendable {
    public let stats: FreedomIpfsStats
    public let retrievalStats: FreedomIpfsRetrievalCounters
    public let routingStats: FreedomIpfsRoutingCounters
    public let activePreloadCount: UInt64
    public let isGatewayRunning: Bool
    public let isBackgrounded: Bool

    public func delta(since previous: FreedomIpfsDiagnostics) -> FreedomIpfsDiagnosticsDelta {
        FreedomIpfsDiagnosticsDelta(
            retrievalStats: retrievalStats.delta(since: previous.retrievalStats),
            routingStats: routingStats.delta(since: previous.routingStats),
            activePreloadCount: activePreloadCount,
            isGatewayRunning: isGatewayRunning,
            isBackgrounded: isBackgrounded
        )
    }
}

public struct FreedomIpfsDiagnosticsDelta: Equatable, Sendable {
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

    /// Configure online retrieval for the native request/event API
    /// **without binding a loopback HTTP gateway**. Backed by
    /// `freedom_ipfs_node_start_native_gateway_online_with_config_v2`
    /// (freedom-ipfs v0.4.0+). Calling it again on a live reader swaps
    /// the gateway core in place, preserving the block cache — so it
    /// doubles as the restart path. `freedom_ipfs_node_gateway_url`
    /// stays `nil` after this; there is no local HTTP server.
    public func startNativeGateway(
        delegatedRouter: String? = nil,
        routingMode: FreedomIpfsRoutingMode = .auto,
        maxConcurrentRequests: Int = 0,
        dhtQueryTimeoutSeconds: UInt64 = 0,
        dhtMaxProviders: Int = 0
    ) throws {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let ok: Bool
        if let delegatedRouter {
            ok = delegatedRouter.withCString { routerPtr in
                freedom_ipfs_node_start_native_gateway_online_with_config_v2(
                    handle,
                    routerPtr,
                    routingMode.rawValue,
                    maxConcurrentRequests,
                    dhtQueryTimeoutSeconds,
                    dhtMaxProviders
                )
            }
        } else {
            ok = freedom_ipfs_node_start_native_gateway_online_with_config_v2(
                handle,
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

    public func startNativeGateway(
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
        try startNativeGateway(
            delegatedRouter: routerList.isEmpty ? nil : routerList,
            routingMode: routingMode,
            maxConcurrentRequests: maxConcurrentRequests,
            dhtQueryTimeoutSeconds: dhtQueryTimeoutSeconds,
            dhtMaxProviders: dhtMaxProviders
        )
    }

    public func startNativeGatewayRequest(json: String) throws -> UInt64 {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let requestHandle = json.withCString { requestPtr in
            freedom_ipfs_gateway_request_start(handle, requestPtr)
        }
        guard requestHandle != 0 else {
            throw FreedomIpfsReaderError.nativeGatewayRequestFailed
        }
        return requestHandle
    }

    public func nativeGatewayResponseJSON(requestHandle: UInt64) throws -> String {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        guard let ptr = freedom_ipfs_gateway_request_response_json(handle, requestHandle) else {
            throw FreedomIpfsReaderError.invalidNativeGatewayRequest
        }
        defer { freedom_ipfs_string_free(ptr) }
        return String(cString: ptr)
    }

    public func nativeGatewayResponseJSON(
        requestHandle: UInt64,
        timeoutMilliseconds: UInt64
    ) throws -> String {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        guard let ptr = freedom_ipfs_gateway_request_response_json_wait(
            handle,
            requestHandle,
            timeoutMilliseconds
        ) else {
            throw FreedomIpfsReaderError.invalidNativeGatewayRequest
        }
        defer { freedom_ipfs_string_free(ptr) }
        return String(cString: ptr)
    }

    public func readNativeGatewayRequest(
        _ requestHandle: UInt64,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> FreedomIpfsNativeGatewayReadResult {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        guard let baseAddress = buffer.baseAddress, buffer.count > 0 else {
            throw FreedomIpfsReaderError.invalidNativeGatewayRequest
        }
        let result = freedom_ipfs_gateway_request_read(
            handle,
            requestHandle,
            baseAddress.assumingMemoryBound(to: UInt8.self),
            buffer.count
        )
        let status = FreedomIpfsNativeGatewayReadStatus(rawValue: result.status) ?? .failed
        return FreedomIpfsNativeGatewayReadResult(status: status, bytesRead: Int(result.bytes_read))
    }

    public func readNativeGatewayRequest(
        _ requestHandle: UInt64,
        into buffer: UnsafeMutableRawBufferPointer,
        timeoutMilliseconds: UInt64
    ) throws -> FreedomIpfsNativeGatewayReadResult {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        guard let baseAddress = buffer.baseAddress, buffer.count > 0 else {
            throw FreedomIpfsReaderError.invalidNativeGatewayRequest
        }
        let result = freedom_ipfs_gateway_request_read_wait(
            handle,
            requestHandle,
            baseAddress.assumingMemoryBound(to: UInt8.self),
            buffer.count,
            timeoutMilliseconds
        )
        let status = FreedomIpfsNativeGatewayReadStatus(rawValue: result.status) ?? .failed
        return FreedomIpfsNativeGatewayReadResult(status: status, bytesRead: Int(result.bytes_read))
    }

    public func waitNextNativeGatewayEvent(
        timeoutMilliseconds: UInt64
    ) throws -> FreedomIpfsNativeGatewayEvent {
        guard let handle else {
            throw FreedomIpfsReaderError.invalidNode
        }
        let event = freedom_ipfs_gateway_wait_next_event(handle, timeoutMilliseconds)
        let status = FreedomIpfsNativeGatewayEventStatus(rawValue: event.status) ?? .gatewayStopped
        return FreedomIpfsNativeGatewayEvent(
            status: status,
            events: FreedomIpfsNativeGatewayEventFlags(rawValue: event.events),
            requestHandle: event.request_handle
        )
    }

    @discardableResult
    public func cancelNativeGatewayRequest(_ requestHandle: UInt64) -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_gateway_request_cancel(handle, requestHandle)
    }

    @discardableResult
    public func freeNativeGatewayRequest(_ requestHandle: UInt64) -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_gateway_request_free(handle, requestHandle)
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

    public var progressSnapshotJSON: String {
        guard let handle, let ptr = freedom_ipfs_node_progress_snapshot_json(handle) else {
            return "{\"active\":[],\"events\":[]}"
        }
        defer { freedom_ipfs_string_free(ptr) }
        return String(cString: ptr)
    }

    /// Raw JSON snapshot of native FFI transport counters: active
    /// handles, started/completed/failed/cancelled/freed totals,
    /// bytes streamed, event queue depth, last native error code &
    /// message. Shape is documented in `freedom-ipfs`'s
    /// `NativeGatewayStatsSnapshot`. Empty-stats string when the node
    /// is not running.
    public var nativeGatewayStatsJSON: String {
        guard let handle, let ptr = freedom_ipfs_node_native_gateway_stats_json(handle) else {
            return "{\"active_native_handles\":0}"
        }
        defer { freedom_ipfs_string_free(ptr) }
        return String(cString: ptr)
    }

    public func clearProgress() -> Bool {
        guard let handle else {
            return false
        }
        return freedom_ipfs_node_clear_progress(handle)
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
