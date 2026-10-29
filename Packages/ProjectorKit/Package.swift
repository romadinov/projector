// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectorKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ProjectorKit", targets: ["ProjectorKit"]),
    ],
    targets: [
        .target(name: "ProjectorKit"),
        .testTarget(name: "ProjectorKitTests", dependencies: ["ProjectorKit"]),
    ]
)
