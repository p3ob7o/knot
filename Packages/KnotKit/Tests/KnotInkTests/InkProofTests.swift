#if canImport(PencilKit) && !KNOT_INK_PROBE_APP
    import Foundation
    import Testing

    // WP-18 proof step, in the package tests. Under `swift test` the process has no bundle
    // ID, and building a PKDrawing can trap there (docs/notes/WP-18.md), so the probes run
    // only under xcodebuild, whose xctest host has one. Set KNOT_INK_PROBE=1 to run them.
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KNOT_INK_PROBE"] == "1"))
    struct InkProofTests {
        @Test func probes() async throws {
            try await InkProbe.all(host: "package-tests") { print($0) }
        }
    }
#endif
