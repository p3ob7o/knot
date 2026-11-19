import KnotCleanup
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotCleanupLive.self) == "KnotCleanup.KnotCleanupLive")
}
