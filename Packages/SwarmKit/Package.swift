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
            url: "https://github.com/solardev-xyz/bee-lite-java/releases/download/ios-v0.1.2/Mobile.xcframework.zip",
            checksum: "1781deb5d0e1f61e51423313ee06bcc11e6bc9a435c00a923c27954979b6c3be"
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
