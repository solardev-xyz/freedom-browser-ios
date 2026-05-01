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
        // Local development: relative path to the sibling
        // freedom-node-mobile build output. Switch to a URL+checksum
        // once an ios-vX.Y.Z release is cut.
        .binaryTarget(
            name: "Mobile",
            path: "../../../freedom-node-mobile/build/Mobile.xcframework"
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
