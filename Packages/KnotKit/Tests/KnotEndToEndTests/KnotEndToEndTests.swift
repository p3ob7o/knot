import KnotApp
import KnotCore
import Testing

// The end-to-end suite: fixture audio through to a finished note, kill and relaunch, and
// the canary that fails when a made-up word from the fixtures reaches a log line. WP-22
// builds it.

@Test func liveEnvironmentIsBuilt() {
    #expect(String(reflecting: type(of: EnvironmentFactory.live)) == "KnotCore.AppEnvironment")
}
