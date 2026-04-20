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
            path: "../../../bee-lite-java/build/Mobile.xcframework"
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
