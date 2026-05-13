// swift-tools-version:5.9
import PackageDescription

// Vendored from `corpus-core/colibri-stateless` release v1.1.24
// (`colibri-swift-package.zip`). When the partner publishes a standalone
// `corpus-core/colibri-stateless-swift` repo we swap this local package for
// a remote `.package(url:from:)` — the public API surface (`import Colibri`,
// `Colibri()`, `colibri.rpc(...)`) is the same, so no callsite changes.
//
// Bumping: download the new release's `colibri-swift-package.zip`, replace
// `c4_swift.xcframework/`, `Sources/`, `Tests/`, and re-verify against
// `Packages/ColibriKit/Tests`. Keep this Package.swift in sync with upstream
// when the target shape changes.
let package = Package(
    name: "Colibri",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Colibri", targets: ["Colibri"])
    ],
    targets: [
        .binaryTarget(
            name: "c4_swift",
            path: "c4_swift.xcframework"
        ),
        .target(
            name: "CColibriMacOS",
            dependencies: ["c4_swift"],
            path: "Sources/CColibri",
            sources: ["swift_storage_bridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        .target(
            name: "Colibri",
            dependencies: ["c4_swift", "CColibriMacOS"],
            path: "Sources/Colibri",
            sources: ["Colibri.swift"],
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        .testTarget(
            name: "ColibriTests",
            dependencies: ["Colibri"],
            path: "Tests"
        )
    ]
)
