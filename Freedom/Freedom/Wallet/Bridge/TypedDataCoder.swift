import Foundation
import web3

/// Dapps pass `typedData` either as a JSON string or as a JSON object —
/// decode both via JSONSerialization, then through the typed decoder.
/// Shared by the dapp bridge and the openlv wallet endpoint.
enum TypedDataCoder {
    enum Error: Swift.Error, LocalizedError, Equatable {
        /// `types` lacks an entry the encoder will force-unwrap —
        /// `primaryType` or `EIP712Domain`.
        case missingType(String)

        var errorDescription: String? {
            switch self {
            case .missingType(let name):
                return "types is missing an entry for \"\(name)\"."
            }
        }
    }

    static func decode(_ param: Any) throws -> TypedData {
        let data: Data
        if let string = param as? String {
            data = Data(string.utf8)
        } else if let object = param as? [String: Any] {
            data = try JSONSerialization.data(withJSONObject: object)
        } else {
            throw PersonalSignCoder.Error.badParams
        }
        let typed = try JSONDecoder().decode(TypedData.self, from: data)
        try validate(typed)
        return typed
    }

    /// web3.swift's `TypedData.encodeType` force-unwraps
    /// `types[primaryType]!` — its dependency walk skips undefined
    /// types, but the raw `primaryType` is prepended unchecked, and
    /// `signableHash()` also encodes `"EIP712Domain"` the same way. A
    /// page-supplied payload missing either entry (dapps do omit
    /// `EIP712Domain`; MetaMask tolerates it) would crash the app
    /// instead of erroring the RPC call. Reject both up front so the
    /// bridge replies `-32602`. Note `primaryType` must match a
    /// `types` key *verbatim* — an array-suffixed form (`"Order[]"`)
    /// is invalid per EIP-712 and would also crash the encoder.
    ///
    /// Undefined types referenced from struct *fields* are safe to
    /// pass through: the encoder treats them as atomic and throws
    /// `ABIError` cleanly, which the signing path already maps to an
    /// RPC error.
    private static func validate(_ typed: TypedData) throws {
        for required in [typed.primaryType, "EIP712Domain"]
        where typed.types[required] == nil {
            throw Error.missingType(required)
        }
    }
}
