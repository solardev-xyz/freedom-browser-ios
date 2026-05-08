// swift-tools-version: 5.9
import PackageDescription

// One Swift package, two library products. SwarmKit links the gomobile
// `Mobile.xcframework` (bee-lite) from solardev-xyz/bee-lite-java.
// IPFSKit links the Rust `FreedomIpfs.xcframework` from
// flotob/freedom-ipfs — a lightweight read-only IPFS reader. The two
// frameworks are independent (Rust has no Go runtime), so they coexist
// in one process without the gomobile-TLS-slot conflict that prevented
// this before. Previously SwarmKit pulled the combined bee+kubo
// `Mobile.xcframework` from solardev-xyz/freedom-node-mobile; that
// existed only to share one Go runtime between bee and kubo, and is
// no longer needed now that kubo is gone.
let package = Package(
    name: "SwarmKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SwarmKit", targets: ["SwarmKit"]),
        .library(name: "IPFSKit", targets: ["IPFSKit"]),
    ],
    targets: [
        // Bee-lite gomobile binding from solardev-xyz/bee-lite-java.
        // SHA256 is verified by SwiftPM before unpacking; bumps
        // require a new tag, a new release, and a new checksum here.
        // Local-path development override: comment out the URL/checksum
        // pair below and replace with `path: "../../../bee-lite-java/build/Mobile.xcframework"`.
        .binaryTarget(
            name: "Mobile",
            url: "https://github.com/solardev-xyz/bee-lite-java/releases/download/ios-v0.1.2/Mobile.xcframework.zip",
            checksum: "1781deb5d0e1f61e51423313ee06bcc11e6bc9a435c00a923c27954979b6c3be"
        ),
        // Rust read-only IPFS reader from solardev-xyz/freedom-ipfs.
        // Released artifact built from the
        // `codex/kubo-session-rc-consolidation` performance branch
        // (commit cfe2e3c). SHA256 is verified by SwiftPM before
        // unpacking; bumps require a new tag, a new release, and a new
        // checksum here.
        //
        // Local-path development override: comment out the URL/checksum
        // pair below and replace with
        // `path: "../../../freedom-ipfs/target/ios-xcframework/FreedomIpfs.xcframework"`,
        // then build the XCFramework with
        // `cargo run -p xtask -- build-xcframework` from `freedom-ipfs`.
        .binaryTarget(
            name: "FreedomIpfs",
            url: "https://github.com/solardev-xyz/freedom-ipfs/releases/download/ios-v0.2.0-rust-reader.1/FreedomIpfs.xcframework.zip",
            checksum: "c2aa24aac4e51448a412aac050cf09718f532f32c34ebcddfe337ba20d5839a4"
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
