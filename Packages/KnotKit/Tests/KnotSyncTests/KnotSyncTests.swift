import KnotSync
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotSyncLive.self) == "KnotSync.KnotSyncLive")
}
