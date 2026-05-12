import Foundation

/// `FreedomIpfsReader` wraps a thread-safe Rust object behind an
/// `OpaquePointer` set in init / freed in deinit; nothing mutates it
/// after init. Safe to share across threads as long as the reference
/// outlives the FFI calls.
extension FreedomIpfsReader: @unchecked Sendable {}
