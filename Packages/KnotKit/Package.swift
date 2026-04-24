// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KnotKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "KnotKit", targets: ["KnotKit"])
    ],
    targets: [
        .target(name: "KnotKit"),
        .testTarget(name: "KnotKitTests", dependencies: ["KnotKit"])
    ]
)
