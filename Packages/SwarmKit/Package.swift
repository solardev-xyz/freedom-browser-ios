// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwarmKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SwarmKit", targets: ["SwarmKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "Mobile",
            url: "https://github.com/solardev-xyz/bee-lite-java/releases/download/ios-v0.1.0/Mobile.xcframework.zip",
            checksum: "865ea29cb69a63db50bbb395613f6b4dd75c5a42175167a7b63db8b6c21e7751"
        ),
        .target(
            name: "SwarmKit",
            dependencies: ["Mobile"],
            linkerSettings: [
                .linkedLibrary("resolv"),
            ]
        ),
    ]
)
