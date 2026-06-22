// swift-tools-version: 5.9
import PackageDescription

// One Swift package, two library products, ONE binary. Both products now
// link the combined `FreedomMobile.xcframework` from
// solardev-xyz/freedom-mobile-ffi — a single Rust staticlib that bundles
// the Swarm node (`ant-ffi`, `ant_*` C ABI) and the IPFS reader
// (`freedom-ipfs-mobile`, `freedom_ipfs_*` C ABI) in one compilation
// graph (one std / allocator / libp2p / tokio).
//
// This replaces the previous split: the gomobile `Mobile.xcframework`
// (bee-lite, Go runtime) and the standalone `FreedomIpfs.xcframework`.
// Bee is gone — Swarm now runs the Rust Ant node, which serves a
// bee-compatible HTTP gateway in-process on 127.0.0.1:1633 (started via
// `ant_start_gateway`), so the app's bee-HTTP layer is unchanged. With
// bee gone there is no Go runtime, hence no `libresolv` link.
let package = Package(
    name: "SwarmKit",
    platforms: [.iOS("18.0")],
    products: [
        .library(name: "SwarmKit", targets: ["SwarmKit"]),
        .library(name: "IPFSKit", targets: ["IPFSKit"]),
    ],
    targets: [
        // Combined Swarm + IPFS Rust staticlib from
        // solardev-xyz/freedom-mobile-ffi. SHA256 verified by SwiftPM
        // before unpacking; bumps require a new release tag + checksum.
        // Local-path development override: comment out the URL/checksum
        // pair and replace with
        // `path: "../../../freedom-mobile-ffi/target/ios-xcframework/FreedomMobile.xcframework"`,
        // building locally with `./scripts/build-xcframework.sh` from
        // `../freedom-mobile-ffi`.
        // LOCAL DEV OVERRIDE (dev/ant-light-mode-local) — consume the
        // locally-built combined framework so unmerged ant changes
        // (feature/ios-gateway-chain) can be tested. REVERT to the
        // url/checksum pair below before merging.
        .binaryTarget(
            name: "FreedomMobile",
            path: "../../../freedom-mobile-ffi/target/ios-xcframework/FreedomMobile.xcframework"
        ),
        // .binaryTarget(
        //     name: "FreedomMobile",
        //     url: "https://github.com/solardev-xyz/freedom-mobile-ffi/releases/download/v0.1.0/FreedomMobile.xcframework.zip",
        //     checksum: "a3704b5a7d0f3533ab7a3b2c8b598f57acf968aa90f7d232fee1f5012df1368d"
        // ),
        .target(
            name: "SwarmKit",
            dependencies: ["FreedomMobile"],
            linkerSettings: [
                // Ant's libp2p/TLS stack pulls these Apple frameworks.
                // The combined modulemap also declares them, but list
                // them here too so app targets don't have to.
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "IPFSKit",
            dependencies: ["FreedomMobile"],
            linkerSettings: [
                // Rust hyper / reqwest pulls in SystemConfiguration for
                // proxy/network config detection on Apple platforms.
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
