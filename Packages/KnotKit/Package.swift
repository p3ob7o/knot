// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KnotKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "KnotKit", targets: ["KnotKit"]),
        .executable(name: "KnotBenchmark", targets: ["KnotBenchmark"]),
        .executable(name: "KnotVaultWorker", targets: ["KnotVaultWorker"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .target(
            name: "KnotKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .executableTarget(name: "KnotBenchmark", dependencies: ["KnotKit"]),
        .executableTarget(name: "KnotVaultWorker", dependencies: ["KnotKit"]),
        .testTarget(name: "KnotKitTests", dependencies: ["KnotKit"])
    ]
)
