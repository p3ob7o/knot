import KnotUI
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotUILive.self) == "KnotUI.KnotUILive")
}
