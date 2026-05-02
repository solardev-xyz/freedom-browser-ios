// swift-tools-version: 5.9
import PackageDescription

// One Swift package, two library products (SwarmKit + IPFSKit), one
// underlying binary target. The combined `Mobile.xcframework` (built by
// freedom-node-mobile/Makefile build-ios) embeds both bee-lite and kubo
// into a single Go runtime — required because two gomobile-bound
// xcframeworks cannot coexist in one iOS process (they conflict over Go
// runtime TLS slots and crash at startup, regardless of which is
// actually used).
//
// The two Swift targets share the binary so they share the runtime.
// Each exposes only its own slice of the gomobile-generated Obj-C
// surface (MobileMobile* for bee, MobileIpfs* for kubo).
let package = Package(
    name: "SwarmKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SwarmKit", targets: ["SwarmKit"]),
        .library(name: "IPFSKit", targets: ["IPFSKit"]),
    ],
    targets: [
        // Combined bee+kubo xcframework built by
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
            dependencies: ["Mobile"],
            linkerSettings: [
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
