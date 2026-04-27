import XCTest
@testable import Freedom

/// `BeeIdentityInjector`'s end-to-end orchestration (stop → wipe → write →
/// start) needs a real Bee node to verify, so we don't unit-test it. What
/// we do test is the small load-bearing helper: the address-match check
/// that drives the same-mnemonic re-import short-circuit. Wrong logic
/// here means either every unlock triggers a 4s restart (annoying), or
/// a real key change is silently skipped (a bug that ships with no
/// observable symptom until the user wonders why their funds aren't
/// where they expected).
final class BeeIdentityInjectorTests: XCTestCase {
    func testAddressesMatchOnIdenticalLowercase() {
        XCTAssertTrue(
            BeeIdentityInjector.addressesMatch(
                "0xabcdef0123456789abcdef0123456789abcdef01",
                "0xabcdef0123456789abcdef0123456789abcdef01"
            )
        )
    }

    /// SwarmNode reports addresses without 0x prefix in some bee-lite
    /// versions; HDKey returns them with prefix. The matcher must bridge
    /// both shapes — otherwise every unlock looks like a key change.
    func testAddressesMatchAcrossPrefixedAndUnprefixed() {
        XCTAssertTrue(
            BeeIdentityInjector.addressesMatch(
                "0xabcdef0123456789abcdef0123456789abcdef01",
                "abcdef0123456789abcdef0123456789abcdef01"
            )
        )
    }

    /// EIP-55 mixed-case addresses come from any UI layer that checksums.
    /// We compare lowercase-only to avoid a "checksum mismatch but bytes
    /// equal" false negative.
    func testAddressesMatchAcrossDifferingCase() {
        XCTAssertTrue(
            BeeIdentityInjector.addressesMatch(
                "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01",
                "0xabcdef0123456789abcdef0123456789abcdef01"
            )
        )
    }

    func testAddressesMismatchOnDifferentBytes() {
        XCTAssertFalse(
            BeeIdentityInjector.addressesMatch(
                "0xabcdef0123456789abcdef0123456789abcdef01",
                "0x1111111111111111111111111111111111111111"
            )
        )
    }

    /// A freshly-constructed `SwarmNode` reports `walletAddress == ""`
    /// before its first start completes. The injector must NOT short-
    /// circuit on this — otherwise initial vault create on a never-yet-
    /// started node would skip the keystore write entirely.
    func testEmptyStringDoesNotMatchAnything() {
        XCTAssertFalse(BeeIdentityInjector.addressesMatch("", ""))
        XCTAssertFalse(
            BeeIdentityInjector.addressesMatch("0xabcdef0123456789abcdef0123456789abcdef01", "")
        )
        XCTAssertFalse(
            BeeIdentityInjector.addressesMatch("", "0xabcdef0123456789abcdef0123456789abcdef01")
        )
    }
}
