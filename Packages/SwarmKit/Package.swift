// swift-tools-version: 5.9
import PackageDescription

// One Swift package, two library products. SwarmKit links the gomobile
// `Mobile.xcframework` (bee-lite) from freedom-node-mobile. IPFSKit
// links the Rust `FreedomIpfs.xcframework` from freedom-ipfs — a
// lightweight read-only IPFS reader. The two frameworks are
// independent (Rust has no Go runtime), so they coexist in one process
// without the gomobile-TLS-slot conflict that prevented this before.
let package = Package(
    name: "SwarmKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SwarmKit", targets: ["SwarmKit"]),
        .library(name: "IPFSKit", targets: ["IPFSKit"]),
    ],
    targets: [
        // Bee-lite gomobile binding from
        // solardev-xyz/freedom-node-mobile@ios-build-target. SHA256 is
        // verified by SwiftPM before unpacking; bumps require a new tag,
        // a new release, and a new checksum here.
        // Local-path development override: comment out the URL/checksum
        // pair below and replace with `path: "../../../freedom-node-mobile/build/Mobile.xcframework"`.
        .binaryTarget(
            name: "Mobile",
            url: "https://github.com/solardev-xyz/freedom-node-mobile/releases/download/ios-v0.1.0/Mobile.xcframework.zip",
            checksum: "270a6ee96c03c2bd8d6c1197f488a6ec6810f2391e44225e2d9ceff398664aed"
        ),
        // Rust read-only IPFS reader from flotob/freedom-ipfs. Built
        // locally during the spike via
        // `cargo run -p xtask -- build-xcframework`. Replace with a
        // `url:`/`checksum:` pair once a release artifact is published.
        .binaryTarget(
            name: "FreedomIpfs",
            path: "../../../freedom-ipfs/target/ios-xcframework/FreedomIpfs.xcframework"
        ),
        .target(
            name: "SwarmKit",
            dependencies: ["Mobile"],
            linkerSettings: [
                // Go's net package uses BSD libresolv (res_9_n*) for DNS
                // on iOS. Declared once here so app targets don't have
                // to add libresolv.tbd manually.
                .linkedLibrary("resolv"),
            ]
        ),
        .target(
            name: "IPFSKit",
            dependencies: ["FreedomIpfs"],
            linkerSettings: [
                // Rust hyper / reqwest pulls in SystemConfiguration for
                // proxy/network config detection on Apple platforms.
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
