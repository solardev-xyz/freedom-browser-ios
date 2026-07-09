import Foundation
import web3

/// Dapps pass `typedData` either as a JSON string or as a JSON object —
/// decode both via JSONSerialization, then through the typed decoder.
/// Shared by the dapp bridge and the openlv wallet endpoint.
enum TypedDataCoder {
    static func decode(_ param: Any) throws -> TypedData {
        let data: Data
        if let string = param as? String {
            data = Data(string.utf8)
        } else if let object = param as? [String: Any] {
            data = try JSONSerialization.data(withJSONObject: object)
        } else {
            throw PersonalSignCoder.Error.badParams
        }
        return try JSONDecoder().decode(TypedData.self, from: data)
    }
}
