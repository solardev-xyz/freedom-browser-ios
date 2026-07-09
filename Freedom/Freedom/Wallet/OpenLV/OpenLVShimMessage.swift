import Foundation

/// One message from `OpenLVShim.js`, posted through the `openlv` script
/// message handler. The shim is trusted code from our own bundle, but the
/// parse is still strict — a malformed body is dropped (`nil`) rather
/// than half-routed.
enum OpenLVShimMessage {
    /// Shell page finished evaluating the shim module; the engine may
    /// now dispatch `start`/`stop` events into it.
    case ready
    case status(OpenLVEngineStatus)
    /// JSON-RPC request from the connected browser. `id` is the shim's
    /// local correlation id (not the openlv messageId, which never
    /// leaves JS).
    case request(id: Int, method: String, params: [Any])

    static func parse(_ body: Any) -> OpenLVShimMessage? {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return nil }

        switch type {
        case "ready":
            return .ready
        case "status":
            switch dict["status"] as? String {
            case "connecting": return .status(.connecting)
            case "connected": return .status(.connected)
            case "disconnected": return .status(.disconnected)
            case "failed":
                return .status(.failed(dict["message"] as? String ?? "Connection failed."))
            default:
                return nil
            }
        case "request":
            guard let id = dict["id"] as? Int,
                  let method = dict["method"] as? String else { return nil }
            return .request(id: id, method: method, params: dict["params"] as? [Any] ?? [])
        default:
            return nil
        }
    }
}
