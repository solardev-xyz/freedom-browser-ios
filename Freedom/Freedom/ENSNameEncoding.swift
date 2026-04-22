import Foundation
import web3

enum ENSNameEncoding {
    enum NameError: Error {
        case invalidLabel
    }

    /// DNS wire format: length-prefixed labels terminated by a zero byte.
    /// Universal Resolver requires the ENS name in this shape as its first
    /// arg. Root ("") encodes as a single 0 byte. Labels cap at 63 bytes.
    static func dnsEncode(_ name: String) throws -> Data {
        var out = Data()
        if !name.isEmpty {
            for label in name.split(separator: ".", omittingEmptySubsequences: false) {
                let bytes = Data(label.utf8)
                guard !bytes.isEmpty, bytes.count <= 63 else {
                    throw NameError.invalidLabel
                }
                out.append(UInt8(bytes.count))
                out.append(bytes)
            }
        }
        out.append(0)
        return out
    }

    /// ENSIP-1 namehash. Callers must normalize the name first. For v1 we
    /// expect lowercase ASCII; full ENSIP-15 unicode normalization is a
    /// later milestone and is rejected at the parse boundary for now.
    static func namehash(_ name: String) -> Data {
        var node = Data(count: 32)
        for label in name.split(separator: ".").reversed() {
            node.append(String(label).web3.keccak256)
            node = node.web3.keccak256
        }
        return node
    }
}
