// WP-18 proof step: the probes as tests hosted in the probe app, the arrangement that
// Knot-iOS-Tests uses for what runs only in the iOS Simulator. See ProbeApp.swift.

#if KNOT_INK_PROBE_APP
    @testable import InkProbe
    import Testing

    @Suite(.serialized) struct ProbeHostedTests {
        @Test @MainActor func probes() async throws {
            print("ink-proof [\(InkProbe.place), hosted-tests] state at start: \(ProbeApp.state)")
            try await InkProbe.all(host: "hosted-tests") { print($0) }
        }
    }
#endif
