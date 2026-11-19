import KnotCapture
import Testing

@Test func liveEntryPointIsDeclared() {
    #expect(String(reflecting: KnotCaptureLive.self) == "KnotCapture.KnotCaptureLive")
}
