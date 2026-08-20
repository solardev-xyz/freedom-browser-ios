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
        .library(name: "MyotisKit", targets: ["MyotisKit"]),
        .library(name: "RadicleKit", targets: ["RadicleKit"]),
    ],
    targets: [
        // Combined Swarm + IPFS + Myotis Rust staticlib from
        // solardev-xyz/freedom-mobile-ffi (built from ant v0.5.43 +
        // freedom-ipfs v0.4.3 + myotis v0.1.7). SHA256 verified by
        // SwiftPM before unpacking; bumps require a new release tag +
        // checksum.
        // Local-path development override: comment out the URL/checksum
        // pair and replace with
        // `path: "../../../freedom-mobile-ffi/target/ios-xcframework/FreedomMobile.xcframework"`,
        // building locally with `./scripts/build-xcframework.sh` from
        // `../freedom-mobile-ffi`.
        .binaryTarget(
            name: "FreedomMobile",
            url: "https://github.com/solardev-xyz/freedom-mobile-ffi/releases/download/v0.10.0/FreedomMobile.xcframework.zip",
            checksum: "7570d65a26a43867546951ffb78acc952fa6e34066a0792c413178bbe198d415"
        ),
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
        .target(
            name: "MyotisKit",
            dependencies: ["FreedomMobile"],
            linkerSettings: [
                // Myotis's devp2p/libp2p stack uses the same Apple
                // frameworks as ant (rustls via Security keychain roots,
                // if-watch via SystemConfiguration).
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Radicle (libradicle-uniffi member). Unlike the C-ABI members,
        // the Swift API in Generated/ is produced by uniffi-bindgen at
        // xcframework build time (freedom-mobile-ffi's
        // scripts/build-xcframework.sh) and committed here; regenerate it
        // whenever the FreedomMobile binary is bumped — a version skew is
        // a load-time checksum failure by design.
        .target(
            name: "RadicleKit",
            dependencies: ["FreedomMobile"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                // Vendored libgit2 (git2 crate) compresses with the
                // system zlib and transcodes paths with iconv.
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
