import Foundation
import web3

/// Thin adapter so Argent's `EthereumAccount` can sign with the key we
/// derived ourselves via BIP-32. `storePrivateKey` is a no-op because the
/// key already lives in the `HDKey`; we just need a way to hand Argent
/// the 32 bytes for one signing operation.
///
/// Use by constructing a fresh instance per sign — the adapter holds the
/// key as a `Data` field, but there's no long-term persistence path here
/// (that's `VaultCrypto`'s job).
struct HDKeyStorage: EthereumSingleKeyStorageProtocol {
    let privateKey: Data

    func loadPrivateKey() throws -> Data {
        privateKey
    }

    func storePrivateKey(key: Data) throws {
        // no-op; the key's lifetime is the signing call
    }
}
