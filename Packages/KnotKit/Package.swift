// swift-tools-version: 6.2
//
// KnotKit: all of Knot's logic, one target per module of docs/architecture.md §3.
//
// WP-01 declares every target, test target, executable and resource folder here, so
// that no later package edits this file. A package that needs a change asks the
// orchestrator for it in its pull request.

import PackageDescription

// GRDB is the one third-party dependency (D30). Its version and its revision are both
// pinned. scripts/verify.sh (step `pins`) checks this revision against SwiftPM's
// Package.resolved and against the one Xcode resolves for the generated project.
let grdbVersion: Version = "7.12.0"
let grdbRevision = "92a554cd0d5e8d67cb18993c6054e73fe42c066c"

// Swift 6 language mode (the default for this tools version), strict concurrency
// complete, warnings are errors.
let strict: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let appleWithUI: [Platform] = [.iOS, .macOS]

func module(
    _ name: String,
    _ dependencies: [Target.Dependency] = [],
    resources: [Resource]? = nil
) -> Target {
    .target(name: name, dependencies: dependencies, resources: resources, swiftSettings: strict)
}

func tests(_ name: String, _ dependencies: [Target.Dependency]) -> Target {
    .testTarget(name: name, dependencies: dependencies, swiftSettings: strict)
}

func tool(_ name: String, _ dependencies: [Target.Dependency]) -> Target {
    .executableTarget(name: name, dependencies: dependencies, swiftSettings: strict)
}

