import XCTest
import RadicleKit

/// The control-socket path is the one piece of Radicle bring-up that
/// depends on the RUN ENVIRONMENT, not the code: unix sockets cap at
/// 104 path bytes, and the simulator remaps every sandbox dir under its
/// enormous device-container path (first smoke test failed exactly
/// here, twice). This suite runs inside that environment, so a nil or
/// over-long candidate breaks the build before it breaks a smoke test.
final class RadicleSocketPathTests: XCTestCase {
    func testShortSocketPathFitsSunPathHere() throws {
        let path = try XCTUnwrap(
            RadicleNode.shortSocketPath(),
            "no writable socket location fits sun_path in this environment"
        )
        XCTAssertLessThanOrEqual(path.utf8.count, 103, "candidate too long: \(path)")
        let dir = (path as NSString).deletingLastPathComponent
        XCTAssertTrue(
            FileManager.default.isWritableFile(atPath: dir),
            "candidate dir not writable: \(dir)"
        )
    }
}
