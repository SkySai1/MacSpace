// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSpace",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacSpaceCore", targets: ["MacSpaceCore"]),
        .executable(name: "MacSpace", targets: ["MacSpace"])
    ],
    targets: [
        .target(name: "MacSpaceCore"),
        .executableTarget(name: "MacSpace", dependencies: ["MacSpaceCore"]),
        .testTarget(name: "MacSpaceCoreTests", dependencies: ["MacSpaceCore"]),
        .testTarget(name: "MacSpaceTests", dependencies: ["MacSpace", "MacSpaceCore"])
    ]
)
