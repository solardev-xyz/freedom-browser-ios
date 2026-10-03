import XCTest
@testable import Freedom

/// Same phrase → same Radicle DID as desktop (`PATHS.RADICLE`,
/// `createRadicleIdentity`): vectors from `docs/ipfs-identity-golden-vectors.md`.
final class RadicleIdentityKeyTests: XCTestCase {
    func testMatchesDesktopGoldenVectors() throws {
        let cases: [(String, String, String, String)] = [
            ("test test test test test test test test test test test junk",
             "af48066c1ee69bd6d95166f9298d585e85f981c140e76b716c10b72e4f54be69",
             "8d8ac6623e5d13848a67428f1ab2c7fc4d121894efc161f64138eab494f1514d",
             "did:key:z6MkoynGGksuz9zpQ9HkFZ3Ayj7FqexXDYbzasYNAGwXftBE"),
            ("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
             "b262e62fc6a558fd045ca68dd7000e30a135f678bc0816935e13ebe6a97e14bd",
             "1fbc19d1e386f9969c5e7925d71ce5b332b399ee632b17f4743a3248823e248b",
             "did:key:z6Mkgb93MjdiDEUrHVCY2X4EfaSwzoFCorViqqPnjoQX8gAn"),
        ]
        for (phrase, sk, pk, did) in cases {
            let key = try RadicleIdentityKey.derive(fromSeed: Mnemonic(phrase: phrase).seed())
            XCTAssertEqual(key.privateKey.hexString, sk, phrase)
            XCTAssertEqual(key.publicKey.hexString, pk, phrase)
            XCTAssertEqual(key.did, did, phrase)
        }
    }

    func testDistinctFromTheIPFSKeyAndDeterministic() throws {
        let seed = try Mnemonic(phrase: "test test test test test test test test test test test junk").seed()
        let radicle = try RadicleIdentityKey.derive(fromSeed: seed)
        let ipfs = try IpfsIdentityKey.derive(fromSeed: seed)
        XCTAssertNotEqual(radicle.privateKey, ipfs.privateKey)
        XCTAssertEqual(radicle, try RadicleIdentityKey.derive(fromSeed: seed))
        XCTAssertEqual(radicle.privateKey.count, 32)
        XCTAssertTrue(radicle.did.hasPrefix("did:key:z6Mk"))
    }

    func testStoreRoundTrip() throws {
        let store = RadicleIdentityStore(item: KeychainItem(account: "radicle.node-key", service: "RadicleIdentityKeyTests-\(UUID().uuidString)"))
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let key = try RadicleIdentityKey.derive(fromSeed: Mnemonic(phrase: "test test test test test test test test test test test junk").seed())
        try store.save(key.privateKey)
        XCTAssertEqual(try store.load(), key.privateKey)
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
