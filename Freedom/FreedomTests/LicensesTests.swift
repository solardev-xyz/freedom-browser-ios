import XCTest
@testable import Freedom

/// The bundled licence inventory matches what the app actually ships:
/// the FreedomMobile pin, every Swift package in Package.resolved, a
/// text for every licence a Rust crate names. Regenerate with
/// `scripts/licenses/generate.py` when this fails after a bump.
final class LicensesTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testInventoryMatchesTheFreedomMobilePin() throws {
        let inventory = try LicenseInventory.load()
        let packageSwift = try String(contentsOf: repoRoot.appendingPathComponent("Packages/SwarmKit/Package.swift"), encoding: .utf8)
        let pinned = try XCTUnwrap(packageSwift.firstMatch(of: /releases\/download\/(v[0-9.]+)\/FreedomMobile/)?.1)
        XCTAssertEqual(inventory.ffiTag, String(pinned), "regenerate licenses.json for the new FreedomMobile pin")
        XCTAssertGreaterThan(inventory.rustCrates.count, 500)
        XCTAssertEqual(inventory.components.map(\.name).count, 4)
    }

    func testEverySwiftPackageIsListed() throws {
        let inventory = try LicenseInventory.load()
        let resolved = repoRoot.appendingPathComponent("Freedom/Freedom.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any]
        let pins = try XCTUnwrap(json?["pins"] as? [[String: Any]])
        let identities = Set(pins.compactMap { $0["identity"] as? String }.map { "swift:\($0)" })
        XCTAssertEqual(Set(inventory.swiftPackages.map(\.id)), identities, "regenerate licenses.json for the changed Swift packages")
        for package in inventory.swiftPackages {
            XCTAssertFalse(inventory.texts(for: package).isEmpty, "\(package.name) has no licence text")
        }
    }

    func testEveryEntryHasALicenceAndAText() throws {
        let inventory = try LicenseInventory.load()
        // Exceptions without an SPDX text: `WITH` exceptions and crates
        // that only point at a licence file in their repository.
        let allowed: Set<String> = ["LLVM-exception", "see", "repository", "unknown"]
        for entry in inventory.all {
            XCTAssertFalse(entry.license.isEmpty, entry.id)
            XCTAssertFalse(entry.name.isEmpty, entry.id)
        }
        for crate in inventory.rustCrates {
            for id in LicenseInventory.spdxIDs(in: crate.license) where !allowed.contains(id) {
                XCTAssertNotNil(inventory.spdxTexts[id], "no SPDX text for \(id) (\(crate.id))")
            }
            XCTAssertFalse(inventory.texts(for: crate).isEmpty, "no text for \(crate.id)")
        }
        for component in inventory.components {
            XCTAssertFalse(inventory.texts(for: component).isEmpty, "no text for \(component.id)")
        }
        let myotis = try XCTUnwrap(inventory.components.first { $0.id.contains("myotis") })
        XCTAssertTrue(myotis.notice?.contains("Dirk Jäckel") == true, "Apache-2.0 §4(d): Myotis NOTICE must ship")
        XCTAssertEqual(inventory.filterLists.map(\.id).sorted(), ["list:easylist", "list:easylist-annoyances", "list:easylist-cookies", "list:easyprivacy"])
    }

    func testSPDXExpressionParsing() {
        XCTAssertEqual(LicenseInventory.spdxIDs(in: "MIT OR Apache-2.0"), ["MIT", "Apache-2.0"])
        XCTAssertEqual(LicenseInventory.spdxIDs(in: "(MIT OR Apache-2.0) AND Unicode-3.0"), ["MIT", "Apache-2.0", "Unicode-3.0"])
        XCTAssertEqual(LicenseInventory.spdxIDs(in: "Apache-2.0 WITH LLVM-exception OR MIT"), ["Apache-2.0", "LLVM-exception", "MIT"])
        XCTAssertEqual(LicenseInventory.spdxIDs(in: "MIT/Apache-2.0"), ["MIT", "Apache-2.0"])
    }
}