let package = Package(
    name: "KnotKit",
    defaultLocalization: "en",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
        .watchOS("27.0"),
    ],
    products: [
        .library(name: "KnotCore", targets: ["KnotCore"]),
        .library(name: "KnotStore", targets: ["KnotStore"]),
        .library(name: "KnotAudio", targets: ["KnotAudio"]),
        .library(name: "KnotCapture", targets: ["KnotCapture"]),
        .library(name: "KnotSpeech", targets: ["KnotSpeech"]),
        .library(name: "KnotCleanup", targets: ["KnotCleanup"]),
        .library(name: "KnotInk", targets: ["KnotInk"]),
        .library(name: "KnotSync", targets: ["KnotSync"]),
        .library(name: "KnotLink", targets: ["KnotLink"]),
        .library(name: "KnotIntents", targets: ["KnotIntents"]),
        .library(name: "KnotExport", targets: ["KnotExport"]),
        .library(name: "KnotUI", targets: ["KnotUI"]),
        .library(name: "KnotAgent", targets: ["KnotAgent"]),
        .library(name: "KnotApp", targets: ["KnotApp"]),
        .library(name: "KnotFakes", targets: ["KnotFakes"]),
        .library(name: "KnotUIPreviews", targets: ["KnotUIPreviews"]),
        .executable(name: "knot", targets: ["knot"]),
        .executable(name: "knot-eval", targets: ["knot-eval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: grdbVersion)
    ],
    targets: [
        // Modules, in the order of docs/architecture.md §3. The dependencies are the
        // "Uses" column; the gate builds with --explicit-target-dependency-import-check.
        module("KnotCore", resources: [.process("Resources")]),
        module("KnotStore", ["KnotCore", grdb]),
        module("KnotAudio", ["KnotCore"]),
        module("KnotCapture", ["KnotCore"]),
        module("KnotSpeech", ["KnotCore"]),
        module("KnotCleanup", ["KnotCore"], resources: [.process("Resources")]),
        module("KnotInk", ["KnotCore"]),
        module("KnotSync", ["KnotCore", "KnotStore"]),
        module("KnotLink", ["KnotCore"]),
        module("KnotIntents", ["KnotCore"], resources: [.process("Resources")]),
        module("KnotExport", ["KnotCore"]),
        module(
            "KnotUI",
            [
                "KnotCore",
                .target(name: "KnotInk", condition: .when(platforms: appleWithUI)),
                .target(name: "KnotExport", condition: .when(platforms: appleWithUI)),
            ],
            resources: [.process("Resources")]
        ),
        module("KnotAgent", ["KnotCore", "KnotExport"]),
        module(
            "KnotApp",
            [
                "KnotCore", "KnotStore", "KnotAudio", "KnotCapture", "KnotSpeech", "KnotCleanup",
                "KnotInk", "KnotSync", "KnotIntents", "KnotExport", "KnotUI", "KnotFakes",
                .target(name: "KnotLink", condition: .when(platforms: [.iOS])),
                .target(name: "KnotAgent", condition: .when(platforms: [.macOS])),
            ]
        ),
        // A fake for every leaf port, fixture builders and the preview environment. It
        // imports no test framework. Debug builds of the apps link it; release builds
        // must not hold it (scripts/verify.sh, step `packaging`).
        module(
            "KnotFakes",
            ["KnotCore", .target(name: "KnotCapture", condition: .when(platforms: appleWithUI))]
        ),
        // The shared contract suites, one per port. Test targets only.
        module("KnotTestSupport", ["KnotCore", "KnotFakes"]),
        module("KnotUIPreviews", ["KnotCore", "KnotUI", "KnotFakes"]),

        // Executables.
        tool("knot", ["KnotCore", "KnotAgent", "KnotExport", "KnotStore"]),
        tool("knot-eval", ["KnotCore", "KnotSpeech", "KnotCleanup"]),

        // Crash hosts: small processes that a kill test starts and kills
        // (docs/architecture.md §17), and the soak's child.
        tool("KnotStoreCrashHost", ["KnotCore", "KnotStore", grdb]),
        tool("KnotAudioCrashHost", ["KnotCore", "KnotAudio"]),
        tool("KnotLinkCrashHost", ["KnotCore", "KnotLink"]),
        tool("KnotInkCrashHost", ["KnotCore", "KnotInk"]),
        tool("KnotSoakChild", ["KnotCore", "KnotStore", "KnotCapture", "KnotAudio", "KnotFakes", grdb]),

        // Test targets. Each one already depends on what its package will need, because
        // this file does not change after WP-01.
        tests("KnotCoreTests", ["KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests(
            "KnotStoreTests",
            ["KnotStore", "KnotCore", "KnotTestSupport", "KnotFakes", grdb, "KnotStoreCrashHost"]
        ),
        tests("KnotAudioTests", ["KnotAudio", "KnotCore", "KnotTestSupport", "KnotFakes", "KnotAudioCrashHost"]),
        tests("KnotCaptureTests", ["KnotCapture", "KnotCore", "KnotStore", "KnotTestSupport", "KnotFakes"]),
        tests("KnotSpeechTests", ["KnotSpeech", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests("KnotCleanupTests", ["KnotCleanup", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests("KnotInkTests", ["KnotInk", "KnotCore", "KnotTestSupport", "KnotFakes", "KnotInkCrashHost"]),
        tests("KnotSyncTests", ["KnotSync", "KnotStore", "KnotCore", "KnotTestSupport", "KnotFakes", grdb]),
        tests("KnotLinkTests", ["KnotLink", "KnotCore", "KnotTestSupport", "KnotFakes", "KnotLinkCrashHost"]),
        tests("KnotIntentsTests", ["KnotIntents", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests("KnotExportTests", ["KnotExport", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests("KnotUITests", ["KnotUI", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests("KnotAgentTests", ["KnotAgent", "KnotExport", "KnotStore", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests(
            "KnotAppTests",
            [
                "KnotApp", "KnotCore", "KnotStore", "KnotAudio", "KnotCapture", "KnotSpeech",
                "KnotCleanup", "KnotInk", "KnotSync", "KnotIntents", "KnotExport", "KnotUI",
                "KnotTestSupport", "KnotFakes",
                .target(name: "KnotLink", condition: .when(platforms: [.iOS])),
                .target(name: "KnotAgent", condition: .when(platforms: [.macOS])),
            ]
        ),
        tests("KnotFakesTests", ["KnotFakes", "KnotCore", "KnotTestSupport"]),
        tests("KnotTestSupportTests", ["KnotTestSupport", "KnotCore", "KnotFakes"]),
        tests("KnotUIPreviewsTests", ["KnotUIPreviews", "KnotUI", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests("knotTests", ["knot", "KnotAgent", "KnotStore", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        tests(
            "knot-evalTests", ["knot-eval", "KnotSpeech", "KnotCleanup", "KnotCore", "KnotTestSupport", "KnotFakes"]),
        // The capture ledger soak (WP-06). WP-11, WP-12 and WP-15 each add one file of
        // kill points to Tests/KnotSoak/.
        tests(
            "KnotSoak",
            [
                "KnotSoakChild", "KnotCore", "KnotStore", "KnotCapture", "KnotAudio", "KnotTestSupport",
                "KnotFakes", grdb,
            ]
        ),
    ]
)
